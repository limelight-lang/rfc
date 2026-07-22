# Lowering: C Structures and LLVM IR Patterns

Companion to [classes.md](classes.md): how the class and object model maps to concrete C structures and to the LLVM IR emitted for each operation. C is used for structure definitions and runtime helpers; IR is shown for the hot paths the compiler emits inline.

---

## Core Structures

```c
// Common refcounted header: offset 0 of EVERY heap entity
// (object, string, array, closure, reference)
typedef struct RcHeader {
    _Atomic uint32_t refcount;
    _Atomic uint32_t flags;      // bits: [0-1] memory category, [2-3] GC state,
                                 //       [4-5] cycle color, [6] buffered,
                                 //       [7] has-weak, [8] DESTRUCTOR_PENDING,
                                 //       [9] DESTRUCTOR_RAN, [10] COW,
                                 //       [11] live escapee, [12-14] entity kind,
                                 //       [15-31] candidate index.
                                 // Authoritative table: classes.md "Flags layout"
} RcHeader;

#define LL_MEMCAT_MASK 0x3u      // 00=GC heap, 01=request arena,
                                 // 10=long-lived, 11=immortal

typedef struct Object {
    RcHeader      rc;            // +0
    struct Class *cls;           // +8
    // +16: property slots, each the machine representation of its
    // declared type (classes.md, "Slot kinds"). Laid out as three runs
    // — counted pointers, Boxes, then the rest in declaration order —
    // followed by the byte block (init bits, packed bools). There is no
    // uniform slot size and no per-slot tag.
    // Classes allowing dynamic properties have one extra hidden slot:
    // a lazily-allocated hashtable pointer.
} Object;

// So a PHP class lowers to an ordinary C struct:
//   class Node { public Node $next; public ?Node $prev;
//                public $meta; public int $id; public bool $ok; }
typedef struct Node {
    RcHeader      rc;            // +0
    struct Class *cls;           // +8
    struct Node  *next;          // +16  ┐ counted-pointer run. next: Node
    struct Node  *prev;          // +24  ┘ (non-null) → NULL means uninitialized;
                                 //        prev: ?Node → NULL is php null,
                                 //        uninitialized is an init-bitmap bit
    Value         meta;          // +32    untyped → Box (undef flag if uninit)
    int64_t       id;            // +40    id: int, uninitialized via bitmap bit
    uint8_t       ok;            // +48    ok: bool
    uint8_t       init_bits;     // +49    prev + id tracked here (fits padding)
} Node;                          // object_size 56

typedef struct InterfaceEntry {
    uint32_t interface_id;
    void   **itable;             // array of code pointers, slots fixed
} InterfaceEntry;                // by interface declaration order

typedef struct Class {
    uint32_t      flags;         // final/abstract/interface + magic-method bitmask
    uint32_t      object_size;
    uint32_t      layout_end;    // first free byte, unrounded: where a
                                 // subclass resumes (classes.md)
    struct Class *parent;
    void         *factory;       // factory(ctx, category): allocate + init;
                                 // the dynamic `new $class` path (classes.md)
    void         *dispose;       // dispose(obj): release counted fields, run
                                 // __destruct if present
    PropLayout   *prop_layout;   // name → (offset, slot kind, hook flags,
                                 //         declaration index)
    Run          *ptr_runs;      // (offset,count) list — counted-pointer runs,
                                 // stride 8, skip NULL (GC trace, clone, dispose)
    uint32_t      ptr_run_count;
    Run          *box_runs;      // (offset,count) list — Box runs, stride 16,
                                 // skip when the refcounted flag is clear
    uint32_t      box_run_count;
    struct Class **display;      // Cohen display, indexed by depth (instanceof)
    uint32_t      display_len;
    uint32_t      destruct_slot; // vtbl slot of __destruct, or NO_DESTRUCT_SLOT
    InterfaceEntry *interfaces;  // sorted by interface_id
    uint32_t      interface_count;
    MethodTable  *methods;       // interned name → method (slow path)
    TlsHandle     statics_tls;   // TLS handle of the static block (classes.md):
                                 // a tagged union — link-time-constant offset for
                                 // an image class, or a (module,offset) dynamic
                                 // slot for a late-loaded one. Thread-local, laid
                                 // out like an object; not a pointer, since each
                                 // thread's block is at its own address
    void        **static_vtbl;   // own table only if this class overrides an
                                 // inherited static method; otherwise = parent's
    Metadata     *meta;          // cold: name, reflection, trait list, link info
    void         *vtbl[];        // inline trailing array
} Class;
```

Intra-metadata references (`parent`, `interfaces`, `meta`, …) may be stored as u32 offsets from the long-lived arena base instead of 64-bit pointers: 4 bytes each, one add per dereference.

---

## retain / release

Phase 1 (one thread per request, no atomics needed, like Zend):

