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

---

## The Strategy Contract

Every strategy plugs into the same four interfaces. Nothing else in the
runtime or the generated code knows which strategy is active.

### 1. The store barrier, as micro-operations

A reference store is not one hook. It is composed from small operations
the compiler picks per site, because the slot's kind and whether a
previous value exists are both known at compile time. The old single
`ll_ref_store(ctx, owner, slot: *Value, old, new: Value)` assumed every
slot was a 16-byte `Value` and every store overwrote a live one; neither
holds under the object layout ([classes.md](../classes.md)): a typed
reference is a bare 8-byte pointer, and an initializing store has no
previous value to release.

**Two operations, not one.** Publishing a new reference and dropping the
old one are separate:

```
store_ptr(ctx, owner_cat, slot, new)   # slot is *pointer, 8 bytes
store_box(ctx, owner_cat, slot, new)   # slot is *Value,   16 bytes
drop(ctx, owner_cat, old)              # old is an entity; no slot
```

- `store_*` retains `new`, applies the cross-arena category check,
  and publishes the slot. The `ptr` form writes 8 bytes; the `box` form
  writes the whole 16-byte `Value` (a caller stamping the tag afterwards
  would leave the slot torn for the length of the call — one slot, one
  writer). A pointer slot holds either `0` (PHP `null`, no entity) or a
  real entity pointer — there is no sentinel — so the `ptr` form counts
  simply when the pointer is non-null.
- `drop` takes the entity the slot **held**, not the slot. Releasing,
  un-counting an escape, and running teardown all operate on the
  displaced entity's header, so `drop` does not depend on the slot's
  kind at all — there is one `drop` for both forms.

**Composition follows the site:**

- **Initializing store** (a fresh slot, in a factory or after `new`):
  `store_*` only. There is no old value, so no `drop` — the release
  path is not emitted at all, which is the point of the split.
- **Overwriting store** (a live slot): `store_*` then `drop(old)`.
  The order is the invariant, not a comment: the slot is published
  before the old value is released, because releasing runs `__destruct`,
  which may collect and read the slot, and must see the new value
  (audit C1). The split makes that ordering fall out of the composition.

**`owner_cat` is a parameter, not read from the owner.** The
destination's memory category decides the cross-arena direction, and
the compiler knows it — so it is passed, not loaded from `owner->flags`.
This is what lets a **static block** be a store destination: it has no
`RcHeader` (it lives for the program in the image, [classes.md](../classes.md)),
and none is needed, because its category (long-lived) is a compile-time
constant. Where `owner_cat` is a constant the escape direction is often
statically impossible, so the compiler emits a **specialized** form with
the category check gone — a heap-to-heap store is then retain + publish
+ release, nothing more. `ctx` still supplies the arena whose escape and
release-at-reset logs a full store writes.

Each operation is still composed at build time from up to three layers:

| Layer | Owner | Present |
|---|---|---|
| Category barrier (cross-arena check, escape count + release log) | arenas, strategy-independent | in the full form; gone where `owner_cat` makes it impossible ([arenas.md](../memory/arenas.md)) |
| RC operations (`retain(new)` in `store`, `release(old)` in `drop`) | ARC | in every RC-based strategy, after compiler pairing elimination |
| Strategy hook | active strategy | only if the strategy defines one; `rc-cycle` defines none — it enrols on the release path instead |

The slot is still the *only* door through which any strategy observes
reference mutation; splitting the write from the release does not add a
second door, it separates two things that were always distinct. Strategies
with no hook (NoGC, pure RC, stop-the-thread tracing) contribute zero
instructions.

Objects whose lifetime the compiler schedules statically (tiers 1–2 of
[static-lifetimes.md](../memory/static-lifetimes.md)) bypass the
strategy entirely: no RC layer, no strategy hook; only the category
barrier remains where a cross-arena store is possible.

The COW check ([values.md](../values.md)) is *not* part of this: it
guards entity mutation, not reference stores, and is orthogonal to the
strategy.

### 2. Safepoints

