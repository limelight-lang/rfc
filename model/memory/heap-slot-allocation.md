# Small-Object Heap: Slot Allocation, Block Retention, and Fast TLS

## Scope

How `Heap` (`ll-model/src/memory/heap.rs`) carves a 32 KB block into
fixed-size slots for a size class, and what happens to a block when its
last live slot is freed. Two decisions here, found by profiling a
degenerate but realistic workload (alloc one object, free it, alloc
another of the same size — a temp-buffer loop, or any LIFO-shaped
allocation pattern):

1. **Lazy (bump) slot carving** at `refill()`, instead of eagerly
   threading a free list through every slot.
2. **Bounded empty-block retention** — a block that empties does not
   unconditionally return to the global pool; each size class keeps at
   most one empty "spare" block, so the pathological pattern above
   never re-carves a fresh block on every cycle.

Builds on: the block-per-size-class design and free/local_free split
described in `heap.rs`'s module doc (mimalloc's page model).

---

## Problem, found empirically

`ll_malloc`/`ll_free` were benchmarked against a real (unmodified)
`larson.cpp` from mimalloc-bench and, in isolation, a pure
alloc-then-immediately-free loop of one fixed size. The isolated loop
measured **~140 ns/op** against our heap vs **~4 ns/op** for mimalloc —
roughly 30x, far wider than the ~2x lead our heap held in an in-process
Rust re-implementation of the same larson pattern (`benches/standard.rs`).

Root cause, confirmed by ablation (holding one object alive as an
anchor so a block's live count never reaches zero collapsed the cost
from ~140 ns/op to ~5 ns/op — tied with mimalloc):

- `refill()` built the entire free list eagerly: for a 64-byte class,
  `BLOCK_PAYLOAD / 64 ≈ 508` slots, each written with a `next` pointer
  in a loop — O(slots) work, touching all 32 KB of a cold block, every
  time a block was carved.
- `free_local()`/`drain_remote()` returned a block to the global pool
  the instant its `used` count hit zero — including the very common
  case where the next call re-allocates the same size immediately.
- Combined: any workload where a size class's live count touches zero
  (temp buffers, LIFO stacks, or simply this benchmark) paid a full
  O(slots) block rebuild on *every* allocation, not once per block
  lifetime as intended.

`benches/standard.rs`'s larson never exercises this: it holds 5,000+
live slots per size class simultaneously, so `used` rarely if ever
returns to zero mid-run. The pathology is invisible to that benchmark
and only shows up under real allocation patterns with low occupancy.

---

## Fix 1 — Lazy (bump) slot carving

A block tracks two independent sources of free slots instead of
eagerly linking all of them:

- **`free` / `local_free`** — the existing intrusive linked lists, for
  slots that have been allocated and freed at least once (unchanged
  from the mimalloc-style split already in place).
- **`bump`** — a count of how many slots, counting from the start of
  the block, have ever been handed out. Slots at index `< bump` may be
  free (via the lists above) or live; slots at index `>= bump` are
  **virgin** — never touched, no metadata written into them, nothing to
  read or maintain.

`alloc` checks in order: `free` (pop, O(1)) → `local_free` (swap into
`free`, O(1), then retry) → `bump < slots` (carve the next virgin slot
by address arithmetic, no memory write to the slot itself, O(1)) →
block exhausted (unlink, try the next block or refill).

`refill()` no longer threads a list at all: it writes the block header
(`bump = 0`, `free = null`, `local_free = null`) and links it — O(1)
instead of O(slots). The cost of "preparing" a slot for use is deferred
to the one point where it's unavoidable: when that specific slot is
actually freed and needs a `next` pointer to join a list.

