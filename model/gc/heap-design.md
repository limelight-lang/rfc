# GC Heap Design Decisions

> The collector itself is a pluggable build-time strategy; see
> [strategies.md](strategies.md). This document owns the decisions that
> hold across strategies (non-moving, block/line heap structure) and
> the coordination machinery used by the concurrent strategy
> ([satb.md](satb.md)).

## Object Movement: Non-Moving

**Decision**: Limelight uses a non-moving GC. An object reached by a direct pointer is never relocated after allocation; its address is stable for the object's lifetime. The one exception is an object held behind a **movable proxy** or inside a memory-managing container ([classes.md](../classes.md), "The Proxy family"): there every access already goes through the handle, so the target may relocate without invalidating a raw pointer. That is the only movement the runtime performs.

**Why:**
- No statepoints, no `gc.relocate`, no stack maps required: significant reduction in LLVM IR complexity
- No read barriers or write barriers for relocation
- CPython, PHP (Zend), and Ruby all use non-moving GC successfully in production

**Fragmentation:** handled by the size-class block heap:
- A freed slot returns to its block's free list and is reused by the next allocation of that size class — no external fragmentation within a class
- Fully empty blocks are returned to the pool and can be re-served to any class
- Objects above the small-object limit (8 KB) get a dedicated pooled block; above a block payload, an OS-direct block-aligned run

Size classes bound internal fragmentation to the class step, and block-level reuse bounds the external kind, so no compaction is needed.

---

## MMTK: One Available Backend

**Decision (revised)**: MMTK is **not** the foundation; it is one
pluggable backend behind the strategy contract (`mmtk:<plan>` in
[strategies.md](strategies.md)), restricted to non-moving plans.
Limelight's own strategies (`rc-trace`, `rc-satb`) own their heap
directly; the block/line structure below is shared vocabulary either
way.

MMTK is a Rust-based framework that provides production-quality GC plans including Immix, StickyImmix, ConcurrentImmix, and LXR.

**Why MMTK as a backend:**
- Written in Rust: natural fit for the Limelight stack
- Implements all chosen algorithms out of the box
- Used in production: OpenJDK, Ruby 3.4, Julia
- Actively maintained by ANU + Shopify + Red Hat
- Provides a C API via `cbindgen`, callable from LLVM IR and C++

