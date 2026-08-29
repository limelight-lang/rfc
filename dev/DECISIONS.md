# Architecture decisions

A changelog for architecture: what was decided and why, not what
changed in the code. Newest on top. A superseded decision is left in
place and replaced by a new entry, never edited away.

Format per entry (3–6 lines): date + one sentence on **what** was
decided; **why** (the problem or constraint); **rejected** alternatives
in one line; **cost** if any.

---

## 2026-08-29 — a trace stays inside the blocks of the thread it claimed, and the exclusion is per thread

**Ruled by Edmond**, replacing the process-wide rule of the two entries below.
The unit a collector excludes is **one mutator thread**, never the process. A
collector works with exactly one thread at a time; several collectors work at
the same time on different threads.

**Three configurations, and the shadow rows serve all three.** A collection
inside the mutator thread; one collector for many mutators; several collectors
beside several mutators. The row scheme was written for the second and read as
if the other two needed something else. They do not, because of the premise
below.

**Why a trace cannot reach another thread's blocks.** A transfer leaves no
reference behind: `thread_move` and `thread_clone` require the graph arriving in
the destination thread to hold no reference to an object that stays in the
source, so no thread ever names an entity living in another thread's blocks
(the entry below, "a transfer leaves no reference behind", and
[`../model/classes.md`](../model/classes.md), the lifecycle family). The crate
agrees: a refcount is stored with a plain relaxed store and never a
read-modify-write, so one thread alone changes a given count. A block belongs to
one thread's heap (`ll-model` `HeapBlockHeader::owner`), so the blocks two
collectors touch are disjoint, and with them the block's collector triple, the
touched list and every row.

*(Premise corrected the same day.* This paragraph first named the crossing
reference a **borrow** and claimed the trace does not follow one. That was
wrong: [`../model/memory/static-lifetimes.md`](../model/memory/static-lifetimes.md)
defines a borrow as a frame-only compile-time state whose obligation is
within-frame, and anything leaving a frame is stored and counted — so a borrow
is the shape that *cannot* cross a thread. The conclusion is unchanged; what
carries it is the transfer rule.)

**What this withdraws.** `amSolo` as a process rule; the trace token as one word
for the process; and the parking of *every* thread's frees while any trace runs.
The sentence those three rest on — a trace's closure crosses heap partitions and
its holder cannot know in advance whose blocks it will touch — is false under
the borrow guarantee, and it was the premise rather than a finding.

**What replaces them.** Exclusion covers the claimed thread: a second tracer of
the same thread is refused, a tracer of another thread is not. Frees park on the
traced thread alone. Row addressing is unchanged — arithmetic from the object's
address, no key and no owner stamp — because a block under two traces cannot
arise.

**Cost, and it is an open question rather than a price.** Edmond stated the
same day that a cycle spanning two mutator threads arises in the general case,
when a thread borrows another's object. The documents in force give that
crossing reference no name: a borrow is frame-only
([`../model/memory/static-lifetimes.md`](../model/memory/static-lifetimes.md)),
a transfer leaves none behind (the entry below), and a stack-held reference
carries a counted `+1` (2026-08-26, "a local reference always carries a counted
`+1`"). So the hole cannot be stated as a mechanism here, and what it is —
whether the vocabulary lacks a form the runtime will have, or the case is
already closed by the transfer rule — is `dev/PLAN.md` S8.10's.

*(This paragraph first read that a cycle through a borrow is found by no trace
on either side, which the corrected premise above removes: a borrow that cannot
cross a thread has no two sides.)*

**Document obligations.** `model/gc/rc-cycle.md`'s "Concurrency" and its
in-trace parking paragraph carry the new scope; `model/gc/cycle/questions.md`
Y14 loses the process-wide parking and the one-trace-per-process reading;
`ll-model`'s `dev/ARCHITECTURE.md` rule 15 states the claim per thread rather
than per process, and `PLAN.md` S38.1 and S38.4 carry its mechanism — one flag
per mutator thread, free or held, taken by CAS by the collector that goes to
judge that mutator, with a mutex to wait on (Edmond, 2026-08-29);
`dev/PLAN.md` S8.9 owns the block that changes threads and S8.10 the question
above.

## 2026-08-29 — a transfer leaves no reference behind

**Ruled by Edmond**, closing what `model/classes.md` had reserved. Moving or
copying an object into another thread requires the graph that arrives there to
hold **no reference to an object that stays in the source thread**. What crosses
is closed: the destination reaches nothing the source still owns. A graph that
cannot satisfy it is not transferable, and the operation refuses rather than
producing a reference across the boundary.

**Rejected: transfer of ownership with atomic counting.** `classes.md` had
carried it beside share-nothing as an open pair. It is what produces the
reference this rule forbids, and the whole collector rests on the rule: with it,
no entity is named by a thread other than the one whose blocks hold it, which is
what lets a trace's claim cover one thread instead of the process (the entry
above).

**What it closes in the collector.** A Critic round of 2026-08-29 raised three
hazards that all needed a thread to hold a counted reference into another
thread's blocks — a foreign last release reaching `free_remote` while a trace
enumerates the slot, a foreign enrolment of a local entity, two collectors over
one large entity's row word. This rule forbids the precondition of all three,
and they close without a per-block claim, a fence on the free path, or an owner
word in three block populations.

**What it does not close.** Abandonment and adoption move a *block* between
threads with no reference crossing anything: `abandon_all` nulls the block's
owner at thread exit and `adopt` gives it to another thread, which can happen
while a trace holds rows for that block. That hazard survives this rule and is
owned by a step of its own.

## 2026-08-28 — the escrow's floor is allocator-issued, and a thread without one never starts

**Ruled by Edmond**, amending the escrow's storage two entries down. The escrow
leaves the thread's TLS image: its storage is one 64 KiB pool block — the
**floor** — the allocator issues at thread init, before the best-effort
reserve fills, and the thread holds for one init→exit life, returning it after
the exit drain. The draw's refusal is the thread that never starts, reported
by `ll_thread_init`'s new status return. The invariant stands on that coupling
instead of on TLS: every thread the runtime registered has a floor, because a
thread whose floor was refused is a thread the runtime never registered.

**The unregistered thread.** Entity work reaches a thread that never ran
`ll_thread_init` — self-initialising allocation, releaser-only FFI consumers —
and that thread has no floor at birth. It draws its floor lazily at first
enrol, once, through the ordinary door; the draw's refusal aborts, which is
the funded class's last resort reached by one more door. **Rejected: entity
work requires registration.** The enrolled bit is set before the write and the
undo is deleted, so a violation surfacing at `enrol` cannot continue except by
abort — the same abort, one door earlier — and the amendment would revoke the
recorded ABI promise that skipping `ll_thread_init` is slower-once rather than
undefined. **Rejected: a TLS array as the unregistered thread's fallback.** The
TLS image is what this ruling removes; conditional TLS storage does not exist;
a smaller fallback array has no written bound and carries its own overflow
abort.

**One life, not one OS thread.** "Thread" in the runtime's vocabulary is an
init→exit pair — the journal already gives each life its identity, and a pool
thread runs a sequence of lives on one OS thread. The floor is per life: it
returns at every `ll_thread_exit`, and a re-birth whose floor draw refuses
refuses that new life — the task dies, the process lives — observable through
the status return; the OS thread belongs to the host and is not the floor's
subject. **Rejected: abort on re-birth refusal** — a new process-kill edge on
a path that today degrades softly, a heapless re-birth. **Rejected: holding
the floor across lives** — the exit guard calls the same exit symbol, so
holding needs a second teardown mechanism; it parks 64 KiB in every OS thread
that finished a task and lives on; and the floor would be the only per-life
structure surviving its own life.

**The trade, recorded rather than derived.** A heapless thread today still
releases entities allocated elsewhere, and a releaser-only consumer allocates
nothing — so memory-hard thread creation is chosen for the invariant, not
derived from inability. It costs: the heapless releaser's path narrows to the
named abort edge under sustained full exhaustion; thread registration gains a
refusable, reportable outcome it did not have; every registered thread holds
64 KiB it may never use.

**Mechanics that survive unchanged.** One segment's capacity (8160 entries,
`ESCROW_ENTRIES` as it was), the `BLOCK_KIND_ARENA` stamp that keeps the trace
and the census out of the block, `POLL_STRIDE` and the sizing argument, the
poll's refill-drain-fire order, the overflow abort as the funded class's last
resort. The best-effort fills stay best-effort: the floor alone is mandatory,
being the one stock that cannot be refilled at a later poll without suspending
the guarantee between birth and that poll. The lazy draw checks the exit phase
and aborts for a thread past `ll_thread_exit` instead of drawing a block
nothing would return.

**Cost.** The escrow's 65 280 bytes — 99.4 % of the crate's 65 680-byte
zero-initialised TLS image — stand as the measurement that motivated the move;
what
the move does to `.tbss`, RSS and the larson respawn churn is S34.8's to
measure. Thread creation is memory-hard, and the ABI owes `ll_thread_init` a
status return. A floor block is out of the pool for its thread's life, which
moves every exact `blocks_out` accounting by one per live thread.

**Document obligations.** `model/gc/cycle/questions.md` clause 3 and
`runtime/exceptions.md`'s funded row and classification table carry the new
storage; `model/memory/critical-reserve.md` names the floor's edge beside the
reserve's; `model/memory/heap-slot-allocation.md`'s slower-once promise gains
its scope; the collector thread's birth moment and its floor refusal are
S38.0's to name.

## 2026-08-28 — a runtime loop carries the poll contract it broke

**Decided (Sage, second round on the entry below), after the consolidation pass
found the counterexample.** The escrow keeps its size and its place; what
changes is who the poll contract binds. `ll_release_vector` is a loop whose
`count` is the caller's and whose body the compiler never sees inside — it is
named for "frame teardown, a scope exit, a container clear" — and the compiler
emits its poll only *after* the call. So the argument the escrow was sized on,
that a whole segment cannot fill between two polls, is false for exactly that
shape: `runtime/exceptions.md` justifies it with "any loop has a backedge poll",
which quantifies over emitted code. **The loop that broke the bound takes on the
bound**: on its backedge, every `POLL_STRIDE` iterations, it runs the safepoint
poll itself. The stride is half the escrow, derived rather than invented, so a
loop obeying it cannot fill the escrow between two of its own polls whatever
the ABI's bound turns out to be.

**The backedge is a legal fire point and this ruling says so rather than
assuming it.** Iteration `i − 1` has fully returned, its death and destructor
with it, and `entities[i]` has not been read — which is
`model/gc/strategies.md`'s own "between mutator operations, after the current
store or teardown has completed". What makes it safe is a precondition the
vector's contract must now state: the caller severs every traced edge to an
entry before submitting the vector, the vector being the entries' last counted
holder. That precondition was load-bearing before this ruling — a concurrent
accelerator can trace at any instant — and what changes is that it is written
down. Inside a teardown the boundary is not clean and needs no special case:
`TEARDOWN_DEPTH` closes the entry gate, so the mid-run poll refills and drains
and fires nothing, which is the reentrancy guard `strategies.md` already
licenses.

**Three sentences of the entry below are withdrawn.** *"Only a fixed array in
the thread-local has no edge"* — a fixed array has no **refusal** edge, no
store on it failing for want of memory, and it has a capacity edge all the
same; the abort sits on it, and the duty is to keep that edge behind the poll
contract rather than to deny it. *"Where the thread stops is the next
compiler-emitted poll"* — inside a bulk run it is the run's own backedge poll,
and that sentence is what let the counterexample through. *The identification
of the token wait with Edmond's "wait for the collector to free memory"* — a
thread that takes the token has waited for another thread's **trace**, and the
token is released before any free, so it is handed no memory. Edmond's second
arm decomposes into two mechanisms the design already has: the **inbox pickup**,
where an accelerator's finished proposal lets this thread free its own condemned
garbage, which is where collector-freed memory actually arrives; and the token
wait, which is waiting for the right to trace. The poll's pressured order is
therefore refill, drain, pickup, then gate and collect. Nothing here discharges
less than Edmond ruled.

**What it costs.** One compare-and-branch per iteration of the bulk release
path, and a full poll every 4080 iterations — unmeasured, and no figure is
offered. A mid-run fire can interleave a pickup's teardowns with the vector's
own destructor order; the vector promises its entries' relative order and PHP
promises no destructor instant, so that is admissible.

**What is still true of the edge.** The abort stands behind a conjunction no
ordinary program produces: the pool refusing across polls, and either a gate
closed for the whole run or a collection that ran and lost, and then thousands
of further non-final decrements before the run ends. **Today's crate still
aborts there**, neither the collection nor the raise being built — the same
standing the store barrier's abort has. What this ruling removed is the case
that needed no exhaustion at all: before it, a clear of some ninety thousand
shared elements aborted with memory free.

**What the ABI is owed, plainly.** `runtime/exceptions.md`'s
bounded-operations-between-polls clause now binds runtime-owned loops over
caller-supplied counts as well as emitted code, and the bound **B** it has never
written must satisfy `B ≤ ESCROW_ENTRIES − POLL_STRIDE`, which is 4080 today.

## 2026-08-28 — an enrolment cannot fail: below the reserve is an escrow, and the poll collects or waits

**Ruled by Edmond**, closing the boundary the thirteenth ruling of 2026-08-25
stopped at: **nothing may be lost.** When memory is exhausted the mutator
thread either goes into collection itself or waits for the collector to free
memory. The drop-with-record tier the Sage had proposed at the spent reserve is
refused with the rest.

**The mechanism (Sage), because the ruling states the outcome and not the
machine.** Enrolment becomes **unfailable** and the thread never stops inside
`ll_release`. Below the live segment, the two spare cells and the critical
reserve sits a fourth tier that cannot refuse: a fixed **escrow** array in the
thread's own queue, `const`-constructible, never allocated and never grown, into
which a refused entry lands by a store and an increment. Clause 3 therefore
holds through the last tier — no allocation, no lock, no copy — and `enrol` has
no failure to report.

**Where the thread stops is the next compiler-emitted poll**, which for a
batched run is the statement boundary after its closing bracket. The poll
refills first, as it already does, and any door that funds a segment drains the
escrow through the ordinary write path. With the doors still spent and the
escrow holding, the poll runs Edmond's two arms behind the entry gate: an open
gate CASes the trace token and collects in line, or waits on the token when
another thread holds it — the wait terminating because the token is never held
across user code. **A closed gate neither collects nor waits**: the thread
carries on to its next poll with the entries safe in escrow, its gate being
closed precisely because the machinery that frees memory is what holds it. A
collection that runs and loses raises memory-exhausted from the frame the poll
holds, and the escrowed roots survive the raise with their bits set.

**Why not inside `ll_release`.** A collection there is unsound and the design
already says so: a store lowers the old value's count before it overwrites the
pointer, and a collection in that window walks the stale edge, subtracts one
reference twice and frees a live object (Y14). Y14 also already ruled that a
failed enrolment "arms and never fires" and that the collection runs at the next
clean point — so what this ruling adds is not the instant but the funding, and
the escrow is what carries the root from the refusal to the first lawful
instant. Waiting there is refused twice over: waiting for memory has no
guarantor when the sleeping thread is the only one that could free any, and a
release inside a teardown would block inside work a collection may be waiting
on.

**Rejected: a growable escrow**, which is the `Vec` trap the two reserves
already paid for — a push that cannot allocate aborts inside the code meant to
make exhaustion survivable. **Rejected: lending from the log or exception
reserves**, which makes each customer's worst case the sum of both.
**Rejected: enlarging the critical reserve**, which moves the boundary without
removing it; every finite fund has an edge, and only a fixed array in the
thread-local has none.

**Cost.** The escrow is sized at one segment's entries — 8160 of them, 65 280
bytes of thread-local per thread — because clause 3's own recorded argument,
that a whole segment cannot fill between two polls at any entry size, is the
only written bound available. Those bytes are committed at thread creation
rather than on first touch: measured in `ll-model` on 2026-08-28, the escrow is
99.4 % of the crate's zero-initialised TLS image, and that image is what glibc
allocates and zeroes for every thread it starts. That sits on top of the two spare segments and
`model/memory/critical-reserve.md`'s 500 KB, and it is deliberately
extravagant: what would license shrinking it is the ABI's poll bound, unwritten,
and the enrolment-rate-during-drain measurement the reserve's sizing already
waits on. The hot path gains nothing — the escrow branch sits after the
reserve's refusal. Memory-exhausted is reported up to one poll interval after
the memory ran out, which is the deferral the store barrier's funded
classification already accepts.

**What is bounded by argument and not by proof:** a gate-closed thread inside a
long teardown, enrolling across many polls while every door stays spent. No
written number bounds a teardown's external decrements. Behind it stands the
same last-resort abort the funded class already keeps
(`runtime/exceptions.md`), and the verification debt gains the case by name.

## 2026-08-27 — the suspects buffer is the owner's, and the re-offer is a splice at the epoch's turn

**Decided (Sage), closing Y12 clause 8.** The suspects buffer is one per
mutator thread, beside that thread's enrolment queue and made of the same
segments, and the owner is its only writer and its only reader — no atomics,
and the trace token does not cover it. Parking is the owner's disposition at
its exact reading: draining a detached buffer it sorts each entry four ways —
corpse, condemned, not-walked, acquitted — and the acquitted one is appended
here with its bit still set. **Epoch turnover is the maturation epoch of Y7 and
Y9**, whose counter is process-global and full-width, advanced by a collection's
commit once every N collections, the epoch field of the header's four-bit
maturation stamp carrying its low two bits. **The re-offer is the owner's first safepoint poll that finds the
counter moved** from a full-width thread-local mirror; at it the owner links
every suspects segment onto its own live queue, one link per segment, and
records the counter.

**Why the owner and why the poll.** Acquittal is the owner's exact reading, on
the owner's thread, in the in-line commit and at the inbox pickup alike, and the
re-offer is a write into the queue whose one writer is the owner (clause 1) — so
writer and reader are the same thread by construction, which is what makes the
buffer a plain owner-private chain. The poll is the instant rather than the
owner's next judgement, because a thread whose only garbage is a parked ring has
an empty queue, and Y14 fixes an in-line collection's scope at that queue: no
roots, so no judgement, and the ring is outside the token's coverage where no
accelerator reaches it either. Waiting for a judgement would wait for ever,
which is Y6's permanent miss by another road. The poll is not unconditional
either — `model/gc/strategies.md` puts it at statement boundaries, allocation
slow paths and request end — so a thread that blocks or exits reaches none, and
thread exit drains this chain beside the queue and the inbox.

