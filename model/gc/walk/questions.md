# The question graph

Every open question of the design of record, as a node with what would
answer it and what it blocks. The graph covers the collector, the barrier,
the proof side inherited from [`../gc-horizon.md`](../gc-horizon.md), and the
verification debt. A node carries a mark for what blocks it:
**today** — answerable with the code and instruments that exist;
**measure** — a number nobody has taken, on instruments that exist;
**design** — a decision to be made and written, no instrument involved;
**compiler** — blocked on a compiler that does not exist;
**corpus** — blocked on a measurement of real PHP programs;
**hardware** — blocked on a machine this project does not have;
**Sage** — deferred to the arbitrating role;
**read** — prior art already read, feeding another node.

The rulings below bound the graph and are not nodes.

## Rulings of 2026-08-22

Edmond, in the session that refused the capture-count regime.

1. **The count stays on heap edges.** It is the write barrier, and it also
   frees at zero, answers the uniqueness test and carries the arena's
   escape hold-count. Nothing else on the table supplies all four.
2. **No thread is stopped from outside.** A thread short of memory may
   spend its own time collecting; the fourth principle of
   [`../rc-walk.md`](../rc-walk.md) stands unamended.
3. **Freeing runs in bounded batches.** The bound is relaxed while memory
   is short. Its ceiling is time rather than a count of entities, checked
   between entities: a destructor is user code, so per-entity cost has no
   bound and a count of entities bounds no pause. Both constants are
   unmeasured (node D3).
4. **A grown verdict queue activates the mutator.** The mutator drains it
   rather than waiting for its ordinary cadence.
5. **The collector is the main freeing path.** Verification stays on the
   mutator: its thread is the one place a verdict is checked against the
   true graph with no race ([`../rc-walk.md`](../rc-walk.md), Phase 4).
6. **Large OS-direct entities are walked.** Ruled on the premise that they
   were not, which was wrong: the registry landed on 2026-08-10 and both
   enumerators read it (`ll-model` `src/memory/large_entity.rs`). The ruling
   stands as a statement of what the design requires and closes node B3
   rather than opening it.
7. **An FFI wrapper holds the references itself.** Every PHP reference the
   C side can reach lies in a declared field of the wrapper; the C
   structure holds at most a raw address of what the wrapper already holds.
   The collector then traces the wrapper as an ordinary entity, and the
   memory of the C structure stays outside the collector's business.
8. **The collector runs user code only where purity is proven.** An impure
   destructor keeps its call on the mutator.
9. **The purity ladder keeps four rungs and every destructor call.** No
   rung folds into another, and no proof licenses skipping a call.
10. **The confirmation's pause is accepted rather than bounded.** A
    component is judged whole, and the exact test runs in one
    uninterrupted stretch over it (nodes D2 and D4).
11. **A value read through a weak cell is always counted.** It is an
    owned base case, and no elision rule reaches it (node G1).

## The graph

```mermaid
flowchart TD
    A1[A1 the pair against its working set<br/>measured 2026-08-22] --> A6
    A6[A6 what share of stores survives the proofs<br/>corpus] --> A2 & A3 & A4
    A2[A2 the birth count<br/>compiler]
    A3[A3 unique ownership<br/>compiler]
    A4[A4 anchor-chain elision<br/>compiler]
    A5[A5 a cheaper count word<br/>answered, prefetch unsettled]
    A7[A7 the unique-ownership discriminant<br/>answered 2026-08-22]
    A8[A8 clearing the COW flag by proof<br/>compiler] --> A3

    B1[B1 skip kinds that cannot ring<br/>rate measured, share corpus] --> C1
    A6 --> B1
    B2[B2 the acyclic class flag<br/>compiler] --> C1
    B4[B4 arrays as the commonest spine<br/>measured 2026-08-22] --> A6
    B5[B5 the epoch-abort watermark<br/>open; returns no memory when it fires] --> C1
    C1 --> B5
    B6[B6 skip by block, not by entity<br/>measured; segregate, not count]
    B1 --> B6

    C1[C1 background cadence<br/>open; two candidates eliminated] --> C3
    C2[C2 the young-free exemption<br/>curve measured; open on soundness] --> C1
    C3[C3 the pressure ladder's constants<br/>measure]
    C4[C4 do the rungs earn their keep<br/>open; priced wrongly once] --> C3

    D1[D1 the hand-off and hand-back channels<br/>open, five constraints] --> D5
    E1 --> D1
    D3[D3 the batch constants<br/>measure]
    D5[D5 collector-side destructor calls<br/>open, blocked on D1]
    D6[D6 WeakMap ephemerons<br/>open; edge-conditional shape unpriced]

    E1[E1 what an owner is<br/>open, both halves] --> E3
    E3[E3 the domains proposal<br/>sorted; waits on E1]
    E2[E2 AArch64 header access<br/>hardware]

    G2[G2 the counted-out categories<br/>open, wider than question 8] --> G7
    G3[G3 placement, raise sites and pad sets<br/>ruled; generator half open]
    G8[G8 anchored parameters<br/>design] --> G6
    G9[G9 one borrow analysis or two<br/>design] --> G6
    G4[G4 the trigger set against the sentinel<br/>design]
    G7[G7 borrow scopes across suspensions<br/>design] --> G6
    G6[G6 the summary language<br/>design] --> G5
    G5[G5 the trusted-effect boundary<br/>design]

    H1[H1 the checker models the old protocol<br/>scoped, re-derivation unstarted]

    F1[F1 coalescing RC<br/>read] --> A5
    F2[F2 arborescent GC<br/>read]
    F3[F3 partial tracing, read<br/>record only]
```

## A. What the count costs, and what removes it

### A1. What the counted pair costs against its working set  [measured]

Answered 2026-08-22, `ll-model` `dev/BENCHMARKS.md`. The pair an overwriting
store adds over a plain one costs 2.9 ns where both foreign headers are warm
and 33 ns at a population of a million entities, median of six runs, spread
of 12 % at the wide end. The figure is the difference between two arms of one
run, not the store's whole cost.

An earlier measurement the same day read 88 ns and is retracted in that file:
its probe published every store into one slot, so the displaced header was
warm where the retained one was cold, and it charged the counted arm for
scattered owner traffic the plain arm did not pay.

**What it changed:** an elided publication is worth up to 33 ns rather than
the 2.4 ns the hot figure suggested — about eleven times — which raises every
compiler proof below against every collector-side lever. Node N's estimate of
roughly 80 ns for the same quantity is high by a factor of 2.4, so the
crossover it draws must be re-derived on the measured figure.

### A2. What the birth count removes  [compiler]

`../rc-walk.md`, "The birth count". The factory writes the in-degree the
construction sequence will produce, and the sequence's publications emit no
retain. **What would answer it:** the share of publications that are
construction publications, which needs a compiler to elide and a corpus to
count. **What it blocks:** nothing; it is the largest compiler-owed lever.

### A3. Unique ownership  [compiler]

`../rc-walk.md`, "Unique ownership". An entity the compiler proves is owned
by exactly one heap slot carries no count. **The open rule is the move**
(`../rc-walk.md`): it must resolve as copy, or as a proof that the entity
never moves. A move that emits a barrier readmits node M's fatal ordering
through a side door.

### A4. Anchor-chain elision  [compiler]

Form A of `../gc-horizon.md`: a borrow anchored by a counted holder emits no
pair. **What would answer it:** the share of borrows whose anchor the
compiler can prove.

### A7. The unique-ownership header discriminant  [answered against the header; one consequence is new]

