# Critical reserve

> **Status:** design of record. The design currently provisions eight 64 KiB
> blocks (512 KiB) per mutator thread. This is an initial value, not a
> workload-derived bound.

## Scope

The critical reserve is memory that the allocator withholds from ordinary
allocations. It is intended to let a small set of runtime operations make
progress after the ordinary allocation path returns null. The bounds required
to prove the current size sufficient remain open.

The reserve belongs to the allocator and is private to one mutator thread. It
is not a separate allocator. Call sites explicitly select either the ordinary
allocation path or the reserve allocation path.

The reserve has two defined users and one reserved use whose call-site contract
is still open:

1. mandatory growth of the cycle-candidate queue;
2. temporary memory used by a collection running for that thread; and
3. progress by a mutator that cannot start a collection, once the eligible
   operations and their bounds have been specified.

The exception reserve described in
[`runtime/exceptions.md`](../../runtime/exceptions.md) is separate and cannot be
borrowed for these operations.

## Allocation paths

The **ordinary allocation path** uses free lists, pool blocks, and arena bump
allocation. It returns null when it cannot satisfy a request.

The **reserve allocation path** may consume the protected per-thread blocks. It
fails only after those blocks are exhausted as well.

Two invariants keep the reserve available:

- A reserve block must never become an ordinary bump-allocation block.
- Eligibility is determined by the call site, not by current memory pressure.
  Only operations explicitly allowed below may use the reserve path.

Allowing an arbitrary failed allocation to retry against the reserve would turn
the reserve into ordinary memory and remove the guarantee it exists to provide.

## Why the reserve is per thread

Candidate queues are thread-owned, so several threads may need queue capacity
at the same time. The trace token serializes only the trace for one owner; it is
released before exact validation and cycle finalization. Consequently, several
owners may validate and reclaim components concurrently. A process-global
reserve would add contention without serializing these consumers.

The same ownership rule applies to a mutator that cannot collect: its progress
budget is local to that thread. See [`rc-cycle.md`](../gc/rc-cycle.md),
“Concurrency”.

## Reserve users

### Candidate-queue growth

A non-final decrement may register an entity as a cycle candidate. Registration
is edge-triggered: losing the entry can make a reference cycle permanently
undiscoverable. Registration has no recoverable failure channel, and no branch
may silently drop an entry.

The live segment first swaps in one of two spare segments held by the owning
thread. Thread initialization and each consistent-point poll try to replenish
those spares through the ordinary allocation path. If no spare is available,
queue growth uses the reserve allocation path. See
[`cycle/questions.md`](../gc/cycle/questions.md), Y12 clause 3.

If reserve allocation also fails, a lifetime-held **overflow buffer** is the
last storage tier. One pool block of baseline overflow capacity is allocated at thread
initialization. A thread that cannot obtain this mandatory block does not
start. If initialization was skipped, the first candidate registration obtains
it lazily; failure on that path aborts the process because registration cannot
be reported to application code. The buffer is finite, and the current RFC does
not prove that it cannot fill between polls. That correctness blocker is
recorded in [`../../dev/ALGORITHM-AUDIT.md`](../../dev/ALGORITHM-AUDIT.md), A5.

The overflow buffer is not part of “reserve mode”: reserve mode begins when a
reserve block is actually consumed. Whether overflow-buffer entries must also
participate in the condition for leaving reserve mode is unresolved.

The deferred-candidate buffer is not a reserve user. It grows from spare space
in its tail and then through ordinary allocation. If both sources fail, the
candidate is returned to the live queue.

### Mutator progress while collection is unavailable

After an allocation failure, a mutator checks its collection-entry conditions:
the collecting flag and `TEARDOWN_DEPTH`. If collection is permitted, the
mutator waits for its trace token, acquires it, and runs a synchronous trace. If
the entry conditions prohibit collection, ordinary application allocation must
not retry against the reserve.

The design intends to let a bounded set of runtime progress operations continue
until the next consistent-point poll. The ABI does not yet identify those
operations or bound their maximum allocation volume. Until it does, no call
site is eligible under this category. Defining the allowlist, the routing of
each eligible allocation, and the between-poll bound is an open blocker; the
reserved capacity for this category cannot yet be derived.

