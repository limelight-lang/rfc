# The second design at the top level

The GC horizon decides which local references carry a reference count
and where the ones that do not pay for their safety. The first design
pays with a count ([../gc-horizon.md](../gc-horizon.md)). This one pays
with a publication the collector reads, which removes the mutator's
reference count from a whole class of entities.

Nothing below is implemented, and the parts of the first design this one
does not touch — the ownership lattice, the horizon list, the placement
rule — hold unchanged.

## Principles the design is judged by

Stated by Edmond, 2026-08-21, and placed first because the rest is judged
against them.

**Many short arms of collector work beat few long ones.** The literature
this design was placed against agrees from three directions: LXR's premise
is that "regular, brief stop-the-world collections deliver sufficient
responsiveness at greater efficiency than concurrent evacuation", and it
modulates the length of each arm with survival-rate prediction and work
budgets; Iso collects at a request boundary because the live set is near
zero there, which is the same trade taken to its limit; and ORCA collects
one actor between two behaviours ([prior-art.md](prior-art.md)). The
counter-example is recorded in the same place — the OCaml team found their
stop-the-world minor collector beating the concurrent thread-local one in
almost every circumstance, which is again short and simple over long and
clever.

**A collector that can be entered from the mutator as well as from the
collector thread is more flexible than one with a single entry.** The
mutator knows things the collector does not: which entity was just
released, which local just went out of scope, that memory is needed now.
`unset` is the first such entry, and the design has to work when
reclamation runs in the middle of ordinary program code.

**So the algorithm has two modes, and they are different algorithms.**

- **Fast, in the mutator.** Bounded work over a **named candidate set** —
  the entities the mutator has reason to suspect, not the heap. It decides
  and frees what it can and gives up on the rest rather than widening. The
  `unset` attempt below is its first instance.
- **Full, in the collector.** The whole walk: rows, edges, `RC - IN`, the
  exact test, cycles.

**The epoch serves both.** It is what tells either mode what it must not
judge: an entity stamped new is skipped by both, and its age is left
intact for every policy that reads it.

