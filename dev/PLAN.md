# PLAN

Updated: 2026-09-19 · Active: S8 — the clauses the build runs into first; S8.10 closed 2026-09-19 by Edmond's ruling, and the open steps are S8.4, S8.8 and S8.9

**Closed stages are deleted whole** (rule 23.1.3). S1 through S5 went on
2026-08-25, S6 and S7 on 2026-08-27; what survived each is in
`dev/DECISIONS.md` and in the question graphs, and a number is never reissued.
S10 went on 2026-09-06 without being closed: its subject moved to `amber`, and
the folder `hir/` went with it.

Destination, as amended 2026-09-06: the collector design of record is readable
here as a question graph.

**The 2026-09-03 destination is retired and its words are kept so the change is
visible:** "the design of record for the runtime and for the toolchain's
language-neutral layer is readable here — the collector as a question graph, and
HIR as a vocabulary in which every node names what lowers onto it and what it
lowers to". HIR is designed in `amber` from 2026-09-06 (`amber`,
`dev/DECISIONS.md`), so the half of the destination that named it is retired
together with stage S10 and the folder `hir/`.

**The 2026-08-23 destination is retired and its words are kept so the change is
visible:** "the collector design of record is readable here as a question
graph — thirty questions about the collector and the runtime, each with what
would answer it, bounded by Edmond's rulings". It named the collector alone,
which was the whole of the work then. `amber` was founded on 2026-09-03 to hold
HIR (`limelight-lang/php`, `dev/DECISIONS.md`, same date) and its design is
written here, so the file now carries a stage that does not touch the
collector.

**The old destination is retired and the words are kept so the change is
visible:** "the GC horizon algorithm is readable in this repository as a case
book — every entity kind and every event that can end a proof has its own
case". Edmond ruled the compiler's proof logic outside these documents on
2026-08-23, and the case book is written entirely in its vocabulary, so it
became a record and step S5.7 was dropped with it. The stages that built the
book — S1 through S5 — closed and were deleted whole on 2026-08-25 (rule
23.1.3); what survived each is in `dev/DECISIONS.md` and the question
graphs, and the audit that licensed the deletion moved the last two
survivors there first.

Structure agreed with Edmond 2026-08-20 after a Sage ruling on the layout and one
Critic round over the plan (22 findings, 4 critical; every finding is folded into
the steps below).

## Fog

- `model/memory/large-entities.md` is in force and still runs on `rc-walk`'s
  collection epoch — a per-epoch snapshot, a removal parking inside a collection
  epoch — and `model/gc/domains.md` uses the same word. The collector that
  defined that epoch was deleted on 2026-08-26 and the epoch in force is the
  maturation one, so the two documents describe a mechanism with no owner.
- The purity ladder's four open questions are carried in
  `model/gc/pure-destructors.md` as open items, unresolved in the code
  repository (`model/dev/design/pure-destructors.md` there).
