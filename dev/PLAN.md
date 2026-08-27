# PLAN

Updated: 2026-08-27 · Active: S8 — the clauses the build runs into first

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
and 8, `classes.md` carries a declared target per pointer slot, and the gate
ruling's premise about `ll-model`'s collecting flag is verified or the ruling is
amended.

The four are what survived stage S6 and the rulings of 2026-08-27. Each was
recorded in a journal and owned by no step, which is what rule 23.1.2а forbids.

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
- [ ] S8.2 Decide who pre-allocates the spare queue buffer, and how it is
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
- [ ] S8.3 Decide where the suspects buffer lives
      done: choice and reason in `dev/DECISIONS.md`, and Y12 clause 8 says
        whether it is one per thread like the queue, who re-offers from it and
        at what instant
      tier: T2 · role: Sage
      handoff: clause 8 was written on 2026-08-27 as the second half of the
        backstop — an acquitted root keeps its enrolment bit, so without a
        re-offer no decrement can ever enrol it again. The obligation is
        stated; the residence is not. YRC's own suspects buffer is priced at
        56 % of captures removed (Y9), which prices the economy and not this.
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
