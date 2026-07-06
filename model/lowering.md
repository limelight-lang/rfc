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
                                 //       [7] weak, [8] has-destructor
} RcHeader;

#define LL_MEMCAT_MASK 0x3u      // 00=GC heap, 01=request arena,
                                 // 10=long-lived, 11=immortal

typedef struct Object {
    RcHeader      rc;            // +0
    struct Class *cls;           // +8
    Value         props[];       // +16: fixed 16-byte slots
    // classes allowing dynamic properties have one extra hidden
    // slot: a lazily-allocated hashtable pointer
} Object;

typedef struct IfaceEntry {
    uint32_t iface_id;
    void   **itable;             // array of code pointers, slots fixed
} IfaceEntry;                    // by interface declaration order

typedef struct Class {
    uint32_t      flags;         // final/abstract/interface + magic-method bitmask
    uint32_t      object_size;
    struct Class *parent;
    PropLayout   *prop_layout;   // name → (offset, type, hook flags)
    IfaceEntry   *interfaces;    // sorted by iface_id
    uint32_t      iface_count;
    MethodTable  *methods;       // interned name → method (slow path)
    Value        *statics;       // static properties, class constants
    void        **static_vtbl;   // own table only if this class overrides an
                                 // inherited static method; otherwise = parent's
    Metadata     *meta;          // cold: name, reflection, trait list
    void         *vtbl[];        // inline trailing array
} Class;
```

Intra-metadata references (`parent`, `interfaces`, `meta`, …) may be stored as u32 offsets from the long-lived arena base instead of 64-bit pointers: 4 bytes each, one add per dereference.

---

## retain / release

Phase 1 (one thread per request, no atomics needed, like Zend):

```c
static inline void ll_retain(RcHeader *h) {
    if (h->flags & LL_MEMCAT_MASK) return;   // arena/immortal: not counted
    h->refcount++;
}

static inline void ll_release(RcHeader *h) {
    if (h->flags & LL_MEMCAT_MASK) return;
    if (--h->refcount == 0)
        ll_free(h);
    else
        ll_buffer_cycle_root(h);   // non-zero decrement → possible cycle
}                                  //   root (Bacon-Rajan, see gc-research.md)
```

The single `flags & 0b11` branch implements the immortal-object and arena-scoping optimizations from [arc-optimizations.md](memory/arc-optimizations.md). Biased/atomic counting arrives with multi-threading (phase 2+).

---

## Property Access

`$this->x`, type known, slot 2 → byte offset 16 + 2·16 = 48:

```llvm
%p = getelementptr inbounds i8, ptr %obj, i64 48
%v = load %Value, ptr %p, align 8
```

One GEP + load, identical to a C struct field access. Every declared,
non-hooked property compiles to this, always. Hashtables are involved only
for dynamic properties and `__get`/`__set`.

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
construction; LLVM may hoist and CSE the load freely.

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

`new User()` in the request arena, bump pointer inline:

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
  call void @User__construct(ptr %cur, ...)      ; constructor known → direct
```

Roughly five instructions per object: an order of magnitude cheaper than
`malloc`.

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

The `%Value` type used throughout is the 16-byte scalar/reference
representation; its design (tagging, strings, arrays, COW) is a separate
RFC.
