# rc-cycle — on-the-fly cycle collection from a mutator-fed candidate set

> **Status: design of record since 2026-08-25, nothing built.** The residence of
> the shadow count, the header's layout and the division of labour between
> mutator and collector were decided on 2026-08-26 and are below. Until
> `rc-cycle` is built the crate runs `rc-trace`; both it and `rc-walk` are
> deleted before the first line of `rc-cycle` is written, and the old state is
> reachable as the branch `archive/pre-rc-cycle`. The open questions are a
> graph: [`cycle/questions.md`](cycle/questions.md).

## What it is

**The sliding view is refused, and the papers' own reading is why** (2026-08-25,
`cycle/questions.md` Y1). The write barrier **is** the snapshot mechanism, so
there is no barrier-free form of it, and a skipped log entry is a wrong
collection. The counts here have synchronous customers the log cannot serve —
the copy-on-write separation test, the `RC − IN` root identity, the exact test,
prompt count-zero death — which refuses the count-replacing configuration
outright, and with it the stack scan and the §4.2 root differencing that exist
only to compensate for deferred counting.

**What is taken instead is the paper's candidate economy over Bacon–Rajan, with
the counts left alone.** Three parts.

- **The candidate set comes from the mutator.** A garbage cycle can arise only
  from a decrement that does not reach zero, so the entities that saw one are
  the only ones worth examining, and a decrement to zero is freed by plain
  counting and never reaches the collector.
- **Trial deletion runs on a shadow count**, off the heap. Mark and scan
  decrement a working count in a side row and leave the real count untouched, so
  nothing a destructor depends on is ever in a torn state — and an aborted
  collection costs **zero heap writes**.
- **Candidates mature by age**, carried in the header's epoch stamp: an entity
  is traced only after it has stayed a candidate across `k` collections without
  dying.

Beside them stands the class filter: a class whose declared slots cannot hold a
reference to a kind that can close a ring cannot be a cycle member, and its
instances never enter the set. A class is **suspect by default** and leaves the
set only by proof, never by a run's history.

## Who judges, and what a trace is worth

**The collector produces a shortlist of suspects, not a verdict** (Edmond,
2026-08-26). Garbage is monotone: to obtain a reference to an object the mutator
must read a slot that already points at it, so a ring whose every referrer is
inside itself cannot be reached from outside and cannot be resurrected. A
verdict of "garbage" therefore cannot be overturned by anything the mutator
does. What can overturn it is an error of the trace — and there is exactly one
source of error: the counts do not see local references whose retain/release
pairs the compiler elided.

Two consequences, and they are the design's licence.

**The trace's precision is a cost, not a correctness property.** A component
proposed and rejected costs the owner time; a garbage ring missed is found by a
later collection. So the trace may be pruned by age, bounded by a budget,
abandoned mid-way under memory pressure, or run over an inconsistent snapshot of
the counts — none of it can make a verdict wrong. This is the freedom
`cycle/questions.md` Y13 was looking for.

**Soundness rests entirely on the exact judgement, and that judgement is the
owner's.** Only the owning thread sees its own stack, which is where the elided
references live.

**The law, and it is load-bearing.** Every *reduction* of state — clearing the
enrolment bit, dropping a queue entry, returning a slot — is the owner's, and
only on an exact reading. A dirty pass may add suspicion and nothing else.
Without the law an acquittal leaks a ring forever: take a ring A↔B with an
external X→B. The trace captures `RC(B) = 2`, subtracts the one internal edge,
reads 1 and acquits B as live from outside. Meanwhile X releases B — not to
zero, and B's bit is already set, so no re-enrolment happens. The ring is now
wholly dead, and if the acquittal cleared B's bit no decrement will ever come
again.

**A collection run in-line on the owning thread is exact by construction**
(Edmond, 2026-08-26). The thread's own stack is visible, and the counts are
changed by the same thread that reads them, so the snapshot is consistent and
the law is satisfied trivially — the owner is the reader and the reading is
exact. There is no verdict list, no handshake, no confirmation and nothing to
wait for. **The in-line form is therefore the standard, and a collector thread
is an accelerator that narrows the owner's list.**

## Where the shadow count lives

**In a per-block array, one row per slot, found by arithmetic from the address**
— no hash, no key, and no field in the entity header. Decided 2026-08-26 after
measuring three forms.

The entity heap is already block-structured, so the address carries the answer:
the block is `p & !BLOCK_MASK`, and the slot is
`((p & BLOCK_MASK) - LINE_SIZE) * recip >> 32`, where `recip = 2^32 / class + 1`
is exact for every size class and every slot of a block. The collector's own
triple — the array pointer, `recip` and its own copy of the size class — sits in
the free tail of the block's 256-byte header line, past the 192 bytes
`HeapBlockHeader` occupies, so the collector never writes the cache line that
carries the owner's bump cursor and free list.

