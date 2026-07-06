# GC Research: ARC, Cycle Collection, and Hybrid Strategies for Limelight

> **Status: research.** The survey below stands, but the
> recommendation in §7 has been superseded by decisions:
> the collector is a pluggable build-time strategy
> ([strategies.md](strategies.md)); the default is `rc-trace`
> (ARC + arenas + stop-the-thread cycle tracing), with concurrent SATB
> as the low-latency strategy ([satb.md](satb.md)); MMTK is one
> backend, not the foundation; LLVM statepoints are ruled out by the
> non-moving decision ([heap-design.md](heap-design.md)), cheap poll
> safepoints suffice. The Phase 1→2→3 ladder maps onto the strategy
> registry rather than onto successive rewrites of a single collector.

---

## 1. Swift ARC — Low-Level Mechanics

### Object Header Layout

Every heap-allocated Swift object has a 16-byte header (`HeapObject`):

| Offset | Size | Field |
|--------|------|-------|
| 0 | 8 B | Metadata pointer (`isa`) — points to type descriptor |
| 8 | 8 B | `InlineRefCounts` — packed 64-bit bitfield |

`InlineRefCounts` bit layout:

| Bits | Meaning |
|------|---------|
| 0 | Pure Swift dealloc flag |
| 1–31 | Unowned reference count |
| 32 | IsDeiniting flag |
| 33–62 | Strong extra refcount (off-by-one: logical count 1 = bits 0) |
| 63 | Use slow RC flag (triggers side table allocation) |

The off-by-one optimization means the initial refcount of 1 requires no bit writes at allocation time.

### Side Tables

Allocated on demand when:
- A `weak` reference to an object is created for the first time
- Inline counts overflow

Weak references point to the side table, not the object. This allows the `HeapObject` memory to be freed when the strong count reaches zero, while weak references can still observe the nil state via the side table.

### ARC Performance Cost

- Retain/release = atomic fetch-add/sub on the inline refcount
- Uncontended atomic on Apple Silicon: ~1–3 ns
- Contended (shared across threads): 70+ cycles minimum
- Objects shared across threads are significantly more expensive than thread-local ones

### ARC Compiler Optimizations

Swift's ARC optimizer runs at SIL (Swift Intermediate Language) level:

- **RC Identity Analysis**: identifies SSA values that represent the same refcount, allowing paired retain/release elimination
- **ARCOpt**: forward scan that pairs retains with releases and eliminates them when code in between cannot trigger a release
- **OwnershipModelEliminator**: converts ownership-aware SIL to conventional SIL with explicit retain/release

At LLVM IR level, `swift_retain()` is annotated `NoModRef` (no memory side effects), enabling aggressive reordering. `swift_release()` cannot get this annotation because it can invoke `deinit()`.

### Cycle Handling

Swift does **not** collect cycles automatically. The programmer must break cycles manually using `weak` or `unowned` references. This is acceptable for Apple frameworks but incompatible with PHP semantics where users cannot be forced to declare weak references.

---

## 2. PHP Zend Engine Reference Counting

### zval Layout (PHP 7+)

```c
struct _zval_struct {
    zend_value value;      // 8 bytes — union (long, double, pointer, ...)
    uint32_t   type_info;  // type (u8) + type_flags (u8) + const_flags (u8)
    uint32_t   var_flags;  // context-dependent
};
// Total: 16 bytes
```

The zval itself holds no refcount. The refcount lives inside the heap allocation pointed to by `value`.

### Common Refcounted Header

Every refcounted type begins with:

```c
struct _zend_refcounted_h {
    uint32_t refcount;
    uint32_t type_info;  // type (u8) + flags (u8) + gc_info (u16)
};
```

`gc_info` (16 bits) encodes the GC color and buffer index used by the cycle collector.

### Key Flags

- `IS_TYPE_REFCOUNTED`: set when the zval type requires reference counting. Scalars (int, float, bool, null) never set this — no counting overhead.
- `IS_TYPE_COLLECTABLE`: set for types that can form cycles: objects and arrays. Only these are added to the cycle collector root buffer.

### Copy-on-Write

Arrays and strings use COW. When a value with `refcount > 1` is about to be modified, a full copy is made and the original's refcount is decremented. The modifying variable takes exclusive ownership. Objects are never COW — they always use reference semantics.

COW check: `if (refcount > 1) { separate(); }`

### Known Performance Bottlenecks