Tracing strategies must observe thread stacks in a consistent state.
The compiler inserts **poll safepoints** (load a global flag + branch,
~1–3 cycles) at function entries and loop back-edges. At a safepoint
the thread is in a state the runtime can reason about: no half-built
object, no reference in flight.

**A safepoint does not by itself make roots enumerable.** It is a point
in time, not a map of the frame: nothing about the poll says which slots
hold references. Only a strategy that declines to *count* stack
references needs that map, and it must then pay for one — the compiler
spilling every live reference into a per-frame list before each poll,
which is Fil-C's arrangement and the real cost, the poll itself being
the cheap half. `rc-cycle` owes nothing: a frame's reference is
counted like any other, so it appears in the refcount and never among
the heap-internal edges, and the frame is a root by arithmetic
([rc-cycle.md](rc-cycle.md)). The choice is paid once either way —
count the locals and never read the stack, or skip the counts and be
able to read it.

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
- the class's `traced_runs` — the list of `(offset, count)` pointer and
  ValueBox runs — for tracing object children ([classes.md](../classes.md))
- the three-phase teardown (`__destruct` with resurrection check →
  drop → memory release). A strategy that proves an object garbage may
  free it directly instead of entering teardown. `rc-cycle` does not:
  its commit stage runs the destructors in a fixed order
  ([rc-cycle.md](rc-cycle.md), "Cycle teardown"), which is what closes
  the missing-`__destruct`-for-cyclic-garbage gap earlier strategies
  left open. A strategy that does free directly still owes the
  bookkeeping teardown would have done: above all, dropping the escape
  hold-count of every request-arena entity the dead holder referenced,
  since arena entities are invisible to the trace and nothing else will do
it.

---

## Constraint: non-moving only

Per [heap-design.md](heap-design.md), objects never relocate. A
strategy that moves objects does not fit the contract.
Arena-reset evacuation is not an exception: it is an arena-boundary
event with no live stack, outside any strategy
([arena-reset.md](../memory/arena-reset.md)).

---

## Strategy Registry

| Strategy | Composition | Cycles | Pauses | Use case |
|---|---|---|---|---|
| `nogc` | bump allocation, never frees | leaks | none | benchmarks baseline; short scripts |
| `rc` | ARC + arenas | **leaks cycles** | none | short CLI where cycles don't accumulate |
| `rc-cycle` **(in force)** | ARC + arenas + on-the-fly cycle collection from a mutator-fed candidate set | collected **once built**; until then a garbage ring is retained | enrolment on the release path, price bounded at ~0.4 ns a pair | the design of record since 2026-08-25, being built — see [rc-cycle.md](rc-cycle.md) |

`nogc` is what the echo compiler ships today; `rc` is approximately
elephc's model; `rc-cycle` is the Zend architecture done right
(RC + cycle collection, plus arenas and compiler ARC elimination).

Two rows left this table on 2026-08-26 and are not replaced by
tombstones: `rc-trace`, the stop-the-thread tracer that was the first
implementation, and `rc-walk`, the barrier-free concurrent walk that was
the default build from 2026-07-27. Both were deleted from the tree and
from this repository by Edmond's ruling of the same day, on the ground
that a superseded mechanism left in place is read as the design in
force. The code and the documents are on the branch
`archive/pre-rc-cycle`, and the reasoning is in
[`../../dev/DECISIONS.md`](../../dev/DECISIONS.md).

---

## `rc-cycle`

The design of record since 2026-08-25 and the only strategy being built;
the two it replaced left the tree on 2026-08-26.
Points 1 and 2 belong to the whole ARC-plus-arenas family and held for
its predecessors too; point 3 is where this strategy differs from them.

1. **ARC is the primary reclamation path.** Refcount hits zero →
   immediate, deterministic teardown. Compiler pairing elimination,
   immortal flags, arena scoping per
   [arc-optimizations.md](../memory/arc-optimizations.md).
2. **Arenas absorb the bulk.** Request-scoped objects carry no
   refcounts and die in O(1) at arena reset; the collector never sees
   them.
