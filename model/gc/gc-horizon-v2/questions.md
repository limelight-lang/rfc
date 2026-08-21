# The question graph

What is still open in the second design, in the order the answers unlock
each other. Each node names what would answer it and what it blocks, so a
session can pick up one node without re-deriving the rest. Resolved nodes
stay in place with their answer, because a later node's argument often
rests on one.

```mermaid
graph TD
    A["A. Scope<br/>is there a deferred regime<br/>outside actor-private memory?"]
    B["B. Regime selection<br/>class, category, or both"]
    C["C. Cross-regime edges<br/>counted source, deferred target"]
    D["D. The mark against<br/>a concurrent walk"]
    E["E. Phase 4's exact test<br/>without a count"]
    F["F. Cycles<br/>publication is not reachability"]
    G["G. Where the mark lives<br/>header byte or side metadata"]
    H["H. Renewal placement<br/>and its measured cost"]
    I["I. Compiler-owned entities<br/>in the walk"]
    Z["Z. The economics gate"]

    A --> B
    A --> C
    B --> C
    B --> D
    B --> F
    B --> G
    D --> E
    F --> I
    G --> H
    E --> Z
    H --> Z
    I --> Z
    C --> Z
```

## A. Scope — is there a deferred regime outside actor-private memory?

**Open, and it is the root.** An actor's arenas are already collected at
message boundaries, where the stack is empty and the state consistent
([../../../runtime/actors.md](../../../runtime/actors.md)). Both Pony ORCA
and Iso reach the same place from different directions: collect at a
quiescent point and the question of which entities the frames hold does not
arise. If that rule extends to the general heap, the mark is needed only
where no quiescent point exists — a long request, a batch behaviour, code
outside any actor — and the deferred regime narrows to that population.

**What would answer it:** the share of allocation that is actor-private in
the corpus, and whether a PHP request reaches any point at which its stack
is empty before it ends.

**Blocks:** every node below, by deciding how much heap they govern.

## B. Regime selection — class, category, or both

**Provisionally decided, open in the second half.** The regime is a class
property, because the compiler must emit the right code without a runtime
mode test, and it takes its own flags bit rather than a fifth memory
category ([top-level.md](top-level.md)). What is open is the category axis:
`retain` and `release` are already absent for arena entities and return
early for immortal ones
([../../memory/arenas.md](../../memory/arenas.md#object-categories-by-memory-strategy)),
so a capture count exists only in the GC-heap category, and the pair
"class × category" has no stated lowering.

**What would answer it:** one table over the four memory categories saying,
for each, whether a deferred entity may live there and what its capture
count means.

**Blocks:** C, D, F, G.

## C. Cross-regime edges — a counted source with a deferred target

**Half answered.** An `ImmediateCounted` source may die between two
collector reads and remove its edge into deferred space. Iso's corollary of
the Doligez-Leroy-Gonthier invariant closes the actor-private half: only
the thread that allocated a private entity can publish it, so the edge is
always installed by its owner and integration needs no synchronisation
([prior-art.md](prior-art.md)). The general-heap half is open, and the first
design's Form C names the two instruments for it — a boundary count, or a
barrier with a snapshot ([../gc-horizon.md](../gc-horizon.md)).

**What would answer it:** whether a deferred entity may ever be reachable
from a counted source that is not its owner. If not, this node closes with
A.

## D. The mark against a concurrent walk

**Open.** A walker that has already read an older epoch for a slot has
recorded its `rc[]` row, so a mark stored after that read arrives too late
and the entity is judged in this epoch. Today a lost stamp costs a wasted
message, because no byte is a safety gate
([../rc-walk.md](../rc-walk.md#the-one-header-byte)); under this design a
lost mark is a freed live entity.

**What would answer it:** either an ordering rule that makes the mark
visible before the row can be recorded, or a second race-free channel for
the publication, or a Phase 4 arm that re-reads the mark under the drain's
exclusivity window ([../drain-window.md](../drain-window.md)).

**Blocks:** E.

## E. Phase 4's exact test without a count

**Open.** Phase 4 is exact because it re-reads counts and edge sources
race-free. A deferred entity has no count to re-read, so the only thing
separating "a frame holds it" from "garbage" is the mark, and D decides
whether that read can be trusted.

**What would answer it:** the deferred arm of the exact test, stated as
what it reads and under which exclusivity.

## F. Cycles — publication answers roothood, not reachability

**Open.** A mark pins one entity and a capture count pins one entity; an
unreachable cycle among deferred entities has neither, so reclaiming it
still needs a trace from the roots. Every system in the prior art answers
this the same way, with an occasional backup trace — LXR with SATB, RC
Immix with a backup trace, partial tracing by tracing the heap as its
primary mechanism ([prior-art.md](prior-art.md)).

**What would answer it:** which of `rc-walk`'s existing machinery serves as
the backup trace over deferred space, and what triggers it.

**Blocks:** I.

## G. Where the mark lives — header byte or side metadata

**Open, and the prior art moved it.** The header byte is cheaper for the
mutator: the cache line is already loaded by the operation next to it. Dense
side metadata is cheaper for the collector: a linear sweep instead of
scattered header reads, and the entity's own cache line is never touched.
The first design's Form C rejected side metadata because it "would turn root
discovery into heap-metadata scanning"
([../gc-horizon.md](../gc-horizon.md)); LXR does exactly that scan as its
ordinary allocation path, at two bits per 16 bytes — four bytes of metadata
per 256-byte line ([prior-art.md](prior-art.md)) — so the objection is not
decisive.

**What would answer it:** the cost of one mark store in each placement, and
the cost of one collector sweep in each, measured rather than argued.

**Blocks:** H.

## H. Renewal placement and its cost

**Provisionally decided, cost open.** The mark is placed at every horizon
rather than once at a dominating point, because it expires and does not
accumulate; a live range crossing many horizons takes the capture-count pair
instead ([top-level.md](top-level.md)). What is open is where the crossover
sits, and that depends on G.

**What would answer it:** the horizon-crossing distribution per borrow
lifetime, which the corpus scan already owes a channel for
([../gc-horizon.md](../gc-horizon.md#economics)).

## I. Compiler-owned entities in the walk

**Provisionally decided, cost open.** A compiler-owned entity is walked as a
root and never condemned, and it may hold deferred children; forbidding that
edge would need a test on every store into such a field, which is a write
barrier. The cost is the `rc[]` row and the out-edges, not a traversal,
because Phase 1 visits every slot of the snapshotted blocks already
([top-level.md](top-level.md)).

**What would answer the rest:** the share of the heap under compiler
ownership, which decides whether the added rows matter.

## Z. The economics gate

**Not reachable yet.** The first design's rule holds unchanged: a gross
number may only kill, and only the marginal number may open
([../gc-horizon.md](../gc-horizon.md#economics)). This design adds two
channels of its own — marks stored per horizon crossing, and captures
acquired and released — and inherits every channel the first design owes.

## Resolved in the session of 2026-08-21

- **Prior art.** The design sits in the count-the-roots quadrant; the
  quadrant is occupied and the expiring form of the publication was not
  found ([prior-art.md](prior-art.md)).
- **Occupancy.** A slot is occupied when `refcount != 0 || deferred`, and
  the bit is cleared by whoever frees the slot, which for a deferred entity
  is the collector.
- **Unresolved call sites.** A site whose static class the compiler cannot
  narrow emits both the retain and the mark, the mark being sound in both
  regimes and the retain being a no-op in the deferred one.
- **The capture count is not a reference count.** It counts code-side
  captures, so zero means the code holds the entity nowhere; no death branch
  runs and no destructor fires at zero.