`../rc-walk.md` left it between a sentinel value in the count word and a
bit of the freed byte. Read against the header as it stands (`ll-model`
`src/refcount.rs`, and [`../../classes.md`](../../classes.md#flags-layout) for the flag map),
the first option is not a discriminant at all and the second exists in
only one build.

**The sentinel value cannot discriminate.** `../rc-walk.md` names the
sentinel as the value 1, which is exactly what an ordinary entity holding
one reference reads. It is an occupancy marker — it keeps the walker's
"is this slot live" test working — and it says nothing about whether the
word is a count. A discriminant made of a value would have to reserve one
no real count reaches, `u32::MAX` being the only candidate, and that rests
on a count never arriving there rather than on a proof.

**The flag word has no free bit below the epoch byte.** Bits 0-1 are the
memory category, 2-3 the GC state, 4-5 the collector colour, 6 the
buffered bit, 7 the weak-reference bit, 8 and 9 the two destructor bits,
10 COW, 11 the live-escapee bit and **12-14 the entity kind**. Bit 15 is
the string's out-of-line bit for one kind, and the whole of 15-31 is the
candidate-buffer index in an `rc-trace` build.

**So the discriminant is a bit of the retired condemned byte, 24-31**,
free under `rc-walk` since the eager-death amendment of 2026-07-27 and
used by nothing today.

**The consequence nobody has recorded: unique ownership is then an
`rc-walk`-only feature.** Under `rc-trace` bits 15-31 are the candidate
index, so no bit is free and the count word is the only place left, which
is the option this node just refused. Strategy selection is a build-time
feature precisely because the two cannot share the top half of the word
(`../strategies.md`), so a proof that changes what the count word means
cannot be strategy-neutral. Either unique ownership is declared
`rc-walk`-only, or the candidate index is narrowed to make room —
131 070 positions today, and the fallback for an out-of-range index is a
linear scan rather than an error.

### A5. A cheaper count word  [answered in direction; one lever unpriced]

The narrow mutator already writes back four bytes rather than eight
(`../rc-walk.md`). The node asked whether any further shape pays after
A1's figure. **The width is not the lever, and A1 says so**: the pair
costs 2.9 ns with both foreign headers warm and 33 ns at a population of a
million. The store is inside the 2.9; what the other 30 buys is the miss.
A narrower or cheaper store cannot reach it.

**Coalescing is bounded by the checkpoint cadence.** F1's shape — one log
entry per object per epoch instead of one pair per write — pays only where
the same header is touched more than once inside the window, and the
window cannot be an epoch here: the exact test recomputes in-degree from
current fields and compares it against the count, and only the owner reads
the counts current
([`../pure-destructors.md`](../pure-destructors.md#the-five-owner-bound-races)).
A log must therefore drain before any checkpoint that can run the test,
and checkpoints sit on every loop back edge. What is left to coalesce is
one straight-line stretch.

**A deferred log is already refused where the count matters most.**
[`../../values.md`](../../values.md#refcount-is-always-maintained-on-cow-entities)
rules deferred ARC out for COW entities at any tier, the sharing test
being consumed at the instant of the write. Every COW-eligible reference
is counted by base case, so the log would apply to the remainder only, and
the remainder is what the compiler proofs of section A are trying to
remove anyway.

**The lever is the miss, and a prefetch was measured against it**,
2026-08-22, `ll-model` `dev/BENCHMARKS.md`. Two arms, both counted,
identical but for a read prefetch of the retained and the displaced header
issued eight stores ahead. Where nothing misses it costs 0.9 ns per store,
stable across runs. At a million entities seven repeats recovered +11.6,
+7.3, −0.3, −1.3, +20.3, +1.3 and +7.2 ns — median +7.2, five of seven
positive, and the spread crosses zero while the bare arm's own median moves
between 79 and 107 ns. **The direction is suggestive and the magnitude is
unmeasured.** Probe:
`memory::barrier::tests::what_a_prefetch_recovers_from_a_cold_pair`.

**What would settle it:** a wide point that holds still — a pinned core and
a longer round, or a machine that is not WSL2 — and then the prefetch
distance varied, which is fixed at eight and not tuned.

### A8. Clearing the COW flag by proof  [compiler]

The road Edmond's ruling of 2026-08-22 opens
(`../../../dev/DECISIONS.md`). COW is one bit of `RcHeader.flags` and
non-COW arrays and objects already exist
([`../../values.md`](../../values.md#cow-is-a-per-object-flag)), so an
entity the compiler proves never needs the separation test can leave COW
outright and become eligible for A3. **What would answer it:** the proof
obligation — every write to the entity is through a holder the compiler
knows to be sole, over the entity's whole life — and what the flag's other
readers do when it is clear. **What it does not reach:** strings, where
the flag is the layout, set meaning bytes inline, and is fixed at
creation.

### A6. What share of stores survives every proof  [corpus]

The root of section A. If the proofs remove almost every pair, A1's figure
buys nothing and the collector-side levers decide; if they remove a third,
the store path is where the work belongs. **What would answer it:** a scan
of real PHP programs, which the repository has needed for three separate
questions and has never had.

**The scan splits in two, and the heap-side half is measured**, 2026-08-22.
The store-side share — how many publications survive the compiler proofs —
needs the compiler and waits. The heap-side share does not, and
`../../../dev/tools/heap-composition.php` takes it: a reachability walk over
a booted application, run here against the Laravel 13 skeleton on PHP 8.6,
once after boot and once after one handled HTTP request.

| | booted | after a request |
|---|---|---|
| objects, exact | 507 | 387 |
| distinct strings, proxy | 797 | 721 |
| array slots | 1 302 | 1 253 |
| counted slots | 3 765 | 3 753 |
| string share of counted slots | 40.5 % | 43.9 % |
| counted slots per object | 7.43 | 9.70 |
| object-to-object edges per object | 1.85 | 2.20 |

Taking entities as objects plus distinct strings plus array slots, that is
**about 31 % of entities being strings in both runs, and 1.4 to 1.6 counted
edges per entity.**

**What the figures are approximate about**, stated rather than assumed:
objects and the edges between them are exact, `spl_object_id` giving
identity; strings and arrays have none in PHP, so distinct string contents
stand in for string entities and under-count, while an array is counted per
slot and over-counts a shared one. Over-counting arrays inflates the
denominator, so **31 % is a floor for the string share**. A closure is an
object here and 309 of the 507 booted objects are closures, which Limelight
keeps as its own kind.

**A third quantity for the same scan, added 2026-08-22: the ratio of
counted edges to entities.** B4 measured a cell at 43-47 ns against a leaf
row's 40-54, so the walk's cost is carried by edges as much as by rows, and
which of B1 and B6 is worth building turns on that ratio as well as on the
share of leaf kinds.

**A fourth, added the same day for node C2: headerless companion records.**
A dying entity parks its own slot; a non-empty array parks its table storage
and an out-of-line string parks its payload as records with no header, which
no epoch byte can exempt. The scan counts 800 non-empty arrays booted and
746 after the request, against 0 out-of-line strings in either — a `GcHeap`
string stays inline up to `MAX_SMALL`, 8 192 bytes, and the widest string
here lands in the 7 168 class. That is **0.31 to 0.32 companion records per
entity, so entity records are 76 % of what the deaths in a heap of this shape
would park**, which bounds C2's exemption before any question of age. Two
things the figure is not: it counts arrays per slot in both halves of the
ratio, so a shared array raises numerator and denominator together and the
direction of the residual error is unresolved; and it counts a stock of live
entities where the parked list is a rate, which leaves out every payload
freed by *growth* rather than by death — those park and are never exempt.

**Two things the re-run of 2026-08-22 established about the instrument
itself.** The tool sized a string's fixed part at 16 bytes, the object's
header and class word, where `LLString` is 24 — an 8-byte header, a 4-byte
length, four bytes of padding and the hash (`ll-model` `src/string.rs`).
Corrected, the booted scan's extra tail blocks fall from 6 to 5 and the
request scan's stay at 8, so the figure recorded for B6 is unaffected; the
control run with the old constant is what says so. And the booted scan now
reports 3 764 counted slots where the table above says 3 765, twice in a
row, so the container is not identical from day to day at one slot in four
thousand.

## B. What the walk reads

### B1. Skip the kinds that cannot sit on a ring  [rate measured, share corpus]

The census enrols every `GcHeap` entity (`ll-model` `src/walk.rs`), strings,
weak cells and FFI boxes among them, although `trace_entity` files all three
under "the kinds with no counted children" and a leaf cannot be a ring
member. The acyclic skip is described in `../rc-walk.md` and is not taken in
code.

**The rate is answered**, 2026-08-22 (`ll-model` `dev/BENCHMARKS.md`):
skipping such an entity returns about 40 ns, give or take a fifth — roughly
half what an object row costs, since a leaf pays the header read, the id-map
entry and the count store and skips only the edge trace. The walk is about
70 % of an epoch.

**The share has a first measurement**, 2026-08-22: about 31 % of entities
in a booted Laravel container are strings, and the same after a handled
request (node A6). Against B4's cost model — a row 40-54 ns, an edge 43-47,
and 1.4 to 1.6 edges per entity — the skip removes the rows of those
entities and no edges, which is roughly **13 % of the walk**. That is one
framework on one machine and an estimate built from two measurements rather
than one, so it is a first bracket and not the number. B4's measurement of 2026-08-22
bounds what the skip can be worth: it removes rows and no edges, and an edge
costs about what a row does, so its ceiling is the leaf share times the row
alone. B6's measurement of the same day removes its rival's cheap
shape rather than the skip itself: no block comes out uniform under any
interleaving, so a per-entity skip is what is available until entity blocks
are segregated by kind.

### B2. The acyclic class flag  [compiler]

The per-class form of B1: a class whose field types cannot close a ring.
**What would answer it:** the closed-world closure over the field-type
graph, with the same failure modes the purity closure has — subclassing,
`mixed`, arrays of unknown element class.

### B3. Large OS-direct entities are in the walk  [closed]

Closed before this graph was written, on 2026-08-10. An entity too large for
a pooled block lives in an OS-direct run, which no region contains, so it is
enumerated from its own registry — `ll-model` `src/memory/large_entity.rs`,
one address per run, entered before the memory and removed before the free —
and both `for_each_entity_slot` and the concurrent epoch's snapshot read it
(`src/memory/heap.rs`).

**The confusion this node was opened on**, recorded so it is not repeated:
`BLOCK_KIND_LARGE_RUN` (kind 4) is a raw C buffer, holds no entity and cannot
ring; `BLOCK_KIND_ENTITY_LARGE_RUN` (kind 10) holds one entity and is the
registered kind. The comment saying huge allocations stay outside the walk is
about the first.

### B6. Skip by block, not by entity  [measured; the two shapes swapped places]

B1 skips a leaf after reading its header; this node asks whether the walk
can decline to touch the block at all. Today it cannot: entity blocks are
divided by block kind and then by size class only (`ll-model`
`src/memory/heap.rs`), so a string and an object of the same size share
one.

Two shapes, and the node used to say the second was where to start.
**Measurement reversed that**, 2026-08-22, `ll-model` `dev/BENCHMARKS.md`.

- **Count the ring-capable entities in each block and skip at zero.** One
  word per block on paths that touch the block header already. Measured
  with a one-property object and a string sized into the same class 32, so
  the two kinds really do share blocks: **one object per sixteen strings
  contaminates every block**, and every interleaving ratio tried leaves
  zero skippable blocks. A block at that class holds 2 000 slots and the
  allocator bumps through it, so one ring-capable entity anywhere in a
  block's fill is enough. A same-kind run has to exceed a whole block
  before any block comes out uniform, and a run of 10 000 — five blocks'
  worth — still leaves 40 %. A first reading blamed run boundaries landing
  mid-block; the arithmetic refutes it, a sequential one-block-at-a-time
  fill predicting 50 / 60 / 50 % where 0 / 40 / 40 was measured with every
  block full. The allocator keeps a per-class chain of available blocks
  rather than one open block, which makes the result stronger: exact block
  multiples still come out mixed. The shape costs nothing in layout and
  returns nothing without runs no interleaved program produces. Probe:
  `collector::tests::how_uniform_a_block_comes_out`, which now asserts the
  size-class collision the measurement rests on.

  Two limits on reading it as more than shape 1's refutation: the probe
  classifies on `kind_may_close_a_cycle`, which is B1's rung and not the
  walk's enrolment test, and the population is quiescent, where a running
  epoch's stamp test would skip most young entities anyway.
- **Segregate entity blocks by entity kind as well as by size class.** The
  walk then skips whole blocks untouched, which is worth more than B1's
  per-entity skip: B4 measured a leaf row at 40-54 ns and an edge at
  43-47, and a skipped block saves both for every slot plus the
  storage-head read for any array. The price is a partly-filled tail block
  per pair of size class and kind, paid in footprint and fragmentation.
  **This is the shape that delivers**, and it is the one to price.

**Shape 2's price has a first measurement**, 2026-08-22, taken with
`../../../dev/tools/heap-composition.php` over a booted Laravel 13 after one
handled request. Objects there occupy 15 size classes and strings 10, for 25
pairs of class and kind over 17 distinct classes — so segregation costs **8
extra tail blocks, half a mebibyte** at the 64 KiB block. Against the ~28 MiB
that boot holds, under two per cent. The figure covers two kinds; the other
five add pairs of their own, and one framework is not a class population.

**What would answer what is left:** the same figure over more than one
program, and whether the allocator's fill can be steered by kind without a
second free list per class.

### B5. The epoch-abort watermark  [open; the identity half holds, two objections stand, one is withdrawn]

The second collector-side bounding mechanism beside C2's exemption:
abandon the epoch when parked volume crosses a watermark. `../rc-walk.md`
says it is sound while nothing is posted, the identity obligation running
only from walk to drain of posted messages, and asks for its own proof
pass.

**The identity half holds; three other halves do not.** Before the first
post no id is in flight, so no address has to stay stable and the walk's
tables — rows, edges, versions, all collector-private — go with the epoch.
What a review round found beside it:

- **The abort returns no memory when it fires.** The park list is
  thread-local and flushed by its own thread at a checkpoint (`ll-model`
  `src/memory/deferred_free.rs`), so ending the window turns parked memory
  into flushable memory and nothing more. The workload that crosses a
  parked-volume watermark is a mutator allocating without reaching a
  checkpoint, and that is exactly the one the abort cannot relieve.
- **What the abort costs depends on where it fires**, and two drafts have
  now priced one firing point as though it were all of them. `walk_rows` is
  one uninterrupted loop over every block and `run_epoch` chains whole
  phases (`ll-model` `src/collector.rs`), which leaves three points:
  - **Before the ack.** `Epoch::open` raises the deferral bit and then the
    protocol waits for the handshake, so parking is on while the collector
    makes no progress at all — the workload of the bullet above, and the
    first place a watermark would fire. Nothing has been stamped, so the
    next epoch meets the young cohort at zero, stamps it and skips it: the
    abandoned epoch leaves *less* enrolled rather than more, and under C2's
    predicate those entities then die exempt. What it costs is coverage, a
    cycle in that cohort waiting another epoch, and the handshake state the
    bullet below describes.
  - **After the walk.** Every slot carries the number a completed epoch
    would have left, the next epoch enrols the same set, and the abort
    costs the walk alone. Parked volume is untouched either way while
    parking stays unconditional.
  - **Inside the walk.** Swept blocks carry the number and the rest carry
    zero, which is the second case for part of the heap and the first for
    the remainder.

  So a watermark policy has to name its firing point before its cost can be
  stated, which puts it with C1's cadence rather than beside it.
- **The handshake flag and the ack counter are cross-epoch state.** An
  abort before any ack leaves the request raised with no epoch behind it,
  and the ack counter is a single global whose first ack lowers the flag
  for everyone, so a second mutator can be counted as having acked an
  epoch it never saw.

**The epoch number, at least, the code already discharges.** An aborted epoch's stamps stay on the entities it
skipped, so a number reused immediately would make them read current and
be skipped again. `Epoch::open` takes its number from a counter that
advances on every open (`ll-model` `src/collector.rs`), so an abort
consumes its number like any other epoch, and the 1-255 cycle's wrap is
already accounted as latency rather than error.

**What is left is the watermark itself**, and it is not one number but a
policy: parked volume against what — the live heap, the allocation rate,
a fixed ceiling — and what the collector does after an abort, since
re-walking immediately would abort again under the same pressure. That
sits with C1's cadence and C3's constants rather than apart from them.

### B4. Arrays as the spine of the commonest ring  [measured and closed]

`../rc-walk.md` calls the array the spine of the commonest PHP cycle, and
arrays are copy-on-write, so they keep their count under every regime. The
node asked whether the walk can read an array's storage differently from
an object's fields.

**It already does, and the layout is not where the cost is.** The array
arm reads the storage head under a version and gives the array up when the
two readings disagree, then picks a stride from the tag (`ll-model`
`src/walk.rs`, `src/array/head.rs`), where the object arm chases the class
word. A vector's key is its position, so only the value is a cell; a hash
entry's string key is a counted child beside the value, so a hash row
carries two. The third tag, a typed vector, no producer stamps and the
walker refuses rather than striding.

**Measured 2026-08-22**, `ll-model` `dev/BENCHMARKS.md`, five arms in one
binary: 23 ns the storage head once per array, **43 ns a cell in array
storage against 47 ns a cell in an object body**, medians over six runs
with overlapping spreads. Per cell the two containers are
indistinguishable, so an array's whole structural excess is the head read.
Probe: `collector::tests::what_an_array_row_costs_the_walk`.

**What the measurement changed, and it is bigger than the node.** A cell
costs 43-47 ns and a leaf row 40-54, so an edge costs about what an entity
does: **the walk's mass is edges, not rows.** B1's acyclic skip removes
rows and no edges, which is the smaller half of the work; B6's skip by
block removes both for a uniform block, and the head read with them. The
ratio of edges to entities in a real heap therefore joins the corpus scan
of A6 as a quantity that decides between them.

**The floors are floors.** Every filled cell in the probe names one shared
entity, so the `IN` increments hit one cache line where a real heap
scatters them; both cell figures are lower bounds.

**And the ratio it needed now has a first value**: 1.4 to 1.6 counted edges
per entity in a booted Laravel container, node A6. At that ratio edges carry
about three fifths of the walk and rows two.

### C1. The background cadence  [open; two candidates eliminated, three named in their place]

Open question 1 of `../rc-walk.md`, undecided since 2026-07-28: how much
deferred memory, how many suspects, or how long since the last epoch
justifies a background epoch while nothing is failing. The pressure half is
decided — the allocation-failure path climbs the self-help ladder.

**Parked volume was picked on 2026-08-22 and is eliminated, by the formula
that was cited for it.** Parked volume is churn rate times epoch duration,
so with no epoch in flight it is zero, and the code says the same
mechanically: a free parks only while `deferred_free::active()`, a bit that
`begin_epoch` sets and `end_epoch` clears (`ll-model`
`src/memory/deferred_free.rs`, `src/memory/stdapi.rs`). The quantity cannot
cross a threshold under the condition the trigger exists for — nothing
collecting.

**The suspect count was named next, and the design of record does not have
one.** A suspect is an entity whose count was decremented to a non-zero
value, and enrolling one is the candidate buffer of `rc-trace`, the regime
this design replaced (`ll-model` `src/gc.rs`). Under `rc-walk` that arm of
`ll_release` is not compiled: the path calls `release_word`, the death
branch acks the handshake, and the non-final release carries no test at all
(`ll-model` `src/refcount.rs`), candidates being computed by the walk
instead — which the same file calls the design's advertised net reduction
on this path. So the quantity does not exist to be read, and creating it
means restoring the store on the release path that the regime was chosen to
remove.

**Three quantities the crate already keeps, and the cheapest is the worst.**
`memory_stats` reads `blocks_out` in O(1) from counters kept on pool get and
put (`ll-model` `src/memory/stats.rs`), and the crate refuses it as an
instrument in its own words: it is process-global over every consumer —
arena, heap, buffer, immortal, large — and it moves only once a block empties
or is commissioned (`ll-model` `src/memory/heap.rs`). A request that
allocates arena memory and no counted entity moves it; a cycle population
growing inside blocks already committed does not.

**The per-block occupancy counter is nearer the quantity, and is cheap for a
reason that does not survive being read.** `BlockPrivate.used` is raised in
`alloc` and lowered in `free` over the entity-block population, one word per
block written where the block header is already in hand (`ll-model`
`src/memory/heap.rs`). It shares a cache line with the block's owner, free
list and bump cursor, and the crate has the price of making a word of that
line collector-visible: an atomic bump cursor cost 14 % on larson
(`ll-model` `dev/BENCHMARKS.md`, 2026-07-26), on a word that moves once per
carve where this one moves on every allocation and every free. The counter is
free to the mutator and not free to a collector that reads it.

**And it covers one of the four populations the walk enumerates.** The
snapshot takes entity blocks, pooled large-entity blocks, retained
former-arena blocks and OS-direct entity runs; only the first keeps `used`, a
retained block holding its occupancy in its own index and a large-entity
block holding one occupant and no count (`ll-model` `src/memory/heap.rs`,
`src/memory/retained.rs`). An arena reset that promotes survivors into
retained blocks rewrites their category to `GcHeap` in place, so the walkable
population grows while the sum does not move. What sums `used` today is a
per-thread test oracle over one thread's owned chain, not a global
instrument, and it is owner-private besides: a cross-thread free deliberately
leaves the counter alone until the owner collects.

**The walk hands back two numbers for nothing, and neither is an allocation
rate.** `EpochStats` carries `stamped_new` — the slots the walk met reading
zero or the current number, so entities born since the previous walk *and
still alive when the walk reached them*, of any category, the stamp preceding
the category test — and `confirmed`, the epoch's yield (`ll-model`
`src/collector.rs`); `close` returns the struct and every caller drops it. The
first misses everything born and dead between two walks: at a churn of three
populations per epoch it reported 9 497 against 30 000 births (`ll-model`
`dev/BENCHMARKS.md`, 2026-08-22). The second is the back-off a cadence needs
to stop re-walking a heap that returns nothing.

**What would answer this node:** a threshold over occupied entity slots with
the back-off `confirmed` supplies, or a further quantity nobody has named.
The threshold is not this crate's to give: every workload in `ll-model` is
hand-built, so a rate measured over one is
the probe's own loop bound read back, and the gate `../rc-walk.md` puts on
a starvation measurement stands. Two answers below it change the numbers
rather than the shape: C2's exemption removes the parked records of
entities dying before the second walk that meets them, and B4's figure
makes an epoch's price edges as much as rows, so a threshold written in
entities is not written in the walk's currency.

### C2. The young-free exemption  [curve measured; two readers and a missing publication keep it open]

`../rc-walk.md` carries it in the backlog: an entity whose epoch byte reads
0 or the current number at free time is in no snapshot row and no
component, so its slot appears recyclable rather than parked, at the cost
of one byte test on the cold parked path. The design asks for a proof pass
before the measurement. **The pass holds, and the reason is that the test
is the walk's own skip predicate spelled backwards.**

`walk_rows` enrols a slot only when its count is non-zero, its stamp is
neither 0 nor the current number, and its category is `GcHeap` (`ll-model`
`src/collector.rs`). A stamp of 0 or current is exactly the allocate-black
branch: the walk stamps such an entity with the current number and skips
it, and it stamps **only** there, so an enrolled entity keeps the older
number it was met with. So the byte at free time answers the question the
exemption needs — whether this entity was enrolled — and answers it with
the same predicate rather than an inference about it.

What the parking protects is slot identity: an id must name one entity from
walk to drain. Every consumer of an id names an enrolled entity — the row
vector, the edge list, and the members of a posted message. An exempt
entity is in none of them, so recycling its slot confuses nothing. A
recycled slot refilled mid-epoch takes a fresh header with stamp 0, which
the walk skips in turn, so no slot gains a row after the fact.

**A mid-teardown slot is covered by the stamp and not by the occupancy
test**, which a draft had it the other way round. The teardown guard raises
the count for the duration of `__destruct`, so the walk can meet a dying
entity at count 1 and fall past the occupancy skip — `ll-model`
`src/object.rs` names the consequence itself, a phantom row. What decides
the case is the byte: a mature entity mid-teardown reads an old number, is
enrolled, and its slot parks; a young one takes the allocate-black branch,
gains no row, and is exempt. So the exemption is sound here for the same
reason as everywhere else, and the occupancy argument is not available.

**The proof is incomplete, and a review round found where.** Two readers of
a slot identity live outside the epoch's own vectors, and the exemption
removes their protection too.

- **The synchronous collection is a second walker.** `collect_cycles_inner`
  enrols every `GcHeap` slot with no epoch-stamp test at all, keys a map by
  address and places raw guards (`ll-model` `src/walk.rs`), and
  `../rc-walk.md`'s ladder lets it run while an epoch is in flight on the
  argument that frees still park. A young entity is in its tables, and the
  exemption recycles that slot from under them.
- **A block can empty and retire, and the failure is corruption rather
  than a missed verdict.** Parking is what keeps a block from emptying,
  returning to the pool and being re-commissioned mid-epoch. The epoch's
  snapshot holds that block's payload address, stride and slot count, so a
  block re-commissioned as a buffer is still walked as entity slots: the
  walk reads raw bytes as headers and `collector_stamp_epoch` writes into
  them. A retained block is the case [`../domains.md`](../domains.md)
  already names, and an ordinary entity block is the same case on the
  commonest event in the system. **The condition is cheap where the free
  already is:** `Heap::free` holds the block's occupancy in a register and
  branches on it reaching zero two lines later (`ll-model`
  `src/memory/heap.rs`), so the exemption can be refused on exactly that
  branch. Two gaps in that: a cross-thread free never touches the counter
  and so can never empty a block, and a retained block empties through its
  own index rather than through this one.

So the exemption needs a second condition, no synchronous collection active
and nothing that would retire a block under a live snapshot, or it is
unsound on the design's own self-help path.

**The exempt window is two epochs wide, not one.** The byte reads 0 from
birth until a walk meets the slot, and that walk writes the current number
and skips the entity, which the exemption reads as exempt in turn. So an
entity is exempt until the **second** walk that meets it: through the rest
of the epoch it was born in, and through the whole of the next one.

**The free variable is the interval between two walks**, which is the
epoch's own churn plus whatever the collector idles between epochs. A death
at position `t` of an epoch is exempt exactly when the entity's age is under
`t + W` for `W` deaths between walks, so the epoch's length alone does not
decide the share and **C1's cadence does**.

**The number is taken against that rule** (`ll-model` `dev/BENCHMARKS.md`,
2026-08-22, probe `collector::tests::what_the_young_free_exemption_removes`,
which runs three epochs of churn before the one it measures and sweeps the
idle gap). Over a constant population of 10 000 entities, a collector that
never idles: nothing exempt while a lifetime spans more than two walk
intervals, 15 % where an epoch is a tenth of the mean lifetime, 58 % at six
tenths, 77 % at one, 98 % at three. At a duty cycle of a half the same cells
read 22 %, 77 % and 91 %, and the fixed-lifetime arm goes from a third to
everything. Both disjuncts of the predicate carry weight: at an epoch per
lifetime the exempt records split 3 669 never met by a walk against 4 042
stamped and skipped by that epoch's own walk. **So "large by construction"
is withdrawn and replaced by a surface**, and what a corpus has to supply is
the age at death against the walk interval rather than a churn rate.

**The first measurement of the day is retracted**, and how it failed is
worth keeping: its arm opened one epoch and churned after the walk, so
nothing born in the loop could be stamped, only the zero disjunct fired, and
the reported shares were a floor read as the answer. The wrong closure that
came with it — "zero by construction for a heap whose entities outlive the
epoch" — is off by a whole epoch.

**Two mechanical conditions the measurement uncovered.** The current epoch
number is published nowhere a free path can read it, `deferred_free` holding
one activity bit while the counter behind `Epoch::open` stays private to the
collector (`ll-model` `src/memory/deferred_free.rs`, `src/collector.rs`), so
the number has to be published before the exemption's test can be written at
all. The byte itself does reach the park site: the releasing decrement
stores the counter half only and teardown's flag writes preserve the byte
(`ll-model` `src/refcount.rs`), so the one-byte test `../rc-walk.md` prices
is the price.

**The exemption's reach is narrower than the parked list.** Only an entity
slot carries a header, so a dying string's out-of-line payload, a dying
array's table storage and every buffer-arena chunk park whatever the
entity's age (`ll-model` `src/string.rs`, `src/memory/buffer_arena.rs`).
**Nor does a companion record need a death at all**: `body_ensure` grows a
payload by allocating, copying and freeing the old chunk, and that free parks
like any other (`ll-model` `src/memory/routing.rs`). An epoch in which a
script appends to one array parks a record per growth step with no entity
dying, and the exemption reaches none of them. Nor are the collector's own
confirmed members ever exempt: they are torn down before the epoch closes and
every one of them was enrolled, so each reads an older epoch's number.

**The corpus figure for the death half is taken**, node A6, 2026-08-22: 0.31
companion records per entity in a booted Laravel container, all of them array
storage and none of them string payload, so entity records are 76 % of what
the deaths in such a heap would park. The measured tables are a share of that
76 %, and the growth records sit outside both — unmeasured, and the reason
the parked list is not a picture of the live heap.

### C4. Do the fixpoint and stratification rungs earn their keep  [open; the first pricing was in the wrong currency]

`../rc-walk.md` open question 3: whether rung 2 (re-walk the candidate set
to a fixpoint) or rung 3 (stratify a repeatedly-acquitted garland) beats
re-running the epoch plus the forced verdict of rung 4.

**Neither rung carries the termination guarantee, and the design says so.**
Rung 2's guarantee "rests on monotone marking, which this rung alone lacks:
one touch resets the round", and it is rung 4 that restores it; rung 3 is
called an optional refinement outright. So the question is not soundness or
termination but precision: how many forced drains the two rungs remove.

**A draft priced both rungs in mutator cycles and both prices were wrong.**

- **Rung 2 does not cost an ack; it costs epoch duration.** The ack is two
  atomics, but a handshake is the collector *waiting* for one, and the wait
  is a mutator-checkpoint interval per round, repeated until two rounds
  agree. `../rc-walk.md` prices that itself — "the queue of deferred
  releases also grows for the duration of an epoch: a slower collector
  costs memory" — and epoch duration is the multiplicand of the quantity
  that bounds the whole design. Against it, rung 4's exact test runs at a
  checkpoint the thread was reaching anyway.
- **Rung 3's arithmetic is private; its output is not.** Condensing one
  component into strata posts several messages where the design charged
  one, and the mutator's cost table charges one verification pass per
  confirmed component. The epoch cannot close until all of them are acked,
  and the hot stratum is re-posted every round.

**So the question is open on both rungs**, and the comparison it needs is
between epoch duration and verification passes rather than between mutator
cycles alone. What is unmeasured is still the rate — rounds to convergence
for rung 2, and how often a repeatedly-acquitted component has a stratum
with no in-edge from the acquitted remainder — but the rate now decides a
different trade.

### C3. The pressure ladder's constants  [measure]

`R`, its doubling, the per-epoch forced-post cap, the stratification
threshold. All are measurements nobody has taken, and `../rc-walk.md` says
so.

## D. The verdict, and who frees

### D1. The hand-off and hand-back channels  [open; the constraints are now known]

Ruling 5 needs them. A specification was attempted on 2026-08-22 against
the queue in `ll-model` `src/epoch.rs` and a review round broke it in five
places. What the round produced is the requirement list any design has to
satisfy, and it is worth more than the attempt was.

**What exists.** One process-global mutex queue of confirmation messages,
each a bare vector of member pointers with **no owner field**. Beside it a
handshake flag, an ack count, and `OUTSTANDING_VERDICTS`, incremented
before the message becomes visible, whose zero is the collector's licence
to end the epoch. A checkpoint attends only when the flag is up, the count
is non-zero, or a flush is due, and then refuses a pickup while `MID_DRAIN`
is set, `TEARDOWN_DEPTH` is non-zero, **or `walk_active()` is true** — the
third gate covering the synchronous collection, which holds guards a
message may name.

**Constraint 1: the collector cannot run the tail on an ungated thread.**
The tail is the sever and the release, and every release goes through
`ll_release`, whose death branch calls `checkpoint_ack`, while every
dispose is bracketed by `teardown_enter`/`teardown_exit` and the outermost
exit calls the full `checkpoint`. On the collector's thread all three gates
are in their open default, so a tail would ack the mutator's handshake with
no mutator having reached a checkpoint — `snapshot` then runs against a
mutator that has not observed the deferred-free activity bit — and would
pick up a confirmation and drain it, running user destructors against
another thread's weak table and reset window. The reentrancy the queue
closes is a property of the release path, not of the mutator.

**Constraint 2: an uncounted hand-back never wakes anybody.** The three
pickup triggers are the only ones there are. A message that touches none of
them sits in the queue until something else raises one, so the counts it
holds pin a subgraph for an unbounded time.

**Constraint 3: a counted hand-back must not outlive its epoch.** The
counter's documented invariant is that an id names one entity from walk to
drain and that at most one epoch's verdicts are in flight. A hand-back
carries raw member pointers like a confirmation, so a message surviving a
close falsifies it — and while it survives, the external children still
carry the dead component's edges, so the next walk computes `RC − IN > 0`
for them and calls them roots. Today the window does not exist: the drain
releases the external children inside the same visit.

**Constraint 4: the queue has no owner routing, and the thread model is
undecided.** One global queue, one global ack counter, and a pickup that
pops the front unconditionally under a comment asserting single-mutator
ownership. Owner-bound duties are exactly what the hand-off exists to
respect, so the channel cannot be specified before node E1 decides whether
each actor runs its own epoch — and `../../../runtime/actors.md` closes the
other end, an actor taking outside business only at a mailbox boundary.

**Constraint 5: `drain-window.md`'s exclusivity must be re-derived, not
assumed.** [`../drain-window.md`](../drain-window.md) states that from the
post until the mutator's drain acks, the collector performs no access to
that component. Under a hand-off the collector is the party that severs and
frees after the post, so the invariant's third link is the one the design
rewrites. `DW_touch_after_post.cfg` is the kill variant that models exactly
that access.

**Two more the attempt got wrong and the round corrected.** The reason to
post the hand-back late is not that an early release would undercount — the
sever nulls a slot before it lists the child, so the release is against the
truth — but that between sever and free no user code runs at all, which
requires posting after the members are freed rather than after they are
severed. And there is no thread-exit drain to lean on: `ll_thread_exit` is
a five-step sequence with no epoch-queue step, and its own ordering rules
say where such a step could go and where it could not.

**A contradiction the round surfaced, and it decides constraint 2's
shape.** [`../pure-destructors.md`](../pure-destructors.md#purity-is-transitive)
says the external children of a pure component are inside the closure, so
the owner's release batch "runs no user code" and is mechanical and
bounded. But the closure admits P2, which keeps its destructor call by
ruling 9 — so an external child of a P2 class does run user code in that
batch. Either the sentence is wrong, or the hand-off's eligibility must
exclude a component with a P2 external child. Which it is decides whether
the hand-back needs the gated queue at all, and whether a bounded
mechanical batch could be counted the way constraint 2 wants.

**What would answer this node:** a channel design that satisfies the five,
which needs E1 first.

### D2. Cutting a garland  [closed]

Components are weakly connected — "a garland of linked garbage rings is
judged as one unit", decided 2026-07-26 (`ll-model` `src/walk.rs`). Cutting
one would bound the confirmation's pause and cost completeness: a ring cut
between two of its members is not recognised as dead on that pass.

**Closed by ruling 10**: the pause is accepted, so the reason to cut is gone.
The garland is judged whole. Edmond deferred this to Sage earlier the same
day, on the premise that the pause had to be bounded; the ruling removes the
premise, and the deferral with it.

### D3. The batch constants  [measure]

Ruling 3. The time ceiling of a freeing batch, and how far memory pressure
relaxes it.

### D4. The indivisible verification  [closed]

The exact test compares every member's count against its in-component
in-degree, recomputed from current fields, and it cannot be split. Splitting
is not merely expensive but unsound, and one example shows it: a component of
X and Y with a local holding Y. Check X — count 1, in-degree 1, passes. The
mutator then reads `$y->x` into a local, raising X's count to 2, and releases
Y. Check Y — count 1, in-degree 1, passes. Both halves agree and X is held.

Nothing beats the bound either: carrying the walk's in-degree instead of
recomputing it uses the stale number the recomputation exists to replace;
summing over the component still reads every member; trial deletion costs the
same. The test is Ω(N) reads in one uninterrupted stretch.

**Closed by ruling 10**, which accepts the pause rather than bounding it. The
lever was never the test but N itself, and N is no longer to be reduced.

### D6. WeakMap ephemerons  [open; the cost was overstated and a cheaper shape exists]

[`../../weak-references.md`](../../weak-references.md#weakmap-cleanup-is-eager-not-lazy)
records the mechanism and defers it: a value that references its own key
keeps that key's count positive forever, so the key never dies, no
notification fires and the entry is never removed. Behaviour matches PHP
8.0-8.2; Zend gained the special support in 8.3 after shipping the leak
for three years. The node asked whether the design of record closes it.

**It cannot, and the reason is the shape of the exact test.** There is no
cycle to find. With `$map[$k] = $v` and `$v->key = $k`, the map holds `$v`
by a counted edge and `$v` holds `$k` by another, so `$v` is reachable from
a live root and `$k` is reachable from `$v`. Every count is right and every
entity is live by the rules the walk applies. What PHP's `WeakMap` means
instead is that the map-to-value edge exists only while the key is
reachable **otherwise**, and a conditional edge is not something a balance
of counted references can express: the judgement is `RC − IN` arithmetic
over counted edges, while an ephemeron needs a fixpoint over reachability —
mark the key live only if something outside the map reaches it, then mark
its value, then repeat until nothing new is marked.

**What closing it would cost was overstated once.** A draft charged the
per-kind hook B4's 43-47 ns per cell; B4 measured the cost of *reading* a
cell, and the stride is already kind-dispatched (`ll-model` `src/walk.rs`),
so one more arm on an existing dispatch is a predicted branch rather than a
cell read.

**And the shape the source names is cheaper than the one that draft
rejected.** `../../weak-references.md` asks that the map's key-to-value
edges be treated as conditional on key liveness — a rule over edges already
recorded, which is the same material rung 3 of the pressure ladder works
over. Expressed in this design's terms: drop those edges from `IN`, re-add
the ones whose key still shows `RC − IN > 0`, iterate. The design already
owns a fixpoint rung and edge-condensation arithmetic, and Phase 4 already
walks the weak table at every death, which is where Zend put its own fix in
8.3.

**So the deferral is a choice rather than a consequence**, and what would
answer the node is a ruling on the edge-conditional form above — where it
runs, in the walk's judgement or in the drain's weak pass — and, before it,
how many real programs hold a value that names its own key, which is the
corpus question of A6 in one more form.

### D5. Collector-side destructor calls  [open; the case for moving them is stronger than it looked]

Ruling 8 lets the collector call a destructor proven pure, and the design
of record does not use the permission: every destructor call sits in the
mutator's prologue, after the weak nulling and before the hand-off, while
the collector's share is the sever and the physical release
([`../pure-destructors.md`](../pure-destructors.md#the-hand-off-drain)).
`../gc-horizon.md` assumes the same two-arm shape independently, so a
ruling to move a call would amend two in-force documents.

An argument that the permission should stay unused was written on
2026-08-22 and does not hold. Both of its costs were overstated.

- **The round-trip.** A P2 body nulls in-component slots as well as
  external ones, and in-component releases do not round-trip — the sever
  does them in place. So a collector-side call round-trips the same
  external set the sever already round-trips and gets the in-component set
  for nothing.
- **The order.** P2 differs from P0 in the order of child releases and that
  order is specified language surface, which is why ruling 9 keeps the
  call. That is a reason the call exists, not a cost of where it runs: the
  same order comes out whether the call precedes the collector's sever or
  the mutator's hand-off.

**And there is a real gain the argument missed.** P2 is P1 plus null-only
counted writes, and P1 permits arbitrary computation and external reads. The
prologue must complete within one checkpoint visit with no return to program
code, and ruling 10 accepts that pause rather than bounding it — so a P2
destructor with a long pure loop runs uninterruptibly inside the mutator's
prologue. Moving the call removes unbounded user computation from the one
stretch the design refuses to bound, which is what the stated philosophy
asks for: a design that spends collector cycles to remove mutator cycles
wins.

**What blocks the ruling** is not this argument but D1: a collector that
runs user code needs the thread it runs on to be gated, and constraint 1
there says it is not. **What would answer this node:** D1's channels first,
then a ruling on whether P2 calls travel with them.

### G1. The weak cell is an uncounted edge  [closed]

`../gc-horizon.md` question 7, opened by the case-book review of 2026-08-20.
A weak cell references its target with no count, so a chain anchored on a
path through it is anchored on nothing, and the exact test — which balances
counted references only — would free the referent under a live borrow. It was
the one soundness hole among the open nodes.

**Closed by ruling 11**: the value a weak-cell read produces is an owned base
case. It is counted always and elided never, which is what happens today by
the convention that a call result is owned, and is now a rule rather than an
accident of lowering. The alternative considered and refused was a
precondition on the elision rules — "the region contains no weak-cell load" —
which forbids more than the hazard: it would strip elision from every value
in a region that merely contains a `get()`.

The collector's side of the same edge is covered elsewhere: a weak cell is an
in-edge the equality cannot see, so a component naming one is judged by the
mutator, which nulls the cells inside the visit that frees, with no user code
between — ruling 8 keeps such a component off the collector's arm.

### G2. Promotion buys nothing in the counted-out categories  [open, and wider than the question]

`../gc-horizon.md` question 8. An answer was written on 2026-08-22 saying
the hazard reduces to G7 and the rest is cost; a review round broke it on
its central premise. What the round established is below, and it makes the
node larger rather than smaller.

**The early return is on any non-zero category, so there are three cases,
not two.** `ll_retain` returns before the counter word when the category
bits are set and the entity is not COW
([`../../lowering.md`](../../lowering.md#retain--release)), which covers
request-arena, immortal **and long-lived**. A long-lived entity dies —
"minimal RC or explicit free", the strategy per object type still
undecided
([`../../memory/arenas.md`](../../memory/arenas.md#long-lived-arena)) — so
there the promotion retain buys nothing and no arena discipline protects
the borrow either. That half is a hole rather than a shape,
ruled 2026-08-23: no explicit-free operation exists in this repository
for a call in the borrow's live range to reach, and whatever strategy is
chosen will not observe the early-returning retain, so the failure cannot
be written as a snippet until the strategy is. The chain edge into such a
referent is uncounted for the same reason, which is node G1's shape in a
category nobody checked.

**An arena is not always reset at a boundary: a `#[Region]` arena resets
mid-message.** A region's arenas reset when the region object dies, by
refcount or by its owner's drop
([`../../memory/regions.md`](../../memory/regions.md#definition)), and its
collector runs on its own threshold rather than at a message boundary. A
region inherits the arena discipline wholesale and shares the same two
category bits, so no lattice axis over the category can tell a region
referent from a request-arena one. **This is the one shape that fails
inside a single frame**, ruled 2026-08-23, and it fires under three
conditions: the borrow's chain runs through neither the region object —
borrow-is-use would hold its count up — nor any counted holder, whose
hold-count and retention would save the referent; the chain's root is
itself region-resident, so the counted root the lattice records has no
count behind it; and the last counted reference to the region object is
droppable from inside a call in the live range. The snippet is in
[`../gc-horizon-cases/arena.md`](../gc-horizon-cases/arena.md), open item
1.

**The reset's fixpoint frees as it goes.** Object memory is logically
freed as each destructor runs, and only the arena's pages are held until a
pure round closes the loop
([`../../memory/arena-reset.md`](../../memory/arena-reset.md#step-1--validate-trace-destruct-a-fixpoint-loop)).
A destructor's own frame is live while later destructors run, since a
child release inside it runs the next teardown, so a borrow taken in one
destructor spans another's stores.

**What the reset happens at is itself unsettled.** `actors.md` states
"actor death = arena reset"
([`../../../runtime/actors.md`](../../../runtime/actors.md#actor-memory));
what a long-lived actor does at a message boundary is *collection*
([`../../memory/arenas.md`](../../memory/arenas.md#request-arena)), and
[`../domains.md`](../domains.md) says an arena's collection is its reset
while its own table has an arena entity judged by nobody. Question 8, this
node's earlier answer, and `../gc-horizon-cases/arena.md` all read the
boundary as a reset without a source that says so.

**What survives:** the immortal category has no hazard. Those entities are
never freed, no thread-exit path tears them down, and a class descriptor
and its metadata train are immortal with the code
([`../../memory/arenas.md`](../../memory/arenas.md#immortal-objects)). The
elision there is free.

**The cost half is not a lattice question.** An immortal entity needs no
retain and no release at all, so where the compiler knows the value is
immortal the right lowering emits nothing — no call, no flag test, no
promotion. That holds for interned strings, class descriptors, `null`,
`true`, `false`, small integers and enum cases, and it holds in today's
lowering as much as under this design: a `retain` on a string literal is
dead code either way.
[`../../memory/arc-optimizations.md`](../../memory/arc-optimizations.md)
carries the runtime half only — the flag makes the operations no-ops —
and the compile-time half, dropping the call where the value's
immortality is a static fact, is written nowhere. What remains beyond it
is a field load, where the category lives in the header and not in the
type, so removing the call there needs the category propagated to the use
site.

**What would answer this node:** the compile-time elision above, which is
owed by the lowering rather than by the lattice; the long-lived category's
reclamation strategy, which `arenas.md` marks undecided; a rule that separates a
region referent from a request-arena one, or a proof that a borrow cannot
outlive a region reset; the fixpoint's relation to the checkpoint
protocol, which `../gc-horizon-cases/arena.md` open item 3 already calls
underivable; and what a long-lived actor does to its arena at a message
boundary.

### G3. Placement, raise sites, and what a landing pad releases  [ruled for pads and placement; the generator half is open]

`../gc-horizon.md` question 9. Three review rounds ran over this node on
2026-08-22 and each broke the closure the one before it produced. What
survived is in `../gc-horizon.md`, in the promotion section; what did not
is here, so the road is not walked a fourth time.

**Ruled: the raise sites join the quantifier.** That is the reading
question 9 offered first, and PH9 asserts it — "the retain is before the
invoke on every normal and exceptional path"
([`../gc-horizon-cases/adversarial.md`](../gc-horizon-cases/adversarial.md))
— as do `unwind.md`, `call.md` and `array.md`. The cost is that a
promotion is not hoisted past an allocating store, and since most loop
bodies allocate, a borrow live across one is promoted at or near its
birth. What the design keeps whole is the case it exists for: a borrow
whose horizon set is empty pays nothing at all.

**Ruled: every set the quantifier names is computed over the graph
including its exceptional edges.** The alternative was tried and it
breaks liveness itself. A value read only inside a `catch` has its last
normal-path use before the `try`, so the drop-point policy
([`../../memory/static-lifetimes.md`](../../memory/static-lifetimes.md#drop-point-policy))
releases it before the raise site and the handler reads freed memory. The
same deletion strands borrow-is-use: a borrow used only in a handler
keeps its anchor live nowhere.

**Ruled: a pad release is a release.** The claim that no horizon kind is
owed for one was wrong. A pad releases the frame's owned values, their
classes unconstrained, and eager death runs `__destruct` at each — a
destructor that stores into a live anchor path severs it there exactly as
it would on the normal path. The earlier argument proved only that a pad
does not release the *anchor itself*, which is a smaller claim, and it does
not hold for an anchor that is a static or an arena slot, neither of which
has the liveness borrow-is-use reasons from.

**Ruled: pad state is per edge and per SSA generation**, by split pads or
an ownership phi. PH22's third option, a tag, is a runtime flag written on
the normal path, and the granularity ruling of 2026-08-18 excludes mutator
work beyond the program's own code.

**Ruled: what a pad releases turns on where phase 1 selected the
handler**, not on the pad's syntactic kind. Selected in an outer frame,
the frame dies and the pad releases the owned set live at the raise site.
Selected in this frame — a `catch` here, or a `finally` that returns,
which discards the in-flight exception
([`../../../runtime/exceptions.md`](../../../runtime/exceptions.md#semantics))
— the frame runs on and the pad releases only what is dead where control
resumes. A `finally` that rethrows into a `catch` of the same frame is the
shape that defeats the syntactic reading.

**Two rules, not one, and the first was written and withdrawn twice.** The
placement rule needs the cycle condition *and* an edge rule for phis, and
they cover different shapes.

- **The cycle condition** — the promotion point lies inside no cycle the
  birth lies outside of — is what a loop-invariant borrow needs. Without
  it the latest point dominating a horizon inside a loop is inside the
  loop, and the retain runs per iteration against one release. Nothing
  else reaches that shape: the borrow is loop-invariant, so SSA gives it
  no header phi.
- **The edge rule** is what a loop-carried borrow needs, and it is PH20's
  own assertion rather than a new invention: phi liveness belongs to
  incoming edges, so a promoted phi is owned on each edge, the retain
  sits there, and where the edge replaces a previous instance the order
  is the store barrier's — retain the arriving value, then release the
  replaced one. An earlier draft said "a phi is an overwrite, so the value
  it replaces is released there"; that is block-granular, which PH20
  refuses, and it left the order unstated, so two edges naming one entity
  could drive its count through zero. It also generalised a rule the
  repository states for heap-slot stores only, and which
  [`../../memory/arenas.md`](../../memory/arenas.md#the-reverse-direction-request-arena--heap)
  makes an exception to.

**The generator half is not derivable and is back open.** A draft closed it
by treating the destruction of a suspended generator as a cleanup pad with
the suspension point for a raise site. The frame model is undecided:
[`../../../runtime/exceptions.md`](../../../runtime/exceptions.md#inlining-and-generators)
is a deferral naming two shapes that "differ completely", and under the one
PHP's own rule points at, a suspended generator has no frames at all, only
a data structure — no frame, no pad. `Generator::throw()` is a second way
into a `finally` around a `yield`, with the frame alive, so the "exactly
one incoming edge" the draft rested on is wrong. And selecting a set per
suspension point needs a resume index, which is a runtime tag written on
the normal path — PH22's third option, excluded by the granularity ruling
of 2026-08-18. [`../gc-horizon-cases/suspension.md`](../gc-horizon-cases/suspension.md)
is a hole report for exactly this, and it stays one.

**Owed elsewhere:** oracle A1 of `unwind.md` asserts the pad's set equals
the owned locals live at the raise site, which is now true of a dying
frame only; the promotion-point wording is quoted without the amendment in
`../gc-horizon-states.md` and in six case files. Both are step S5.7 of
`../../../dev/PLAN.md`.

### G4. COW and unique ownership intersect  [ruled; the trigger set stays open]

`../gc-horizon.md` question 10. **Ruled by Edmond, 2026-08-22: COW wins**
(`../../../dev/DECISIONS.md`). The unique-ownership proof establishes
lifetime — one owning slot, death at the overwrite — and lifetime is not
what the separation test asks, so the proof neither answers that test nor
licenses removing the count. A COW-eligible entity keeps its count
whatever else is proved about it, and the intersection is empty rather
than contradictory: the occupancy sentinel and the COW flag never sit in
one header.

The elision licence
[`../../values.md`](../../values.md#refcount-is-always-maintained-on-cow-entities)
grants — a pair may be elided "only where it has proved that no second
holder arises" — is therefore not discharged by the uniqueness proof. The
road it does open is node A8: prove COW itself unnecessary and clear the
flag, after which the entity is no longer COW-eligible and unique
ownership applies to it normally.

**What stays open is the trigger set, which the collision only exposed.**
Two defects survive the ruling because neither is about COW.

- **A retain against the sentinel from a base case.** The unique-crossing
  base case ([`../gc-horizon.md`](../gc-horizon.md#the-ownership-lattice))
  classifies a borrow as owned *because* the entity is unique. Where the
  borrow's target is that entity — `$n = $this->e` on the owning slot —
  the retain lands on the sentinel, and the demotion trigger set names
  convention retains and horizon-reaching borrows only, so nothing fires.
  Reading the set as a closure over the lowering does not repair it: the
  base case's predicate is the verdict the set computes, so the two
  oscillate. Evaluated once against the lowering computed under the
  assumption of uniqueness, and never revisited, it terminates — and that
  one-pass rule then demotes every entity ever loaded into a local, whose
  cost is node A3's share and A6 has not measured it.
- **A release against the sentinel.** `new` is owned by the lattice, which
  absorbs the creation reference and releases at the drop point
  ([`../gc-horizon.md`](../gc-horizon.md#the-ownership-lattice)), while
  the owning store into a unique slot takes no count — so the temporary's
  release drives the sentinel to zero, which is eager death, a destructor
  call, a free, and a walker reading an occupied slot as free. Either the
  trigger set names release sites, or the owner's allocation is specified
  as a move that consumes the temporary.

**What would answer this node:** a written trigger rule that is one-pass
and that names release sites as well as retain sites.

### G5. The trusted-effect boundary  [design]

`../gc-horizon.md` question 11. A stored callee summary is not the only
source of effect knowledge — body analysis, builtin models, ABI contracts,
the joined models of a closed multi-target call establish the same facts.
The design needs one source-independent rule for sufficiency, trust,
composition, freshness and invalidation.

### G6. The summary language  [design]

`../gc-horizon.md` question 1. What a summary states, who writes the ones for
the standard library, the conservative default at every unknown, and the
versioning rule.

### G7. Borrow scopes across suspensions  [design]

`../gc-horizon.md` question 2, and the case book's two hole reports
(`../gc-horizon-cases/closure.md`, `../gc-horizon-cases/suspension.md`). A
yield is a horizon unless the summary system learns resumption points, and a
fiber suspended across an arena reset carries frame borrows the reset cannot
see. `gc-horizon.md` marks it as shaping the IR early, which puts it before
most of section A.

### G8. Anchored parameters  [design]

`../gc-horizon.md` question 6. Whether caller-guarantee summaries can lift
the receiver and by-value parameters out of the owned default, and what the
re-entrancy obligation costs there.

### G9. One borrow analysis, or two  [design]

`../gc-horizon.md` question 5. One IR-level borrow analysis parameterized by
the invalidation set, serving unique ownership and the horizon together. The
working default recorded 2026-08-18 is one analysis with two invalidation
sets, with Edmond's veto open.

**Closed by the refusal of 2026-08-22:** `../gc-horizon.md` question 12,
selective collector-computed counts. That is Form C, and the capture-count
regime is its descendant.

## H. Verification debt

### H1. Both model-checker specifications model a protocol that is gone  [scoped by a run; the re-derivation is unstarted]

`../../../dev/tools/rc-walk/README.md` and `../drain-window.md` record the
drift: the TLA+ specifications were written against the pre-amendment
protocol, while eager death is the premise of everything since.

**The battery is alive, and it agrees with itself.** Run whole on
2026-08-22, OpenJDK 21 with the vendored TLC: 22 scenario configs against
`RcWalk.tla` and 4 against `DrainWindow.tla`, **all 26 matching the
expectation recorded for them** in
[`../rc-walk-proof.md`](../rc-walk-proof.md) — every sound config
exhausts clean, every kill config ends in its violated invariant, and the
two liveness kills (`SC_dtor_reentrant`, `SC_nosever`) end in a violated
temporal property. Scenario runs take seconds. So the instrument works
and the specs have not rotted; what is wrong with them is what they
describe.

**What green there does not say.** The specs carry a shared condemned
byte, the F5 death deferral and message-based acquittals with drain
duties ([`../rc-walk-model.md`](../rc-walk-model.md), the 2026-07-27
banner). The protocol since the amendment has none of the three:
condemnation is collector-private, every death is eager, the drain drops
on any zero-count member by the corpse rule, and an acquittal posts
nothing. A green battery is therefore evidence for the superseded rule
set — except where a scenario exercises machinery the amendment kept,
which the banner itself says is most of it: the walk, the filter, the
exact test, the sever and the deferred queue.

**What the re-derivation has to change**, and it is a list rather than a
rewrite: the condemned byte leaves the state vector; the death action
loses its deferral arm and commits at zero; the acquittal action stops
posting and becomes collector-private; the drain's entry condition
becomes the corpse rule. Then the rulings of 2026-08-22 add what has no
model at all — the collector as the freeing path, the hand-off and
hand-back crossings of node D1, and the batch bound of D3.

**What it blocks:** any model-checker scenario written today inherits the
drift, so the re-derivation is a precondition of that instrument rather
than a task beside it — which is what
[`../gc-horizon-cases/README.md`](../gc-horizon-cases/README.md) already
tells the case book about its third candidate oracle.

### E1. Actors and the epoch protocol  [structures resolved 2026-08-23; the stamp half stays open]

Refcounts are non-atomic and the crate is single-mutator
(`../rc-walk.md`). The node asked whether each actor runs its own epoch,
and what the collector's single shared write — the epoch stamp — becomes
across several of them.

**The stamp is single-writer today, and not for the reason a draft gave.**
That draft argued that only the general heap has an epoch, so the byte has
one writer. Two things refute it. There is no general heap in this memory
model — every block belongs to some thread's heap, which
`../../../runtime/actors.md`'s own open list records and node E3 repeats —
and an actor's memory is not only its arenas: a provably transferable
object is born directly in the general-heap category and held by the actor
while hosted by whichever pool thread mounts it. Second, the walk stamps
outside the category it enrols: `walk_rows` writes the stamp and *then*
tests the memory category (`ll-model` `src/collector.rs`), so the first
epoch that meets a slot reading zero or the current number stamps it
whatever its category, while only the `GcHeap` ones ever get a row. The set
that reaches the walk is `GcHeap` and `LongLived` together — the entity
blocks both allocate from, the walker skipping the second by category per
entity (`ll-model` `src/memory/routing.rs`) — plus the three populations the
same snapshot adds: pooled large-entity blocks, retained former-arena blocks
and OS-direct entity runs.

What actually keeps one writer is that the protocol is one-at-a-time by
construction: the epoch number, the handshake flag, the ack counter, the
verdict queue and the outstanding count are process-global statics and
opening an epoch asserts that epochs do not nest. Two collectors would
reach the same header through the global block registry, each reading the
other's number as an old stamp — [`../domains.md`](../domains.md) invented
a per-block "epoch it was snapshotted in" field for that reason and noted
that a bare 1-255 number does not say whose epoch it is. **So the stamp
half is not answered; it is held by the same single-mutator scaffolding
E1's other half is about.**

**The ownership half is worse than "undecided": two in-force documents
disagree about what an owner is.**
[`../../../runtime/actors.md`](../../../runtime/actors.md#serial-execution-without-thread-affinity)
says an actor is not bound to a thread — the scheduler runs it on whatever
pool thread is free and it may migrate between messages, the invariant
being only that at most one thread executes it at a time.
[`../../weak-references.md`](../../weak-references.md#the-weak-table-address--subscriber-row)
builds the weak table **per thread**, calls entities thread-confined, runs
every notification on the owning thread, and disposes the table at thread
exit. It never mentions actors.

The two cannot both hold. An actor creates a weak reference while mounted
on one thread, so the row lands in that thread's table; the actor migrates;
the entity dies on the new thread, which looks in its own table, finds no
row, and never nulls the cell. The old thread then exits and disposes a
table still holding rows for live entities.

**Half of this is already recorded, for a different resource.**
[`../domains.md`](../domains.md) noted on 2026-07-28 that a transferable
entity promoted out of an actor's arena lands in the entity heap of
whichever pool thread was mounting the actor, "so its host is a thread while
its holder is an actor", and called the payload table and the allocation-site
selection owed a re-derivation. The weak table is the same crossing over a
second resource, and the drain gates, the reset window, the journal ring and
the park list are the same crossing over four more.

The same question decides the rest of the protocol's TLS: `MID_DRAIN` and
`TEARDOWN_DEPTH` are thread-locals guarding a drain whose entities belong
to an actor, the reset window and the journal ring are owner-bound the same
way
([`../pure-destructors.md`](../pure-destructors.md#the-five-owner-bound-races),
race 5), and the deferred-free park list is thread-local and flushed by its
own thread ([`../domains.md`](../domains.md)). Each is correct while the
owner is a thread and wrong once the owner is an actor that migrates.

**What would answer this node:** one ruling on what an owner is — a thread,
or an actor context the scheduler mounts — after which the weak table, the
drain gates, the reset window, the journal ring and the park list follow it
rather than each being decided separately. **What it blocks:** node D1,
whose channels cannot be routed to an owner that is not defined.

**Most of the structural half closes on 2026-08-23, and not by a ruling about
owners.** Two facts of `../../../runtime/actors.md` bound it. An actor's own
memory is collected by the actor itself, at its message boundary, on the thread
executing it — no poll safepoints inside actor code, the scope being one actor's
arenas, and the concurrent part shrinking to "the general heap outside any
actor". And nothing enters an actor except through the queue, so its object
graph is closed by construction. Inside an actor there is therefore never a
second thread to disagree with, and the drain gates, the reset window and the
journal ring, all of which live inside one execution, need no owner assigned.
The deferred-free park list is a thread resource on its own evidence: the list
is thread-local and the frees it defers are bound to the heap that issued the
block (`ll-model` `src/memory/deferred_free.rs`), and an actor's own memory is
returned by arena reset rather than parked. The static-block registry is
disposed at thread exit and was never actor state.

**What is left of the ownership half** is the weak table and the general heap.
For the weak table Edmond ruled on 2026-08-23 that a weak reference does not
cross the actor queue — an object holding one is not sendable and an object that
is the target of one may not be moved
([`../../../dev/DECISIONS.md`](../../../dev/DECISIONS.md)) — so a cell and its
target stay in one actor, and the rows are the actor's. What the table's
per-thread residence then owes is the mechanism: rows keyed by actor, rows
following the actor, or an actor pinned while it has subscribers. For the
general heap the stamp half of this node stands unchanged.

**Three obligations were added to this node on 2026-08-23**, by the review
chain over the context-aware calling convention
([`../../../dev/DECISIONS.md`](../../../dev/DECISIONS.md)). First, the
assignment of the six per-thread structures splits in two before it can be
made: some are thread-owned resources correct under a thread invariant — the
block header's owner, the C-standard allocator surface, the buffer arena —
and are not waiting on this node at all, while the rest are actor state and
are. Second, a crossing into foreign code needs an entry mark saying a thread
is out of the ack population, and the measurement that would justify it
against the standing 2026-07-25 rejection. Third, that crossing needs a
re-entry mechanism for a callback, and this chain established two constraints
on it: it must survive a `longjmp` that skips the compiler's bracket, so a
discipline resting on drop glue will not do, and it must answer a callback
arriving on a thread that never entered.

### E2. AArch64 header access  [hardware]

`../rc-walk.md` open question 2. x86-64 is settled — plain moves, no lock
prefix, no read-modify-write. The instruction half of the AArch64 claim is
settled too; the cost half is not, and no machine here can take it.

### E3. The domains proposal sits behind E1  [sorted; the largest hole is named by the proposal itself]

[`../domains.md`](../domains.md) is the standing multi-mutator design and
carries its own open list, which E1 as a single node hides. Sorted by what
the epoch protocol actually needs:

**E1's question wearing another hat.** The list's actors item, recorded
2026-07-28, says `actors.md`'s allocation-site selection assumes a general
heap owned by no domain, that this memory model has none, and that a
transferable entity promoted out of an actor's arena therefore has a thread
for a host and an actor for a holder. That is E1, and it is owed a
re-derivation there rather than here. It is also the sentence that refuted
E1's first draft, which argued from a general heap that this item says does
not exist.

**What the epoch protocol needs before anything else.** Three items, and
the proposal ranks the first itself:

- **A domain dying mid-epoch** — an epoch nobody will close, a parked list,
  a weak table — which `../domains.md` calls the largest hole in the model.
  It is also what makes D1's constraint 4 sharp: a channel routed to an
  owner has to say what happens when the owner goes.
- **Per-domain enumeration does not exist.** The snapshot is global today
  (`ll-model` `src/memory/heap.rs`), which the same file's inventory of
  single-mutator points already records.
- **The drain-exclusivity window is proven for one mutator**, and the
  re-derivation is owed — the same third link node D1 rewrites for the
  hand-off, now for a second reason.

**What is the movable-value design and does not touch the walk.** Frozen
from birth or after the send, `~=` on a DAG, the move's counter semantics,
where the resurrection ban is raised, what the arena copy of I6 owes, and
whether a `shared` class may have a destructor at all. They belong to the
proposal and are cited here so nobody folds them into the collector's
questions.

**One hard limit worth surfacing, because it is the same shape as A7's.**
The box that gives a shared entity its per-domain handle needs an entity
kind, and the kind field has **exactly one code left**, which `resource`
also wants ([`../../layouts.md`](../../layouts.md)). Three bits, seven kinds
assigned, one spare, two claimants.

**What would answer this node:** nothing here, until E1 says what an owner
is. The sorting above is what this node contributes.

### F1. Barrier forms  [read]

LXR's field logging and SATB are already in this repository. Coalescing
(sliding-view) reference counting, Levanoni and Petrank, is not, and is the
shape A5 asks for: one log entry per object per epoch rather than one pair
per write. Feeds A5.

### F2. Cycle collection  [read]

Arborescent GC (ISMM 2025) is the only published shape found that decomposes
D4's global question into local ones — a spanning forest inside the program's
own graph, checked locally on each edge removal. It costs about two words per
object. Feeds D2 and D4, which have no other candidate.

### F3. Partial tracing  [read, record only]

**Concurrent Deferred Partial Tracing (PLDI 2026) is the published form of
the capture-count regime** — "DRC counts heap edges and traces the roots; PT
counts the roots and traces the heap" — and it carries the same blocker this
design refused it for, destruction timing. Recorded so that the refusal is
findable against the literature. Nothing in it is proposed for this design.

## Inherited record

The capture-count regime and the two reviews that closed it are kept in
[`../gc-horizon-v2/questions.md`](../gc-horizon-v2/questions.md), nodes M
and N. Nothing in this graph re-derives them.