- Two sentences are owed an amendment by the crate's ruling of 2026-09-13
  (`model`, `dev/DECISIONS.md`, "a survivor cell the pool cannot supply severs
  the edge, and the reset finishes"): `runtime/exceptions.md`'s gap paragraph,
  which says the reset fixpoint's working memory "is funded by none of the
  three reserves" and that "finishes the reset" assumes it is available, and
  the promise that a reset promotes the whole reachable subgraph of a survivor.
  The first becomes the arena's own memory with the roots' cells in the escapee
  records; the second gains the severed edge as its exception.
- Closure and fiber/generator layouts are unspecified anywhere in this
  repository. The case book that reported the holes went with the horizon on
  2026-08-26; the holes did not.

## S8 — The open clauses `rc-cycle` cannot be built without

Goal: every clause the first line of `rc-cycle`'s code would run into is closed
or owned, so the build stops at code nobody has written rather than at a
decision nobody took.

Done when: `cycle/questions.md` Y12 names an owner and a mechanism for clauses 3
and 8, clause 2 states what the queue's writer and its swapper agree on, no
clause leaves the spent-reserve case to the reader, `rc-cycle.md`'s teardown
order names the instant a collection's blocks return, `classes.md` carries a
declared target per pointer slot, Y9 states who advances the epoch counter and
how it is counted, and the gate ruling's premise about `ll-model`'s collecting
flag is verified or the ruling is amended.

The first four are what survived stage S6 and the rulings of 2026-08-27, each
recorded in a journal and owned by no step, which is what rule 23.1.2а forbids.
S8.5 through S8.8 are what the two rulings of 2026-08-27 left behind — the
boundary one of them refused to cross, the ordering obligation it created, the
clause whose swap their mechanisms gave a chain and a third writer, and the
counter one of them gave a reader and no writer discipline — and they are here
for the same reason. S8.11 is the relayout that closes the audit's A1 on
2026-09-14 (`dev/DECISIONS.md`, "A1 closes on a discriminating word"): the
documents state the encoding the ruling fixed, so that the crate's stage has a
normative table to follow rather than a decision entry.

- [x] S8.1 Verify that `ll-model`'s collecting flag is per-thread
      done: the flag the entry gate reads is named in `ll-model`, its scope is
        read from the source rather than assumed, and either `dev/DECISIONS.md`
        records that the premise holds or a new entry amends the gate ruling to
        say what the gate reads instead
      tier: T1 · role: —
      handoff: the ruling of 2026-08-27, "the entry gate reads this thread's own
        state and never the trace token", names this as its one new obligation.
        A flag spelled as a global "a collection is running" bit reproduces the
        rejected reading without naming the token: every trace in flight would
        close every allocator's gate, and the thread that most needs memory
        would skip the collection that could free it.
      handoff: closed 2026-08-27. The premise holds for the shape the crate had
        and for nothing in the tree: `gc::GC_ACTIVE`, `gc::TEARDOWN_DEPTH`,
        `epoch::TEARDOWN_DEPTH` and `walk::WALK_ACTIVE` were all `thread_local!`
        cells, and all four went with the two collectors on 2026-08-26. The
        obligation moves to the step that rebuilds the guard rather than
        closing.
      handoff: the trap is the spelling. `GC_ACTIVE`'s comment reads "True while
        a collection is running", a sentence with no thread in it over storage
        that is per-thread — a reader checking the premise against the comment
        answers wrongly in both directions, and only the declaration settles it.
- [x] S8.2 Decide who pre-allocates the spare queue buffer, and how it is
      replenished
      done: choice and reason in `dev/DECISIONS.md`, and Y12 clause 3 states
        the mechanism rather than the question
      tier: T2 · role: Sage
      handoff: open since S6.4 wrote the contract, and on the critical path
        since 2026-08-27: a trace consumes a spare of its own, because the
        token holder swaps a thread's live buffer out in order to trace it, in
        the in-line form as well as under the accelerator. The overflow path
        may not call the allocator, so somebody else allocates — the reader, or
        the thread at a checkpoint — and the choice decides what a failed
        replenishment costs.
      Sage 2026-08-27: each consumer provisions its own swap, the either/or of
        the question being right for one consumer each. The owner keeps two
        spare segments in two pointer cells, filled at thread init and at every
        safepoint poll through the ordinary allocation path, because at a non-final
        decrement no reader exists to have provisioned anything; the token
        holder takes the trace's spare through its own ordinary allocation path at the
        swap, standing at no hot path. Accepted on the question asked; the
        terminal tier at the spent reserve, which the ruling volunteered, was
        refused and became S8.5. Final on clause 3.
      handoff: closed 2026-08-27. Y12 clause 3 is rewritten in the indicative
        and the node's header says so; `model/memory/critical-reserve.md`'s
        queue paragraph and `model/gc/rc-cycle.md`'s "Concurrency" carry the
        halves that touch them; the ruling and both refused alternatives are the
        top entry of `dev/DECISIONS.md`. A segment is one 64 KiB pool block,
        which is what lets either allocation path fund one.
      handoff: what it hands the crate. `model/PLAN.md` S34.1 can be built
        against its allocation counter, the overflow being a cell swap and the
        backstop a fixed-array pop. Three obligations come with it: the queue's
        return paths join the critical reserve's return as callers,
        `ll_thread_exit` drains the inbox and the queue beside the reserves, and
        the exhausted-reserve tier needs a forced-failure test naming which allocation path
        refused once S8.5 says what that tier is.
- [x] S8.3 Decide where the suspects buffer lives
      done: choice and reason in `dev/DECISIONS.md`, and Y12 clause 8 says
        whether it is one per thread like the queue, who re-offers from it and
        at what instant
      tier: T2 · role: Sage
      handoff: clause 8 was written on 2026-08-27 as the second half of the
        backstop — an acquitted root keeps its enrolment bit, so without a
        re-offer no decrement can ever enrol it again. The obligation is
        stated; the residence is not. YRC's own suspects buffer is priced at
        56 % of captures removed (Y9), which prices the economy and not this.
      Sage 2026-08-27: one per mutator thread beside its queue, owner-written
        and owner-read, because acquittal is the owner's exact reading on the
        owner's thread and the re-offer is a write into the queue, whose one
        writer is the owner. The instant is the owner's safepoint poll, not its
        next judgement: a thread whose only garbage is a parked ring presents an
        empty queue and would never reach a judgement. Accepted. Final.
      handoff: closed 2026-08-27. Y12 clause 8 is rewritten in the indicative,
        the node header says clauses 3 and 8 are ruled, `model/gc/rc-cycle.md`
        carries the four-way disposition at the pickup and the parked corpse's
        window, `model/memory/critical-reserve.md` records that the buffer is no
        fourth customer, and the ruling is the top entry of `dev/DECISIONS.md`.
      handoff: the ruling had to name what an epoch is, so Y9 gains it: the
        counter is process-global and full-width, a commit advances it every N
        collections, the epoch field of the header's four-bit maturation stamp
        takes its low two bits, and a thread compares against a full-width
        mirror so a wrap hides no turnover.
        `N` joins the promote bound `k` as an open dial; YRC's 64 and 3 are the
        only known values of either.
      correction 2026-09-10: Y12 clause 8 no longer promises a whole-segment
        splice at re-offer. The built queue has one fill bound per lane, so a
        deferred partial head cannot lawfully become an interior segment. The
        normative form is the bounded merge of the deferred lane into the
        active one at the poll, and with it three rules the built path carries:
        the mirror is the commit count the reading itself saw, the deferral
        retires completed deaths on the way in, and a bounded pressure round
        defers nothing. One registered entity remains one token throughout.
        `model/PLAN.md` S37.4 is built to this text.
      handoff: the retention this buys is the widest in the design and was
        accepted rather than solved — a suspect that dies while parked keeps its
        slot, and the slot's block, until the next turnover or an in-line
        sweep. `model/PLAN.md` S34.2 gets its mechanism from this: force the
        counter forward through a `#[cfg(test)]` shorthand, run the poll, run a
        collection, and assert the stale-acquitted ring reclaimed.
      handoff: the ruling adds a third per-thread chain, so the exit obligation
        S8.2 handed the crate grows with it: `ll_thread_exit` drains the
        suspects buffer beside the inbox, the queue and the overflow buffer
        (2026-08-28). Its entries hold their
        enrolment bits set and, by this ruling, hold slots and blocks parked, so
        a thread that exits without draining it parks them for the life of the
        process.
- [ ] S8.4 Give the class descriptor a declared target per pointer slot
      done: `classes.md` carries, per pointer slot, at minimum a three-way tag
        separating class, string and array, and for the class case a pointer or
        link-time id, so a class's own slots can be examined; Y3's "what
        remains" paragraph states the field rather than owing it
      tier: T2 · role: —
      handoff: what S6.3 turned out to owe, recorded in Y3 and in the
        eighteenth `dev/DECISIONS.md` entry of 2026-08-25, owned by no step
        since. The class filter of Y3 cannot be written without it:
        `SlotKind`'s `Pointer` variant covers a declared class type, a `string`
        and an `array` in one code, and `PropSlot` carries no target, so the
        evaluable form demotes 0 of 114 classes with live instances.
- [x] S8.5 Decide what an overflow does when the critical reserve is spent too
      done: `dev/DECISIONS.md` records the boundary and Y12 states it, so no
        clause leaves the spent-reserve case to the reader
      tier: T2 · role: —
      handoff: put to Edmond rather than to a Sage, because it reverses his own
        ruling. The Sage of 2026-08-27 ruled a terminal tier — clear the bit the
        enrolment had just set, record the root as a known leak, arm
        memory-exhausted — and it was not adopted: it reinstates for candidate
        roots the drop-as-known-leak licence of `runtime/exceptions.md` that the
        thirteenth ruling of 2026-08-25 overrode for them by name.
      handoff: the second defect is the record channel. `ll-model` compiles the
        journal's record sites away without the `debug-journal` feature, which
        is off by default, so in any ordinary build "recorded as a known leak"
        is a silent permanent miss of exactly the class Y6 refuses. Whatever
        tier is chosen needs a channel compiled into the default build, or it
        needs to say that the miss is silent.
      Edmond 2026-08-28: nothing may be lost. When memory is exhausted the
        mutator thread either goes into collection itself or waits for the
        collector to free memory. The terminal tier is refused with the rest,
        and the question of a record channel goes with it — there is nothing to
        record.
      Sage 2026-08-28: the ruling states the outcome, so the mechanism was
        ruled beside it. Enrolment becomes unfailable — an overflow buffer, a fixed
        array in the thread's own queue below the reserve — and the thread
        never stops inside `ll_release`, which is unsound mid-mutation by
        Y14's own stale-edge argument. Both of Edmond's arms run at the next
        poll, behind the entry gate; a closed gate neither collects nor waits,
        the entries being safe in the overflow buffer. Final.
      Sage 2026-08-28 round 2: the consolidation pass found the overflow buffer's sizing
        argument false for one shape — `ll_release_vector`, a runtime-owned loop
        over a caller-supplied count with no poll inside it, which a container
        clear drives — so a large clear reached the abort with memory free. The
        loop that broke the bound takes the bound: it polls on its own backedge
        every half-buffer of registrations, and the backedge is a legal trigger point under a
        precondition `bulk-operations.md` now states. Three sentences of the
        first ruling are withdrawn, the token wait's identification with
        Edmond's second arm among them. Final.
      handoff: closed 2026-08-28. Y12 clause 3 carries the overflow buffer and clause 6
        its floor, Y14 carries the poll-side sequence, `model/gc/rc-cycle.md`
        and `model/memory/critical-reserve.md` carry their halves, and
        `runtime/exceptions.md` moves `ll_release` from refusable to funded —
        the refusable category losing its only member and keeping its name.
      handoff: the second round costs the crate one more thing, and it is a
        present defect rather than a future one: without the backedge poll a
        clear of some ninety thousand shared elements aborts with memory free,
        because nothing refills the two cells or the reserve's eight blocks
        mid-run. `model/PLAN.md` S34.7 is that repair.
      handoff: what it costs the crate. `model/PLAN.md` S34.1 shipped the
        forbidden branch — it undoes the enrolled bit and loses the edge — so
        the replacement is owed there: the overflow buffer, an infallible `enrol`, the
        poll's overflow buffer drain, and the deletion of the undo. The overflow buffer is 8160
        entries, 65 280 bytes of thread-local per thread, sized on clause 3's
        own poll argument and deliberately extravagant until the ABI writes its
        poll bound down.
      handoff: *(figures amended 2026-09-04.)* The built overflow buffer holds
        **8,152** entries, not 8160: it stands in the base block's
        65,280-byte payload behind the 64 bytes of the owner's queue state, and
        `POLL_STRIDE` is half of it, **4,076** (`ll-model`,
        `src/cycle/queue.rs`, `OVERFLOW_CAPACITY` and `POLL_STRIDE`). 8160 is a
        segment's capacity, which is the whole payload and remains right.
      handoff: *(storage amended 2026-08-28.)* Edmond moved the overflow buffer's
        storage into the allocator: one pool block issued at init, held for
        the life, its refusal the thread that never starts; the thread that
        skipped init draws lazily at first enrol, refusal aborts
        (`rfc/dev/DECISIONS.md`, "the baseline overflow segment is allocator-issued").
      handoff: *(record, superseded 2026-08-28.)* This line argued from
        `runtime/exceptions.md` filing `ll_release`'s candidate buffer under
        refusable work, and calling the resulting leak "still the right trade
        against killing the process". Edmond's ruling moved the row to funded
        and demoted those paragraphs to a record in that document, so the
        argument is kept for what it cost rather than for what it says.
- [x] S8.6 Decide when the shadow arena resets, against the teardown order
      done: `rc-cycle.md`'s teardown order names the instant a collection's
        blocks return, and says where the exact test's collection-private memory
        comes from once they have
      tier: T2 · role: Sage
      handoff: raised by the Sage of 2026-08-27 as the one ordering obligation
        its ruling creates. Returning the blocks at the token's release, before
        the first destructor, refills the reserve ahead of a teardown whose own
        destructors can overflow a queue. Against that, the exact test and the
        re-verify compute `IN` in collection-private memory drawn from the same
        reserve and run after the release, so one arena cannot serve both.
      handoff: half of this is now ruled and the other half is narrower than it
        looked. The 2026-08-28 ruling makes the arena's return at the token's
        release **required** rather than merely legal, because the enrolment's
        floor needs a teardown to meet a refilled reserve; `rc-cycle.md` and
        Y14 both say so. The **fund** the exact test draws from is already
        named — `dev/DECISIONS.md`, "The release obliges a readership rule, and
        the rule is what makes it legal", says
        collection-private memory from the collector's reserve, and
        `model/memory/critical-reserve.md` counts judgement among that
        reserve's customers. What is left is the **vehicle**: the arena is the
        only allocator that fund had, and it has gone back at the release, so
        what the exact test and the re-verify allocate through afterwards is
        unnamed.
      handoff: closed 2026-09-04 on Edmond's ruling of 2026-09-03, taken in
        `ll-model` and carried here; no Sage of this repository was called. The
        instant is not one instant. A collection off the poll keeps its rows
        through the teardown, which reads them directly and needs no member list
        or allocator at all; a collection an allocation failure started harvests
        the unreachable rows into a fixed region of the thread's workspace,
        returns every block, and runs the teardown off that region.
        `model/gc/rc-cycle.md`, "Concurrency", carries both, and
        `dev/DECISIONS.md` records the ruling.
      handoff: the token's release does not move with the arena. It still
        precedes the first destructor on both paths; what narrows is the
        readership rule, the owner reading its own rows after the release on the
        ordinary path while mark and scan stay the only writers. Whether a
        worker may acquire the token while an owner's teardown is still reading
        those rows is the accelerator's, and `ll-model`'s ruling leaves it
        there.
      handoff: what the held rows carry with them is stated in
        `model/gc/rc-cycle.md` beside the ruling — the teardown's frees wait for
        the window's close, the sever's non-final decrements register the live
        children of a member, so the detached chain is disposed of rather than
        restored, and a collection that cannot carry on ends itself and returns
        every block. All three are ruled in `ll-model` on 2026-09-03; what is
        not is the instant the window closes, which S36.7 builds.
- [x] S8.7 Decide what the queue's writer and the buffer's swapper agree on
      done: Y12 clause 2 states the agreement, so that an entry written while
        the chain is being detached lands in exactly one of the detached chain
        and the lane the writer keeps, and in neither twice, and so does a whole
        segment spliced onto the chain at a re-offer poll
        *(criterion amended 2026-09-04: the swap it named became a two-word
        detach, so there is no second buffer for an entry to land in)*
      tier: T2 · role: Sage
      handoff: clause 2 says the holder swaps the live buffer for a spare and
        traces the detached one, and clause 1 says the owner is the only
        writer. Neither says how the two agree at the instant of the swap. The
        second swapper arrived with the token ruling of 2026-08-27, which gave
        clause 2 its swap; what the clause-3 ruling of the same day added is the
        chain, so the two now agree on a link as well as on the live pointer,
        and the clause-8 ruling added a third writer of that chain — the
        re-offer splice at a poll.
      handoff: it does not block `model/PLAN.md` S34.1, which writes only the
        owner's side: the enrolment, the overflow swap and the in-line reader
        all run on the one thread, and that step's criterion is met by refusing
        a second reader by construction. What it blocks is the accelerator,
        where a second thread swaps the word for the first time.
      handoff: *(the swapper is a detacher, 2026-09-04.)* The swap this step was
        written against is gone: a collection moves two words, the head segment
        and its fill, leaves the write position empty and draws nothing
        (`dev/DECISIONS.md`, "the collection detaches the candidate chain and
        swaps nothing"; Y12 clause 2). The step stands, and its question is now
        narrower and sharper — the fill the detacher moves is a cell the writer
        is about to reset, so the two words are read while one of them may be
        written. `ll-model`'s queue states the same bound as a property of
        today's single mover rather than of the structure.
      Critic 2026-09-15: seven findings against the first draft, none against
        the linearization; the exit could return the block the outbox stood
        in under a worker's read, and "posted at the release" admitted a
        post into a freed inbox. The outbox moved beside the token, the post
        precedes the release, and the exit's final claim is never released;
        the offer gained the worker's request word as its arming, the closed
        gate its effect on pickup and offer, the refused trace its duty to
        post, and clause 3's two-cell count its third consumption. All in
        the entry.
      Consolidation reader 2026-09-15: eight findings of fact, all repaired —
        the record stated as existing (it is S38.5's first build), "touches
        only under the token" against the pre-claim load, Y5 still saying
        "at the release", clause 2's "gives its segments back" against the
        merge of clause 5 and `rc-cycle.md` (the review's Q9, standing since
        2026-09-09), the audit's two blocker lists, the one-release-instant
        rule unnamed as superseded for the exit, the Y12 heading, and the
        count of amended crate sentences.
      handoff: closed 2026-09-15. The writer and the detacher are one thread:
        the owner detaches at its poll on the worker's request and publishes
        one word to an outbox beside its token, the worker takes it under the
        token by an acquire exchange. `dev/DECISIONS.md`, "the owner detaches
        at its poll, and the worker takes the chain from a one-word outbox";
        Y12 clauses 2, 3 and 6 and Y14's poll sentence carry it;
        `rc-cycle.md`, "Worker-to-owner handoff"; `ALGORITHM-AUDIT.md` A2
        closed. `model/PLAN.md` S38.5 is unblocked and its criterion rewritten
        to the record, the request and the exit's final claim.
- [x] S8.12 Restore the queue's concurrent reader: written by the mutator, read behind it by the collector   *(before S8.8; reopens S8.7)*
      done: Y12 clause 2 states the single-producer single-consumer form
        Edmond designed and the entry of 2026-09-15 replaced without his
        ruling — the mutator only writes its queue: an entry, then the fill
        by a release store; the collector only reads it: entries up to an
        acquire-loaded fill by a cursor of its own, moving neither the head
        nor the fill and writing nothing into the queue; a consumed entry is
        consumed, so the owner neither merges, defers, drains nor retires
        inside the live queue — its dispositions work on what comes back;
        the proposal returns by a second queue of the same form in the other
        direction, written only by the collector and read only by the
        mutator; the in-line collection is the same consumer on the owner's
        own thread, the token being what keeps the consumer single; the
        growth's segment publication is stated as a producer-only act —
        evaluated against Lamport's SPSC queue, FastForward and `kfifo`;
        `dev/DECISIONS.md` carries the ruling and marks "the owner detaches
        at its poll, and the worker takes the chain from a one-word outbox"
        superseded, and names what of `ll-model` S38.5–S38.7 (the outbox,
        the offer, the pickup's walk-back) goes with it
      tier: T2 · role: Critic
      handoff: opened 2026-09-15 by Edmond's ruling in conversation: the
        queue was designed so that the mutator writes and the collector reads
        in parallel; a session's Decide step closed S8.7 by making the reader
        the owner's detach at its poll, considered no SPSC form, and never
        put the change of premise to him. The two-word tearing the entry
        argues from is a detacher's problem, not a reader's: a reader that
        moves nothing needs one release/acquire pair on the fill.
      progress 2026-09-15: the ruling is written — `dev/DECISIONS.md`, "the
        candidate queue is read behind its writer, and the collector's
        verdicts come back by a second ring"; `rc-cycle.md`, "Worker-to-owner
        handoff" rewritten, its "Concurrency" merge paragraph and exit
        citation amended; Y12's heading, clause 2 (restored), clause 3's
        two-cell count and spare replenishment, clause 5's merge, clause 8's
        parking and turnover, and "What is still open" amended; Y5's
        handshake paragraph, `strategies.md`'s mechanism list and
        `ALGORITHM-AUDIT.md` A2 amended.
      Critic 2026-09-15 round 1: eleven findings, all accepted — the in-line
        collection disposes after the token's release while the collector
        reads (a collecting word in the record); the ring is a FIFO and
        four disposition arms leave an entry standing (compaction in place
        at the close, the retirement pass in ring form); zero-count is a
        count read, not a death (retire on the completed-free bit, else
        write back); a two-word tail tears; P read only by the poll (every
        in-line collection reads it first); the index words' residence;
        post-then-advance; the re-offer's funding; two unnamed prices; the
        timer's signal; the criteria.
      Critic 2026-09-15 round 2: ten findings, all accepted — the per-root
        re-offer copy can abort in the overflow buffer at a pressure poll
        (a splice); a root past the budget blocks the ring for ever (the
        *unwalked* verdict, K halved and doubled); the segment the other
        side's index names must never be returned; withheld returns under
        the owner's own token; the collecting word's clear is the close's
        last release store; a record mandatory at init; P's write-back arm
        for every undisposed verdict; the offset word overflows (an entry
        index); the re-offer's arming retires with a living collector;
        S49.1 was four results. Then Edmond named the deployed queue in
        `~/true-async-server`, moodycamel's `ReaderWriterQueue`, and the
        ring took its exact form — a circle of blocks with per-block
        indices — which retired the packed word, the oldest-segment pointer
        and the return-behind-head rule.
      Critic 2026-09-15 round 3: eleven findings, all accepted — the
        compaction breaks the reference's "tail never goes backwards" and
        must rewrite the blocks' local copies; indices wrap modulo the
        capacity with a spare slot; the splice must move `tailBlock` to the
        last spliced block or the reader never enters them; P must not grow
        (the collector's link would race the owner's unlink); the teardown
        retirement reads P's prefix only; parked cases are a rule-4 dress
        (deleted with the mechanism); the splice belongs beside the ring
        and the shrink last; the collecting word is `COLLECTING` moved; the
        batch advance is three stores under one guard; K on the reader's
        line. The survey behind the adoption is `dev/SPSC-QUEUE-SURVEY.md`.
      handoff: closed 2026-09-15. The ruling and its three rounds are one
        entry, `dev/DECISIONS.md`, "the candidate queue is read behind its
        writer, and the collector's verdicts come back by a second ring";
        `rc-cycle.md`, "Worker-to-owner handoff" carries the mechanism; Y12
        clauses 2, 3, 5, 8 and its heading; `model/PLAN.md` S49 builds it in
        eight steps.
- [ ] S8.8 Decide how concurrent commits advance the epoch counter
      done: Y9 states who writes the process-global counter, how "every N
        collections" is counted when several owners commit at once, and what
        orders that write against the header stamps a commit writes on its own
        thread
      tier: T2 · role: Sage
      handoff: the clause-8 ruling of 2026-08-27 gave the counter its residence
        and its reader and left its writer undisciplined. Commits are not
        serialized: the trace token is released before any exact test, so
        several owner threads judge, tear down and commit at the same instant,
        and each of them stamps entities of its own on the epoch it reads.
- [ ] S8.9 Order a block's change of thread against the trace claim
      done: `model/gc/rc-cycle.md` states what happens when a block leaves its
        thread while a trace holds rows for it, so that neither a reissued slot
        nor a recommissioned block is read through a row array of the trace
        still running
      tier: T2 · role: Critic
      handoff: the one hazard the transfer rule does not close, found by the
        Critic round of 2026-08-29 and confirmed against `ll-model`:
        `Heap::abandon_all` nulls a block's owner at thread exit and pushes it,
        live objects and all, onto a process-global list; `Heap::adopt` gives it
        to another thread and allocates out of its surviving free list. No
        reference crosses a thread, so the ruling of 2026-08-29 does not reach
        it, and `src/cycle/row.rs` states the assumption it breaks: "the two
        readings could differ only if the block changed hands mid-trace, which
        the trace token forbids". A pool thread running one life per task makes
        this the ordinary path rather than an edge.
      handoff: the Sage of 2026-08-29 proposed ordering thread exit against the
        thread's own claim, which is bounded because the claim is never held
        across user code, and a claimable estate for blocks whose thread is
        gone — otherwise a cycle surviving its thread's exit is collectable by
        nobody. Both are proposals, neither is ruled.
      handoff: the first proposal was ruled by Edmond on 2026-09-04 and is
        carried into `model/gc/rc-cycle.md`, "Concurrency", and
        `dev/DECISIONS.md`: a thread waits for the trace, collects, retires its
        queue and only then hands its heap over, so neither `abandon_all` nor
        `adopt` runs under a live trace. That is the first clause of
        `dev/ALGORITHM-AUDIT.md` A4.
      handoff: the step stays open on the second clause. What the exiting
        thread's own collection could not take — a component whose destructor
        threw, or one a refusal ended — keeps its candidate bit, and once its
        blocks are adopted no thread will register it again. The estate that
        would collect it is refused until the accelerator exists and is
        revisited there against the measured residue, so today that residue is a
        bounded leak with no collector.
- [x] S8.10 Decide what a cross-thread reference is, and whether a cycle can run through one
      done: the documents name the form a reference takes when it reaches
        another thread, or state that none exists and that a cycle therefore
        cannot span two mutator threads; `rc-cycle.md`'s claim scope cites that
        answer rather than the transfer rule alone
      tier: T2 · role: —
      handoff: Edmond stated on 2026-08-29 that a cycle spanning two mutator
        threads arises in the general case, when a thread borrows another's
        object, and that the RFC describes the case. The vocabulary in force
        does not: `model/memory/static-lifetimes.md` makes a borrow frame-only,
        anything leaving a frame is stored and counted, `model/classes.md`'s
        transfer rule forbids a reference left behind, and the ruling of
        2026-08-26 gives every stack-held reference a counted `+1`. Three
        readings are open and the step is to pick one — the case is already
        closed by the transfer rule; the runtime will grow a form the documents
        have not written; or `ffi.md`'s `#[Borrow]` and `runtime/actors.md`'s
        shared object are that form and owe the collector a rule.
      handoff: it is the per-thread claim's own soundness that waits on this.
        The claim rests on no thread naming an entity in another thread's
        blocks; a cross-thread reference the trace follows would break it, and
        one it must not follow needs a written rule saying so.
      handoff: ruled by Edmond 2026-09-19, the first of the three readings — no
        reference names an entity in another thread's blocks, the compiler
        enforces it, and a cycle cannot span two mutator threads.
        `model/gc/rc-cycle.md`, "Concurrency" states it as the claim's premise;
        `dev/DECISIONS.md`, "no reference crosses a thread, and the compiler is
        what keeps it so"; `dev/ALGORITHM-AUDIT.md` records what of B3, B4 and
        C3 closes with it. The two residues are not references: a moved object's
        placement, and the actor's uncounted shared pointer.

- [x] S8.11 Write the discriminating word into the ValueBox's normative documents
      done: `model/values.md`, "ValueBox Layout" states the two arms of the +8
        word — the counted pointer with bit 0 clear, or the tag word with the
        flags byte at +8 (bit 0 fixed to 1, bit 1 undef) and the tag byte at
        +9 — with +0 the immediate value on one arm and the tag word on the
        other, `(0, 0)` as null, `(0, 0x0003)` as undef, the rule that the +8
        word alone decides the arm, the type tests by tag (a 16-bit compare on
        bytes +8..+9 for the four immediate tags, `(w8 & ~1) == 0` for null,
        the arm test and a 16-bit compare of +0 for a pointer tag), the undef
        test `w8 & 2`, and what the layout says of identity and no more (bit 0
        and the bytes above the tag byte are never the value; after a
        reference is followed, different tag bytes are never identical); the
        `refcounted` flag and bit 2 `writing` are gone from "Type tags" and
        the `satb.md` citation with them; `model/layouts.md`, "ValueBox" shows
        the new sample fillings and the WRITING-lock sentence names the
        discriminating word instead; `model/lowering.md` states the
        one-store-per-word rule for published slots a trace can read, the
        16-bit type test on a slot whose arm is unknown, and the
        `box_runs` skip on the +8 test, and narrows "no atomics needed" to
        the counts; `model/arrays-hashtable.md`, which places the link today,
        moves the hash entry's collision link to the top 32 bits of the arm's
        tag word and spells the table's null
        as `(0, 0x0001 | link << 32)`; `model/gc/rc-cycle.md`'s open-blocker
        sentence under "Speculative tracing and exact validation" cites the
        resolution, and "Concurrency" carries the publication clause (a
        release fence after the last building store and before the store
        that hands the address out, an acquire load on every load through
        which the worker obtains an address) and the deferral's contract (no memory a trace holds an
        address into is returned, recommissioned or unmapped before the
        token's release); `dev/tools/linkcheck.php` clean; `ll-model`'s
        `citations.py` unmoved, or every citation it moves repointed in the
        same sitting
      tier: T2 · role: Critic
      Critic 2026-09-14, first round over the written text: nine findings —
        the publication fence on the wrong side of the installing store, the
        factory sample stamping undef as a pointer-arm box, the whole-word
        type test failing on every hash element, "exactly one word has bit 0
        set" refuted by an odd integer, `===` silent on the pointer arm, the
        typed vector named for the mixed one, the typed-slot ReferenceBox's
        interior pointer read as an entity, stale flag wording and glossary
        terms, two silences (the key word and storage head under the
        one-store rule; endianness). Six repaired from the sources, three to
        the Sage.
      Sage 2026-09-14, `Final`: the fence stands after the last building store
        and before the handing-out store, one per construction event, with an
        acquire on every address-obtaining load including the detached chain;
        the layout owns of identity only which bits are never the value and
        that different tag bytes are never identical after a reference is
        followed — `===` per tag is an operators' document's, owed; the typed
        slot reference is a ring-closing kind of its own, and a trace reads
        its `owner` and never its `slot`.
      Critic 2026-09-14, second round: six findings, every one refutable and
        repaired — the 16-bit test is the four immediate tags' only, null is
        `(w8 & ~1) == 0` and pointer tags test +0 after the arm; null keeps
        two spellings and no read normalizes; the identity sentence takes the
        reference qualifier; the typed slot reference takes a free reserve
        code because the mutator's flag half is full; the one-store rule gains
        the strategy tag and counts, and the count-versus-element order is
        S38.0's; the undef test is `w8 & 2`, one instruction, written where
        it happens.
      consolidation 2026-09-14: four citations corrected (`set_storage` is the
        installing store, not a building one; the eligibility paragraph cited
        for its converse; `slot` is not 8-aligned for a `bool`; 8-alignment
        sourced to `refcount.rs` and `maps.md`), five cross-document
        mismatches aligned; `linkcheck.php` 649 links clean; `ll-model`'s
        `citations.py` 602/6 unmoved.
      handoff: the ruling and the Critic round that shaped it are
        `dev/DECISIONS.md`, "A1 closes on a discriminating word"; the shipped
        precedents are `dev/CONCURRENT-SLOT-READS-SURVEY.md`. The crate's half
        — `Value` as two words with decode accessors, `write_value_slot`,
        `counted_box_cell`, `refcounted_in_meta_word`, `Entry::value()` and
        the link accessors, the fixtures that spell bits by hand, and the three
        gate benches (a mixed-arithmetic loop, a tag-only loop and a lookup
        bench with collisions) — is a stage in `ll-model`'s plan that
        opens after this step, since the code follows the document.
      handoff: `resource`'s arm is not this step's: the pointer arm is
        reserved for entities beginning with `RcHeader`, and whether a resource
        becomes one is `model/layouts.md`'s open question.
      handoff: the language's operators have no document. `values.md` now
        states only what the layout decides about identity — which bits are
        never part of the value, and that different tag bytes are never
        identical — and hands `===` per tag (integer equality, IEEE equality
        for `float`, object identity, string and array content, a reference's
        referent) to a document that does not exist yet; the same-pointer
        shortcut for strings and arrays is that document's to state. Owned by
        no step (the Sage's second round over this step, 2026-09-14).

## S9 — The vocabulary

Goal: every word these documents use as a term is a word the field already
uses for that thing, or is defined here as a new one on purpose.

Ordered by Edmond on 2026-08-29, after `door` was found to be a metaphor with
no entry anywhere defining it — 275 occurrences in 70 files across both
repositories, counted 2026-08-29 with `grep -rio` over `*.md` and `*.rs`. `escrow` is the
second of the same kind: a term from law for what allocator and collector
literature calls an overflow buffer. Both entered through a commit subject and
spread by agreement with the text already written. No review this project runs
looks at vocabulary — the consolidation pass checks citations, contradictions
and unsourced claims, and an invented term trips none of them.

- [ ] S9.1 Build the glossary
      done: `dev/GLOSSARY.md` separates canonical terms from deprecated and
        context-sensitive words; every term states what it denotes and its
        established equivalent, then carries an independently checkable
        keep/rename/project-specific verdict; every deprecated term has a
        literal replacement, and every project-specific verdict explains why
        no established term denotes the same thing
      tier: T2 · role: Critic
      progress 2026-09-01 — the glossary is structurally split and its
        candidate-age, lifecycle, FFI, hash-table and ownership entries were
        corrected after a Sage audit. It remains a draft: the active RFC set
        still has to be checked term by term, and the established-equivalent
        evidence and explicit verdicts restored, before this step closes.
      handoff: the audit reads the documents for words used as terms, which
        is wider than the words the documents define: `door`, `escrow` and
        `floor` are all used as if defined and none of them is.
      progress 2026-09-02 — rebuilt on `work/s9-1`: 92 canonical entries in
        nine tables, each with what it denotes, its established equivalent
        with a source, and a keep or project-specific verdict (12 of the
        latter, each with its reason); 45 deprecated rows, one sense and one
        literal replacement each; 20 context-sensitive words, each with the
        rule that selects the replacement. The four entries `model` S41.7
        waited on: storage a carry left in its source block is *promoted in
        place* (`PromotedInPlace`); the journal's thread without a ring is an
        *unjournaled thread* (`Window::Unjournaled`); `ResetWindow::escrow` is
        the *deferred increment* list and `credits` the *deferred decrement*
        list, `park_large` is a *deferred free* and `CORPSE_WALKS` counts
        walks over *torn-down entities*; the sweep-list sense of enrolment is
        *attachment to the touched list*, and the end-of-scan sweep is a
        *clear*. Every citation was checked against its heading by script, and
        `dev/tools/linkcheck.php` passes. Open: the Critic round.
      progress 2026-09-02, first Critic round — nine findings, all taken, two
        with a different remedy than proposed. Two of the four entries above
        change: storage a carry left in its source block is a *pinned payload*
        (`Pinned` replaces both `Refused` carry variants), because *promoted
        in place* is the entity's category rewrite in `rc-cycle.md` and
        `weak-references.md` and *pinned* is what `arena-reset.md`,
        `rc-cycle.md` and `retained::pin` already call the storage outcome;
        the journal's thread without a ring is a *never-journaled thread*
        (`Window::NeverJournaled`), because *unjournaled* also describes the
        closed thread whose records `Window::Lost` counts. The deferred
        increment, deferred decrement, deferred free and touched-list entries
        stand. Outside the four: *release-at-reset list* is canonical and
        *release log* deprecated; *carry*, *transfer* and *collision defense*
        have rows; crate paths read `ll-model/…`; five literature attributions
        were dropped or reworded, none of them checkable inside the
        repository. Now 96 canonical rows, 46
        deprecated, 20 context-sensitive, 13 project-specific. Open: the
        second Critic round.
- [ ] S9.2 Rewrite the documents and the crate to the glossary
      done: no document, identifier or test file name uses a word S9.1
        marked for rename; the renames land as one commit per repository;
        `dev/tools/linkcheck.php` is green after the pass
      tier: T2 · role: —
      handoff: the counts as of 2026-08-29, by the grep above — `door` 275 in
        70 files, `escrow` 189 in 19, test file names among them
        (`the_door_that_opens_after_a_refusal.rs`, `the_two_cow_doors.rs`).
        `ResetWindow::escrow` in `model/src/memory/reset_window.rs` names a
        different structure, deferred count corrections, and takes a
        different name from the queue's.
