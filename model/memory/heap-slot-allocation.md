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