**Rejected: the shadow arena as residence.** Its blocks return at the arena's
reset while a suspect must outlive many collections, so parking there either
pins the arena or forces a copy out at reset, which re-asks this question.
**Rejected: a process-global buffer.** The token is released before any exact
test, so several owners judge and park at the same instant, and the drain would
be a cross-thread write into per-thread queues that clause 1 forbids in terms.
**Rejected: no buffer, re-enqueuing every acquitted root under clause 5.**
Correct, and the negation of the economy: the age prune is evaluated on edge
targets and never on a root taken from the queue, so every survivor re-enqueued
would be re-descended from as a root — cheaply within an epoch, where its mature
targets read as opaque, and in full in the first collection after a turnover,
when every stamp is stale. That is the population YRC's own suspects buffer
removed, at 56 % of captures on its generational bench (Y9). It survives demoted to the funding
fallback, which is what lets the buffer's own growth refuse harmlessly.
**Rejected: an entry-by-entry copy at the re-offer.** A copy drains through the
queue's overflow path, and a large drain would consume both spare cells and then
the reserve, breaking clause 3's two-cell argument at a single poll; linking
whole segments consumes nothing.

**Cost:** up to one segment per thread from its first acquittal, and as many as
the acquittals between two re-offers fill — the chain empties at the first
re-offer poll after a turnover rather than at the turnover itself, so that
interval and not the epoch is the bound, and it is unmeasured in size. What would settle it is
suspects churn per epoch on the corpus, the same measurement
`model/memory/critical-reserve.md`'s sizing already waits behind; YRC's 56 %
prices the benefit and not this footprint. Per poll it costs two loads — the
global counter and the thread's own mirror — and one compare. **A suspect that dies while parked keeps its slot, and the slot's
block, parked until the splice puts its entry back where the corpse rule reads
it**, or until an in-line collection sweeps the buffer for corpses first — up to
one epoch, which is the widest retention this design carries and is accepted
rather than solved. The mass re-offered at a turnover feeds the expense Y9
already records, the first collection of an epoch being the expensive one, and
nothing bounds that mass here or there.

## 2026-08-27 — each consumer of a queue segment provisions its own swap

**Decided (Sage), closing Y12 clause 3.** The enrolment queue grows by linking
whole 64 KiB pool blocks — the only unit both funding doors dispense — and each
of the two consumers that swaps a segment in provisions it through its own
doors. The **owner** keeps two spare segments in a thread-private inventory of
two pointer cells, initialised to null without allocating and filled at thread
init and at every safepoint poll through the ordinary door; an overflow swaps a
cell in, and with both cells null draws the critical reserve and enters reserve
mode. The **token holder** provisions the trace's swap at the swap itself: a
collector thread takes a block through its own ordinary door and skips the
thread for the round when the pool refuses, while the in-line form asks the
pool, then its own cells, then its own critical reserve, and aborts before
tracing when all three refuse. A consumed spare is replenished at the inbox
pickup out of the buffer that comes back.

**Why the two halves differ.** At a non-final decrement no reader exists, so
"the reader allocates" serves the overflow never and the owner's checkpoint
inventory has to be built whatever feeds the trace. The holder then has no
reason to be on a pre-allocation discipline at all, standing at no hot path,
and the pool keeps a per-thread cache of eight blocks in front of its global
chain, so a holder is served in cases where the visited thread's own refill was
refused — provisioning at the swap is therefore no less available than
provisioning ahead of it, and it asks nothing of the hot path. It also
leaves the cells single-threaded, the owner being their only reader and writer,
so they need no atomics.

**Rejected: the accelerator drawing from the visited thread's cells.** Its skip
would fire on a timing gap the pool could serve — spares consumed, poll not yet
run — and each swap would strip that thread's overflow cover at the instant a
trace had just been provoked. **Rejected: the spares being the critical reserve
itself.** The reserve is per thread and unreachable to an accelerator, and
routing ordinary overflow through it would make reserve mode, whose exit is
gated on a full drain, the queue's normal operating regime.

**Cost:** 128 KiB resident per thread at rest, the two spares, on top of
`model/memory/critical-reserve.md`'s 500 KB, and 192 KiB from a thread's first
enrolment on — the live segment is a cell that first enrolment swaps in, so a
thread that never enrols holds two segments and not three. Add one transient
pool block per visited thread per accelerator round. A
reserve block can end up installed as a live segment on the in-line pressure
path and is repaid at that collection's drain, or at the next pickup after an
abort, so the reserve runs one block short for a bounded interval. Not
measured: the poll bound the two cells are sized against, which is the ABI's
and unwritten, and the enrolment rate during a drain, which is the corpus
measurement `critical-reserve.md` already waits on.

**Not adopted from the same ruling: a terminal tier at the spent reserve.** The
Sage also ruled that an overflow finding the critical reserve empty clears the
bit it had just set, records the root as a known leak and arms
memory-exhausted. Two things hold it back. It reinstates for candidate roots
the drop-as-known-leak licence of `runtime/exceptions.md` that the thirteenth
ruling of 2026-08-25 overrode for them by name, which is Edmond's to reverse
rather than a Sage's. And the record channel it names is not there: `ll-model`
compiles the journal's record sites away without the `debug-journal` feature,
which is off by default, so in any ordinary build the tier is a silent
permanent miss of exactly the class Y6 refuses. The boundary is open and belongs to no clause; `dev/PLAN.md` S8.5
carries it.

## 2026-08-27 — the gate's two inputs were thread-local in the deleted code, and neither exists today

