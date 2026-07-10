# Mutable Buffers: Growth, Isolation, Reclaim

## Scope

The growable-buffer primitive (`{ data, len, capacity }`, no `RcHeader`,
see [ll-model/docs/memory-manager.md](https://github.com/limelight-lang/ll-model/blob/main/docs/memory-manager.md)
"Mutable Buffers") across all three arena categories, and the reclaim
strategy for buffers that outlive a single request.

Consumers: mutable (non-COW) strings ([strings.md](../strings.md)), and
any future growable container built the same way.

---

## Per-Category Growth

- **Request arena**: bump allocation. Growth is extend-in-place when the
  buffer's payload is the top of the arena's bump (no copy), otherwise a
  fresh payload at 2× capacity, copy, swap `data`. Fragmentation is a
  non-issue: the whole arena resets together, so an abandoned old payload
  is reclaimed for free at request end. No dedicated isolation needed
  here.
- **Long-lived / immortal**: no bump-top to extend. Growth is alloc-new +
  copy + free-old (`ll_realloc`-shaped). This is where isolation and
  reclaim strategy (below) matter.

## Memory-Pressure Modes

The manager tracks a global mode — **plenty / tight / critical** — the
same shape as the GC activity bit in
[heap-design.md](../gc/heap-design.md) (one load + branch). The mode
governs two independent decisions:

1. **Slack on allocation**: `plenty` gives growable buffers a slack
   "hole" (default 2× capacity); `tight`/`critical` allocate exact-size,
   no slack.
2. **Hole reuse**: see Reclaim Strategy below — `plenty`/`tight` never
   consult existing holes (pure bump); `critical` does.

Callers (compiler-generated code) may pass an explicit growth-hint
parameter at the allocation site (0 = "unknown, let the mode decide").
The hint is a **recommendation**: the active mode may override or ignore
it, even down to exact-size in `critical`.

Open: thresholds separating the three modes, and where the mode flag
lives, need real workloads to calibrate.

## Dedicated Buffer Arena: `BLOCK_KIND_BUFFER`

**Decision**: long-lived growable buffers get their own block-pool kind,
separate from `BLOCK_KIND_HEAP` (the fixed-size-class object allocator).
Realloc-heavy buffer churn is isolated from the general object heap so
its fragmentation never pollutes it — arena isolation by allocation
pattern is standard practice (validated against real-world arena
allocators: isolating growable/high-churn allocations into a dedicated
region is a recognized technique for keeping fragmentation out of the
general heap). Request-scoped buffers stay in the plain request arena;
isolation buys nothing there since the whole arena reclaims together.

No size classes: buffers vary continuously in size, so the `Heap`
size-class-slot model doesn't fit.

### Size routing

Everything below applies to payloads that fit a pooled block
(≤ 32 KB − header). A larger payload lives in an OS-direct,
32 KB-aligned run (the `BLOCK_KIND_LARGE_RUN` path of `ll-model`'s
stdapi): growth there is alloc-new + copy + free-old, and a freed run
returns to the OS immediately — the free-list machinery below never
sees it. The memory-pressure modes still govern slack for runs; hole
reuse is block-only.

### Reclaim Strategy Decision

When a long-lived buffer grows and moves, the abandoned chunk is
reclaimed via an **intrusive LIFO free-list threaded through the freed
chunk's own payload** — the same zero-metadata trick `ll-model`'s
`heap.rs` `FreeSlot` already uses, not a permanent boundary-tag header.
The list is **per-block**: its head lives in the buffer block's
256-byte header and the chain never leaves the block, so the
L2-residency of a walk holds by construction, not by hope.

- Live buffers pay **zero steady-state overhead**: no permanent header
  field to maintain or keep cache-warm.
- Free (push): O(1) onto the owning block's list, writing into memory
  that was just touched (the freed chunk itself) — cache-hot.
- Each block header keeps a **live-chunk count** (as `heap.rs` blocks
  do): when it hits zero the block returns to the global pool.
  Without this, an emptied buffer block would be parked forever.
- `plenty`/`tight` mode: allocation just bumps, ignoring the lists
  entirely.
- `critical` mode: allocation pops from a block's list first, searching
  at most the first *K* entries (bounded, tunable) before falling back
  to bump.

**Known limit — no coalescing, ever**: adjacent free chunks are never
merged (that would need boundary tags, rejected below), so a block can
fragment into holes that individually fit nothing. Accepted because the
damage is bounded by one block (32 KB), emptied blocks recycle through
the live-chunk count, and sustained pathological fragmentation is what
the compaction fallback (rejected alternative 2) exists for — the free
list is a cheap opportunistic layer, not the defragmentation story.

**Rejected alternatives**:

1. **Permanent boundary tags on every chunk** (classic free-list +
   coalescing, dlmalloc-style) — correct, and the search stays
   block-local (bounded by 32 KB) so it never suffers the classic
   scattered-free-list cache-miss problem of a general-purpose malloc —
   but it taxes every live buffer forever (a permanent header field) for
   a benefit only `critical` mode needs.
2. **Compaction/evacuation on mode transition** (relocate live buffers
   into dense fresh blocks, à la the sparse-block evacuation of
   [arena-reset.md](arena-reset.md)) — the best cache behavior for the
   scan+copy itself (sequential,
   prefetcher-friendly), but requires a permanent owner back-pointer per
   chunk, and the owner-pointer fixup is an effectively-random pointer
   chase (each owning struct lives wherever it lives). Kept as a
   secondary fallback for sustained heavy fragmentation, not the default
   path; converges with the "explicit pack/optimize operation for
   long-lived structures" backlog item rather than needing separate
   design.

Needs real workloads to pick *K* and the mode thresholds.

## Interactions

- [strings.md](../strings.md): the mutable-string class embeds exactly
  this buffer.
- [arena-reset.md](arena-reset.md): the compaction fallback above reuses
  the same evacuation shape as sparse-block evacuation, applied to
  buffer blocks instead of whole arenas.
- [heap-design.md](../gc/heap-design.md): the memory-pressure mode is
  the same one-flag-load-and-branch shape as the GC activity bit;
  whether they are the same flag or two independent ones is open.
