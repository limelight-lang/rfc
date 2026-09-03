# PLAN

Updated: 2026-09-03 · Active: S8 — the clauses the build runs into first; S10 — the HIR vocabulary

**Closed stages are deleted whole** (rule 23.1.3). S1 through S5 went on
2026-08-25, S6 and S7 on 2026-08-27; what survived each is in
`dev/DECISIONS.md` and in the question graphs, and a number is never reissued.

Destination, as amended 2026-09-03: the design of record for the runtime and
for the toolchain's language-neutral layer is readable here — the collector as a
question graph, and HIR as a vocabulary in which every node names what lowers
onto it and what it lowers to.

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

## S10 — The HIR vocabulary

Goal: a set of HIR nodes that Efen lowers onto, that PHP lowers onto as the
poorer case, and that a backend lowers further without inventing a runtime
`model` does not describe.

Done when: every node names the Efen construct that lowers onto it and the MLIR
construct it lowers to; every Efen abstraction carries a verdict on whether it
reaches HIR or is erased before it; and both cases of S10.7 are written without
adding a node.

Ordered by Edmond on 2026-09-03, when `amber` was founded to hold HIR. The
vocabulary is designed against Efen rather than against PHP: Efen is
PHP-compatible and strictly richer, so a set built for PHP first is one Efen
cannot use, while the reverse costs nothing.

- [ ] S10.1 Decide the shape of HIR
      done: `hir/shape.md` states whether HIR is a control-flow graph or a
        tree, what a unit is, and whether values are in SSA form, each with
        the rejected alternatives and the reason; one Efen function and one
        PHP function are written out by hand in the chosen shape
      tier: T2 · role: Critic
      progress 2026-09-03, from `efen/docs` — what the step already knows.
        HIR is a tree, not a graph: it keeps the flow of the language and
        drops the notation, so `if`, `switch`, loops, `try`, `guard` and
        `defer` stay nodes and no basic block appears. Names are already
        resolved: a name is a key into the symbol database, and a package and
        module are parts of that key rather than nodes. Sugar that collapses
        to one node, collected as the test of "no tie to syntax": the two
        parameter syntaxes (signature and `param` in the body), the
        paren-less statement call, named arguments, an omitted parameter list
        taken from the interface, and PHP's `elseif` chain and `array()`.
        `guard` does not collapse into `if` with a negation, because its
        binding scopes over the rest of the function.
      Held over 2026-09-03, at Edmond's word: which of those forms really are
        only notation. The test is one question — another way of writing the
        same abstraction, or a different abstraction — but the answers are not
        obvious. `|>` fixes an evaluation order as well as naming a call, and
        the PHP forms belong to the poorer language and prove nothing about
        Efen. Until that discussion happens this list is a candidate list, not
        a verdict.
- [ ] S10.2 Draw the erasure line — below HIR, not above it
      done: `hir/erasure.md` carries a row for every abstraction in
        `efen/docs` — contracts, typestate, refinement types, code regions,
        metafunctions, interfaces, classes, structs, strategies, ownership,
        effects — each saying how HIR holds it and what lowering does with it;
        an abstraction HIR cannot hold is marked so with the reason, and one
        whose row waits on another step is marked open and names that step
      tier: T2 · role: Critic
      Reframed 2026-09-03 on Edmond's ruling: HIR keeps the logical semantics
        of Efen whole, and only notation is dropped. The erasure line
        therefore runs between HIR and lowering, not between the frontend and
        HIR. A contract disappearing from the binary is not a contract
        disappearing from HIR. The step's old question — "reaches HIR or is
        erased before it" — was the wrong fork and is retired.
      progress 2026-09-03, from `meta/aspect.md` — an ordering constraint the
        step has to respect. An aspect adds methods, properties, contracts and
        interfaces to its target and changes how the compiler resolves an
        abstraction's components, so the member list of a class does not
        follow from its own source. HIR is therefore built after aspects are
        expanded, and the symbol database stores the expanded shape. This also
        names a large invalidation unit for the orchestrator: editing an
        aspect invalidates every class that uses it, as editing a module's
        `use` list invalidates every call in that module.
      progress 2026-09-03, what the step can write down, corrected the same
        day under the reframing above. Present in HIR and erased below it:
        contracts, and with them function signatures, which `functions.md`
        calls a kind of contract existing only at compile time. Superseded
        here: an earlier version of this line said contracts are erased and
        aspects absent from HIR. Aspects and decorators generate members, so
        the class HIR describes is the expanded one, and whether HIR also
        records that a member came from an aspect is the sharpest question the
        reframing creates. Present as themselves: interfaces, strategies, and
        the attributes of a declaration — `@packed` and
        `@bigEndian` mean nothing to HIR but the lowering needs them, so a
        declaration node carries its attributes untouched. A symbol record
        needs four visibility levels, one of them file-scoped: `public`,
        `internal`, `private`, `api`. The first exact row of this table comes
        from `compile-time/index.md` rather than from reasoning: metadata
        carries `markForRuntime(key)` and `isMarkedForRuntime(key)`, so
        metadata is erased below HIR unless it is marked to travel. Held:
        effects on a function
        (`fn f() in LoggerEffect`) — `context-and-effects.md` is unread.
      progress 2026-09-03, after the audit — representation-neutrality is a
        rule of the language and not only a choice of ours. The audit's
        §Решения после аудита puts the physical placement of objects and
        structs, and the layout of a union, in the compiler's hands with
        observable behaviour preserved. A verdict of "reaches HIR" therefore
        never carries a layout with it.
      progress 2026-09-03, a dependency edge that runs against the calls.
        `in X` is part of a function's signature and the compiler infers it
        along the call graph: `funcA` inherits the requirement `EnvA` because
        it calls `funcB`, and `isolated` is the attribute that cuts the edge.
        So the symbol database stores the required contexts of every function,
        the inference is interprocedural, and adding `%a` to a leaf changes
        the requirement set of every caller transitively and invalidates them
        all. The module context record grows with it: imports, the strategies
        a module `use`s, and the static effect binding of
        `with { Logger: FileLogger }` and `use MyApp with { … }` — one record,
        three kinds of content, one invalidation unit.
