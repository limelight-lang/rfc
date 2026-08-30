# `rc-cycle`: decrement-triggered cycle collection

> **Status:** design of record since 2026-08-25; not implemented. The runtime
> does not collect reference cycles until this design is built. The superseded
> collectors are available on `archive/pre-rc-cycle`. Unresolved design
> questions are tracked in [`cycle/questions.md`](cycle/questions.md), and
> implementation blockers found during review are listed in
> [`../../dev/ALGORITHM-AUDIT.md`](../../dev/ALGORITHM-AUDIT.md).

## Decision summary

- A non-final reference-count decrement registers the entity as a cycle
  candidate. A decrement to zero uses ordinary reference-counted destruction.
- Trial deletion uses trace-local shadow counts and does not modify live
  reference counts.
- Candidate age prunes traversal edges at a traversal age threshold. The rule
  never applies to a candidate-queue root.
- An acyclic-class filter prevents instances that cannot participate in a
  reference cycle from entering the candidate queue.
- A collector worker may produce a speculative validation batch, but only the
  owning mutator performs exact validation and reclamation.
- The trace token serializes tracing of one mutator thread's blocks and live
  candidate queue. Different owners may be traced concurrently.

The terminology in this document follows
[`dev/GLOSSARY.md`](../../dev/GLOSSARY.md).

## Candidate registration and trial deletion

The design keeps synchronous reference counts. Snapshot algorithms based on a
deferred write log are unsuitable here because copy-on-write separation,
`RC - IN`, exact validation, and prompt count-zero destruction all require the
current count. A missed log entry could also make collection unsound.

The algorithm therefore combines ordinary reference counting with the
candidate mechanism from Bacon and Rajan:

- **Candidate registration.** A reference cycle can become unreachable only
  after a decrement that does not reach zero. The mutator registers entities
  that observe such a decrement. Entities whose count reaches zero are
  destroyed immediately and do not enter the candidate queue.
- **Shadow-count trial deletion.** Mark and scan copy each visited reference
  count into a side row and subtract internal edges from that shadow count. The
  live count is never modified, so aborting a trace requires no heap rollback.
- **Age-based pruning.** The entity header stores candidate age. When a
  non-root target has the current epoch stamp and has reached the traversal age
  threshold, the traversal treats it as an opaque external live reference. The
  rule applies only to edge targets, never to queue roots; otherwise a reference
  cycle at the threshold could be skipped until the epoch changes. A trace
  may also stop at an explicit budget. See `cycle/questions.md`, Y9 and Y13.

The age rule is a performance policy, not a completeness guarantee. In the
first collection after an epoch change, every stamp is stale and the rule
prunes nothing. A 2026-08-25 measurement also found that the median candidate
root reached all 381 objects in its test heap, which is why an independent
trace budget remains necessary.

The **acyclic-class filter** excludes a class only when static analysis proves
that none of its declared slots can contain a reference that closes a cycle.
All other classes remain cycle-capable by default; runtime history cannot
change that classification.

## Speculative tracing and exact validation

A collector worker produces a **validation batch**, not a final reachability
decision. An unreachable reference cycle cannot acquire a new external
reference: the mutator would first need an existing path through which to read
one of its members. However, an off-thread trace may combine fields and counts
from different instants. Its result is therefore only a proposal for the owner.

The compiler must count every reference held in a local variable or stack slot.
Retain/release elimination is allowed only inside a region in which collection
cannot start: the region contains no call, store, release, or consistent-point
poll. This ensures that exact validation cannot overlook a stack-held
reference.

Written the other way round the danger is concrete, and it is what the
guarantee rules out. Take `$node = $ring->head` with the retain elided against
`$ring->head` as the covering reference, then `$ring = null`. The covering
reference is an edge *inside* the ring, so the trace subtracts it, the ring
reads as internally balanced, and `$node` would be left pointing at freed
memory. Refcounting alone never has this problem, because it frees only at
zero; a cycle collector frees at a non-zero count, which is why the covering
obligation has to be the counted `+1` and not "someone else holds it".