**Verified, not decided.** The ruling below rests on the entry gate reading this
thread's own state, and named as its one obligation the scope of `ll-model`'s
collecting flag. Read from the source on the branch `archive/pre-rc-cycle`, all
four candidates were declared inside `thread_local!` blocks as `Cell`s:
`gc::GC_ACTIVE` ("True while a collection is running", the reentrancy guard),
`gc::TEARDOWN_DEPTH`, `epoch::TEARDOWN_DEPTH` and `walk::WALK_ACTIVE` ("whether
a synchronous collection is running **on this thread**"). The premise holds for
the shape the crate had.

**What it does not hold for is the present tense.** All four went with `rc-walk`
and `rc-trace` on 2026-08-26, so the gate has no inputs in the tree today and
the verification is of a precedent rather than of a live flag. The obligation
therefore moves rather than closing: **the step that rebuilds the reentrancy
guard writes it thread-local**, and a global "a collection is running" bit is
refused at that step rather than debated after it.

**The trap the reading exposes is the spelling, and it is why this is written
down.** `GC_ACTIVE`'s own comment reads "True while a collection is running" —
a sentence with no thread in it, over storage that is per-thread. A reader
checking the ruling's premise against the comment would answer wrongly in both
directions, and only the declaration settles it.

**Cost:** none; the finding is a constraint on unwritten code. What stays
unmeasured is what a per-thread guard costs against a global one on the entry
gate's path, there being no such path yet.

## 2026-08-27 — the entry gate reads this thread's own state and never the trace token

**Decided (Sage), amending the entry below.** The entry gate reads two things
and no third: the allocating thread's own collecting flag and `TEARDOWN_DEPTH`.
Neither touches the token. The gate answers one question — could this thread run
a collection if it held the token — which is answerable from the thread's own
state, and that is why it can precede the wait.

**The order a failed allocation runs.** The gate first. Either flag closed sends
the allocation to the next rung of the pressure ladder, and the token word is
not accessed on that path at all. An open gate CASes the token from free: a
successful CAS starts the in-line collection with no wait, a failed one means
another thread's trace holds it, and the thread waits on the word and retries
the CAS at each wake. There is no third outcome — an open gate leads to a
collection, sooner or later, never to the ladder. The gate is not re-checked
after the wait: a waiting thread is blocked inside the allocator and runs no
user code, so neither of its inputs can have changed, and a post-wait re-check
is a read with no writer.

**The three-readers sentence of the entry below is superseded**, its count kept
and one reader renamed: the word's readers are the failed-allocation waiter's
CAS loop, whose first attempt and whose retries are one reader; the skip rule's
round entry, whose try-take on finding the word held retries in a later round
rather than waiting; and the slot-return path's load. The accelerator's
periodic round and a mutator's allocation failure are two customers, and only
the second ever waits — calling the first "the entry gate's load" is what
produced the contradiction this amends.

**The back door this pins shut.** The gate's inputs are the *thread's own*
state. A collecting flag spelled as a global "a collection is running" bit
would reproduce the rejected reading without naming the token: every trace in
flight would close every allocator's gate. The gate therefore reads the flag in
its per-thread meaning. **Whether the crate's current spelling is thread-local
is unverified** and is an open item; if it is global, giving it a per-thread
reading at the gate is a repair of unmeasured cost.

**Rejected:** the gate loading the token, which re-derives the non-wait clause
Edmond retired on 2026-08-26 — under pressure the thread that most needs memory
would skip the collection that could free it, and every trace in flight would
send every other allocator down the ladder. Also rejected is naming the
try-take's CAS "the entry gate's load", which folds a token access into the gate
and counts one code site as two readers; the try-take is the first iteration of
the waiter's loop. A pre-CAS peek load is not forbidden in implementation but
belongs to that loop and earns no sentence in the design.

**Cost:** none in the machine — no access is added or removed, and the price is
two document edits and this entry. The unfairness named on 2026-08-27 sharpens
in wording: because the gate is blind to the token, an open-gated thread waits
out a trace even when that trace frees nothing on its own heap, bounded by one
mark and scan and unmeasured. The collecting-flag scope check is the one new
obligation.

## 2026-08-27 — the trace token covers the trace alone, and the accelerator hands off by buffer swap

**Decided (Sage), on three failures a Critic round found in the amendments of
S7.5.** The exclusion word of `rc-cycle` is named the **trace token**, it covers
mark and scan and the reading of the live root queues, and its holder releases
it at the end of scan — after the last touch of any shadow row, any met-bitmap
word and any live queue, and **before the exact test of any component**.
Everything after that store runs untokened: the corpse rule, the guards, the
weak-cell nulling, the destructors, the re-verify, the sever, the frees, the
slot returns, the bit clearings. There is one release instant and not one per
form. A code path of a collection that touches a shadow row, a bitmap word or a
live queue after the release store is a defect rather than an ambiguity.

**The release obliges a readership rule, and the rule is what makes it legal.**
Mark and scan are the only readers and writers of the shadow rows and the met
bitmap. The exact test and the teardown's re-verify compute `IN` by iterating a
component's current fields against the component's own member list, in
collection-private memory from the collector's reserve, never through the shared
rows. Without that clause the release instant is a lie, because the rows would
outlive the token that protects them.

**`amSolo` means one trace at a time, and the token alone enforces it.** The
teardown gets no global exclusion and needs none: under the accelerator
concurrent teardowns are the ordinary state already, and a second trace crossing
blocks whose occupants are mid-teardown reads guards, nulled slots and parked
corpses — staleness, which the law prices at zero, a dirty pass adding suspicion
and reducing nothing. The in-line form is made to match the accelerated one
rather than to differ from it.

**The two parkings are re-scoped.** The between-collections parking — a slot
withheld while a queue entry names it — is untouched. The in-collection parking
becomes an **in-trace** parking: a thread's frees park while the token is held
by any thread but itself and return when that thread next observes the token
free, which is one load on the slot-return path. No finer per-thread flag is
invented, because a trace's closure crosses heap partitions and the holder
cannot know in advance whose blocks it will touch. `used` therefore falls at the
token's release rather than at the collection's end, so a block may return to
the pool while a teardown still runs — correct, because the rows it could have
collided with are dead by then.

**The handshake is deleted design-wide, and the accelerator hands off by buffer
swap.** The Y14 amendment of 2026-08-26 deleted it only from the in-line form,
while `questions.md` Y5 and `rc-cycle.md`, "What it keeps from `rc-walk`", kept
it alive with no protocol behind it — and any acknowledged rendezvous that
survived would revive the deadlock the retired non-wait clause named, a
collection parked on an acknowledgement that rides the waiter's checkpoint.
Instead the token holder **swaps** a thread's live queue buffer for a spare and
traces the detached buffer, marking entries; at the release it posts the marked
buffer to a per-thread inbox of capacity one, and the owner reads it at its own
checkpoint. Nothing waits on the pickup. The owner re-enqueues what stays
enrolled, which it may do as its queue's one writer, and Y12 clause 2 stays true
under the new release point: the single reader of the *live* queue is the token
holder, and the owner judges only from a detached buffer it alone holds. The
wait graph then has one edge kind — waiter on token — and no cycle.

**The skip rule's subject was never the token.** A collector that finds the
token held retries in a later round, naming no thread; a collector that finds a
thread's inbox unconsumed skips that thread for this round. Candidates keep
their bits, so both skips cost nothing.

**The word carries one bit.** Free or held, entered by CAS from free, released
by one store with release ordering: no holder identity, no holder kind, no
thread-local held flag. The three-state form dissolves because no reader needs
the owner-or-collector distinction, and the identity dissolves because a waiter
can no longer be the holder. **The entry gate is checked before any wait** —
the crate's existing collecting flag and `TEARDOWN_DEPTH`, unchanged — and a
thread whose gate is closed goes down the ladder rather than waiting, since it
could not collect on taking the token anyway. Gate before wait makes self-wait
structurally impossible: a trace runs no user code and draws its working memory
through the reserve door, so no allocation site executes on a thread while that
thread's trace holds the token. The word has three readers: the waiter's CAS
loop, the entry gate's load, and the slot-return path's load.

**One name.** `rc-cycle.md`'s "claim" and Y12 clause 2's "collection token" both
become **trace token**, the name being normative because it teaches the
coverage. Y9's `claimCell` is untouched, being YRC's own name in quotation.

**Rejected, so none of it is proposed again:** the token spanning the whole
collection, which puts arbitrary user code under a word other threads wait on;
a second word serializing teardowns, which reintroduces the same deadlock one
level down; a holder thread id in the word, for which no reader exists once
release precedes user code and the gate precedes the wait; the thread-local held
flag, whose one case is unreachable; the three-state word, the holder-kind
distinction having no customer; a cursor by which an owner reads its live queue
during judgement, which breaks clause 2 the moment judgement runs outside the
token; and abort-flag preemption, refused by Edmond on 2026-08-26 — this ruling
is what makes the waiting he chose terminate.

**Costs.** The exact test and the re-verify carry a private per-component member
set, sized by the component and drawn from the reserve — unmeasured. Every
thread parks its frees during any trace rather than only during a trace over its
own blocks, a wider floating-garbage window bounded by one trace; a thread
seeing back-to-back traces with no observable gap defers its returns across them
— unmeasured, presumed pathological. Waiting terminates but is not fair, and
whether a ticket is needed is a measurement rather than a design change. The
one-load parking protocol has a boundary race — a slot return in flight at the
instant the token is taken — whose worst outcome under the law is lost precision
and not a wrong free; proving that is now the **first obligation of the
verification debt**, whose TLC model must run a trace concurrently with an
owner's teardown and with a racing slot return. And Y12 clause 3's open
question, who allocates the spare buffer and how it is replenished, becomes
load-bearing for the in-line form too and is on the critical path.

**What it supersedes:** the held-flag clause of the 2026-08-26 four-rulings
entry, and that entry's claim that the amendment "deleted the handshake", which
overreached — the amendment deleted it from the in-line form only.

## 2026-08-27 — the twelfth ruling's document half is reversed for all three bodies of text

**Decided:** the twelfth ruling of 2026-08-25 — code is deleted and documents
stay the record — no longer holds for `rc-walk`, `rc-trace` or the GC horizon.
Edmond's ruling of 2026-08-26 sent all three out of the working tree in code and
in documents, and sent them out first rather than one piece at a time behind
each replacement. `archive/pre-rc-cycle` carries the deleted text in both
repositories.
**Why:** a superseded mechanism left in the tree is read as the design in force,
by a person or by an agent, which costs more than the record is worth. The entry
of 2026-08-25 (sixteenth) withdrew the document half for `rc-walk`'s documents
and the horizon; the deletion of 2026-08-26 took `rc-trace`'s and `rc-satb`'s as
well, and no entry says so, so a reader who finds the twelfth entry reads it as
in force for those.
**Rejected:** leaving the twelfth entry to be read against the two later ones,
which name `rc-walk` and the horizon and answer nothing about the other two.
**Cost:** the twelfth ruling's own cost clause goes with its document half — the
pieces did not go one by one behind their replacements, so `ll-model` carries no
cycle collector at all from the deletion until `rc-cycle` is built.

## 2026-08-26 — generated code touches bytes 4–5 of the header and nothing else

**Decided:** the C mirror in [lowering.md](../model/lowering.md) declares the
flags word as `_Atomic uint16_t flags` at +4, `_Atomic uint8_t collector` at
+6 and a reserved byte at +7. It stays one 32-bit word and
[classes.md](../model/classes.md) keeps numbering its bits as one; what the
declaration fixes is the width a consumer may access.
**Why:** the collector writes byte 6 a byte at a time, so a 32-bit access at
+4 overlaps that store without covering it. That is a mixed-size atomic
access, undefined in the C and the Rust memory model alike, and a consumer
transcribing `_Atomic uint32_t flags` would emit exactly it — the mirror is
what a compiler copies, so the width has to be in the declaration rather than
in prose beside it. Every mask a mutator tests is below bit 16, which is what
makes the narrow access lossless.
**Rejected:** leaving the mirror at 32 bits and stating the rule in the text.
A comment does not survive transcription; a type does.
**Cost:** `ll_release`'s sketch loses its `is_gcheap_object` /
`ll_buffer_cycle_root` pair, which named `rc-trace`'s candidate buffer and had
outlived it. It reads the enrolment gate now, `flags & 0x723`.

## 2026-08-26 — the ring-closing reserve is widened to codes 0–7

**Decided:** entity kinds are `Object 0, Lazy 1, Array 2, Reference 3, String 8,
StringDynamic 9, Box 10, WeakRef 11`. Codes 0–7 are held for kinds that can
close a ring and 4–7 of them stand free; 12–15 are free for kinds that cannot.
"Closes a cycle" becomes `flags & 0b100000 == 0`, "is a string" becomes
`flags & 0b111000 == 0b100000`, and the enrolment gate becomes
`flags & 0x723 == 0`.
**Why:** the assignment ruled earlier the same day held codes 0–3 for
ring-closing kinds and gave all four of them away, so the reserve reserved
nothing: a fifth such kind — a closure entity, and 179 of the corpus's 381
objects are closures — would have taken code 8 and been refused by the mask
permanently, with no test and no build failure, which is the miss
[Y6](../model/gc/cycle/questions.md) exists to prevent. The ring test also
narrows from two bits to one.
**Rejected:** moving Array and Reference to 4–5 to leave room inside the
class-word prefix 0–1. An entity carrying a class word at +8 tears down through
`dispose` and traces through `traced_runs`, so a new one of those needs no kind
of its own — it is an Object.
**Cost:** the code assignment recorded on the same day is superseded and the
crate's `EntityKind` is renumbered a second time before any of it shipped.
Nothing in [lowering.md](../model/lowering.md) moves — its C mirror names bit
positions and no kind codes — and no consumer exists to transcribe the codes.

## 2026-08-26 — the collector proposes a shortlist, and every reduction of state belongs to the owner's exact reading

**Decided:** the trace produces suspects, not verdicts; the exact judgement on
the owning thread decides, and clearing an enrolment bit, dropping a queue entry
or returning a slot may happen only there.
**Why:** garbage is monotone — a ring whose every referrer is inside itself
cannot be reached from outside — so the mutator cannot overturn "garbage"; only
a wrong trace can, and the one source of error is local references whose pairs
the compiler elided, which the counts do not see and the owner's stack does.
**Rejected:** letting a dirty pass acquit. Ring A↔B with an external X→B: the
trace reads `RC(B)=2`, subtracts the internal edge, acquits; X then releases B
without re-enrolment, the ring dies whole, and a cleared bit means no decrement
ever comes again.
**Cost:** none in the in-line form; in the accelerated form the owner pays for a
noisy list, which makes trace precision a cost rather than a correctness
property.

## 2026-08-26 — a collection run in-line on the owner is the exact form, and a collector thread is an accelerator

**Decided:** run from the mutator, the algorithm's judgement is valid outright —
no verdict list, no handshake, no second phase. A mutator that cannot allocate
while a collector thread holds the claim waits rather than preempting.
**Why:** the owning thread sees its own stack and changes the counts it reads,
so the snapshot is consistent by construction. Waiting is safe because the claim
covers the trace alone; the exact judgements are the owners' own, at their own
checkpoints.
**Rejected:** preemption by an abort flag — cheap, since mark and scan write
nothing to the heap, but Edmond ruled for waiting.
**Cost:** the trace's duration bounds the stall of a thread under memory
pressure. Coroutines yielding inside a destructor are out of scope by the same
day's ruling — recorded, not designed.

## 2026-08-26 — the shadow count is found by arithmetic from the address, and leaves the header entirely

**Decided:** one row per slot in a per-block array, block by mask and slot by
`(off - LINE_SIZE) * recip >> 32`; the collector's triple sits in the free tail
of the block's header line, past the 192 bytes `HeapBlockHeader` occupies.
**Why:** measured 2.6 ns a lookup against 10.4 for a pointer-keyed hash with a
displacement hint in the entity header, and 717 MiB against 2.0–4.0 GiB on a
12 GiB heap — the hash's upper figure being its doubling when 94 M rows land
just past load 0.7.
**Rejected:** the hash and its six header bits; and the eleven-bit index of Y4,
which bounded the collection at 2047.
**Cost:** the formula does not cover every GC-heap population — see the next
entry.

## 2026-08-26 — the trace dispatches on the block's kind, and the retained-block index outlives rc-walk

**Decided:** ordinary entity block by arithmetic; retained blocks by binary
search over the occupancy index; a large entity's row in its own block header;
arena blocks never entered, their occupants read as external live references.
**Why:** retained blocks are former arena blocks filled by a bump allocator —
mixed sizes, no stride, nothing to divide by. The dispatch is free: the trace
holds the block header before it can reach any row.
**Rejected:** not tracing retained blocks at all, which would reinstate the
limit `rc-walk` removed in August — a ring living wholly among promoted
survivors would never be collected.
**Cost:** `memory/retained.rs` is excluded from the deletion of `rc-walk`, and
the retained path does not have the arithmetic path's measured cost.

## 2026-08-26 — the shadow rows are not zeroed greedily; the met flag moves to a group bitmap

**Decided:** one bit per group of eight slots is zeroed instead of the rows, and
a group's rows are initialised at its first touch. The row becomes two bits of
colour and thirty of working count, saturating as "conservatively live".
**Why:** a zero row means "not met", so a per-slot array would arrive zeroed for
every slot of a touched block. Measured for the 717 MiB case: 41–76 ms to zero
mapped memory, 178–196 ms from fresh — asked for on the path where an
allocation has already failed. The bitmap costs 1.4 ms, and untouched pages are
never materialised.
**Rejected:** the chunked form as the cure. On a full trace it writes more than
the flat array — 762 MiB against 717 — since every chunk is zeroed too; it stays
the alternative for a traced density below 29 %.
**Cost:** one load of the bitmap word before the row can be trusted.

## 2026-08-26 — the flags word is re-laid for one collector, and the entity kinds are renumbered

**Decided:** category 0–1, kind **2–5**, COW 6, arena mark 7, acyclic 8, owned 9,
enrolled 10, escapee 11, weak 12, pending 13, ran 14, free 15, epoch 16–17, age
18–19, collector reserve 20–23, byte 3 free. Kinds become `Object 0, Lazy 1,
Array 2, Reference 3, String 4, StringDynamic 5, Box 6, WeakRef 7`, and
`STRING_OUT_OF_LINE` becomes kind code 5, meaning **bytes outside the body,
whatever the reason**.
**Why:** with one collector the word has no truce to keep. The order makes three
predicates mask tests — closes a cycle, carries a class at +8, is a string — and
folds the enrolment gate into one `flags & 0x733 == 0` over five conditions.
**Rejected:** kind at bits 0–3. The category's value is read by more surviving
sites than the kind's, and a mask test is position-free, so position 0 goes to
the category.
**Cost:** this reopens the renumbering refused on 2026-08-07 and confirmed on
2026-08-13. It rides along because the field is being rebuilt anyway; the
candidate gate alone would still not justify it.

## 2026-08-26 — an entity that dies while enrolled parks its slot, and the owner un-parks it

**Decided:** death runs in full at once — weak cells, destructor, children — and
only the slot is withheld while a queue entry names it. A dirty reader may mark
the entry a corpse; clearing the bit and returning the slot are the owner's.
Two parkings: one between collections, one inside a collection; `used` falls at
the return, not at the parking.
**Why:** the candidate index that allowed a queue entry to be withdrawn dies
with `rc-trace`. `ll_release` publishes the zero before the death path begins,
so a reader acting on it could hand a slot back out under a running destructor;
and a slot reused inside a collection would inherit the dead occupant's row.
**Rejected:** keeping an index in the header so entries can be withdrawn —
seventeen bits, permanently.
**Cost:** parked memory bounded by the queue's length until the next collection,
which memory pressure itself triggers.

## 2026-08-26 — both old collectors are deleted whole rather than bannered, and the old state is a branch

**Decided:** `rc-walk`, `rc-trace` and the GC horizon leave the working tree in
code and in documents before `rc-cycle` is written; `archive/pre-rc-cycle`
carries the old state in both repositories.
**Why:** Edmond's reason is a reader's, not a tidiness one — a superseded
mechanism left in the tree is read as the design in force, by a person or by an
agent.
**Rejected:** keeping `rc-trace` alive until `rc-cycle` passes its tests, which
would have kept a working collector and a live contract to compare against.
**Cost:** the crate has no cycle collector for the duration, and the tests of
both mechanisms go with them — each one classified rather than swept.


## 2026-08-25 (twenty-fourth) — the header carries a hash displacement, not an index, and the slice bound goes with it

**Decided by Edmond**, after the index of the nineteenth entry was measured
against a real closure and failed: the side table is open-addressed and **keyed
by the entity's address**, and the header carries only the displacement from
the home bucket. The home bucket is `hash(ptr) mod size`, computed from a
pointer the tracer already holds with no memory access; the displacement makes
the lookup one probe with no probe loop; the row's key confirms the landing.
**Why the index failed:** eleven bits address 2047 entities, a component's
verdict needs all its members in one slice, and the subgraph reachable from a
*median* candidate root was measured at the entire object population — 381 of
381 on booted Laravel — so the slice had to hold the heap rather than a cycle.
**Why the displacement does not:** a displacement measures the hash's quality,
not the heap's size; six bits is two orders of magnitude of slack at a sane
load factor, and overflowing it is the signal to grow the table. **What leaves
with the index:** the collection tag, whose question the row's key answers
better — it also catches bits invalidated by a rehash — and the
stamp-against-claim mark, which existed only because tag and stamp shared bits.
Six bits come back free. **What cannot leave:** the epoch and the maturation
age, which live between collections and are read before any table exists.
**Rejected:** per-block side arrays addressed by pointer arithmetic — no header
bits at all, but the array is allocated per block and a sparsely touched block
of the smallest size class costs up to 32 KB for one entity. **Cost:** growing
the table invalidates every stored displacement and needs an O(n) rewrite pass,
amortised nothing; and the address is the key, so the heap must stay
non-moving, which it is.

---

## 2026-08-25 (twenty-third) — the collector-side free is withdrawn; only the mutator frees

**Ruled by Edmond**, in the words "if you cannot guarantee it, cancel it": the
ninth entry of this day is withdrawn and `rc-walk`'s ruling 5 stands whole —
the collector judges, and every free and every destructor happens on the
owning thread. **Why neither hole could be closed.** The Phase 4 exact test is
sound because the owning thread holds the entity while it reads its current
fields; a collector on another thread has no such warrant and cannot get one,
since reading a component's counts at a single instant needs the snapshot Y1
refused. And the weak table is per thread, so a collector cannot null the weak
cells naming a dying entity before user code runs, which `rc-walk.md` binds
every design here to do. **Cost: none, in either repository.** `ll-model` never
had a collector-side free — `collector.rs` writes only the epoch stamp and
posts its verdict, and every teardown path is reached from a mutator's
checkpoint — so the withdrawal restores the contract the code already keeps.
The purity ladder does not lapse with it either: its scope is which steps of
the drain a component may skip, and the drain is now wholly the mutator's.
**What it changes is the design's centre of gravity:** Y14's in-line
collection, where judge and owner are one thread, becomes the only shape in
which a collection frees anything.

---

## 2026-08-25 (twenty-second) — the cycle colour leaves the header, and the three bits it frees fund the acyclic gate and the ownership mark

**Noticed by Edmond** reading the layout of the nineteenth entry: the colour is
not needed any more. It is not, and the reason is the same one that moved the
shadow count — once mark and scan compute in the collector's side arrays, the
colour is per-collection state like the working count and belongs beside it.
That frees bits 4-5. **Bit 3 was already dead:** the GC-state field was
declared two bits wide for the CAS handoff of `model/gc/heap-design.md`, a
device for a concurrent marking collector, and the only value any code writes
is `ARENA_RESET_MARK` at bit 2, which is the arena reset's and stays.
**What the three fund**, and both were recorded as unfunded the same morning:
Y10's acyclic gate takes bit 4, and the ownership mark the fourteenth ruling
left open — "an ownership mark in the header once Y7's freed bits are laid out"
— takes bit 5. Both sit in byte 4, the mutator's own, which is where a test on
the release path has to be; an owned entity now costs the same test as an
acyclic one. **Rejected** with them: reading the acyclic property through the
class descriptor, which costs the release path a second cache line, and staying
at `CANDIDATE_KINDS`' entity-kind granularity, which forfeits what Y3 is for.
**Cost:** none; bit 3 is recorded free with no customer invented for it.

---

## 2026-08-25 (twenty-first) — the critical reserve is the allocator's own block, 500 KB a thread, reached through a second door

**Decided by Edmond**, closing the item the thirteenth entry opened and the
BACKLOG carried unwritten: the memory manager takes a block from the operating
system at thread start and holds it, and work that must not fail is served from
it. **It belongs to the allocator rather than beside it** — the same allocator
has two doors, the ordinary one that refuses when it has nothing and the
critical one that serves from the held block — which is what makes "ask the
allocator after it refused" coherent instead of contradictory. **Per thread,
not process-global**, because two of its three customers are per-thread and
concurrent (the enrolment queue's growth, the mutator that finds the collection
token taken) while the third is exclusive by construction, one collection
existing at a time, so the collecting thread's own zone funds it and a second
residence buys nothing. **Rejected:** a process-global zone beside the
allocator, and a per-thread copy of the collector's working room, which would
be one live copy and N − 1 idle. **Cost:** 500 KB is a starting figure and not
a measurement; only the collector's share is derivable, at about 32 KB from
Y7's slice bound, and the queue's share is a rate against a duration nobody has
measured. `model/memory/critical-reserve.md`.

---

## 2026-08-25 (twentieth) — the crossover figure was wrong at both ends, and the corrected one is a lower bound

**Found by re-reading the source both figures cite.** The fifth entry and
`model/gc/rc-cycle.md` put a walked entity at "about 140 ns an epoch" and the
crossover at "around 360 non-final decrements per live entity per epoch",
citing `ll-model` `dev/BENCHMARKS.md` of 2026-08-16. That file contains no 140
and never did: its epoch probe reports 32–41 ns per entity for singletons and
72–108 ns for the chain. The 0.4 ns at the other end is real but mislabelled —
it is the instrument's floor, "a difference under ≈ 0.4 ns between ll-shaped
arms is unresolved on this instrument", so it bounds the candidate cost from
above and measures nothing. **Corrected:** dividing the measured walk cost by
that upper bound gives the smallest crossover the evidence permits — at least
80 decrements per live entity per epoch for the singleton shape, at least 180
for the chain — and the true crossover is higher by however far the candidate
cost sits below the floor. **What survives:** the argument, since no ordinary
program approaches 80 either. **Cost:** none to the design; the entry exists
because a number was carried for four months that its cited source does not
hold, and the fifth entry stands unedited with this one superseding it.

---

## 2026-08-25 (nineteenth) — the epoch tag is two bits, and the shadow count leaves the heap

**Decided by Edmond:** two bits are enough for the epoch. That closes Y7's
layout, because sixteen bits — header bytes 6 and 7, flags 16-31, one aligned
two-byte atomic store — then divide as epoch 2, maturation age 2 (YRC's promote
bound of three fits exactly), stamp-against-claim 1, and eleven left over.
**What the eleven carry is an index, not a count:** `CRC` is a full `u32` and
cannot share sixteen bits with three other fields, so the shadow counts move
into the collector's side arrays and the header carries only the index into
them. **Why that is better than a field and not merely smaller:** mark and scan
then write nothing into the heap, so Y4's reason for a shadow — never leaving a
count torn where a destructor could see it — is met by construction, and an
aborted collection costs zero heap writes. It is not a hash, either: the index
rides in the word the tracer already loaded. **Rejected:** growing the header,
which the eleventh ruling forbids and which would tax every entity for a field
only candidates use. **Cost:** eleven bits bound a collection slice at 2047
entities, a component larger than the slice needs the paper's overflow table,
and a two-bit tag wraps — the collector clears a non-current stamp on first
contact, which it is touching the entity to trace anyway. Node Y7.

---

## 2026-08-25 (eighteenth) — the class filter needs a declared type per slot, and the form available today demotes nothing

**Measured, and it refutes Y3's premise.** The demotion rule Edmond named — a
class whose declared slots cannot hold a ring-closing kind leaves the candidate
set — cannot be evaluated against `SlotKind`: its `Pointer` variant covers a
declared class type, a `string` and an `array` in one code, and `PropSlot`
carries no target. The gap is this repository's, not the crate's: `classes.md`
collapses the three the same way and its `prop_layout` enumeration carries no
declared type either. **What is evaluable demotes nothing:** the only predicate
the descriptor supports is "holds no counted reference at all", and on booted
Laravel plus one request no class with a live instance passes it — 0 of 114
classes, 0 of 381 objects; statically 94 of 5680, two thirds test tooling, and
the application's own code none of 49. **Decided:** the filter is worth having
only in the form the ruling names, so `classes.md` gains a declared target per
pointer slot — a class/string/array tag, and for the class case a link-time id
— before `src/class.rs` does. **Cost:** the descriptor grows, and S6.3 turns
out to owe a change to the class design rather than a rule against the existing
one. The corpus instrument cannot report this share either; the figures come
from a separate script cross-checked against it on the walk.

---

## 2026-08-25 (seventeenth) — the named SPSC queue does not meet the enrolment contract, and the tenth entry's premise falls with it

**Found by reading `Zend/zend_spsc_queue.{c,h}` first-hand**, which the tenth
entry named as "already built" on the strength of its own top comment. The
comment is wrong on three of four claims: no `fetch_add` is executed anywhere,
the reader performs no CAS and has no batch operation at all, and the first
overflow allocates a second buffer at the same capacity rather than doubling.
**Three properties refuse the contract outright:** growth drops the root when
its allocation fails, which is Y6's permanent miss; growth runs on the
mutator's own thread inside a mutex and may `memcpy` the whole buffer, landing
a futex and a `malloc` inside a non-final decrement; and the read side admits
one reader only, crashing in five runs out of five with two, which is precisely
the case Y14 creates when the mutator drains its own queue. **What survives:**
the shape — one queue per thread, one writer, one reader at a time — and the
contract now written at Y12 says what such a queue owes. **Cost:** the
enrolment queue is written rather than adopted, and clause 3 leaves open who
allocates the spare buffer that keeps the overflow path off the allocator.

---

## 2026-08-25 (sixteenth) — the `rc-walk` documents and the GC horizon are deleted too, not kept as records

**Decided by Edmond:** when `rc-cycle` is finished, `rc-walk`'s documents leave
the repository with its code, and the GC horizon documents go with them. **What
it reverses:** the twelfth entry of the same day, which deleted code and kept
documents — "the capture-count precedent holds for documents, which stay the
record, and not for code". That reading is withdrawn for these two bodies of
text. **Why the horizon goes at all:** its proof logic left this repository's
scope on 2026-08-23 and it has been a bannered record since, so nothing in force
cites it as an obligation. **Cost:** three things outlive their documents and
move first — the chain rule, already in `model/memory/static-lifetimes.md`; the
count-elision bargain that Y11 and the fourteenth entry both cite; and the TLC
battery's verification debt, which does not lapse with `dev/tools/rc-walk/`.
Stage S7 of `dev/PLAN.md` carries the work and starts only after the build.

---

## 2026-08-25 (fifteenth) — a mutator short of memory runs the collection itself, while no collector runs elsewhere

**Decided by Edmond:** under memory pressure the collection starts on the
mutator's own thread, and only while no collector is running on another thread.
**What runs is the synchronous form on this thread's own roots**, which is what
makes it safe: it opens no deferral window, so what it frees is recyclable at
once rather than parked; it needs no handshake, the judging thread being the
owner; and it crosses no threads, as `rc-walk`'s ladder already requires.
**Why the condition is soundness rather than policy:** trial deletion runs on
the shadow count `CRC`, the scratch of one collector, so two concurrent
collections read each other's decrements — `rc-walk`, whose counts are real,
needed no such rule. **Rejected:** a mutator that waits for the token, since the
running collection may be waiting for that same thread's handshake
acknowledgement; and firing at a failed enrolment, which happens inside
`ll_release` mid-mutation, where the arm/fire rule forbids collecting on
correctness grounds. **This narrows the tenth entry rather than reversing it:**
the writer still never drains at the enrolment. **Cost:** the collector's
working memory must be sized in advance and drawn from the reserve, because the
free path allocates today (`ll-model` finding 4,
`dev/RC_WALK_CRITICAL_REVIEW.md`) in a `panic = "abort"` profile. Node Y14.

---

## 2026-08-25 (fourteenth) — a proven-owned entity never enters the roots

**Decided by Edmond:** an entity whose ownership is proven never enters the
candidate set — no decrement of it enrols while the ownership holds. **Why
it is sound:** the owning edge's own release is the enrolling one, so
enrolment is deferred to the owner, not lost — Y11's covering claim raised
from a single release site to a standing property of the entity. **And it is one more elidable `−1`**, Edmond's addendum: the same ownership
proof that skips enrolment licenses eliding the counting pair itself at the
proven sites — the bargain `gc-horizon.md`'s count elisions struck, now
available to `rc-cycle`. **Cost:** how the release path knows is open — the
compiler's plain form at every site it proves, or an ownership mark in the
header once Y7's freed bits are laid out; node Y11 carries the contract.

---

## 2026-08-25 (thirteenth) — root-queue growth under OOM draws on the reserved area, and the mode holds until the roots are walked

**Decided by Edmond**, closing the boundary the tenth entry left unpriced:
when the root queue's growth allocation fails, the enrolment does not drop —
it draws on a **reserved critical memory area** the runtime keeps for exactly
such must-not-fail work, and the runtime does not return to normal mode until
every queued root has been walked, which is what refills the reserve's
headroom. This overrides `runtime/exceptions.md`'s drop-as-known-leak licence
for candidate roots. **Cost:** the reserved area itself is recorded nowhere —
this entry is its first written trace; its size, residence and other
customers are an open item for the memory documents.

---

## 2026-08-25 (twelfth) — `rc-walk` code is deleted as `rc-cycle` replaces it

**Decided by Edmond** (map round): everything `rc-cycle` makes unneeded is
deleted from `ll-model`, not kept under a banner. The capture-count precedent
— refused, kept as a record — holds for documents only; they stay the record.
**Rejected:** the fifth entry's reading that nothing is deleted, argued on the
day the design was named, before any replacement existed. **Cost:** each
deletion waits for its replacement to land, so the pieces go one by one.

---

## 2026-08-25 (eleventh) — maturation is an age in the epoch stamp; the header does not grow

**Decided by Edmond** (map round): candidate maturation is carried as an age
inside a collection-epoch stamp in the entity header, YRC's device, not as
Levanoni–Petrank's carousel of `k + 1` rotating buffers; and the header gains
no second word and no extra byte — the stamp is first tried in `rc-walk`'s
existing epoch byte, and the seventeen-bit candidate index is dropped because
a buffered entity is found through its root-queue entry. **Why:** the age
rides a write the commit makes anyway, and the freed index bits are what made
unique ownership `rc-walk`-only. **Cost:** the bit layout under the one-store
discipline is open, node Y7.

---

## 2026-08-25 (tenth) — enrolment never drops a root; the queue is the grown SPSC, not YRC's stripes

**Decided by Edmond** (map round): a full candidate buffer never discards the
enrolment — the buffer grows. The queue candidate is the double-buffered SPSC
handoff queue already built in the `spsc-refactor` tree
(`Zend/zend_spsc_queue.{c,h}`); its header claims a `fetch_add`-only writer,
a two-CAS-per-batch reader and a doubling buffer, figures S6.4 verifies
against the code — the header's own pointer to a specification is dead.
**Rejected:** dropping the root on overflow — a dropped enrolment is a cycle
no later collection finds (Y6); and YRC's striped queues — fixed 256-slot
stripes whose writer drains them himself on overflow. **Cost:** one queue per
thread and the read-side ownership are undesigned, node Y12; and the ruling
priced the full buffer, not the growth allocation failing under OOM, where
`runtime/exceptions.md` licenses dropping the root — that boundary is
Edmond's, not yet asked.

---

## 2026-08-25 (ninth) — the collector frees, but runs only pure destructors

**Decided by Edmond** (map round): under `rc-cycle` both the mutator and the
collector may free; the collector itself may run only a destructor proven
pure, or tear down an entity with no destructor, and an impure destructor
runs on the owning thread. The full-heap walk leaves the design with the
same ruling: the collection traces from the candidate set alone. **Why:**
this keeps user code off the collector thread while letting the common case
— no destructor, or a pure one — die where it is judged. **Cost:** narrows
`rc-walk`'s ruling 5 (the collector judges, only the mutator frees), whose
handshake machinery survives for exactly the impure remainder.

---

## 2026-08-25 (eighth) — the enrolment gate is proven acyclicity; purity has no bearing

**Decided by Edmond** (map round): a decrement that does not reach zero
enrols the entity unless it is provably acyclic — the only exclusion. His
earlier "pure object" clause is withdrawn: a pure destructor says nothing
about the references the entity holds. The compiler's plain (non-enrolling)
release is licensed at exactly two kinds of site: the entity is provably
acyclic, or it provably cannot die there — held by a reference whose own
later release will be the enrolling one. A runtime that proves a class
cyclic may stamp it with a flag; the flag only strengthens suspicion and
feeds traversal aggression (Y13), never demotes. **Rejected:** "someone
still holds it after the decrement" as a licence — the holder may lie in
the same ring.

---

## 2026-08-25 (seventh) — the destructor runs when death is established

**Decided by Edmond** (map round), closing the sixth entry's open bound: the
destructor is called as soon as the death is known — at a zero count
immediately, as today; for a cyclic component, at the collection that
confirms it dead. The call is decoupled from the memory: the arena holds the
block until its reset either way, and cyclic garbage no collection reached
is caught by the reset's own destructor pass (`model/memory/arena-reset.md`,
step 1). **Cost:** none new — the pass already exists. The order of two
collection-time destructors is not promised anywhere.

