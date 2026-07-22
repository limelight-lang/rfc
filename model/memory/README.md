# Memory

Memory Manager — allocation and management of memory used by the runtime.

Covers memory regions, allocation strategies, arena/pool design, and the interfaces exposed to other subsystems for requesting and releasing memory.

## Documents

- [arenas.md](arenas.md) — memory categories, request/long-lived arenas, the cross-arena category barrier
- [arena-reset.md](arena-reset.md) — deferred promotion: the escapee registry, evacuation (not built) vs block retention at arena death
- [buffers.md](buffers.md) — growable buffers: per-category growth, memory-pressure modes, the dedicated `BLOCK_KIND_BUFFER` reclaim strategy
- [static-lifetimes.md](static-lifetimes.md) — compiler-tracked ownership and moves: the tier ladder, drop-point policy, relationship analysis (acyclic classes, `#[Backedge]` cycle shapes)
- [zero-abstraction.md](zero-abstraction.md) — `#[FFI]` entities: no header, no ARC; owner-bound lifetime or `Box` attachment, borrowed string/array views
- [ffi.md](ffi.md) — pure C structures: the mandatory owner model, field/type mapping (where `string` is a C string), `Box` attachment, the attribute catalog
- [regions.md](regions.md) — `#[Region]`: instance-owned arenas with a per-region GC binding; the memory half of an actor
- [arc-optimizations.md](arc-optimizations.md) — refcount elimination strategies (partly superseded by static-lifetimes.md)
