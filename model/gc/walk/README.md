# The walk, second version

> **Closed 2026-08-25.** The design of record is
> [`../cycle/README.md`](../cycle/README.md) — Edmond chose an on-the-fly
> cycle collector over a sliding view, and the work is built on its graph
> now. What stands here is the record of a stage that finished: every one
> of its thirty-two nodes carries an answer with its argument or a recorded
> reason for staying open, and the answers `rc-cycle` inherits are named in
> node Y5 there rather than re-derived.

The garbage collection design of record from 2026-08-22 to 2026-08-25. It keeps the
counted heap edge of [`../rc-walk.md`](../rc-walk.md) and it retires the
capture-count regime of [`../gc-horizon-v2/`](../gc-horizon-v2/README.md).
It carried the compiler proofs of [`../gc-horizon.md`](../gc-horizon.md)
until 2026-08-23, when Edmond ruled the compiler's proof logic outside these
documents; that text is a record now, not an inheritance.

## What decided it

The capture count stopped counting heap edges and left the concurrent walk
to find them. Two findings closed that road; the first is recorded in
[`../gc-horizon-v2/questions.md`](../gc-horizon-v2/questions.md), the second
in [`../../../dev/DECISIONS.md`](../../../dev/DECISIONS.md), 2026-08-22:

- **Node M.** A walk reads each entity once, at different times. A
  reference moved from an entity the walk has not read into one it has
  already read is invisible to it, and no count moves to record the move.
  With no per-store instruction the collector's observations are identical
  between "moved and live" and "dropped and garbage".
- **The semantics, 2026-08-22.** The count is not only a barrier.
  It also frees promptly at zero, answers the copy-on-write uniqueness
  test, and carries the arena's escape hold-count. Removing it from heap
  edges costs prompt `__destruct` for every deferred class, which
  [`../../weak-references.md`](../../weak-references.md) already refused
  for one map type.

What replaced the regime is not a new mechanism. The count stays the write
barrier, the walk stays the cycle collector, and the work moves to making
each of them cheaper.

## Files

- [questions.md](questions.md) — the open questions as a graph, with the
  rulings of 2026-08-22 that bound them.
- [compiler-proofs.md](compiler-proofs.md) — the analyses the compiler must
  run for each elision the design depends on, what each needs, and which PHP
  construct defeats it.
- [prior-art.md](prior-art.md) — round two of the search, read against the
  graph's nodes: barrier forms, cycle collection without an indivisible
  verification, and how others hand reclamation to a collector thread.