```c
static inline void ll_retain(RcHeader *h) {
    // Not lifetime-counted — unless COW, which counts in every category
    // (values.md), so the test is category != 0 && !COW.
    if ((h->flags & LL_MEMCAT_MASK) && !(h->flags & LL_COW)) return;
    h->refcount++;
}

// Returns "this entity just died", it does not free: the caller runs
// the three-phase teardown (obj->class->dispose). Only GcHeap entities die
// this way; an arena object's count reaching zero means nothing.
static inline bool ll_release(RcHeader *h) {
    if ((h->flags & LL_MEMCAT_MASK) && !(h->flags & LL_COW)) return false;
    if ((h->flags & LL_MEMCAT_MASK) == LL_IMMORTAL) return false;
    if (--h->refcount == 0)
        return (h->flags & LL_MEMCAT_MASK) == LL_GCHEAP;
    // Non-zero decrement of a heap *object* → possible cycle root.
    // Buffering only arms a collection; it never runs one inline.
    if (is_gcheap_object(h)) ll_buffer_cycle_root(h);
    return false;
}
```

The `flags & 0b11` test (plus the COW exception) implements the
immortal-object and arena-scoping optimizations from [arc-optimizations.md](memory/arc-optimizations.md). Biased/atomic counting arrives with multi-threading (phase 2+).

---

## Property Access

The offset and the slot kind both come from `prop_layout` at compile
time, so the load is emitted for the type, with no tag anywhere:

```llvm
; $this->id   where id: int, offset 48
%p  = getelementptr inbounds i8, ptr %obj, i64 48
%v  = load i64, ptr %p, align 8

; $this->next   where next: Node, offset 16 — a bare pointer.
; NULL here means uninitialized (a non-nullable type has no valid null),
; so an unproven read tests for it and throws before use:
%p2 = getelementptr inbounds i8, ptr %obj, i64 16
%o  = load ptr, ptr %p2, align 8
%u  = icmp eq ptr %o, null
br i1 %u, label %throw_uninit, label %use          ; elided if init is proven
use:
; on this path %o is non-null, so a reload/CSE may carry !nonnull; the
; annotation is valid only here, never on the load above unconditionally

; $this->meta   where meta is untyped, offset 32 — the only boxed form
%p3 = getelementptr inbounds i8, ptr %obj, i64 32
%b  = load %Value, ptr %p3, align 8

; $this->ok   where the compiler packed this class's bools: bit 3 of
;             the byte block at offset 65 (the plain form is a byte load)
%p4 = getelementptr inbounds i8, ptr %obj, i64 65
%w  = load i8, ptr %p4
%s  = lshr i8 %w, 3
%v2 = trunc i8 %s to i1
```

One GEP + load, essentially a C struct field access. The only additions
are an uninitialized check where the property can be uninitialized and
the compiler has not proven otherwise — a null compare for a
non-nullable pointer, a bitmap-bit test for a `?T`/scalar, a Box `undef`
test folded into the tag decode — and the shift for a packed `bool`.
None of these is emitted for a property with a default or a proven
assignment. Hashtables are involved only for dynamic properties and
`__get`/`__set`.

Stores to a slot holding a counted reference go through the store
barrier, which is chosen statically by slot kind: an 8-byte pointer
slot and a 16-byte Box slot are two different entries.

A hooked property (PHP 8.4) compiles to a call through the hook's vtable
slot instead; `virtual` properties have no backing slot at all. The
plain/hooked distinction is known at class link time, so the access form is
chosen at compile time, no runtime check.

---

## Method Calls

### Virtual call — class known, slot 3

```llvm
%cls.p = getelementptr inbounds i8, ptr %obj, i64 8
%cls   = load ptr, ptr %cls.p, !invariant.load !0
%fn.p  = getelementptr inbounds i8, ptr %cls, i64 VTBL_OFF + 3*8
%fn    = load ptr, ptr %fn.p
%r     = call %Value %fn(ptr %obj, ...)
```

Two dependent loads: the cost of a C++ virtual call. `!invariant.load` on
the class pointer is sound because an object's class never changes after
construction; LLVM may hoist and CSE the load freely. The one exception is
a **ghost-capable** class (per-class opt-in flag, [classes.md](classes.md)
"Lazy Objects: Ghost and Proxy"), whose class pointer is rewritten on first
touch: instances of such classes emit the class-pointer load **without**
`!invariant.load`. The overwhelming majority of classes, never used as
ghosts, keep it.

### `static::foo()` — late static binding, slot 1

The called class arrives as a hidden argument through the call chain:

```llvm
%svt  = load ptr, ptr getelementptr(i8, ptr %cls, i64 STATIC_VTBL_OFF)
%fn   = load ptr, ptr getelementptr(i8, ptr %svt, i64 1*8)
%r    = call %Value %fn(ptr %cls, ...)
```

Branch-free: a class with no static overrides simply has `static_vtbl`
pointing at its parent's table. `self::`, `parent::`, and explicit
`Foo::bar()` never reach this path: they are direct calls.

### Interface call — interface known, slot 2

```llvm
%cls    = load ptr, ptr getelementptr(i8, ptr %obj, i64 8)
%itable = call ptr @ll_find_itable(ptr %cls, i32 IFACE_ID)  ; sorted-array search
%fn     = load ptr, ptr getelementptr(i8, ptr %itable, i64 2*8)
%r      = call %Value %fn(ptr %obj, ...)
```

