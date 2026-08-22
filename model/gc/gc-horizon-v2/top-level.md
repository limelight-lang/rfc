# The second design at the top level

The GC horizon decides which local references carry a reference count
and where the ones that do not pay for their safety. The first design
pays with a count ([../gc-horizon.md](../gc-horizon.md)). This one pays
with a publication the collector reads, which removes the mutator's
reference count from a whole class of entities.

Nothing below is implemented, and the parts of the first design this one
does not touch — the ownership lattice, the horizon list, the placement
rule — hold unchanged.

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

## The two prices of one protection

Both prices answer the same question — *is this entity held from outside
the heap* — and differ in how long the answer stands and who ends it.

**The mark: one byte, expires by itself.** The epoch byte at object
offset 6 already means "created during the current epoch", and the walk
answers it by stamping the current epoch number and skipping the slot;
a skipped entity and its targets are pinned as roots
([../rc-walk.md](../rc-walk.md#the-one-header-byte)). Writing 0 into
that byte at a horizon publishes the same thing about an entity that is
not new. The mutator already performs this store once per entity, at
allocation, so the operation is not a new one.

Nothing has to clear the mark, because the walk clears it: the stamp
ages, and an entity stamped with an older epoch is walked and judged
again. That is the property a sticky bit lacks — the first design's
Form C states the lack outright ("without a stack scan or a
reassertion handshake the collector has no sound operation that clears
it", [../gc-horizon.md](../gc-horizon.md)) and answers it with a
canonical root owner and a demotion path, machinery the ageing byte
does not need. Two locals holding one entity both write 0, and neither
has to know about the other.

The mark expires, so it does not accumulate: it is placed at each
horizon rather than once at a point dominating them all.

**The capture count: durable, and released explicitly.** For an entity
in the deferred regime the count word stops counting references and
counts **captures by code** — the places where the program itself holds
the entity. Heap-internal edges are absent from it, the collector
enumerating those. So `retain` increments the captures and the collector
reads a positive capture count as a root, exactly as it reads the mark
but without an expiry; `release` decrements, and zero means the code
holds the entity nowhere, not that the entity is dead. No death branch
runs at zero and no destructor fires: reclamation is the collector's,
by reachability.

**The capture count is not a new kind of header state.** The runtime
already reuses the count word for a count that is not a lifetime count,
gated by a flag: `IS_ESCAPEE` says that a request-arena entity is
referenced from one or more longer-lived containers, and "while set,
`refcount` holds the escape hold-count instead of a lifetime count —
arena objects are not lifetime-counted, so the field is free"
(`model/src/refcount.rs`). The entity joins the arena's escapee list on the
0 to 1 transition and the flag is cleared when the count returns to zero.
The deferred regime's flag plays the same role for a different population,
and the capture count is that hold-count generalised.

**Which price the compiler picks** follows the shape of the borrow's
live range. A live range crossing one horizon takes the mark: one store,
nothing to undo. A live range crossing a loop or a run of horizons takes
the pair, placed once at a point dominating them all — the first
design's placement rule, unchanged
([../gc-horizon.md](../gc-horizon.md#at-the-horizon-promotion)).

```php
$c = $a->property;
foreach ($items as $x) {
    work();            // no trusted effects: a horizon
    $c->method();
}
```

Marking `$c` here would store once per iteration, because a mark placed
before the loop is aged out by the first walk that runs inside it. The
pair costs two operations for the whole loop, so this shape takes the
pair.

`$x` is a different case and takes neither price: it is a borrow of
`$items`, which is an owned local live across the whole loop, so its
chain holds through every iteration and its live range reaches no
horizon. A loop matters only for a borrow whose proof the loop body
breaks.

## Which slots must publish

The axis is not the memory category and not the actor: it is whether the
walk sees the slot. `rc-walk` derives its roots from the count precisely
because every slot it cannot see is counted — "a stack local, a static
block, an arena slot, an immortal container, an FFI handle. Every one of
those is counted" ([../rc-walk.md](../rc-walk.md)). The deferred regime
removes the count, so each of those slots needs its own answer.

- **A slot the walk sees** — a field of a walked GC-heap entity. The
  collector enumerates the edge itself and the mutator pays nothing.
- **A frame slot.** Nothing records it and no owner can retract it at a
  known point, which is what the mark is for.
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

## The three treatments the collector owes an entity

1. **Walk it, and it may be condemned** — an ordinary GC-heap entity,
   in either regime.
2. **Walk it as a root, never condemn it** — an entity the compiler
   owns, an immortal or arena entity, and an entity a mark or a capture
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
- **The mark is the epoch byte, written 0.** A single-byte relaxed
  store, which is what the collector's own stamp is. The 2026-07-27
  amendment bars the mutator from storing the whole flags half, because
  such a store buries a fresh stamp; a byte store to offset 6 buries
  nothing else.
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

The compiler cannot pick the regime here, and the first design's answer —
analysis failure selects counted — is unsound once the two regimes differ
at runtime, because a `retain` on a deferred entity writes into a word no
one maintains.

The way out is an asymmetry: **the mark is sound in both regimes and the
retain is not.** Marking a counted entity costs one epoch of survival,
since the walk skips it and skipping costs recall rather than
correctness. So an unresolved site emits the retain and the mark
together and needs no regime test of its own; the retain's header test,
which already exists for arenas and immortals, absorbs the rest.

## What changes in `rc-walk`

The first design changes nothing in the collector, and says so in its
scope ("nothing in this document changes `rc-walk`'s protocol, the
header layout, or what the mutator does at a checkpoint",
[../gc-horizon.md](../gc-horizon.md)). This one changes four things.

1. **The epoch byte becomes a safety gate.** Today no byte is one:
   Phase 3 decides only what is worth posting and Phase 4 re-reads
   counts race-free, so a lost or stale byte costs a wasted message
   ([../rc-walk.md](../rc-walk.md#the-one-header-byte)). Under this
   design a lost mark is a freed live entity.
2. **The occupancy test gains the regime bit**, a zero count no longer
   meaning a free slot.
3. **Skipping stops being total** for a source with uncounted children,
   which narrows treatment 3 as described above.
4. **The walk enrols compiler-owned entities as roots** rather than
   passing over them.

## Open questions

1. **Phase 4's exact test for a deferred entity.** Its exactness today
   comes from re-reading counts and edge sources; a deferred entity has
   no count to re-read, and what separates "a local holds it" from
   "garbage" is the mark, read in a race.
2. **The mark against a concurrent walk.** A walker that read an older
   epoch has already recorded the row, so a mark stored after that read
   arrives too late and the entity is judged this epoch. The mark
   therefore needs an ordering rule against the walk, or a second
   race-free channel.
3. **Class property, allocation category, or both.** The regime is a
   class property in the emitter's terms, but retain and release are
   already absent for arena entities and return early for immortal ones
   ([../../memory/arenas.md](../../memory/arenas.md#object-categories-by-memory-strategy)),
   so the capture count exists only in the GC-heap category.
4. **Cross-regime edges.** A counted source may die between two
   collector reads and remove its edge into a deferred target. The first
   design's Form C names the two instruments — a boundary count, or a
   barrier and a snapshot — and picks the first
   ([../gc-horizon.md](../gc-horizon.md)); this design has not chosen.
5. **Cycles.** A mark or a capture count pins an entity, and an
   unreachable cycle among deferred entities has neither, so reclaiming
   it still needs a trace from the roots. Publication answers roothood
   and not reachability.
6. **The prior art.** Deferred reference counting, ulterior reference
   counting and their descendants occupy this space, and the specific
   combination here — publication into the header instead of a stack
   scan, with an ageing byte as the clearing operation — has not been
   searched for yet. That search is the next step.

## Record

Written 2026-08-21 from a working session with Edmond, who is the author
of the algorithm. The decisions taken in that session, each with the
argument that settled it:

- The payment at a horizon is a publication rather than a count, and the
  mutator's only obligation is to publish at points of uncertainty.
- The mark is placed at every horizon, because it expires and does not
  accumulate; a live range crossing many horizons takes the pair
  instead.
- The regime lives in its own flags bit, because a category code would
  remove the entity from the walk that counts it.
- Occupancy is `refcount != 0 || deferred`, cleared by whoever frees the
  slot.
- A compiler-owned entity is walked as a root and never condemned, and
  it may hold deferred children; forbidding that edge would need a test
  on every store, which is a write barrier.
- An unresolved call site emits both the retain and the mark, the mark
  being sound in both regimes.
- The deferred regime is a property of the entity and is available in any
  memory, so what decides who must publish is whether the walk sees the
  slot, not where the memory came from (Edmond, correcting the first
  derivation).
- An arena store whose target is deferred takes no `retain` and no
  release-at-reset entry: the target's address goes on a root list instead.