### Collection working memory

A trace uses a bump-allocated scratch arena for its worklist, shadow rows, and
visited bitmaps. The arena opens over one block the thread already holds, its
**workspace**, and grows past it. Growth tries ordinary allocation first because
most collections do not begin under memory pressure and a full trace can be much
larger than the reserve. It falls back to reserve allocation when ordinary
allocation fails.

The workspace itself has one allocation path, the ordinary one. A thread draws
it at its first collection and keeps it until the thread exits; the arena's
reset rewinds the bump over it rather than returning it, so every collection
after the first opens on memory the thread already has. A refused workspace draw
is a collection that does not start. Reserve allocation may never fund it,
because a reserve block held for the life of a thread is a reserve spent as
ordinary memory.

If both paths fail during growth, the trace aborts and returns every block it
drew. Blocks obtained from the reserve return to it when the trace scratch arena
is reset, including on abort.

One fixed region stands in front of the bump inside the workspace, and it draws
on nothing: the first 1,024 records of the deferred-reuse list, so a trace that
withholds fewer slots than that asks no allocation path at all
([`../gc/rc-cycle.md`](../gc/rc-cycle.md), "Zero-count entities pending slot
reuse"). A second region takes the same shape and the same bytes when the free
path stops carrying that list: it is where a collection an allocation failure
started harvests its unreachable rows before returning its blocks, and it is
what that collection's teardown reads in place of a component-member list. Its
capacity is unchosen. What the post-trace validation storage of
[`../../dev/ALGORITHM-AUDIT.md`](../../dev/ALGORITHM-AUDIT.md) A6 adds to this
reserve's bound is zero either way, both regions being part of a block the
thread already holds.

The current flat shadow-row layout needs four bytes per slot. At the smallest
size class, one touched block therefore needs about 16 KiB of rows. A 512 KiB
reserve can fund roughly thirty such blocks, and more at larger size classes.
This is a capacity estimate, not a proof that the complete pressure path fits.

## Reserve lifecycle

The allocator obtains the reserve when the mutator thread is initialized and
holds it for the thread's lifetime. Reserve blocks never return to the ordinary
allocation path.

A compiler-emitted consistent-point poll replenishes consumed capacity through
ordinary allocation. If replenishment fails, the normal failure sequence
applies: reclaim, collect, retry, and then raise the catchable
memory-exhaustion exception described in
[`runtime/exceptions.md`](../../runtime/exceptions.md).

The exit predicate for reserve mode is not yet specified. Replenishing consumed
blocks is necessary but not sufficient: candidates may still exist in the live
queue, a detached or in-flight segment, the validation handoff, or the
lifetime-held overflow buffer. The RFC does not yet define a registration
generation or another mechanism by which the owner can observe completion
across all of these representations.

Until the pending set and its completion observer are defined, leaving reserve
mode is an open blocker. An implementation must not infer an exit condition
from an empty live queue or from replenished reserve capacity alone.

## Exhaustion behavior

For collection working memory or mutator progress, exhaustion aborts the
current collection attempt and eventually raises memory exhaustion from a
runtime frame that can report it.

Candidate registration may run without a frame from which to report failure. If
the reserve path is exhausted, the entry goes to the overflow buffer. The next
consistent-point poll tries collection before reporting memory exhaustion. A
poll whose collection-entry conditions are closed neither collects nor waits;
it carries the entries to a later poll because a collection or teardown is
already active.

No branch may drop a candidate entry. Filling the overflow buffer reaches the
current process-abort edge until A5 is resolved.

## Sizing evidence and open questions

The 512 KiB implementation value rounds the original 500 KiB design estimate to
eight pool blocks. It was chosen before representative workloads existed.

Three measurements are still required:

- candidate-registration rate during a queue drain;
- the maximum number and size of managed allocations between consecutive
  consistent-point polls; and
- the number and occupancy of blocks touched by a pressure-triggered trace.

Those measurements determine whether 512 KiB is sufficient and whether the
reserve needs fixed sub-budgets for its three users. No partition is specified
until the measurements exist.
