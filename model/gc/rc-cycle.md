# rc-cycle — on-the-fly cycle collection over a sliding view

> **Status: design of record since 2026-08-25, nothing built.** Edmond
> chose the direction and the name; the algorithm is Bacon–Rajan's cycle
> collection over Levanoni and Petrank's sliding views, and its premise is
> **unverified** — the paper is being read, and what it costs the mutator
> per store decides whether this document survives its first node. Until
> `rc-cycle` is built, [`rc-walk.md`](rc-walk.md) is the text in force for
> the strategy the crate actually runs. The open questions are a graph:
> [`cycle/questions.md`](cycle/questions.md).

## What it is

A reference-counted heap whose cycles are collected **on the fly** — no
thread stopped, no heap census. Three parts, and the third is this
project's own.

- **The candidate set comes from the mutator**, as in Bacon–Rajan: a
  garbage cycle can arise only from a decrement that does not reach zero,
  so the entities that saw one are the only entities worth examining. A
  decrement to zero is freed by plain counting and never reaches the
  collector.
- **The view comes from a log, not from a walk.** Levanoni and Petrank's
  sliding views let the collector assemble a consistent picture of the
  heap from what the mutator recorded, without stopping it and without
  reading every slot. The cycle collector then runs over that picture.
- **The classes carry the filter.** A class whose declared slots cannot
  hold a reference to a kind that can close a ring cannot be a cycle
  member, and its instances never enter the candidate set. The direction
  is fixed and it matters: a class is **suspect by default** and leaves
  the set only by proof, never by a run's history.

## What it trades

`rc-walk` was built on one constraint — the mutator does no per-operation
work for the collector — and paid for it with a full census every epoch:
every slot of every entity block read, and the graph of the whole mature
population built, whether or not anything changed. `rc-cycle` spends the
other way: the mutator records, and the collector reads what was recorded.

**That is a change of constraint, not an improvement inside it**, and the
first node of the graph is what it costs. Two measured figures bound the
question today. The candidate machinery of `rc-trace` costs about **0.4 ns**
on a retain-and-release pair that does not reach zero (`ll-model`
`dev/BENCHMARKS.md`, 2026-08-16, and it is an upper bound — the retain
differs between the builds too). Against it, a walked entity costs about
**140 ns** an epoch, a row plus its edges, paid whether or not it changed.
The crossover is around 360 non-final decrements per live entity per epoch,
which no ordinary program approaches.

## What it keeps from `rc-walk`

The expensive half of concurrency is already built and is not re-derived
here. A collector that judges concurrently cannot be trusted, so the owner
re-verifies: the handshake, the Phase 4 exact test against current fields
on the owning thread, the deferred-free parking that keeps a slot from
being recycled under an identifier in flight, and eager death. Ruling 5
stands — the collector judges and the mutator frees.

## What replaces the walk

The census and the full edge build of Phase 1. Everything that made them
expensive — `slot_rows` at four bytes a slot written before anything is
read, thirty-two bytes an edge, the id map — is what this design exists to
delete.
