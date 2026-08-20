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
