# Memory

Memory Manager — allocation and management of memory used by the runtime.

Covers memory regions, allocation strategies, arena/pool design, and the interfaces exposed to other subsystems for requesting and releasing memory.

## Documents

- [arenas.md](arenas.md) — memory categories, request/long-lived arenas, the cross-arena category barrier
- [arena-reset.md](arena-reset.md) — deferred promotion: remembered set, evacuation vs block retention at arena death
- [static-lifetimes.md](static-lifetimes.md) — compiler-tracked ownership and moves: the tier ladder, drop-point policy, relationship analysis (acyclic classes, `#[Backedge]` cycle shapes)
- [zero-abstraction.md](zero-abstraction.md) — `#[FFI]` entities: no header, no ARC; owner-bound lifetime or adapter wrapper, borrowed string/array views
- [arc-optimizations.md](arc-optimizations.md) — refcount elimination strategies (partly superseded by static-lifetimes.md)