- Every assignment or argument pass involving a refcounted type writes a refcount. No atomics (PHP is single-threaded per request), but the conditional + memory write adds up.
- The root buffer check on every non-zero decrement: one conditional branch + potential pointer write per decrement of any object or array.
- Large arrays modified inside a function trigger a full hashtable copy if `refcount > 1`.
- `zend_reference` wrappers (for `&` variables) add a permanent extra level of indirection.

---

## 3. Bacon-Rajan Cycle Collector

**Paper**: "Concurrent Cycle Collection in Reference Counted Systems," David F. Bacon & V.T. Rajan, ECOOP 2001.
Available: https://pages.cs.wisc.edu/~cymen/misc/interests/Bacon01Concurrent.pdf

### Core Insight

Garbage cycles can only arise from a **non-zero decrement**. When a decrement takes refcount to zero, the normal free path handles it. When a decrement leaves a nonzero count, the object *might* be the root of a garbage cycle.

### Color Scheme

| Color | Meaning |
|-------|---------|
| Black | In use, not garbage |
| Gray | Possible cycle member under investigation |
| White | Confirmed garbage |
| Purple | Possible cycle root (was non-zero decremented) |

### Algorithm (Synchronous Version — PHP's Implementation)

**Step 1 — Mark gray** (DFS from each root in the buffer):
- Decrement refcount of every reachable object by 1
- Mark as gray

This simulates: "what if all references were only from inside the cycle?"

**Step 2 — Scan**:
- `refcount == 0`: mark white (garbage candidate)
- `refcount > 0`: mark black (still externally referenced) + restore all decrements in reachable subgraph

**Step 3 — Collect white**:
- All white objects are garbage
- Run destructors, then free memory

**Performance**: O(n) in collectable objects reachable from the root buffer. PHP's root buffer capacity: 10,000 objects. GC adds ~7% overhead when enabled.

The original paper also describes a **concurrent version** where the mark-gray phase runs concurrently with the mutator using a heap snapshot, reducing pause times to near-zero. PHP implements only the simpler synchronous version.

---

## 4. ARC + GC Hybrid: Theory and Practice

### The Core Problem

ARC cannot reclaim reference cycles. A tracing GC can. The natural solution is a hybrid: ARC handles the fast path (immediate reclamation of acyclic objects), tracing handles cycles.

### CPython: Refcount + Generational Cycle Detector

The original production ARC+GC hybrid. Every container object (list, dict, class instance) carries a 24-byte `PyGC_Head` prepended to the standard `PyObject`. Scalar types (int, str, float) do not pay this cost.

Generational cycle detector runs:
1. Copy `ob_refcnt` into scratch `gc_refs` for each object in the generation
2. For each object, decrement `gc_refs` of each referenced object
3. Objects with `gc_refs > 0` after this: reachable from outside, mark as such transitively
4. Objects at `gc_refs == 0`: unreachable — collected

Stop-the-world, runs only on one generation at a time.

### LXR: Deferred ARC + Immix + SATB (PLDI 2022)

The state-of-the-art ARC+GC hybrid. Paper: "Low-Latency, High-Throughput Garbage Collection," Zhao et al., PLDI 2022.
https://arxiv.org/abs/2210.17175

**Key innovations:**

1. **Temporal coarsening (deferred refcount)**: within a GC epoch, only the first and last write to a field update the refcount. All intermediate writes are elided. This eliminates the majority of refcount traffic.

2. **Stack deferral**: stack/local variable pointers are not counted continuously. At epoch start the GC scans roots and increments counts; at epoch end it decrements. Eliminates the dominant source of refcount traffic (local variable scoping).

3. **2-bit saturating counters**: because temporal coarsening produces small net counts per epoch, 2 bits are sufficient for most objects. Objects whose count saturates become "sticky" and are managed by the tracing component.

4. **Concurrent SATB tracing**: periodic background tracing using Snapshot At The Beginning. Handles cycles and stuck objects. Since LXR already maintains the root-reachable set for stack deferral, SATB adds minimal extra complexity.

5. **Immix heap**: cache-friendly 32KB block / 256B line structure for both allocation and collection.

**Results**: outperforms both G1 and Shenandoah in throughput and latency on DaCapo benchmarks.

### Tradeoff Summary

| Strategy | Cycle Safety | Pause Times | Throughput Overhead | Complexity |
|----------|-------------|-------------|---------------------|------------|
| Pure ARC (Swift) | Manual only | None | ~5–15% (atomics) | Low |
| ARC + sync cycle collector (PHP) | Automatic | Occasional small | ~7–10% | Medium |
| ARC + concurrent cycle collector | Automatic | Near-zero | ~7–10% | High |
| Pure tracing GC (V8) | Automatic | STW pauses | ~0–5% (write barriers) | High |
| LXR (deferred ARC + Immix + SATB) | Automatic | Near-zero | Very low | Very High |