Trace precision affects cost and latency, not safety: a missed cycle remains
eligible for a later collection. A trace may therefore stop at an age boundary,
at its work budget, or after scratch allocation fails. This statement assumes a
memory-safe protocol for concurrent slot reads; that protocol is currently an
open blocker, as recorded in `dev/ALGORITHM-AUDIT.md`.

Only the owning mutator performs **exact validation**. It re-reads current
fields on its own thread and calculates the component's current internal edge
counts.

The **ownership invariant** applies to every state-reducing transition:
clearing the candidate bit, removing a queue entry, and returning a slot for
reuse are owner-only operations based on exact state. A speculative trace may
add a candidate result but must not perform any of those transitions. Exact
validation that finds an external reference also leaves the candidate bit set
and re-offers the root; the bit is cleared only when the entity dies. See
`cycle/questions.md`, Y12 clauses 4 and 8.

Clearing the bit after a live result would leak a cycle permanently. Consider a
cycle A↔B with an external X→B. A trace captures `RC(B) = 2`, subtracts the
internal edge, and finds one external reference. If X then releases B, B does
not reach zero. Without the retained candidate bit and re-offer, no later
decrement would register the now-unreachable cycle.

**Synchronous collection is exact by construction.** The owning mutator can see
its own stack and is the only thread changing the counts it validates. It does
not need a result handoff or confirmation step. Synchronous collection is the
required implementation; collector workers are an optional optimization that
reduce the owner's validation work.

## Where the shadow count lives

Each touched heap block has a temporary array with one shadow row per slot. The
trace derives the row from the entity address; it needs no hash table, key, or
entity-header field. This layout was selected on 2026-08-26 after measuring
three alternatives.

The entity heap is already block-structured, so the address carries the answer:
the block is `p & !BLOCK_MASK`, and the slot is
`((p & BLOCK_MASK) - LINE_SIZE) * recip >> 32`, where `recip = 2^32 / class + 1`
is exact for every size class and every slot of a block. The collector's own
triple — the array pointer, `recip` and its own copy of the size class — sits in
the free tail of the block's 256-byte header line, past the 192 bytes
`HeapBlockHeader` occupies, so the collector never writes the cache line that
carries the owner's bump cursor and free list.

**Measured** on an i7-11700K, median of nine, null pair 0.7–1.1 ns: 2.6 ns a
lookup, against 10.4 ns for an open-addressed hash keyed by the pointer with a
displacement hint in the entity header, and 15.8 ns for the same hash with an
ordinary probe. On a 12 GiB heap of classes 32/64/128/256 at half occupancy the
rows cost 717 MiB against the hash's 2.0–4.0 GiB — the hash's upper figure being
what its doubling costs when 94 million rows land just past a load factor of 0.7.

The formula does not cover every population of the cycle-collected heap, so the
trace dispatches on the block kind after loading its header. An ordinary entity
block uses the arithmetic lookup. A
**retained** block — promoted arena survivors, filled by a bump allocator, mixed
sizes, no stride — goes by binary search over the occupancy index, so
`memory/retained.rs` outlives the deletion of `rc-walk` that built it. A **large
entity** holds one row in its own block header's free tail. An arena block is
never entered: the descent stops at any child outside the GC heap and treats it
as an external live reference, because a reference cycle through the arena is
broken by the arena's own reset.

**A large entity's block kind does not say which heap it belongs to, and the
category is what does** (found while building the dispatch, 2026-08-27). An
arena entity past one block payload is allocated by the same allocator a heap
one is and carries the same block kind, so a dispatch that took the kind for
proof would descend into an arena entity. A component confirmed as unreachable
through it would be freed by finalization and again by the arena's reset, which
still holds the run in its log. The other two populations need no such test: an entity block
and a retained block hold entities of the collected heap alone. Promotion
rewrites a surviving run's category in place and deliberately leaves its kind
unchanged, so the category is the word that is right on both sides of a reset.

**Rows are initialized lazily.** A zero row would otherwise have to mean “not
visited in this collection”, forcing initialization of every slot in a touched
block. In the 717 MiB case, eager initialization took 41–76 ms for already
mapped memory and 178–196 ms on first touch. The selected layout stores visited
state in a bitmap with one bit per eight-slot group and initializes only the
bitmap and visited groups; the same benchmark took 1.4 ms.

