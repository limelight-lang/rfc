# rc-walk — a barrier-free concurrent cycle collector

> **Status: design.** Nothing here is implemented. The strategy registry
> ([strategies.md](strategies.md)) gains `rc-walk` alongside `nogc`, `rc`,
> `rc-trace` and `rc-satb`. Selection stays build-time, as for every other
> strategy.

## What this collector is for

Exactly one job: **find reference cycles**. Everything else is already
reclaimed without it.

- Request-scoped entities die wholesale at arena reset ([arena-reset.md](../memory/arena-reset.md)).
  The collector never sees them.
- Everything that outlived the request dies the moment its refcount reaches
  zero — immediately, deterministically, with `__destruct` on the spot.

What neither path takes is an island of entities holding each other in a
ring: the counts never reach zero and the arena is long gone. Finding those
islands is the whole of this collector's work.

Two consequences follow, and they shape every decision below:

- **The collector may skip.** A missed cycle is memory not yet reclaimed,
  never a wrong answer. So whenever it is unsure, it does nothing and
  retries next epoch.
- **The collector may be slow.** Its cost is off the mutator's path
  entirely, so trading collector time for mutator instructions is always
  the right trade here.

## The design constraint that produced this shape

**The mutator does no work for the collector.** No write barrier, no
snapshot queue, no root publication, no safepoint park for the walk. That
rules out SATB-style concurrent marking, which pays a flag test on every
reference deletion, and it rules out stop-the-thread walking.

What is left is the mutator's *existing* bookkeeping — the refcount it
already maintains for deterministic death and for copy-on-write — plus one
masking operation, and the collector's own patience.

## The central identity: roots are derived, not enumerated

For any heap entity:

```
RC = (references from walked heap containers) + (references from everywhere else)
```

"Everywhere else" means a stack local, a static block, an arena slot, an
immortal container, an FFI handle. Every one of those is *counted* — the
store barrier retains on any store regardless of the holder's category.

So if the walk counts the heap-internal in-edges itself, calling that `IN`:

```
RC - IN > 0   ⟺   something outside the walked heap references this entity
```

That is the root set, **computed rather than collected**. No stack maps, no
conservative stack scanning, no shadow stack, no handshake to enumerate
roots. This is what makes a barrier-free design possible at all.

**Corollary — an un-walked region is automatically a root source.** Its
edges appear in RC and never in IN, so its targets survive. Skipping the
arenas, the immortal region, buffers and `LongLived` entities is therefore
conservative, never unsound. Skipping costs recall, never correctness.

## Prerequisite: entity blocks are segregated

Today `ll_object_new` routes `GcHeap` allocations through `ll_alloc` into
the same size-class blocks as raw `ll_malloc` buffers from the C ABI. A
walker cannot tell a live 40-byte object from a live 40-byte C buffer, and
reading the buffer's first eight bytes as a header is a wild pointer
dereference.

**Entities get their own block population** — a distinct block kind served
by its own instance of the same size-class heap. Only those blocks are
walked. This is not an Immix line allocator and does not need one; it is the
existing allocator with a separate block population.

Two more pieces of metadata:

- **A FREE stamp** written into a slot's flags word when an entity's memory
  is released. It must be written by **entity teardown** (`ll_object_die`
  phase 3), not by `ll_free`, because a promoted survivor in a retained
  arena block takes a free path that does nothing today. Without the stamp,
  a dead entity's stale out-edges inflate `IN` and can turn a live object
  into garbage.
- **A region registry**: the block pool counts regions but does not record
  their bases, so the walker cannot enumerate blocks. Eight bytes per 2 MB
  region.

## The header bit

The collector's verdict lives in the **top byte of the flags word (bits
24-31)**, which the design frees by deleting the candidate buffer (bits
15-31 today) and the cycle-collector colour bits (4-6, now collector-private).

- The **collector** writes 1 into that byte to condemn an entity.
- The **mutator** writes 0 into it on every `retain` and `release`.

The byte is at object offset 7; the refcount occupies bytes 0-3. Different
addresses, plain stores on both sides — **no atomic read-modify-write
anywhere**.

Cost on the mutator: the header word is already loaded and stored by
`retain`/`release`; clearing the byte adds one masking operation and no
memory traffic. In builds without this collector the mask is not emitted.

**Races on this byte are safe by direction.** If a mutator's whole-word
flag update clobbers a concurrent condemnation, the byte reads 0, the
collector treats the entity as touched, and the verdict is dropped. A lost
update always produces the conservative answer.

## The algorithm

### Phase 1 — WALK (collector thread, no synchronisation)

Enumerate entity blocks from the region registry, in address order. Per
slot: skip if FREE-stamped or past the block's bump cursor; load the 8-byte
header; skip if the category is not `GcHeap`; skip if the class is marked
acyclic by the compiler.

For each surviving entity: record `rc[id] = refcount`, then walk
`traced_runs` and append every `GcHeap`-category child as a compact id to a
flat `edges[]` array with per-source offsets.

Reads are unsynchronised and may be stale — that is expected and is what
Phase 3 exists to repair. `id = (block index << k) | slot index`.

### Phase 2 — DIFF and MARK (collector thread, private memory)

`in[]` is accumulated from `edges[]`; roots are `{ id : rc[id] - in[id] > 0 }`;
marking is a breadth-first walk of `edges[]` from those roots. Unmarked
entities are grouped into connected components — **a cycle is judged and
freed as a unit, never member by member**.

All of this happens inside the collector's own arrays. It touches no
mutator memory and contends for no cache line.

### Phase 3 — CONDEMN and VALIDATE

The walk read a moving graph, so its verdict is a hypothesis. Validation
turns it into a fact without any mutator cooperation:

1. Write 1 into the condemned byte of every member of every candidate
   component.
