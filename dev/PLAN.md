# PLAN

Updated: 2026-08-22 · Active: S5

Destination: the GC horizon algorithm is readable in this repository as a case
book — every entity kind and every event that can end a proof has its own case,
with the states it moves, a diagram, and the oracle a test would assert — so the
implementation work that follows reads cases instead of re-deriving the design.

Structure agreed with Edmond 2026-08-20 after a Sage ruling on the layout and one
Critic round over the plan (22 findings, 4 critical; every finding is folded into
the steps below).

## Fog

- The purity ladder's four open questions (`model/dev/design/pure-destructors.md`)
  are unresolved in the code repository; S1.3 carries them into the RFC as open
  items rather than answering them.
- Closure and fiber/generator layouts are unspecified anywhere in this repository,
  so two cases can only be hole reports (S2.3).
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

## S3 — Review  [in progress]

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
- [ ] S3.2 Critic round 2 over round 1's fixes; unresolved findings to Sage
      tier: T2 · role: Critic → Sage

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

- [ ] S5.6 Two Critic rounds over the design of record, then Sage on what does not close
      done: both rounds are recorded here, every finding is fixed or refused
        with a reason, and any surviving dispute carries a Sage verdict marked
        Final
      tier: T2 · role: Critic → Sage
- [ ] S5.7 Fold the outcome back into the case book
      done: each of the sixteen cases either states that the rulings of
        2026-08-22 leave it unchanged or carries the case's new shape under
        them — ruling 11 touches the weak-reference case directly, ruling 7
        the FFI case, and question 9's ruling `unwind.md`'s open item 1 — and
        the cases that cite `gc-horizon-v2/` as current are re-pointed;
        `model/gc/gc-horizon-cases/weakref.md` still calls the weak-cell
        base case missing, which ruling 11 supplied, and
        `model/gc/gc-horizon-states.md` is folded on the same terms,
        being the case book's state document without being a case
      tier: T2 · role: Critic

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