At a block's first visit, the trace scratch arena bump-allocates `slots × 4`
bytes of rows plus the visited bitmap from pooled 64 KiB blocks. It uses the
ordinary allocation path first and the reserve path from
[`critical-reserve.md`](../memory/critical-reserve.md) after ordinary allocation
fails. Allocation returns null on failure, allowing the trace to abort and
return all scratch blocks. The rejected virtual-reservation alternative could
instead fault while materializing a page and could not report that failure to
the trace.

This layout allocates the complete row array for each touched block, even if the
trace visits only one slot: up to 16 KiB at the smallest size class. The cost is
bounded by the number of touched blocks. Each row contains two color bits and a
30-bit working count.

**Saturation is absorbing, and that is a rule for every stage that touches a
row** (2026-08-27). A saturated count is a lower bound rather than a total — "at
least 2^30 − 1 references", the trace having no room to say how many — so
subtracting an internal edge leaves it saturated and the scan must classify it
as conservatively live.
Without the rule the entity above the field is the one the collector is most
likely to free wrongly: a refcount of 2^31 meets at the bound, and a trace that
finds 2^30 internal edges walks the row to zero while a billion external
references stand. That heap is 16 GiB at the smallest size class, which is a
large machine rather than an impossible one. The alternative — a wider row —
was rejected with the row's width, and a second word for “exact or lower bound”
would reintroduce the captured count this design deliberately omits.

**The chunked form is the recorded alternative, not the choice**: rows in groups
of eight behind a two-byte directory entry per group. It wins only where the
density of traced slots in touched blocks stays below 29 % — the analytic
crossing is `1 − 1/√2` — and it costs a further dependent load on every edge. On
a full trace it writes *more* than the flat array, 762 MiB against 717, because
every chunk is zeroed at first use too.

## Zero-count entities pending slot reuse

An entity can reach a zero reference count while a candidate-queue entry still
contains its address. The current design has no index with which to remove that
entry immediately.

The owning mutator still performs all observable teardown at once: it
invalidates weak references, invokes `__destruct`, and releases child fields.
Only storage reuse is delayed. The slot remains readable with count zero and
the candidate bit set until the owner removes every outstanding identifier.

A collector worker may label the queue entry as a zero-count entry, but it must
not clear the candidate bit or return the slot. Owner-only reuse prevents the
slot from being allocated to a new entity while the old entity's destructor is
still running.

Two conditions can delay reuse:

1. A queue or deferred-candidate-buffer entry still names the entity. Such an
   entry may remain until the candidate epoch changes, unless a synchronous
   collection removes zero-count entries earlier.
2. A trace token protects scratch rows indexed by slot. Reusing a slot before
   the trace stops accessing those rows could associate the previous entity's
   visited bit and shadow count with the new occupant.

The owner must return a slot only after both conditions are false, and block
occupancy must decrease at that return rather than at zero-count teardown. The
exact owner/worker handoff that establishes this instant is unresolved; the
previous text gave incompatible owner-observed and token-release instants. See
`dev/ALGORITHM-AUDIT.md`, issue A3.

Candidate registration applies only to the cycle-collected heap category. The
fast-path gate combines category zero, a cycle-capable entity kind, an eligible
class, unproven ownership, and a clear candidate bit as
`flags & 0x723 == 0`. Without the category test, an arena reset could reuse a
slot while a stale queue entry still names it.

## Cycle finalization and reclamation

The owning mutator runs the following sequence for each component that exact
validation confirms as unreachable. The order is normative and applies to both
synchronous collection and batches proposed by a collector worker. Reordering
the steps can expose a weak reference, run teardown twice, or reclaim storage
while user code still holds a reference.

1. **Check for zero-count members, then validate the component.** If any member
   already has count zero, ordinary reference-counted teardown has completed
   and its slot is awaiting reuse. Remove that component from the current
   validation batch before tracing fields or adding guard references. The
   disposition of other candidate roots in such a component is unresolved; see
   `dev/ALGORITHM-AUDIT.md`, issue B1.