No zeroing is introduced or required. `alloc` never promises zeroed
memory (that is `calloc`'s contract, handled separately in `stdapi.rs`)
— a virgin slot's prior contents are whatever the pool block held
before, and the caller must write before reading, same as today.

## Fix 2 — Bounded empty-block retention

`Heap` gains one field: `empty_reserve: Vec<*mut HeapBlockHeader>`,
indexed by size class, holding at most one retained-but-empty block per
class (null if none).

When a block's `used` count reaches zero:

- If `empty_reserve[ci]` is null, this block *becomes* the reserve: it
  stays linked in `available` (ready for instant reuse — its `free`/
  `local_free` lists and `bump` state are exactly as they were, no work
  needed) and its pointer is recorded in `empty_reserve[ci]`.
- If `empty_reserve[ci]` already holds a different block, this
  newly-emptied block is the one actually unlinked and returned to
  `BlockPool` (today's behavior, now the fallback rather than the
  default).

When a slot is claimed from a block that was the reserve (`used` goes
0 → 1), `empty_reserve[ci]` is cleared — the block is active again, not
a spare.

This bounds the extra resident cost to at most one empty 32 KB block
per size class (≤ 32 classes × 32 KB ≈ 1 MB high-water in the fully
degenerate case) while eliminating the instant-return/instant-refill
cycle for the common case of one class briefly going idle.

Same logic applies on both the same-thread free path (`free_local`)
and the cross-thread drain path (`drain_remote`), factored into one
`retire_empty(ci, block)` helper so the two paths cannot drift.

### Known simplification (phase 1, matches this file's own pattern of
staged builds elsewhere in the memory manager)

No periodic trim / purge pass exists yet. A heap that briefly needs
many blocks in one class and then goes permanently idle retains at
most one empty block for that class forever (bounded, not unbounded —
see above) rather than eventually decommitting it back to the OS.
mimalloc's equivalent is a background/heuristic page-purge pass; ours
is deferred, same as the arena-reset evacuation phase is deferred in
`arena-reset.md`.

---

## Result

Isolated fixed-size alloc/free loop, 20M iterations, `SIZE=64`
(`bench-external/larson/isolate_path.cpp`, diagnostic-only harness):

| Variant | ns/op |
|---|---|
| mimalloc | ~3.9 |
| **ours, after both fixes** | **~7.7–8.2** |
| ours, before the fix (baseline) | ~140 |
| ours, anchored (`used` never hits 0) — the ceiling this fix approaches | ~4.4–4.5 |
| system malloc | ~26–28 |

18x faster than the pre-fix baseline; within ~2x of mimalloc, versus
~30x before. The small remaining gap versus the anchored ceiling
(~4.4 ns) is `claim()`'s extra branch plus whatever the reserve/refill
bookkeeping still costs on the (rare, amortized) path where the class's
one empty spare is already taken.

Real (unmodified) `larson.cpp` from mimalloc-bench, single thread,
`5 8 1000 5000 100 4141 1`:

| Contender | Throughput (ops/s) | vs mimalloc |
|---|---|---|
| mimalloc | ~45–54M | 1.0x |
| **ours, after the fix** | **~20.0M** | **~2.2–2.7x slower** |
| system malloc | ~11.3M | ~4–4.7x slower |
| ours, before the fix | 7.95M | ~6.8x slower |

After the fix, our heap moved from *slower than system malloc* to
consistently faster than it (~1.8x), and closed the mimalloc gap from
~6.8x to ~2.2–2.7x, on the exact same unmodified upstream benchmark.

---

## Fix 3 — Fast TLS (Windows): stop paying for module-indirected TLS

With fixes 1-2 in place, `dumpbin /disasm` on the real `ll_malloc`/
`ll_free` symbols showed the remaining gap to mimalloc was dominated by
thread-local heap lookup — not `std::thread_local!`'s lazy-init guard
(already removed, see `ll_thread_init` below), but the *mechanism*
itself. On `windows-msvc`, compiler-emitted TLS (what `thread_local!`
and `__declspec(thread)` both compile to) resolves a variable through
**three dependent, non-pipelineable loads**:

```
mov eax, [_tls_index]          ; this module's index in the process
mov rcx, gs:[0x58]              ; TEB.ThreadLocalStoragePointer
mov rax, [rcx + rax*8]          ; this module's TLS block
mov rcx, [rax + offset]         ; the field
```

That module-indirection exists so a DLL's TLS block can be found
generically after being loaded/unloaded at arbitrary times. We don't
need it — `ll-model` is one static library, not a plugin. Measured cost
via ablation (`bench-external/larson/isolate_path.cpp`, comparing the
real `ll_malloc`/`ll_c_free` against a diagnostic variant taking the
`Heap*` as an explicit parameter, no TLS at all): **~2.5–3 ns of the
~4 ns gap to mimalloc** was this chain of three dependent loads.

