# PLAN

Updated: 2026-08-20 · Active: S3

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
