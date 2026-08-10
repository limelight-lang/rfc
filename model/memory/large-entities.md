# Large Entities

## Scope

Where an entity lives when its single allocation exceeds what its memory
category's allocator packs, and how the collector reaches it there.

The refusal is built and the shape that replaces it is designed; the
status list at the end says which is which, statement by statement.
Bodies are out of scope: a string's payload and a table's storage
already split out of line ([arenas.md](arenas.md),
[buffers.md](buffers.md)), and this document is about the entity *slot*,
which had no rule.

## The invariant

Two clauses, and the second is the one the collector depends on.

**A shared block never holds a slot larger than its category's packing
unit.** The unit is `BLOCK_PAYLOAD` (65 280 bytes) where the category
bump-packs within one block — the request arena and the immortal
region — and `MAX_SMALL` (8 192 bytes) where it packs by size class —
the GC heap and the long-lived heap. `memory::routing::slot_limit`
answers for all four.

**No live counted heap entity is outside the reach of the two
enumerators.** `heap::for_each_entity_slot` is the synchronous walk and
`heap::snapshot_entity_blocks` is the collector's per-epoch snapshot;
both find entities by scanning the pool's regions for blocks whose kind
says "entity", plus the retained former-arena blocks that carry an
explicit occupant index. An entity the two miss gets no row, so it is
never a candidate and a cycle among such entities is never collected —
a leak no pass finds, which is the reason `slot_limit` bounds the heap
categories at the size class rather than at the block
(`memory/routing.rs`).

The opposite error is the unsafe one. A walker that reads *more* slots
than a block holds fabricates rows out of an entity's own cells, and
fabricated edges can drive a live component to `RC == IN` and confirm it
for collection. Missing an entity retains memory; inventing one frees
memory that is live.

Past its packing unit an entity is not packed at all. It keeps its
inline layout whole as the sole occupant of a block-aligned allocation
whose first line is a block header of a large-entity kind, with the
entity at `+LINE_SIZE` (256). The first clause therefore bounds what a
*shared* block holds, and says nothing about how large one entity may
be.

Sizes follow from the object layout: a header of 16 bytes (`RcHeader`
and the class pointer) and one 16-byte slot per declared property, so
one block payload holds 4 079 properties and `MAX_SMALL` holds 511.

## Two kinds of oversize

The bytes an entity owns are opaque to the collector, while the cells it
owns are strided by the walker inside the slot. The answer splits along
that line, because only the second kind changes what the walker must do.

## Bytes: the layout that already exists

A string past the limit is built in the dynamic layout instead of the
inline one. The slot is then 32 bytes — `RcHeader`, `len`, `capacity`,
`hash` and a `data` pointer — and the payload comes from `body_alloc`,
which sends anything over a block payload to a dedicated OS-direct run
in either category, and in the request arena also logs that run for the
reset. Every part of that path is built and tested: the arena's
run, the reset's carry (`promote::carry_external_memory` and
`string::carry_payload_out_of`), and the size-carrying free. What is
missing is one decision at the factory, which today always builds
inline, so a 9 KiB heap string is refused rather than served in a
32-byte slot beside a right-sized body.

This covers the GC heap and the request arena, and only those two.
`ll_string_new_dynamic` refuses `LongLived` and `Immortal` outright, and
for the long-lived category the stated reason is that `string_die`
reclaims the GC heap alone (`string.rs`). A long-lived string past
`MAX_SMALL` therefore stays refused after the factory decision lands,
and it is unblocked by the long-lived reclamation policy rather than by
this document.

## Cells: one block-aligned allocation per entity

An entity whose cells push it past the limit keeps its inline layout and
occupies a block-aligned allocation of its own. The first line is a
block header of a new kind, the entity starts at `+256`, and field
access is unchanged because the cells are at the offsets the class
assigned them. The walker learns one kind and visits **exactly one
slot** in such a block; that count is the soundness rule of the previous
section, not an optimisation, so the block's snapshot entry carries
`slots = 1` and any striding of it is a defect. The precedent is
[arena-reset.md](arena-reset.md)'s retained block, which cannot be
strided either and is enumerated from an explicit index of its
occupants; here the index has length one and is computed from the block
address.

