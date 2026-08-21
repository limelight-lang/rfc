# GC

Garbage Collector — automatic reclamation of memory no longer reachable by the program.

Covers GC algorithms, collection strategies, interaction with the Memory Manager, and the impact on object layout and lifetime.

- [strategies.md](strategies.md) — pluggable build-time GC strategies: the contract (store barrier slot, safepoints), the registry, the `rc-walk` default
- [satb.md](satb.md) — concurrent SATB marking, the `rc-satb` strategy: designed and deliberately unbuilt since 2026-08-03, `rc-walk` having overtaken it on pauses; the banner carries why it is kept and what would make it worth building
- [heap-design.md](heap-design.md) — cross-strategy decisions: non-moving, block/line heap, CAS handoff and deferred free for the concurrent strategy
- [rc-walk.md](rc-walk.md) — the `rc-walk` barrier-free concurrent cycle collector: derived roots, the epoch byte, the Phase 4 exact test
- [drain-window.md](drain-window.md) — the drain-exclusivity invariant: what the collector may touch while a mutator drains a confirmed component
- [gc-horizon.md](gc-horizon.md) — the compiler-side rule that decides which locals carry a count and where the uncounted ones pay: the ownership lattice, the eight horizon kinds, promotion
- [gc-horizon-states.md](gc-horizon-states.md) — its state set: what the runtime must not change, the axes the lattice reads and creates, the product and the identities that collapse it
- [gc-horizon-cases/](gc-horizon-cases/README.md) — sixteen cases instantiating the algorithm on one entity kind or one proof-ending event each, with the coverage table over the repository's own cases
- [gc-horizon-v2/](gc-horizon-v2/README.md) — the current GC horizon design: the horizon pays by publishing to the collector rather than by a count, which removes the mutator's reference count from a class of entities
- [pure-destructors.md](pure-destructors.md) — the purity ladder P0/P1/P2/NR, the transitive closure, and the hand-off drain it makes sound
- [retained-block-walk.md](retained-block-walk.md) — proposal: keep the reset's survivor list as an object index so retained former-arena blocks can be walked, retiring the "cycles among promoted survivors" limit
- [domains.md](domains.md) — proposal: `rc-walk` with more than one mutator — one writer per refcount, `#[Moved]` and the frozen handover, `~=`, each domain collecting itself, and the cases
- [domains-rejected.md](domains-rejected.md) — every shape and mechanism tried for the above and dropped, with the reason that killed it, and the prior art consulted
- [rc-walk-model.md](rc-walk-model.md) — its formal model: actor alphabets, state vector, invariants, theorems, the optimality bound, and the comparison with Java and Go
- [rc-walk-review.md](rc-walk-review.md) — the design review that produced the current shape: findings, what changed, the remaining agenda
- [rc-walk-states.md](rc-walk-states.md) — state-space accounting for the model checker: factor cardinalities, the raw product, structural collapses, the feasibility bracket
- [rc-walk-proof.md](rc-walk-proof.md) — proof by scenario replay: ordinary and adversarial interleavings played action by action, findings F1–F6 against the design documents
- [rc-walk-danger-cases.md](rc-walk-danger-cases.md) — danger cases DC0–DC5 distilled from the replay: concrete kill traces, the seeds for the adversarial test harness
- [gc-research.md](gc-research.md) — research survey (ARC, Zend, Bacon-Rajan, Immix, LXR); §7 superseded by strategies.md
