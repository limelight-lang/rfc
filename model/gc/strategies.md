# GC Strategies: Pluggable Collection, Fixed Contract

## Decision

There is no universal GC. A short CLI script, a request-per-arena web
server, and a latency-sensitive long-running daemon want different
collectors. Limelight therefore treats the collector as a **pluggable
strategy behind a fixed contract**, selected **at build time**.

- The runtime and codegen define the contract (below) once.
- Each strategy implements the contract; the build selects the
  compiled-in set and the default. **Actors** may bind a different
  collector from that set per class via `#[Actor(gc: ...)]`
  ([actors.md](../../runtime/actors.md)); freely mixable as long as
  only the collector differs, not the store path.
- Because selection is at build time, the strategy's hot-path code is
  specialized and inlined: a NoGC or pure-RC build physically contains
  no flag checks or dispatch in its store paths. (Same approach as
  Ruby's modular GC.)

MMTK is **not** the foundation of this design; it is one backend that
can sit behind the contract (see the registry below).

---

## The Strategy Contract

Every strategy plugs into the same four interfaces. Nothing else in the
runtime or the generated code knows which strategy is active.

### 1. The unified store barrier slot

The compiler emits every reference store through a single hook:

```
ll_ref_store(ctx, dst_owner, slot: *Value, old_entity, new_value: Value)
```

The two value arguments are deliberately asymmetric. `new_value` is the
whole 16-byte `Value` and the barrier writes it — one slot has one
writer, and a caller stamping the tag afterwards would leave the slot
torn for the length of the call. `old_entity` is only the entity the
slot currently holds (null when it holds a scalar), because that is all
the counting needs and the caller already has it loaded.

`dst_owner` is the entity containing `slot`: a slot has no header of
its own, so the destination's category is read from its owner's flags —
and the generated code has the owner in a register anyway (it just
computed `slot` from it). `ctx` supplies the arena whose escape and
release-at-reset logs the barrier writes: one mounted arena per executing
context, kept correct by the compiler (actor arenas are unreachable
from outside, so an escape-creating store always runs with the owner's
arena mounted).

Its body is composed at build time from up to three layers:

| Layer | Owner | Present |
|---|---|---|
| Category barrier (cross-arena check, escape count + release log) | arenas, strategy-independent | always ([arenas.md](../memory/arenas.md)) |
| RC operations (`retain(new)` / `release(old)`) | ARC | in every RC-based strategy, after compiler pairing elimination |
| Strategy hook (e.g. SATB deletion barrier) | active strategy | only if the strategy defines one |

The slot is the *only* door through which any strategy observes
reference mutation. Strategies with no hook (NoGC, pure RC,
stop-the-thread tracing) contribute zero instructions to it.

Objects whose lifetime the compiler schedules statically (tiers 1–2 of
[static-lifetimes.md](../memory/static-lifetimes.md)) bypass the
strategy entirely: no RC layer, no strategy hook; only the category
barrier remains where a cross-arena store is possible.

The COW check ([values.md](../values.md)) is *not* part of this slot:
it guards entity mutation, not reference stores, and is orthogonal to
the strategy.

### 2. Safepoints

Tracing strategies must observe thread stacks in a consistent state.
The compiler inserts **poll safepoints** (load a global flag + branch,
~1–3 cycles) at function entries and loop back-edges. At a safepoint
the thread's roots are enumerable.

The poll has a second duty that is not about tracing at all: it refills
the block reserve the store barrier's log growth draws on
([exceptions.md](../../runtime/exceptions.md), "The log reserve
protocol"). That is what converts a failure the barrier cannot report
into an ordinary exception raised at the next poll — so poll density is
a correctness input for the barrier, not only a latency knob for the
collector.

- Strategies that never stop threads and never scan stacks (NoGC, pure
  RC) compile the poll away entirely; build-time selection again.
- These are cheap poll safepoints, **not** LLVM statepoints. The
  non-moving decision ([heap-design.md](heap-design.md)) stands:
  objects never relocate, so no stack maps or `gc.relocate` plumbing.

### 3. General-heap allocation

The strategy owns the allocator for the `GcHeap` memory category only.
Request and long-lived arenas allocate independently of the strategy
([arenas.md](../memory/arenas.md)) and are **invisible to it**: no
strategy scans or collects arena objects.

### 4. Object metadata and teardown

Strategies consume, not define, the object model:

- `RcHeader` flags and refcount ([object-lifecycle.md](../../runtime/object-lifecycle.md))
- class `prop_layout.refcounted_slots()` for tracing object children
- the three-phase teardown (`__destruct` with resurrection check →
  drop → memory release). A strategy that proves an object garbage may
  free it directly instead of entering teardown — today's `rc-trace`
  does, and the missing `__destruct` for cyclic garbage is a known gap
  (BACKLOG). What such a strategy still owes is the bookkeeping teardown
  would have done: above all, dropping the escape hold-count of every
  request-arena entity the dead holder referenced, since arena entities
  are invisible to the trace and nothing else will

## Constraint: non-moving only

Per [heap-design.md](heap-design.md), objects never relocate. A
strategy (or MMTK plan) that moves objects does not fit the contract.
Arena-reset evacuation is not an exception: it is an arena-boundary
event with no live stack, outside any strategy
([arena-reset.md](../memory/arena-reset.md)).

---

## Strategy Registry

| Strategy | Composition | Cycles | Pauses | Use case |
|---|---|---|---|---|
| `nogc` | bump allocation, never frees | leaks | none | benchmarks baseline; short scripts |
| `rc` | ARC + arenas | **leaks cycles** | none | short CLI where cycles don't accumulate |
| `rc-trace` **(default)** | ARC + arenas + stop-the-thread cycle tracing | collected | small, bounded by live general heap | web workloads; the first implementation |
| `rc-satb` | ARC + arenas + concurrent SATB marking | collected | near-zero | latency-sensitive daemons, see [satb.md](satb.md) |
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
   refcounts and die in O(1) at arena reset; the tracer never sees
   them.
3. **Stop-the-thread tracing collects cycles only.** *Armed* by a
   threshold (candidate-root buffer fill, as Zend's 10K, to be
   calibrated) but *fired* only at a clean point (see [Triggering:
   arm vs fire](#triggering-arm-vs-fire) below). At the fire point the
   thread is parked at a safepoint; the marker traces the general heap
   from roots; unmarked refcounted islands are cycles and are freed
   through normal teardown. The pause is proportional to the *live
   general heap*, which arenas keep small.

Because the mutator is parked while marking runs, `rc-trace` needs
**no store-barrier hook, no snapshot, no mark-phase coordination**:
the graph cannot change under the marker. That simplicity is why it is
first.

### Triggering: arm vs fire

Cycle collection reads refcounts against the physical object graph and
frees what the two agree is unreachable. It may therefore run **only
where refcounts and edges agree** — between mutator operations, after
the current store or teardown has completed. This is a *correctness*
requirement, not a tuning choice.

The failure it rules out is concrete. A reference store
(`$box->slot = null`) lowers the old value's refcount *before* it
overwrites the pointer; for that instant the count says "one fewer
reference" while the pointer is still physically in the slot. A
collection that runs in that window walks the stale edge and subtracts
that same reference a second time, drives a still-live object to
refcount 0, and frees it out from under its remaining holder. The same
window opens mid-teardown (a child release during phase 2) and mid-reset.

So the trigger splits in two, and only the runtime half is fixed:

- **Arm (runtime mechanics).** A non-zero decrement buffers a candidate
  root; crossing the threshold sets a *pending* flag. It runs from
  inside `ll_release`, i.e. mid-mutation, so it **never runs the
  collector** — it only records that one is due. The candidate buffer
  itself is always maintained (the collector needs it to know what to
  trace), even when no automatic trigger is configured.
- **Fire (compiler policy).** The collector runs only at a **clean
  point** the compiler chooses: an explicit `ll_gc_collect_cycles`, or a
  `ll_gc_maybe_collect` poll injected at a safepoint (§2) — a statement
  boundary, an allocation slow path, request end. A reentrancy guard
  makes any fire point safe even if reached from within teardown (a
  nested collection is a no-op).

**The policy is the compiler's, outside the runtime model.** *Which*
signals arm a collection and at what thresholds — candidate count,
bytes allocated since the last cycle, the memory-pressure mode
([buffers.md](../memory/buffers.md)), request end — is decided before
codegen and injected as calls, exactly as the store barrier's
*whether-to-call* is the compiler's (§1). Each signal is independently
enabled and tuned per build; **there is no universal trigger.** Request
end in particular is one optional signal among others, not a default:
daemons, actors and long CLI runs are not request-shaped, and much
cyclic garbage already dies for free at arena reset regardless. With no
signal enabled the runtime never fires on its own — collection is then
purely explicit — which is a legitimate configuration (its cost is
retained cycles, the caller's call to make).

The runtime therefore exposes only mechanism: `buffer_candidate`
(arm), `collect_cycles` / `ll_gc_collect_cycles` (fire now),
`ll_gc_maybe_collect` (fire if armed), and the reentrancy guard. No
triggering policy lives in the model.

## The flagship against pauses: `rc-satb`

Same composition, one substitution: marking runs **concurrently** with
the mutator, and correctness during marking is maintained by an SATB
deletion barrier in the store slot. Design: [satb.md](satb.md).

The GC/mutator coordination machinery in
[heap-design.md](heap-design.md) (the lock-free CAS handoff and the
deferred-free bit) belongs to this strategy: those races only exist
when the mutator runs during a collection cycle.