2. **Add a guard reference to every member of every confirmed component**
   (`+1` each) before any user code runs. A release from inside any destructor
   then stops at a guard
   instead of at zero, so no member starts ordinary zero-count teardown during
   cycle finalization. Guard references prevent re-entrant teardown; they are
   not a concurrency mechanism.

3. **Null every weak cell naming any confirmed member — all members of all
   confirmed components, before the first destructor.** A weak load is the one
   channel that can hand a destructor a reference the counts do not account
   for. Per-member nulling interleaved with per-member teardown is what this
   forbids: in an unreachable cycle A↔B, `B::__destruct` would load the cell
   naming A, receive a strong reference, and A's slot would be freed under it. CPython
   closes the same window in PEP 442, and Zend nulls at the top of
   `zend_object_std_dtor` for the same reason
   ([`../weak-references.md`](../weak-references.md), "Death notification").

4. **Run each pending `__destruct` exactly once.** User code may store,
   release, allocate or resurrect; a store retains normally. The kind gate here
   covers objects today and widens to `Lazy` when the compiler starts producing
   it — a lazy entity carries a class pointer, and its destructor would
   otherwise never run.

5. **Repeat exact validation with the guard discounted** (`RC − 1 = IN`), but
   only when a destructor ran **anywhere** — one flag for the whole commit, not one per
   component, so the skip owes nothing to any reasoning about what a destructor
   in one component can reach in another. Without the discount, guard
   references make every component appear externally reachable. When
   revalidation finds an external reference, remove the guards through counted
   release and retain the surviving entities with their destructors already
   invoked.

   This step remains necessary even when a collector worker produced the
   validation batch. Unreachability is monotonic only while no reference to the
   component exists outside it, and step 4 hands
   user code `$this` — a reference the teardown itself created.

6. **Sever, un-guard, then drop the deferred external children.** Severing
   nulls every member's slots and collects the displaced children;
   in-component children are released immediately and stop at their guards,
   external ones are held back until after the members are freed. Between the
   sever and the free no user code runs at all, which makes the property
   structural instead of proof-dependent. The external children then die
   ordinarily, destructors and all; the members were GC-heap holders, so the
   barrier's drop settles an arena escapee's hold count exactly as member
   teardown would have.

Two consequences are part of the specified behavior. A component retained at
step 5 keeps its invalidated weak references; unlike PHP, this design does not
restore them after resurrection. A weak reference created during step 4 is not
covered by step 3, so the storage-reclamation notification clears it at step 6.

## Concurrency

At most one trace may run for a given mutator thread. A per-thread **trace
token** enforces this rule: the tracer acquires it with compare-and-swap and
releases it with a release store. Different mutator threads have different
tokens, so their traces may run concurrently only if their reachable blocks are
disjoint.

The intended disjointness proof assumes that transferring an object leaves no
reference in the source thread and that no thread points into another thread's
blocks. That proof is currently incomplete for block adoption, moved objects,
actor sharing, and FFI entry. These are correctness prerequisites, not optional
optimizations; see `dev/ALGORITHM-AUDIT.md`, issues A4, B3, B4, and C3.

The token covers mark, scan, and reads of the live candidate queue. The tracer
releases it after its final access to any shadow row, visited bitmap, or live
queue and before exact validation. Zero-count-entry handling, guard references,
weak-reference invalidation, destructors, revalidation, edge severing, storage
reclamation, slot return, and candidate-bit clearing all run without the token.
Any access to trace scratch data after release is a defect.

The trace scratch arena is also reset at token release so that finalization can
use a replenished critical reserve. This creates an unresolved lifetime
requirement: exact validation and revalidation still need component membership
data after the trace arena is gone, but no allocator or ownership transfer for
that data is specified. See `dev/ALGORITHM-AUDIT.md`, issue A6.

Mark and scan are the only readers and writers of shadow rows and visited
bitmaps. Exact validation and teardown revalidation must compute `IN` by
iterating current fields against a retained component-member list; they must not
read released trace rows.

