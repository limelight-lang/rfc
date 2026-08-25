# PLAN

Updated: 2026-08-25 · Active: S6

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

- The purity ladder's four open questions are carried in
  `model/gc/pure-destructors.md` as open items, unresolved in the code
  repository (`model/dev/design/pure-destructors.md` there).
- Closure and fiber/generator layouts are unspecified anywhere in this
  repository, so the case book's `closure.md` and `suspension.md`
  (`model/gc/gc-horizon-cases/`) are hole reports rather than cases.
- ~~Section G, the proof side~~ — ruled out 2026-08-23: pairs on local
  references are removed where the compiler proves it safe, a horizon is
  where that proof stops, and both are the compiler's business. All
  seventeen nodes left the index; `gc-horizon.md` is bannered and
  `walk/README.md` no longer claims the proofs as an inheritance.
- Whether the economics and measurement-order sections belong in the RFC at
  all, or stay in the code repository as a working note — `gc-horizon.md`
  keeps them with a revision pointer; the split is revisited if the corpus
  veto is exercised.

## S6 — `rc-cycle`: on-the-fly cycle collection from a mutator-fed candidate set  [in progress]

Goal, set by Edmond 2026-08-25: the collector's cost stops following the size
of the heap and starts following the size of what changed. The candidate set
comes from the mutator, and the classes that cannot hold a cycle leave the
set by proof. The stage opened under the words "over a sliding view", with
the view from a coalescing log; S6.1 refused the sliding view the same day,
and the view is the candidate set alone — the words are amended here so the
goal does not contradict the step that closed under it. The
design of record is [`../model/gc/rc-cycle.md`](../model/gc/rc-cycle.md) and
the work is built on its graph,
[`../model/gc/cycle/questions.md`](../model/gc/cycle/questions.md), node by
node, as S5 was built on the walk's.
Done when: every node of that graph carries an answer with its argument or a
recorded reason for staying open, and `dev/tools/linkcheck.php` reports zero
broken links.

- [x] S6.0 Name the design, banner what it supersedes, and seed the graph
      done: `model/gc/rc-cycle.md` and `model/gc/cycle/` exist, the registry
        and the `model/gc/` index carry `rc-cycle`, `rc-walk.md` and `walk/`
        are bannered as the text in force and a closed record rather than as
        work, and the graph holds the eight nodes the day's reading produced
      tier: T2 · role: —
      handoff: the premise is **not** verified — sliding views are a write
        barrier and `rc-walk` was built on the constraint that the mutator
        does no per-operation work for the collector. Node Y1 holds it and a
        reader was on the paper when the stage opened.
- [x] S6.1 Answer Y1: what the mutator pays per store, and whether a sliding
      view needs enumerated roots
      done: the paper is read and the node carries what the barrier executes
        in the common case, whether a thread must publish its local roots,
        and what either answer costs against `rc-walk`'s constraint
      tier: T2 · role: Critic
      handoff: **the sliding view is refused, on the paper's own reading.**
        All three constraints break on load-bearing parts: the write barrier
        *is* the snapshot, the fourth handshake suspends each thread and scans
        its stack while §4.2 differences the root set between collections, and
        the counts are reconstructed at a collection rather than maintained,
        so no instant exists at which the last reference was dropped. What
        `rc-cycle` takes instead is the candidate economy — the shadow count
        (Y4), maturation over rotating buffers (Y9, new), the acyclic-class
        filter, and one linear pass over all candidates — with the counts left
        alone. **Y2 narrows with it:** every design the survey found defers
        destructors because its *counting* is deferred; real counts keep prompt
        destruction for everything whose count reaches zero, and only cyclic
        garbage waits, as it does today. The Critic round is owed.
- [x] S6.2 Put Y2 to Edmond: may a destructor wait for the collection?
      done: his ruling is recorded in `dev/DECISIONS.md` and folded wherever a
        document in force states the `__destruct` promise
      tier: T2 · role: —
      handoff: ruled on the map (seventh entry): the destructor runs when
        death is established — zero count immediately, a cycle at its
        confirming collection — and the arena reset's own destructor pass is
        the backstop, so no document in force stated a promise that needed
        weakening. The same map round answered Y3, Y5, Y6, Y8, Y9, Y10 and
        Y11 (entries eight to twelve) and filed Y12 (root queue) and Y13
        (traversal aggression); all folded into `cycle/questions.md`.
- [ ] S6.3 Write the class filter of Y3 against the class descriptor
      done: the rule is written against `SlotKind` and the share of a real
        corpus's classes it demotes is measured with the recorded bootstrap
      tier: T2 · role: Critic
