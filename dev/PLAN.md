# PLAN

Updated: 2026-08-22 · Active: S5

Destination, as amended 2026-08-23: the collector design of record is
readable here as a question graph — thirty questions about the collector and
the runtime, each with what would answer it, bounded by Edmond's rulings.

**The old destination is retired and the words are kept so the change is
visible:** "the GC horizon algorithm is readable in this repository as a case
book — every entity kind and every event that can end a proof has its own
case". Edmond ruled the compiler's proof logic outside these documents on
2026-08-23, and the case book is written entirely in its vocabulary, so it
became a record and step S5.7 was dropped with it. Steps S2.5, S3.1 and S3.2
built that book and stay closed; their work is the record.

Structure agreed with Edmond 2026-08-20 after a Sage ruling on the layout and one
Critic round over the plan (22 findings, 4 critical; every finding is folded into
the steps below).

## Fog

- The purity ladder's four open questions (`model/dev/design/pure-destructors.md`)
  are unresolved in the code repository; S1.3 carries them into the RFC as open
  items rather than answering them.
- Closure and fiber/generator layouts are unspecified anywhere in this repository,
  so two cases can only be hole reports (S2.3).
- ~~Section G, the proof side~~ — ruled out 2026-08-23: pairs on local
  references are removed where the compiler proves it safe, a horizon is
  where that proof stops, and both are the compiler's business. All
  seventeen nodes left the index; `gc-horizon.md` is bannered and
  `walk/README.md` no longer claims the proofs as an inheritance.
- What the same ruling does to the case book is the open one. Most of the
  sixteen cases of `model/gc/gc-horizon-cases/` are horizon shapes, and S5.7
  is written over them. Read the ruling against the book before starting
  that step, and say out loud what is left of it.
- Whether the economics and measurement-order sections belong in the RFC at all,
  or stay in the code repository as a working note — S1.1 keeps them with a
  revision pointer; the split is revisited if the corpus veto is exercised.

## S1 — GC horizon enters the RFC  [done]

Goal: the algorithm is an RFC document under its new name, the RFC sections it
contradicts are amended, and the instrument two of its horizon kinds depend on
exists here.
Done when: every step below is closed and `dev/tools/linkcheck.php` reports zero
broken links over the whole repository.

- [x] S1.0 Create this plan file and list it
      done: `dev/INDEX.md` carries a PLAN.md row; `dev/WORKFLOW.md` carries one
        line defining the tier/role vocabulary the step lines use; the code
        repository's `PLAN.md` carries a pointer line to this file
      tier: T1 · role: —
      handoff: rfc/dev/INDEX.md and WORKFLOW.md carry the plan and the
        tier/role vocabulary; the code repository's PLAN.md points here.
- [x] S1.1 Move the algorithm into `model/gc/gc-horizon.md`
      done: `grep -rli 'proof.horizon' .` over this repository returns only
        `dev/DECISIONS.md`, whose 2026-08-20 entry records the rename;
        over the code repository it returns only `dev/DECISIONS.md`,
        `docs/history/`, the three banner stubs and their inbound pointers;
        the moved document's prose citations are relative markdown links with
        anchors, and linkcheck reports zero broken over them; `model/gc/README.md`
        lists every `.md` in its directory (`ls` diffed against the list, which
        also closes the standing `drain-window.md` omission); `../README.md`'s
        document map gains the gc-horizon row; a DECISIONS entry in each
        repository records the rename and keeps the old name findable
      tier: T2 · role: Critic
      handoff: gc-horizon.md is revision 5 renamed, with five open questions
        7-11 added from the 2026-08-20 review; the three model-repo files are
        banner stubs; linkcheck is green at 1296 links, zero broken anchors.
        A stale link in retained-block-walk.md was fixed on the way.
- [x] S1.2 Amend the RFC sections the chain extension contradicts
      done: `grep -rn 'never qualifies' .` returns only `model/gc/gc-horizon.md`,
        which quotes the old rule while extending it, and the dated 2026-07-25
        entry in `dev/DECISIONS.md`, which is a record and is not rewritten; `model/memory/static-lifetimes.md` ("What may
        own a borrow"), `model/gc/rc-walk.md` ("Uncounted borrows", "What this
        design does not solve") and `model/gc/rc-walk-danger-cases.md` (DC5's
        mitigation sentence) state the chain rule with borrow-is-use and cite
        gc-horizon.md
      tier: T2 · role: Critic
      handoff: static-lifetimes.md gains "The chain rule, and the borrow as a
        use of its anchor"; rc-walk.md's uncounted-borrows bullet and DC5's
        mitigation sentence follow it. The old wording survives only in dated
        DECISIONS entries.
