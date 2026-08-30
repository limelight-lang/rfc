# PLAN

Updated: 2026-08-29 · Active: S8 — the clauses the build runs into first

**Closed stages are deleted whole** (rule 23.1.3). S1 through S5 went on
2026-08-25, S6 and S7 on 2026-08-27; what survived each is in
`dev/DECISIONS.md` and in the question graphs, and a number is never reissued.

Destination, as amended 2026-08-23: the collector design of record is
readable here as a question graph — thirty questions about the collector and
the runtime, each with what would answer it, bounded by Edmond's rulings.

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
for the same reason.

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
- [ ] S8.6 Decide when the shadow arena resets, against the teardown order
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
        named — `rc-cycle.md`, "The release obliges a readership rule", says
        collection-private memory from the collector's reserve, and
        `model/memory/critical-reserve.md` counts judgement among that
        reserve's customers. What is left is the **vehicle**: the arena is the
        only allocator that fund had, and it has gone back at the release, so
        what the exact test and the re-verify allocate through afterwards is
        unnamed.
- [ ] S8.7 Decide what the queue's writer and the buffer's swapper agree on
      done: Y12 clause 2 states the agreement, so that an entry written while
        the live buffer is being detached lands in exactly one of the two
        buffers and in neither twice, and so does a whole segment spliced onto
        the chain at a re-offer poll
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
- [ ] S8.10 Decide what a cross-thread reference is, and whether a cycle can run through one
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
      done: `dev/GLOSSARY.md` lists every word the RFC documents use as a
        term, and gives for each what it denotes, the established name for
        that thing in allocator and collector literature, and one of three
        verdicts — keep, rename to the established name, or define as new
        because the thing has no established name; the two words already
        known carry their replacements, `door` → the ordinary allocation
        path and a draw from the critical reserve, `escrow` → overflow
        buffer
      tier: T2 · role: Critic
      handoff: the audit reads the documents for words used as terms, which
        is wider than the words the documents define: `door`, `escrow` and
        `floor` are all used as if defined and none of them is.
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