**Rejected: an out-of-line cell vector.** The slot would hold
`RcHeader | class | pointer`, the cells would sit in a body, and
`object::for_each_counted_cell` would follow one more indirection. It
reuses the body machinery whole and costs an indirection on every field
read of every object, which is the hottest path a program has, to serve
a case that is rare. Not to be reproposed, in any form, and neither are
chunked or discontinuous entities.

## Mechanics

**A new kind pair, and a new allocator entry point beside
`ll_alloc_large`.** `BLOCK_KIND_LARGE` (one pooled block, 8 KiB to one
payload) and `BLOCK_KIND_LARGE_RUN` (OS-direct above that) also hold raw
C buffers from `ll_alloc`, and a walker reading such a buffer's first 8
bytes as an `RcHeader` is exactly the mistake block-kind segregation
exists to prevent. The new pair splits at the same boundary — pooled
below one payload, OS-direct above it — and repeats
`ll_alloc_large`'s arithmetic rather than calling it: calling it and
re-stamping the kind afterwards would put a live entity briefly under
the raw-buffer kind, which is the same failure by a slower route.

**Commissioning: zero the header word, then publish the kind, then the
entity.** An entity block's occupancy test reads the slot's first 8
bytes, so `Heap::refill` zeroes those bytes in every slot before the
release kind store (`heap.rs`), and a large-entity block owes the same
pass over its single slot at `+256`. Skipping it is not a stale-value
nuisance: a pooled block recycled from a raw C buffer carries that
buffer's bytes, which read as a nonzero refcount with arbitrary category
bits, and the collector then traces a class pointer that is the caller's
data. Run memory comes from `std::alloc::alloc` and is never zeroed by
anyone, so the pass is unconditional. The kind is published last through
`block_pool::store_block_kind`, whose `rc-walk` build makes that store a
release because the collector loads every block's kind with an acquire;
the entity's `RcHeader` follows, header last, the rule `ll_object_new`
already obeys.

**Discovery follows the pooled/OS-direct split.** A pooled large entity
sits inside a carved region, so both enumerators reach it through the
region scan they already perform, once the kind test admits the new
kind. An OS-direct run is outside every region — the pool's region
registry records only the 2 MB regions it carved — so a run is
discovered from a registry of its own, and **is entered into that
registry after its `RcHeader` is published, never before**. The
insertion order is the mirror of the removal rule below, and for the
same reason: a registered address is dereferenced by both enumerators
without further testing, so an address is registered only once it names
an entity.

**The block's snapshot entry needs the entity's size, published before
the kind.** `snapshot_entity_blocks` reads a per-block field to compute
`class_size`; for a large-entity block that value is the entity's own
size, so it is written into the block header with the other fields and
covered by the release store that publishes the kind.

**Both kinds join `deferred_free`'s park set.** For the pooled kind this
is the hygiene every recyclable kind gets: a block re-stamped mid-epoch
loses the identity the queue exists to preserve. For a run it is
soundness of a stronger sort, because a run is unmapped at free while an
epoch's snapshot still holds its address, so an unparked free leaves the
collector reading unmapped memory rather than an intact corpse. It also
raises the queue's declared cost: `deferred_free`'s module doc bounds a
dropped record at 64 KiB, one block, and a parked run record pins the
whole run instead — 3.2 MB for the 200 000-property instance measured
below. A thread that frees a large entity mid-epoch and exits before the
next checkpoint leaks it for the life of the process, and that bound has
to be restated where the old one is written.

**The free path dispatches on the kind, and three neighbouring
functions need the same arms.** The pooled kind returns its block to the
pool; the run kind calls `std::alloc::dealloc` with the run's layout,
and its registry entry is removed before either. `ll_free_large`'s
default arm ignores an unknown kind silently, so a missing arm there is
a leak nothing reports; `ll_usable_size` answers 0 for an unknown kind,
so a `realloc` reaching a large entity through the C ABI would copy
nothing and free the entity. `ll_free`'s two test-build assertions —
that a freed entity's header reads refcount 0, and that it is not still
buffered as a cycle-collector candidate — fire on the entity kind alone,
so the population with an entirely new free path is the one that would
lose them. All three take the new kinds, and `ll_free_large`'s default
arm gains a `debug_assert` naming the invariant.

