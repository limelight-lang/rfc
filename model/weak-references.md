# Weak References

## Scope

How `WeakReference` and `WeakMap` are represented and how the runtime
delivers death notification: the weak cell, the per-thread weak table
with its subscriber rows, and the three places an object's death must
clear its weak state. The cycle-collector obligation this machinery
discharges is stated in [gc/rc-cycle.md](gc/rc-cycle.md), "Cycle
teardown", step 3; the arena interaction in
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
  only after teardown commits. This holds on the ordinary death path;
  cyclic garbage is nulled *before* its destructors run — a deliberate
  divergence from Zend, argued under "Death notification".
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
+0  RcHeader   8 B   kind WeakRef, ordinary refcount, held by every $w copy
                     (maps subscribe through the weak table, below, and
                     never hold the entity)
+8  target     8 B   the referent; null once the referent died
```

**The entity is always GC-heap memory (category `00`)**, no matter
where `create()` was called or where the target lives. Its ordinary
refcount only counts in that category, and an arena-allocated cell
would die at reset under the `$w` copies that hold it — a
use-after-free of the cell itself. A weak reference to an
arena-resident object is therefore a heap cell pointing into the
arena, invalidated at reset (below).

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
currently holding the object as a key. Header flag bit 12
(`HAS_WEAK_REFERENCES`, [classes.md](classes.md) "Flags layout") is
the cheap gate: it is set iff the row exists iff the row is non-empty.
Teardown paths already load the flags word, so objects with no weak
state pay one masked test and nothing else.

**Per thread, no locks.** Entities are thread-confined, `create()`
runs where the target lives, and every notification site below runs on
the owning thread, which under `rc-cycle` is the design's own rule rather
than a property of one collector: the collector proposes and the owner
tears down, so every free and every destructor happens where the entity
lives ([gc/rc-cycle.md](gc/rc-cycle.md), "Requirements retained from earlier designs"). Zend's single table in
`EG(weakrefs)` is the same structure made global because the engine is
single-threaded; globalizing it here would buy a mutex on every
create and death. Consequence: the thread-exit teardown that already
walks static blocks ([classes.md](classes.md), "Teardown at thread
exit") also disposes the thread's weak table.

**The owner named above is a thread because this runtime has one mutator per
thread and no actor.** Once the scheduler mounts an actor, "the owning thread"
stops being constant across an entity's life: the actor may migrate between
messages while its rows stay in the table of the thread it left. The residence
that survives migration is open — "Open: where the weak table lives when an
actor migrates", below; [gc/domains.md](gc/domains.md), a proposal
scoped to threads with actors deferred, already writes the table as
per-domain and keyed by address, a domain being a thread or an actor mounted
on one — a shape rather than a ruling. Every per-thread claim in this section holds under the
thread invariant and is re-read against that node when the mechanism lands —
the thread-exit disposal above included, which under a per-actor table is no
longer thread exit's business.

### Operations

- **`create(obj)`** — flag clear: allocate the entity (`refcount` 1,
  `target = obj`), insert a row `[CanonicalRef]`, set bit 12. Flag set:
  return the row's `CanonicalRef` retained. Edge: the row exists but
  holds no `CanonicalRef` (a map registered the object, or the
  canonical instance died while map entries remained) — allocate a
  fresh entity and add it. **Row creation, whatever its origin, pushes
  an arena-resident target onto the arena's weak list** (below); the
  list may accumulate duplicates and stale entries (row died and was
  re-created before reset), which the reset walk tolerates by testing
  bit 12 before each notify.
- **`get(weakref)`** — read `target`; null → null; else retain and
  return.
- **`WeakRef` teardown** (its own refcount reached zero, kind-5 arm of
  the entity death switch): if `target` is non-null, remove own entry
  from the target's row; an emptied row is deleted and bit 12 cleared,
  so the target dies down the cheap path. If `target` is already null
  the row died first; nothing to do.
- **Map subscribe / unsubscribe** (future): adding an object as a key
  appends a `Map` entry to its row (creating row + flag — and the
  arena-list push — as needed); removing the key, or the map's own
  death, removes it, symmetrically with `WeakRef` teardown.

## Death notification

`notify(obj)`, always on the owning thread:

1. Look the row up by the dying object's address.
2. Walk the subscribers — `CanonicalRef`: null the entity's `target`
   (the entity itself lives on, owned by its holders); `Map`: delete
   the map's row for this key. The displaced value's release runs
   **per the calling site's rule below**, never inside the walk.
3. Delete the row, clear bit 12.

The walk itself severs rows and runs no user code; the one thing it
can *trigger* — a displaced map value's release, which may cascade
into a `__destruct` — is sequenced by each site. The sites, and one
invariant common to all of them: **once teardown of an object is
committed, its cell reads null before any user code can run.**

- **Ordinary death** — the **first act of teardown phase 2**, after
  `__destruct` but **before any child release**
  ([../runtime/object-lifecycle.md](../runtime/object-lifecycle.md)).
  After the destructor because during it the object is alive, `get()`
  must still produce it, and a resurrected object keeps its weak
  state untouched. Before the child drops because those cascade into
  user code: a child's destructor calling `get()` on the
  mid-teardown, refcount-zero object would receive a strong reference
  that either outlives the free or re-enters dispose — use-after-free
  either way. Zend nulls at the top of `zend_object_std_dtor` for the
  same reason. Displaced map values release inline right after the
  row is severed — this site is already a cascade of releases.
- **Cycle death** — the teardown notifies every confirmed member
  **after the exact test passes and before any user code runs**, the
  binding obligation of [gc/rc-cycle.md](gc/rc-cycle.md), "Cycle
  finalization and reclamation", step 3 (ruled 2026-07-26; the
  after-the-exact-test half
  is load-bearing because a trace proposes a validation batch that may be
  stale and only the owner's exact test confirms a member, so nulling
  before it could clear the cells of a live object. CPython's PEP 442
  is the same move). Displaced map values go onto the teardown's
  existing deferred-drop queue (the one already deferring severed
  external children), never inline. Two consequences are accepted,
  not accidental:
  - *Nulling is irrevocable.* Revalidation can find that a destructor
    resurrected a member — that object lives on with its
    cell nulled, its map entries gone, and the queued value drops
    still executing. CPython behaves identically (weakrefs to a cyclic
    isolate are cleared even if a finalizer resurrects it); Zend does
    not (it notifies only at actual free), so this is a **known,
    deliberate divergence from PHP** — the price of the teardown's
    safety argument, which holds only in the counted world.
  - *A destructor can re-create weak state* on a member confirmed as unreachable
    (`WeakReference::create($this)`, a map insert): bit 12 was cleared,
    so nothing stops it. The safety net is the free itself — the
    sever-and-free path frees members through the ordinary dispose,
    whose bit-12 test delivers a second, final notification. That
    free-time clear is **load-bearing, part of this design**, and its
    displaced map values also go onto the deferred queue — the
    sever-to-free window must stay free of user code
    ([gc/rc-cycle.md](gc/rc-cycle.md), "Cycle finalization and reclamation", step 6).
- **Arena reset** — arena objects die with the pages, skipping
  teardown, so reset walks the arena's weak list (populated by row
  creation, above): for each entry **whose category still reads
  request-arena** and which still carries bit 12, notify. The category
  test is load-bearing (found in build, 2026-07-27): an escapee
  promoted in place had its category rewritten and is *alive* — its
  cell must keep resolving, so the walk skips it and its row survives
  the reset.
  Ordering: **after the reset's destructor fixpoint, before the pages
  are reused** — a tracked destructor running `get()` on a fellow
  arena object must still see it alive
  ([../runtime/object-lifecycle.md](../runtime/object-lifecycle.md),
  "Arena reset and destructors"). Displaced map values are collected
  during the walk and released after it completes (an arena-resident
  value needs no release — it dies with the pages; a heap value's
  release then cascades normally). A weak edge is not ownership and
  never promotes its target.

Two smaller pins the sites imply:

- **Every entity kind honours bit 12 at death.** A `FFIBox` or a
  lazy object is a legal `WeakReference` target, so the
  weak-notify test lives in the generic entity death switch, not in
  the object arm alone.
- **Thread exit**: the weak table outlives the static-block teardown
  ([classes.md](classes.md), "Teardown at thread exit") and any teardown
  still running on the thread — both deliver notifications through it —
  and is disposed after them, ahead of the buffer arena and the
  thread's heaps; rows still present at that point (e.g. a
  weak reference to an immortal) are discarded without notification,
  the thread's cells dying with its heap. Cross-thread movement of a
  graph containing a kind-5 entity (`thread_clone` / `thread_move`),
  and the death path of a `long-lived`-category target, are
  **reserved** for the threading pass — the per-thread/no-locks claim
  must be re-examined there, not silently extended. A migrating actor is
  the second occasion for that re-examination, and this bullet's disposal
  step is one of the claims it takes: see "Open: where the weak table lives
  when an actor migrates", below.

## Across an actor boundary

Neither a cell nor a subscribed entity travels in a message. An object
holding a `WeakReference` is not sendable at all, and an object that is
the target of one may not be moved — the send falls back to a deep copy,
and the copy is a new entity nobody is subscribed to, while this actor's
cell keeps naming the original and is nulled when the original dies. The
test at pack time is per entity, bit 12 being set on a subscribed one
([classes.md](classes.md#flags-layout)); the holds-a-cell half is
decidable from the class where the class is closed. Decided 2026-08-23
([../dev/DECISIONS.md](../dev/DECISIONS.md),
[../runtime/actors.md](../runtime/actors.md#message-payload-discipline)).

**Open: where the weak table lives when an actor migrates.** The queue is not
the transfer mechanism that shape uses, so the question the message path answers is not this
one. It was node E1 of `rc-walk`'s question graph, which was deleted with that
collector on 2026-08-26, and it has had no node since: it is carried here, by
this lead-in, and the candidates and their call-site costs are enumerated by
[gc/domains.md](gc/domains.md), which chooses none. What answers it is a
threading pass, not a collector one.

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
after shipping the leak for three years. Deferred: behavior matches
PHP 8.0–8.2, logged in [../BACKLOG.md](../BACKLOG.md).

## Runtime-internal only

The subscriber row is a death-notification mechanism, and it stays
internal to the runtime — `WeakReference`, `WeakMap`, and future
runtime facilities (the object registry of the observability design)
may subscribe; **no user-facing death callback is exposed**. The row
is walked inside the three notification sites above, whose safety
argument is "no user code runs here" at each; a user callback in that
position could resurrect the dying object mid-notification, throw
through teardown, or observe a half-severed cycle. Python permits
weakref callbacks and has to swallow their exceptions; declining the
feature costs nothing now and can be revisited deliberately, not by
accident.

## Build scope

One step builds this whole machinery, the build plan that used to
carry it having been deleted with `rc-walk` on 2026-08-26 and no
successor step yet written: the kind-5 entity, the weak table and rows,
`notify` wired into ordinary teardown and into the cycle teardown, the
arena weak list, and the `create`/`get` ABI surface — the machinery is
untestable without its entry points. The `Map` subscriber variant lands with `WeakMap`
itself, when the runtime grows maps; nothing in the row format needs
revisiting for it.