**Integration path**: implement the `VMBinding` Rust trait; it describes how to scan Limelight objects, enumerate roots, and handle finalizers. Reference implementations: [mmtk-ruby](https://github.com/mmtk/mmtk-ruby), [mmtk-julia](https://github.com/mmtk/mmtk-julia).

**Links:**
- Homepage: https://www.mmtk.io
- Core (Rust): https://github.com/mmtk/mmtk-core
- Ruby binding (reference): https://github.com/mmtk/mmtk-ruby
- Julia binding (reference): https://github.com/mmtk/mmtk-julia
- Status / supported plans: https://www.mmtk.io/status

---



## Heap Structure: aligned blocks (no global object list)

**Decision**: Limelight does not maintain a global linked list of objects. The heap structure itself serves as the object enumeration mechanism.

The heap is divided into fixed-size **blocks** (64 KB, aligned to their size), carved from 2 MB OS regions; a block serves one size class, and its first 256 bytes hold the block header. The GC enumerates all live objects by linearly scanning blocks: no separate list required.

**Why:**
- A global intrusive linked list is shared mutable state: it requires synchronization on every allocation and free.
- Linear block traversal is cache-friendly: scanning a block = sequential memory reads. A linked list of heap objects scattered across memory causes pointer-chasing cache misses.
- Block boundaries are computable from any pointer (mask off the low 16 bits): the GC always knows which block an object belongs to without a lookup.

Block-scanning enumeration is the standard modern arrangement (MMTk and the collectors built on it work this way). Global object lists (as in Boehm GC, early PHP) are considered obsolete for this reason.

---

## GC / Mutator Coordination: Lock-Free CAS Handoff

**Scope**: this machinery belongs to the **concurrent strategy**
(`rc-satb`, [satb.md](satb.md)); it exists only when the mutator runs
during a collection cycle. Under the default `rc-trace` the mutator is
parked at a safepoint while marking runs, and none of these races occur.

**What it does and does not solve**: the CAS handoff resolves the
*delete-vs-scan* race (mutator freeing an object the marker is
scanning). It does **not** maintain the tri-color invariant of
concurrent marking: a mutator can hide a live object from the marker
without ever touching a state field. That correctness problem is owned
by the SATB deletion barrier ([satb.md](satb.md)). The two mechanisms
are complementary, not alternatives.

**Decision**: GC and mutator coordinate ownership of objects via a single atomic CAS on the object's state field. Neither side waits for the other.

### Protocol

Each object has an atomic state field with four values: `LIVE`, `SCANNING`, `DEAD`, and `OWNED`. The handoff below is between `LIVE` objects. `OWNED` marks a heap object captured by an arena/actor; because both CAS operations start from `LIVE`, an `OWNED` object fails both and is skipped by collector and mutator alike — its lifetime is the owner's until it escapes to shared and is re-armed to `LIVE`.

```
Mutator (deleting):              GC (scanning):
CAS(obj.state, LIVE → DEAD)      CAS(obj.state, LIVE → SCANNING)

Success → mutator owns the        Success → GC owns the object,
object, proceeds with free.       proceeds with scan.

Failure → GC got there first,     Failure → mutator got there first,
mutator steps back.                GC skips the object.
```

One CAS determines the winner. No locks, no barriers, no waiting.

### Why this works with block scanning

Because the GC enumerates objects by scanning blocks linearly, it encounters objects in a predictable, localized order. Contention between the GC and the mutator is low: the GC visits each object once per collection cycle, and the mutator deletes objects on its own schedule. The probability of simultaneous CAS on the same object is proportional to GC frequency × mutator delete rate, which is small in practice.

### Cost

- Uncontended CAS: ~10–40 cycles
- Contended CAS (rare): ~100–300 cycles + cache line bounce

For typical PHP workloads where GC cycles are infrequent relative to mutator activity, contention is low and CAS is cheap. (This is not a substitute for the SATB deletion barrier, see the scope note above; they guard different races.)

### What happens when GC wins but object becomes unreachable during scan

The GC completes its scan of the object, then checks reachability. If the object is unreachable (refcount dropped to zero or no tracing paths reach it), the GC enqueues it for deferred reclamation. The mutator does not need to be involved: it already stepped back from the CAS.

---

## Deferred Free via GC Activity Bit

**Decision**: The memory manager checks a single global bit set by the GC. When the bit is 1 (GC cycle active), physical memory is not released immediately: frees are queued. When the bit returns to 0 (cycle complete), the queue is flushed and memory is reclaimed.

### Protocol

```
GC starts cycle:   bit → 1
GC ends cycle:     bit → 0, flush deferred queue

Memory manager on free:
  if bit == 0 → release immediately
  if bit == 1 → push to deferred queue
```

### Cost

- One `load` + `branch` per free: ~1–3 cycles
- Compared to per-object CAS (~10–40 cycles): an order of magnitude cheaper

### Queue growth

While the bit is 1, freed objects accumulate in the deferred queue and their memory is not reclaimed. Queue growth is bounded by limiting GC cycle length: short cycles keep the queue small.

### Relationship to CAS handoff

These two mechanisms are complementary:
- **CAS** determines *who decides* the fate of an object (mutator or GC)
- **Deferred free bit** determines *when physical memory is actually released*

A mutator can win the CAS and mark an object `DEAD` during a GC cycle, but the memory manager will defer the actual release until the cycle ends. This keeps the GC's view of the heap consistent throughout the cycle without per-object coordination.
