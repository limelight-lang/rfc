# Weak References

## Scope

How `WeakReference` and `WeakMap` are represented and how the runtime
delivers death notification: the weak cell, the per-thread weak table
with its subscriber rows, and the three places an object's death must
clear its weak state. The cycle-collector obligation this machinery
discharges is stated in [gc/rc-walk.md](gc/rc-walk.md), "What this
design does not solve"; the arena interaction in
[../runtime/object-lifecycle.md](../runtime/object-lifecycle.md),
"Arena reset and destructors".

---

## The PHP contract

Verified against the manual and `zend_weakrefs.c` (2026-07-27):

- `WeakReference::create($obj)` returns "a new WeakReference, **or the
  existing instance** if there was already a WeakReference to the same
  object" — the instance is canonical per target while it lives.
- `WeakReference` is `final`, cannot be instantiated, serialized, or
  cloned (`clone_obj = NULL` in Zend). So **at most one `WeakReference`
  instance exists per target at any moment** — the property the layout
  below leans on.
- `get()` returns the object or `null`; during `__destruct` the object
  is still alive and resurrection is possible, so invalidation happens
  only after teardown commits.
- `WeakMap`: keys are weakly held, values are strong, the map is
  countable and iterable, and an entry disappears when its key dies.
  Note `WeakMap` *is* cloneable — Zend's clone copies the table and
  re-registers every key — so the map side must not assume one map per
  registration when it is built.

## The weak cell is the canonical `WeakReference` itself

**Decision**: there is no separate side entry. The canonical
`WeakReference` instance — entity kind `5`
([classes.md](classes.md)), a class-less singleton kind — is the
shared cell all holders read:

```
WeakRef entity, 16 bytes on the heap
+0  RcHeader   8 B   kind 5, ordinary refcount (held by every $w copy,
                     and later by every WeakMap that adopted it)
+8  target     8 B   the referent; null once the referent died
```

`get()` is a load of `target`, a null test, and a `retain` on the
non-null path (the caller receives a strong reference). Death
notification is **one store**: null `target`, and every copy of every
`$w` observes it on its next `get()` — the holders are never
enumerated, they all point at the same 16 bytes.

**Rejected — a separate Swift-style side entry** (target + canonical
pointer + own refcount, a third allocation between holders and
target). The canonical-instance guarantee already makes the
`WeakReference` unique per target, so the entity can *be* the cell;
the separate entry duplicates `RcHeader`'s counting by hand and costs
an allocation, and bought nothing but the layout freedom PHP's
contract makes unnecessary.

## The weak table: address → subscriber row

The dying object must find its cell to null it, and the object does
not store the cell's address — a field would tax every object 8 bytes
for a feature a small minority uses. Instead each thread keeps a
**weak table**:

```
WeakTable : HashMap<entity address, WeakRow>       // per thread
WeakRow   : SmallVec<Subscriber>                   // inline 1, spill rare
Subscriber:
    CanonicalRef(*WeakRef)   // action: null its target field
    Map(*WeakMap)            // action: remove the row keyed by the dead
                             // object from that map (future, with maps)
```

A row lists exactly the parties that need the death of *that* object
delivered immediately: the canonical cell (zero or one), and every map
currently holding the object as a key. Header flag bit 7
(`HAS_WEAK_REFERENCES`, [classes.md](classes.md) "Flags layout") is
the cheap gate: it is set iff the row exists iff the row is non-empty.
Teardown paths already load the flags word, so objects with no weak
state pay one masked test and nothing else.