**The request arena allocates a large entity through a door of its own,
and `Arena::alloc` keeps its refusal.** `ll_arena_alloc` reaches
`Arena::alloc` straight from the C ABI and cannot tell an entity from a
byte buffer, which is why the bound lives there at all; a large raw
arena allocation is what `alloc_body` is for and stays refused on that
door. Entity allocation gets a separate arena entry point, which
`routing::entity_alloc_in`'s arena arm calls: below the payload it bumps
as today, above it it allocates through the large-entity entry point and
pushes the run into the arena's large-run log, so an unpromoted corpse
is freed by the reset with every other run. `Arena::alloc_large` is not
that door, because it allocates through `ll_alloc` and would stamp the
raw-buffer kind.

**An arena large entity is transferred at the reset, never copied, and
the reset needs four more rules to do it.** Today a survivor's block is
stamped `BLOCK_KIND_RETAINED` and indexed in `retained.rs`
(`promote.rs`), unconditionally, which for a run means the block later
reaches `give_block_back` and a multi-megabyte OS allocation is pushed
onto the 64 KiB block free list. So: a survivor whose block carries a
large-entity kind is not stamped retained; it is not entered into the
retained index; it leaves the arena's large-run log through
`forget_large`, so the reset stops owning it; and it is entered into the
run registry under its new category. The first of the four displaces
code that runs today, and its absence is silent, so it is the one that
owes a test — a promoted large entity whose block is checked against the
retained registry after the reset. `carry_external_memory` is not the
door for any of this: it dispatches on what a survivor owns *outside*
itself and an object answers `None`, so the four rules belong in the
survivor loop, beside the block stamp they replace.

**The immortal region already serves this shape, and its refusal is
lifted with the others.** `immortal_alloc` sends anything above
`BLOCK_PAYLOAD` to an OS-direct, block-aligned run with the payload at
`+LINE_SIZE` (`immortal.rs`), so an immortal large entity needs no new
allocator, no registry and no park-set entry, because it is never freed
and never walked. What refuses is `entity_alloc_in`'s `slot_limit` gate,
which was applied uniformly across the categories while the shape was
undecided. The gate never covered `intern`, which calls `immortal_alloc`
directly, so interned strings above one block payload exist today.

**All four refusals are lifted, each on its own door.** The two heap
categories and the immortal region lift their arms in `entity_alloc_in`,
where `slot_limit` gates them; the request arena lifts through the
entity door named two paragraphs above, while `Arena::alloc` keeps
refusing for the C ABI. `slot_limit` itself stays, because it is still the answer
to what one *shared* block holds and the first clause of the invariant
is stated in terms of it.

## The registry of runs

**A table of its own, holding one address per run.** A run's occupant
index has length one and is computed (`block + 256`), so an entry stores
the block address and nothing else: an ordered set behind a mutex, keyed
the way `retained.rs` keys its map, by the block's own address.

Extending `retained.rs` was the alternative, and its three differences
all fall in the same place. A retained entry carries a shared occupant
vector and two counters, `live` and `payloads`, while a run entry
carries neither. A retained entry dies when both counters reach zero,
while a run entry dies with its single entity. Most of all, the two ends
of life diverge: `retained::give_block_back` re-stamps the block to
`BLOCK_KIND_FREE` and hands it to the block pool, whereas a run must
reach `dealloc` and must never reach the pool.

That last difference is a branch somewhere in any design, and neither
placement is free. A shared table would put it on the entry, in the
reclamation path itself, where the wrong branch either unmaps a pooled
block or leaks a run. A separate table puts it at the reset's survivor
loop, which must test a survivor's block kind before stamping it
retained. The separate table is chosen because the run's identity is
known at the reset and nowhere else — `retained.rs` sees only an address
and a count, and by the time `give_block_back` runs, the fact that this
block came from `alloc` rather than the pool is unrecoverable. The
price is that the branch is a deletion rather than an addition: the
stamp is unconditional today, so omitting the test is silent, which is
why that rule and not the registration is the one covered by a test.

What the new table copies is `retained.rs`'s contract rather than its
code, in three rules. The snapshot clones the addresses out under the
lock and the caller walks them without it, so no visitor runs while the
mutex is held. The entry is removed strictly before the memory leaves,
because both enumerators dereference a registered address without
checking that the block still exists. A removal that falls inside a
collection epoch parks with the free it belongs to.