- [x] S1.3 Bring transitive purity into the RFC as `model/gc/pure-destructors.md`
      done: the P0/P1/P2/NR ladder and the transitive-purity closure are stated
        here with their four open questions as open items; the release horizon and
        the checkpoint condition in gc-horizon.md cite this document by anchor
        instead of a code-repository design note
      tier: T2 · role: Critic
      handoff: model/gc/pure-destructors.md carries the ladder, the transitive
        ruling, the five owner-bound races and the hand-off drain with its
        diagram; gc-horizon.md cites #purity-is-transitive rather than a
        design note.
- [x] S1.4 Write `model/gc/gc-horizon-states.md`
      done: every axis the algorithm reads or is constrained by is listed with its
        value set, its cardinality where finite, and the document that states it;
        memory category is among them; no row of the runtime non-changes table
        paraphrases a protocol another document states — the COW row cites
        `model/values.md` and asserts only that the lattice never decrements a COW
        holder's count; the three overview diagrams render; the product is stated
        last, through its collapses, with the COW ∧ unique intersection named as
        inconsistent rather than presented as three independent identities
      tier: T2 · role: Critic
      handoff: the product is 224 referent configurations, of which 8 admit an
        anchored borrow (4 if question 8 resolves against arena and immortal);
        derived by enumeration, not measured.

## S2 — The case book  [done]

Goal: sixteen cases, each readable alone, each naming what a test would assert and
whether that test can be built today.
Done when: every case file carries all nine template sections; each of entity kinds
0–6 has one primary case named in the README index; `closure.md`,
`unique-entity.md` and `destructor-bearing.md` are declared cross-cutting
properties of kind 0 with a boundary sentence against `object.md`; the coverage
table accounts for its bounded population with no unresolved row.

- [x] S2.1 The frame: `model/gc/gc-horizon-cases/README.md`
      done: the nine-section template is shown filled on `total(Cart)` in two
        lowerings — with and without a summary for `audit()`, the second being the
        no-horizon base case; a terminology note separates the design's "anchored
        borrow" from the `#[Borrow]` attribute and from `model/memory/ffi.md`'s
        "anchor"; the index leads with the owned base cases named once, so the six
        exclusion files read as one thing; every asserted behaviour in the
        template contract carries an inline citation to the section stating it
      tier: T2 · role: Critic
      handoff: the template is nine sections; the terminology note separates
        the anchored borrow from the #[Borrow] attribute and from ffi.md's
        anchor; five cases are marked buildable today.
- [x] S2.2 The nine entity cases
      done: object, array, string, weakref, reference-box, closure, ffi,
        unique-entity, destructor-bearing, each with all nine sections;
        `string.md` and `array.md` split the verdict by sub-mode (COW-eligible
        forms owned by the base case, non-COW forms not covered by it), and
        "frozen" appears only as a rejected-design pointer if at all;
        `weakref.md` states that a path through a cell's `target` is not a lawful
        anchor chain and records the missing base case as an open item;
        `closure.md` is a hole report — sections 2, 3 and 7 read "not determinable
        from the RFC as it stands", with the missing specification named
      tier: T2 · role: Critic
      handoff: written by four subagents in one pass, 188-260 lines each.
        weakref.md carries the uncounted target edge; closure.md is a hole
        report; unique-entity.md carries the COW-unique intersection.
- [x] S2.3 The seven event cases
      done: call, store, release, checkpoint, unwind, suspension, arena, each with
        all nine sections; `call.md` carries dynamic dispatch and reflection as
        its horizon rows, the loop/back-edge placement snippet, and the runtime
        entry-point boundary as an open item; `unwind.md`'s subject is the raise
        sites (unsummarized calls, COW-separating stores, migrating element
        writes, `new`), not the throwing calls; `arena.md` states that promotion
        is payment only in the GC-heap and long-lived categories and records the
        reset's destructor fixpoint as a user-code point outside the horizon list;
        `store.md` and `release.md` carry the category barrier's two directions;
        `suspension.md` is a hole report on the same terms as `closure.md`
      tier: T2 · role: Critic
      handoff: unwind.md is written over raise sites rather than throwing
        calls; arena.md found that the convention retains have the same
        category defect as promotion, which question 8 does not name.
- [x] S2.4 The coverage table
      done: DC0–DC5, F1–F9, scenarios 1–9, B1, A8 and review findings 1–11 are
        mapped row by row; `RC_WALK_CRITICAL_REVIEW.md` findings 1–10 are cited by
        section title with the reason a code-repository review is in scope; every
        fenced PHP block in `model/memory/static-lifetimes.md`, `model/values.md`,
        `model/weak-references.md`, `model/memory/ffi.md` and
        `model/memory/arenas.md` is cited by document and heading; other example
        families are excluded as named classes with one reason each
      tier: T1 · role: —
      handoff: coverage.md maps DC0-DC5, scenarios 1-9, F1-F9, B1, A8, review
        findings 1-11 and the critical review's ten, plus the six PHP-fenced
        examples; six families are excluded by class with a reason each.