- [ ] S10.3 Decide the value model
      done: `hir/values.md` lists the value kinds, maps each to a construct in
        `model/values.md`, and shows PHP's dynamic value as one of them
      tier: T2 · role: Critic
- [ ] S10.4 Design generics in HIR
      done: `hir/generics.md` states the form of a type parameter, of a
        constraint and of an instantiation site; names where monomorphisation
        sits in the pass pipeline and makes every pass declare which side of
        that point it runs on; states the symbol record of a generic
        definition and the rule by which an instantiation becomes a symbol
        only when monomorphisation creates it; and states what the type of an
        expression inside a generic body is before substitution, and at which
        stage every type in HIR becomes determined
      tier: T2 · role: Critic
      Monomorphisation runs after HIR, not before — Edmond's ruling of
        2026-09-03. It analyses a generic body once instead of once per
        instantiation, and it leaves a backend that has generics of its own
        able to consume HIR unexpanded.
      HIR carries generic entities, so a type inside a generic body stays
        symbolic until substitution — Edmond, 2026-09-03, held over for its
        own discussion. Until that discussion happens, no other step may
        assume a type in HIR is concrete.
      Efen has two kinds of generic, one erased and one monomorphised, and
        `efen/docs/DOCUMENTATION-AUDIT.md` (2026-09-03, §Решения после
        аудита) rules how they are chosen: the compiler picks the strategy by
        default, the programmer may demand a particular one, and a demand the
        compiler cannot satisfy is a compile error. The kind is therefore not
        a property of the declaration, which settles the shape of this step:
        HIR carries a generic so that either outcome stays possible, and it
        carries the demand as a constraint the monomorphisation pass checks
        and can fail on.
- [ ] S10.5 Decide how HIR names what lies outside the function
      done: `hir/references.md` states the form of a reference to a symbol in
        another unit and the rule for a name resolved later; the case of a
        call that precedes its declaration is written out
      tier: T2 · role: Critic