**Measured** on an i7-11700K, median of nine, null pair 0.7–1.1 ns: 2.6 ns a
lookup, against 10.4 ns for an open-addressed hash keyed by the pointer with a
displacement hint in the entity header, and 15.8 ns for the same hash with an
ordinary probe. On a 12 GiB heap of classes 32/64/128/256 at half occupancy the
rows cost 717 MiB against the hash's 2.0–4.0 GiB — the hash's upper figure being
what its doubling costs when 94 million rows land just past a load factor of 0.7.

**The formula does not cover every population of the GC heap, so the trace
dispatches on the block's kind** — it holds the block header before it can reach
any row, so the dispatch is free. An ordinary entity block goes by arithmetic. A
**retained** block — promoted arena survivors, filled by a bump allocator, mixed
sizes, no stride — goes by binary search over the occupancy index, so
`memory/retained.rs` outlives the deletion of `rc-walk` that built it. A **large
entity** holds one row in its own block header's free tail. An arena block is
never entered: the descent stops at any child outside the GC heap and treats it
as an external live reference, because a ring through the arena is broken by the
arena's own reset.

**The rows are not zeroed greedily.** A zero row means "not met in this
collection", so a per-slot array would have to arrive zeroed — and that is paid
for every slot of a touched block rather than for the ones visited. Measured for
the 717 MiB case: 41–76 ms to zero already-mapped memory, 178–196 ms to
first-touch fresh memory, and it is asked for on the path where an allocation
has already failed. So the "met" flag leaves the row for a **bitmap of one bit
per group of eight slots**, and only the bitmap and the touched group are
zeroed: 1.4 ms instead, and the pages of the row array that the trace never
touches are never materialised, so the reservation stays virtual while the
footprint follows the trace. The row is then two bits of colour and thirty of
working count, with saturation reading as "external references exist,
conservatively live".

**The chunked form is the recorded alternative, not the choice**: rows in groups
of eight behind a two-byte directory entry per group. It wins only where the
density of traced slots in touched blocks stays below 29 % — the analytic
crossing is `1 − 1/√2` — and it costs a further dependent load on every edge. On
a full trace it writes *more* than the flat array, 762 MiB against 717, because
every chunk is zeroed at first use too.

## Death while enrolled

An entity can reach count zero while a queue entry still names it, and the entry
cannot be withdrawn: the index that made withdrawal possible under `rc-trace` is
deleted with the rest of its machinery.

**Death splits in two.** Everything user code can observe happens at once, on
the mutator: weak cells are cleared first, then `__destruct` runs, then children
are released. What is deferred is only the slot: it stays parked while a queue
entry names it, with the header readable — count zero, enrolment bit still set.

**The owner un-parks, per the law.** A dirty reader of the queue may mark an
entry as a corpse and pass it on; clearing the bit and returning the slot belong
to the exact judgement. That closes the window in which `ll_release` has
published the zero but the death path has not yet begun, during which a slot
returned by a reader could be handed back out under a running destructor.

**Two parkings, with different windows.** The one above is between collections.
The other is inside one: a slot freed during a collection waits for its end,
because the row is keyed by the slot and a reused slot would inherit the dead
occupant's met bit and working count. A slot returns when both windows are shut,
and `used` falls at the return rather than at the parking — otherwise a block
empties with a corpse inside it and goes back to the pool.

**Enrolment requires the GC-heap category**, which the release path gets for
free: category zero, kind below four, class not acyclic, ownership not proven
and not already enrolled are all "these bits are zero", so the whole gate is one
`flags & 0x733 == 0`. Without the category clause an arena entity in the queue
outlives an arena reset and the corpse rule reads the count of the slot's next
occupant.

## Cycle teardown

**The order below is binding.** It holds in the in-line form and in the
accelerated one, and no later rewrite of the commit stage may reorder it. It is
written here because it cannot be re-derived from the counts: every step but
the first exists to close a window that the exact test does not see, and each
window was found by a defect rather than by reasoning. The text is transcribed
from `rc-walk`'s commit stage — `collect_cycles` and `drain_confirmed` in
`ll-model`'s `walk.rs` — before that code is deleted.

The teardown runs on the owning thread, on a component the owner has confirmed.

1. **The exact test, per component, opening with the corpse rule.** A member
   that reads count zero died ordinarily since it was proposed — its teardown
   is complete and its slot parked — and the component is dropped whole before
   any field is traced or any guard written. A dropped component carries no
   duties: acquittal leaves nothing to clean.

2. **Guard every member of every confirmed component**, `+1` each, before any
   user code runs. A release from inside any destructor then stops at a guard
   instead of at zero, so no member starts an ordinary death inside the
   teardown. The guard is needed on a single thread; it has nothing to do with
   concurrency.