- [x] S2.5 Map Edmond's PH1-PH35 into the case book
      done: every PH number in `model/gc/gc-horizon-cases/adversarial.md` is
        cited by the case that owns its shape, or listed in
        `gc-horizon-cases/coverage.md` as out of scope with a reason; every PH
        case that contradicts a case file is recorded as a finding rather than
        reconciled silently; PH shapes that name a hole the algorithm does not
        carry become numbered open questions in `model/gc/gc-horizon.md`
      tier: T2 · role: Critic
      Consolidation 2026-08-23: eight findings — the "seven" count counted
        questions and read as a count of shapes; three rows named a case file
        that cited no such number; question 18 attributed PH25's handle
        taxonomy to an ffi.md item that does not carry it and to the
        repository, which defines no such taxonomy; object.md applied the
        always-provable route to a convention pair; the generator-`finally`
        fact was stated three times with no source. Accepted whole.
      Critic 2026-08-23 round 1: thirteen findings. PH15 and PH28 were "no
        case" in the table and cited by the case files; the "no case" verdict
        carried three incompatible definitions; question 14 asserted a weak
        divergence neither lowering produces, since the drop-point policy
        drops a destructor-free class at last use in both; PH4's break does
        not compose with the round-4 bound on the always-provable set; PH5,
        PH6, PH16 and PH34 contradict case files and were recorded as
        additions; question 18 ignored ruling 7 of 2026-08-22; call.md stated
        the implicit-invoke rule in the unsound direction; question 17 adopted
        alone empties the free region. Accepted whole.
      Critic 2026-08-23 round 2: ten findings over round 1's fixes, and four
        of the fixes broke. Question 21 priced this design's pair with node
        A1, which measured a different pair — a store's retain of the new
        value and release of the displaced one, two foreign headers; the
        suspension finding argued from the branch in which the frame dies
        with the referent; the backtrace item prescribed a horizon on every
        may-throw call against `exceptions.md`'s "Arguments must not hold
        references"; the unique-entity item used the counterfactual section 2
        excludes; PH5's second disjunct and primary rule were quoted away;
        question 18 ended a chain in a heap field, which the chain rule
        forbids. Accepted whole. Two rounds, then the device is dropped.
      handoff: the mapping is `model/gc/gc-horizon-cases/coverage.md`,
        section "Edmond's adversarial cases": 35 rows, 8 of them "no case",
        9 recorded disagreements. Twenty shapes opened questions 14 to 21 of
        `model/gc/gc-horizon.md`. Thirteen case files cite their numbers and
        eleven carry a new open item. Linkcheck green at 1619 links.
        **No step owns questions 14 to 21** — they are the proof side's, and
        S5.4 resolves the walk's graph rather than this one; the debt is
        named here and its step is Edmond's to place.

## S3 — Review  [done]

Goal: the book survives two Critic rounds; what does not close goes to Sage.
Done when: both rounds are recorded in the role lines below, every finding is
fixed or refused with a reason, and any surviving dispute carries a Sage verdict
marked Final.

- [x] S3.1 Critic round 1, three lenses: soundness against the algorithm, coverage
      against the repository, readability against the stated purpose
      tier: T2 · role: Critic
      Critic 2026-08-23 round 1, three lenses, twenty-five findings, all
        accepted. **Soundness:** `unwind.md`'s subject was the reading the
        2026-08-22 ruling refused, so its lowering, pad sets and diagram
        asserted it; `checkpoint.md` placed the retain after a `new`, which
        is a raise site; `object.md` and `store.md` omitted the checkpoint
        kind a displacing store carries, which falsifies "both instructions
        disappear"; the states document's placement rule dropped the cycle
        condition, and as stated it retains once per iteration;
        `unique-entity.md` prescribed a base-case retain into a standing
        sentinel and attributed the shape to COW, which ruling 10 removed;
        `call.md`'s ⊥ for the loop-born borrow reads the placement bullet
        while the base case reads liveness; `weakref.md` taught its subject
        as an unruled hole against ruling 11; the cascade routed arena and
        immortal referents to OWNED on a solid edge while the arithmetic
        below it needs them anchorable. **Coverage:** the normative horizon
        list carried seven kinds while the book counts eight — suspension had
        no row; `arena.md` said the failure needs a fiber, which the widened
        question 8 denies, and said two categories where the test returns
        early on three; the model-checker exclusion ignored
        `rc-walk-model.md`'s own exception clause; the buildable list named
        five cases where ten carry a runtime premise; `string.md` missed the
        FFI borrowed view; `maps.md` was neither covered nor excluded; the
        lazy kind had no index row while holding four of the eight surviving
        configurations. **Readability:** four files restated the placement
        rule in its superseded form; the README's base-case list was short
        the weak-cell case; `object.md`'s diagram drew a materialization
        path its own open item says is unspecified; `store.md` pointed at
        the wrong section of itself.
      handoff: every finding is fixed. The horizon list gained the
        suspension row and the questions gained 22 (the loop-born borrow's
        two readings); `unwind.md` is rewritten over the ruled quantifier
        with the per-edge pad shape as its second listing; the placement
        rule is stated in one ruled form in five places; `weakref.md`,
        `unique-entity.md` and `arena.md` carry the 2026-08-22 rulings.
        Linkcheck green at 1664 links.