---

## 5. Ready-Made GC Libraries

### MMTK (Memory Management Toolkit)

https://www.mmtk.io / https://github.com/mmtk/mmtk-core

A Rust-based framework for building GC subsystems. Used in OpenJDK, Ruby 3.4, Julia.

**Available GC plans:**

| Plan | Description |
|------|-------------|
| `NoGC` | Never collects — for baselines |
| `MarkSweep` | Classic non-moving mark-sweep |
| `MarkCompact` | LISP2-style mark-compact |
| `SemiSpace` | Classic copying collector |
| `Immix` | Mark-region (32KB blocks / 256B lines) |
| `GenImmix` | Generational Immix |
| `StickyImmix` | Immix with sticky bits for generational without full promotion |
| `ConcurrentImmix` | Concurrent marking variant |
| `LXR` | Deferred ARC + Immix + SATB (see above) |

**Embedding**: Language VMs implement the `VMBinding` Rust trait (object scanning, root enumeration, finalizer handling). Use `cbindgen` to generate a C header for C/C++ runtimes. The Ruby (`mmtk-ruby`) and Julia integrations are good references.

### Immix Algorithm

**Paper**: "Immix: A Mark-Region Garbage Collector with Space Efficiency, Fast Collection, and Mutator Performance," Blackburn & McKinley, PLDI 2008.
https://www.steveblackburn.org/pubs/papers/immix-pldi-2008.pdf

**Heap structure**: 32KB aligned blocks, each divided into 128 lines of 256 bytes. Allocation uses a bump pointer within a block. When a block is exhausted, a new one is requested from the global block pool.

**Why cache-friendly**: objects allocated in sequence reside in sequence in memory. A 32KB block fits comfortably in L2 cache. Object traversal during GC and object access during the mutator tend to hit the same block.

**Collection**: mark in place by default (no movement, no forwarding pointers). Opportunistic evacuation kicks in when fragmentation exceeds a threshold, compacting fragmented blocks into fresh ones.

**Performance**: 7–25% improvement over canonical algorithms in the original paper across 20 JVM benchmarks.

### Boehm-Demers-Weiser GC

Conservative mark-sweep for C/C++. Not recommended for Limelight: it cannot move objects, cannot compact, and throws away the precise type information available in LLVM IR. Suitable for retrofitting GC into legacy C codebases, not for a new precise runtime.

### Deferred Reference Counting

Origin: Deutsch & Bobrow, 1976.

**Key insight**: most refcount mutations come from local/temporary pointers (stack), not from long-lived heap-to-heap pointers. Stack → heap references can be counted lazily via a root scan at epoch boundaries instead of continuously.

**Effect**: reduces refcount operations by up to 80%. LXR's "temporal coarsening" is a modern generalization of this principle.

---

## 6. State-of-the-Art Fast GC (2025–2026)

### Shenandoah (OpenJDK)

Concurrent compaction using **Brooks pointers** — an extra forwarding word in every object header. When GC relocates an object, it updates the Brooks pointer. A **read barrier** on every object load checks the forwarding pointer and redirects to the new address. Pause times: 1–5 ms typical.

### ZGC (OpenJDK)

**Colored pointers** — GC metadata (mark bits, relocation bits) encoded in the high bits of 64-bit pointers. A load barrier strips the color and updates the reference if the object was relocated. No forwarding word in the object header. Pause times: 0.1–0.5 ms, sub-millisecond achievable.

### Azul C4 (Continuously Concurrent Compacting Collector)

Proprietary. **Loaded Value Barrier (LVB)** — self-healing read barrier that repairs references in-place when the mutator loads a relocated object. True pauseless: no stop-the-world fallback. Pause times: sub-millisecond, most consistent of any JVM GC.

### Oilpan / cppgc (V8/Chromium)

A C++ GC library available standalone. Requires explicit `Member<T>` smart pointers and objects inheriting from `GarbageCollected<T>`. Precise for heap references, conservative for stack. Incremental marking interleaved with the event loop. Thread-local heaps allow concurrent mutators. Available at https://github.com/oilpan-gc/cppgc.

---

## 7. Recommendation for Limelight

### Why Pure ARC is Ruled Out