Two things this owes, neither settled. The candidate set is a mechanism
this repository has removed once: the header's candidate-buffer index went
away with the eager-death amendment, freeing the top half of the flags word
([../rc-walk.md](../rc-walk.md#the-one-header-byte)), so a candidate set
returns as a plain list rather than as header state. And the fast mode runs
outside the drain-exclusivity window, which is question L.

## The problem, and the three answers to it

The collector has to know which entities the program's locals hold. An
entity a local holds and nothing else references is reachable, and a
collector that cannot see the local frees it.

**Answer 1 — read the stack.** Stack maps, a safepoint and a
handshake. `rc-walk` cannot use it: the walk reads the heap
concurrently, through unsynchronised and stale loads, and never stops a
mutator ([../rc-walk.md](../rc-walk.md)). A stack cannot be read that
way, so this answer costs the property the collector is built around.

**Answer 2 — count the locals.** Every reference from outside the walked
heap is counted, so the walk derives the root set instead of collecting
it: `RC - IN > 0` means something outside the walked heap references the
entity
([../rc-walk.md](../rc-walk.md#the-central-identity-roots-are-derived-not-enumerated)).
This is what Limelight does today, and the frame announces itself
through the count it takes. The price is a `retain`/`release` pair per
local reference.

**Answer 3 — prove the local is already covered.** A borrow whose anchor
chain ends in a counted root needs no count of its own, because the
root's count already keeps every entity on the chain alive. The compiler
pays only where the proof stops, and that point is the horizon. This is
the first design, and its payment is a `retain` that turns the borrow
into an ordinary owned local.

## What this design changes

A count is one way to tell the collector that an entity is held from
outside the heap, and not the cheapest. A publication the collector
reads during its own walk carries the same information. Once the
horizon pays by publishing, an entity needs no mutator-maintained
reference count at all: no pair on ordinary local traffic, no write
barrier on stores between such entities, and one obligation left —
publish at each point where the compiler's proof stops. Edmond's name
for that obligation is the **uncertainty barrier**.

The collector then computes what the mutator no longer maintains. It
already walks the heap and enumerates edges, so an entity whose incoming
edges are all internal to the walked heap needs no header count for the
walk to judge it; what the walk cannot see is the reference held in a
frame, and that is exactly what the publication supplies.

## The one price: the capture count

For an entity in the deferred regime the count word stops counting
references and counts **captures by code** — the places where the program
itself holds the entity. Heap-internal edges are absent from it, the
collector enumerating those by walking. `retain` increments the captures
and the collector reads a positive capture count as roothood; `release`
decrements, and zero means the code holds the entity nowhere, not that the
entity is dead. No death branch runs at zero and no destructor fires:
reclamation is the collector's, by reachability.

The operation is today's, unchanged. Under `rc-walk` `ll_retain` loads the
header once as a relaxed atomic word, branches on the category bits, and
stores back only the four-byte counter half — a narrow write, no atomic
read-modify-write anywhere, because the count has one writer and the
collector never writes it (`model/src/refcount.rs`). What the deferred bit
changes is the meaning of the word, not the instructions.

**This is not a new kind of header state.** The runtime already reuses the
count word for a count that is not a lifetime count, gated by a flag:
`IS_ESCAPEE` says that a request-arena entity is referenced from one or
more longer-lived containers, and "while set, `refcount` holds the escape
hold-count instead of a lifetime count — arena objects are not
lifetime-counted, so the field is free" (`model/src/refcount.rs`). The
capture count is that hold-count generalised to a second population.

**An expiring mark was considered and dropped** (Edmond, 2026-08-21). The
proposal was to publish roothood by writing 0 into the epoch byte at each
horizon, which costs one byte store and needs no release, the walk clearing
it by ageing. Two objections killed it. It overwrites the collector's
maturity stamp, so an entity that has lived for many epochs reads as
newborn and every policy that reads age loses its input. And "new" in Phase
1 means skip-entirely, so the marked entity's children lose their in-edges,
`RC - IN` inflates for all of them and none can be judged. Moving the mark
to its own free byte answers both, and was dropped in turn for a plainer
reason: a count is already being maintained for the durable case, and one
mechanism is better than two. What the mark would have saved is one
retain/release pair on a live range that crosses exactly one horizon —
which is Form A's cost for that borrow, so the second design simply does
not compete on the local-reference path.

**Where the saving is, then.** On the store path, and only there:

```php
final class Chain {
    private ?Node $head = null;

    public function push(Node $n): void {
        $n->next    = $this->head;   // today: retain + release
        $this->head = $n;            // today: retain + release
    }                                // deferred regime: nothing
}
```

Locals keep the first design's rule and pay a pair at a horizon; fields of
a declared deferred type pay nothing at all. That is the population the
optimisation was aimed at from the start — entities whose properties are
written often.

## Which slots must publish

The axis is not the memory category and not the actor: it is whether the
walk sees the slot. `rc-walk` derives its roots from the count precisely
because every slot it cannot see is counted — "a stack local, a static
block, an arena slot, an immortal container, an FFI handle. Every one of
those is counted" ([../rc-walk.md](../rc-walk.md)). The deferred regime
removes the count, so each of those slots needs its own answer.

- **A slot the walk sees** — a field of a walked GC-heap entity. The
  collector enumerates the edge itself and the mutator pays nothing.
- **A frame slot.** Nothing records it, so the compiler takes a capture at
  the horizon its live range reaches and releases it at the end of that
  range — the first design's placement rule, with the capture count in
  place of the reference count.
- **An arena slot, a static, an immortal container, an FFI handle.** Each
  has an owner that ends at a known point — the reset, the overwrite, the
  handle's close — so each can carry a capture count, and the arena's store
  barrier already takes the matching `retain`
  ([../../memory/arena-promotion.md](../../memory/arena-promotion.md)).

The arena slot gets a cheaper rule when its target is deferred, and the
reason is that eager death is what forces a count in the first place.
Today a heap reference stored into an arena container takes `retain(new)`
and an entry on the arena's release-at-reset list, because between that
store and the next collection the source may die, the count may reach zero
and the entity may be freed under the arena slot
([../../memory/arenas.md](../../memory/arenas.md)). A deferred entity is
never freed by reaching zero, so the count buys nothing: the store appends
the entity's address to a root list the collector reads each epoch, and
nothing is released at reset. Because no release is paired with the entry,
the prohibition on compacting that list — deduplication would release early
while an arena slot may hold the only reference — does not apply to the
deferred half, and the list may be a set.

What that costs is a change of reading schedule. The release-at-reset list
is read once, at reset; a root list is read at every epoch while the arena
lives, and it grows monotonically through the request.

## What forces a class to stay counted

Two things, and both are structural rather than about the moment of death.

1. **A COW-eligible value** — array, string, reference box. Its uniqueness
   test reads the count while the entity is alive
   ([../../values.md](../../values.md#copy-on-write-protocol)), so the
   count is doing work that has nothing to do with reclamation.
2. **An entity the walk does not collect at all** — arena, immortal,
   unique ownership, compiler ownership. There is nothing to defer,
   because nothing about its liveness was ever computed from a count.

A destructor is not on the list. The mutator runs a destructor either way:
today a condemned cycle's members are freed by the collector and their
destructors are called by the mutator at a checkpoint through the drain,
and a deferred entity takes the same path. What deferral changes is the
delay between "no one holds it" and "the destructor runs", which is a
tuning question. Weak references are the same shape: the collector clears
the cells of what it frees, exactly as an arena reset already walks the
arena's weak list for objects that die with their pages
([../../weak-references.md](../../weak-references.md)). Both were on an
earlier revision's list and Edmond struck them off on 2026-08-21.

What the deferral does cost in both cases is the moment, and that cost is
visible: `WeakReference::get()` keeps returning an entity whose last strong
reference is gone until the collector notices, where PHP nulls it at once
for an acyclic object and only delays for a cycle member. The `unset` rule
below returns the prompt behaviour to the population that observes it, and
what remains is recorded as question K.

## `unset` is an explicit attempt to reclaim

For a deferred entity `unset` does not lower to nothing. It lowers to an
explicit call that **tries** to reclaim the entity there and then, and
gives up silently when it cannot prove the entity is dead.

The attempt succeeds when two facts hold together:

- the entity never entered the heap — no store put it in a field or an
  array element, so no uncounted internal edge can reach it; and
- the capture count reaches zero at this `unset`, so no frame, arena slot,
  static or handle holds it either.

The first fact is what makes the second conclusive: for a deferred entity
internal heap edges are not counted, so a zero capture count on an entity
that did escape says nothing. On success the entity dies with PHP's own
timing — the destructor runs, the weak cells clear, the memory returns —
and none of that cost anything on the store path, because the entity was
never counted.

Who establishes the first fact is open. The compiler can establish it
statically, by finding no store site whose value is this local, which costs
nothing at runtime and fails closed on anything it cannot see. Or the store
path can set a header bit the first time an entity is stored into a heap
slot, which is exact but puts one unconditional write back on the store
path that deferral exists to keep empty.

The risk is stated plainly: an unsound non-escape proof frees a live entity
with no runtime guard, because there is no count to contradict it. The
detector is the shadow-count lowering
([../gc-horizon.md](../gc-horizon.md#verification-artifacts-a-precondition-of-implementation)),
and the whole-program condition the first design already states for
unique ownership applies here unchanged.

## Who judges a deferred entity

**Provisionally settled 2026-08-21, conditional on one measurement.** The
concurrent walk cannot judge deferred space: with no count on a heap edge
into it, the collector's observations are identical whether a reference was
moved or dropped, so no verdict function separates the two
([questions.md](questions.md), M). The division that answers it is the one
`rc-walk` already uses, with a different re-check:

- **The collector supplies suspects.** It walks as it does today, deferred
  entities included, and posts what looks dead. Nothing it says is acted
  on, exactly as now — "the collector never frees anything itself — and the
  drain trusts nothing it was told" ([../rc-walk.md](../rc-walk.md)).
- **The mutator finalises.** For a counted member the re-check is
  arithmetic: the count equals the in-component in-degree. For a deferred
  member there is no arithmetic, so the re-check is a **trace over the
  deferred subgraph from the deferred roots**, run in a window where the
  mutator executes nothing else.

The collector may therefore err in one direction only, and both directions
are already handled: a missed corpse waits for the next epoch, and a live
entity wrongly suspected is acquitted by the trace. What the suspect list
buys is not the verdict but the decision whether to run the pass at all.

**The cost, and what is not yet known.** The trace visits `N` live deferred
entities and their `F` reference fields each — the dead are never visited,
and neither is the rest of the heap, so `N` is the only quantity that
decides the question. Two points pay nothing extra, because a traversal
happens there already for other reasons: the arena reset, which traces
survivors to place escapees
([../../memory/arena-reset.md](../../memory/arena-reset.md)), and the end of
a request. The pass is new work only at intermediate checkpoints, and those
are needed only when memory is wanted before the request ends.

`N` at an intermediate checkpoint is unmeasured, and the design is taken on
condition that it be measured. Two instruments settle it between them: a
probe on the existing crate, built on the pattern of
`memory::barrier::tests::what_a_store_costs_by_working_set`, giving trace
cost against working-set size and so the number of entities that fit a
pause budget; and the corpus scan's channel for how many are live at a
quiescent point. A third road removes the dependence altogether at the cost
of a narrower population: license the deferred regime only for classes
whose instances provably do not leave a region, and `N` inherits that
region's bound.

## The three treatments the collector owes an entity

1. **Walk it, and it may be condemned** — an ordinary GC-heap entity,
   in either regime.
2. **Walk it as a root, never condemn it** — an entity the compiler
   owns, an immortal or arena entity, and an entity a positive capture
   count protects.
3. **Skip it entirely** — no `rc[]` row, no out-edges, no in-edges.

Today the collector uses 1 and 3, and 3 is sound for one reason: a
skipped source only removes in-edges, so `RC - IN` grows for its
children and they are pinned as roots
([../rc-walk.md](../rc-walk.md)). The reason holds only while every
edge out of the skipped entity is counted. A child in the deferred
regime carries no count, nobody counts the edge into it, and skipping
its holder loses it. So treatment 3 narrows to sources whose every
outgoing edge is counted, and everything else that must not be
condemned moves to treatment 2.

## Entities the compiler owns

Ownership as Swift and Rust have it: the compiler proved that one place
owns the entity and emits the free at a known point. The collector must
not free such an entity — freeing it twice is corruption — and must walk
it, because its children can be collector-managed and the owner's edge
may be the only one that reaches them.

`Buffer` below owns its storage; `Node` can have other holders, so the
compiler proves nothing about `Node` and the collector keeps it:

```php
final class Buffer {
    private Node $head;
}
```

The edge is allowed and `Buffer` is walked as a root. The alternative —
forbidding a deferred `Node` in a compiler-owned field — needs a test on
every store into such a field, which is a write barrier, and this design
exists to avoid one. The cost of allowing it is bounded: Phase 1 already
visits every slot of the snapshotted blocks and classifies it, so what
is added for an owned entity is the `rc[]` row and its out-edges, not a
traversal.

In the RFC this case already exists as unique ownership, whose count
word holds an occupancy sentinel instead of a count
([../rc-walk.md](../rc-walk.md#unique-ownership-one-owning-slot-and-no-count)).
Its proof is whole-program — a second reference anywhere falsifies it —
which is why it is lawful today only for entities whose every access
site compiles in one session.

## The header

The flags word is four bytes at object offset 4, with the memory
category in bits 0-1, the GC handoff state in bits 2-3, the epoch byte
at offset 6, and bits 24-31 back in the free pool since the
narrow-mutator amendment of 2026-07-27 (`model/src/refcount.rs`,
`model/src/refcount/tests/the_header_the_compiler_shares.rs`).

- **The regime takes its own bit, not a fifth memory category.** A
  deferred entity still lives in the GC heap, and the census enrols only
  `GcHeap` (`model/src/walk.rs`), so a category code would take the
  entity out of the walk that is meant to count it. The category answers
  where the memory comes from; the bit answers who keeps the account.
- **Occupancy becomes `refcount != 0 || deferred`.** Phase 1 today reads
  a zero count as a free slot, and a deferred entity has no count to
  read. The word is loaded on that path already. The bit is cleared by
  whoever frees the slot, and the collector frees deferred entities, so
  the mutator pays nothing for it.
- **The epoch byte is untouched.** The mutator writes it once, at
  construction, exactly as today; nothing in this design gives it a second
  writer, so the maturity stamp keeps its meaning.
- **The capture count is bytes 0-3**, the half `ll_retain` already loads
  and branches on.

The regime test costs nothing new. Under `rc-walk`, `ll_retain` loads
the header once as a relaxed atomic word and branches on the category
bits before it touches the count, and its own comment gives the reason —
"the category tests need the flags anyway" (`model/src/refcount.rs`).
One more state in that word widens a branch that already executes.
This is a different thing from the load-path test the superseded
stack-exit model died of and the first design's Form C bars: that test
stood on every load of a value, this one on an operation that already
loads the header.

## Call sites where the class is unknown

```php
function f(mixed $x) {
    $y = $x->prop;
    work();
    $y->m();
}
```

The compiler cannot pick the regime here, and it does not have to. It
emits today's counted lowering, and the runtime does the right thing from
the header: `ll_retain` already branches on the flags word before touching
the count, so one more state in that word makes the same call increment a
reference count on a counted entity and a capture count on a deferred one.
Both are correct.

What an unresolved site cannot do is elide a store. `$bag->data = $n` on an
untyped slot emits `retain(new)` and `release(old)` as today, and on a
deferred target that pair moves the capture count for what is really a heap
edge. The collector also enumerates that edge, so the entity is counted
twice — which keeps it alive longer than necessary and never less, and the
pair still balances under any number of overwrites. Conservative, and the
declared-type rule is what turns it back into nothing.

## What changes in `rc-walk`

The first design changes nothing in the collector, and says so in its
scope ("nothing in this document changes `rc-walk`'s protocol, the
header layout, or what the mutator does at a checkpoint",
[../gc-horizon.md](../gc-horizon.md)). This one changes five things, and
the header layout is not among them.

1. **Roothood for a deferred entity is read, not derived.** `RC - IN > 0`
   holds because every slot the walk cannot see is counted
   ([../rc-walk.md](../rc-walk.md#the-central-identity-roots-are-derived-not-enumerated));
   for a deferred entity the count holds captures only, so roothood is the
   capture count itself and `IN` is what the walk enumerates beside it.
2. **The occupancy test gains the regime bit**, a zero count no longer
   meaning a free slot.
3. **Skipping stops being total** for a source with uncounted children,
   which narrows treatment 3 as described above.
4. **The walk enrols compiler-owned entities as roots** rather than
   passing over them.
5. **The drain's corpse rule splits.** Today a member reading `refcount ==
   0` is a corpse and drops the message whole. For a deferred member zero
   is the ordinary condemned state, so occupancy comes from the regime bit
   and liveness from the capture count, read from the same word.

## Open questions

Kept in full, with their dependencies, in
[questions.md](questions.md). In brief, what is still open after
2026-08-21: the cross-regime edge from a counted source into deferred
space; cycles, which no publication answers; whether the arena stays an
unwalked root source or the walk enters it; the moment a weak cell reads
null; the collector called from inside the mutator; and the profitability
threshold that selects the regime, which needs measurement.

## Record

Written 2026-08-21 from a working session with Edmond, who is the author
of the algorithm. The decisions taken in that session, each with the
argument that settled it:

- The payment at a horizon is a publication rather than a count, and the
  mutator's only obligation is to publish at points of uncertainty.
- The horizon is paid with a capture, and only with a capture: the
  expiring mark was proposed, refined and dropped in one session, the
  deciding reason being that a count is maintained for the durable case
  anyway and one mechanism beats two.
- The regime lives in its own flags bit, because a category code would
  remove the entity from the walk that counts it.
- Occupancy is `refcount != 0 || deferred`, cleared by whoever frees the
  slot.
- A compiler-owned entity is walked as a root and never condemned, and
  it may hold deferred children; forbidding that edge would need a test
  on every store, which is a write barrier.
- An unresolved call site emits today's counted lowering unchanged; the
  runtime reads the regime from the header and the same `retain` moves the
  right counter.
- The deferred regime is a property of the entity and is available in any
  memory, so what decides who must publish is whether the walk sees the
  slot, not where the memory came from (Edmond, correcting the first
  derivation).
- An arena store whose target is deferred takes no `retain` and no
  release-at-reset entry: the target's address goes on a root list instead.
- A destructor does not force a class to stay counted, because the mutator
  runs it at a checkpoint either way; nor do weak references, because the
  collector clears the cells of what it frees (Edmond, striking both off
  the eligibility list).
- Unique ownership is not an exclusion but a different regime: such an
  entity is not collected by the walk at all.
- `unset` on a deferred entity lowers to an explicit reclamation attempt
  rather than to nothing (Edmond).
- The collector supplies suspects and proves nothing; the mutator
  finalises, by arithmetic for a counted member and by a bounded trace for
  a deferred one (Edmond, sharpening the partition a Fable review
  recommended). Taken on condition that the trace measures cheap.