- [x] S6.4 Write the root queue's contract (Y12) against
      `zend_spsc_queue.{c,h}` in the `spsc-refactor` tree, read first-hand —
      the specification the header points to does not exist, so the header's
      CAS and growth figures are verified against the code
      done: Y12 carries the enrolment queue's contract — queue-per-thread
        ownership, the read side, the already-enrolled bit's position
        relative to the queue write, the growth rule of Y6, and the
        reserve-mode entry and exit of the thirteenth 2026-08-25 ruling
        (growth under OOM draws on the reserved critical area; normal mode
        resumes only after all roots are walked)
      tier: T2 · role: —
      handoff: read first-hand, and **the named candidate does not meet the
        contract**. Its top comment is wrong on three claims of four (no
        `fetch_add` anywhere, no CAS and no batch on the reader, the first
        overflow allocates at the same capacity), and three properties refuse
        enrolment outright: growth drops the root on allocation failure,
        growth runs on the mutator's thread inside a mutex and may copy the
        whole buffer, and a second reader crashes it — the case Y14 creates.
        Y12 now carries a six-clause contract instead; clause 3, who
        pre-allocates the spare buffer so the overflow path never calls the
        allocator, is the one part left open. Seventeenth `DECISIONS.md`
        entry.
- [ ] S6.5 Lay out the header under the no-growth rule (Y7)
      done: Y7 carries the split between the epoch byte and the freed index
        bits — epoch, maturation age, stamp-against-claim mark — with the
        one-store discipline argued for each field the collector reads
      tier: T2 · role: —
- [x] S6.6 Answer Y14: the collection the mutator runs itself under memory
      pressure, while no collector runs on another thread
      done: Y14 carries the trigger, the exclusion token and what holds it,
        the clean point the collection fires at against the arm/fire rule of
        `../model/gc/strategies.md`, where its own working memory comes from,
        and what it may not do on the allocating thread
      tier: T2 · role: Critic
      handoff: **the in-line collection is the synchronous form on the thread's
        own roots**, and that choice is what dissolves the hazards — no
        deferral window opens, so what it frees is recyclable at once; no
        handshake, the judge being the owner; no thread crossed, as the ladder
        requires. It narrows the tenth ruling rather than reversing it: the
        writer still never drains at a failed enrolment, which is mid-mutation
        and where the arm/fire rule forbids collecting. **The Critic round ran
        and its verification did not** — the session limit killed the verify
        pass, so the load-bearing findings were checked by hand against the
        code (the deferral window's only opener, `retire_empty`'s block return,
        the teardown gate) and the rest stand unverified. **One finding is
        Edmond's and blocks S6.5:** `CRC` has no address. Y4 orders a second
        count field, the eleventh ruling forbids the header growing, and the
        candidate index frees bits 16-31 of which the epoch byte holds 16-23 —
        eight bits, against a `u32` count. The off-heap side table of Y4 is
        recorded there as not chosen.

## S7 — retire `rc-walk` and the GC horizon  [blocked on S6 and on the build]

Ordered by Edmond 2026-08-25: when `rc-cycle` is finished, the old collector
and the horizon algorithm leave the repository and the crate — not under a
banner, not as records. **This reverses the document half of the twelfth
ruling of 2026-08-25**, which deleted code and kept documents as the record;
the reversal gets its own `DECISIONS.md` entry before the first file goes.

Nothing here starts before `rc-cycle` is in force. Each step is a checklist
rather than one commit, and `dev/tools/linkcheck.php` reports zero broken
links at the end of each.

- [ ] S7.1 Delete the `rc-walk` code from `ll-model`
      done: `src/walk.rs` and `src/walk/`, `src/collector.rs` and
        `src/collector/`, `src/epoch.rs`, the `rc-walk` Cargo feature with the
        24 files gated on it and the 13 carrying `not(feature = "rc-walk")`
        guards, and `dev/RC_WALK_CRITICAL_REVIEW.md` are gone; what `rc-cycle`
        inherits — the deferred-free parking, the handshake, the exact test —
        has moved rather than died, and the crate builds and tests green
        without the feature
      tier: T2 · role: Code Reviewer
- [ ] S7.2 Delete the `rc-walk` documents
      done: `model/gc/rc-walk.md`, `rc-walk-proof.md`, `rc-walk-model.md`,
        `rc-walk-states.md`, `rc-walk-danger-cases.md`, `rc-walk-review.md`,
        `model/gc/walk/`, `model/gc/retained-block-walk.md`,
        `dev/TASK-rc-walk-proof.md` and `dev/tools/rc-walk/` are gone, every
        inbound link is repointed or its paragraph went with it, and the
        verification debt of `model/gc/cycle/questions.md` names where the TLC
        battery's obligation now lives — it does not lapse with the battery
      tier: T2 · role: —
- [ ] S7.3 Delete the GC horizon documents
      done: `model/gc/gc-horizon.md`, `gc-horizon-states.md`,
        `gc-horizon-cases/`, `gc-horizon-v2/` and
        `model/gc/walk/compiler-proofs.md` are gone; the arguments that
        outlive them are moved first — the chain rule already sits in
        `model/memory/static-lifetimes.md`, and the count-elision bargain
        cited by Y11 and by the fourteenth ruling moves into `rc-cycle`'s own
        documents
      tier: T2 · role: —