- [x] S3.2 Critic round 2 over round 1's fixes; unresolved findings to Sage
      tier: T2 · role: Critic → Sage
      Critic 2026-08-23 round 2: twelve findings over round 1's fixes,
        four of them breaking a fix. The checkpoint member round 1 added
        to a displacing store applies to every release that may reach
        zero, which makes the release row's purity lift false and puts
        `release.md` against `checkpoint.md`; `unwind.md`'s raise table
        excluded releases on a policy `exceptions.md` calls unsettled;
        `arena.md`'s two new routes both fail — nothing maintains a
        minimal RC on a long-lived entity and borrow-is-use holds a region
        object's count up; question 22 describes a test that cannot fail
        over strict SSA. The other eight were counting and citation
        defects and were fixed directly: the product is 448 and not 224,
        "two categories" survived in three more places, `string.md` cited
        the wrong section of `strings.md`, `weakref.md` §4 answered
        question 16 in passing, `unique-entity.md`'s snippet demoted its
        own subject.
      Sage 2026-08-23: four verdicts, all **Final**. (1) Every release that
        may reach zero carries a checkpoint member — dispose exists for
        any dying object and the pickup at its exit drains a verdict whose
        destructors belong to an unrelated component — so purity lifts the
        release row's own hazard and nothing else. (2) `unwind.md` may not
        exclude releases: the returned-error policy is unsettled and one
        of its named candidates raises in the dropping frame, so the row
        enters as a conditional raise site, fail-closed, and the policy
        stays `exceptions.md`'s to rule. (3) The arena failure is
        realizable in one frame only by the region route, under three
        conditions, with a snippet; the long-lived half is a hole until a
        reclamation strategy is chosen. (4) Question 22 is closed by
        replacement, the liveness reading winning: over strict SSA the
        test cannot fail for a non-phi borrow, and a loop-carried borrow
        is a loop-header phi the edge rule and PH15 already decide.
      handoff: all four verdicts executed. `gc-horizon.md` carries the
        checkpoint member in the release row and in the sound-configuration
        paragraph, question 8's single-frame shape, and question 22 struck
        with its ruling; `unwind.md` has the conditional raise-site row and
        an open item for the policy; `arena.md` open item 1 carries the
        region snippet and its three conditions; node G2 of
        `walk/questions.md` follows. Linkcheck green.

## S5 — The second design, refused; the counted walk is the design of record  [in progress]

Goal, as amended 2026-08-22: the capture-count regime is refused with its
reasons recorded, the counted walk is the design of record with its open
questions as a graph, and the work that follows is ranked against measurement
rather than against which text is newer. The stage keeps its number and its
closed steps; steps S5.4 onward were re-aimed the day the regime fell.
Done when: every step below is closed and `dev/tools/linkcheck.php` reports zero
broken links.

- [x] S5.1 Write the top level into `model/gc/gc-horizon-v2/`
      done: the folder carries a README marking it the current design and a
        `top-level.md` holding the problem, the three answers, the two prices,
        the three collector treatments, the header states, the unresolved-site
        rule and six open questions; `model/gc/README.md` lists the folder and
        `model/gc/gc-horizon.md` carries a banner pointing here; linkcheck green
      tier: T2 · role: —
- [x] S5.2 Find the prior art and place this design against it
      done: the family this design belongs to is named with citations —
        deferred reference counting, ulterior reference counting and their
        descendants at least — and each is compared on the four axes that
        matter here: who publishes a root, where it is published, who clears
        the publication, and what the mutator pays; any algorithm that already
        does publication-into-the-header with an ageing clear is named as such
        rather than as an analogue
      tier: T2 · role: —
      handoff: `model/gc/gc-horizon-v2/prior-art.md`. Three of the four
        mechanisms are known — deferred RC, URC's partition, Nim-style cursor
        elision — and the fourth, publishing roothood into the collected
        object's own header with the collector's stamp as the clearing
        operation, was not found in a bounded search of eight queries and six
        sources. Free-threaded CPython ships the same header flag for "who
        counts" and keeps a root registry for "who roots"; Pony ORCA matches
        the philosophy and avoids the question by collecting only when the
        actor's stack is empty. Extended the same day with Iso (PLDI 2025), a
        request-private collector whose premise is Limelight's own and whose
        DLG corollary — only the allocating thread can publish an object —
        answers the cross-regime edge question for actor-private entities;
        and with LXR's current status: still unmerged in MMTk, continued in
        the 2025 work-packets paper.
