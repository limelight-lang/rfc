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

### Aggregate proof fast path

Collection has two scheduling modes:

- **Normal mode** only registers candidates and defers collection to a later
  consistent point. It does not reclaim a component on the decrement path.
- **Critical mode**, entered under memory pressure, processes candidates at
  the first collection-safe point. When the owning mutator proves the aggregate
  equality against current fields and counts, it proceeds directly to cycle
  finalization and reclamation rather than deferring the proven set.

A proof retained by normal mode is not a reclamation permit: heap state may
change before the deferred commit, so the owner must validate it again.

Per-entity shadow counts are not required when the complete visited set can be
proved unreachable as a whole. For a visited set `S`, current reference counts
obey

```text
sum(RC(v) for v in S) = internal_edges(S) + incoming_edges(outside, S).
```

All terms are non-negative, so equality between the reference-count sum and
the number of internal counted edges proves that no member has an external
counted reference. The owner may then pass the whole set to exact validation
and cycle finalization. Accumulator overflow makes this proof inconclusive; it
must never be handled as equality.

This proof is sufficient but not necessary. If an unreachable cycle has an
outgoing edge to an externally reachable object, a traversal that includes
that object fails the aggregate test even though a collectible subset exists.
Per-entity shadow counts remain the fallback that can separate that subset.

The aggregate pass also permits a smaller scratch representation:

- one append-only traversal vector, advanced by an index, serves both as the
  worklist and as the retained component-member list;
- a visited bitmap prevents duplicate insertion;
- two checked accumulators hold the reference-count sum and internal-edge
  count;
- shadow rows are allocated and populated only if the aggregate proof fails
  and the collector chooses to search for a collectible subset.

The persistent candidate queue remains logically separate: it records roots
across collection attempts, whereas the traversal vector contains every member
discovered by one attempt. An implementation may reuse detached queue storage,
but only after the owner has established a linearized snapshot; the unresolved
worker detach protocol does not yet provide that guarantee.

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

**Stack-reference invariant:** every reference live in a local variable or
stack slot at a collection point contributes to the entity's reference count.
Retain/release elimination is therefore allowed only in a region where
collection cannot start. Such a region contains no call, store, release, or
consistent-point poll.

Without this invariant, the following execution is unsafe:

1. `$node = $ring->head` is compiled with its retain elided because
   `$ring->head` is treated as the covering reference.
2. `$ring = null` removes the external reference to the ring.
3. The collector subtracts `$ring->head` as an internal edge and concludes
   that the component is internally balanced.
4. The collector reclaims the ring while `$node` still points into it.

