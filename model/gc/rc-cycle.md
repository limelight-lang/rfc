# rc-cycle — on-the-fly cycle collection over a sliding view

> **Status: design of record since 2026-08-25, nothing built.** Edmond
> chose the direction and the name. The first premise — Levanoni and
> Petrank's sliding views — was **refused the same day** on the paper's own
> reading (node Y1): the barrier is the snapshot, the algorithm scans stacks,
> and its counts are reconstructed at a collection rather than maintained,
> which is the `__destruct` promise. What is taken is its candidate economy
> over Bacon–Rajan, with the counts left alone. Until
> `rc-cycle` is built, [`rc-walk.md`](rc-walk.md) is the text in force for
> the strategy the crate actually runs. The open questions are a graph:
> [`cycle/questions.md`](cycle/questions.md).

## What it is

**The sliding view is refused, and the paper's own reading is why**
(2026-08-25, `cycle/questions.md` Y1). All three of this runtime's
constraints are broken by load-bearing parts of that algorithm rather than
by incidental ones: the write barrier **is** the snapshot mechanism, so
there is no barrier-free form of it; the fourth handshake suspends each
thread and scans its stack, and the root-set differencing of its §4.2 is how
root-caused cycles enter the candidate set at all; and its counts are not
maintained per store but reconstructed at a collection from logged slot
histories, so no instant exists at which "the last reference was dropped" is
observable — which is the `__destruct` promise.

**What is taken instead is the paper's candidate economy over Bacon–Rajan,
with the counts left alone.** Three parts.

- **The candidate set comes from the mutator.** A garbage cycle can arise
  only from a decrement that does not reach zero, so the entities that saw
  one are the only ones worth examining, and a decrement to zero is freed by
  plain counting and never reaches the collector. Nothing is coalesced, so
  the set is Bacon–Rajan's plain one rather than the paper's smaller
  `o₀`-only set.
- **Trial deletion runs on a shadow count.** `CRC` beside `RC`: the mark and
  scan stages decrement and restore the shadow and leave the real count
  untouched, so nothing a destructor depends on is ever in a torn state.
  The paper carries this for its own reasons; here it is what makes trial
  deletion admissible beside prompt destruction at all.
- **Candidates mature over rotating buffers.** An entity is traced only
  after it has stayed a candidate across `k` collections without dying or
  being re-buffered, which buys back the set size that coalescing would have
  bought. It needs two facts a per-store-decrement runtime already has —
  whether the entity was released, and whether it was re-added.

Beside them stands the class filter, Edmond's own: a class whose declared
slots cannot hold a reference to a kind that can close a ring cannot be a
cycle member, and its instances never enter the set. A class is **suspect by
default** and leaves the set only by proof, never by a run's history.

## What it trades

`rc-walk` was built on one constraint — the mutator does no per-operation
work for the collector — and paid for it with a full census every epoch:
every slot of every entity block read, and the graph of the whole mature
population built, whether or not anything changed. `rc-cycle` pays instead
for naming the candidates at the decrement that creates them.

Two measured figures bound it. The candidate machinery of `rc-trace` costs
about **0.4 ns** on a retain-and-release pair that does not reach zero
(`ll-model` `dev/BENCHMARKS.md`, 2026-08-16, an upper bound — the retain
differs between the builds too). Against it, a walked entity costs about
**140 ns** an epoch, a row plus its edges, paid whether or not it changed.
The crossover is around 360 non-final decrements per live entity per epoch,
which no ordinary program approaches.

**And the counts stay real, which keeps the promise.** Because no count is
deferred or coalesced, an entity whose count reaches zero dies then and
there with its destructor. Only genuine cyclic garbage waits for the
collector, and it waits under every design including today's: a cycle
member's count never reaches zero by construction. The weakening the survey
of 2026-08-25 found everywhere — Nim's YRC, `scheme-rs`, CIRC — is the price
of **deferred counting**, not of cycle collection, and this design does not
pay it.

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
