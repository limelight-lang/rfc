# dev/INDEX — project map for the agent

Pointers only. What is written elsewhere is not repeated here.

## What this repo is

Design documents (RFCs) for **Limelight**, a compiled runtime for PHP.
No product code lives here — this is the specification, see
[../README.md](../README.md) for the architecture and reading order.

## Where to look

- **Project overview & reading order** → [../README.md](../README.md)
- **Deferred work** → [../BACKLOG.md](../BACKLOG.md)
- **Architecture / knowledge map** → [ARCHITECTURE.md](ARCHITECTURE.md)
- **Decisions (why, dated)** → [DECISIONS.md](DECISIONS.md)
- **Project conventions (branches, commits, PRs)** → [WORKFLOW.md](WORKFLOW.md)
- **Plan: stages, steps, review roles** → [PLAN.md](PLAN.md)
- **Pitfalls already hit** → [POSTMORTEM.md](POSTMORTEM.md)
- **Diagrams / schemas** → [design/](design/)
- **Repository utilities** → [tools/](tools/README.md) — `linkcheck.php`
  verifies every cross-reference and anchor resolves; run it after moving a
  document or rewording a heading. `heap-composition.php` walks a booted
  application's object graph and reports what a Limelight heap of it would
  hold — the heap-side half of the corpus question, node A6 of
  [../model/gc/walk/questions.md](../model/gc/walk/questions.md)
- **rc-walk model checker** → [tools/rc-walk/](tools/rc-walk/README.md) —
  TLA+/TLC scenario battery for the collector; results in
  [../model/gc/rc-walk-proof.md](../model/gc/rc-walk-proof.md)

## Active initiative

**Fact-base consistency checking.** Building a networked fact base over
the RFCs to mathematically verify that facts across documents do not
contradict each other. Methodology and formalism not yet decided —
tracked in [DECISIONS.md](DECISIONS.md) once chosen. Schemas will live
in [design/](design/); tooling and `dev/tools/` will be added when the
checker exists.

## Not yet present (deferred on purpose)

- `dev/BENCHMARKS.md` — no code to measure yet. The corpus figures
  `heap-composition.php` produces live in the node that asked for them.