---

## 2026-08-25 (sixth) — `__destruct` may run later than the count reaching zero

**Ruled by Edmond**, and he has ruled it before: PHP's destructor is **not**
promised at the instant the refcount reaches zero. It may run later. No
document in this repository carried the ruling, which is why it kept being
re-derived from `rc-walk.md`'s own text; it is written here so it stops.

**What it permits.** A design may defer a destructor past the last release —
to a collection, to a checkpoint, to a batch — without breaking a promise this
language makes. Deferred or coalesced reference counting is therefore **not**
disqualified by destructor timing, and neither is a collector that reclaims at
trace time.

**What it does not say.** It states no bound, and none is written anywhere:
how much later, whether within the request, whether before the arena reset
that would free the memory anyway, whether ordering between two destructors
is kept. Those are open and are node Y2's.

**What it costs the day's work.** The refusal of Levanoni and Petrank's
sliding views rested on three legs and loses one: the barrier is still the
snapshot, and the algorithm still suspends threads and scans their stacks, but
"its counts are reconstructed at a collection, so no instant exists at which
the last reference was dropped" is no longer an objection. The same removes
the objection to Nim's YRC, whose deferred decrements are what make its
verdict free.

---

## 2026-08-25 (fifth) — the design of record is `rc-cycle`; `rc-walk` and the rest become records

**Decided by Edmond:** the next collector is on-the-fly cycle collection over
a **sliding view** — Bacon–Rajan's candidate set from the mutator, Levanoni
and Petrank's coalescing log in place of the heap census, and a per-class
filter over which classes may hold a cycle. He named it `rc-cycle`. Work is
built on its question graph, `model/gc/cycle/questions.md`, as stage S5 was
built on the walk's.

**Why:** the walk's cost is the heap's and its yield is the cycle's. Every
epoch reads every slot of every entity block and builds the graph of the
whole mature population, whether or not anything changed, and a collector
exists only for cycles. The candidate set the mutator can name is measured at
about **0.4 ns** on a retain-and-release pair that does not reach zero
(`ll-model` `dev/BENCHMARKS.md`, 2026-08-16, an upper bound), against about
**140 ns** an entity an epoch for a row and its edges — a crossover near 360
non-final decrements per live entity per epoch, which no ordinary program
approaches.

**What "superseded" does not mean.** `rc-walk` is the built default and
`rc-cycle` is not a line of code, so nothing is deleted and no code moves.
`rc-walk.md` stays the text in force for the strategy the crate runs and is
bannered; `walk/` is closed as the record of a finished stage; the registry
gains a row rather than losing four.

**The premise is unverified and the first node says so.** Sliding views are a
write barrier, and `rc-walk` was built on the constraint that the mutator does
no per-operation work for the collector. That is a change of constraint, not
an improvement inside it, and node Y1 holds it.

**Cost, already visible:** every concurrent design surveyed on 2026-08-25 —
Nim's YRC, `scheme-rs`, Samsara, CIRC — defers a destructor to collection
time for cycle-capable types, keeping prompt release only where a class is
proven acyclic. Whether PHP's `__destruct` may weaken that far is node Y2 and
is Edmond's.

---

## 2026-08-25 (fourth) — the drain's resumption is a flat state machine, not a fiber

**Decided by Edmond:** where the paused drain's state lives is the coroutine
shape without a separate stack — a heap frame across the suspension, an
ordinary return to suspend, which is the cursor generated rather than written
by hand. The real-stack form is refused for this path.

**Why:** suspension from arbitrary depth is the freedom the two Sage verdicts
and the step-8 ruling spent three sittings narrowing, and a fiber makes every
point representable again. Its four prices are unpaid beside that: a parked
stack per outstanding drain inside the window whose defect is retained
memory; a pinning to the thread that the drain's race-freedom forces, which
node E1 has not settled; a destructor free to suspend on its own I/O and hold
the epoch open with the guards on; and a context switch Miri cannot execute,
on the most invariant-dense path in the system.

**What it buys:** `sever_cells` walks an entity's cells through a callback
that no hand-written cursor can re-enter, and a state machine can.

**Cost:** in Rust a stackless coroutine colours every frame of the chain, so
the five sever helpers are rewritten either way; what changes is that the six
cursor fields stop being written by hand. And the shape decides nothing about
*when* to suspend — the ceiling's mechanism, the slice's outer boundary
against the pickup loop, and the ack that must not fire on a suspended drain
all stay open (node D3).

---

## 2026-08-25 (third) — the drain may stop inside step 8, between two external drops

**Decided by Edmond:** the release of a confirmed component's external
children admits a boundary. The mutator may return to program code between
two `drop_ref` calls of step 8, as it may between two cells of the sever.

**Why it was asked:** the ceiling as chosen bounded step 6 and left step 8
whole, and on the commonest shape — an array of objects — every cell is
external, so the whole release cost lands in step 8 and a split sever bounds
the cheap half alone.

**What licenses it:** the warrant's second clause. A child reached in step 8
has lost its in-edge and its count is held by the displaced vector, so the
synchronous collection reads `RC − IN` as risen and treats it as a root;
`DrainPause.tla`'s configuration that opens this seam exhausts clean. The
earlier refusal rested on `unguard` running once, which is a property of
step 7 and not of step 8.

**Cost:** the resumption cursor gains an index into the external children
beside the sever's, and the epoch stays open across the pause — every
thread's parked memory with it, which is node D8's quantity.

**Unchanged:** the seam between the last severed cell and `unguard` stays
refused, and steps 6 and 7 still admit no boundary between them.

---

## 2026-08-25 (second) — the charged budget is withdrawn; the ceiling's shape is open

**Decided:** the batch ceiling has no chosen mechanism. The entry below and
the one under it are both records: a charge debited at the measured price
bounds a count of units rather than a length of time, and a charge debited at
a conservative price does not bound the pause either.

**Why the conservative price fails too:** a severed cell's unit contains a
`displaced.push`, whose regrowth the probe reserves outside the timer, so a
vector doubling lands hundreds of microseconds on one cell no price can carry;
the safety factor is paid in slices, each returning to program code, which
multiplies the span in which every other thread's checkpoint takes the cold
branch and no thread flushes parked memory; and the two clock reads have no
consumer that does not relax the price back to the measured one.

**The standing candidate:** read the clock every K units rather than per unit
or never. At K = 512 on the cheapest unit the read is about one per cent, the
overrun is at most K units of whatever the shape really costs, and no price
table or calibration is needed. The earlier rejection was of K = 1.

**What has to be settled before any shape:** the slice's outer boundary and
the budget's reset against a pickup that drains every queued message in one
loop, and a boundary inside the release pass, which is where the commonest
shape's cost lands.

**Cost:** ruling 3 stands and its enforcement does not exist. Node D3 carries
what would answer it; nothing is built either way.

---

## 2026-08-25 — the charged budget debits a conservative price, not the measured one

**Decided:** the ceiling's register is debited with a per-unit **ceiling**
price rather than with the measured one, and the clock is read twice a slice —
at its resume and at its yield. This narrows the entry below, which stands as
the record of the shape.

**Why:** the measured prices are floors, and a floor bounds a count of units
rather than a length of time: the slice then lasts one budget times the ratio
of the true price to the charged one, which is the number the same entry lists
as unmeasured. "The error is capped at one slice" is circular where the slice
is defined by the charge in error. The rejected bare count of cells was wrong
by a measured factor of five in the *safe* direction; the charge as first
written is wrong by an unmeasured factor in the unsafe one. A conservative
price ends the slice early, which is a bound, and pays in throughput on
friendly shapes — which is what a latency mechanism spends.

**Why two reads:** between two slice boundaries lies the program code the
pause exists to permit, so a boundary-to-boundary difference is mostly program
time and reconciles nothing. Resume-to-yield is the interval that means
something.

**Rejected:** charging the measured price with the sign argued safe. Two of
the three figures are floors by their source and the third, the released
child, is the arm the probe scattered; all three are differences against
controls that had already paid the memory traffic, so a conservative price has
to put the miss back and none of the three is it.

**Cost:** the conservative price is unmeasured, so the mechanism owes one
measurement before it can be built — the true cost of a released child and of
a teardown under a scattered component. Node D3.

---

## 2026-08-24 — the batch ceiling is a charged budget between clock reads, not a check

**Decided:** ruling 3's time ceiling is enforced by debiting each mechanical
unit's measured price against a budget on a register, and reading the clock
only where the drain yields — once per slice boundary — plus once after every
destructor. Step 8 is split on the same budget as the sever, which is the
strategy applied one level down rather than a ruling of its own: Edmond
declined to rule it separately on 2026-08-24, saying the adopted strategy
answers it and naming a clock as an admissible mechanism.

**Why:** a monotonic clock read is 13.2 ns on the reference box, against a
severed cell at 2.3 and a released child at 1.0 (`ll-model`
`dev/BENCHMARKS.md`, 2026-08-24). Checking per cell would cost six times the
work it bounds. One read per slice at a millisecond budget is one part in
seventy-seven thousand, and it reconciles everything charged since the last
read.

**Why a count bounds a pause here and not in ruling 3:** that ruling refused a
count *of entities* because a destructor is user code with no bound. A cell's
mechanical cost is bounded and measured; the destructor keeps a read of its
own.

**Rejected:** a clock read per cell, on the price above; and a bare count of
cells, which assumes a mix and is wrong by a factor of five between an
all-surviving batch at 3.3 ns a cell and an all-dying one at 16.3.

**Open:** where the charged prices are calibrated and how often. Between two
reads nothing corrects them, so the error is bounded by one slice and its size
is unmeasured. Node D3 of `model/gc/walk/questions.md` carries it with the
ceiling's own value.

## 2026-08-23 — what a shared object is inside an actor, and what a moved one is

**Decided (Edmond).** An actor is a virtual thread and the memory manager
already works per thread, which is what makes both forms below work at actor
scope.

**Shared.** When a shared object reaches an actor, the message carries a
**copied pointer**, not the object. The object stays in the other, genuinely
shared memory; the actor reads it by dereferencing and **does not own it** — it
writes no count and can free nothing. In this design's own vocabulary the actor
holds an uncounted reference, the shape `model/gc/gc-horizon-cases/weakref.md`
describes for a cell's `target`.

**Moved.** A move into an actor is possible too. A moved object joins a
**list of moved objects** and is handled exactly as an object moved into
another thread is handled today.

**Why:** the payload table of [../runtime/actors.md](../runtime/actors.md)
described the share form as "immortal and frozen-COW values pass by reference",
and the value model of record carries no frozen-COW class, so the one stated
exception to "nothing enters an actor except through the queue" named something
that does not exist.

**Owed, and not decided here.** What guarantees a shared object's lifetime while
an actor dereferences it — the owner it was created under, or a lease for the
duration — asked and unanswered. How an actor's own collection avoids reading
the copied pointer as one of its own edges: it must be invisible to that walk
the way a weak cell's `target` is, or the exact test balances against memory the
actor does not own. And what the moved-objects list holds, who appends to it and
who clears it: the arena's escapee list with its hold-counts and its promotion
at reset is the analogue this generalizes
([../model/memory/arena-reset.md](../model/memory/arena-reset.md)), and no such
list exists in the crate or in these documents today.

## 2026-08-23 — a weak reference does not cross the actor queue

**Decided (Edmond):** two limits on what a message may carry. An object that
holds a `WeakReference` is not sendable at all — the cell is an entity of its
own, shared by every copy of the handle
([../model/weak-references.md](../model/weak-references.md)), and neither
packing form works on it: a deep copy would leave the copied cell's `target`
pointing into the sender's arena, which the queue exists to prevent, and
sharing is reserved for values with no mutable state. And an object that is
itself the **target** of a weak reference may not be moved: the move is a
pointer handoff, so the entity would leave the sending actor while its
subscription row stays in the sender's table. Move is refused for it and the
send falls back to a deep copy, whose result is a new entity nobody is
subscribed to — the sender's cell keeps naming the original and nulls when the
original dies.

**Why:** the payload discipline is chosen per allocation site
([../runtime/actors.md](../runtime/actors.md)), and weak subscription is not a
property of an allocation site — `WeakReference::create` can run at any later
moment. The enforceable test is per entity at pack time: flag 7,
`HAS_WEAK_REFERENCES` ([../model/classes.md](../model/classes.md)), is already
set on a subscribed entity, so packing reads it and refuses the move. The
holds-a-cell half is statically decidable wherever the class is closed.

**Cost:** a proven-transferable object that gains a subscriber before the send
pays a deep copy instead of a pointer handoff, and the compiler cannot predict
which objects those are, so the cost is unbounded in the static analysis and
bounded per send by the subgraph's size.

**What it does not close:** node E1. Both limits are about the queue, and the
weak table's failing shape is about **migration** — an actor creates a weak
reference while mounted on one thread, migrates between messages, and its
entity dies on another thread whose table holds no row for it. No message
crosses in that shape, so neither limit reaches it.

## 2026-08-23 — one word at the mount; an interior path takes the owner as a parameter

**Decided:** the scheduler installs exactly one word of per-thread runtime
state when it mounts an actor and clears it at unmount — the mounted-context
pointer. Slot 0 is the compiled fast path over the same value, and null stays
the legal no-context state, resolving through it. That word answers **which
actor executes on this thread**, and nothing else. It does not answer which
actor owns a piece of work, so an interior path — the arena reset's destructor
fixpoint, the verdict drain, the synchronous collection, the static-block
teardown — takes the owner it works on as a parameter and presents that
owner's context to any user code it runs. The mount is a fallback only where
the executing actor is the owner by construction, which mutator-path death is,
the queue being the only door.

**Supersedes**, in the first entry of this date, the sentence "Nothing is
installed, swapped or restored when the scheduler mounts an actor": one word
is installed and nothing else. It also strikes three claims the review chain
found in the working design — that the context is the single home of actor
state, that interior paths resolve through the mount, and that the C-standard
allocator surface does. That surface reads no context at all: it dispatches on
the block header and on the thread's heap, with a cross-thread path (`ll-model`
`src/memory/stdapi.rs`), and it stays that way. The second entry's rejection of
a thread-local owner read on the death paths is **reaffirmed**: with the owner
as a parameter those paths carry no thread-local read, which is what that
rejection's ground required.

