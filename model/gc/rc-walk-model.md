# rc-walk — the formal model

> **Status: design.** A model of the protocol in [rc-walk.md](rc-walk.md),
> written to be *executed*: every actor's action set is complete, so an
> exhaustive checker over the state vector below explores every
> interleaving the real system can produce. Nothing here is implemented.

## 0. What is being optimised

The objective is not total work, and it is not a single quantity. It is
**lexicographic**:

> 1. Minimise the mutator's work, subject to correctness.
> 2. Then minimise the collector's work.
> 3. Then measure what (2) costs the program anyway, and feed it back
>    into (1).

The order is strict: any trade that moves work off the mutator is taken
even if it multiplies the collector's, and only once the mutator's side is
settled does the collector's own cost become an objective at all. A design
that halves collector time by adding one instruction to `retain` is, here,
strictly worse — not marginally, categorically.

Step 3 is what keeps step 2 from being a formality. The collector's work
does not stay on the collector: it comes back as memory held, as cores and
memory bandwidth shared with the program, and as cache the program had
been using (§8). So "the collector may be slow" is a licence to trade, not
a licence to waste, and every claim of optimality in §7 is relative to
this ladder and means nothing without it.

## 1. What the model covers, and what it drops

**Modelled:** entities, their refcounts, their reference fields, the epoch
byte, the condemned byte, slot occupancy and slot reuse, the deferred
queue, the interleaving of the three actors, and the ground-truth
reachability of §4.

**Dropped, each with the reason it cannot change the answer:**

| Dropped | Replaced by | Why sound |
|---|---|---|
| Non-reference object contents | nothing | cannot appear in any modelled predicate |
| Class identity, `traced_runs` shape, entity kinds | "an entity has `k` reference fields" | the walk's only use of a class is to find fields |
| Size classes, block geometry | "a block has `S` slots" | slot identity is what matters, not its width |
| The walk's address order | an arbitrary permutation | strictly more behaviours than address order |
| Real time | order only | no action's effect depends on duration; the one ordering-sensitive element, the handshake, is an explicit edge (C7) |
| Destructor bodies | an arbitrary finite sequence of mutator actions at the destructor point | strictly more general than any PHP destructor |
| Arenas, statics, immortals, FFI handles | one *external holder* that takes and drops counted references | they enter the algorithm only through the count they take |

**Abstraction lemma.** Each dropped element either cannot influence a
modelled variable, or is replaced by strictly more permissive
nondeterminism. The checker therefore explores a superset of real
behaviours: an invariant that holds on the model holds on the system, and
a counterexample must be inspected for realisability before it is
believed.

One thing is dropped *without* being conservative, and it is deliberate:
**uncounted borrows**. They violate invariant I1 by construction, which is
exactly why they are a compiler obligation and not a collector problem
(§8).

## 2. The actors and their complete alphabets

Completeness is the whole point. If an actor can do something not on its
list, the enumeration proves nothing.

### Mutator `M` — one thread

| | Action | Effect |
|---|---|---|
| M1 | `new(x)` | take a slot from `A`, refcount := 1, epoch byte := 0, fields := null, bind to a frame slot |
| M2 | `load(x, y.f)` | copy a reference from a heap field into a frame slot: `retain` |
| M3 | `store(x.f, y)` | `retain(y)`, `x.f := y`, then `release(old)` — the release is **last**; `y = null` degenerates to the write plus the release |
| M4 | `drop(x)` | clear a frame slot: `release` |
| M5 | `checkpoint` | inside the allocator: ack a pending handshake, drain a pending message |

M2 and M3 are the only ways a reference moves. The store barrier is inside
M3 and is the whole of the mutator's cooperation with anything.

