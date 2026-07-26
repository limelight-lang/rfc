# GC

Garbage Collector — automatic reclamation of memory no longer reachable by the program.

Covers GC algorithms, collection strategies, interaction with the Memory Manager, and the impact on object layout and lifetime.

- [strategies.md](strategies.md) — pluggable build-time GC strategies: the contract (store barrier slot, safepoints), the registry, the `rc-trace` default
- [satb.md](satb.md) — concurrent SATB marking: the `rc-satb` low-latency strategy
- [heap-design.md](heap-design.md) — cross-strategy decisions: non-moving, block/line heap, CAS handoff and deferred free for the concurrent strategy
- [rc-walk.md](rc-walk.md) — the `rc-walk` barrier-free concurrent cycle collector: derived roots, the epoch byte, the Phase 4 exact test
- [rc-walk-model.md](rc-walk-model.md) — its formal model: actor alphabets, state vector, invariants, theorems, the optimality bound, and the comparison with Java and Go
- [rc-walk-review.md](rc-walk-review.md) — the design review that produced the current shape: findings, what changed, the remaining agenda
- [rc-walk-states.md](rc-walk-states.md) — state-space accounting for the model checker: factor cardinalities, the raw product, structural collapses, the feasibility bracket
- [rc-walk-proof.md](rc-walk-proof.md) — proof by scenario replay: ordinary and adversarial interleavings played action by action, findings F1–F6 against the design documents
- [rc-walk-danger-cases.md](rc-walk-danger-cases.md) — danger cases DC0–DC5 distilled from the replay: concrete kill traces, the seeds for the adversarial test harness
- [gc-research.md](gc-research.md) — research survey (ARC, Zend, Bacon-Rajan, Immix, LXR); §7 superseded by strategies.md
