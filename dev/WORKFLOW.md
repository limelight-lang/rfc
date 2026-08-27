# Project workflow

How work is done in this repo. Not how the code is built
(ARCHITECTURE.md) nor what was decided (DECISIONS.md), but the order of
work that is the same for every task.

## Branches

- Work commits **directly to `main`**; no PR is required (confirmed
  2026-07-23).
- A side branch is optional for larger work: short kebab-case describing
  it (observed: `heap-perf-fix5`).
- `main` is the mainline; `origin/HEAD` points at it.

## Commits

- One line: `area: imperative summary`, lowercase area prefix and colon
  (observed: `model: resolve H3 (static-block teardown at thread exit)`,
  `backlog: defer H5 (graph-copy rollback)`).
- `area` is the touched surface: `model`, `gc`, `values`, `ffi`,
  `runtime`, `backlog`, `dev`, etc.
- Body only when the *why* is not obvious; no diff retelling.
- English (core rule 17).

## PR and merge

- No PR required. One commit per logical change lands on `main`.

## Versions

- Not applicable yet — design phase, no releases.

## Plan

- Work larger than one step goes through [PLAN.md](PLAN.md) before it starts.
  `## S<n>` heads a stage, `- [ ] S<n>.<m>` is a step, and a step carries three
  fields: `done:` — the condition that closes it, checkable by someone who did
  not write it; `tier:` — T0 cosmetic, T1 local change, T2 feature or refactor;
  `role:` — the reviewer the step gets.
- A question-graph node closes by measurement where an instrument exists;
  where none does, the node records what would answer it and stops. The
  rule is stage S5's lesson: every closure written by argument broke under
  review, and every closure written by measurement held.
- Two review roles, and `—` when a step gets neither. **Critic** attacks the work
  and decides nothing. **Sage** settles a dispute Critic did not close after two
  rounds, and the verdict is marked `Final`. A role line is written when the call
  happened, never in advance.

## Consolidation check

Every set of documents written or amended in one sitting goes through a
**consolidation agent** before the work is called done. It is a separate
reader, not the author, and it looks for four things:

- **A citation that does not say what it is cited for.** Quote against
  source, line by line.
- **A superseded document used as if it were in force.** In force in the
  collector area: [`../model/gc/rc-cycle.md`](../model/gc/rc-cycle.md), the
  design of record, and [`../model/gc/strategies.md`](../model/gc/strategies.md)
  as amended on 2026-08-26. What is a record: `model/gc/gc-research.md`, whose
  own banner supersedes its §7 recommendation, and
  `model/gc/domains-rejected.md`, which is kept so nothing in it is proposed
  twice. The documents this bullet used to sort — `rc-walk.md`,
  `rc-walk-model.md`, `gc-horizon.md`, `gc-horizon-cases/`, `gc-horizon-v2/`
  and `walk/compiler-proofs.md` — were all deleted on 2026-08-26 and are on
  `archive/pre-rc-cycle`; a text quoted from the branch is a record whatever it
  once was. Text taken from a record is never an obligation the new work must
  satisfy, and a new document that reconciles itself against one has taken the
  wrong authority.
- **Two of the new documents contradicting each other**, or a banner, status
  line or index row contradicting the body it introduces.
- **A claim with no source at all** — a number, a mechanism or a rule stated
  as fact and traceable to nothing.

It reports; it changes nothing. Errors of fact only: style is `style-en.md`
and is not this pass's business.