In hot code the `ll_find_itable` step is eliminated by the same inline
cache used for unknown receivers.

### Unknown receiver — monomorphic inline cache

Per call site, two private globals:

```llvm
@site42.cls = private global ptr null
@site42.fn  = private global ptr null

  %cls    = load ptr, ptr getelementptr(i8, ptr %obj, i64 8)
  %cached = load ptr, ptr @site42.cls
  %hit    = icmp eq ptr %cls, %cached
  br i1 %hit, label %fast, label %slow, !prof !likely

fast:
  %fn = load ptr, ptr @site42.fn
  %r1 = call %Value %fn(ptr %obj, ...)          ; one compare + direct call
  br label %join

slow:                                           ; interned-name lookup in
  %r2 = call %Value @ll_call_by_name(ptr %obj,  ; cls->methods, then __call;
             ptr @iname.foo, ...)               ; updates @site42.*
  br label %join
```

The cache never needs invalidation: classes are immutable after link and
the GC is non-moving, so a cached class pointer stays valid forever. A miss
means genuine polymorphism at that site.

---

## Allocation

Construction is compiler-generated code, one routine per class
(classes.md, "Construction and teardown"). There is no generic
allocate-and-walk-the-map runtime call; the map is read only by the GC.

**Static `new User()`**, category known, the factory inlined into the
call site — the object body zeroed in one store, then the typed slots
that start non-zero stamped straight-line:

```llvm
%cur  = load ptr, ptr @arena.bump
%next = getelementptr i8, ptr %cur, i64 SIZEOF_USER
%ok   = icmp ule ptr %next, %limit
br i1 %ok, label %commit, label %refill          ; refill = runtime call, rare

commit:
  store ptr %next, ptr @arena.bump
  store i64 RC1_PLUS_FLAGS, ptr %cur             ; header in one 8-byte store
  store ptr @class.User,
        ptr getelementptr(i8, ptr %cur, i64 8)
  ; Body zeroed as one range: an all-zero Box is null (tag 0), a null
  ; pointer is PHP null, a zero scalar is 0, and a clear init-bitmap bit
  ; is uninitialized — every uninitialized slot's correct start, and the
  ; bitmap's, in one store. No sentinel or tag to stamp.
  call void @llvm.memset.p0.i64(ptr %body, i8 0, i64 BODY_LEN, i1 false)
  ; Then the explicit stores: defaults, and the undef flag on a mixed
  ; slot with no default (an all-zero Box is null, not undefined).
  store i64 1, ptr getelementptr(i8, ptr %cur, i64 U_COUNT)   ; public int $count = 1
  store i8 UNDEF, ptr getelementptr(i8, ptr %cur, i64 U_META_FLAGS) ; public $meta;
  call void @User__construct(ptr %cur, ...)      ; constructor known → direct
  ; Only for a class with a destructor, and only after __construct
  ; returns: this is what makes the object owe a __destruct at all
  ; (runtime/object-lifecycle.md, "Two constructors").
  %ok2 = call i1 @ll_object_constructed(ptr %ctx, ptr %cur)
  br i1 %ok2, label %done, label %oom            ; false → raise memory-exhausted
```

**Dynamic `new $class`**, class in a register, one indirect call into
the class's own factory — specialized code, not a map walk:

```llvm
%f = load ptr, ptr getelementptr(i8, ptr %class, i64 FACTORY_OFF)
%o = call ptr %f(ptr %ctx, i32 %category)        ; allocate + initialize
; %o is initialized; the caller emits __construct separately
```

The refill path inside the factory is a runtime call that **can report
null** — allocation failure is an ordinary exception raised from the
generated frame, not something the runtime throws
(runtime/exceptions.md).

Roughly five instructions per object on the inlined fast path: an order
of magnitude cheaper than `malloc`.

---

## Optimization Summary

1. **ARC pairing (LLVM pass)**: `ll_retain` is annotated
   `memory(argmem: readwrite) nounwind`, allowing reordering; paired
   retain/release within a function cancel out (as in Swift ARCOpt).
   Temporaries end up with zero RC operations.
2. **Devirtualization**: `final` class or method → direct `call @User_foo`,
   then ordinary inlining erases the call entirely.
3. **`!invariant.load` on the class pointer**: hoistable out of loops,
   CSE-able across accesses.
4. **`instanceof` in O(1)**: Cohen display; each class stores an array of
   its ancestors indexed by depth; the check is one load + compare instead
   of walking the parent chain. Interface checks: sorted-array search over
   `interfaces` + inline cache.
5. **Off-by-one refcount** (Swift trick): logical count 1 encodes as zero
   bits, so header initialization is a single constant store.
6. **Interned names on the slow path**: name compare = pointer compare,
   hash precomputed (see classes.md).

The `%Value` type in the call signatures above is the 16-byte
scalar/reference representation, used where the type is not known
statically; its design (tagging, strings, arrays, COW) is a separate
RFC. It is not the representation of an object's properties — a
declared property is stored as its machine type (classes.md, "Slot
kinds").