PHP programmers routinely create cyclic object graphs: doubly-linked lists, trees with parent pointers, event listeners, observer patterns. Unlike Swift, you cannot force PHP users to declare `weak` references — it would break PHP compatibility. Pure ARC will leak in all real PHP applications.

### Recommended Strategy: Deferred ARC + Immix + Concurrent Cycle Collection

Targeting the LXR architecture, implemented incrementally via MMTK.

**Phase 1 — Correct and faster than PHP:**

- Use MMTK's `Immix` plan as the heap allocator. Replace `malloc` entirely. Bump-pointer allocation from thread-local blocks is comparable to stack allocation throughput.
- Implement retain/release as LLVM IR calls: `@limelight_retain(%obj)` / `@limelight_release(%obj)`. Apply ARC-style pairing elimination in LLVM passes (modeled after Swift's ARC optimizer or clang's ObjC ARC pass).
- Run Bacon-Rajan synchronously when the root buffer fills (10K entries threshold).
- COW arrays: `if (refcount > 1) { separate(); }` — unchanged from PHP semantics.

**Phase 2 — Low-latency:**

- Switch to MMTK's `StickyImmix` or `ConcurrentImmix` plan for concurrent background marking.
- Introduce **LLVM statepoints** (`RewriteStatepointsForGC` pass + `gc.statepoint` intrinsics, `addrspace(1)` for GC-managed pointers). This enables precise root enumeration at every GC safepoint without conservative scanning.
- Replace synchronous Bacon-Rajan with concurrent SATB tracing.
- Introduce stack deferral: local variables do not update refcounts continuously. At each safepoint, the root set is scanned explicitly.

**Phase 3 — Full LXR:**

- Implement 2-bit saturating counters and temporal coarsening per the LXR paper.
- Objects with saturated counts are promoted to the tracing component.
- This eliminates the majority of remaining refcount traffic.

### What Not to Use

- **Pure ARC**: PHP cycles will leak. Hard no.
- **Boehm GC**: conservative, cannot compact, wastes LLVM's precise type info.
- **Pure stop-the-world tracing GC**: COW semantics interact badly with GC pauses (a pause during array modification can cause spurious separations). Also, immediate reclamation of short-lived objects is lost.

---

## Key Papers

| Paper | Why |
|-------|-----|
| Bacon & Rajan, ECOOP 2001 | The cycle collector algorithm |
| Blackburn & McKinley, PLDI 2008 | Immix heap design |
| Zhao et al., PLDI 2022 | LXR: ARC + Immix + SATB |
| LLVM Statepoints docs | Precise GC in LLVM IR |
| Nofl, arxiv 2025 | Immix refinement for compact objects |

---

## References

- [Swift ARC Internals — Jacob's Tech Tavern](https://blog.jacobstechtavern.com/p/swift-reference-counting)
- [ARC Optimization for Swift](https://apple-swift.readthedocs.io/en/latest/ARCOptimization.html)
- [Internal value representation in PHP 7 — Nikita Popov](https://www.npopov.com/2015/05/05/Internal-value-representation-in-PHP-7-part-1.html)
- [PHP: Collecting Cycles — PHP Manual](https://www.php.net/manual/en/features.gc.collecting-cycles.php)
- [Bacon & Rajan, ECOOP 2001 (PDF)](https://pages.cs.wisc.edu/~cymen/misc/interests/Bacon01Concurrent.pdf)
- [CPython GC internals — Python Developer's Guide](https://devguide.python.org/garbage_collector/)
- [MMTK status page](https://www.mmtk.io/status)
- [Ruby 3.4 Modular GC + MMTK — Rails at Scale](https://railsatscale.com/2025-01-08-new-for-ruby-3-4-modular-garbage-collectors-and-mmtk/)
- [Immix paper, PLDI 2008](https://www.steveblackburn.org/pubs/papers/immix-pldi-2008.pdf)
- [LXR paper, arxiv](https://arxiv.org/abs/2210.17175)
- [Nofl: A Precise Immix, arxiv 2025](https://arxiv.org/html/2503.16971)
- [LLVM Statepoints](https://releases.llvm.org/8.0.0/docs/Statepoints.html)
- [Oilpan / cppgc — V8 Blog](https://v8.dev/blog/oilpan-library)
- [ZGC vs Shenandoah 2025](https://www.javacodegeeks.com/2025/04/zgc-vs-shenandoah-ultra-low-latency-gc-for-java.html)
- [C4: The Continuously Concurrent Compacting Collector](https://dl.acm.org/doi/10.1145/1993478.1993491)