2. Establish that nothing was touched between the read and the
   condemnation. Two mechanisms, complementary:
   - **The condemned byte.** Any `retain` or `release` on a member clears
     it. This catches the case a value comparison cannot: a reference that
     migrated out of the heap and left the count numerically unchanged
     (`$x = $a->o; $a->o = null;` leaves RC at its old value while a live
     local now holds the entity).
   - **OS dirty-page tracking.** Ask the operating system which pages were
     written since the walk began; discard any component with a member, or
     an in-edge source, on a dirty page. This costs the mutator **nothing**
     — the MMU already tracks it — and it covers writes that never went
     through `retain`/`release` at all.
3. **A component is confirmed only if no member was touched by either
   test.** One touched member acquits the whole component: a resurrected
   or re-referenced member keeps its neighbours alive, and freeing them
   would dangle its pointers.

Anything not confirmed is simply dropped. It will be re-judged next epoch.

### Phase 4 — RELEASE (mutator thread, by message)

Confirmed components are posted to the owning mutator thread, which drains
the queue at its next poll. The collector never frees anything itself.

Per component, the discipline the existing `run_cyclic_destructors` already
implements:

1. Guard every member (`refcount += 1`) so no member can die mid-way.
2. Run each member's pending `__destruct` exactly once (`DESTRUCTOR_RAN`).
   This is PHP code; it must run on the request thread with its own
   context, and it may resurrect.
3. Un-guard through `ll_release` and let the ordinary teardown path decide:
   zero → `dispose` releases the children and the memory is freed; non-zero
   → the entity was resurrected and lives on with a true count.

Children outside the component are released ordinarily, so a chain of
non-cyclic dependants dies deterministically, destructors and all.

### Deferred physical release during an epoch

While a walk is in flight, memory released by ordinary refcount death is
**queued rather than recycled** — the GC activity bit of
[heap-design.md](heap-design.md). The entity dies normally and on time,
`__destruct` included; only the slot's reuse waits, so the walker cannot
read a slot that has become a different object underneath it. The queue is
flushed when the epoch ends.

This is one load and a predicted branch on the free path, active only
during an epoch.

## What the mutator pays, in total

| | |
|---|---|
| `retain` / `release` | one masking operation on a word already loaded and stored |
| memory release | one flag test while an epoch is in flight |
| everything else | nothing |

No barrier on reference stores. No queue. No park. No atomic
read-modify-write. In a build without this collector, none of the above is
emitted.

Against `rc-trace` as implemented today this is a net **reduction**:
`ll_release` loses the candidate-buffer test and call it performs on every
non-zero decrement, and the header loses 17 bits of candidate index.

## Convergence and the failure mode

Validation can starve: a workload that keeps touching the same entities
never lets a component stay untouched long enough to be confirmed. Then
nothing is collected and memory grows.

The escalation ladder, in order, with the mutator never drafted into
collector work:

1. Re-run the epoch — cheap, and the population of true cycles is stable
   while the population of hot objects is not.
2. Shrink the window: validate immediately after the walk of the relevant
   blocks rather than after the whole heap, so fewer writes fall inside it.
3. As a last resort, park the mutator at a poll for one short window and
   confirm without racing. This is a pause, and it is the fallback, not the
   design.

The queue of deferred releases also grows for the duration of an epoch: a
slower collector costs memory. Both of these are measurements, not
arguments — they must be taken on real workloads before any threshold is
fixed.

## What this design does not solve

- **Uncounted borrows.** A `retain` the ARC optimiser elided is invisible:
  no count, no cleared byte, no dirty page from the borrow itself. If the
  covering reference lives in an object that turns out to be cyclic
  garbage, the borrowed entity is freed under a live local. The rule the
  optimiser must follow: an elided borrow is legal only when covered by a
  counted reference **in a frame** — covering "by a field of some heap
  object" is not enough, because that object may itself be garbage. This
  obligation is independent of which collector is chosen; it applies to
  `rc-trace` today and is written down nowhere.
- **Weak references.** Deferred. The planned shape is a side entry per
  weakly referenced target, so a `WeakRef` counts the entry and never the
  target, and Phase 4 nulls the entry — no reverse map needed.
- **Huge objects** in OS-direct block runs are outside the pool regions and
  cannot be enumerated by the registry. Cycles through them are not
  collected; the edge is skipped, which is conservative.
- **Multiple mutator threads** sharing `GcHeap` entities. Refcounts are
  non-atomic today, so the crate is single-mutator; actors will force this
  question and may force a per-thread epoch protocol.

## Open questions before implementation

1. **Dirty-page APIs.** Windows `GetWriteWatch` and Linux soft-dirty /
   `userfaultfd` write-protect are the assumed mechanisms; neither has been
   verified against its documentation, and page granularity (4 KB against a
   64-byte header) may make the false-positive rate impractical.
2. **Ordering proof for the condemned byte.** "A lost update is safe by
   direction" is argued above but not proved against the memory model.
3. **Whether validation needs both mechanisms.** The condemned byte alone
   misses writes that bypass `retain`/`release`; dirty pages alone are
   coarse. Whether either suffices on its own is unanswered.

## Build order

1. Entity block segregation, the FREE stamp in teardown, the region
   registry. Required by any walking collector, useful on its own as a heap
   census.
2. A synchronous walk fired at an explicit call: diff, mark, components,
   release inline. No collector thread, no validation — a whole-heap leak
   detector and a correctness harness for everything above.
3. The collector thread, the condemned byte, validation, the deferred-free
   bit, the message queue.
4. Weak references.
5. The dirty-page half of validation, if measurement shows the byte alone
   starves.

`rc-trace` (`gc.rs`, Bacon–Rajan) stays in the registry throughout as the
single-threaded strategy, so the two can be compared on the same workload.