**The external holder of §1 is represented by the frame slots**
(stated 2026-07-26, finding F9: §1 promised a holder actor that no
alphabet contained, violating this section's own completeness rule).
For the counts — the only way holders enter the algorithm — a holder
and a frame slot are indistinguishable, so no separate actor is
needed; the obligation is on the configuration instead: `F` must cover
the deepest borrow chain *plus* the holders the shape requires. The
holder is not a heap entity and occupies no slot.

**Lost stamps are a mutator effect the alphabet must carry.** Every
retain/release rewrites the whole flags word to mask the condemned
byte, so it can bury a concurrent collector stamp under the stale
epoch byte it loaded. Leak-ward only (the entity reads as new one more
epoch, T1), but a checker built from this alphabet does not explore it
unless the effect is modelled.

**M3's internal order is load-bearing.** The old value's release may
reach zero and run a destructor — arbitrary code that can legally read
`x.f`. If the field still held the old value at that moment, the
destructor would resurrect a corpse (finding F7,
[rc-walk-proof.md](rc-walk-proof.md)). The field is therefore written
*before* the old value is released, and emitting that order is a
**compiler obligation**: the codegen for a field store (or the helper
call it lowers to) must not reorder the release ahead of the write.

A `release` that reaches zero runs teardown as part of the same action:
the destructor (an arbitrary M-sequence, per §1), then the child releases,
then the slot goes to `A` — or to the deferred queue if an epoch is in
flight.

### Memory manager `A`

| | Action | Effect |
|---|---|---|
| A1 | `alloc` | hand out a free slot or a virgin one; write refcount 1 and epoch byte 0 |
| A2 | `free` | slot's refcount is already 0; write the list link at slot+8; slot becomes free |
| A3 | `defer` | during an epoch, A2 parks the slot instead: not reusable |
| A4 | `flush` | at epoch end, parked slots become free |
| A5 | `trigger` | start an epoch |

`A` is a separate actor rather than part of `M` because A3/A4/A5 are
decisions it makes on its own numbers, and because slot reuse is where
identity bugs live.

### Collector `C` — its own thread

| | Action | Effect |
|---|---|---|
| C1 | `snapshot` | record the registry and each block's cursor |
| C2 | `readCount(s)` | read one slot's refcount |
| C3 | `readField(s,f)` | read one field |
| C4 | `stamp(s)` | write the current epoch byte into an occupied unstamped slot |
| C5 | `condemn(s)` | write the condemned byte |
| C6 | `request` | raise the handshake flag |
| C7 | `ack` | observe the mutator's answer; establishes the ordering edge |
| C8 | `post(K)` | queue a component for the drain |

**Private computation is not an action.** Diff, mark and component
extraction touch only collector-owned arrays, so no interleaving can
observe them and none needs enumerating. This is what keeps the state
space small, and it is a property of the design, not of the model:
Phase 2 was built to touch no shared memory.

## 3. The state vector, and why it is finite

**Per slot:** occupancy ∈ {virgin, live, free, parked}; refcount ∈ 0..R;
epoch byte ∈ {0, current, old}; condemned ∈ {0,1}; fields ∈ (slots ∪
{null})^k.

**Frame:** a multiset of at most `F` slot references.

**`A`:** the free set, the parked set, the epoch counter.

**`C`:** its phase, `rc[]` and `edges[]` over the walked set, the
candidate set, the posted messages.

Three reductions make this finite and small:

- **Counts are bounded.** By I1, `refcount(e) ≤ F + N·k + guards`, so `R`
  is a function of the configuration, not a free parameter.
- **Three epoch values suffice.** The only test performed on the byte is
  equality with the current epoch, so all pre-current epochs collapse into
  one `old` class.
- **The free set is a set.** No modelled predicate depends on free-list
  order, so permutations collapse. (This is worth re-checking if a scheme
  ever reads the list rather than popping it.)

The state count is a product of small factors in `N`, `k`, `S`, `F`. The
exact number is for the checker to report; this document does not assert
one.

## 4. Ground truth

The model carries `R*`, the set of entities reachable from frame slots by
following fields, recomputed after every action. It is the oracle: the
algorithm may never consult it, and every theorem below is stated against
it rather than against the algorithm's own beliefs.

This is the part that makes the enumeration a proof rather than a test.
The algorithm computes an approximation of `R*` from counts; the checker
knows `R*` exactly and can therefore catch the one failure that matters
without knowing anything about why it happened.

## 5. Invariants

Every reachable state must satisfy:

- **I1 — counts are honest.** For every entity `e`, `refcount(e)` equals
  the number of frame slots pointing at `e`, plus the number of heap
  fields pointing at `e`, plus outstanding Phase 4 guards. Everything else
  rests on this. An uncounted borrow is precisely its violation.
- **I2 — a free slot holds nothing.** No field and no frame slot points at
  a slot whose refcount is 0.
- **I3 — identity is stable within an epoch.** A slot freed while an epoch
  is in flight is parked, not reused, so a slot id names one entity from
  `C1` to the drain.
- **I4 — the epoch byte is honest.** A slot stamped `old` was occupied at
  snapshot time; a slot stamped `current` or 0 was not walked this epoch.
- **I5 — the collector invents nothing.** `C` never raises a refcount
  except the Phase 4 guard and never writes a field except in the sever
  step.
- **I6 — one verdict outstanding.** An epoch does not end, and the next
  does not begin, while a posted component is undrained.

## 6. Theorems

### T1 — the skip lemma

Omitting an entity from the walk, for any reason (wrong category, acyclic
class, unwalked kind, unregistered region, allocate-black), can only add
roots.

*Proof.* `IN` is a sum over recorded edges. Omitting a source removes
terms from that sum; `RC` is unchanged; so `RC − IN` is non-decreasing,
and the set `{RC − IN > 0}` only grows. ∎

*Corollary (omission must be total).* If an edge into `e` is recorded
while `rc[e]` is not, the difference reads `0 − 1 < 0` and `e` is a
non-root: the error reverses direction. Row omission and edge omission are
one decision.

### T2 — the exact test is exact

If, at a moment when the mutator's own thread is inside the drain and no
other action interleaves, every member `m` of component `K` satisfies
`refcount(m) = indeg_K(m)`, then no entity outside `K` references any
member of `K`.

*Proof.* By I1, `refcount(m)` counts *every* reference to `m`. `indeg_K(m)`
counts those originating inside `K`. Equality forces the count of
references from outside `K` to be zero, for every member simultaneously.
The drain runs on the only thread that can create a reference, and it is
executing this test, so the equality that is read is the equality that
holds. ∎

This is where safety lives. Everything before it is filtering.

### T3 — unreachability is stable

No mutator action makes an unreachable entity reachable.

*Proof.* By the alphabet. M2 copies from a field of an entity the frame
already holds, so its source is reachable. M3 stores a value the frame
holds. M1 creates a fresh entity. M4 and M5 remove references. No action
has an unreachable source. ∎

*Exceptions, and they are the only ones:* `WeakReference::get`, which
materialises a reference from an uncounted handle, and an FFI handle
holding a raw pointer. Both are excluded in §8, and both are the reason
that exclusion is not a formality.

### T4 — safety

No entity in `R*` is ever freed.

*Proof sketch.* A free happens only in the drain, only for a component
that passed T2, and T2's conclusion is exactly "no member is in `R*`". T3
guarantees the conclusion survives the interval between the test and the
free; I3 guarantees the ids in the message still name the entities the
test examined; and the guard/destructor/re-verify sequence re-establishes
T2 after the arbitrary mutator actions a destructor may perform. Every
earlier phase can be wrong in either direction without affecting this
argument, which is the design's central claim. ∎

### T5 — progress

**Premise (made explicit 2026-07-26, finding F2): the mutator reaches
checkpoints infinitely often.** The ack and the drain run only at
checkpoints; a thread that stops allocating stalls the epoch
indefinitely — an accepted limitation, recorded in
[rc-walk.md](rc-walk.md). Under the premise: each epoch terminates —
the walk is bounded by the snapshot, private computation is finite,
the candidate set only shrinks under re-checking, and the drain is
bounded by the posted components. By I6 no component is judged twice
concurrently.

Progress in the useful sense — that garbage is *eventually* collected — is
weaker and deliberately so. A component whose members are untouched
between snapshot and drain is collected. A workload that keeps touching
its candidates can starve the filter indefinitely; that is a recall
failure, not a safety one, and the escalation ladder in
[rc-walk.md](rc-walk.md) addresses it with measurements rather than
proofs.

## 7. Complexity, and in what sense it is optimal

**Per epoch**, with `V` walked entities and `E` recorded edges:

| Phase | Time | Space |
|---|---|---|
| Walk | `O(V + E)` | `O(V + E)` (collector-private) |
| Diff, mark, components | `O(V + E)` | reuses the above |
| Condemn and re-check | `O(candidates + their in-edges)` | `O(candidates)` |
| Drain, per component `K` | `O(|K| + edges leaving K)` | `O(1)` |

**Mutator cost**, which is the objective of §0: zero per reference
operation, zero per allocation, `O(1)` per epoch for the ack, and
`O(|K|)` per confirmed component for the verification pass — work it
would have spent freeing that memory in any case.

### The lower bound

**Theorem.** Let a collector be *barrier-free*: the mutator performs no
action whose purpose is to inform the collector. Then certifying the
garbage set requires reading every reference field and every count, so any
such collector is `Ω(V + E)` per full collection.

*Proof sketch.* To certify `e` as garbage, the collector must establish
that no live reference to `e` exists. A reference to `e` may reside in any
field of any entity. Barrier-freedom means the mutator has communicated
nothing, so no field can be excluded a priori — for any field the
collector declines to read, an adversary schedules a store of `e` into it
that no other observation reveals. Hence every field must be read, and
`E ≥` the number of fields; counts likewise for `V`. ∎

rc-walk attains this bound, so **it is asymptotically optimal in the
barrier-free class**.

### What the bound does not say

Bacon–Rajan is sublinear in `V` because the mutator hands it a candidate
list, at a cost of one test and branch on every non-zero decrement. That
does not contradict the theorem; it is the theorem's contrapositive. The
two designs are not comparable on collector time alone, and §0 is what
decides between them.

Three honest limits on the claim:

- It is asymptotic. Constants are where an implementation is won or lost,
  and none are measured.
- It is per *full* collection. A scheme that re-walked only what changed
  since the last epoch would beat `Ω(V + E)` amortised without a barrier —
  if change can be detected for free. OS dirty-page tracking was rejected
  as a *validation* mechanism ([rc-walk.md](rc-walk.md), "Rejected"); as a
  *narrowing* mechanism it is the original use and remains open.
- It says nothing about latency or about the collector keeping up, which
  are the properties that actually decide whether the design ships.

## 8. The cost that comes back

Step 3 of §0. The collector's work is off the mutator's *instruction*
path; it is not off the program's *critical* path, and the difference has
four parts.

- **Memory held.** While an epoch is in flight, freed slots are parked
  rather than reused (I3). The program's footprint therefore grows with
  epoch duration, which is the one place where a slower collector is
  directly a worse program. Bounded by the live heap at epoch start, per
  [rc-walk.md](rc-walk.md).
- **Cache and bandwidth.** The walk reads every entity header and every
  reference field in the walked heap. On a shared last-level cache that is
  the program's working set being evicted by a thread the program did not
  ask for, and it is the honest argument against whole-heap walking that
  no barrier accounting shows. Go's collector targets a quarter of the
  process's CPU precisely because this cost is real and had to be capped.
- **Cores.** A collector thread competes for a core. On a machine sized
  for the request rate, that core was not free.
- **The drain.** `O(|K|)` on the request thread per confirmed component —
  work the program would have done anyway when freeing that memory, but
  bunched rather than spread, so it shows up as latency at one point
  instead of as throughput everywhere.

**Counted in operations, what the program pays for the cycle collector on
top of the refcounting it performs regardless:**

| Program action | Operations added by this collector |
|---|---|
| create an object | none — the epoch byte is written by the collector, not by `alloc` |
| copy a reference to a local | none |
| store a reference into a field | none |
| drop a reference | one predicted branch while an epoch is in flight |
| destroy an object | none |
| allocate, occasionally | one checkpoint: a flag test, plus a handshake ack or a drain when one is pending |

The marginal cost of cycle collection, per reference operation, is zero.
That is the claim this design exists to make, and §9 is where it is worth
something.

## 9. Against Java and Go

The comparison has to start with what is *not* being compared, or it
flatters us.

**Limelight already pays more per reference operation than either.** A
`retain` and a `release` are a load, an arithmetic op and a store each,
executed on every reference copy. G1 pays a card mark on reference stores
only; Go's write barrier is a flag test outside a collection cycle and a
short slow path during one; ZGC pays on *loads*, which are roughly an
order of magnitude more frequent than stores and cost it something in the
region of five to ten per cent of CPU. Against a tuned generational JVM,
refcounting is the expensive side of the trade, not the cheap one.

What we buy for it is not throughput. It is `__destruct` at the moment the
last reference dies — a PHP semantic, not a preference — plus no root
enumeration, no stack maps, no moving, and no read barrier.

| | Limelight `rc-walk` | Go | G1 / ZGC |
|---|---|---|---|
| Per reference store | refcount ops (owed to PHP semantics), **nothing for the collector** | flag test, slow path during marking | card mark (G1); store barrier (ZGC) |
| Per reference load | nothing | nothing | nothing (G1) / load barrier (ZGC) |
| Roots | derived by arithmetic, never enumerated | stack maps at safepoints | stack maps at safepoints |
| Moving | never | never | yes (both) |
| Destruction timing | at the last release | at collection | at collection |
| Cycles | the only job of the collector | ordinary tracing | ordinary tracing |
| Collector cost | `O(V + E)` per epoch, whole heap | proportional to live set, capped near a quarter of CPU | generational: proportional to survivors |

The honest summary is narrower than "faster than Java". It is this: **the
marginal cost of collecting cycles is zero on the mutator, which no
tracing collector can say, because for a tracing collector the barrier
*is* the collection.** Everything else about the comparison is decided by
refcounting versus tracing, which PHP semantics decided for us before this
document started.

The direction where Java and Go are structurally ahead, and it should be
written down rather than discovered later: allocation. A bump-pointer
nursery with bulk young reclamation beats a size-class allocator with
per-object teardown on allocation-heavy code, and no amount of collector
design here closes that. Arenas are our answer to it
([../memory/arenas.md](../memory/arenas.md)), and they are a different
mechanism from anything in this document.

## 10. What the model does not cover

- **Uncounted borrows.** They break I1 by construction. The obligation is
  the compiler's and is written down in
  [static-lifetimes.md](../memory/static-lifetimes.md), "What may own a
  borrow". The model cannot verify it; it can only be extended to *show*
  the failure, by adding an action that binds a frame slot without a
  retain — worth doing once, as a demonstration that the checker notices.
- **Weak references.** T3's first exception. Excluded until their design
  exists; the interaction to check then is `get()` inside a destructor of
  the component being drained.
- **FFI raw pointers.** T3's second exception. A handle that stores a bare
  address outside the counted world can resurrect anything.
- **Multiple mutators.** T2 depends on the drain running where nothing
  interleaves. Actors take that guarantee with them.
- **Skipped populations** — `Box`, huge objects, retained arena blocks.
  Covered by T1: recall, never safety.

## 11. From this document to a running checker

The state vector of §3 and the alphabets of §2 are directly executable: a
bounded exhaustive search over all interleavings, asserting T4 (against
`R*`) and I1–I6 after every action.

**The minimum configuration that can express every failure found so far**
is small, and each parameter earns its place:

- `N = 3` heap entities: a two-member cycle and a child borrowed out
  of the cycle — the shape of the reference-migration case. The
  external holder is a frame slot, not a heap entity (§2), which is
  what lets the shape fit `S = 3` slots.
- `k = 2` fields: one to close a ring, one to hang a non-member child.
- `S = 3` slots in one block: enough to force reuse of a freed slot while
  a walk is in flight, which is what I3 exists for.
- `F = 2` frame slots: enough for a borrow to outlive its owner.

**Implementation is open** between a specification language (TLA+/PlusCal,
where the fairness and liveness vocabulary is already built) and a few
hundred lines of Rust beside `ll-model` that enumerates directly (no new
toolchain, and counterexamples come out as Rust test cases). The choice
should follow whoever has to maintain it.

**A counterexample is a trace of actions**, which maps one-to-one onto a
test in the adversarial harness described in
[rc-walk-review.md](rc-walk-review.md), "How to test it". That mapping is
the point: the model is not a parallel artifact to be kept in sync by
hand, it is the generator for the tests that guard the implementation.
