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

The compiler emits allocation inline (bump pointer, see
[lowering.md](../model/lowering.md)) whenever the class and memory
category are statically known; `ll_object_new` is the out-of-line runtime
path used otherwise. Both do the same steps:

```rust
#[repr(C)]
pub struct RcHeader {
    refcount: u32,      // atomic in multi-threaded phases
    flags: u32,
}

#[repr(C)]
pub struct Object {
    rc: RcHeader,           // +0
    class: *const Class,    // +8
    // property slots follow at +16, per class prop_layout
}

#[no_mangle]
pub extern "C" fn ll_object_new(ctx: *mut LLContext, class: &Class, cat: MemCat) -> *mut Object {
    let mem = match cat {
        MemCat::RequestArena => request_arena().bump(class.object_size),
        MemCat::GcHeap       => gc_alloc(class.object_size),
        MemCat::LongLived    => long_lived_arena().alloc(class.object_size),
    };
    let obj = mem as *mut Object;
    unsafe {
        // header in one store: refcount = 1 (the off-by-one encoding is
        // deferred), flags = memory category + ENTITY_OBJECT. NOT
        // HAS_DESTRUCTOR, and not the class's flag word: that flag means
        // "this object owes a __destruct", which is not true yet.
        (*obj).rc = RcHeader::new(cat, ENTITY_OBJECT);
        (*obj).class = class;
        class.init_props(obj);          // defaults / UNINIT discriminants
    }
    obj
    // the __construct call is emitted by the compiler at the call
    // site: the class is known there, so it is a direct call
    //
    // Tracking the destructor is NOT done here. An arena object with a
    // `__destruct` is registered only once `__construct` has returned
    // successfully — see "Two constructors" above: an object whose
    // constructor threw must never have its `__destruct` run, so a
    // record created by the factory would be a record demanding exactly
    // the thing that is forbidden.
}

// Emitted after `__construct` returns, and only for a class that has a
// destructor. Sets HAS_DESTRUCTOR on the header and, for an arena
// object, writes the destructor-log record. False means the record could
// not be written: the creation fails with memory-exhausted, which is the
// same observable outcome as a constructor that threw.
pub extern "C" fn ll_object_constructed(ctx: *mut LLContext, obj: *mut Object) -> bool;
```

---

## Teardown: Three Phases

Triggered when the refcount reaches zero (or the cycle collector proves
the object garbage).

### Phase 1 — Pre-destructor: `__destruct`

The only phase visible to PHP code.

- Runs **exactly once** per object: guarded by a `DESTRUCTED` bit in the
  flags, set before the call.
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
pub extern "C" fn ll_object_die(obj: *mut Object) {
    let class = unsafe { &*(*obj).class };

    // Phase 1: pre-destructor, exactly once, resurrection-aware.
    // The test is the object's own HAS_DESTRUCTOR flag, not the class:
    // a class may declare __destruct while this object never completed
    // construction, and such an object must not run it.
    if flags_test(obj, HAS_DESTRUCTOR) && !flags_test_and_set(obj, DESTRUCTED) {
        refcount(obj) += 1;               // guard: a transient $this ref
        call_vtbl_slot(obj, class.destruct_slot());
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

    // Phase 2: drop, release children and internal structures
    for slot in class.prop_layout.refcounted_slots() {
        // A holder going away is a `lose` for every request-arena
        // escapee it referenced — the same event as the store barrier
        // overwriting the slot. Heap children fall through to the
        // ordinary release below. (The cycle collector owes this too,
        // when it frees a holder without coming through here.)
        if is_request_arena(prop_ptr(obj, slot)) {
            escape_lose(prop_ptr(obj, slot));
        }
        ll_release(prop_ptr(obj, slot));
    }
    if let Some(dyn_props) = dynamic_props(obj) { free_hashtable(dyn_props); }
    if flags(obj) & WEAK != 0 { weak_table_clear(obj); }

    // Phase 3: memory, by category
    match mem_category(obj) {
        MemCat::GcHeap => gc_free(obj),   // respects deferred-free bit
        _ => {}                           // arenas: reset reclaims
    }
}
```

### Arena reset and destructors

At end of request the arena runs only phase 1 for tracked objects (the
`track_destructor` list), then resets the bump pointer; phases 2–3 are
unnecessary, children living in the same arena die with it.

---

## Cross-arena references

Resolved by the **category barrier** on reference stores; see
Cross-Arena References in [arenas.md](../model/memory/arenas.md): deepCopy
or arena pinning for escaping references, and a release-at-reset list for
heap entities referenced from arena objects.
