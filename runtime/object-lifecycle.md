# Object Lifecycle

## Scope

The runtime implementation of object creation and destruction: the `new`
path, and the three-phase teardown of pre-destructor (`__destruct`), real
destructor (drop), memory release. Reference implementation sketches in
Rust per [implementation-language.md](implementation-language.md); object
layout per [classes.md](../model/classes.md).

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
pub extern "C" fn ll_object_new(class: &Class, cat: MemCat) -> *mut Object {
    let mem = match cat {
        MemCat::RequestArena => request_arena().bump(class.object_size),
        MemCat::GcHeap       => gc_alloc(class.object_size),
        MemCat::LongLived    => long_lived_arena().alloc(class.object_size),
    };
    let obj = mem as *mut Object;
    unsafe {
        // header in one store: refcount = 1 (off-by-one: zero bits),
        // flags = memory category + HAS_DESTRUCTOR from class
        (*obj).rc = RcHeader::init(cat, class.flags);
        (*obj).class = class;
        class.init_props(obj);          // defaults / UNINIT discriminants
    }
    // arena objects with a PHP destructor must be tracked: the arena
    // reset must run their pre-destructors first (see arenas.md)
    if cat == MemCat::RequestArena && class.has_php_destructor() {
        request_arena().track_destructor(obj);
    }
    obj
    // the __construct call is emitted by the compiler at the call
    // site: the class is known there, so it is a direct call
}
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
  raising the refcount. After the call, if `refcount > 0`, teardown is
  aborted: the object lives on. When its count reaches zero again,
  phase 1 is *skipped* (the bit is set) and teardown proceeds to phase 2.

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

    // Phase 1: pre-destructor, exactly once, resurrection-aware
    if class.has_php_destructor() && !flags_test_and_set(obj, DESTRUCTED) {
        call_vtbl_slot(obj, class.destruct_slot());
        if refcount(obj) > 0 {
            return;                       // resurrected: abort teardown
        }
    }

    // Phase 2: drop, release children and internal structures
    for slot in class.prop_layout.refcounted_slots() {
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
