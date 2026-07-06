# GC

Garbage Collector — automatic reclamation of memory no longer reachable by the program.

Covers GC algorithms, collection strategies, interaction with the Memory Manager, and the impact on object layout and lifetime.

- [strategies.md](strategies.md) — pluggable build-time GC strategies: the contract (store barrier slot, safepoints), the registry, the `rc-trace` default
- [satb.md](satb.md) — concurrent SATB marking: the `rc-satb` low-latency strategy
- [heap-design.md](heap-design.md) — cross-strategy decisions: non-moving, block/line heap, CAS handoff and deferred free for the concurrent strategy
- [gc-research.md](gc-research.md) — research survey (ARC, Zend, Bacon-Rajan, Immix, LXR); §7 superseded by strategies.md