3. **Null every weak cell naming any confirmed member — all members of all
   confirmed components, before the first destructor.** A weak load is the one
   channel that can hand a destructor a reference the counts do not account
   for. Per-member nulling interleaved with per-member teardown is what this
   forbids: in a condemned ring A↔B, `B::__destruct` would load the cell naming
   A, receive a strong reference, and A's slot would be freed under it. CPython
   closes the same window in PEP 442, and Zend nulls at the top of
   `zend_object_std_dtor` for the same reason
   ([`../weak-references.md`](../weak-references.md), "Cycle death").

4. **Run each pending `__destruct` exactly once.** User code may store,
   release, allocate or resurrect; a store retains normally. The kind gate here
   covers objects today and widens to `Lazy` when the compiler starts producing
   it — a lazy entity carries a class pointer, and its destructor would
   otherwise never run.

5. **Re-verify with the guard discounted** (`RC − 1 = IN`), and only when a
   destructor ran **anywhere** — one flag for the whole commit, not one per
   component, so the skip owes nothing to any reasoning about what a destructor
   in one component can reach in another. Without the discount the guards
   themselves acquit every component and nothing is ever freed. A component
   that fails the re-verify is abandoned: the guards come off through the
   counted release, and the survivors carry true counts with their destructors
   behind them.

   This step is what the shortlist framing does not remove. Garbage is monotone
   only while no reference to the component exists outside it, and step 4 hands
   user code `$this` — a reference the teardown itself created.

6. **Sever, un-guard, then drop the deferred external children.** Severing
   nulls every member's slots and collects the displaced children;
   in-component children are released immediately and stop at their guards,
   external ones are held back until after the members are freed. Between the
   sever and the free no user code runs at all, which makes the property
   structural instead of proof-dependent. The external children then die
   ordinarily, destructors and all; the members were GC-heap holders, so the
   barrier's drop settles an arena escapee's hold count exactly as member
   teardown would have.

**Two consequences, accepted rather than engineered away.** A component
acquitted at step 5 keeps its nulled cells: nulling is irrevocable, and a
resurrected object's weak references stay null, which is where this design
diverges from PHP's. And a weak cell that a destructor creates on a condemned
member during step 4 is not covered by step 3; it is cleared by the free-time
notification on the header's weak bit, at step 6.

## Concurrency

One collection at a time in the process — the `amSolo` rule — because the
shadow rows are one collection's scratch and a second would read the first's
decrements. The claim is one word with three states: free, held by the owning
thread, held by a collector thread, entered by CAS from free.

A collector thread that finds the claim held skips that thread and returns in a
later round; the candidates keep their bits, so a skip costs nothing. A mutator
that cannot serve an allocation and finds the claim held by a collector
**waits** (Edmond, 2026-08-26) rather than preempting — and waiting is safe here
because the claim covers the trace alone: the exact judgements are the owners'
own, taken at their own checkpoints, so a sleeping thread delays only the
components it is party to.

While a trace is in flight over a thread's blocks, that thread's frees park.
That is the floating garbage every concurrent collector pays, bounded by the
allocation churn of one collection.

## What it trades

`rc-walk` was built on one constraint — the mutator does no per-operation work
for the collector — and paid for it with a full census every epoch: every slot
of every entity block read, and the graph of the whole mature population built,
whether or not anything changed. `rc-cycle` pays instead for naming the
candidates at the decrement that creates them.

**The candidate machinery of `rc-trace` costs at most 0.4 ns** on a
retain-and-release pair that does not reach zero, and 0.4 is the instrument's
floor rather than a measurement. **A walked entity costs 32–41 ns an epoch as a
singleton and 72–108 ns in a chain.** Dividing the walk's cost by the candidate
cost's *upper* bound gives the smallest crossover the evidence permits: at least
80 non-final decrements per live entity per epoch for the singleton shape and at
least 180 for the chain. No ordinary program approaches either.

**And the counts stay real, which keeps destruction prompt.** Because no count
is deferred or coalesced, an entity whose count reaches zero dies then and there
with its destructor. Only genuine cyclic garbage waits, and it waits under every
design including today's.

## What it keeps from `rc-walk`

The expensive half of concurrency is already built and is not re-derived here:
the handshake, the exact test against current fields on the owning thread, the
deferred-free parking that keeps a slot from being recycled under an identifier
in flight, eager death, and the occupancy index of retained blocks.

**Ruling 5 stands whole: the collector judges and only the mutator frees.** The
exact test is sound only because the owning thread holds the entity while it
reads its current fields, and the weak table is per thread, so a collector
cannot null the weak cells naming a dying entity before user code runs.

## What replaces the walk

The census and the full edge build of Phase 1. Everything that made them
expensive — `slot_rows` at four bytes a slot written before anything is read,
thirty-two bytes an edge, the id map — is what this design exists to delete. The
shadow rows are four bytes a slot too, but only for blocks a trace touched, only
for the duration of that trace, and only written where the trace went.