**Why:** the mounted actor and the owning actor differ on a pool thread. With
actor B mounted, the synchronous collection can run actor A's destructor — it
enumerates process-wide (`ll-model` `src/walk.rs`, `src/memory/heap.rs`) — and
a store inside that destructor logs A's entity on the **mounted** arena's
escapee list (`src/memory/barrier.rs`). The reset that follows retains a block
the owning arena later returns to the pool, which leaves a live promoted entity
in recycled memory and a wild read for every walk after it.

**The convention stays one.** Entity teardown, release and the checkpoint gain
the context parameter, which the first entry's cost paragraph already priced.
An entry without the parameter asserts that it reads thread-owned resources
only and never resolves the mount; those entries are enumerated in one
inventory, so a new one is an edit to that inventory rather than a silent
addition.

**Thread exit needs a context of its own.** `ll_thread_exit` installs one
around the static-block teardown — the single step that runs `__destruct`
bodies, which allocate (`ll-model` `src/static_block.rs`) — and disposes it
before the steps that dispose what its reset touches. Without it the
no-context path panics, and a panic there cannot unwind out of a destructor:
under `panic = "abort"` it ends the process (`ll-model` `Cargo.toml`).

**The context's arena field changes only where the one-mounted-request-arena
premise holds** ([../model/memory/arenas.md](../model/memory/arenas.md)). A
region-shaped field is rejected: the barrier compares a two-bit category and
cannot tell two request arenas apart, and the reset's dirtiness test reads the
resetting arena's cursor while such destructors would move another's. Regions
stay deferred behind the cross-arena design `arenas.md` already names, with one
constraint recorded for it — a region-entering frame has at least four exits:
normal, unwind, a channel-R error return
([../runtime/exceptions.md](../runtime/exceptions.md)), and suspension, for
which this repository has no frame model.

**Rejected:** moving the six per-thread structures — weak table, the
non-default strategy's candidate buffer, the deferred-free park list, the reset
window with its died set, the drain gates, the static-block registry — into the
context. It would decide node E1 by construction and dismantle the explicit
thread-exit disposal order the crate rests on. Also rejected: recording that the
drain "runs while its owner is mounted", since the verdict queue carries no
owner field, so the drain's soundness condition until node D1 is the
single-mutator invariant.

**Open, with owners:** which of the six structures are actor state, and the
epoch duty and re-entry slot a foreign crossing would need — node E1
(../model/gc/walk/questions.md);
the message owner field and pickup routing — node D1; the entry shim for a
callback on a thread this runtime did not create, and a C-callable writer for
the mount word, which does not exist today (`ll-model`
`src/memory/context.rs`); the region design and the suspension frame model, as
above.

## 2026-08-23 — the actor context travels as an argument: context-aware functions

**Decided (Edmond):** a function that works with an actor takes the actor
context as an argument — a **context-aware** function. Nothing is installed,
swapped or restored when the scheduler mounts an actor: no per-thread copy of
actor state exists, so there is no base to re-point and no cache to
invalidate. A function that is not context-aware does not touch actor state
at all, and reaching one is a boundary crossing.

**Supersedes the second half of the entry below**, of the same day, which
served an extension's module globals by re-pointing one pointer at the mount.
That half is unnecessary where an extension is compiled against this
runtime's headers: the macro through which a module reads its globals is ours
and resolves through the context the function already received, so the
extension's source does not change either way. The first half stands — code
this compiler emits carries the context.

**Why:** every alternative buys the same reachability with a worse property. A
swapped base or a reserved register reaches the owner without an argument and
leaves open what happens at a boundary this runtime did not compile. Copied
cells leave two copies of one state, invalidate every address taken inside
them, and need a guaranteed write-back when a message ends in an abort. An
argument in a register is also cheaper to read than a thread-local, so the ABI
change is not a cost to defend.

**Cost:** the runtime's PHP-facing surface changes shape — release, entity
teardown and the epoch checkpoint gain a parameter they do not carry today.
Not measured.

**Open:** entry from code this runtime did not call — a callback from a C
library, a thread that library created — arrives with no context and needs an
entry shim to establish one. And a `static` inside libc or a third-party
shared object is reached by none of this: it needs a declaration from the
module or an actor pinned to a thread.

## 2026-08-23 — per-actor state: the compiler carries the context, the mount swaps one pointer

**Decided (Edmond):** state that must follow an actor is reached two ways,
and which one applies depends on who compiled the code. Code this compiler
emits takes the actor context the way it already takes the allocation
context — in a register, so no path it emits reads a thread-local to find
its owner. Code it does not emit, a C extension reading its module globals,
keeps its source and is served by the scheduler at mount: the pointer
re-pointed is `storage`, the first field of the per-thread TSRM entry, which
the module accessor reads as `(*(void ***) cache)[id]` (php-src `TSRM/TSRM.c`,
`struct _tsrm_tls_entry`; `TSRM/TSRM.h`, `TSRMG_BULK_STATIC`).

**Why:** a function called from an actor executes as the actor and knows
nothing about it, so a `static` inside it makes the actor's state outlive
the message. A process-global one races across threads and is overwritten
across actors on one thread; a thread-local one survives the actor and is
lost when the scheduler moves it. PHP's threaded build already reduced
every extension's globals to one indirection through a per-thread vector,
so re-pointing that indirection makes the ecosystem actor-local without a
line of it changing. CPython met the same problem in the same kind of
ecosystem and answered it by contract rather than by mechanism: module
state in a struct instead of statics (PEP 489), and a module that does not
declare support for several interpreters is refused (PEP 684).

**The pointer is swapped, never the contents.** Copied values leave two
copies and a rule about which is authoritative; one pointer leaves one
copy, in the actor.

**The module's own cache needs no invalidation.** Each shared object holds a
`__thread` copy of the cache pointer, and that pointer names the entry, not
the storage vector; the entry is per-thread and does not move, so a swap of
`storage` under it is invisible to every cached copy. What is not valid
across a change of thread is anything else derived from the old one.

**The swap is legal at a message boundary alone**, which is where the
scheduler mounts.

**One access path the swap does not reach.** The engine's own globals are
resolved by an offset from the entry block rather than through `storage`
(`TSRMG_FAST_BULK_STATIC`), so re-pointing `storage` does not move them.
Limelight has no Zend core and supplies those names from a shim header;
through what indirection the shim defines them is undecided.

**Rejected:** one universal runtime reading the owner from a thread-local
on every path. It puts a dependent load on the death paths, which are the
paths carrying no context, and buys nothing on the paths that already carry
one.

**Open, and not decided here:** how the runtime's own death paths — release,
entity teardown, the epoch checkpoint — reach the owner. They carry no
context today and do not read the extension vector, so neither half of this
decision reaches them
(model/gc/walk/questions.md).

## 2026-08-22 — copy-on-write outranks the unique-ownership proof

**Decided (Edmond):** where a COW-eligible entity is also proved uniquely
owned, COW wins and the count is maintained. The unique-ownership proof
establishes lifetime — one owning slot, death at the overwrite — and
lifetime is not what the separation test asks, so the proof neither
answers it nor licenses removing the count.

