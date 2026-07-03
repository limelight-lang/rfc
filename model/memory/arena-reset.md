# Arena Reset: Deferred Promotion

## Scope

What happens when a request arena dies. Escaped references are handled
**lazily** — not at the assignment barrier, but at arena destruction, and
only for objects that actually survived. The algorithm is adaptive: it
chooses between evacuating survivors and retaining their blocks, per
arena, based on how much survived.

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
  registry of external references into the arena — no heap tracing is
  ever needed to find them.
- **Arena block map**: which 32KB blocks belong to the arena, and (after
  the survivor trace) which contain survivors.
- **No live stack**: the arena dies after the request completes, so no
  PHP frames or registers reference it. Moving survivors requires **no
  statepoints** — the non-moving property of the GC heap is untouched;
  promotion is an arena-boundary event, not heap compaction.

## Step 1 — Validate and trace

1. Walk the remembered set; drop stale entries (the slot was overwritten
   or its owner died — check it still points into this arena).
2. Trace the **escaped subgraph** from the valid external references:
   escaped objects may reference other arena objects transitively. The
   trace is bounded by the size of the escaping graph, not the arena.
3. Run pre-destructors (`__destruct`) for tracked dying objects
   ([object-lifecycle.md](../../runtime/object-lifecycle.md)); escaped
   objects are not dying and are skipped.

## Step 2 — Decide, per arena

Survival ratio = escaped bytes / arena bytes (thresholds tunable,
to be calibrated with real workloads).

### Mode A — Evacuation (few survivors)

- Copy the escaped subgraph into the GC heap (or long-lived arena).
- Update every incoming reference — the remembered set *is* the complete
  list of them, so this is a walk over logged slots, not a heap scan.
- Object identity is preserved observably: all surviving references are
  updated, and `spl_object_id` uses the JVM identity-hash trick — the id
  is lazily stored in the object on first request and travels with it.
- **The arena's blocks — all of them — return to the global block pool.**

### Mode B — Retention (many survivors)

- Blocks containing **no** survivors are returned to the global pool
  immediately. Only survivor-carrying blocks are retained — the unit of
  retention is the block, never the whole arena, so fragmentation cost is
  bounded by survivor placement.
- Free lines within retained blocks are recyclable through normal Immix
  line-level allocation — the retained blocks are donated to the general
  heap, not held as a private reserve.
- Retained blocks are marked **sticky**: their objects carried no
  refcount history while in the arena (objects are not counted there), so
  they are managed by the tracing component from now on — exactly the
  fate of saturated objects in LXR, a mechanism already in the plan
  ([gc-research.md](../gc/gc-research.md)).
- **Category bits are rewritten in place**: a linear walk over the
  retained blocks flips the memory-category bits in each live object's
  flags. Sequential reads over a handful of 32KB blocks — cheap, and it
  keeps the retain/release fast path exactly as designed (one load of the
  object's own flags, no block-metadata lookup). Deriving the category
  from block headers was considered and rejected: it would add an
  indirection to every retain for the benefit of a rare reset-time event.
- Sparse retained blocks may be evacuated later, opportunistically
  (Immix defragmentation), or never — correctness does not depend on it.

## Freed memory is just memory

Everything released — the whole arena in mode A, survivor-less blocks in
mode B — goes back to the **global 32KB block pool** and is immediately
reusable by any consumer: new request arenas, the GC heap. An arena is not
a separate memory kingdom; it is a set of blocks borrowed from the common
pool and returned on death.

---

## Relation to the barrier strategies

- **deepCopy at the barrier** remains as the *eager* variant for
  value-like data (COW strings/arrays), where copying is natural and
  identity is not observable.
- **Arena pinning** as a standalone strategy dissolves into mode B: block
  retention *is* pinning, at block granularity instead of whole-arena.

## Open design debts

1. **`SplObjectStorage` / `WeakMap`** keyed by object address: after
   evacuation, keys must be rehashed — or keyed by the stored lazy id
   from the start.
2. **Thresholds** for mode A vs B: measure, then fix.