**Per thread, no locks.** Entities are thread-confined, `create()`
runs where the target lives, and every notification site below runs on
the owning thread — including the rc-walk drain, which executes in the
mutator's checkpoint, never on the collector thread
([gc/rc-walk.md](gc/rc-walk.md)). Zend's single table in
`EG(weakrefs)` is the same structure made global because the engine is
single-threaded; globalizing it here would buy a mutex on every
create and death. Consequence: the thread-exit teardown that already
walks static blocks ([classes.md](classes.md), "Teardown at thread
exit") also disposes the thread's weak table.

### Operations

- **`create(obj)`** — flag clear: allocate the entity (`refcount` 1,
  `target = obj`), insert a row `[CanonicalRef]`, set bit 7; an
  arena-resident target is additionally pushed on the arena's weak
  list (below). Flag set: return the row's `CanonicalRef` retained.
  Edge: the row exists but holds no `CanonicalRef` (maps outlived a
  dead canonical instance) — allocate a fresh entity and add it.
- **`get(weakref)`** — read `target`; null → null; else retain and
  return.
- **`WeakRef` teardown** (its own refcount reached zero, kind-5 arm of
  the entity death switch): if `target` is non-null, remove own entry
  from the target's row; an emptied row is deleted and bit 7 cleared,
  so the target dies down the cheap path. If `target` is already null
  the row died first; nothing to do.
- **Map subscribe / unsubscribe** (future): adding an object as a key
  appends a `Map` entry to its row (creating row + flag as needed);
  removing the key, or the map's own death, removes it, symmetrically
  with `WeakRef` teardown.

## Death notification

`notify(obj)`, always on the owning thread:

1. Look the row up by the dying object's address.
2. Walk the subscribers — `CanonicalRef`: null the entity's `target`
   (the entity itself lives on, owned by its holders); `Map`: delete
   the map's row for this key. The displaced value's release is
   immediate on the ordinary path, **deferred on the drain path**
   (below).
3. Delete the row, clear bit 7.

`notify` runs no user code — that is what makes it safe to call from
all three sites:

- **Ordinary death** — teardown phase 2, *after* `__destruct`
  ([../runtime/object-lifecycle.md](../runtime/object-lifecycle.md)):
  during the destructor the object is alive, `get()` must still
  produce it, and a resurrected object keeps its weak state untouched.
- **Cycle death** — the drain nulls every confirmed member's weak
  state **before any user code runs**, the binding obligation of
  [gc/rc-walk.md](gc/rc-walk.md) (2026-07-26; CPython's PEP 442 is
  the same move). A `Map` subscriber's value drop is user code one
  release away, so on this path the drop is pushed onto the drain's
  existing deferred-drop queue (the one already deferring severed
  external children) instead of running inline. The same ordering
  applies to `rc-trace`'s cycle teardown when it gains destructor
  support.
- **Arena reset** — arena objects die with the pages, skipping
  teardown, so reset walks the arena's weak list (populated by
  `create()` above) calling `notify` for each entry before the pages
  are reused; specified in
  [../runtime/object-lifecycle.md](../runtime/object-lifecycle.md),
  "Arena reset and destructors". A weak edge is not ownership and
  never promotes its target.

## `WeakMap` cleanup is eager, not lazy

**Decision**: when a key dies, its map entries are removed at
notification time — the Zend/CPython shape (Zend: the tagged
per-object list behind `zend_weakrefs_notify`; CPython: weakref
callbacks, with removals deferred only while the dict is mid-iteration).

**Rejected — lazy expunge** (Java's `WeakHashMap`: dead entries
removed only when the map is next touched). Java's own javadoc
documents the consequence: a stale entry strongly holds its value
until someone happens to touch the map, `size()` over-reports, and
the idiomatic fix is wrapping values in weak references by hand. For
Limelight it is worse twice over: the retained value graph has
deterministic-destruction semantics (`__destruct` held hostage by
"does anyone read this map again"), and PHP's `WeakMap` is countable
and iterable, so cleanup timing is observable — the API concealment
that lets JavaScript get away with GC-timed removal (its `WeakMap`
exposes no size and no iteration) is not available.

**Known limitation — ephemerons.** A value that references its own
key (directly or through another entry) keeps the key's refcount
positive forever: no death, no notification, entry never removed.
This is not an eager-vs-lazy question — a cycle collector must treat
the map's key-to-value edges as conditional on key liveness, which is
exactly the special `WeakMap` support Zend's GC gained in PHP 8.3
after shipping the leak for three years. Deferred: behaviour matches
PHP 8.0–8.2, logged in [../BACKLOG.md](../BACKLOG.md).

## Runtime-internal only

The subscriber row is a death-notification mechanism, and it stays
internal to the runtime — `WeakReference`, `WeakMap`, and future
runtime facilities (the object registry of the observability design)
may subscribe; **no user-facing death callback is exposed**. The row
is walked inside teardown and inside the drain, the two places whose
safety argument is "no user code runs here"; a user callback in that
position could resurrect the dying object mid-notification, throw
through teardown, or observe a half-severed cycle. Python permits
weakref callbacks and has to swallow their exceptions; declining the
feature costs nothing now and can be revisited deliberately, not by
accident.

## Build scope

Step 4 of the rc-walk build plan ([gc/rc-walk.md](gc/rc-walk.md))
covers: the kind-5 entity, the weak table and rows, `notify` wired
into ordinary teardown and the drain, the arena weak list, and the
`create`/`get` ABI surface — the machinery is untestable without its
entry points. The `Map` subscriber variant lands with `WeakMap`
itself, when the runtime grows maps; nothing in the row format needs
revisiting for it.