Ordinary refcounting frees only at zero and does not expose this case. A cycle
collector may reclaim an internally balanced component whose members have
non-zero counts. The covering obligation must therefore be an actual counted
`+1`, not merely the knowledge that another edge exists.

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
sizes, no stride — goes by binary search over its survivor list, which the
block's own header names (next section). A **large
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
bytes of rows plus the visited bitmap. The first such bytes come out of the
thread's workspace, one 64 KiB block held from its first collection to its exit
([`critical-reserve.md`](../memory/critical-reserve.md), "Collection working
memory"); past it the arena draws further pooled 64 KiB blocks, the ordinary
allocation path first and the reserve path after ordinary allocation fails.
Allocation returns null on failure, allowing the trace to abort and return every
block it drew, the workspace staying with the thread. The rejected virtual-reservation alternative could
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

## The survivor list of a retained block

A retained block is a former arena block whose survivors were promoted in
place. Its header's collector line carries, beside the shadow pointer, the
address and length of a sorted array of its survivors' addresses, and one
64-bit count word: live survivors in the low half, and in the high half the
payloads the block is pinned for, the survivor lists of other blocks standing in
it, and the count the reset holds of its own while it establishes the
occupants.

The reset writes the array and the two words on the thread that owns the arena,
and does not publish them in one instant. Retention clears the whole collector
line and then stamps the block's kind, which publishes zeros; a block retained,
returned and retained again would otherwise carry a stale array address.
Retention is unconditional for a block that holds a survivor, and a block held
for a pinned payload alone is stamped in the same pass, because a payload freed
inside the reset must route to the retained arm by its kind. A block that
becomes the holder of *another* block's list is stamped later, when that list is
placed. The array is written after the fixpoint and published by a release store
of its own,
the length first and the address after it. The count word is published last, by
an increment whose release half covers the address; published before the list,
it would let a decrement that reaches zero on another thread land between the
two stores, read a null address, and return the block without spending the hold
the list has on its holder. A trace reading the list acquire-loads the address
and reads the length behind it, both plain moves on x86; the count word's own
writes are locked read-modify-writes — one per retained block at the reset, one
per pin, and one per death. Every list is placed, and its holder retained and pinned, before any
block's count is read, so a holder whose own survivors all died inside the reset
cannot answer empty while a later block's list is still to land in its tail
(`ll-model`, `dev/DECISIONS.md`, "the reset places every survivor list before it
reads any count").

Between the kind's store and the count's, the low half reads zero while the kind
already routes a free to the retained arm, and two mechanisms cover that window.
The reset holds one count of its own per block it pins, from the pin until the
occupant counts are established, and spends it after. Its own window absorbs a
free that finds the low half at zero, keying on the count rather than on the
list's presence, so a block published without a list still counts its deaths. A
block whose survivors all died inside the reset is therefore returned by the
reset itself, through an arm that asserts the count reads zero, rather than by a
last death that never comes (`ll-model`, `dev/DECISIONS.md`, "the reset holds a
pin of its own, and releases it after the index is real").

The array lives in memory the arena already holds: the retained block's own tail
when the list fits below its last object, otherwise the reset's current block,
which is then retained as the holder of that list, and only when neither has
room a block drawn from the memory manager. A null address is a block retained
for a payload alone, and the trace treats an edge into it as an external live
reference. The process-wide registry that once held these lists served
`rc-walk`'s census of every block; nothing in this design enumerates retained
blocks, so no such table exists (`ll-model`, `dev/DECISIONS.md`, "a retained
block's survivor list lives in the arena's own memory").

A retained block is on no thread's list. Thread exit neither abandons nor
adopts it: its survivors die by counting from whichever thread releases them,
and the last death returns the block. The count word is decremented
atomically for that reason — `ll_free` is an ABI entry and cannot be made
owner-only — and the value the decrement returns says whether the caller holds
the last count and returns the block. Both halves reaching zero is the whole
condition; two separate words could not answer it without a lock.

A block that holds survivor lists returns when its last list and its last
survivor are gone, whichever comes later. A list dies before its block does,
in the same operation that returns the block it describes, so no list ever
names a returned block.

The quiescent enumerator of the collected heap — the test-only walk that
visits every slot — finds retained blocks by their kind in the region scan and
reads the list from the header without a lock; the quiescent-mutator contract
it already states is what makes the read sound.

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
occupancy decreases at that return rather than at zero-count teardown.

In the in-line form the free path tests the two conditions in that order, and
only one of them writes anything down. A slot whose entity still has a
candidate-queue entry is recorded nowhere, the entry naming the slot already,
and the disposal of that entry is what returns it. A slot freed while the
thread's own trace is open is appended to the trace's **deferred-reuse list**,
which the trace's close replays through the ordinary free path once its last
row is gone, so the two conditions may clear in either order. That list is a
fixed region of the thread's collection workspace holding 1,024 records, and it
asks no allocation path (`ll-model`, `dev/DECISIONS.md`, "the withheld returns'
first 1,024 records are the workspace's second region").

**A death past that region is marked in the dead slot rather than recorded**,
and the sweep that nulls the block's shadow pointer is what finds it, so for
such a death the free path asks no allocation path either. The slot's count still reads zero
under the mark and its candidate bit is still clear, so a reader of the first
word sees what this section already specifies; what the mark adds is a third
answer to the question of whether the allocator may have the slot, and every
walk that asks it reads the mark beside the count. The region, its 1,024
records and the eight-byte append all stay: a mark costs the sweep a walk of
the block's slots where a record costs eight bytes, and that walk is dearer in
cache lines at every size class the design is computed over, so it is paid
where it buys something — on the refusal — and nowhere else (`ll-model`,
`dev/BENCHMARKS.md`, 2026-09-04, S43.1, and `dev/DECISIONS.md`, "the chain
stays and the mark answers its refusal").

**A mark is taken only where the sweep will find it.** The block carries this
trace's shadow pointer, and the thread taking the mark owns the block: a shadow
pointer another thread's trace wrote, or one standing on a block an exited
thread abandoned, addresses rows this thread's sweep will never walk.
**The owner clears a mark and returns the slot**; a collector worker may not,
for the reason it may not clear the candidate bit.

The other two populations have no slot word to write into — a retained block's
whole-block return and an OS-direct run — and **their marks are owed rather
than specified**. Neither condition above transfers to them as it stands: a
retained block is on no thread's list, so ownership does not name a thread
there, and a retained occupant's mark would land in the same word the emptiness
count reads, which decides whether the block goes back to the pool.

**A death the mark cannot take still takes a record**, and with it the growth
past the region that the mark exists to retire. One case is left in that state
and it is open: a slot dying past a full region in a block no shadow pointer
addresses, or in one this thread does not own. It cannot be marked, a mark there being one no
sweep walks to, and a return cannot be dropped. Two forms would close it — one
record per block rather than per slot, which retires both conditions above, or a growth kept for that one population — and the design chooses
neither here. Until one is chosen, a record the region cannot take and the
growth cannot fund has no answer.

What answers memory starvation, which is a regime rather than this residue, is
the collection: one that cannot carry on with the memory it holds winds itself
down, sweeps its rows, replays what it has already withheld and returns every
block, the critical reserve included (Edmond, 2026-09-03; `ll-model`,
`dev/DECISIONS.md`, "under memory starvation a collection ends itself and gives
back everything"). In that regime no collector is needed, each thread freeing
its own memory by counting.

A thread runs at most one trace at a time, so no old or newly started trace of
its own can address a replayed slot. Establishing the same instant for a
collector worker still needs the generation or handoff protocol issue A3 asks
for; that half is open. See `dev/ALGORITHM-AUDIT.md`, issue A3.

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
blocks. Block adoption is ordered against the trace by the exit rule at the end
of this section. The proof is still incomplete for moved objects, actor sharing
and FFI entry. These are correctness prerequisites, not optional optimizations;
see `dev/ALGORITHM-AUDIT.md`, issues B3, B4, and C3.

The token covers mark, scan, and reads of the live candidate queue. The tracer
releases it at the end of scan, before exact validation and before the first
destructor, on both paths. Everything after the release — zero-count-entry
handling, guard references, weak-reference invalidation, destructors,
revalidation, edge severing, storage reclamation, slot return, and candidate-bit
clearing — runs without the token. What the release ends is the right to trace
and not the life of the rows: reading a row whose block has gone back is a
defect on either path, and reading one whose block has not is what the ordinary
path's teardown does.

**When the arena goes back depends on why the collection ran.** A collection
off the safepoint poll keeps its rows: the arena is not reset before the
teardown, and the guards, the weak nulling, the destructors, the sever and the
frees read the shadow rows directly, so there is no component-member list at
all and nothing is allocated to hold one. A collection an allocation failure
started gives its memory back first, because the destructors it is about to run
allocate and there is nothing to allocate from: the sweep that nulls the
touched blocks' shadow pointers writes the unreachable rows into a fixed region
of the thread's workspace, every block then goes back, and the teardown runs off
that region. The region's capacity is fixed and never grows; entities past it
keep their candidate bits and stand in the queue for the next trace, which under
pressure follows immediately, on the memory the first teardown returned
(`ll-model`, `dev/DECISIONS.md`, "the member list is the pressure path's
alone"). This answers `dev/ALGORITHM-AUDIT.md` issue A6 for the in-line
collection: on the ordinary path the arena is not gone, and on the pressure path
the membership data is a bounded region of memory the thread already holds.
Whether a worker's trace may hold its arena the same way is open with the
accelerator.

**The ordinary path's teardown runs inside its own trace**, and three things
follow from that. Every slot the teardown frees waits for the window's close
rather than returning at the free. The releases the sever performs are non-final
decrements, so the live children of a member register as candidates in the
operation that frees them, and the collection therefore **disposes of** its
detached chain — takes the batch and gives its segments back — instead of
restoring it into a write position the severing has already refilled; a restore
over a refilled lane is a checked error in every build. And a collection that
cannot carry on with the memory it holds ends itself and returns every block,
the critical reserve included, which is the answer to a refusal rather than a
process end (`ll-model`, `dev/DECISIONS.md`, "the restore's refusal is the
ordinary teardown, and it yields on an unwind" and "under memory starvation a
collection ends itself and gives back everything").

The readership rule narrows with it. Mark and scan remain the only **writers**
of a shadow row. The readers are mark and scan, the sweep that harvests on the
pressure path, and on the ordinary path the owner's own teardown after the
release. Nothing else reads them, the in-line form having no second tracer.
What a worker may do here is open twice over: whether its trace may hold its
arena through a teardown the way an owner's does (`ll-model`,
`dev/DECISIONS.md`, "the member list is the pressure path's alone, and the
surplus is a second trace", which leaves that to the accelerator), and whether
it may acquire an owner's token while that owner's teardown is still reading
rows, which no ruling has reached.

Exact validation and teardown revalidation compute `IN` by iterating current
fields against the component's members: on the ordinary path the rows the
collection kept, on the pressure path the harvested list. Neither may read a row
whose block has gone back.

**Check collection eligibility before waiting.** After allocation failure, a
thread reads its collecting flag and `TEARDOWN_DEPTH`. If either prohibits
collection, the thread follows the memory-pressure fallback instead of waiting
for a token it cannot use. Otherwise it waits, acquires the token, and traces.
A trace runs no user code, takes no user lock, and releases the token before
destructors, so this wait is intended to be bounded.

A collector worker that finds the token held or the owner's result inbox full
skips that owner until a later round. Candidate bits remain set.

### Worker-to-owner handoff

A collector worker detaches the owner's active candidate chain — two words, the
head segment and its fill — traces it, and posts the marked chain to a
capacity-one per-thread inbox at token release. The owner processes it at a
consistent-point poll. Nothing waits for pickup. The detach draws no segment and
cannot be refused, so a collection is never stopped at its front by an
allocation; the lane it leaves empty is the state a thread holds before its
first registration, and the next registration takes the growth path
(`cycle/questions.md`, Y12 clause 2).

What a trace does need is rows. The worker draws its own workspace and its own
scratch blocks through ordinary allocation, and skips that owner for the round
when the pool refuses. Synchronous collection tries the pool and then the
critical reserve, and aborts before drawing a row if both fail. See
`cycle/questions.md`, Y12 clause 3.

The detach is not yet linearized against concurrent candidate registration: it
moves two words the writer is about to write, and until that protocol is
defined a worker can lose or duplicate an entry. This blocks the collector-worker
optimization; see `dev/ALGORITHM-AUDIT.md`, issue A2, and `dev/PLAN.md` S8.7.

At pickup, the owner handles each entry in one of four ways:

- return storage for a zero-count entity when slot reuse is safe;
- finalize a component confirmed as unreachable;
- requeue an entry that was not traced or not validated; or
- move a candidate that currently has an external reference to the
  deferred-candidate buffer until the epoch changes.

The owner is the sole writer for all of these queue transitions.

While a trace is active, its owner defers reuse of released slots. Other threads
need not do so only if the block-disjointness prerequisite above holds.

**A thread does not exit while any trace holds rows over its blocks.** It
waits, collects, retires its queue and only then hands its heap over, so
`ll-model`'s `abandon_all`, which clears a block's owner, and `adopt`, which
assigns the block to another thread, never run under a live trace. The
collection precedes the queue's retirement because the queue is its root set
(`ll-model`, `dev/DECISIONS.md`, "a thread waits for the trace, collects, and
then exits", ruled 2026-09-04).

**What bounds that wait differs by path, and the ruling was written against the
shorter one.** On the pressure path the rows go back before the first
destructor, so the exiting thread waits only for a trace, which runs no user
code and takes no user lock. On the ordinary path the rows are held across the
teardown, so it waits behind that teardown's destructors as well. Nothing
unbounded stands behind a destructor by rule, but nothing bounds one either.

What that last collection could not take — a component whose destructor threw,
or one a refusal ended — keeps its candidate bit, and once its blocks are
adopted no thread will register it again. That residue is a bounded leak with
no collector. An estate a worker could claim, which would make that worker the
component's owning mutator, is refused until the accelerator exists and is
revisited then against the measured residue, so the second clause of
`dev/ALGORITHM-AUDIT.md` issue A4 stands open where the first is closed
(`dev/PLAN.md` S8.9).

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
in flight, prompt zero-count teardown, and a survivor list for retained
blocks. Only the survivor list exists in code today, and in the form this
document specifies: a list the block's own header names, no process-wide table
naming retained blocks (`ll-model`, `memory/retained.rs`). The other three must
be implemented for this design.

The old mutator handshake is not retained. It could deadlock with a mutator
waiting on its trace token. Collector workers instead use the detached-chain
handoff described under “Concurrency”.

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