**Ruled out: entering runs into the block pool's region registry.** That
registry records regions the pool carved, which are never unmapped, and
an index into it is a stable handle for the life of the process. A run
is neither pool memory nor permanent, and putting one there would make a
stale index dereference freed memory.

## What a run costs the collector

Counted from the code and the types; no epoch has been measured with
runs present, because none exist yet.

One snapshot entry costs **40 bytes**: `EntityBlockSnapshot` holds
`payload`, `class_size` and `slots` at 8 bytes each, plus an optional
shared occupant index, which is a 16-byte fat pointer whose `Option`
costs nothing by niche. A run's entry carries no index, `class_size` set
to the entity's size and `slots` set to 1, so the walk reads one header
there against 255 in a 256-byte-class entity block.

The registry snapshot costs **8 bytes per live run**, cloned under one
mutex once per epoch on the collector thread, beside the region-registry
clone the epoch already performs.

Per traced edge, `census_row` binary-searches one sorted array of all
snapshot rows, so *N* runs added to *B* blocks cost
`log2(B + N) − log2(B)` extra comparisons: at *B* = 1 000 and *N* = 100,
0.14 of a comparison.

## The declaration-time warning

The compiler warns at class layout when an instance slot exceeds
`MAX_SMALL`, and never refuses. This is a diagnostic in the compiler,
which has no channel in this crate: `ClassBuilder::build` returns a
class and nothing else, so the warning belongs to the layout pass that
feeds it.

8 KiB is the threshold because it is the smallest packing unit any
category imposes, and it is a footprint cliff in the two heap
categories, where an object above it stops sharing a block and takes an
allocation of its own. In the request arena and the immortal region the
same object keeps sharing a block up to 65 280 bytes, so the warning
fires below their cliff. That is deliberate while the layout pass cannot
know the categories a class will be instantiated in: the compiler
assigns a category to an owner without knowing what kind of entity will
live there (`memory/routing.rs`), so a per-category threshold would have
to be a per-allocation-site diagnostic, which is a larger change than
the warning is worth.

Refusing was rejected on a measurement. Against PHP 8.6.0-dev on the
developer's machine, a class of 10 000 declared properties compiles and
runs at 163 840 bytes an instance, and 200 000 properties runs at
3 203 168 bytes — 2.5 and 49 of our blocks. A cap at one block payload
would stop at 4 079 properties and refuse a program Zend runs, which is
a compatibility cost this runtime does not take; Zend can afford the
size because its collector never walks the heap. Dynamic properties
pressure neither engine's slot: PHP keeps them in a hash table beside
the object, which is our body.

## Out of scope

Raising `MAX_SMALL`, and size classes for the band between 8 KiB and one
block, both change the same limit from the other side and are tracked
separately in `ll-model/PLAN.md`; moving both at once would leave neither
measurable. The long-lived heap takes the same shape as the GC heap for
an entity of counted cells, while its reclamation policy stays
undecided — and that policy, rather than this document, is what a
long-lived large *string* waits on.

## Status

**Built, and it is the refusal this design replaces.** Three categories
refuse an entity past their packing unit in `entity_alloc_in`, with the
bound answered in one place (`memory::routing::slot_limit`), and the
request arena enforces its own copy in `Arena::alloc`; `intern` reaches
`immortal_alloc` without passing the gate and is the one path that
already produces an oversize entity. The physical layout of a large
allocation exists in two places — pooled and OS-direct in
`stdapi::ll_alloc_large`, OS-direct in `immortal::immortal_alloc_run` —
as does the arena's large-run log with its transfer out, and
`body_alloc` with its size-carrying free.

**Designed, not built.** The kind pair and its allocator entry point,
the zeroing and publication order for a large-entity block, the run
registry, the enumerators' arm for the new kinds, the two park-set
entries and the restated leak bound, the arms in `ll_free_large`,
`ll_usable_size` and `ll_free`'s two assertions, the arena's entity
door, the reset's four rules for a surviving run, the four lifted
refusals, the factory's choice between the inline and dynamic string
layouts, and the compiler's warning at `MAX_SMALL`.

When the cells half is built, [../gc/rc-walk.md](../gc/rc-walk.md)'s
"Huge objects" bullet needs narrowing: objects in OS-direct runs stop
being unenumerable, and the bullet holds only for raw C buffers.
