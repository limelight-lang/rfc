# rc-cycle — on-the-fly cycle collection from a mutator-fed candidate set

> **Status: design of record since 2026-08-25, nothing built.** Edmond
> chose the direction and the name — the name's original expansion, "over a
> sliding view", died the same day with the premise it named. Levanoni and
> Petrank's sliding views were **refused** on the papers' own reading (node
> Y1): the barrier is the snapshot, the algorithm scans stacks, and the
> counts have synchronous customers here the log cannot serve. What is
> taken is the candidate economy over Bacon–Rajan, with the counts left
> alone. Until `rc-cycle` is built, [`rc-walk.md`](rc-walk.md) is the text
> in force for the strategy the crate actually runs. The open questions are
> a graph: [`cycle/questions.md`](cycle/questions.md).

## What it is

**The sliding view is refused, and the papers' own reading is why**
(2026-08-25, `cycle/questions.md` Y1, re-argued after the Critic round the
same day). The write barrier **is** the snapshot mechanism, so there is no
barrier-free form of it, and a skipped log entry is a wrong collection — a
per-store soundness cost no compiler proof can delete, unlike this design's
enrolment, which Y11's covering claim makes deletable at proven sites. The
counts here have synchronous customers the log cannot serve — the
copy-on-write separation test, the `RC − IN` root identity, the exact test,
prompt count-zero death — which refuses the count-replacing configuration
outright, and with it the stack scan and the §4.2 root differencing that
exist only to compensate for deferred counting. The earlier third leg —
"no instant exists at which the last reference was dropped, which is the
`__destruct` promise" — was withdrawn by the destructor ruling of the same
day (`dev/DECISIONS.md`, sixth and seventh entries): destructor timing
disqualifies nothing.

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
- **Candidates mature by age, carried in the header's epoch stamp.** An
  entity is traced only after it has stayed a candidate across `k`
  collections without dying, which bounds the tracing of the set that
  coalescing would have shrunk. The residence was ruled on 2026-08-25
  (`cycle/questions.md` Y9): a collection's commit stamps each proven-live
  component with the epoch and an age, YRC's device — not the papers'
  carousel of `k + 1` rotating buffers.

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

Two figures bound it, and both were restated on 2026-08-25 after the source
was read again. **The candidate machinery of `rc-trace` costs at most 0.4 ns**
on a retain-and-release pair that does not reach zero, and 0.4 is the
instrument's floor rather than a measurement: `ll-model` `dev/BENCHMARKS.md`
(2026-08-16) says "a difference under ≈ 0.4 ns between ll-shaped arms is
unresolved on this instrument", so the true cost lies somewhere in nought to
0.4 and no probe separates it. **A walked entity costs 32–41 ns an epoch as a
singleton and 72–108 ns in a chain**, a row plus its edges, paid whether or
not it changed (same file, the epoch probe: three runs, 100 000 entities,
resolution roughly ±15 %).

**The crossover is therefore a lower bound, not a point.** Dividing the walk's
cost by the candidate cost's *upper* bound gives the smallest crossover the
evidence permits: **at least 80 non-final decrements per live entity per epoch
for the singleton shape and at least 180 for the chain**, and higher by however
much the candidate cost sits below the instrument's floor. No ordinary program
approaches either. *(Until 2026-08-25 this passage read "about 140 ns an
epoch" and "around 360", citing `dev/BENCHMARKS.md`; that file carries no 140
and never did. The corrected figures are its own.)*

**And the counts stay real, which keeps destruction prompt** — the
design's choice, not a promise the language makes (`dev/DECISIONS.md`,
sixth entry). Because no count is deferred or coalesced, an entity whose
count reaches zero dies then and there with its destructor. Only genuine cyclic garbage waits for the
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
being recycled under an identifier in flight, and eager death. Ruling 5 is
narrowed rather than standing whole (2026-08-25, ninth `dev/DECISIONS.md`
entry): both sides may free, but the collector itself runs only a
destructor proven pure or tears down an entity that has none — an impure
destructor still goes to the owning thread, and what the collector's own
free re-verifies is an open seam recorded at `cycle/questions.md` Y5.

**The pressure ladder survives with one condition added.** A mutator that
cannot serve an allocation runs the collection itself before failing, which
`rc-walk` already licensed as its fourth rung and `runtime/exceptions.md`
requires before memory-exhausted may be raised. Here it runs as the synchronous
form over the thread's own roots, and only while no collector runs on another
thread: the shadow count is one collector's scratch, so a second collection
would read the first's decrements. Node `cycle/questions.md` Y14 carries it.

## What replaces the walk

The census and the full edge build of Phase 1. Everything that made them
expensive — `slot_rows` at four bytes a slot written before anything is
read, thirty-two bytes an edge, the id map — is what this design exists to
delete.
