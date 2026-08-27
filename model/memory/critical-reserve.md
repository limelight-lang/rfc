# The critical reserve

The critical reserve is a block the memory manager takes from the operating
system once and holds, so that work which must not fail can be served after the
ordinary path has nothing left. It belongs to the allocator rather than sitting
beside it: **the same allocator has two doors**, and the caller names which one
it is entitled to. It is **per mutator thread, 500 KB**, and it has three
customers — the enrolment queue's growth, the mutator whose entry gate is
closed and must continue anyway, and the working memory a collection uses on
the thread that runs it, trace and judgement alike.

The size is Edmond's, set 2026-08-25 (`../../dev/DECISIONS.md`), and it is a
starting figure rather than a measured one. **No share is derivable today** —
the one that was lost its arithmetic when the header index went — and the
section on sizing says what each waits on.

## The two doors

The ordinary door serves from free lists, blocks and the arena bump, and when
it has nothing it **refuses** — returns null, which every allocation path here
already handles. The critical door serves from the held block and refuses only
when that block is spent too.

This is what makes "ask the allocator when the allocator has just refused you"
a coherent sentence rather than a contradiction: the refusal came from the
ordinary door, and the critical caller was never asking through it. There is
one allocator, one place that knows what memory the thread has, and one block
inside it that ordinary requests cannot reach.

Two rules keep the doors apart, and both are load-bearing.

**A reserve block never becomes the ordinary path's bump block.** Otherwise the
next ordinary allocation eats the reserve and the refusal that was supposed to
report never happens.
[../../runtime/exceptions.md](../../runtime/exceptions.md#allocation-failure-is-an-ordinary-exception)
states this for its own log reserve and it holds here for the same reason.

**Entitlement is a property of the call site, not of the moment.** A caller
goes through the critical door because it is one of the three below, never
because memory happens to be short. A path that takes the critical door on
pressure alone converts the reserve into ordinary memory with extra steps.

## Why it is per thread, and why nothing sits beside it

The residence follows who can draw at the same instant. Two customers are
per-thread and concurrent: every thread owns its enrolment queue
([../gc/cycle/questions.md](../gc/cycle/questions.md), Y12), so several threads
can need a growth allocation at once, and a thread whose entry gate is closed
continues on the reserve rather than waiting for the trace token.

The third is per-thread too, and since 2026-08-27 it is no longer exclusive.
The trace token serializes the **trace** and nothing else, and it is released
before any exact test, so several owner threads can be judging and tearing down
at the same instant and each draws for its own working memory
([../../dev/DECISIONS.md](../../dev/DECISIONS.md), "the trace token covers the
trace alone, and the accelerator hands off by buffer swap"). A process-global
block would therefore be a contended residence for a per-thread load, and the
argument that used to carry this share — one collection at a time, so one
drawer — is retired with the clause it rested on.

The same split is already in force in `exceptions.md`, on the same principle:
its exception reserve is process-global because it is drawn only while
memory-exhausted is being raised, and its log reserve is per mutator thread.

## The three customers

**The enrolment queue's growth.** A non-final decrement enrols a candidate, the
queue fills, and its growth allocation is refused at the ordinary door. The
root is never dropped — a dropped enrolment is a garbage cycle no later
collection can find, enrolment being edge-triggered — so the growth goes to the
critical door (`../../dev/DECISIONS.md`, thirteenth entry of 2026-08-25). The
draw is one growth step. What bounds the total is not the queue's eventual size
but the mode: from the first such draw the runtime is in reserve mode, and it
leaves reserve mode only when every queued root has been walked, so the queue
drains while it fills.

**The mutator that cannot collect.** A thread short of memory tries to become
the tracer, and reads its own entry gate first — the collecting flag and
`TEARDOWN_DEPTH`. A closed gate sends it down the ladder, where it draws and
continues to its next checkpoint; an open one lets it wait on the trace token,
take it and trace, the wait terminating because the token is never held across
user code ([`../gc/rc-cycle.md`](../gc/rc-cycle.md), "Concurrency"). The refusal
to wait that stood here until 2026-08-27 was argued from a handshake
acknowledgement riding this thread's checkpoint, and the handshake is deleted.
The draw is bounded by what one thread allocates between two polls, the same
quantity `exceptions.md` bounds for the log reserve and leaves to the ABI.

**A collection's working memory.** The in-line collection of Y14 runs because
memory ran out, so its mark stack and its shadow-count arrays are drawn through
the critical door, from the reserve of the thread running it.

## Sizing

**The collector's share was derivable and is not any more.** The arithmetic
that stood here ran on Y7's eleven-bit collection index — 2047 entities to a
slice, a captured and a working count of four bytes each, a pointer stack of
eight, about 32 KB a slice — and the index was withdrawn on 2026-08-25 with the
slice bound that depended on it, then refused again on 2026-08-26
([../../dev/DECISIONS.md](../../dev/DECISIONS.md), "the header carries a hash
displacement, not an index" and "the shadow count is found by arithmetic from
the address"). There is no slice and no per-entity captured count now: a row is
four bytes in a per-block array. **How the rows are funded is open**, and it is
a question rather than a repair — this document draws them through the critical
door while [../gc/rc-cycle.md](../gc/rc-cycle.md) describes a virtual
reservation materialised page by page, and 500 KB a thread funds about sixteen
sparsely touched blocks at the 32 KB a block that
[../../dev/DECISIONS.md](../../dev/DECISIONS.md), "the shadow rows are not
zeroed greedily", prices. None of the three shares is derivable today.

**The queue's share is a rate against a duration and nobody has measured it.**
The question is not how large a thread's enrolment queue becomes but how many
roots are enrolled while a drain runs, which is the shape `rc-walk` already
carries for parked memory as `churn rate × epoch duration` and leaves open for
the same reason: it needs a workload.

**The mutator's share follows the poll interval**, which the ABI has not fixed.
`exceptions.md` states the contract it will need — a bounded number of barrier
operations between two polls — and that contract sizes this share too.

## Filling, refilling, and leaving reserve mode

The block is taken from the operating system when the thread is initialised,
where a refusal already has somewhere to go: the thread's first allocation
returns null. It is held for the life of the thread and is never returned to
the ordinary path.

Refill happens at the safepoint poll the compiler already emits, which runs in
a Limelight frame, so a refill that fails does the ordinary thing — reclaim,
collect, retry, and raise memory-exhausted if that also fails.

**Reserve mode ends when the roots are walked, not when the block is refilled.**
The two are different conditions and the walk is the load-bearing one: it is
what makes the reserve's use bounded rather than a slow slide into a smaller
and smaller headroom.

## When the reserve is spent too

The runtime raises memory-exhausted, an ordinary catchable `Throwable` here
rather than a fatal error, and it is legitimate precisely because everything
above has already been tried and a collection has run and lost. Constructing
the exception draws on the exception reserve, which is a different block and is
never lent to these three.

## What this document does not settle

The figure. 500 KB per thread was chosen before any workload existed, and two
of the three shares cannot be derived until one does. What would settle it is a
measurement of enrolment traffic during a drain on a real program, the same
corpus gate several other numbers sit behind.
