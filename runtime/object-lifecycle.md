# Object Lifecycle

## Scope

The runtime implementation of object creation and destruction: the `new`
path, and the three-phase teardown of pre-destructor (`__destruct`), real
destructor (drop), memory release. Reference implementation sketches in
Rust per [implementation-language.md](implementation-language.md); object
layout per [classes.md](../model/classes.md).

---

## Two constructors, and why the split matters

`new` is not one operation. It is two, with different natures, and
almost everything below follows from keeping them apart.

**1. The factory constructor.** Runtime code, and **static by nature**:
it runs with no `$this`, because there is no object yet. It is called
**without allocated memory at all — it allocates the memory itself**,
then stamps the header, the class pointer and the property defaults.
Its input is a class, its output is an object that exists but has not
been touched by user code.

**2. The user constructor** (`__construct`). An instance method, and
therefore not static: it runs on memory the factory has already
produced, with `$this` bound, and it is ordinary user code that may do
anything, including throw.

The split is what makes the interesting optimizations legal. Because
the factory *owns* the allocation rather than receiving it, it is free
to decide where the object comes from and whether it needs to come from
anywhere at all: the arena, the heap, the immortal region, inline in a
caller's frame, a shared instance for a value-like class, or nothing at
all when the object provably does not escape. None of that is available
to a design that allocates first and then calls a constructor on the
result — there the address is already fixed before anyone knows what
the object is for. Being static also means the factory is dispatched on
the class, not through an instance, so it is a direct call the compiler
can see through and inline.

### What each of the two guarantees on failure

**A failed factory is the cheapest failure in the system.** Nothing has
run, nothing is registered, nothing is observable — there is no object,
so there is nothing to destruct and nothing to unwind. This is why
allocation refusal is reported here rather than anywhere else: the
factory is the one place where "it did not happen" is the whole truth.

**A failed user constructor is a different event.** The object exists;
user code has run and may have left effects elsewhere. The rule:

> If `__construct` throws, the **user destructor is not called** —
> `__destruct` never runs for an object whose construction did not
> complete. Our own teardown *does* run: children are released and the
> memory is reclaimed.

So the guarantee "`__destruct` will run" does not begin when the object
exists. It begins **when the user constructor returns successfully**,
and that is the boundary every mechanism keyed on destructors must use.

### Consequence: when a destructor is registered

An arena object with a `__destruct` must be recorded in the arena's
destructor log. That registration belongs **after** the user
constructor returns, not in the factory: registering earlier leaves a
record demanding a `__destruct` that must never run, for exactly the
objects whose constructor threw.

Registration itself can fail (the log may need memory). It needs no new
policy: raising the memory-exhausted exception at the creation site
makes the outcome **identical to a constructor that threw** — our
teardown runs, the user destructor does not. A failure with nowhere to
go is thereby folded into a path that already exists and is already
specified. See `exceptions.md`, "The enumeration, and the three ways
off the list".

---

## Creation: `new`

The factory constructor is **compiler-generated per class**, not a
generic runtime routine ([classes.md](../model/classes.md),
"Construction and Teardown"). The compiler emits it inline (bump
pointer, see [lowering.md](../model/lowering.md)) when the class and
category are statically known; the dynamic path (`new $class`) makes one
indirect call through the descriptor's `factory` pointer. There is no
generic `ll_object_new` that reads `object_size` and walks a layout map
to initialize — construction is straight-line code specialized to the
class.

```rust
#[repr(C)]
pub struct RcHeader {
    refcount: u32,      // atomic in multi-threaded phases
    flags: u32,
}

// LLObject: 16-byte header, then property slots at their laid-out
// offsets ([classes.md], "Slot kinds"). Each slot is the machine
// representation of its declared type — a raw i64, a bare pointer, a
// 16-byte Box only for mixed — never one uniform Box per property.
#[repr(C)]
pub struct Object {
    rc: RcHeader,           // +0
    class: *const Class,    // +8
    // property slots follow at +16
}

// The descriptor carries a pointer to this class's factory and to its
// dispose; both are emitted by the compiler against the class's layout.
//   Class { …, factory: *const (), dispose: *const (), traced_runs, … }

// What `Foo`'s generated factory does — the shape, not a generic body:
//   fn Foo__factory(ctx, category) -> *mut Object {
//     let obj = allocate(ctx, category, FOO_OBJECT_SIZE); // per category
//     obj.rc = RcHeader::new(category, ENTITY_KIND_OBJECT); // kind 0; NOT DESTRUCTOR_PENDING
//     obj.class = &FOO_CLASS;
//     // straight-line init: zero-fill the body, then the explicit stores
//     // (defaults, and a Box `undef` flag on a mixed slot without a
//     // default). No init_props, no map walk, no UNINIT discriminant.
//     obj
//   }
// The __construct call is emitted by the compiler at the call site (the
// class is known there, so it is a direct call). Registering the
// destructor is NOT done in the factory: an arena object with a
// `__destruct` is recorded only once `__construct` returns successfully
// ("Two constructors" above), so a record created by the factory would
// demand exactly the __destruct that must never run.

// Emitted after `__construct` returns, and only for a class that has a
// destructor. Sets DESTRUCTOR_PENDING on the header and, for an arena
// object, writes the destructor-log record. False means the record could
// not be written: the creation fails with memory-exhausted, the same
// observable outcome as a constructor that threw.
pub extern "C" fn ll_object_constructed(ctx: *mut LLContext, obj: *mut Object) -> bool;
```

---

## Teardown: Three Phases

