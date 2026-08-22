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
- **A superseded document used as if it were in force.** `rc-walk.md` is the
  first version of the walk; `gc-horizon-v2/` is a refused regime. Text taken
  from either is a record, never an obligation the new work must satisfy, and
  a new document that reconciles itself against them has taken the wrong
  authority.
- **Two of the new documents contradicting each other**, or a banner, status
  line or index row contradicting the body it introduces.
- **A claim with no source at all** — a number, a mechanism or a rule stated
  as fact and traceable to nothing.

It reports; it changes nothing. Errors of fact only: style is `style-en.md`
and is not this pass's business.
