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

- [ ] S2.5 Map Edmond's PH1-PH35 into the case book
      done: every PH number in `model/gc/gc-horizon-cases/adversarial.md` is
        cited by the case that owns its shape, or listed in
        `gc-horizon-cases/coverage.md` as out of scope with a reason; every PH
        case that contradicts a case file is recorded as a finding rather than
        reconciled silently; PH shapes that name a hole the algorithm does not
        carry become numbered open questions in `model/gc/gc-horizon.md`
      tier: T2 · role: Critic

## S3 — Review  [in progress]

Goal: the book survives two Critic rounds; what does not close goes to Sage.
Done when: both rounds are recorded in the role lines below, every finding is
fixed or refused with a reason, and any surviving dispute carries a Sage verdict
marked Final.

- [ ] S3.1 Critic round 1, three lenses: soundness against the algorithm, coverage
      against the repository, readability against the stated purpose
      tier: T2 · role: Critic
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
      handoff: the graph moved to `model/gc/walk/questions.md` on 2026-08-22
        with the refusal of the capture-count regime. Eleven rulings bound
        it. Closed: A1 (measured), B3 (already built), D2, D4 and G1 (by
        rulings 10 and 11). B1's rate is measured and its share is corpus.
        Fifteen nodes open, three of them roots: A6 the corpus share, G7
        borrow scopes across suspensions, and the compiler-owed group.
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
        `dev/BENCHMARKS.md`. The overwriting store's pair costs 4.1 ns at a
        working set of one child and 88 ns at a million, median of eight
        runs; the spread at the wide end is a factor of seven, so the
        direction is settled and the magnitude is not. Node N's unmeasured
        ~80 ns estimate is inside the range and near its median. Probe:
        `memory::barrier::tests::what_a_counted_pair_costs_when_headers_miss`.
- [ ] S5.5 Give the design of record one home
      done: `model/gc/walk/` carries the protocol and the proof side under
        one banner, or `gc-horizon.md` stays the proof-side text in force
        with `walk/` above it — Edmond's call; either way no document says
        `gc-horizon-v2/` is current, every inbound citation resolves, and
        linkcheck is green
      tier: T2 · role: Critic
      note: reversed on 2026-08-22. The step used to move the proof side
        *into* `gc-horizon-v2/`, which is now the refused regime. The banner
        work is done — `gc-horizon.md` and `model/gc/README.md` name `walk/`
        as the design of record — and what is left is whether the proof side
        moves house.

- [ ] S5.6 Two Critic rounds over the design of record, then Sage on what does not close
      done: both rounds are recorded here, every finding is fixed or refused
        with a reason, and any surviving dispute carries a Sage verdict marked
        Final
      tier: T2 · role: Critic → Sage
- [ ] S5.7 Fold the outcome back into the case book
      done: each of the sixteen cases either states that the rulings of
        2026-08-22 leave it unchanged or carries the case's new shape under
        them — ruling 11 touches the weak-reference case directly — and the
        cases that cite `gc-horizon-v2/` as current are re-pointed
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
