# Memory

Memory Manager — allocation and management of memory used by the runtime.

Covers memory regions, allocation strategies, arena/pool design, and the interfaces exposed to other subsystems for requesting and releasing memory.

## Documents

- [arenas.md](arenas.md) — memory categories, request/long-lived arenas, the cross-arena category barrier
- [arena-reset.md](arena-reset.md) — deferred promotion: the escapee registry, evacuation (not built) vs block retention at arena death
- [critical-reserve.md](critical-reserve.md) — the 512 KiB per-thread reserve withheld from ordinary allocation for candidate-queue growth, progress by a mutator that cannot collect, and collection working memory; workload-derived bounds remain open
- [large-entities.md](large-entities.md) — an entity past its category's packing unit: the two-clause invariant, the dynamic string layout for bytes, one block-aligned allocation per entity for cells, the run registry
- [buffers.md](buffers.md) — growable buffers: per-category growth, memory-pressure modes, the dedicated `BLOCK_KIND_BUFFER` reclaim strategy
- [static-lifetimes.md](static-lifetimes.md) — compiler-tracked ownership and moves: the tier ladder, drop-point policy, relationship analysis (acyclic classes, `#[Backedge]` cycle shapes)
- [zero-abstraction.md](zero-abstraction.md) — headerless `#[FFI]` values: no header, no ARC; owner-bound lifetime or `FFIBox` attachment, borrowed string/array views
- [ffi.md](ffi.md) — pure C structures: the mandatory owner model, field/type mapping (where `string` is a C string), `FFIBox` attachment, the attribute catalog
- [regions.md](regions.md) — `#[Region]`: instance-owned arenas with a per-region GC binding; the allocator class (custom allocation/free/traversal); the memory half of an actor
- [arc-optimizations.md](arc-optimizations.md) — refcount elimination strategies (partly superseded by static-lifetimes.md)
- [bulk-operations.md](bulk-operations.md) — vector release and entity-cell reservation: one call per batch, best-effort contiguous placement; design only