- [ ] S10.6 Write the first operation set
      done: `hir/operations.md` lists every node with the Efen construct that
        lowers onto it and the MLIR construct it lowers to; a node missing
        either is marked open rather than shipped; and every method of the
        compile-time API in `efen/docs/efen/compile-time/index.md` is answered
        from the nodes, or the gap is written down
      tier: T2 · role: Critic
      progress 2026-09-03, `compile-time/index.md` — the declaration list
        already exists, written from the other side. That API is reflection
        plus builders over exactly the entities HIR must hold: `Module`,
        `Class`, `Interface`, `Struct`, `Aspect`, `Strategy`, `Method`,
        `Property`, `Type`, `Parameter`, `Attribute`, `Metadata`,
        `SourceLocation`, `CodeBlock`, `Expression`. It gives the step a
        sharper acceptance test than inventing nodes: a node earns its place
        when the matching call can be answered from it — `getOwnMethods`
        against `getMethods(inherited: true)` needs the inheritance edge,
        `hasGetter`/`getGetter` needs a computed property to keep its
        accessor, `getContracts` needs contracts present rather than erased.
        A source location is part of that contract and not a diagnostic
        convenience: `getSourceLocation()` is public API on a class, a method
        and a property. Compile-time code writes as well as reads —
        `ClassBuilder` adds methods, properties, interfaces and aspects and
        changes modifiers, while `Expression.call/literal/variable` and
        `CodeBlock.parse` construct expressions — so HIR is a structure user
        code reaches, not a private stage of a pipeline. Noted in passing and
        absent from the audit: `enum Visibility` here reads `Public, Private,
        Protected, Internal` while `functions.md` names `public, internal,
        private, api`.
      progress 2026-09-03, `compile-time/metafunctions.md` — a fragment of HIR
        is a value of the language. Efen has no raw code injection at all
        ("весь код проходит через inline closure"), which settles the audit's
        conflict 21 against `decorators.md`, and puts `CodeBlock.parse(code:
        String)` from `compile-time/index.md` in doubt, since parsing code
        from a string is that same raw injection. Generation goes through
        `InlineClosure`, and it is first class: a parameter (`code:
        InlineClosure`), a type with its own parameters and result (`body:
        inline (T, Int) -> Void`), callable inside another closure, and
        spliced into one with `$code`. So HIR must be representable as a
        typed, composable value, and a `meta fn` is a declaration kind beside
        `fn`. Hygiene is a guarantee rather than a convention: the closure
        cannot bind a name into the calling scope and cannot change a
        surrounding variable except through an explicit `var` parameter, so
        the node carries that guarantee and lowering has to keep it. Two
        parameter modes come with this: `comptime`, evaluated during
        compilation, and `var`, a mutable capture.
      progress 2026-09-03, from reading `efen/docs` — three findings the step
        starts from. A call has one node and three kinds of target: a concrete
        symbol, an interface method reached through a VTBL, and a contract
        requirement on a type parameter, which is a static call whose target
        monomorphisation supplies. Properties add no node: a computed property
        reads through the same node as a field, and `willSet`/`didSet` expand
        at lowering, because the declaration says which it is. Projection is a
        node of its own and is not a cast — a cast may convert, a projection
        guarantees the bytes stay put, and it is the mechanism by which a class
        is allocated in one allocator and initialised without a copy.
      progress 2026-09-03, second reading — strategies, structs, functions.
        A call has a fourth kind of target: an object from one place and a
        vtable from another, which is what a dynamic strategy applied with
        `using` produces. `using` is a node by the same test as `guard`: it
        changes the dispatch environment of a scope and nothing else
        reproduces it. A strategy assigned to a variable of interface type is
        a value of its own — a vtable with no receiver. Call arguments are
        bound to their parameters when they reach HIR and not flattened to
        positions — corrected 2026-09-03, the binding is meaning and the order
        of writing is notation — and they carry a spread marker for
        `sum(...nums)`. A default value stays with the parameter while the
        call records an absent argument, which settles the small fork below. Assigning a struct is one node with value semantics:
        copy-on-write is a guarantee of the language, and its machinery is
        inserted at lowering. Open, and small: whether a default parameter
        value is filled at the call site or held by the callee — the first
        duplicates an expression that may have effects, the second needs a
        notion of a missing argument.
      progress 2026-09-03, a unification to test before the node list is
        written. `memory/classes-internal.md` sketches the compiler's own view
        of a class: the method becomes `fn init(x, y) -> Self in Self`, so the
        receiver arrives through the same `in` notation that carries an effect
        in `fn f() in LoggerEffect`. If that holds, a method call, an effect
        and `using` are one mechanism — a context supplied to a call — and
        `using` is a context binding over a scope rather than a node about
        strategies. `context-and-effects.md` decides it, and the audit reports
        two TODOs and a muddled `without` in that file. The same document
        shows projections modelling the states of a half-built object (`Raw`,
        `NonInit`), which makes projection the compiler's own device for
        partial initialisation rather than only a user-facing feature.
        Reference kinds are three and belong in the type tree: `&T` read-only,
        `&mut T` read/write, `&out T` write-only.
      progress 2026-09-03, `context-and-effects.md` — the unification holds
        for scopes and not for the receiver. `with C { }`, `override C(…) { }`,
        `without { }` and `using s { }` all bind implementations over a scope
        and none of them is reducible to other nodes, so all four are nodes of
        one family. That the receiver arrives the same way stays a guess: only
        the internal-IR sketch writes `in Self`, and no normative document
        does. Reading through `%` is a node of its own, and not a field
        access: a context is not a variable of the function but is found in
        the environment a `with` bound further up. Resolution says which
        context and which member `%db` names, the node keeps saying "read
        `db` from `Environment`", and the choice between substituting an
        implementation (an effect declared as a contract) and a vtable lookup
        (one declared as an interface) belongs to lowering, like every other
        choice of representation. The file's own TODO sits on that split.
        Corrected 2026-09-03: an earlier line here said the compiler rewrites
        `%` before HIR. The document says it rewrites `%` into an explicit
        context access and says nothing about when.
- [ ] S10.7 Break the vocabulary on two cases
      done: `hir/cases.md` writes Efen's strategies and PHP's `&` references
        as sequences of S10.6 nodes and adds none; a case that needs a new
        node reopens S10.6 and names the node it asked for
      tier: T2 · role: Critic → Sage