- [x] S5.3 Build the question graph
      done: `model/gc/gc-horizon-v2/questions.md` holds every open question of
        the second design as a node with what would answer it and what it
        blocks, a mermaid dependency graph over them, and the session's
        resolved nodes kept in place; the README lists it
      tier: T2 · role: —
      handoff: nine nodes A-I plus the economics gate Z. A is the root — does
        a deferred regime exist outside actor-private memory — and it bounds
        every node below.
- [ ] S5.4 Resolve the graph node by node, root first
      done: every node in `model/gc/walk/questions.md` carries either an
        answer with its argument, or a recorded reason for staying open;
        nodes whose answer changes another document are folded into it
        rather than left in the graph alone
      tier: T2 · role: Critic
      Critic 2026-08-22 round 1: the closures written for G3 and G4 both
        fail — a shared `finally` pad is reached from raise sites on both
        sides of the promotion (PH22 already asserts per-edge pad state);
        borrow-is-use puts the anchor *into* the pad's released set, not
        out of it; the trigger-set closure oscillates on the
        unique-crossing base case and misses release sites. Accepted whole,
        both nodes rewritten as open.
      Critic 2026-08-22 round 2: the rewrite's case analysis still
        overlapped, "every loop has a back-edge poll" is false for actor
        code and the poll-free strategies, "closest is the latest" was a
        silent ruling rather than a repair, and the third pad rule was
        dropped from the node's own list. Accepted whole; the placement
        bullet reverted and question 13 restated over both readings.
      Critic 2026-08-22 round 3: the four rulings taken to close G3 broke
        too — computing liveness over the normal graph alone releases a
        value the handler reads before the raise site; a horizon inside a
        `catch` is dominated by no promotion placed after the raise site,
        which is PH9's shape unanswered; a pad release runs `__destruct`
        and is a release like any other. Accepted whole. The node is
        `[partly ruled]`: the raise sites join the quantifier, which is
        the reading question 9 offered first and PH9 asserts, and the
        execute-once condition and the generator pads stay open. Three
        rounds, three broken closures — the node is not to be closed
        again without a shape nobody has attacked.
      Critic 2026-08-22 round 4 (D1, D5): the channel specification broke in
        five places — the collector's tail runs `ll_release`, whose death
        branch acks the handshake and whose outermost teardown exit picks
        up messages, so the collector thread is ungated; an uncounted
        hand-back matches none of the three pickup triggers; a counted one
        outliving its epoch falsifies the id invariant and makes the next
        walk read the displaced children as roots; the queue has no owner
        field; and `drain-window.md`'s third link is the one a hand-off
        rewrites. Accepted whole; both nodes are open and carry the
        constraints. D5's costs were overstated in both legs and the case
        for moving a P2 call is stronger than the attempt said.
      Critic 2026-08-22 round 5 (nine nodes closed by argument): eight broke.
        The placement rule needs the cycle condition *and* an edge rule for
        phis, and "a phi is an overwrite" was block-granular where PH20
        requires edge liveness. C1 picked parked volume, which is zero while
        nothing collects — a free parks only inside an epoch. C2's exemption
        is unsound against the synchronous collection, which enrols every
        GcHeap slot with no stamp test, and against block retirement. B5's
        abort returns no memory when it fires and leaves the next epoch
        parking more. E1's stamp half argued from a general heap that this
        memory model does not have. C4 priced rung 2 in mutator cycles where
        it costs epoch duration. D6 charged a kind branch a cell read's
        price. B6's numbers reproduced; its mechanism did not. Accepted
        whole; every one is open again with what the round established.
      Critic 2026-08-22 round 6 (the day's own work on C1, C2, B5, E1):
        six findings, all accepted. C2's exempt window is two epochs and
        not one — the first walk to meet an entity writes the current
        number, which the predicate also reads as exempt — so the probe
        that churned inside one epoch exercised half the predicate and its
        table was a floor. B5's stamp-residue objection does not follow
        from the corrected mechanism. C1 named `blocks_out` where the crate
        itself calls it the wrong instrument and keeps a better one. C2's
        mid-teardown leg rested on an occupancy test the teardown guard
        defeats. E1's stamped set was over-broad, and the prediction
        control covered one arm and one cell.
      Critic 2026-08-22 round 7 (over round 6's fixes): seven findings, all
        accepted. The abort has three firing points and the rewrite priced
        one of them; the exemption's free variable is the interval between
        walks rather than the epoch, which the probe had pinned at duty
        cycle one; the 76 % ceiling divides a live-entity stock by a parked
        rate and omits payloads freed by growth; `stamped_new` is a
        surviving-births meter and not an allocation rate; `used` is cheap
        because nothing outside the owner reads it, and it covers one of
        the four walked populations; E1's set still omitted the pooled
        large-entity blocks; and the benchmark's control sentence was false
        under every reading. Two rounds, then the device is dropped.
      handoff: state at the end of 2026-08-22. **Closed and holding:** A1,
        A5 (the width is not the lever; the prefetch is measured and
        unsettled), A7 (the discriminant is a bit of the retired condemned
        byte, which makes unique ownership rc-walk-only), B3, B4 (a cell
        costs the same in array storage as in an object body, so the walk's
        mass is edges), D2, D4, G1, G4 (COW outranks the uniqueness proof,
        Edmond), and the heap half of A6 (about 31 % of entities are
        strings, 1.4-1.6 counted edges per entity, 0.31 headerless
        companion records per entity, Laravel 13).
        **Open, and every one carries what a review round established
        rather than a guess:** A2-A4, A6's store side, A8, B1's share, B2,
        B5 (the abort's price now written per firing point), B6 (shape 1
        refuted by measurement, shape 2 priced at 8 tail blocks), C1 (two
        candidates eliminated, three named, threshold pending a real
        workload), C2 (the curve is measured against the walk interval;
        soundness open on two readers and on publishing the epoch number),
        C3, C4, D1, D3, D5, D6, E1-E3, G2, G3's generator half, G5-G9, H1. **The rule this stage taught:** every closure written by
        argument broke under review and every closure written by
        measurement held. Close by measurement where an instrument exists;
        where none does, write what would answer the node and stop.
- [~] S5.4a Measure what the mutator's confirming trace costs
      note: dropped with the capture-count regime, 2026-08-22 — the trace it
        was to price belonged to the deferred regime's finalise arm, and
        there is no such arm in the design of record.
- [x] S5.4b Measure what a counted store really costs when it misses
      done: a cold-mode canary for the `retain`/`release` pair, on the
        existing probe pattern, reports the pair's cost when the two foreign
        object headers it touches are out of cache, beside the hot figure of
        1.84-1.87 ns already recorded; the result is in the code repository's
        `dev/BENCHMARKS.md` with the machine named
      tier: T2 · role: —
      note: this single quantity moves the deferred regime's crossover
        against today's lowering by roughly a factor of forty
        (`gc-horizon-v2/questions.md`, N).
      handoff: measured 2026-08-22, recorded in the code repository's
        `dev/BENCHMARKS.md`. **The figures below are retracted in that file
        and superseded the same day** — the probe published every store
        into one slot, so the displaced header was warm where the retained
        one was cold. The standing figures are 2.9 ns with both foreign
        headers warm and 33 ns at a population of a million entities,
        median of six runs, spread 12 % at the wide end, and node N's
        ~80 ns estimate is high by a factor of 2.4
        (`model/gc/walk/questions.md`, A1). Retracted: 4.1 ns at a working
        set of one child and 88 ns at a million, median of eight runs.
        Probe:
        `memory::barrier::tests::what_a_counted_pair_costs_when_headers_miss`.
- [x] S5.5 Give the design of record one home
      done: `model/gc/walk/` carries the protocol and the proof side under
        one banner, or `gc-horizon.md` stays the proof-side text in force
        with `walk/` above it — Edmond's call; either way no document says
        `gc-horizon-v2/` is current, every inbound citation resolves, and
        linkcheck is green
      tier: T2 · role: Critic
      note: reversed on 2026-08-22. The step used to move the proof side
        *into* `gc-horizon-v2/`, which is now the refused regime.
      handoff: closed 2026-08-22 with the second option, which the
        documents already carried. `walk/README.md` says the design of
        record keeps the compiler proofs of `gc-horizon.md`, and
        `gc-horizon-v2/README.md` says that document is again the text in
        force for the proof side, `walk/` ruling where the two disagree.
        The proof side does not move: `gc-horizon.md` is the only text on
        its subject, so there are no two current documents to reduce to
        one. `rc-walk.md` is the old collector document and is left
        untouched, its COW-and-unique permission among the stale text. No
        document calls `gc-horizon-v2/` current — its two inbound
        citations reach `prior-art.md` as a record. Linkcheck green at
        1448 links.

- [x] S5.6 Two Critic rounds over the design of record, then Sage on what does not close
      done: both rounds are recorded here, every finding is fixed or refused
        with a reason, and any surviving dispute carries a Sage verdict marked
        Final
      tier: T2 · role: Critic → Sage
      Critic 2026-08-23 round 1, over `model/gc/walk/`: sixteen findings,
        none fixed yet. **Numbers.** `compiler-proofs.md` and `prior-art.md`
        both price the design at 88 ns, the figure node A1 retracted the day
        it was taken (2.9 ns warm, 33 ns at a million); worse, A1 measured an
        overwriting store's pair — two foreign headers — while this design
        elides one entity's retain and release, so the single-entity figure
        is a derived ~17 ns and nobody has written it down; A1's own "2.4 ns
        the hot figure suggested" is the 2.4× factor of node N transcribed
        into a nanosecond slot. A6's table counts array slots both as
        entities and as the counted edges out of them, so the string share
        is 38 % rather than 31 % under B1's and B4's own definition of a
        row. `prior-art.md` states arborescent GC's two words per object as
        fact where `gc-research.md` marks the number unverified.
        **Rulings against their own machinery.** Ruling 4 activates a mutator
        on a grown queue, ruling 2 forbids the push that would do it, and no
        node owns how a mutator is activated at all. Ruling 3's time ceiling
        bounds the arm that runs no user code and leaves unbounded the arm
        that does. Ruling 7's "the collector traces the wrapper as an
        ordinary entity" is refuted by question 18: nothing roots a wrapper
        the foreign side holds. **Nodes.** A5 refuses coalescing on "every
        loop has a back-edge poll", which round 2 of S5.4 already killed and
        which `rc-walk.md` and `strategies.md` deny; D6's proposed shape
        drops edges from `IN` alone, which makes every WeakMap value a root
        forever — a worse leak than the one it closes; A6 is four
        measurements under one number and one of them, the purity closure,
        has no node; A7, G4, B5 and C2 carry status lines their own bodies
        refute. **The graph.** B5 ⇄ C1 is a two-cycle, G7→G6 and G8→G6 point
        backwards, B1→C1 and B2→C1 are unsupported, B3, D2, D4 and G1 have
        no node, A7→A3 and A6→D6 are missing, G4 and F2 and H1 are isolated.
        Section G claims to carry the proof side and omits questions 14 to 21
        and the closure of 22. `compiler-proofs.md` §1 names four defeaters
        where the horizon list has eight kinds — the may-alias store, the
        suspension, the impure release and the draining checkpoint are all
        absent, so §1 reports a free region the in-force document forbids —
        and §3 describes a class-level proof where A3 is value-level and
        calls it weaker when it is stronger. C1 to C4 sit under section B's
        heading, G1 to G9 under section D's, E and F under H's.
      Round 1 fixed 2026-08-23, all sixteen. Nodes A9, D7 and G10 to G17 are
        new; the mermaid graph, the corpus figures and the section headings
        were rewritten; the attacks on rulings 3, 4 and 7 were recorded as
        nodes rather than executed, a ruling being Edmond's to amend.
      Critic 2026-08-23 round 2, over the fixes: fifteen findings, fourteen
        accepted whole and one corrected against the reviewer. **The heaviest
        three were repairs that broke worse than what they replaced.** D6's
        new shape judged a WeakMap key by `RC − IN > 0`, which
        `../rc-walk.md` defines as the *root* predicate, not reachability —
        a key held by an ordinary live array read as unreachable and its
        value was freed under a live `$map[$k]`; and neither home the node
        offers can run the corrected fixpoint, the drain's weak pass seeing
        only condemned components and Phase 4 recomputing in-degree from
        current fields. The attack on ruling 3 was wrong: a raw sever of one
        array with a million cells is one entity, so a count of entities
        bounds neither arm and the ruling's stated reason holds. Ruling 4 is
        implemented already — `OUTSTANDING_VERDICTS` non-zero is a pickup
        trigger — so D7 shrinks to the thread that reaches no checkpoint.
        Beside them: one derived figure covered three levers whose prices
        differ by an order (A2 one header touch, A3 two, A4 a warm pair), A9
        and `compiler-proofs.md` §5 asserted opposite things about P0's
        day-one population, and the declared-slot count of §3 proves a
        property about declaration sites where A3 is about run-time slots.
      Consolidation 2026-08-23, per `dev/WORKFLOW.md`: ten findings, and two
        of them overturn round 1 itself. **Round 1's finding 3 was wrong and
        had been executed.** `arraySlots` is a classifier holding the counted
        slots whose value is an array, exactly as `objectSlots` holds the 938
        slots pointing at 507 objects; cells inside arrays are `arrayElements`
        and were never in the entity total, so there was no double count and
        the recomputation was withdrawn whole — 31 %, 1.4-1.6, 0.31-0.32 and
        76 % restored, with the episode kept in the node because the same
        misreading is available to the next reader. What it did expose stands:
        the entity total uses `arraysWalked`, a counter the table does not
        print, so the total cannot be re-derived from the rows. **Round 1's
        finding 15 was also wrong**: the class-level form is necessary and not
        sufficient rather than the stronger obligation, and a counterexample
        is written beside it. The rest: question 12 stood open in
        `gc-horizon.md` while G9 called it closed, and it is struck there now;
        node M of the refused regime was cited as refusing a barriered move
        where the in-force source is question 4's ruling; the C1-C2 arrow was
        described and not drawn; F2 pointed at two closed nodes; and a
        ~28 MiB denominator with no source is withdrawn.
      No dispute survives to Sage. Both wrong findings were settled by
        reading the instrument's source rather than by argument, which is the
        rule S5.4 taught.
- [x] S5.8 Edmond's walkthrough of the question graph, 2026-08-23
      done: every verdict he gave is recorded where it changes a document in
        force, and the graph carries his scope ruling rather than an
        instrument's leftovers
      tier: T2 · role: —
      handoff: **the scope ruling is the largest of them.** This repository
        does not examine the compiler's proof logic; it is assumed to exist
        and to work. Five nodes left the index — the birth count,
        anchor-chain elision, clearing the COW flag, the purity closure and
        the acyclic class flag — kept in place under a fourth-level heading
        so the work behind them stays findable and no tool counts them open.
        `compiler-proofs.md` carries the same banner and is a record.
        A3 was recast as the one runtime replacement: **a uniquely owned
        entity is not collected, and what it holds is still walked.**
        **Three corrections to the protocol as this repository had written
        it.** The collector judges and suspects go to the mutator — one
        direction, and ruling 5 never asked for a return channel, which node
        D1's opening had attributed to it. Nobody is woken: a grown verdict
        queue makes the collector stop judging, and ruling 4 is rewritten
        over that. Ruling 8's collector-side destructor call is nearly
        unrealisable, the final judge being the mutator; D5 keeps the note
        rather than closing.
        **One node added, B7**, soft segregation by skippability: the
        allocator prefers a group and falls back anywhere, which would let
        the collector be told which blocks it need not walk. The group key is
        skippability rather than kind, so a class the compiler marks acyclic
        joins the strings. Three measurements would answer it and none is
        taken; the residue a block skip removes over an entity skip — the
        header read, the id-map entry and the count store, times 2 040 slots
        at size class 32 — is the whole of what it adds.
        **The walkthrough continued and took three more rulings.** The
        proof side went out whole — pairs on local references are removed
        where the compiler proves it safe, a horizon is where that proof
        stops, and both are the compiler's business, so section G's
        seventeen nodes left the index and `gc-horizon.md` is bannered. The
        case book followed it: all sixteen cases are written in the same
        vocabulary, so `gc-horizon-cases/` is a record and step S5.7 was
        dropped unexecuted. And **the mutator frees** — ruling 5 said the
        collector was the main freeing path and is rewritten over that,
        which closed the gap this line used to name and invalidated the
        hand-off drain of `pure-destructors.md`.
        **Two Sage verdicts closed what Edmond left as a variant.** Asked
        what the mutator does when the batch ceiling runs out with a group
        half freed, he offered leaving the remainder. The first verdict
        permitted that at two boundaries — between messages, and after the
        prologue before the sever — and refused any interior boundary; it
        also corrected the account, the drain being seven steps in code
        where `rc-walk.md` lists four, with the weak nulling before the
        destructors. Edmond then challenged the sever half, and the second
        verdict, on Fable, narrowed the first: **a split inside one entity
        is permitted at cell granularity**, which chooses D3's first
        candidate and gives ruling 3's ceiling its mechanism. Resurrection
        is closed on every managed channel and open on FFI alone (node
        G14). One stretch stays better where no pause budget binds: a
        million-cell array is 43-47 ms whole, about twenty thousand cells
        to a slice at a millisecond budget.
        **What it leaves open:** the epoch's completion bound, which a
        split lengthens; a kill variant for a synchronous collection
        meeting a paused drain's outstanding guards, now with two shapes to
        model; node G14; the cursor's home, waiting on D1; and the code,
        where no sever helper carries a cursor.
- [~] S5.7 Fold the outcome back into the case book
      **Dropped 2026-08-23**, with the case book itself. Edmond ruled the
        compiler's proof logic outside these documents, and every one of the
        sixteen cases is written in the vocabulary of borrows and horizons,
        so `model/gc/gc-horizon-cases/` became a record and this step lost
        its subject. Nothing of it was executed. What the step would have
        folded — the rulings of 2026-08-22 against the cases — is now folded
        only where a live document carries it, which is `walk/questions.md`.


## S4 — Code from the cases

Named, not broken into steps. The design is closed pending Phase D and its two
verification instruments — the shadow-count lowering and the differential
lowering — need a compiler that does not exist. What a case can produce today is a
runtime-side test in the code repository or a model-checker scenario, and the
checker carries a recorded protocol drift: `dev/tools/rc-walk/README.md` says both
specs model the pre-amendment protocol, while eager death is the premise of the
release horizon. So the re-derivation of the checker specs is a precondition of any
model-checker scenario, not an admissible instrument beside them. The cases whose
oracle is buildable today are marked in the README index; the rest say so in
section 8. Broken into steps when S3 closes.