3. **Cycle collection finds islands only, and enumerates no roots —
   ever.** Every external hold — a stack local, a static, an arena slot,
   an FFI handle — is already *counted*, so "referenced from outside" is
   **computed**, `RC − IN > 0` over what the trace reached, never
   scanned. What the trace reaches is not the heap: the candidates come
   from the mutator, which enrols an entity at a decrement that does not
   reach zero, and the descent stops at a mature member and at a child
   outside the GC heap, and may also be cut by a budget, which is open
   ([rc-cycle.md](rc-cycle.md), `cycle/questions.md` Y9 and Y13).
   Trial deletion runs on shadow rows off the heap, so an abandoned
   trace writes nothing into any entity.

The collector proposes and the owning thread judges. A collection run
in-line on the owning thread is exact by construction and needs no
second phase; a collector thread is an accelerator that narrows the owner's
list, and every *reduction* of state — clearing an enrolment bit,
dropping a queue entry, returning a slot — is the owner's, on an exact
reading.

### Triggering: arm vs fire

Cycle collection reads refcounts against the physical object graph and
frees what the two agree is unreachable. It may therefore run **only
where refcounts and edges agree** — between mutator operations, after
the current store or teardown has completed. This is a *correctness*
requirement, not a tuning choice.

The failure it rules out is concrete: a window in which a count and the
edges that justify it disagree, so a collection walking the edge subtracts
the same reference a second time, drives a still-live object to refcount 0
and frees it out from under its remaining holder. It opens mid-teardown, at
a child release during phase 2, and mid-reset. It does **not** open at an
overwriting store, because §1 mandates `store_*` then `drop(old)`: the slot
carries the new value before the old count falls, so the skew there is the
conservative one — the count is high, never low. An earlier draft of this
section argued from the opposite order, which the composition forbids.

So the trigger splits in two, and only the runtime half is fixed:

- **Arm (runtime mechanics).** A decrement that does not reach zero
  enrols the entity in its thread's root queue; a signal that a
  collection is due sets a *pending* flag. Both run from inside
  `ll_release`, i.e. mid-mutation, so neither **ever runs the
  collector** — they only record that one is due. The root queue itself
  is always maintained, even when no automatic trigger is configured:
  the collector needs it to know what to trace, and the enrolment is
  the design's whole per-operation cost. The runtime keeps one signal of
  its own and no threshold: an enrolment that cannot grow the queue, or
  that draws on the reserve, arms the flag
  ([rc-cycle.md](rc-cycle.md), `cycle/questions.md` Y12).
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

The runtime therefore exposes only mechanism: enrolment on the release
path (arm), `ll_gc_collect_cycles` (fire now), `ll_gc_maybe_collect`
(fire if armed), the entry gate and the reentrancy guard behind it, the
inbox pickup at a safepoint, and the GC-heap allocation slow path, which
collects in-line on a refusal rather than reporting one. No triggering
policy lives in the model.

**The entry gate and the inbox are `rc-cycle`'s, added 2026-08-27.** A
thread whose allocation fails reads its own gate — the collecting flag and
`TEARDOWN_DEPTH` — before waiting on the trace token, and a closed gate
sends it down the pressure ladder instead; and a thread's safepoint poll
picks up the per-thread inbox in which a collector thread leaves the
shortlist it traced, that being how the accelerator delivers now that the
handshake is gone ([rc-cycle.md](rc-cycle.md), "Concurrency").

The allocation slow path is the one fire point the runtime owns
outright, because it is the point at which not collecting is a failure
rather than a delay: `runtime/exceptions.md` promises a *catchable*
memory-exhausted. That promise now has two legs rather than one — a
collection ran first, or the gate was closed and the reserve carried the
thread to its next checkpoint ([rc-cycle.md](rc-cycle.md),
`cycle/questions.md` Y14, [`../memory/critical-reserve.md`](../memory/critical-reserve.md)).

## What the GC/mutator coordination machinery went with

`heap-design.md` carried a lock-free CAS handoff and a deferred-free bit
whose races exist only when the mutator runs during a collection cycle. They
were written for a GC-state field in the header that no strategy in force
has, and they go with that field. `rc-cycle` parks a freed slot instead, on
two windows of different widths ([rc-cycle.md](rc-cycle.md), "Death while
enrolled").
