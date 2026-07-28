# Walking retained blocks

> **Status: proposal**, agreed 2026-07-28. Independent of the domain
> work: it fixes a recorded limit of the shipped collector and touches
> only the walk and the arena reset.

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

## Owed before it lands

- **Totality.** rc-walk.md's rule that row omission and edge omission
  are one decision taken at one test must survive a census with two
  sources (size-class blocks and retained indexes). One lookup that
  consults both, not two lookups with two answers.
- **Granularity.** One index per retained block or one per retained
  set — a reset can retain several blocks, and the walk wants to find
  the index from a block address.
- **Lifetime.** The index is freed with the block; the existing "return
  a fully-emptied retained block to the pool" mechanism is where that
  hooks in.
