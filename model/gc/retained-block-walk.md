# Walking retained blocks

> **Status: built**, 2026-08-03 (`ll-model` `memory/retained.rs`,
> `promote.rs`, `heap.rs`, `collector.rs`). Independent of the domain
> work: it fixed a recorded limit of the shipped collector, and the
> limit has left rc-walk.md's "What this design does not solve".
>
> One thing the proposal understated: there are **two** enumerators, not
> one. `heap::for_each_entity_slot` feeds the synchronous
> `walk::collect_cycles`, `heap::snapshot_entity_blocks` feeds the
> collector's epoch, and both had to learn the index — otherwise the two
> collectors disagree about what is walkable and the synchronous walk
> stops being the harness that validates the concurrent one.

## The limit

Retained former-arena blocks sit outside the region registry, so their
occupants are never walked. By the derived-roots corollary they are
therefore **root sources** — their out-edges land in `RC` and never in
`IN` — and a ring living entirely among promoted survivors is never
collected ([rc-walk.md](rc-walk.md), "What this design does not
solve"). Conservative, never unsound, but permanent.

## Why they cannot be enumerated today

The walk locates a slot arithmetically: block by address mask, slot by
division by the block's size class
([collector.rs](../../../ll-model/src/collector.rs), `census_row`). A
retained block was filled by an arena's bump allocator, so its
occupants have mixed sizes and no uniform stride. There is nothing to
divide by, and the block cannot join the entity-block population.

## The observation

The inventory already exists, and the reset throws it away. The
fixpoint in `promote.rs` builds `survivors: Vec<*mut RcHeader>` —
`mark_subgraph` walks out from each escapee root and `mark_one` pushes
**every** surviving entity onto it — and uses it only for the counting
pass before dropping it.

## The proposal

Keep that vector as the retained set's **object index**, sorted by
address at reset. Then:

- the walk **enumerates** a retained block by iterating its index
  instead of striding;
- the census **resolves** an address inside one by binary search over
  the index, in the same shape as the existing search over sorted block
  payloads.

Three properties make this unusually cheap:

- **The set is frozen.** Nothing allocates into a dead arena, so the
  index never grows, never shifts, and needs neither lock nor version.
- **Entries validate themselves.** A survivor that later dies leaves a
  header reading refcount 0, which is exactly the walk's occupancy
  test — a dead entry is skipped like an empty slot.
- **Identity is free.** Individual slots in a retained block are never
  reissued: the block returns to the pool only when all its survivors
  are gone. The deferral window, which exists to stop a slot naming two
  entities, has nothing to do here.

Cost: one pointer per survivor for the life of the retention. Survivors
are few by the premise that makes retention worth doing at all.

## What it buys

- The "cycles among promoted survivors" limit falls.
- An entity promoted by retention becomes judgeable, so a *post-reset*
  survivor no longer has to be copied into an entity block to be
  collectable — the copy becomes a placement choice there. This does
  **not** relax [domains.md](domains.md) I6, which governs a handover
  out of a **live** arena: that copy exists to keep the reset fixpoint's
  hold-count reads away from a foreign writer, and nothing here touches
  that race.

## Owed before it lands — how each was settled

Reasons in full: `ll-model` `dev/DECISIONS.md`, 2026-08-03.

- **Totality.** One lookup, as required. Both kinds of block live in the
  same sorted payload list, and only the slot derivation branches after
  the match: a size-class block divides its offset, a retained block
  binary-searches its index. An exact-match miss rejects an interior or
  stale address for the same reason the remainder test does.
- **Granularity.** One index per retained block. Both enumerators reach
  a block first — one by the 64 KiB alignment mask, the other by
  scanning the region registry — so an index keyed by block address
  costs no second mapping on the lookup path.
- **Lifetime.** A registry keyed by block address owns the indexes
  (`memory/retained.rs`) and `release(block)` drops one. Nothing calls
  it yet, because a retained block never returns to the pool today; the
  index therefore lives exactly as long as the retention it describes,
  which is the correct lifetime rather than a leak. The call exists so
  that the return mechanism, when it lands, hooks in with one line.