mimalloc avoids it by never going through compiler TLS *or* the real
Win32 `TlsGetValue`/`TlsSetValue` (those are genuine, non-inlined calls
through the kernel32 import table — no cheaper than the module path
once the call/ret and the callee's own TEB lookup are counted).
Instead (`mimalloc/prim.h`, `MI_TLS_SLOT`) it reads/writes the TEB's
inline `TlsSlots` array directly at a fixed, stable offset:
`gs:[0x1480 + slot*8]`, one instruction, via MSVC's `__readgsqword`
intrinsic. `TlsAlloc()` is called exactly once, process-wide, purely to
reserve a slot number the OS promises not to hand to anyone else — the
hot path never calls it again.

`heap.rs`'s `tls` module (`#[cfg(windows)]`) mirrors this exactly via
inline `asm!` (`mov {val}, gs:[{off:e}]` / `mov gs:[{off:e}], {val}`),
since Rust does not expose `__readgsqword` directly:

- The OS TLS slot number is resolved once (`TlsAlloc`, cold path) and
  published to a `Relaxed` `AtomicU32` — racing this init across
  threads is harmless (losers discard their own reserved slot number
  and use the winner's; the *value* stored in each thread's own TEB
  slot is still per-thread).
- Fast path: if the reserved slot is one of the first 64 (the inline
  array's fixed size — true in practice, since this is one of the
  first TLS allocations in the process), read/write `gs:[offset]`
  directly.
- Fallback: if the slot lands at 64 or above (the OS spills to a
  separately-allocated `TlsExpansionSlots` array not reachable by the
  fixed-offset trick), fall back to the real `TlsGetValue`/
  `TlsSetValue` API. Practically never taken, but correctness for that
  case matters more than the fast path here.
- Non-Windows targets keep the portable `thread_local!` implementation
  unchanged — ELF `__thread` is already a single `%fs`-relative load
  with no module table, so there is nothing to fix there (unverified
  by measurement on this project so far; no Linux benchmark run yet).

### Result

Isolated fixed-size loop, 20M iterations, `SIZE=64`:

| Variant | ns/op |
|---|---|
| mimalloc | ~3.6–4.3 |
| **ours, after fixes 1-3** | **~6.8–7.3** |
| ours, after fixes 1-2 only | ~7.7–9.0 |
| ours, before any fix | ~140 |
| snmalloc (0.7.4, same harness) | ~4.4–5.4 |
| system malloc | ~26–29 |

Real `larson.cpp`, single thread, `5 8 1000 5000 100 4141 1`: no
regression versus fixes 1-2 (~18.4–20.0M ops/s both before and after —
larson's workload has more per-op cost outside the TLS lookup itself,
so the win is smaller in relative terms there than in the isolated
loop). One outlier run (13.8M ops/s) was discarded as a cold-start /
system-noise artifact, consistent with this file's own note that this
is a dev laptop, not an isolated bench rig.

### What this does not close

The remaining ~1.6–2x gap to mimalloc/snmalloc is not yet attributed
further. `claim()`/`retire_empty()` bookkeeping (churn accounting) and
residual algorithmic differences are the likely remaining candidates —
see the anchored-vs-raw breakdown further up this file.

---

## Fix 4 — Bitmap free-slot tracking + O(1) size-class lookup

> **Half of this fix has since been reverted — read Fix 5 before trusting
> anything below.** The O(1) size-class lookup table stands and is still in
> `Heap`. The bitmap does not: it was replaced by an intrusive per-block
> free list, which measured **+18-20%** on the same real `larson.cpp`. The
> ablation table below does not support the conclusion it was read as
> supporting — the row labelled "old linked-list" is the *entire production
> allocator* of the time, while every "bitmap" row is a standalone prototype
> with a static per-class arena and no `refill`, no `BlockPool`, no block
> list, and no slow paths at all. It compared an isolated arena against
> production, not one free-slot structure against another. Fix 5 has the
> detail.

Profiling the real C ABI on a *realistic* workload (varying sizes
8..1000, not one fixed size, 5000-object live-set churn — matching what
`larson.cpp` actually does) found two more contributors that the
fixed-size isolated loop above couldn't see:

1. **`size_class_index`'s linear scan** (`SIZE_CLASSES.iter().position`)
   compiles to a fully unrolled chain of up to 26 sequential
   compare+branch pairs (confirmed via `dumpbin /disasm`) — negligible
   for `size=64` (resolves in ~4 comparisons) but real for large,
   varying sizes. Fixed with a direct lookup table at 16-byte
   granularity (`CLASS_LUT`, built at compile time via `const fn`): one
   array read, zero branches.
2. **The intrusive linked-list free/local_free scheme** pops/pushes by
   chasing a pointer stored inside the freed slot itself — a
   cache-unfriendly, unpredictable-latency access, since that slot can
   be anywhere in the 32 KB block. Fixed with a bitmap (one bit per
   slot, `alloc` = find-first-set + clear, `free` = set the bit back):
   one small, always-hot region touched on every operation, instead of
   pointer-chasing scattered across 32 KB. The bitmap is heap-allocated
   per block (a `Vec<u64>`'s raw parts, freed explicitly when the block
   is truly released) rather than embedded in the fixed 256-byte
   (`LINE_SIZE`) block header — the worst case (2032 slots for the
   16-byte class) needs 256 bytes on its own, the entire existing header
   budget, with no room left for `kind`/`used`/`owner`/etc.

An isolated ablation prototype (`bench-external/larson/bitmap_proto.cpp`,
static 8 MB arena per class, no `refill`/`BlockPool` interaction)
measured, on the realistic workload:

| Variant | ns/op | vs mimalloc |
|---|---|---|
| mimalloc (same workload) | ~11.6–15.7 | 1.0x |
| bitmap + O(1) LUT (isolated prototype) | ~19.4–22 | ~1.7x slower |
| bitmap + linear scan | ~26–29 | ~2.3x slower |
| old linked-list + linear scan (production, before this fix) | ~32.5–43.75 | ~2.9x slower |

Both changes landed in `Heap` (not just the prototype). **Real,
measured result after landing** (same workload, real `ll_malloc`/
`ll_c_free`, not the idealized prototype):

| | ns/op | vs mimalloc |
|---|---|---|
| mimalloc | ~12.2–15.7 | 1.0x |
| **ours, after fix 4** | **~27.5–30.4** | **~2.0–2.2x slower** |
| ours, before fix 4 | ~32.5–43.75 | ~2.9x slower |

The real gain (~15-25%, gap 2.9x → ~2.0-2.2x) is smaller than the
isolated prototype's ~40-47% suggested — the prototype's static arena
sidesteps real overhead the production `Heap` still pays: TLS lookup,
the doubly-linked `available` block list, `refill`/`BlockPool`
interaction, and `retire_empty`/`empty_reserve` bookkeeping. The
prototype correctly isolated *which data-structure change* helps and by
roughly how much in principle; it was never going to predict the
fully-integrated number exactly.

### Known deferral: division in slot-index computation

`free`'s index-from-pointer computation
(`(ptr - block_base) / class_size`) is a real 64-bit integer division —
`class_size` is not a power of two for most classes, so the compiler
can't fold it into a shift (it's a per-class *runtime* value, not a
compile-time constant at the call site). An isolated profile
(`selfprofile3.cpp`, real `SuspendThread`-based sampling) found this at
~3.5% of total time — real, but the smallest of the three findings in
this investigation. Not fixed: the correct fix (a precomputed
per-class multiply-by-reciprocal-plus-shift, "magic number division")
risks a subtly wrong hand-rolled reciprocal, and 3.5% didn't justify
that risk under the time available. Left as a documented, deferred
optimization — matches this codebase's existing pattern of phased,
explicitly-labeled deferrals (see `arena-reset.md`'s evacuation phase).

---

## Fix 5 — Free list back, block-list churn, and a split fast path

Fix 4's own follow-up asked for a profile of the *fully-integrated* `Heap`
rather than another prototype. That profile (`selfprofile4.cpp` — same
`SuspendThread` sampling, but resolving RIPs to symbol+line in-process via
DbgHelp instead of dumping 300 MB of raw addresses) was run, and it found
the remaining gap was three separate things, not one.

Headline, real `larson.cpp` through the C ABI, `larson 5 8 1000 5000 100
4141 1`, all binaries interleaved run-by-run in one session (the machine
drifts ~20% over a long session; only interleaved ratios are meaningful):

| | throughput | vs mimalloc |
|---|---|---|
| before (fix 4 state) | ~26.0M ops/s | 2.15x slower |
| **after** | **~36.4M ops/s** | **1.54x slower** |
| mimalloc | ~55.9M ops/s | 1.0x |

### 5a — Intrusive free list replaces the bitmap (+18-20%)

Fix 4's premise — a free list "chases a pointer to an essentially random
address within the block" — is true but irrelevant, because that address is
one the caller touches anyway: on `alloc` it is the slot being handed out
(the caller is about to write it), on `free` it is the slot just released.
The link rides a line that is already hot. The bitmap, by contrast, is a
*side* allocation: it adds a second dependent load into a line nothing else
touches, makes "is this block full?" an O(words) scan instead of a null
check, and forces `free` to recover a slot index via `(ptr - base) /
class_size` — a real integer division (fix 4's own "known deferral", now
simply gone: a free list never needs the index).

Not measured as a data-structure swap in isolation, because that is exactly
the mistake fix 4 made — measured by changing the production `Heap` and
running the real benchmark.

### 5b — Block-list churn was the memory cost (walk 1.41 -> 1.00)

Instrumenting how many blocks one `alloc` walks before finding a slot
produced a number that tracked the gap across every working-set size:

| live set | walk/alloc | gap then |
|---|---|---|
| 50 | 1.000 | 1.23x |
| 200 | 1.001 | 1.24x |
| 1000 | 1.159 | 1.75x |
| 5000 | 1.410 | 1.80x |

Cause: `free` re-linked an unfulled block at the **head** of `available`,
which is exactly where `alloc` serves from. So every cross-block free
installed a head with a single free slot; the next alloc took it, the block
was full again, and the alloc after that loaded that header cold only to
discover it was full and unlink it. `unlink` rewrites `prev.next` and
`next.prev` — two *other* blocks' headers, 32 KB apart, both cold.

Two changes: an unfulled block re-links **behind** the head
(`relink_unfull`), and a block that has just handed out its last slot is
unlinked **immediately**, while its header is still hot, instead of being
left for the next alloc to trip over. `walk/alloc` is now 1.000 flat.

### 5c — Fast path split out of the slow paths (+4.4%)

Reading the generated code (`cargo rustc -- --emit asm`) against mimalloc's
(`dumpbin /disasm mimalloc.lib`) showed `mi_malloc` is **21 instructions,
leaf, no stack frame**, ending in `jmp _mi_malloc_generic` — every rare path
lives in another function. Ours was three non-inlined functions
(`ll_malloc` -> `ll_alloc` -> `Heap::alloc`), ~45-50 instructions, two stack
frames, five `push`es and a `movaps` saving `xmm6` (LLVM had picked a
callee-saved SSE register to zero 16 bytes inside `unlink`). None of that
frame is used by a free-list pop; it existed because the rare branches
shared the function, and LLVM — with no `#[cold]` anywhere in the file — had
no reason to think `refill` (measured: 0.00003 calls per alloc) was rare.

`refill`/`drain_remote`/full-block/large-object/TLS-fallback are now
`#[cold] #[inline(never)]` tails reached by tail calls; the fast path is
`#[inline]` and collapses into `ll_malloc`. Also removed from the hot path:
a redundant second `CLASS_LUT` lookup (the `size_class_index(size).is_some()`
guard was equivalent to the `size <= MAX_SMALL` test beside it), a bounds
check that cannot fire (`get_unchecked` on a const-built table), the
`Vec`-behind-a-pointer indirection for the per-class tables (now inline
arrays), and the lazy-init check on every TLS read (`ll_thread_init`'s
contract already guarantees it, so `get` no longer re-checks). Frame is down
to one `push` and a `sub rsp, 32`.

Only +4.4% on its own: those instructions were cheap, hot-stack traffic that
pipelines well. Its real value is visible on small working sets, where
nothing stalls (see below) — and note the profile is a *poor* tool for this
class of cost, since samples land on stalled loads, not on cheap prologue
stores. The disassembly is the evidence here, not the profile.

### What the gap is now, by working set

`scaling_probe.cpp` — larson-shaped, only the live set varies. Baseline and
current built from the same tree, run back-to-back (mimalloc's own column
agrees within 10% across the two runs on every row but the last, which is
why the last is not quoted):

| live bytes | before | after |
|---|---|---|
| 24 KB | 1.74x | **1.03x** |
| 98 KB | 1.81x | **0.95x** |
| 492 KB | 2.09x | **1.18x** |
| 2.4 MB | 2.35x | **1.45x** |
| 9.8 MB | 2.12x | **1.32x** |

The floor — small working sets, everything cache-resident, pure path length
— went from ~1.8x to parity. That is 5c's result and it confirms the
attribution. What remains is memory behaviour, peaking ~1.45x where the live
set is in L2/L3 range, which is exactly where larson's default 5000-object
config sits: **the project's headline benchmark is measured at the worst
point of the curve.**

### Two hypotheses this killed, recorded so nobody re-runs them

- **Scan length in the bitmap was not the cost.** An ablation adding O(1)
  full detection and a resume hint to the scan gained 1.6% — noise. The 27%
  of samples on those lines were a *stall* on the bitmap's cache line, not
  loop iterations.
- **Metadata layout is not the cost.** `metadata_probe.cpp` isolates
  scattered per-block headers (ours) against one dense array (mimalloc's
  `mi_segment_t.slices[]`) under identical data traffic: 1.07 / 1.02 / 0.96 /
  1.11 / 0.98x across 20..1404 blocks. Noise. A dense per-region header array
  would buy nothing; it was proposed and dropped on this measurement.

## Fix 6 — `BLOCK_SIZE` 32 KB → 64 KB, and the churn was causal after all

Fix 5 left block-list churn as the open item and a 64 KB block as its
measured-but-unproven lever: block size moves **two** things at once — slots
per block (fewer full/not-full crossings) and block count (fewer headers) —
and nothing separated them.

They separate cleanly on the live-set axis, because churn itself does. At a
200-object live set the churn counters read 0.001 per alloc; at 5000 they
read 0.634. So: if churn is the mechanism, 64 KB must do **nothing** at 200
and a lot at 5000. If block count is, it should help at both, since 32 KB
still uses ~20 blocks at a 200-object live set.

| live bytes | churn/alloc, 32 KB | churn/alloc, 64 KB | 32 KB | 64 KB | gain |
|---|---|---|---|---|---|
| 98 KB | 0.001 | 0.000 | 6.10 ns | 6.14 ns | **0%** |
| 492 KB | 0.138 | 0.019 | 8.07 ns | 6.60 ns | +18% |
| 2.4 MB | 0.634 | 0.323 | 15.44 ns | 11.33 ns | +27% |
| 9.8 MB | 1.091 | 0.803 | 22.59 ns | 20.28 ns | +10% |

Zero churn, zero gain. **The mechanism is the churn; block count is not
it** — consistent with `metadata_probe.cpp` (fix 5), which found metadata
locality worth nothing on its own.

Landed. Real `larson 5 8 1000 5000 100 4141 1`, interleaved: ~37.4M ->
~45.6M ops/s, **1.52x -> 1.25x** slower than mimalloc. Cumulative with fix
5, from where this investigation started: **~27.0M -> ~45.6M, +69%, 2.11x ->
1.25x.** The gap-vs-working-set curve now reads 1.09 / 1.00 / 0.97 / 1.05 /
1.15 across 24 KB..9.8 MB — parity, where it was 1.74..2.35 before.

64 KB is also exactly mimalloc's small-page size
(`MI_SMALL_PAGE_SHIFT == MI_SEGMENT_SLICE_SHIFT`, verified in its headers),
which is not a coincidence worth ignoring: it faces the same trade-off.

### What it costs

A size class needs at least one whole block, so the footprint floor is
`classes_touched * BLOCK_SIZE` and doubling the block doubles the floor.
Measured resident (`blocks_probe.cpp`): 640 KB -> 1280 KB at a 24 KB live
set (+100%), 3392 KB -> 3776 KB at 2.4 MB (+11%), 11.7 MB -> 12.1 MB at
9.8 MB (+3%). It is a fixed per-class overhead, so it amortises away as the
working set grows; the worst case in absolute terms is under a megabyte.
The `empty_reserve` cap (one spare block per class) doubles with it too:
~1 MB -> ~2 MB in the fully degenerate case.

### Why `relink_unfull` is worth its cost, measured

`relink_unfull` inserts an unfulled block **behind** the head instead of at
it. Per event that is strictly more expensive: linking at the head writes
one foreign header (`head.prev`), inserting behind it reads `head.next` and
writes `head.next` and `second.prev` — three cold accesses against one. Once
fix 5's eager unlink guarantees the head always has room, the obvious guess
is that the cheap version is now good enough.

It is not. Reverting to link-at-head, everything else held:

| | churn/alloc @5000 live | larson |
|---|---|---|
| relink behind head | 0.323 | ~44.0M ops/s |
| link at head | **0.768** | **~34.5M ops/s (-21.7%)** |

Linking at the head installs a block with one free slot as the allocation
point; the next alloc drains it and it crosses the full line again
immediately. Churn **doubles**, and the rate swamps the per-event saving.

The rule this gives: **the event rate dominates the per-event cost.** Do not
optimise a churn operation without checking what it does to how often churn
happens.

### What churn actually costs — a bitmap over blocks buys nothing

Fix 5 left this as the obvious next move, reasoning that `link`/`unlink`
rewrite `prev.next` and `next.prev` — two *foreign* block headers, 64 KB
away, touched for nothing else — so replacing the `available` list with a
per-class "has room" bitmap (one hot word, `tzcnt` to pick, a bit to
set/clear, zero foreign headers) should remove that cost outright.

Built it in the real `Heap`: dense per-class block table, `has_room` /
`occupied` masks, `slot_idx` in the header, and a `current[ci]` allocation
point kept separate from the mask so a free cannot steal it (the lesson
from the link-at-head experiment above).

**Result: a tie.** +0.3% — noise.

| variant | churn events/alloc @5000 live | larson |
|---|---|---|
| linked list (current) | 0.323 | ~42.4M |
| bitmap over blocks | 0.291 | ~42.5M |

The bitmap does *fewer* events, each with no foreign-header traffic at all,
and buys nothing. Put that beside the other two churn results:

| change | churn events | throughput |
|---|---|---|
| bookkeeping made free (bitmap) | 0.323 → 0.291 | **0%** |
| events halved (64 KB block) | 0.634 → 0.323 | **+22%** |
| events doubled (link at head) | 0.323 → 0.768 | **−21.7%** |

Making an event cheaper: nothing. Changing how many events happen: ±22%.
So **the cost of churn is not the bookkeeping** — it is the block switch
itself. When the allocation point moves, the next block's header and its
free-list head are both loads this thread has not made recently. Both
designs pay that identically; the pointer updates are noise on top of it.

The premise was wrong in a specific, instructive way: those "cold foreign
headers" are not cold. A size class holds ~3 blocks at a 5000-object live
set, and its own allocations touch all three constantly, so all three
headers sit in L1. **Distance in the address space is not temperature** —
the cache holds what you touch, not what is nearby. `metadata_probe.cpp`
(fix 5) had already said exactly this about metadata layout, and the same
mistake was made again here.

Not landed: a tie that costs 32 KB per thread heap and imposes a hard
ceiling (`MAX_BLOCKS_PER_CLASS`) the linked list does not have is strictly
worse.

One incidental finding worth keeping: the first cut of this measured
**−15%**, and all of it was the block table being an inline
`[[*mut; 128]; 32]` — 32 KB sitting *between* the fields the hot path reads,
pushing `current` and `empty_reserve` 34 KB apart in a struct that had been
~530 bytes and one page. Boxing the table recovered every bit of it. Field
layout of a per-thread structure is worth 15% on its own.

### Unplanned: the cross-thread "known weakness" was never real

Re-running the benchmarks that fixes 5-6 invalidated — `mt_bench.rs` had
been left with numbers measured against the bitmap design — turned up
something nobody was looking for.

| pattern, 8 threads | recorded before | now |
|---|---|---|
| independent | ~11.5 vs ~12.0 — a tie | **~18.9 vs ~13.9 — +36% ahead** |
| bleeding (cross-thread) | ~19.6 vs ~23.1 — **mimalloc +15%** | **~34.2 vs ~24.4 — +40% ahead** |

`benches/RESULTS.md` and `heap.rs`'s module doc both recorded the
cross-thread deficit as "the real weakness", with a diagnosis (all
cross-thread frees funnel through **one** contended `remote_free` stack per
owner, where mimalloc shards per page) and a planned fix (per-destination
batching, snmalloc-style).

**Nothing on that path was touched by fixes 5-6.** `remote_free` is still
one atomic stack per owner. What changed is only what `drain_remote` does
once it has a slot: push onto a free list instead of dividing to find a
bitmap index, across half as many blocks. The contention was never the
bottleneck; the per-slot work on the owner's side was.

So the planned sharding is **not justified by any measurement we hold**, and
should not be built until something re-establishes a need. The diagnosis was
plausible, matched what mimalloc does, and was wrong — it was inferred from
a number, not measured.

### Prerequisite: `BLOCK_SIZE` had to become tunable first

`arena::tests::slow_path_takes_new_block_exactly_at_exhaustion` hardcoded
`4064` — "32512 payload / 8" — so it failed on any change to `BLOCK_SIZE`
with "block must be exactly full", which reads as an arena bug rather than a
stale literal. It now derives the count from `BLOCK_PAYLOAD` and asserts the
same property. Every other 32 KB mention in the tree was prose, not code;
those are corrected, and the comments that spelled the ABA tag as "15 bits"
now say it widens with `BLOCK_MASK`.

## Open items / notes for follow-up

Not done, in rough priority order:

- ~~**Division in `mark_free`**~~ — gone with the bitmap (fix 5a); a free
  list never computes a slot index.
- ~~**Remaining gap not fully attributed**~~ — done, fix 5. Both halves are
  now named and measured: path length (closed, parity at small working
  sets) and block-list churn (open, below).
- ~~**Block-list churn is what is left**~~ / ~~**`BLOCK_SIZE` is not
  tunable**~~ — both done, fix 6. Churn confirmed causal, block size raised
  to 64 KB, the arena test now derives its constant.
- ~~**stop threading `available` through the block headers**~~ — tried, ties,
  not landed (see "What churn actually costs" above). The bookkeeping was
  never the cost.
- **Churn is reduced, not gone** — still ~0.32 block switches per alloc at a
  5000 live set, and each one is a cold header plus a cold free-list head.
  The only lever that has ever moved this is **how often the allocation
  point changes**, so anything aimed at it must reduce that count, not make
  the switch cheaper. Untried: 128 KB blocks (halves switches again, but
  doubles the `classes_touched * BLOCK_SIZE` footprint floor a second time,
  and the gap at that live set is already 1.05x); keeping more than one
  block per class hot; sizing blocks per class rather than one constant for
  all 32.
- **The mid-curve rows are the ones to watch.** Every gain in fixes 5-6 came
  from 0.5-10 MB live sets; the small ones were already at parity and the
  huge ones were already ahead. Any future change should be judged on that
  band, and `scaling_probe.cpp` is the tool for it — a single larson run
  reports one point on that curve and hides the shape.
- **`#[cfg(not(windows))]` TLS path is unverified.** The portable
  `thread_local!` fallback for non-Windows targets has never been
  measured — no Linux/macOS benchmark run exists yet for this project.
  ELF `__thread` is expected to already be a single `%fs`-relative load
  (no module-indirection tax the way windows-msvc has), so the fast-TLS
  work from fix 3 may simply be unnecessary there, but this is an
  assumption, not a measurement.
- **jemalloc could not be added to any comparison in this investigation**
  — `tikv-jemalloc-sys`'s autotools `configure` fails to find a working
  C compiler when invoked from windows-msvc (confirmed independently,
  matches the note already in `Cargo.toml`). Would need MSYS2/WSL with
  a full mingw toolchain to include, which is a different ABI/build
  than what ships — not attempted.
- **Thread-exit abandonment remains unhandled** (pre-existing, not
  touched by this investigation) — see `heap.rs`'s module doc. A thread
  that exits with live heap blocks leaks them rather than having
  another thread adopt them (mimalloc does adopt). Fine for long-lived
  worker pools, not fine for short-lived-thread-per-task workloads.
- **Terminology note:** fix 1's "lazy (bump) slot carving" no longer
  exists in the code — fix 4 replaced the whole free/local_free/bump
  scheme with the bitmap. The *effect* fix 1 achieved (refill is O(1),
  not O(slots)) still holds under the bitmap design (initializing a
  bitmap to all-free is O(slots/64) words, cheaper still), but readers
  should not go looking for a `bump` field — it's gone.