**Check collection eligibility before waiting.** After allocation failure, a
thread reads its collecting flag and `TEARDOWN_DEPTH`. If either prohibits
collection, the thread follows the memory-pressure fallback instead of waiting
for a token it cannot use. Otherwise it waits, acquires the token, and traces.
A trace runs no user code, takes no user lock, and releases the token before
destructors, so this wait is intended to be bounded.

A collector worker that finds the token held or the owner's result inbox full
skips that owner until a later round. Candidate bits remain set.

### Worker-to-owner handoff

A collector worker swaps the owner's live candidate-queue buffer for a spare,
traces the detached buffer, and posts the marked buffer to a capacity-one
per-thread inbox at token release. The owner processes it at a
consistent-point poll. Nothing waits for pickup.

The worker obtains its spare through ordinary allocation; failure skips that
owner for the round. Synchronous collection tries the pool, the owner's two
spare segments, and then the critical reserve. If all three fail, it aborts
before tracing. See `cycle/questions.md`, Y12 clause 3.

The queue swap is not yet linearized against concurrent candidate registration.
Until that protocol is defined, a worker can lose or duplicate an entry. This
blocks the collector-worker optimization; see `dev/ALGORITHM-AUDIT.md`, issue
A2.

At pickup, the owner handles each entry in one of four ways:

- return storage for a zero-count entity when slot reuse is safe;
- finalize a component confirmed as unreachable;
- requeue an entry that was not traced or not validated; or
- move a candidate that currently has an external reference to the
  deferred-candidate buffer until the epoch changes.

The owner is the sole writer for all of these queue transitions.

While a trace is active, its owner defers reuse of released slots. Other threads
need not do so only if the block-disjointness prerequisite above holds.

`ll-model`'s `abandon_all` can clear a block's owner at thread exit, after which
`adopt` assigns the block to another thread. A trace may still hold rows for the
block while this happens. Block migration therefore requires explicit ordering
against the old owner's trace token; this remains open in `dev/PLAN.md` S8.9.

## Cost model

The superseded `rc-walk` design avoided per-operation mutator work but required
a full heap census each epoch. It read every entity-block slot and built the
graph of the complete aged population whether or not it had changed.
`rc-cycle` instead pays the smaller cost of registering a candidate at the
decrement that creates it.

The candidate-registration machinery measured at no more than 0.4 ns on a
retain-and-release pair that does not reach zero; 0.4 ns is the instrument's
resolution limit rather than a measured duration. A traced entity costs
32–41 ns per epoch as a singleton and 72–108 ns in a chain. Dividing the
trace's cost by the candidate
cost's *upper* bound gives the smallest crossover the evidence permits: at least
80 non-final decrements per live entity per epoch for the singleton shape and at
least 180 for the chain. Whether representative programs approach either
crossover remains a workload measurement.

Reference counts remain current, which keeps zero-count teardown prompt. Because
no count is deferred or coalesced, an entity whose count reaches zero begins
teardown immediately. Only unreachable reference cycles wait for collection.

## Requirements retained from earlier designs

Four requirements originated in the earlier collector work: exact owner-side
validation against current fields, deferred slot reuse while an identifier is
in flight, prompt zero-count teardown, and the occupancy index for retained
blocks. Only the occupancy index exists in code today
(`ll-model` `memory/retained.rs`); the other three must be implemented for this
design.

The old mutator handshake is not retained. It could deadlock with a mutator
waiting on its trace token. Collector workers instead use the buffer handoff
described under “Concurrency”.

Only the owning mutator validates and reclaims a component. Exact validation is
sound only when the owning thread stabilizes the entity while reading its
current fields. The weak-reference table is also per thread, so a collector
worker cannot invalidate weak references before user teardown runs.

## Removed full-census structures

The census and the full edge build of Phase 1. Everything that made them
expensive — `slot_rows` at four bytes a slot written before anything is read,
thirty-two bytes an edge, the id map — is what this design exists to delete. The
shadow rows are four bytes a slot too, but only for blocks a trace touched, only
for the duration of that trace, and only written where the trace went.
