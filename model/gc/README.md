# GC

Garbage Collector — automatic reclamation of memory no longer reachable by the program.

Covers GC algorithms, collection strategies, interaction with the Memory Manager, and the impact on object layout and lifetime.

- [rc-cycle.md](rc-cycle.md) — **the design of record since 2026-08-25, and the only cycle collector**: decrement-triggered candidate registration, shadow-count trial deletion, exact owner-side validation, ordered finalization, and the acyclic-class filter; nothing built
- [cycle/](cycle/README.md) — its open questions as a graph, which the work is built on
- [strategies.md](strategies.md) — the contract every strategy plugs into: store-barrier micro-operations, consistent-point duties, the non-moving constraint, the registry, and collection request/trigger rules
- [heap-design.md](heap-design.md) — cross-strategy decisions: non-moving, the block/line heap
- [pure-destructors.md](pure-destructors.md) — historical destructor-effect analysis: P0/P1/P2/NR, its transitive closure, and a handoff that must be revalidated against `rc-cycle`
- [domains.md](domains.md) — historical `rc-walk` proposal for more than one mutator; not reconciled with `rc-cycle`
- [domains-rejected.md](domains-rejected.md) — every shape and mechanism tried for the above and dropped, with the reason that killed it, and the prior art consulted
- [gc-research.md](gc-research.md) — research survey (ARC, Zend, Bacon-Rajan, Immix, LXR); §7 superseded by strategies.md

## What was deleted on 2026-08-26, and where it is

Edmond ruled that only the new algorithm remains, and that a superseded
mechanism left in the tree is read as the design in force. Three collectors
and one compiler-side algorithm left this directory, with their code in
`ll-model`:

- **`rc-walk`** — the barrier-free concurrent cycle collector with derived
  roots, the epoch byte and the Phase 4 exact test; the default build from
  2026-07-27. Its design, formal model, state-space accounting, scenario-replay
  proof, danger cases, review, question graph, drain-exclusivity invariant and
  retained-block proposal all went with it.
- **`rc-trace`** — the stop-the-thread candidate-buffer tracer, the first
  implementation; described in `strategies.md`, which stays.
- **`rc-satb`** — concurrent SATB marking, designed 2026-08-03 and never built.
- **The GC horizon** — the compiler-side rule deciding which locals carry a
  count, with its state set, its sixteen-case book and the refused
  capture-count regime. Ruled compiler business on 2026-08-23 and a record
  since; the count-elision bargain it struck is restated in
  [cycle/questions.md](cycle/questions.md), Y11.

**All of it is on the branch `archive/pre-rc-cycle`**, in this repository and
in `ll-model`, on `origin` as well as locally, at the commit before the first
deletion. Citations of these documents elsewhere in the repository were left as
prose and stripped of their links: the sentences are still true, and this is
where the text they name now lives. Nothing is copied back without a
`dev/DECISIONS.md` entry.
