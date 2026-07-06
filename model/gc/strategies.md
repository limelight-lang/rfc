# GC Strategies: Pluggable Collection, Fixed Contract

## Decision

There is no universal GC. A short CLI script, a request-per-arena web
server, and a latency-sensitive long-running daemon want different
collectors. Limelight therefore treats the collector as a **pluggable
strategy behind a fixed contract**, selected **at build time**.

- The runtime and codegen define the contract (below) once.
- Each strategy implements the contract; the build selects the
  compiled-in set and the default. **Actors** may bind a different
  collector from that set per class —
  `#[Actor(gc: ...)]` ([actors.md](../../runtime/actors.md)); freely
  mixable as long as only the collector differs, not the store path.
- Because selection is at build time, the strategy's hot-path code is
  specialized and inlined — a NoGC or pure-RC build physically contains
  no flag checks or dispatch in its store paths. (Same approach as
  Ruby's modular GC.)

MMTK is **not** the foundation of this design — it is one backend that
can sit behind the contract (see the registry below).

---

## The Strategy Contract

Every strategy plugs into the same four interfaces. Nothing else in the
runtime or the generated code knows which strategy is active.

### 1. The unified store barrier slot

The compiler emits every reference store through a single hook:

```
ll_ref_store(slot, old_value, new_value)
```

Its body is composed at build time from up to three layers:

| Layer | Owner | Present |
|---|---|---|
| Category barrier (cross-arena check, remembered set) | arenas — strategy-independent | always ([arenas.md](../memory/arenas.md)) |
| RC operations (`retain(new)` / `release(old)`) | ARC | in every RC-based strategy, after compiler pairing elimination |
| Strategy hook (e.g. SATB deletion barrier) | active strategy | only if the strategy defines one |

The slot is the *only* door through which any strategy observes
reference mutation. Strategies with no hook (NoGC, pure RC,
stop-the-thread tracing) contribute zero instructions to it.

Objects whose lifetime the compiler schedules statically (tiers 1–2 of
[static-lifetimes.md](../memory/static-lifetimes.md)) bypass the
strategy entirely — no RC layer, no strategy hook; only the category
barrier remains where a cross-arena store is possible.

The COW check ([values.md](../values.md)) is *not* part of this slot —
it guards entity mutation, not reference stores, and is orthogonal to
the strategy.

### 2. Safepoints

Tracing strategies must observe thread stacks in a consistent state.
The compiler inserts **poll safepoints** (load a global flag + branch,
~1–3 cycles) at function entries and loop back-edges. At a safepoint
the thread's roots are enumerable.

- Strategies that never stop threads and never scan stacks (NoGC, pure
  RC) compile the poll away entirely — build-time selection again.
- These are cheap poll safepoints, **not** LLVM statepoints. The
  non-moving decision ([heap-design.md](heap-design.md)) stands:
  objects never relocate, so no stack maps or `gc.relocate` plumbing.

### 3. General-heap allocation

The strategy owns the allocator for the `GcHeap` memory category only.
Request and long-lived arenas allocate independently of the strategy
([arenas.md](../memory/arenas.md)) and are **invisible to it** — no
strategy scans or collects arena objects.

### 4. Object metadata and teardown

Strategies consume, not define, the object model:

- `RcHeader` flags and refcount ([object-lifecycle.md](../../runtime/object-lifecycle.md))
- class `prop_layout.refcounted_slots()` for tracing object children
- the three-phase teardown (`__destruct` with resurrection check →
  drop → memory release); a strategy that proves an object garbage
  enters teardown at phase 1 like any refcount death

## Constraint: non-moving only

Per [heap-design.md](heap-design.md), objects never relocate. A
strategy (or MMTK plan) that moves objects does not fit the contract.
Arena-reset evacuation is not an exception — it is an arena-boundary
event with no live stack, outside any strategy
([arena-reset.md](../memory/arena-reset.md)).

---

## Strategy Registry

| Strategy | Composition | Cycles | Pauses | Use case |
|---|---|---|---|---|
| `nogc` | bump allocation, never frees | leaks | none | benchmarks baseline; short scripts |
| `rc` | ARC + arenas | **leaks cycles** | none | short CLI where cycles don't accumulate |
| `rc-trace` **(default)** | ARC + arenas + stop-the-thread cycle tracing | collected | small, bounded by live general heap | web workloads; the first implementation |
| `rc-satb` | ARC + arenas + concurrent SATB marking | collected | near-zero | latency-sensitive daemons — see [satb.md](satb.md) |
| `mmtk:<plan>` | MMTK backend via `VMBinding` adapter | per plan | per plan | experimentation; non-moving plans only |

`nogc` is what the echo compiler ships today; `rc` is approximately
elephc's model; `rc-trace` is the Zend architecture done right
(RC + cycle collection, plus arenas and compiler ARC elimination).

---

## The default: `rc-trace`

1. **ARC is the primary reclamation path.** Refcount hits zero →
   immediate, deterministic teardown. Compiler pairing elimination,
   immortal flags, arena scoping per
   [arc-optimizations.md](../memory/arc-optimizations.md).
2. **Arenas absorb the bulk.** Request-scoped objects carry no
   refcounts and die in O(1) at arena reset — the tracer never sees
   them.
3. **Stop-the-thread tracing collects cycles only.** Triggered by
   threshold (candidate-root buffer fill, as Zend's 10K, to be
   calibrated). The thread parks at a safepoint; the marker traces the
   general heap from roots; unmarked refcounted islands are cycles —
   freed through normal teardown. The pause is proportional to the
   *live general heap*, which arenas keep small.

Because the mutator is parked while marking runs, `rc-trace` needs
**no store-barrier hook, no snapshot, no mark-phase coordination** —
the graph cannot change under the marker. That simplicity is why it is
first.

## The flagship against pauses: `rc-satb`

Same composition, one substitution: marking runs **concurrently** with
the mutator, and correctness during marking is maintained by an SATB
deletion barrier in the store slot. Design: [satb.md](satb.md).

The GC/mutator coordination machinery in
[heap-design.md](heap-design.md) — the lock-free CAS handoff and the
deferred-free bit — belongs to this strategy: those races only exist
when the mutator runs during a collection cycle.
