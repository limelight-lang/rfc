# Bulk object operations

Two compiler-facing primitives that turn per-object calls into one:
releasing a batch of references with a single call, and reserving a
run of entity cells ahead of construction. Design only — nothing is
implemented (2026-07-27). The split of duties is the crate's usual
one: the runtime provides the mechanism, every *decision* (when to
batch, how many cells, which sites) is the compiler's.

Both exist for the same two reasons:

- **No per-object call.** A scope exit that drops twelve locals, or a
  loop hydrating a collection, currently pays one ABI call per object.
  The compiler sees the whole batch statically; the runtime should
  accept it as one.
- **Placement.** A reserved run puts sibling objects next to each
  other in one block — a parent and its children in one cache
  neighbourhood, by construction rather than by luck.

## Vector release

```c
void ll_release_vector(RcHeader *const *entities, size_t count);
```

Local code accumulates the objects it is done with — frame teardown,
a scope exit, a container clear — and submits the vector once.
Semantically exactly equal to:

```c
ll_gc_checkpoint();                 // once, before any death
for (i in 0..count)
    if (ll_release_batch(entities[i]))
        ll_entity_die(entities[i]);
```

- The epoch checkpoint is served **once, at entry** — before the first
  death, so every free the batch performs observes an in-flight epoch
  in program order (the same argument that placed the checkpoint on
  the death branch of `ll_release`).
- Releases run in vector order; destructor-visible order is the
  vector's order. The compiler owns that ordering choice.
- Strategy-independent: in an rc-trace build this is plain releases
  behind one call boundary.
- What the single call buys beyond the batched pair: code size at cold
  exits (one call, not 2·N), and the runtime's freedom to prefetch the
  next header while tearing the current entity — an optimisation the
  per-call form cannot express. Neither is committed until measured.

## Cell reservation

```c
size_t ll_entity_reserve(size_t size, size_t count,
                         void **out_cells, size_t *contiguous_len);
void   ll_entity_cells_return(void *const *cells, size_t count);
```

Reserve up to `count` cells of one entity size, best-effort
contiguous, and hand construction a ready pointer instead of an
allocator call per object.

**The parameters are a request; the manager decides.** `count` is what
the compiler wants, never what it is owed: the manager may return
fewer, or zero — refusal is an answer, not an error, and the caller's
fallback is always the ordinary factory. `contiguous_len` reports how
many of the *leading* cells form one adjacent run (stride = the slot
size): the compiler may zero-fill that run with one store sequence and
treat the tail cells individually. The policy behind the decision —
how far to go for cells, when to refuse — lives in the manager and can
change without touching the ABI; the first policy is deliberately
tame: serve from the size class's block already on hand (virgin bump
tail first — the contiguous part — then its free list), draw at most
**one** fresh block from the pool, and never force region growth for a
speculative reservation.

**The request arena needs no reservation ABI at all.** One bump
allocation of `count × size` *is* the contiguous run there — the
compiler already has that mechanism, and arena cells need no return
(reset reclaims the run like any arena garbage). The cell machinery
below is the heap's.

- **Cells are keyed by size class, not by class.** A cell carries no
  identity until the factory stamps it, so two classes of equal slot
  size draw from one run. The compiler groups its classes by size and
  issues one reservation per size — "one vector per class" falls out
  of that grouping as the degenerate case, but the mechanism is
  size-based, which is strictly more general.
- **Contiguity is best effort, and honest about it — in every
  category.** A bump run anywhere is contiguous only as far as the
  current block's remaining space; a run that does not fit splits at
  the block boundary, and blocks are not adjacent. Heap cells prefer
  the size-class block's virgin bump tail (contiguous, reported via
  `contiguous_len`), then fall back to free-list pops from the same
  block (same 64 KB, not adjacent). No promise ever spans blocks,
  anywhere.
- **Construction consumes a cell** through a factory variant that
  takes the cell instead of allocating —
  `ll_object_new_in(cell, class, category)`-shaped. Stamp and
  zero-fill as today; a cell is single-use.
- **Unused cells are owed back.** `ll_entity_cells_return` pushes heap
  cells onto their block's free list; arena cells need no return —
  reset reclaims the run like any arena garbage. The obligation is the
  compiler's (scope exit, exception paths), same discipline as the
  destructor debt.
- **Partial reservation is the failure mode.** The call returns how
  many cells it could reserve — possibly zero — and the compiler falls
  back to the ordinary factory for the remainder. No new error
  channel.

### Interaction with rc-walk

None that is new, which is the point:

- A reserved cell is a popped free slot or a virgin bump slot: its
  header still reads the final `rc 0` (or zero), so the walker's
  occupancy test skips it — reserved-but-unconstructed cells are
  invisible exactly as free slots are.
- Stamping publishes the header the same way the factory does today
  (kind last, release order), so a mid-epoch construction is the
  allocate-black newcomer the protocol already handles.
- Reservation is allocation, not release: nothing parks, nothing needs
  the deferral queue.

## What this enables, concretely

- A deserializer or collection hydrator constructs N objects with one
  reservation, one zero-fill over a contiguous run, and N header
  stamps — no allocator entry at all on the per-object path.
- The compiler lays out an object graph it knows statically (parent
  plus children built together) inside one run, making the pointer
  chase it just emitted cache-resident.
- Frame teardown compiles to one `ll_release_vector` instead of a
  release ladder.

## Who decides what

The former open questions resolve into a split of authority, not into
research items:

- **Batch thresholds are the compiler's parameter.** Below whatever N
  its own measurement favours, it emits inline releases; the manager
  is indifferent to the choice.
- **How hard to try is the manager's policy.** Refuse, serve short,
  draw a block or not — parameterised inside the manager, revisable
  without ABI change. The caller's contract is only: the answer may be
  any number from 0 to `count`, and `contiguous_len` of the answer is
  honest.
- **Physical order belongs to the manager.** `ll_release_vector` runs
  destructors in vector order — that is program-visible and fixed —
  but the physical recycling behind them is the manager's to batch,
  reorder or defer (it already defers wholesale during an rc-walk
  epoch). Whether sorting frees by block pays is its internal
  measurement to make, invisible to the contract.