**Why:** the separation test reads the count to decide whether a write
copies ([values.md](../model/values.md#refcount-is-always-maintained-on-cow-entities)),
which is value semantics rather than bookkeeping. A count word holding the
occupancy sentinel would answer that test with a constant.

**The other road is a separate instrument.** The compiler may prove COW
itself unnecessary for an entity and **clear the COW flag**, one bit of
`RcHeader.flags`, non-COW arrays and objects already existing
([values.md](../model/values.md#cow-is-a-per-object-flag)). That proof is
explicit and owed on its own terms, and only after it does the entity
leave COW and become eligible for the unique-ownership treatment. Strings
are outside it: there the flag is the layout and is fixed at creation.

**Rejected:** reading `values.md`'s elision licence — "only where it has
proved that no second holder arises" — as discharged by the uniqueness
proof.

**Cost:** a uniquely-owned array keeps today's count and today's
separation check until the COW-clearing proof exists.

## 2026-08-22 — the capture-count regime is refused; the counted walk is the design of record

The second design (`model/gc/gc-horizon-v2/`) stopped counting heap edges
and left the concurrent walk to find them. Two findings closed it.

**Soundness.** A walk reads each entity once, at different times. A
reference moved from an unread entity into an already-read one is invisible
to it, and under the regime no count moves to record the move. With zero
per-store instructions the collector's observations are identical between
"moved and live" and "dropped and garbage" — node M of that folder's
`questions.md`, verified against the text in two review rounds.

**Semantics.** The count is not only a barrier. It frees promptly at zero,
answers the copy-on-write uniqueness test, and carries the arena's escape
hold-count. Removing it from heap edges costs prompt `__destruct` for every
entity held only through the heap, which `model/weak-references.md` already
refused for one map type, and which `model/gc/gc-horizon.md` refused once
before for Form B.

The design of record is `model/gc/walk/`: the counted heap edge stays the
write barrier, the walk stays the cycle collector, and the work moves to
making each cheaper. The rulings that bound it and the open questions are in
`model/gc/walk/questions.md`. `gc-horizon-v2/` is kept as the record of the
refused road; its nodes M and N are the argument and are not re-derived
elsewhere.

## 2026-08-21 — the horizon pays by publishing, and the second design gets its own folder

**Decided (Edmond):** the payment at a GC horizon is a publication the
collector reads, not a `retain`. The second design lives in
`model/gc/gc-horizon-v2/`, which is marked as the current one;
`model/gc/gc-horizon.md` stays in place as the record of the first
design and carries a banner pointing at the folder.

**Why:** the first design keeps the mutator's reference count on every
local that reaches a horizon, because the count is what makes a root
visible — `RC - IN > 0` is the only channel a stack-free collector has.
A publication carries the same fact for less: the epoch byte already
means "do not judge this slot", the mutator already writes it once per
entity at allocation, and the walk clears it by ageing, so nothing has
to be retracted. With publication available, a class of entities needs
no mutator-maintained count at all.

**Rejected:** a sticky local-root bit with a canonical owner, which the
first design's Form C proposes — it needs a clearing operation the
collector does not have, and `$b = $a; unset($a)` breaks the single
owner; a fifth memory-category code for the deferred regime, which would
take the entity out of the census that enrols only `GcHeap`; forbidding
a deferred entity in a compiler-owned field, which needs a test on every
store into such a field and so is a write barrier.

**Cost:** the epoch byte becomes a safety gate, and `rc-walk` states
today that no byte is one — a lost mark is a freed live entity, where a
lost stamp costs a wasted message. Phase 4's exact test has no count to
re-read for a deferred entity, and the ordering of a mark against a
concurrent walk is unsolved. Both are open questions in
`model/gc/gc-horizon-v2/top-level.md`, and no entity leaves the first
design until they close.

## 2026-08-20 — the borrow-elision design enters the RFC as GC horizon, and the chain rule amends two normative sections

**Decided (Edmond):** the algorithm named `proof-horizon` in the code
repository's design notes is called **GC horizon** and lives here, as
`model/gc/gc-horizon.md`, with its state set beside it and a case book
of sixteen files under `model/gc/gc-horizon-cases/`. The purity ladder
it depends on moved with it (`model/gc/pure-destructors.md`), two of the
eight horizon kinds having cited an instrument this repository did not
hold.

**Why:** the design was normative nowhere. Its text sat in a code
repository beside three reading aids, while the sections it contradicts
— [static-lifetimes.md](../model/memory/static-lifetimes.md), "What may
own a borrow", and rc-walk.md, "Uncounted
borrows" — sat here saying a heap field never covers a borrow. Both now
carry the chain rule: a field covers a borrow on a counted path from a
root, with the borrow counting as a use of that root. DC5's mitigation
sentence follows them, and the case that made it condemns the same shape
under either reading.

**Rejected:** copying the algorithm and keeping the design note as a
working copy (two texts reading as normative drift silently); moving the
two reading aids as standalone RFCs (they would re-split the normative
surface the move exists to unify); a single combined cases file on the
`rc-walk-danger-cases.md` pattern (Edmond asked for a folder).

**Cost:** the algorithm's economics and measurement order now sit in the
specification while the process that revises them — the corpus veto, the
summary-language rulings — stays in `model/dev/DECISIONS.md`; the moved
document names that file as the place its open choices change. Dated
entries there keep the old name verbatim.

---

## 2026-08-07 — entity-kind codes leave the RFC; the enum is normative

**Decided (Edmond):** no document here prints the code of an entity kind.
A kind is named — Object, StringBox, ArrayBox, ReferenceBox, FFIBox,
WeakRef, Lazy — and where a code form is needed the text writes
`EntityKind::…`. The assignment of code to kind is normative in
`EntityKind`, `ll-model/src/refcount.rs`, and a consumer takes it from
the runtime's exported ABI rather than by transcription; a hardcoded code
is a defect even when its value happens to be right.

**Why:** the code is a detail of the encoding, and restating it here made
the design depend on it. The runtime's cycle-collector admission test was
written as a bitmask over the codes, could not express the set it needed,
and leaked a ring through a ReferenceBox until it became a set built from
the names (`ll-model` f2f2461). `classes.md` carried the same defect as a
parenthetical claiming the buffer holds only objects and arrays, which
bit 13 separates.

**The test for what may still print a number:** the sentence stays true
under any permutation of the code-to-kind assignment. The field's width
and position (three bits at 12–14) and the count of codes used and
reserved pass it; a kind-to-code pair, and any argument from the order,
adjacency or bit pattern of the codes, do not.

**Rejected:** one normative table of codes kept inside the RFC (it is the
thing the ruling removes); building an ABI header or `cbindgen` now (no
consumer exists, and the header's shape belongs to the whole ABI surface
rather than to this one row).

**Cost:** until that ABI surface exists, the assignment lives only in Rust
source, so a reader of `layouts.md` follows one link to see a concrete
byte. Historical documents keep the wording of their day, codes included,
and `layouts.md` says so where it introduces them. A grep is the standing
check: `grep -rnE '\bkind ?=? ?[0-7]\b' --include='*.md' .` may match only
under `dev/` and in the dated review records.

### 2026-08-06 — no cache in this runtime carries a replacement policy, and the personality routine gets a flag bit

**Decided:** `model/caches.md` is written, and its answer is negative — no LRU,
LFU, ARC or CLOCK anywhere. **Why:** nine production runtimes were read at source
level (Zend, V8, HotSpot, HHVM, CPython 3.12 and `main`, PyPy, LuaJIT,
JavaScriptCore, CoreCLR) and not one uses a classical policy for a dispatch,
property, method or type cache; every one overwrites in place, because the
entries are two or three words and any policy costs metadata work on every hit.
**The industry's one exception is a checklist Limelight fails.** HotSpot's code
cache qualifies because entries are kilobytes, the recency signal is free from an
entry barrier that already exists, reclamation batches into an existing pause,
and the policy disables itself under no pressure. `rc-walk` pauses the mutator
not at all, AOT calls are direct so there is no entry barrier, and nothing here
scans another thread's stack — so the conclusion is that **nothing qualifies,
including a future compiled-code region**, which therefore grows monotonically.
**Rejected imports:** HHVM's per-request generation byte, which names no site
here and is unsound for an actor that migrates between threads; and a CPython
class version stamp, which answers a question PHP cannot ask. **Also decided,
in `runtime/exceptions.md`:** the personality routine — the one genuinely
megamorphic site, since it sees a different class per call and has no site to
attach a cache to — takes a `Throwable` bit in the class flags plus the sorted
itable's binary search. A shared megamorphic table was rejected there: it would
buy back only the two-compare search while re-introducing the multi-writer
problem that per-site words avoid. **Standing rule recorded with it:** every
capacity limit names a degradation path, and it is never an abort — there is no
interpreter to fall back to here, so every path must be exact.

### 2026-08-06 — an inline cache site is one word pointing at an immutable pair

**Decided:** a site holds one word, published with a release store, pointing at a
`(class, target)` pair baked at class link time beside its method-table entry in
the immortal region and never written again. **Why:** the previous shape was two
independent process-global words, both written by the slow path on every thread
executing the site, so a reader could observe one thread's class beside another's
target and dispatch the wrong method on the wrong class — silently, with no
memory error, in a runtime that is multi-threaded by construction. Publishing a
pointer to an already-complete record removes the race by construction rather
than by ordering. **Baked, not allocated:** a pair allocated per cache update
would let a bimorphic site in a hot loop grow a region that is never reclaimed;
baking costs 16 bytes per method-table entry once per class, and a site
transition becomes one store with no allocation. An uninitialized site points at
a static `{null, null}` pair, so the fast path needs no emptiness test.
**Rejected:** a seqlock (two extra loads and a branch per hit); per-thread site
arrays (`sites x 16 B x threads`, cold start per thread); and packing a 48-bit
class pointer with a 16-bit vtable slot into one word — cheapest of all, and
sound because descriptors are immortal, but it stakes a claim on
virtual-address width that LA57 and ARM LVA make questionable. **Cost:** one
dependent load on the hit path, and one acquire load — free on x86-64, one
`ldar` on the ARM targets. **Invariant written down rather than assumed:** the
target half is valid only while compiled code is immortal, which phase 1
satisfies trivially and a tiering JIT would break; `lowering.md` names the two
shapes that survive tiering.

### 2026-08-06 — Ghost is the shim, and class metadata is immortal rather than long-lived

**Decided:** two contradictions inside `classes.md` are resolved by following
what another document already settled, so neither needed a new decision.
**Ghost:** `classes.md` described the mechanism twice and incompatibly — kind 6
keeping the real target class at `+8`, and a generated ghost-shim descriptor
swapped out on first touch. `lowering.md` had already settled it by dropping
`!invariant.load` for a class "whose class pointer is rewritten on first touch",
which describes the shim alone. The kind-6 passage is rewritten; kind 6 stays as
an instance marker for `clone` and reflection, which load flags anyway. **Why
the shim is also the only safe reading:** an inline cache's hit path compares the
class pointer and calls, never loading flags, so with the real class at `+8` a
warm cache would call a method on a zero-filled body — and teaching the hit path
to test kind 6 costs a load and a branch at every dynamic dispatch site.
**Residence:** `classes.md` said class descriptors and interned names live in the
long-lived arena while the crate puts both in the immortal region, and
`arenas.md` listed them under Long-Lived while its own Immortal row listed
interned strings. Immortal wins, following the code. It is load-bearing rather
than tidy: `arenas.md` leaves long-lived reclamation undecided, and a recycled
descriptor address re-issued to another class is a **false inline-cache hit**,
not a crash. **Retired with it:** the u32-offsets-from-an-arena-base option and
its 4 GB constraint — the immortal region is a chain of pool blocks with no base
and no bounded span. **Cost:** an `eval`'d or plugin class is never reclaimed,
which is acceptable while nothing supports unloading, and is now stated rather
than implied.

### 2026-08-06 — the chained index is the decision, not the default pending a measurement

**Decided:** the array hashtable indexes its entry array with chains, and the
question is closed rather than deferred. **Why now, without the equal-memory run
that was owed:** the margin lives at the sizes strategy 3 actually sees — 1.5x to
3x on build, both lookups and delete at N up to a few thousand, where the whole
table is cache-resident, so it is the cost of the path (two arrays and a group
probe against one slot read) rather than an effect of memory latency. An
equal-memory run would let the control-byte index run near load 0.55 and cheapen
its miss, but only at the large sizes where the two already meet within the
spread; it cannot move the small-N columns the decision rests on. **The
assumption it does rest on, stated so it can be attacked:** not that PHP arrays
are small — a small dense integer array is strategy 2 and never reaches the hash
— but that the tables reaching strategy 3 are mostly small and middling
associative ones. **Two non-performance grounds agree:** the flood backstop
counts entries with an equal full hash, which a chain walk visits exactly while a
probe run includes unrelated keys, so the counter is cleaner; and NEON has no
single-instruction movemask, so chains need no second probe implementation for
the ARM targets. **Cost:** about 3.4 bytes more index per entry, ~7 % of a
40-byte entry. The `next` field is not part of that cost — without it the entry
is 36 bytes, which the ValueBox's alignment rounds back to 40. **What reverses
it,** named in advance in the document: the control-byte index winning both
lookups by 1.5x or more on string keys at N from 56 to 28 672 without a worse
deletion margin.

### 2026-08-06 — the index comparison is measured at design load, and the control byte's advantage does not survive it

**Decided:** chains stay the default on measured grounds for integer keys. The
harness was rewritten after the retraction below: the slot count is now the power
of two for the control-byte index and the entry capacity seven eighths of it, so
a full table sits at 0.875 while the chained index sits at 0.4375 — each at its
own design maximum, printed with every row. Deletion follows hashbrown's
slot-anchored rule; a correctness pass over 200k keys with six rounds of churn
runs before anything is timed; every insert is lookup-then-insert; every timed
loop checks the count it produced; the two arms alternate. **Result:** the
absent-key lookup, which is the whole argument for a control byte, goes to chains
at every size but the largest, where the two are level — at 0.5 a chained miss
ends on the first slot read, while at 0.875 the control-byte probe walks two
groups on average and up to twelve. Deletion goes to chains everywhere by 1.3x to
3.1x. The control byte wins the build at the largest size only. **Not
established, and stated in the document:** string keys, where the seven-bit tag
filters a comparison a chain has to make in full; and the mixed workload, whose
run is discarded because the sizes gave one arm a full growth cycle of headroom
and the other none, so a single doubling sat inside the measurement and dropped
the table off its design load. **Cost:** the index memory is 9.1 bytes per entry
chained against 5.7 for the control byte, and that is the price of the default.

### 2026-08-05 — the index measurements are withdrawn, and the default stands on structure rather than on numbers

**Decided:** the benchmark numbers quoted in the entry below are retracted, and
`arrays-hashtable.md` no longer carries them. An independent review of the
harness found four defects: every table size was a power of two, so the
open-addressed index was allocated twice the slots it needed and never ran above
load 0.500 — the comparison the numbers claimed to make was never executed; the
mixed workload sized its tables for a theoretical peak and ran between loads
0.016 and 0.508; the tombstone rebuild that was supposed to separate two of the
runs could not fire at the sizes tested, so the explanation given for their
disagreement was false; and the deletion rule was not the one it was modelled
on, truncating the probe sequence of unrelated keys and losing live entries at
roughly one per seven hundred operations at realistic load. Two earlier defects
in the same harness had already been found and fixed — a timed `memset` of an
oversized index, and probing in insertion order, which walks the entry array
sequentially and erases the cost the control byte exists to avoid. **Why this is
recorded rather than quietly corrected:** the same numbers were used twice to
reverse a design conclusion in one day, and the failure mode is a harness that
silently measures a different structure than the one named. **Cost:** the choice
of index layer is now explicitly undecided; the requirements for a measurement
that would decide it are listed in the document's "Open" section. **What does
not change:** chains remain the default, on the structural argument — the dense
ordered entry array is required either way, PHP arrays are mostly small and
cache-resident where a control byte buys nothing, and deletion is frequent while
an open-addressed slot cannot be freed without leaving a tombstone.

### 2026-08-05 — the array hashtable is an index array over a dense insertion-ordered entry array, and the collision link moves out of the element

**Decided:** one allocation of `u32` index slots plus a dense 40-byte
entry array in insertion order; a lookup is two dependent accesses, and
no order-preserving design does better. The collision link is an explicit
`next` field at +16 rather than Zend's trick of threading it through the
element's own padding — `values.md` forbids per-slot state in bytes 10..15
because the store barrier writes all sixteen, so a value store would sever
the chain. The ValueBox sits last, at +24, so no write it performs reaches
the key or the link. **Rejected: SwissTable as storage** — insertion order
forces a dense ordered array to exist anyway, and iterating a control-byte
table costs about twice a dense stride (measured 6.8 against 1.2 ns per
element at 8 M). **Cost:** 40 bytes per entry against Zend's 32, plus 8
bytes of index at load 0.5.

### 2026-08-05 — the index layer is replaceable and the choice waits on a measurement nobody has

**Decided:** chains on `u32` are the default; the alternative is a `u64`
slot fusing a 7-bit fingerprint with the entry index, which is still two
dependent accesses. The entry array, promotion, the tracer and every
observable semantic are identical under both. **Why:** measured over a
byte-identical entry array, the fused slot wins absent-key lookups
(16.0 against 26.3 ns at 8 M) and loses badly after deletion (12.4 against
3.2 ns at 100 k), because an open-addressed slot cannot be freed and
becomes a tombstone, and a table that is deleted from and then only read
never reaches a rebuild. Moving the rebuild onto the delete path raised
deletion at 4 M from 18.7 to 61.3 ns. **What decides it:** the ratio of
`isset`-shaped lookups to reads in real PHP, unmeasured by anyone.

### 2026-08-05 — the flood backstop counts equal full hashes on insertion and escalates once to a keyed hash

**Decided:** count, per insert and against current state, the entries met
whose full 64-bit hash equals the new key's (constant threshold, since
eight-way agreement by chance needs ~2^56 keys) and the chain length.
Firing on the first escalates the table once to a keyed byte hash and sets
a one-way mode bit; firing on the second redraws the per-table salt.
Integer keys are indexed through a salted avalanche mix, not by value, so
`0, 1024, 2048, …` no longer share a bucket. **Why:** rapidhash is in the
family with published seed-independent multicollisions, so a salt over the
index cannot separate equal-hash keys, and redrawing it in response to
them is what made Perl's REHASH exploitable (CVE-2013-1667). **Rejected:
treeification** — the nodes fit neither beside a 16-byte ValueBox nor as
indices into an order-preserving array, and side allocation would make the
attacked path an attacker-triggered allocation. **Rejected: firing on
lookup** — `isset()` must not allocate, must not reallocate storage under
a live iterator, and has no synchronisation on a shared table. **Cost:**
one multiply on hash-resident integer keys, and folded hash constants go
unused in an escalated table.

### 2026-08-05 — the template object is an ordinary object, and nothing about it is generated per site except its class

**Decided:** parts and values alternate with empty parts allowed, so
there is always one more part than values and the offset map disappears —
the order is the encoding (JS tagged templates fix the same invariant).
Parts are interned immortal strings on the per-site class; the instance
is `RcHeader | class | Value[n]`, fixed size, walked by the ordinary
object tracer. **No new entity kind and no arrays**, which is what the
whole shape was chosen to avoid. **Dropped: the cached flattened
result** — rule 2 made the object's only consumer a structure-aware one,
which flattens rarely, so a slot on every instance serves a path most
never take. **Dropped: a generated flatten method per site** — rules 1
and 2 separated the cases, so the common path is straight-line code with
no object and the object path is rare; a function per site spends binary
size on what is seldom called, and the unroll threshold nobody could have
measured stops mattering. **Flattening** is Zend's two passes (sum,
allocate once, copy) with a value written into the result directly where
its length is knowable first, and with every `__toString` call completed
*before* the allocation, so user code cannot change what is being
assembled under it.

### 2026-08-05 — the template object is built only where the destination's declared type asks for it

**Decided:** materialization is the default everywhere; a template object
exists only when the declared type of the destination — a parameter, a
property, a typed local — is the template interface. `$db->query(...)`
with `query(InterpolateStringInterface $sql)` builds a template;
`$x = "$y 234"` builds a string, always. **Why:** the decision is one
lookup at the site, visible in the source, and the API author opts in
once for every caller — the arrangement C# uses, where the parameter type
selects the handler. **Rejected:** keeping the template wherever the
compiler cannot prove nobody wants the structure, which allocates at
every untyped site and makes the cost of an interpolation depend on an
analysis the reader cannot see; and forward flow analysis from the
assignment, which is more machinery for the same answer. **Cost, and it
is not small:** the protection follows the declared type, so a value that
reaches a call through an untyped variable was already materialized and
arrives as a string. SQL injection is impossible by construction where
the API declares the interface and the call reaches it directly, not
unconditionally — the section's earlier wording claimed more than that
and has been corrected.

### 2026-08-05 — an interpolated string used once and never stored is never built

**Decided:** the compiler decides at the interpolation site. Where it can
see that the result is consumed as a plain string and does not outlive the
expression, no template object exists at run time — the site compiles to
string assembly. `$x = "$y + 1"` is `$x = $y . ' + 1'`. **Why:** a template
that never escapes the expression gains nothing from being an object and
costs an allocation, a header and a free. **Assembly is one pass** — sum
the lengths, allocate once, copy each piece — because a chain of binary
concatenations produces an intermediate string per join; the two coincide
only at two pieces, which is why Zend keeps `FAST_CONCAT` beside its rope.
**Rejected:** guessing the result length the way C#'s handler does
(`literal_length + holes * 11`), because that trade assumes growth is
expensive and ours is not — a payload at the bump top grows without a copy;
and a stored lazily-flattened template for this case, which is LLVM
`Twine`'s shape and which `Twine` itself forbids storing. **Open:** the
rules for a structure-aware consumer and for a result whose type the
compiler cannot see.

### 2026-08-04 — folding a literal key's hash is a build option, and the seed goes with it

Supersedes the "Open" clause of the entry below, which left folding
undecided and defaulted to not folding. **Decided:** neither, it is
selected — one option (`hash-folding` in `ll-model`, off by default)
carries folding and the seed's home together, because a compiler that
folds must know the seed while it compiles and a per-process seed is not
knowable then. Off draws the seed from the OS per process; on fixes it at
build time and folds. **Why optional:** the trade is real in both
directions and belongs to whoever ships, not to the language. **Why off
by default:** the folded arm puts the seed inside the artifact, and an
attacker holding the artifact can then precompute colliding array keys.
**What folding buys is one load per literal-key access**, not the "few
multiplies" the entry below priced — a literal key is interned and its
hash is computed once per process at intern time — and that gain is
unmeasured. **Cost:** folded constants live in the program while the
function lives in the runtime, and nothing in the linker compares them, so
a folding build must carry a stamp of the hash's identity and check it at
startup. **Still not answered by either arm:** hash flooding. rapidhash
claims no resistance to key recovery from observed collisions, so the
table's probe-length backstop remains the only real defence, and it is
undesigned.

### 2026-08-04 — the string hash is chosen when the runtime is built, and defaults to rapidhash v3

The hash becomes a build-time axis like the GC strategy already is — an
`ll-model` cargo feature — with rapidhash v3 (vendored, constants
pinned, scalar) as the default short-input function, a frozen length
threshold, and a slot for a long-input function whose first occupant is
the same one. **Why build time:** we compile runtime bitcode and
generated IR together and re-optimize, so a build-time constant reaches
every call site as an inlined body, while a runtime choice would put a
function pointer on the hot path and cost the constant-folding of a
literal key's hash. **Why rapidhash:** fastest function passing SMHasher3
clean, no vector or crypto instructions, therefore inlinable in every
build mode including portable AOT. **Rejected:** xxh3 (its win is bulk
throughput this workload never reaches; seed-independent collisions on
record from its development), wyhash (superseded by the same author,
still failing the seed families), gxhash and aHash (need AES, so either a
pointer or a build that will not inline into baseline-featured IR).
**Long side is a strength decision, not a speed one:** an attacker picks
key length and so picks the function, making total resistance the weaker
of the two — HighwayHash-64 is the named candidate because it can carry a
per-process 256-bit key even where the short path's seed is baked into
the artifact. **Cost:** in the AOT modes the seed is extractable by
anyone holding the binary, so the hash table must carry a structural
backstop (probe-length counter with an escape hatch) rather than relying
on a secret. **Open:** the threshold is a measurement not yet taken, and
whether the compiler folds a literal key's hash at all — default until
measured is not folded, which keeps the seed out of the artifact.

### 2026-08-04 — a string is capped at 4 GiB, and the length gives up half its width to pay for capacity

`len` becomes `u32` at +8; the dynamic layout spends the four bytes of
padding at +12 on its `capacity`, taking that header from 40 bytes to
32. `hash` stays 64-bit at +16, so the shared-offset rule is untouched.
**Why:** an 8-byte `hash` must be 8-aligned, so a narrow length leaves
that padding whatever we do with it — capacity rides for free, and the
inline layout pays nothing, staying at 24 bytes. **Cost:** a 4 GiB limit
on strings, which is language-visible; every growth path checks against
it through one choke point and raises, since a silent 32-bit truncation
would write past the buffer. More generous than Java and C# (`2^31 - 1`
since release) and than V8; stricter than PHP, whose `zend_string` uses
`size_t` — a program reading a 5 GiB file into one string works there
and fails here. **Rejected: narrowing `hash` to 32 bits too**, which
would save a further 8 bytes and drop a 9-byte string from the 48-byte
size class to the 32-byte one — but that hash must serve both the bucket
index and the Swiss-table control byte, and full-hash collisions would
begin around 65k keys; revisit when Phase D shows the real length
distribution. **Rejected: a transparent long-string form** — it would
add a branch to every string operation and spend the last free
`EntityKind` code (seven of eight taken). Strings beyond the cap arrive
later as a separate class the programmer chooses, a stream or a rope.

### 2026-08-03 — the COW flag is the string layout, and a dynamic string never copies on write

Supersedes the sub-mode bit and the separating append in the entry
below (Edmond). `COW = 1` means bytes inline, `COW = 0` means a dynamic
string with its bytes out of line; the flag is set at allocation and
never flips, so every path reads the layout from a bit that cannot have
changed. **Why:** the flags word has no free bit — the layout test in
`ll-model/src/refcount.rs` accounts for all 32 — and a dynamic string is
exactly what the non-COW form of that flag has always denoted: freely
mutable, no copy on write, no sharing test. **Consequence:** a dynamic
string is outside the barrier rule, so its safety rests on the compiler
allocating one only where it has proved a single owner; where the proof
fails it allocates inline COW. **Rejected:** carrying the sub-mode in the
high bit of `len` (free by construction, since no string reaches 2^63
bytes) — unnecessary once the COW flag answers it, and it would have put
a mask on every length read.

### 2026-08-03 — strings: two layouts, no freeze, and the COW rule reads the category first

Freeze is dropped and the two string layouts are settled (Edmond).
Inline and dynamic differ only in where the bytes are; `len` and `hash`
sit at the same offsets in both, so only byte access and teardown branch
on the sub-mode. The layout is chosen by the compiler at allocation —
dynamic where it sees the string being appended to — and there is **no
runtime promotion between layouts**: rewriting the body under a header
`rc-walk` may be reading concurrently is the same objection that killed
freeze, and it is symmetric. **Why freeze fails:** it was specified as a
mode-bit flip, and no bit moves bytes from inline to out of line. Its job
is done instead by the ordinary COW rule, which now reads **category,
then `IS_ESCAPEE`, then the count** — an immortal entity's count is
pinned at 1 by the retain/release early-outs, so a bare count test would
have grown an interned literal in place and overwritten its neighbour.
A separating write on a dynamic string produces a **dynamic** copy, so
an append loop stays linear after it. **Arena survivors:** promotion
keeps the header where it is and reallocates the payload into the heap,
because promotion retains the block the header lies in and would
otherwise leave `data` pointing into a block returned to the pool;
an OS-direct payload transfers ownership instead of being copied.
**Rejected:** a third frozen sub-mode (keeps the dereference and the
spare capacity for life); a single inline-only layout in the heap
(makes `$obj->buf .= $x` quadratic). **Cost:** dynamic strings pay one
dereference to reach their bytes, and surviving arena strings pay a copy
of their payload at reset. The old `builder` name goes too:
`ClassBuilder` already holds that word in `ll-model`, and `Buffer` is the
primitive a dynamic string owns rather than is.

### 2026-08-03 — a COW entity's refcount equals its number of holders

The sharing test is only as good as the count, so the count is exact
(Edmond): a second holder retains before it can write, and the compiler
may elide a retain/release pair only where it proved no second holder
arises. **Why:** deferred ARC lets the count lag the stack until the next
safepoint. For lifetime that is harmless — the stack scan repairs it —
but the COW test is consumed at the instant of the write and never
revisited, so a lagging count means writing in place into a string
somebody else holds, and the value is corrupted silently. **Rejected:**
keeping deferred ARC for COW entities behind an analysis that proves
non-sharing; that is tiers 1-2, which already carve COW out, and tier 3
is precisely where no such proof exists. **The `IS_ESCAPEE` case is not
covered by exactness at all:** while bit 11 is set the field holds the
arena escape hold-count, so there is no reference count to read, and the
rule there is to separate unconditionally — which promotes
`ll-model/src/memory/barrier.rs`'s `debug_assert` into a normative rule
in the conservative direction. **Cost:** strings and arrays forgo the
deferred-ARC traffic reduction, the same price Zend pays for the same
oracle.

### 2026-08-03 — `rc-satb` stays designed and unbuilt, with named triggers

`rc-walk` overtook it on the one axis it was registered for. **Why:**
`rc-satb` promises near-zero pauses and pays a deletion barrier on every
overwriting store plus two all-thread safepoints per epoch; `rc-walk`
pauses the mutator not at all and charges nothing on a reference store,
because its roots are derived from the counts rather than enumerated.
`satb.md` predates `rc-walk` and never mentions it. **Rejected:
retiring it** the way MMTK was retired the same day — that was a slot
with neither code nor plan behind it, whereas this has both a plan and
properties `rc-walk` cannot acquire: marking terminates by
construction, floating garbage is bounded by one epoch, liveness comes
from reachability rather than completeness of the counts (the only
defence against an ARC-elided borrow), and it is the recorded door to
deferred reference counting. It is also the only spare collector whose
failure modes do not overlap `rc-walk`'s. **Cost of keeping it:** a
design that must be re-derived before use — and one defect found while
deciding, now recorded in it as blocking: the root set omits FFI
handles, so an entity held only by one would be swept under a live C
pointer, turning `rc-walk`'s conservative leak into a use-after-free.
**Triggers to build:** a measured `rc-walk` failure surviving a *built*
escalation rung 4; `domains.md` failing on its largest hole after an
honest attempt; or a decision to elide ARC past the covering-root rule.

### 2026-08-03 — MMTK is out; the registry offers no third-party backend

MMTK will not be built (Edmond). The `mmtk:<plan>` row leaves the
strategy registry and nothing replaces it, so the contract now serves
Limelight's own strategies only. **Why:** the shipped collectors own
their heap directly and have since `rc-walk`; keeping a backend row
nothing implements made the registry advertise a slot that no code,
and no plan, stands behind. **Rejected:** keeping the row as a
standing offer — it is the drift class this repo already pays for.
**Cost:** one supporting argument for Rust as the core language
disappears (`runtime/implementation-language.md`); the decision itself
stands on memory safety and is already executed. The surveys in
`heap-design.md` and `gc-research.md` stay as the record of what was
considered.

### 2026-07-28 — The forced verdict replaces the parked mutator; the allocation-failure path is the pressure trigger

The escalation ladder's rung 3 (park the mutator) is deleted — it
violated design principle 4 and, per the channel analysis, bought
nothing: parking at a checkpoint inside a borrow's hold window
re-reads the same inflated count. New endgame: after `R` consecutive
acquittals of the same component (trigger-only identity: slot-set
hash, invalidated on flush; the posted message is always the current
walk's product), the collector bypasses the Phase 3 filter and posts
the component — the Phase 4 exact test, race-free on the owner
thread, is the final arbiter: balanced → collected, mismatch →
provably live at that instant, corpse → part-dead, re-judged.
Rationing is mandatory: per-component exponential backoff, a
per-epoch cap, weak-subscribed components first (the only perpetual
touch channel to true garbage is `WeakRef::get`). Prerequisite that
became load-bearing: the batched/vector checkpoint splits — ack
before the release run, pickup after it — else a scope-exit poller
phase-locks every pickup inside its hold window. Second load-bearing
order: weak nulling only after the exact test passes
(weak-references.md reconciled). Companion section "When the
collector runs": the allocation-failure path climbs the mutator's
self-help ladder (flush parked → drain verdicts → signal pressure,
rations lift → synchronous `collect_cycles`, gated by the walk-active
bit joining the pickup gate → honest OOM); principle 4 forbids
outside pauses, not one's own spent time.
- **Why:** the design already owns a quiescent re-check — the drain —
  so the park was strictly dominated; prior art has no forced-verdict
  precedent because no other system has a race-free final gate to
  force *to* (Recycler retries forever; FUGC terminates by
  monotonicity, which the forced verdict restores here).
- **Rejected:** condemned-aware `WeakRef::get` (per-get mutator cost,
  and it would resurrect the byte eager death just deleted); early
  weak nulling at condemn time (unsound for live false candidates);
  backoff without a final gate (Zend GH-9266: starvation becomes a
  sanctioned leak).
- **Cost:** rare rationed `O(component)` verification passes on live
  components; all of it is design ahead of code ("code lag" flags in
  place: `ll_gc_checkpoint_ack`, the trailing pickup, the vector
  split, the walk-active pickup gate). Open question 1 keeps only its
  cadence half.

### 2026-07-27 — Eager-death review: ack-only death checkpoint, out-of-band parking, unwind waits for acks

Two fresh-context adversarial passes over the eager-death amendment
surfaced two BLOCKERs that predate it, plus one spec gap; all three are
now design rules.
- **The death-branch checkpoint acks only; message pickup and the
  parked flush ride the outermost dispose's exit.** Between the
  committing zero store and dispose, the dying entity is
  committed-dead with a live weak cell; a drain destructor's
  `WeakRef::get()` there returns a strong reference to it —
  resurrection after commit, or double teardown (DC0 through the
  front door). Opened by the 2026-07-27 checkpoint move to the death
  branch, universal since eager death.
- **Parking is out-of-band.** The in-slot park link at bytes 8-15
  overwrote the class word mid-epoch, under a walker that reads the
  header in one pass and dereferences `+8` in the next — a wild read.
  A parked slot is now never written until the post-epoch flush;
  corpses stay intact (header 0, class live, fields nulled).
- **The epoch's unwind path waits for posted confirmations** before
  releasing the deferral window, or the next epoch opens over an
  undrained queue — two epochs' verdicts in flight.
- **Corrected in passing:** the F2 volume claim ("parked memory cannot
  exceed the live heap at epoch start") was derived under the F5
  deferral and is false under eager death — the true bound is churn
  rate × epoch duration. Two collector-side bounding mechanisms
  (epoch-abort watermark, young-free exemption) recorded in BACKLOG.
- **Cost:** parking allocates (a side list, cold path, epoch-only);
  drain latency moves from the death's checkpoint to its dispose exit
  (microseconds, same event).

### 2026-07-27 — Eager death: every refcount death tears down at the natural point; the condemned byte is retired

A release reaching zero mid-epoch now runs full teardown immediately —
`__destruct` on the owner thread, weak notify, sever, free — with only
the memory parked (the existing deferred queue); the F5 deferral, the
deferred-death marker and the shared condemned byte are deleted, and
condemnation becomes collector-private. The drain header-scans first
and drops any message containing an `rc = 0` member (the corpse rule),
which closes DC0 without acting on the corpse. Acquittals post no
message — both drain duties (byte clears, deferred-death tears)
dissolved with the mechanisms they served.
- **Why:** the deferral traded destructor timeliness — the one
  userland-visible semantic — for drain simplicity; the parked slot
  already guarantees corpse identity, so refusing the message is as
  safe as preventing the corpse, and the mutator's death path drops
  its last collector test.
- **Rejected:** keeping the byte as a Phase 3 filter (after the narrow
  mutator nothing writes it but the collector — it carried no
  information); zeroing corpse payloads (a torn ValueBox for the
  walker; the parked slot makes stale pointers safe to follow, so
  nothing needs zeroing).
- **Cost:** a component that partially dies between posting and drain
  waits an epoch for its survivors' re-judging; the TLA+ battery
  models the pre-amendment protocol until re-derived (noted in
  rc-walk-model.md and the tools README).

### 2026-07-27 — The weak cell is the canonical WeakReference; a per-thread table delivers death

Weak references designed ([weak-references.md](../model/weak-references.md)):
no separate side entry — PHP's canonical-instance guarantee lets the
`WeakRef` entity itself be the shared cell, so death notification is one
store into its target field. The dying object finds the cell through a
per-thread weak table (address → subscriber row, tagged: canonical cell /
map); rows are runtime-internal, no user-facing death callbacks. `WeakMap`
cleanup is eager at notification time.
- **Why:** the cell must be findable by the dying object without an 8-byte
  field in every object; per-thread because every notification site
  (teardown, drain checkpoint, arena reset) runs on the owning thread, so
  the table needs no locks.
- **Rejected:** a Swift-style separate side entry (an allocation and a
  hand-rolled refcount that `RcHeader` already provides); Java-style lazy
  map expunge (stale entries hold values hostage — javadoc-documented);
  a global Zend-style table (a mutex per create/death).
- **Cost:** ephemeron entries (value references its own key) are not
  collected — PHP 8.0–8.2 behaviour, 8.3 parity deferred to BACKLOG.

### 2026-07-25 — A safepoint is a moment, not a root map; and rc-walk's checkpoints live in the allocator

Two corrections that turned out to be one. A poll safepoint says *when*,
not *what*: it makes roots enumerable only for a strategy that also pays
the compiler to publish them. Counting a frame's references is the
alternative payment, and `rc-walk` has already made it, so it never reads
a stack. Separately, the checkpoints `rc-walk` does need — the handshake
ack and the Phase 4 drain — belong in the **memory manager**, not in
compiler-inserted polls.
- **Why:** the allocator is called constantly, already owns the numbers
  that decide whether collection is worth doing, and is the natural place
  to choose the moment. It also dissolves the parked-thread problem: a
  thread inside a syscall or an FFI call reaches no checkpoint, but it
  allocates nothing and mutates nothing, so nobody waits on it. A compute
  loop that releases without allocating is bounded by the live heap at
  epoch start.
- **Rejected:** marking entry to and exit from foreign code so the runtime
  can ack for a blocked thread (FUGC's move) — two writes on every call
  out, and PHP calls out constantly.
- **Cost:** [strategies.md](../model/gc/strategies.md) §2 reworded; the
  obligation to publish roots now sits explicitly with `rc-satb`, which
  does not have the mechanism. Compiler polls stay in the project for
  their other duty, raising an exception after a failed reserve refill.

### 2026-07-25 — A borrow's owner must be a root, not merely something alive

When the compiler elides a `retain` because some other reference keeps the
object alive, that other reference must be one the cycle collector counts
as a **root**: a frame slot, an arena slot, a static, an immortal, an FFI
handle. A field of a heap object never qualifies.
- **Why:** liveness-by-refcount is strictly weaker than liveness. `$x =
  $obj->other; $obj = null;` with `$obj` in a cycle is sound under plain
  refcounting (the ring merely leaks) and unsound the moment a collector
  frees the ring. The narrow scope is the good news: anything that leaves
  the frame is stored, every store is counted, so an uncounted borrow can
  only live in a frame slot and the obligation is a within-frame property.
- **Rejected:** relaxing the rule for holders of acyclic classes. An
  acyclic holder cannot be a cycle *member*, but it can be garbage held
  *by* a cycle and dies in the cascade that frees it.
- **Cost:** none to the collector; it constrains the borrow analysis of
  [static-lifetimes.md](../model/memory/static-lifetimes.md), where the
  rule and its three worked cases now live ("What may own a borrow").

### 2026-07-25 — The cycle collector's licence to skip, and the acyclic-class flag that spends it

`rc-walk` operates under two standing permissions: it **may skip** (a
missed cycle is memory not yet reclaimed, never a wrong answer) and it
**may be slow** (its cost is off the mutator's path, so collector time
buys mutator instructions at any exchange rate). The skip lemma makes the
first safe: omitting an entity from the walk only removes in-edges, so
`RC − IN` grows and its targets are pinned as roots. The first thing that
licence buys is the **acyclic-class flag** — a class whose node lies on no
cycle of the class-reference graph is skipped entirely, in the walk and as
an edge target.
- **Why:** skipping is recall-only in both directions, so an *unsound*
  flag can only leak, never free a live entity — the analysis can ship
  imprecise and tighten later. Bacon and Rajan compute the same flag for
  the Recycler and report the candidate population falling by roughly an
  order of magnitude.
- **Rejected:** a per-object dynamic version (an object currently holding
  only scalars is acyclic in fact) — it needs a re-check on every store,
  which is the per-operation mutator cost the strategy exists to avoid; a
  header bit — bits are scarce and a collector-side class load is free.
- **Cost:** skipping must be **total**. An edge recorded into an entity
  whose `rc[]` row was omitted reads as a negative derived root and frees
  a live object. Recall loss is bounded by one epoch, since an acyclic
  entity dies on the ordinary path once its holder does. The analysis
  needs a closed class set: a field typed `T` reaches every subclass of
  `T`, so anything registered later (`eval`, late autoload, an
  FFI-installed descriptor) is cyclic by default.
- Written up in rc-walk.md, "The compiler's
  acyclic flag".

### 2026-07-24 — A `#[Region]` is an allocator class: it may supply its own alloc, free, and GC traversal

A `#[Region]` ([regions.md](../model/memory/regions.md)) is the runtime's
**allocator class**: an object that owns memory and governs the objects
it creates. Beyond binding a named collector, a region may supply its own
allocation and free policy and — the new capability — its own **GC
traversal** of its objects. Its contents are `gc_state = OWNED`; the
global collector skips them and the region's own collector handles them.
- **Why:** unifies arenas, per-class pools, slotmap/movable containers,
  and custom allocators under one first-class object — matching Verona
  regions and Zig/Ada custom allocators, and adding a user-supplied GC
  walk those do not have (the novel part). Movement stays confined to a
  region's key/handle store (the only relocation the runtime does).
- **Traversal safety contract:** over-approximation — a custom traversal
  must report a superset of live outgoing references and only references
  the object actually holds, never a fabricated address. Over-report is
  harmless (one extra cycle); under-report is a use-after-free and is
  forbidden — the same rule as release-at-reset and SATB marking. The
  runtime does not verify a hand-written traversal; that unsafety is
  accepted for now and revisited separately.
- **Deferred:** verifying/restricting a hand-written traversal so it
  cannot under-report; the attribute spelling (`#[Region]` vs
  `#[Allocator]`); explicit `reset()`/`pack()` lifecycle.
- **Written:** [regions.md](../model/memory/regions.md), "The region as
  an allocator class".

### 2026-07-24 — Proxy is the runtime's one indirection; movement is opt-in through it

Box (kind 4), WeakRef (kind 5), and Ghost/lazy (kind 6) are unified as
instances of one **Proxy** pattern — a surrogate that intercepts all
access to a target for one dereference — and a fourth effect, a movable
handle, joins them. Object movement exists **only** behind a movable
proxy (or an extract-to-access container); the general heap stays strictly
non-moving.
- **Why:** fragmentation is handled without a global moving collector.
  Confining relocation to an opt-in proxy pool keeps the common path on
  direct pointers (no read barrier, no global pinning) and localizes the
  compactor; identity rides the stable proxy, so `spl_object_id` stays
  address-derived. The shape is the GoF taxonomy (virtual proxy = Ghost,
  smart reference = WeakRef, handle = movable), and PHP 8.4 already names
  its lazy strategies Ghost and Proxy. No mainstream language unifies
  weak + lazy + movable under one primitive, so this consolidates known
  effects rather than inventing.
- **Rejected:** a global moving/compacting collector — read barriers plus
  pinning for FFI-escaped addresses plus header identity-hash, all to move
  objects the FFI load often pins anyway (see the non-moving research).
  The committed fragmentation answer is the movable proxy, not arena-reset
  sparse-block evacuation, which stays deferred.
- **Cost:** one pointer-chase per access on proxied objects; a scoped
  compactor for the movable-proxy pool if/when built.
- **Deferred:** consolidating kinds 4–6 (one family) to reclaim
  entity-kind bits — noted, not designed.
- **Written:** [classes.md](../model/classes.md), "The Proxy family".

### 2026-07-24 — Captured heap objects carry `gc_state = OWNED`, skipped by the collector

A general-heap object (category `00`) captured by an arena/actor stays
physically in the heap but is marked with a fourth `gc_state` value,
`OWNED`. Both CAS handoffs start from `LIVE`
([heap-design.md](../model/gc/heap-design.md)), so an `OWNED` object
fails both and is skipped by collector and mutator alike; its lifetime is
the owning arena's responsibility until it escapes to shared and is
re-armed to `LIVE`.
- **Why:** a transferable object is allocated in the general heap for a
  zero-copy handoff ([actors.md](../runtime/actors.md)) but is owned by
  one actor at a time. The collector must not touch a captured object;
  saying so with `gc_state` costs zero new bits (2-bit field, only 3
  values used) and needs no new collector branch — a non-`LIVE` state
  already fails the handoff CAS. It also makes the "needs no atomic
  counts" claim exact: the single owner is the sole writer of `refcount`.
- **Rejected:** a dedicated flag bit (the flags word is full, bits 0–31
  all assigned); a fifth `mem_category` (2 bits, all four values used);
  reusing entity-kind `7` (conflates identity with collectability).
- **Cost:** `heap-design.md` state field is now four-valued; `classes.md`
  flags table and `actors.md` updated.
- **Not fully worked out.** The escape event that flips `OWNED → LIVE`
  (an object becoming reachable by ≥2 actors) rides the existing
  escape/category machinery; its exact trigger and the in-transit
  A→queue→B ownership window are not yet pinned. Provisional.

### 2026-07-24 — The marker's root set includes live arenas' heap references

The concurrent marker's roots are `stacks + globals` **plus every live
arena's references into the general heap** (its *release-at-reset* list),
not stacks + globals alone. Transport depends on the arena's thread: a
same-thread arena (request / ordinary) is scanned directly at the
SNAPSHOT safepoint; an actor arena on another thread **publishes** its
list in the mailbox handshake (variant B), so the marker never reads a
running actor's memory.
- **Why:** a general-heap object reachable *only* from an arena slot is
  on no stack or global, and the marker does not walk arenas, so a
  stacks+globals-only trace would sweep it while live — a use-after-free
  at reset. Prior art (Pony/ORCA, Go, HotSpot, OCaml-multicore/DLG)
  overwhelmingly reads a running mutator's roots by cooperative
  self-publish at a safepoint/handshake, not by concurrent direct reads.
- **Rejected:** the marker reading a running actor's list directly (the
  earlier `actors.md` wording) — only ZGC/Shenandoah approximate
  concurrent root reads and even they gate with a stack-watermark
  barrier; an unsynchronized read also contradicts actor isolation.
- **Deferred, larger:** a capability restriction on what may cross an
  actor boundary into the general heap (immutable or unique only, à la
  Pony `val`/`iso`) — what buys barrier-free collection. Its own entry
  when designed.
- **Cost:** `satb.md` root set and `actors.md` root transport reworded.
- **Not fully worked out.** A direction chosen from prior art, not a
  verified mechanism: the SNAPSHOT "all-threads safepoint" wording still
  sits in tension with the actors' "no stop-the-world" handshake, and the
  handshake payload and same-thread watermark/SATB interaction are
  unproven. `actors.md` and `satb.md` both flag it provisional; re-verify
  at implementation.

### 2026-07-23 — A reserved region must state its extent explicitly

Any reserved or padding region in a layout must state where it starts,
how large it is, and why it is unused; the regions must sum to the
declared total.
- **Why:** the first run of the fact-base checker (`efen-lang/kolvir`)
  found that the value Box was declared 16 bytes while its fields summed
  to 15 — payload 8, type_tag 1, flags 1, reserved 5 — leaving byte 15
  belonging to nobody. `reserved` had to be 6 bytes (+10..15), which
  PHP's `zval` confirms independently: `u1.v.u.extra` (2 B) and `u2`
  (4 B) occupy exactly that span. A loosely worded reserve hid a whole
  missing byte.
- **Rejected:** treating an unexplained "reserved" as harmless slack.
- **Cost:** none of substance; layout tables get slightly more verbose.
- Fixed in [values.md](../model/values.md), "Box Layout". What to put in
  those six bytes is deliberately deferred, see [BACKLOG.md](../BACKLOG.md),
  "Deferred optimizations".

### 2026-07-25 — rc-walk checker: TLA+/TLC, not PHP or SPIN

The rc-walk interleaving checker (`TASK-rc-walk-proof.md`) is a TLA+
spec model-checked by TLC, resolving the choice `rc-walk-model.md` §11
left open.
- **Why:** the state space is finite by construction, so the right
  search is full breadth-first exploration with sound deduplication and
  no depth bound — exactly what TLC does, and what kills all three traps
  the thrown-away hand-rolled checker hit (depth-bounded memoisation,
  tight bounds, minimal counterexamples come free). The `R*` oracle is a
  transitive closure, native in TLA+; T5 is a liveness property under
  fairness, which TLC checks and a hand-rolled enumerator realistically
  cannot. Java verified present on the working machine.
- **Rejected:** PHP enumerator (hand-rolled DFS re-creates the traps);
  SPIN/Promela (the `R*` oracle would need embedded C); Coq/Isabelle
  theorem proving for the unbounded claim (weeks of work against a
  design still moving — revisit if the design freezes).
- **Cost:** one external toolchain (`tla2tools.jar`, pinned); TLC
  counterexample traces must be translated by hand into the adversarial
  harness tests `rc-walk-model.md` §11 describes.
- State-space accounting that informed this:
  rc-walk-states.md.

### 2026-07-26 — rc-walk: resolutions from the scenario-replay findings

The scenario replay and TLC runs (`rc-walk-proof.md`, findings F1–F9)
were resolved in one pass; `rc-walk.md` and `rc-walk-model.md` carry
the edits, each stamped with this date.
- **Condemned entities never die on the ordinary path** (F5): a
  release reaching zero on a condemned entity defers teardown to the
  drain — exactly-once teardown, destructor deferred past the last
  release is accepted semantics. Replaces the vacuous dead-member
  acquittal claim.
- **Phase 2 groups by weak connectivity**: linked garbage dies in one
  epoch; one touched member acquits the whole group for an epoch.
- **Masquerade closed, not screened**: the manager commissions blocks
  with zeroed slot headers (free for fresh OS commits; explicit pass
  for recycled or lazily-decommitted memory), and the object factory
  publishes the header last as one 8-byte store. `ll_object_new`
  reorder lands with build-order step 1.
- **Drain is non-reentrant** via the allocator's own mid-drain state
  (F8); **re-verify discounts the guard** (F1); **M3 releases last**,
  a compiler obligation (F7); **frame slots represent external
  holders**, §11 corrected to 3 heap entities (F9); **T5 carries an
  explicit fairness premise** and the stalled-epoch case is accepted
  without a fallback (F2).
- **Checker runs are scenario-scripted**: the free mutator blows the
  state space past 30M states without exhausting. Each run binds the
  mutator to a fixed 2–4-action script (the danger-case shapes); the
  only nondeterminism is the placement of those actions between
  collector micro-steps. Runs land at 10²–10⁴ states and seconds of
  wall clock; the claim is per-scenario, stated with every result.
  Free-mode exhaustion remains available (`ScriptName = "free"`) as an
  optional offline run.
- **Cost:** one condemned-byte test on the reaching-zero path; a
  header-zeroing pass when commissioning non-fresh blocks.

### 2026-07-26 — rc-walk: second-audit resolutions (acquittal message, total skip, canonical filter)

A second fresh-context audit attacked the same-day amendments and the
checker; two design changes and one canonisation came out of it.
- **An acquittal is a message.** The collector performs no acquittal
  cleanup itself: the owning thread's checkpoint clears condemned
  bytes and tears deferred deaths. Every condemned component ends in
  exactly one mutator-side message (confirm or acquit); the epoch
  waits for all of them.
- **Why:** the draft ran destructors/releases on the collector thread
  and had a byte-clear race that minted permanently invisible zombies
  (rc = 0 reads as free; destructor never runs; children pinned
  forever).
- **The allocate-black skip is total**: child-pointer validation also
  requires the target's epoch byte to read an older epoch, else the
  edge is dropped (conservative). Closes row-absent/edge-present
  arising in the sound design.
- **Phase 3 filter canonised as snapshot comparison** (any observed
  change acquits); the "recompute RC − IN" reading is retired —
  comparison is simpler, strictly more acquittal-prone, and is what
  the TLC battery verifies.
- **Checker**: 4 slots / 3 frame slots; the audit's 4-entity
  near-false-post shape passed exhaustively (35 202 states, full
  invariants) — strongest F6 evidence so far. Battery is 22 scenarios,
  all matching expectations; SC-memory-only and narrow-destructor
  limits recorded in rc-walk-proof.md.
- **Cost:** acquitted components keep their bytes until the owner's
  next checkpoint; one more message kind on the queue.

### 2026-08-23 — compiler logic leaves this repository's scope; a uniquely owned entity is not collected

Edmond, in the session that reviewed the question graph of `model/gc/walk/`.

- **The compiler's proof logic is not this repository's subject.** It is
  assumed to exist and to work. Questions of the form "what can the compiler
  prove" therefore leave the graph: the birth count, anchor-chain elision,
  clearing the COW flag by proof, the transitive purity closure and the
  acyclic class flag were struck by name or by the rule. What stays in their
  place is what the runtime does with a proof already given.
- **A uniquely owned entity is not collected, and what it holds is walked.**
  Where the compiler proves that exactly one heap slot owns an entity, the
  walk does not collect that entity; it still reads its children as edges,
  like any other entity's. The header mark is the retired condemned byte's
  bit (`model/gc/walk/questions.md`, the header-discriminant node).
- **Why:** not stated, and not inferred here. The rule is recorded as given.
- **What this does not close:** the move rule of `model/gc/rc-walk.md` —
  copy the entity or prove it never moves — is compiler business under the
  first bullet and is owed a home outside these documents.

### 2026-08-23 — the verdict protocol, restated by Edmond over the question graph

Three corrections to what this repository had written about the protocol,
given while reviewing `model/gc/walk/questions.md`.

- **One direction, not two.** The collector judges; suspects go to the
  mutator. Ruling 5 asks for no return channel and never did: it puts
  freeing on the collector and verification on the mutator and says nothing
  about channels. The hand-off/hand-back pair is `model/gc/pure-destructors.md`'s
  own design, and node D1's line attributing it to ruling 5 was wrong.
- **Nobody is woken. A grown verdict queue makes the collector stop
  judging.** This replaces ruling 4 as it was recorded — "a grown verdict
  queue activates the mutator, which drains it rather than waiting for its
  ordinary cadence". The mechanism is back-pressure on the collector, and no
  push toward a thread is needed or wanted.
- **Ruling 8's collector-side destructor call is nearly unrealisable.** The
  final judge is the mutator, so a call on the collector's side has almost no
  room left. The permission stays on the books; node D5 carries the note.
- **What this does not close:** ruling 5 puts freeing on the collector, and
  with nothing returning to it, what tells the collector that a suspect was
  confirmed is unstated. Recorded as a gap rather than answered here.

### 2026-08-23 — the proof side is the compiler's, and leaves these documents

Edmond, closing the same walkthrough. The exchange that settled it: pairs on
local references **are** removed where the compiler can prove it safe, and a
horizon is the place where the proof stops covering a borrow and the pair goes
back — «убираем, но это вопрос для компилятора».

- **Section G of `model/gc/walk/questions.md` leaves the node index**, all
  seventeen nodes, kept in the file at a heading level the index does not
  read. `model/gc/gc-horizon.md` carries a banner saying the same of itself,
  which its own scope line already said: it owns the compiler-side rule for
  which local references carry a count, and the collector is not a party to
  it. `walk/README.md` no longer claims the proofs as an inheritance.
- **Why it was there at all:** `walk/` was made the design of record on
  2026-08-22 and given "the compiler proofs of gc-horizon.md" with it. That
  inheritance is what dragged the whole proof side into the collector's
  question graph, and it is now undone.
- **What this leaves:** thirty nodes and nineteen edges, all of them about
  the collector and the runtime. The case book `model/gc/gc-horizon-cases/`
  is the next thing to read against this ruling — most of its sixteen cases
  are horizon shapes — and step S5.7 of `dev/PLAN.md` is written over it.

### 2026-08-23 — the case book becomes a record, and the stage loses its destination

Edmond, closing the walkthrough. Asked whether the sixteen cases of
`model/gc/gc-horizon-cases/` follow the proof side out: **yes**.

- **Nothing moves.** The folder stays where it is with a banner: compiler
  business, kept as a record. It holds the mapping of Edmond's thirty-five
  adversarial shapes, which is why it is kept rather than deleted, and no
  collector document defers to it.
- **Step S5.7 is dropped** with its subject, unexecuted. Steps S2.5, S3.1 and
  S3.2 built the book and stay closed — that work is the record.
- **The stage's destination is retired.** `dev/PLAN.md` aimed at "the GC
  horizon algorithm readable in this repository as a case book"; it now aims
  at the collector design of record as a question graph. The old words are
  kept beside the new ones so the change is visible rather than silent.
- **Why the book was written in that vocabulary at all:** every case opens on
  a borrow's chain, an owned base case or a horizon kind, because the book
  was built to instantiate the horizon algorithm. That is the same
  inheritance that put section G in the collector's graph.

### 2026-08-23 — the mutator frees; ruling 5 is restated

Asked who releases the memory of a group the collector judged garbage and the
mutator then confirmed: **the mutator**.

- **Ruling 5 as recorded said the opposite** — "the collector is the main
  freeing path" — and is rewritten over this. The collector walks and judges;
  suspects go to the mutator; the mutator verifies and frees. Nothing returns
  to the collector, and nothing needs to.
- **The gap recorded earlier the same day is closed by it.** With freeing on
  the mutator there is no confirmation to send back, so the missing signal
  that node D1 named was missing because it does not exist.
- **What it invalidates:** the hand-off drain of
  `model/gc/pure-destructors.md` moves the sever and the physical release to
  the collector, which this ruling no longer permits; that section carries an
  amendment banner and what replaces it is unwritten. Ruling 8's permission
  narrows again — with no collector-side freeing arm, a collector-side
  destructor call has nothing to sit beside.
- **What is unexamined:** ruling 3's batch ceiling is written over a freeing
  batch whose owner has just changed, and node D3 does not say so yet.

### 2026-08-23 — Sage: where a partial drain may be left  `Final`

Edmond offered leaving the unfinished remainder «как вариант» and sent the
question to Sage. The verdict, and it corrects the account the question was
asked over.

- **The drain is seven steps, not four**, and `rc-walk.md`'s four-step list is
  a record rather than an account of the code. `ll-model` `src/walk.rs`
  (`drain_confirmed`): exact test, guard, **weak nulling**, destructors,
  guard-discounted re-verify, `sever_component`, `unguard`, then the external
  children drop. The weak nulling sits before the destructors, not after, and
  its omission from the list is what hid the boundary analysis.
- **The remainder may be left at two boundaries and no others:** between
  messages, and after the prologue completes but before the sever begins.
- **The sever-to-free stretch has no interior boundary.** `unguard` runs only
  after `sever_component` returns, and every member of a confirmed component
  carries at least one in-component in-edge, so a stop inside the sever is
  always a stop with hollow members and nothing freed. Independently: the
  drain trusts nothing it was told, and the equality the mutator would re-run
  is the one the sever destroys.
- **So leaving the remainder does not bound the pause.** The unbounded cost
  is the sever, and at the only moment the ceiling can fire there the mutator
  must finish. The bound on the unit stays owed, and the measurement that
  chooses between D3's two candidates — the distribution of per-entity sever
  cost — becomes the blocking item.
- **The ack must be late**, acking at pop being a checked kill of the
  drain-exclusivity invariant. The epoch then cannot close and every thread's
  parked memory stays parked for the pause: a bounded mutator pause bought
  with an unbounded epoch.
- **The remainder is still garbage on return** and needs no re-verification,
  by the argument that already lets a tail run on a foreign thread. What it
  needs is a cursor, two fields, unspecified, waiting on D1.

**Not closed:** the bound on the unit; the epoch's completion bound; FFI, the
one channel by which a paused-over member could still be reached (node G14);
and the unmodelled case of a synchronous collection starting while a paused
drain's guards are outstanding, which wants a kill variant rather than an
argument.

### 2026-08-23 — Sage: the sever of one entity may be split, at cell granularity  `Final`

Edmond challenged the first verdict's sever half — why a very large array
cannot have its cells nulled in batches with the mutator returning to the
program between them — and sent the question to Sage on Fable. The verdict
narrows the first rather than overturning it.

- **A split inside one entity is permitted, between cells**, after a cell's
  empty-and-record pair completes and before the next begins. That pair is
  the only granularity: pause inside it and the child has neither a cell nor
  a count. Steps 6 to 8 still admit no boundary between them.
- **The first verdict's "hollow members" ground falls, and Edmond's reading
  was right.** Hollowness forbids nothing, because the exact test excluded
  every outside counted reference and the weak nulling ran before any
  destructor, so program code cannot name a member across a pause however its
  fields look — which is what the already-permitted boundary rests on. The
  second ground bars a check inside the sever, not a pause, and no check runs
  there anyway.
- **This chooses D3's first candidate:** the ceiling is checked inside the
  sever, at the cell granularity where B4 measured the cost uniform. Refusing
  large entities altogether stays available as policy, Edmond's to adopt.
- **Resurrection is closed on every managed channel** — a destructor cannot
  run twice, another entity's destructor cannot name a member, and the
  synchronous collection can only err toward live, a guard being a count with
  no edge and a nulled cell an edge removed with no count removed. **Open on
  FFI**, node G14, where a wrapper the C side holds carries no counted
  in-edge; the split does not open that channel, it changes what a stale
  foreign read meets.
- **Edmond's latency instinct holds as a comparison.** One stretch does
  strictly less work and closes the epoch soonest, and an open epoch parks
  every thread's deferred memory. A million-cell array is 43-47 ms in one
  stretch; at a pause budget near a millisecond that is roughly twenty
  thousand cells to a slice.

**Not closed:** the epoch's completion bound, which a split lengthens; the
kill variant for a synchronous collection meeting outstanding guards, now
with a second shape to model; G14; the cursor's home, waiting on D1. And the
code — `sever_counted_children`, `sever_entries` and `sever_cells` carry no
cursor today.

## 2026-08-26 — four rulings from the Critic round over `ll-model`'s plan, and what they change here

Edmond asked for a Critic round and a Sage pass over `model/PLAN.md`
S30–S40 before the deletion started. Four rulings came back; three of them
change this repository, and they are recorded here because the plan that
carries them lives in the other one.

**Y9's prune is the maturation mechanism, and the summary bullet that said
otherwise is wrong.** `model/gc/rc-cycle.md` says "an entity is traced only
after it has stayed a candidate across `k` collections" — a delay on the root
side. Y9 says a stamped mature member is read as an opaque live external and
is **not descended into** — a prune on the edge side — and calls it the only
mechanism in this design that bounds the closure. The root-side reading
filters which roots start a trace and leaves the closure alone, and the
closure is the problem: the subgraph reachable from a median candidate root
on the booted Laravel corpus is 381 of 381 objects. The bullet is rewritten
to the prune.

**The trace writes nothing, so Y7's wrap rule is superseded.** Y7 has the
collector clearing a stamp whose epoch is not the current one "at the moment
it first touches the entity". The stamp is written by commit on the owning
thread and only read by the trace, which is what keeps an aborted collection
free of heap cost. The wrap clause is also useless where it was placed:
eager clearing fires only on contact, and the stamp that wraps is exactly the
one no trace touched for four epochs. The real backstop is that **acquittal
never clears the enrolment bit** — a proven-live root parks in a suspects
buffer with its bit set and is re-offered at epoch turnover — which turns
ring-mates matured apart, a wrapped stamp and a wrong dirty proposal from a
permanent miss into bounded floating garbage.

**Y12 clause 4 is narrowed, and the clause count corrected.** The text says
"Six clauses" and numbers seven. Clause 4 has the already-enrolled bit
"cleared after the root is walked"; the law of 2026-08-26 has every reduction
of state belonging to the owner on an exact reading. A dirty pass that walks
a root and clears its bit performs exactly the acquittal the law forbids, and
because enrolment is edge-triggered the ring is then unreachable garbage
forever. The bit is cleared only at death; a dirty reader marks the entry and
leaves the bit.

**Y14's non-wait clause retires with its reason.** "A thread that finds the
token taken does not wait" was argued from the handshake's deadlock, and the
amendment of 2026-08-26 deleted the handshake. A holder's in-line collection
is synchronous and needs nothing from the waiter, so a refused allocation
waits on a held claim by any holder but itself, then takes the claim and
collects. The claim carries a thread-local held flag, so a destructor
allocating inside its own thread's collection collects nothing rather than
waiting on itself.

**And `strategies.md` leaves the deletion list.** Edmond's deletion ruling
named `rc-walk`, `rc-trace` and the horizon. `model/gc/strategies.md` is not
a collector's document: it carries the store-barrier micro-operation contract
(`store_ptr` / `store_box` / `drop`), the safepoint duties including the log
reserve's refill, the non-moving constraint, and the arm/fire rule that Y14
cites as a correctness requirement — a store lowers the old value's count
before overwriting the pointer, and a collection firing in that window
subtracts one reference twice and frees a live object. Twenty-one documents
link it and fourteen of them survive the deletion. It is amended instead: the
`rc-trace` section and the two dead registry rows go, the registry lists
`rc-cycle` and `rc-satb`, and §2's counted-locals argument is re-attributed
from `rc-walk` to `rc-cycle`.

**The teardown's order is written here before the old collector's document
goes.** `model/weak-references.md`, "Cycle death", binds the drain to null
every confirmed member's weak cell after the exact test passes and before any
user code runs, and names `gc/rc-walk.md` as the obligation's source.
`rc-cycle.md` does not restate it, and the deletion would take the only
written form of an ordering whose violation hands a destructor a strong
reference to a severed object. `rc-cycle.md` gains a "Cycle teardown"
section, transcribed against the running `drain_confirmed` before the code is
removed, and `weak-references.md` repoints to it.

## 2026-08-26 — a local reference always carries a counted `+1`, so the trace's only error is staleness

Ruled by Edmond, closing the question this session left open.

**Decided:** an entity named by a local variable, or held anywhere on the
stack, carries a counted `+1`. The compiler guarantees it. A retain/release
pair may be elided only inside a region where no collection can fire — the
enclosed region contains no call, no store, no release and no checkpoint, the
bound already recorded in `ll-model`'s `dev/DECISIONS.md` under the
always-provable elision rules — so an elision is invisible to the collector
rather than making a reference invisible to the counts.

**What it changes.** `rc-cycle.md` said the one source of trace error was that
"the counts do not see local references whose retain/release pairs the
compiler elided", and drew from it that soundness rests on the owner because
"only the owning thread sees its own stack". Both sentences described a
danger that the guarantee rules out. The one source of error is **staleness**:
a dirty pass may read a count that has changed since, and cannot read a count
that was never taken. Soundness still rests on the owner's exact judgement,
now for the plain reason that the owner re-reads current fields on its own
thread.

**Why the weaker form would not have done.** The bargain as the horizon wrote
it was "a pair may go where the compiler proves the referent outlives the
local". Under refcounting alone that is enough, because nothing frees an
object at a non-zero count. A cycle collector frees at a non-zero count, and
the covering reference may be an edge *inside* the component under judgement:
`$node = $ring->head` with the retain elided against `$ring->head`, then
`$ring = null`, leaves a ring the trace reads as internally balanced and a
`$node` pointing at freed memory. The counted `+1` is what closes it, and no
proof about lifetimes can substitute for it.
