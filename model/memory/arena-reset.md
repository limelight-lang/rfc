# Arena Reset: Deferred Promotion

## Scope

What happens when a request arena dies. Escaped references are handled
**lazily** — not at the assignment barrier, but at arena destruction, and
only for objects that actually survived. The algorithm is adaptive: it
chooses between evacuating survivors and retaining their blocks, **per
32 KB block**, based on how much survived in each block.

Prior art: this is the Garbage-First principle (G1: collect regions where
garbage dominates, skip regions where survivors dominate) combined with
en-masse promotion and Immix opportunistic evacuation.

Builds on: the category barrier ([arenas.md](arenas.md)), the 32KB
block / 256B line heap structure ([heap-design.md](../gc/heap-design.md)),
object lifecycle ([object-lifecycle.md](../../runtime/object-lifecycle.md)).

---

## Inputs — all available for free at reset time

- **Remembered set**: the category barrier logged every store of an
  arena reference into a longer-lived container. This is a *complete*
  registry of external references into the arena: no heap tracing is
  ever needed to find them.
- **Arena block map**: which 32KB blocks belong to the arena, and (after
  the survivor trace) which contain survivors.
- **No live stack**: the arena dies after the request completes, so no
  PHP frames or registers reference it. Moving survivors requires **no
  statepoints**: the non-moving property of the GC heap is untouched;
  promotion is an arena-boundary event, not heap compaction.

## Step 1 — Validate, trace, destruct: a fixpoint loop

Destructors and the trace depend on each other circularly: which
destructors run depends on who escaped (escaped objects are not dying
and are skipped), but `__destruct` runs PHP code and can *create new
escapes* — store an arena object, `$this` included, into a longer-lived
slot, after the remembered set was already read. A fixed step order
would miss those. So step 1 iterates to a fixpoint:

1. Walk the remembered set; drop stale entries (the slot was overwritten
   or its owner died; check it still points into this arena). Remember
   the high-water mark — the set is append-only.
2. Trace the **escaped subgraph** from the valid external references:
   escaped objects may reference other arena objects transitively. The
   trace is bounded by the size of the escaping graph, not the arena.
3. Run pre-destructors (`__destruct`) for tracked dying objects
   ([object-lifecycle.md](../../runtime/object-lifecycle.md)) that are
   not escaped and not yet destructed (the `DESTRUCTED` flag is the
   exactly-once guard). Destructors go through the normal barrier, so
   new escapes land in the remembered set; destructor-allocated objects
   land in the arena and may register destructors of their own.
4. If the remembered set grew past the mark, or new destructors were
   registered: validate and trace **only the delta**, then repeat
   from 3. Otherwise the state is stable — proceed to step 2.

The loop terminates: every round either destructs at least one new
object (each destructs at most once) or is the last. An object
resurrected from its own `__destruct` survives already-destructed —
the destructor never runs again, matching Zend semantics.

## Step 2 — Decide, per block

**The unit of decision is the 32 KB block, not the arena.** An arena is
heterogeneous at death: bump allocation places objects created together
next to each other, so mass survivors cluster densely (a cache built in
one loop fills whole blocks) while accidental stragglers sit alone in
mostly-dead blocks. A single per-arena survival ratio would misjudge
both. Instead, after the survivor trace, each block is judged by its
escaped bytes (threshold tunable, to be calibrated with real
workloads):

- **No survivors** — the block returns to the global pool immediately.
- **Dense** — the block is retained in place; nothing is copied.
- **Sparse** — its survivors are evacuated (copied out individually)
  and the block returns to the pool.

This is Immix opportunistic evacuation applied at the arena boundary.
The whole-arena modes are its degenerate cases (every block sparse /
every block dense), so nothing is lost — and the global survival-ratio
knob disappears; the only tunable left is the per-block one.

### Evacuation is now-or-never

Evacuation is legal **only at this moment**. The remembered set is a
complete registry of external references exactly at arena death, and
there is no live stack. The instant a block is retained, its objects
become ordinary heap objects: stores of references to them are no
longer logged anywhere, completeness is gone, and the non-moving
contract ([heap-design.md](../gc/heap-design.md)) fixes their addresses
for the rest of their lives — moving them later would take read
barriers or statepoints, both deliberately rejected. So a sparse block
is evacuated now or carried until its stragglers die; there is no
"defragment it later".