Teardown is the class's compiler-generated **`dispose`**
([classes.md](../model/classes.md), "dispose — the internal
destructor"), the counterpart of the factory. The collector or the
release path holds a bare object and calls `obj->class->dispose(obj)` —
one indirect call into straight-line code. `dispose` does **not** read
`prop_layout` at runtime; the releases below are emitted per class,
slot by slot. Only the GC reads layout as data, through `traced_runs`.
The three phases are the shape every class's `dispose` has.

Triggered when the refcount reaches zero (or the cycle collector proves
the object garbage).

### Phase 1 — Pre-destructor: `__destruct`

The only phase visible to PHP code.

- Runs **exactly once** per object: guarded by a `DESTRUCTOR_RAN` bit in
  the flags, set before the call.
- Called through the vtable slot (it is an ordinary virtual method).
- **Resurrection check**: `__destruct` may store `$this` somewhere,
  raising the refcount. The call is made with **one guard reference held**:
  a *transient* `$this` reference taken and dropped inside the destructor
  (`$x = $this;` then `$x` leaves scope) must not drive the count to zero
  and re-enter teardown, which would free the object here and again below
  (a double free). After the call the guard is dropped; if `refcount > 0`,
  teardown is aborted and the object lives on. When its count reaches zero
  again, phase 1 is *skipped* (the bit is set) and teardown proceeds to
  phase 2.

### Phase 2 — Real destructor: drop

Runtime-level teardown, invisible to PHP:

- release every refcounted property slot (cascading releases),
- free the dynamic-properties hashtable if present,
- clear the weak-reference side table entry if the WEAK bit is set.

### Phase 3 — Memory release

Decided entirely by the memory category bits:

| Category | Action |
|----------|--------|
| GC heap | free, honoring the deferred-free GC activity bit ([heap-design.md](../model/gc/heap-design.md)) |
| Request arena | nothing; arena reset reclaims the pages |
| Long-lived | per its lifecycle policy |

```rust
// The shape of every class's generated `dispose`. `Foo__dispose` inlines
// this for Foo's specific counted slots — there is no `refcounted_slots()`
// walk at runtime; the compiler knew the slots and emitted the releases.
fn Foo__dispose(obj: *mut Object) {
    // Phase 1: pre-destructor, exactly once, resurrection-aware.
    // The test is the object's own DESTRUCTOR_PENDING flag, not the class:
    // a class may declare __destruct while this object never completed
    // construction, and such an object must not run it.
    if flags_test(obj, DESTRUCTOR_PENDING) && !flags_test_and_set(obj, DESTRUCTOR_RAN) {
        refcount(obj) += 1;               // guard: a transient $this ref
        call_user_destruct(obj);          // Foo's __destruct, known here
        refcount(obj) -= 1;               // drop the guard, no re-entry
        if refcount(obj) > 0 {
            return;                       // resurrected: abort teardown
        }
    }

    // Leaving the cycle collector's candidate buffer comes BEFORE any
    // child release, and the order is load-bearing: a child release can
    // fill the candidate buffer and run a collection, which would trace
    // this still-buffered object — refcount already zero — as a root and
    // free it, and then phase 3 would free it again.
    forget_candidate(obj);

    // Phase 2: drop, emitted per counted slot (Foo has, say, two).
    // A holder going away is a `lose` for every request-arena escapee it
    // referenced — the same event as the store barrier's `drop` on an
    // overwrite. Heap children fall through to the ordinary release.
    // (The cycle collector owes this same bookkeeping when it frees a
    // holder without coming through here.)
    drop_slot(obj, FOO_NEXT_OFFSET);      // e.g. `Foo $next`
    drop_slot(obj, FOO_DATA_OFFSET);      // e.g. `array $data`
    if FOO_HAS_DYNAMIC_PROPS { free_hashtable(dynamic_props(obj)); }
    if flags(obj) & WEAK != 0 { weak_table_clear(obj); }

    // Phase 3: memory, by category
    match mem_category(obj) {
        MemCat::GcHeap => gc_free(obj),   // respects deferred-free bit
        _ => {}                           // arenas: reset reclaims
    }
}
// drop_slot is the `drop` micro-op of the store barrier
// (gc/strategies.md): escape_lose if the child is a request-arena
// escapee, then release, then teardown if that was the last reference.
```

### Arena reset and destructors

At end of request the arena runs only phase 1 for tracked objects (the
`track_destructor` list), then resets the bump pointer; phases 2–3 are
unnecessary, children living in the same arena die with it.

**Weak references need one more step.** A `WeakReference` to a
request-arena object does not bump the escape hold-count (a weak edge is
not ownership, [arenas.md](../model/memory/arenas.md)), so the arena
object is not promoted and dies at reset — but skipping phase 2 skips
the `weak_table_clear` that phase 2 would run, leaving the weak
side-table pointing at reclaimed bump memory. `$weak->get()` would then
return a dangling pointer into reused arena pages. So the arena must
also clear the weak side-table for its objects at reset: an object that
takes a weak reference while it lives in an arena is registered on a
per-arena weak list (as `__destruct` objects are on `track_destructor`),
and reset walks that list clearing each side-table entry before the
pages are reused. An arena with no weak-referenced objects pays nothing.
(A runtime mechanism, noted in BACKLOG; the rule is stated here so weak
references and arenas are specified together, not each in isolation.)

---

## Cross-arena references

Resolved by the **category barrier** on reference stores; see
Cross-Arena References in [arenas.md](../model/memory/arenas.md): deepCopy
or arena pinning for escaping references, and a release-at-reset list for
heap entities referenced from arena objects.