### Evacuation (sparse blocks)

- Copy the survivors of sparse blocks into the GC heap (or long-lived
  arena). References among survivors are fixed during the copy trace;
  every incoming external reference is fixed by walking the remembered
  set, which *is* the complete list of them — a walk over logged slots,
  not a heap scan.
- Object identity is preserved observably: all surviving references are
  updated, and `spl_object_id` uses the JVM identity-hash trick: the id
  is lazily stored in the object on first request and travels with it.
- **Pinned objects don't move**: an object whose raw address escaped
  through the FFI boundary
  ([zero-abstraction.md](zero-abstraction.md)) is invisible to the
  remembered set and must not be copied; its block is retained
  regardless of density.

### Retention (dense blocks)

- Free lines within retained blocks are recyclable through normal Immix
  line-level allocation: the retained blocks are donated to the general
  heap, not held as a private reserve.
- Retained blocks are marked **sticky**: their objects carried no
  refcount history while in the arena (objects are not counted there), so
  they are managed by the tracing component from now on, exactly the
  fate of saturated objects in LXR, a mechanism already in the plan
  ([gc-research.md](../gc/gc-research.md)).
- **Category bits are rewritten in place**: a linear walk over the
  retained blocks flips the memory-category bits in each live object's
  flags. Sequential reads over a handful of 32KB blocks: cheap, and it
  keeps the retain/release fast path exactly as designed (one load of the
  object's own flags, no block-metadata lookup). Deriving the category
  from block headers was considered and rejected: it would add an
  indirection to every retain for the benefit of a rare reset-time event.
- **Why carrying stragglers is acceptable**: retention damage is
  bounded by the straggler's own lifetime. A short-lived escapee (a
  session entry living minutes) frees its lines when it dies, and the
  emptied block returns to the pool; under steady load the retained
  blocks form a bounded stationary population, not unbounded accretion.
  Only unpredictably long-lived stragglers keep blocks forever — exactly
  the ones sparse-block evacuation exists for.
- **Phasing**: retention is the safe default and the whole of the first
  implementation — no copying, no identity machinery, no reference
  fixup. Sparse-block evacuation is purely additive and can land later.

### Rejected: proxy handles instead of copying

Considered: redirect all remembered-set slots to a thin per-survivor
proxy (one target pointer inside), so that a later move updates one
pointer and objects stay movable forever — reopening the now-or-never
door. Arena death is genuinely the one moment proxies could be
introduced cleanly: no direct external references exist outside the
remembered set, so no global read barrier would be needed. Rejected for
the core path anyway: (1) survivors reference each other directly, so
any property read that hands out a neighbor's direct pointer re-pins
that neighbor — keeping a cluster movable requires intercepting every
reference-returning read (the general interception-proxy machinery)
plus a canonical proxy per object; (2) the payoff is marginal, because
short-lived stragglers self-heal (previous section) and long-lived cold
data is better served by an explicit opt-in from its owning container.
Kept in the backlog as **proxy-mediated movability** for cold
long-lived data ([BACKLOG.md](../../BACKLOG.md)).

## Freed memory is just memory

Everything released (survivor-less blocks, evacuated sparse blocks, and
every block of an arena nothing escaped from) goes back to the
**global 32KB block pool** and is immediately
reusable by any consumer: new request arenas, the GC heap. An arena is not
a separate memory kingdom; it is a set of blocks borrowed from the common
pool and returned on death.

---

## Relation to the barrier strategies

- **deepCopy at the barrier** remains as the *eager* variant for
  value-like data (COW strings/arrays), where copying is natural and
  identity is not observable.
- **Arena pinning** as a standalone strategy dissolves into block
  retention: retention *is* pinning, at block granularity instead of
  whole-arena.

## Open design debts

1. **`SplObjectStorage` / `WeakMap`** keyed by object address: after
   evacuation, keys must be rehashed, or keyed by the stored lazy id
   from the start.
2. **The per-block dense/sparse threshold** (escaped bytes per block):
   measure, then fix.
