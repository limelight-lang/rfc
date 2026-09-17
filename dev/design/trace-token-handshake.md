# The trace token as a handshake

Status: ruled 2026-09-17 — drafted by the model on Edmond's proposal of
that day, attacked by two Critics, ruled by the Sage, and the silent-owner
question ruled by a second Sage round the same day; awaiting Edmond's
reading before it amends `model/gc/rc-cycle.md`, "Concurrency", and before
`ll-model` builds it. The defect it answers is the Code Reviewer's of
2026-09-16 (`ll-model`, `dev/DECISIONS.md`, "the free path's reading of the
token is fenced against the take"); the fence that repair put on every
free is what this protocol removes.

## The problem it answers

A collector thread traces a mutator's entities from its candidate ring while
the mutator keeps running. The mutator's free path returns memory only when
no collector holds its token; a return the collector could still address is
withheld. The reading of the token on the free path and the collector's take
are the two halves of a store-buffering pair: the mutator stores into cells,
then loads the token; the collector swaps the token, then loads cells. With
no full barrier on the mutator's side, its load of the token can execute
before its cell stores leave the store buffer, and a collector that takes
the token just after that load reads the cells as they stood before those
stores — an address the mutator is about to free. Today's repair is a
`SeqCst` fence on every free, 2.5 to 3 ns (`ll-model`, `dev/BENCHMARKS.md`,
"the free path's fence against the take").

The handshake removes the fence from the free path by never letting the
collector read a cell without the mutator's consent, given by one
release-ordered compare-and-swap per consent rather than one barrier per
free.

## The word

One `AtomicU8` per mutator thread, in the token line of its record
(`ll-model`, `cycle::mutator_record`), six bits used. The low three bits
are the state; bits 3–5 are the requesting collector's slot
(`MAX_COLLECTORS` is 8). `FREE`, `MUTATOR` and `POSTED` carry slot zero,
so a collector's request expects exactly 0. The byte replaces
`TraceToken::held`, the record's `owner_holds` byte, the collector-facing
reading of the collecting word (E10), and the poll's reading of P (the
fourth round).

| state | meaning |
|---|---|
| `FREE` (0) | nobody traces this thread; the mutator returns memory at once |
| `MUTATOR` (1) | the mutator holds its own token: an in-line collection through its close, the exit's final claim, the initialisation's hold on a record not yet claimable |
| `REQUESTED\|s` (2) | collector s asks to trace; the mutator has not consented |
| `COLLECTOR\|s` (3) | collector s traces; the mutator withholds every return |
| `POSTED` (4) | no collector holds anything; the last batch posted verdicts into P that the owner has not disposed of; the mutator returns memory at once and owes a collection over P |

The record leaves the registry `MUTATOR`, the initialisation's end stores
`FREE`, the exit's kept claim leaves `MUTATOR` on the free list; the
registry writes nothing to the byte across lives. The invariant `POSTED`
carries: P holds an entry the owner has not disposed of only while the
byte reads `POSTED` or `MUTATOR`, so a byte that reads `FREE` promises an
empty P and the poll has no reason to read P.

The slot rather than a life counter: three bits fit beside the state, the
slot is already the collector's name, and it is exact — a request never
outlives the collector thread that made it (the guard, E7), a slot holds
one thread at a time, a collector runs one round at a time, so
`REQUESTED|s` and `COLLECTOR|s` are written for one request of s and no
other, across a record's lives and across slot handovers alike. A life
counter would need enough bits to outlast a wait that spans two lives
inside one bound, which a thread pool produces.

## Transitions

Byte = `state | slot << 2`; `s` is the acting collector's slot. Every
transition is a compare-and-swap naming the value it expects, and the
value a failed swap reads back is acted on, never inferred.

| from | to | who | where | ordering |
|---|---|---|---|---|
| `FREE` | `REQUESTED\|s` | collector s | `serve`, after the hold-read idle test, the guard installed first | CAS Acquire / Relaxed |
| `REQUESTED\|s` | `COLLECTOR\|s` | mutator | the slot free entry; the poll's reading before the gate | CAS Release / Acquire; then wake s |
| `REQUESTED\|s` | `FREE` | collector s | the deadline, the round-end sweep, the guard's drop | CAS Relaxed / Acquire; failure acted on by value |
| `COLLECTOR\|s` | `FREE` | collector s | after the last row read and the arena's reset, when the batch posted nothing into P | store Release; lock; `notify_all` |
| `COLLECTOR\|s` | `POSTED` | collector s | the same release, when the batch posted its verdicts into P; on the unwind as on the return | store Release; lock; `notify_all` |
| `POSTED` | `MUTATOR` | mutator | every taker of the `FREE → MUTATOR` row below, the teardown-refusal retirement excepted, which holds `POSTED` unswapped | CAS Acquire / Acquire |
| `POSTED` | (skip) | collector s | the request CAS fails on it: neither a batch nor work; the owner is served by no round until its own collection has run | CAS failure, Relaxed |
| `FREE` | `MUTATOR` | mutator | `CollectingThread::take` on both paths, the teardown-refusal retirement, the exit | CAS Acquire / Acquire |
| `REQUESTED\|s` | `MUTATOR` | mutator | the same takers: the request is refused | CAS Acquire / Acquire; then wake s |
| `MUTATOR` | `FREE` | mutator | the close's last store; the initialisation's end | store Release |
| `COLLECTOR\|s` | (wait) | mutator | the same takers: the condition variable under the token's mutex, re-tested by CAS | — |

No other transition exists. The collector writes over `COLLECTOR|s` alone
and only its own; the mutator never writes over `COLLECTOR`; `POSTED` is
written by the collector alone and consumed by the mutator alone, and the
close that consumed it writes `FREE`, always. Every load that acts on
`FREE` or on `POSTED` is Acquire.

## The two sides

**Mutator, free path.** One acquire load of the byte — a plain `mov` on
x86-64, `ldar` on ARM64 — made by one reading function that the slot
entry and the poll share and nobody else calls. `FREE`: return the
memory. `POSTED`: arm this thread for a collection over P (a thread-local
store; the byte is left as it is, so every reading in the window re-arms)
and return the memory: the collector holds no cell after its release.
`COLLECTOR|any`: withhold it, as today. `MUTATOR`: the thread's own window
decides, as today. `REQUESTED|s`, at the slot entry with no window open:
consent — CAS `REQUESTED|s → COLLECTOR|s` (Release on success, Acquire on
failure), wake slot s read from the byte, withhold this slot; a swap that
fails acts on the value it read back. The other readers — the chunk gate, the block
gate, `returns_are_withheld` for the remote reclaim, the per-pop checks of
the three drains — read `REQUESTED` and `POSTED` as `FREE` and return:
before consent, and after the release, the collector holds no cell, so no
address it holds names the memory. They test `state == COLLECTOR`, never
`state != FREE`.
The slot drain needs no arm of its own — its hand-back re-enters the slot
entry, which consents at the first slot, and the next pop reads `COLLECTOR`
and splices the rest back. `BlockPool::put` from a thread-local's drop at
exit reads `MUTATOR` and returns; it never wakes a condition variable.

**Mutator, poll.** The poll is a second caller of the reading function,
before the gate, one acquire load per poll; it reads nothing of P.
`POSTED` arms; `REQUESTED|s`: consent, wake s, continue; the arming is
kept — an arming is spent by a collection that ran and by nothing else.
An armed poll that read `COLLECTOR` returns before `take_arming()`; the
next poll re-reads. A request that lands between the reading and the take
is met by the take loop, which refuses; a `COLLECTOR` that lands there is
waited for, today's wait and bound. A closed-gate poll consents and arms
all the same, since the reading precedes the gate. The arming word has
two values above none, `Verdicts` and `AllRoots`, merged by maximum: the
byte's `POSTED` arms `Verdicts`; the pressure path's endings that hand a
component to the next poll arm `AllRoots`; nothing else arms. The fire
spends the word: `Verdicts` fires the collection over P, `AllRoots` the
collection over R whole with P disposed of whole in it. The explicit fire
waits as today and spends a standing arming.

**Mutator, in-line collection.** `CollectingThread::take` takes `MUTATOR`
after the gate and after `set_collecting`: `FREE → MUTATOR`;
`POSTED → MUTATOR`; `REQUESTED|s → MUTATOR` with the refusal wake;
`COLLECTOR` waited out on the condition variable, the loop acting on every
other read-back by a fresh swap. The collection `Verdicts` fires is over
P alone: it counts P's proposed and unwalked roots without writing, and
`EmptyLane` is its answer only on a zero count; it traces them with exact
counts, validates and finalizes; then, on every ending of every path that
took `POSTED`, one disposition of P whole — a read-live root deferred to
the deferred lane, or written into R on `NoBlock`; a zero-count verdict
retired on the entity's re-read completed-free bit; a finalized root
nulled; a refused, untraced, resurrected or unreached root written back
into R through `append_entry`, which cannot refuse — followed by one
advance of `front` by the whole prefix, so that a root is in one ring at
every instant; and the close writes `FREE`. The disposition sits in
`CollectingThread`'s drop, where `retire_candidates` runs, so
`NoWorkspace` before the window opens and the pressure path's `restore_batch`
endings reach it too. The pressure path and the exit read R whole and
dispose of P whole the same way. The teardown-refusal retirement pass, run
with the gate closed, takes `FREE → MUTATOR` and `REQUESTED|s → MUTATOR`
and holds `POSTED` unswapped: under `POSTED` no collector holds anything
and a request fails, so it nulls P's slots and rewrites R's blocks under
it and leaves the byte as it found it. The P-only reading never lowers
`signal_due`: the block-filled wake is for an R it did not read. The claim is released in the guard's drop after
`retire_candidates`, as the close's last store, on both paths: the ordinary
path holds it through its teardown and the pressure path through its loop.
The `HeldToken` takes inside the two paths are nested and release nothing.
The collecting word stays the mutator's own gate, written and read by the
mutator alone, Relaxed; `is_collecting_as_collector` and
`Served::OwnerCollecting` go.

**Mutator, exit.** The exit's final claim is the same take loop; after it
the byte never changes again for this life of the record.

**Collector.** A guard is installed first, holding the record and the
slot. Request: CAS `FREE → REQUESTED|s`; any other value is a skip
(`Served::TokenHeld`). For an owner that answered its last request: a
deadline loop with one bound W — `deadline = now + W`; load Acquire;
`COLLECTOR|s` is the grant; past the deadline, withdraw; else
`park_timeout(deadline − now)`. Only the byte is the answer; a park return
is not. A return before the deadline that was not the grant is remembered,
and the between-rounds sleep after this round is skipped once, because the
loop may have consumed a round-start wake. For an owner that did not
answer its last request — a silent mark on the collector's reader line,
reset with the line at a re-take — the request is not waited for and not
withdrawn: it stands on the byte, recorded in a fixed array on the
collector thread's frame (a silent owner past the array's capacity is
skipped that round), until the owner answers or the collector thread
ends. The standing array is read at two checkpoints on the collector's
frame, the two places it commits time, at both of which it holds no token
and no arena: before every request of the walk — which is after every
batch, every skip and every refusal, and at the round's start — and after
every `park_timeout` return inside a deadline loop that was not the grant,
before the loop parks again. At a checkpoint the live prefix of the array
is read in order, one Acquire load per entry: `COLLECTOR|s` is served then
— arena opened after the grant, the batch, the arena's reset, the release,
the entry dropped, the silent mark cleared; `REQUESTED|s` is left
standing; anything else — `MUTATOR`, `FREE`, another slot's value — is a
record moved on and the entry is dropped. Every consented entry found is
served in the same checkpoint, and the walk or the stranger's deadline
loop resumes after; the deadline is absolute, computed once, so a resumed
loop parks for what is left or withdraws. A standing request costs no
wait; the consent wake cannot be lost, since `park`'s token makes an
unpark sent mid-round end the next `park_timeout` at once, and a batch in
progress ends by its block budget — so a woken owner is served at the
first checkpoint after its consent, at most one stranger's batch away plus
the batches of standing entries ahead of it that consented in the same
interval. The "remembered early return" that skips the between-rounds
sleep once is set only when the checkpoint that followed the return served
nothing. The withdrawal of standing requests is the thread body's drop;
one that fails reading its own `COLLECTOR|s` releases without a batch.
Withdrawal: CAS `REQUESTED|s → FREE` (Relaxed
success, Acquire failure); on failure the read-back decides —
`COLLECTOR|s` is the grant and is served then, not released; `MUTATOR` is a
refusal; `FREE`, or a value with another slot, is a record moved on — the
collector holds nothing. On the grant: `TraceScratchArena::open()` (a
refusal releases at once and answers `Idle`), the batch as today, the
arena's reset, then release `COLLECTOR|s → POSTED` if the batch posted
verdicts into P and `COLLECTOR|s → FREE` if it posted nothing (Release),
lock, `notify_all`; the guard that releases on the unwind carries the
posted fact, set before the first post. A request that meets `POSTED`
fails and reads nothing: P holds one batch at a time, and the next request
is made against `FREE` after the owner's close; for the timer the skip is
neither a batch nor work, and the owner's note of a freeing disposition
is the way back to the minimum interval. The collector exists before the
first pressure collection: the poll's first wake births the elder, since
the poll has a frame and may allocate. The guard's drop is the withdrawal above, and a failure
reading its own `COLLECTOR|s` releases; `note_traced_owner(null)` in the
same drop; the arena is declared after the guard and drops before it.
`Served` gains `Unanswered`, which is neither a batch nor work: the
interval doubles. A refusal is work as today.

**Fallback for an owner that never answers: none.** Its request stands,
and it is served at the collector's first checkpoint after its consent —
its first poll or slot free — at most one stranger's batch away; its
withholding, its pressure path's wait and its exit's wait are bounded by
that, and neither W nor the round's length enters. Its garbage is held for as long as it is blocked under
every form this design can carry: the collector frees nothing — its batch
posts verdicts into P, one block per owner, and every reduction of state
is the owner's at its poll or its in-line collection — so a forced trace
of a sleeper yields a shortlist the sleeper cannot judge until it wakes,
and no protocol on the token shortens the hold. The asymmetric barrier
(`membarrier(2)` private-expedited on Linux, `FlushProcessWriteBuffers` on
Windows, a signal to the one thread on POSIX) is refused as the whole
protocol and as a fallback: the ruling and its reasons are under
"Rulings", the second Sage round.

## Why it is sound

The collector reads no cell of the mutator's before it reads `COLLECTOR|s`.
That value is written by the mutator's Release compare-and-swap, so every
store sequenced before it — the cell rewrites of every free before this
one — is visible to the collector's loads after its Acquire read, whichever
load or failed swap made the read; the collector's first cell load follows
that read in program order, and neither side fences. A return the mutator
made before its consent is memory no cell names any more: the release that
brought the count to zero rewrote the cell before the free, in program
order on every path opened, and that rewrite is among the stores the
consent published. A return the mutator reaches after its consent reads
`COLLECTOR` and is withheld. The mutator's load of the byte may still be
reordered ahead of its earlier stores; nothing depends on it, because a
stale `FREE` leads to a return the collector cannot address and a stale
`COLLECTOR` to one more return withheld.

The return direction: the hand-back's stores into a slot must happen after
the collector's last load of it, and the release/acquire pair on the byte —
the collector's Release store of `FREE`, the mutator's Acquire load that
acts on it — gives that on every reader; the pressure path's reading of
`front` the collector advanced rides on the same pair through its take's
Acquire.

Two traces never meet on one thread's blocks: the collector holds only its
own `COLLECTOR|s`, the mutator's own collection holds `MUTATOR` from its
take through its close, and a failed swap is acted on by the value it read.
No `REQUESTED` or `COLLECTOR` outlives its requester: the guard withdraws
or releases on every exit from the collector's frame.

The wait is the collector's alone. The mutator waits only where it waited
before: for a `COLLECTOR` to release when it must collect itself.

## Cost

The mutator's free path pays one acquire load of the byte, a plain `mov`
on x86-64 and `ldar` on ARM64, as before 2026-09-16: the 2.5–3 ns fence
per free is gone. A consent pays one Release compare-and-swap, one lock of
the collector slot's handle mutex with an `unpark`, and one slot withheld
until the batch ends — once per batch, not measured. The poll pays one
acquire load per poll, the one addition to a path the draft did not touch,
and loses its per-poll peek of P (`Reader::new` and one `peek`); the
difference is not measured; since the poll is emitted per statement,
bench measures it before the rfc amendment lands. The fourth round's
prices: every free made while the byte reads `POSTED` stores the arming
once more, a thread-local write on the slow branch, the window being one
poll interval; the collector posts one batch per owner-collection, its
request failing at `POSTED` until the owner's close; a completed death in
R keeps its slot until the collector's batch reaches it and the owner's
collection over P retires it, so slot retirement runs at the collector's
throughput, the pressure path's whole-R compaction being the fallback;
each not measured. The collector pays per batch one request
CAS, a wait of at most W, one acquire load per wake inside it, the arena
opened after the grant, the batch as today, the arena's reset, and one
Release store with a lock and notify; per silent owner one request and one
withdrawal per round, and at most k Acquire loads and k branches per
checkpoint (k the standing array's capacity, a constant named beside
`BACKLOGGED_REMEMBERED`), one checkpoint per walk step and one per park
return, which the batch that follows dwarfs; per refusal one wait ended
early by the wake. W is not measured and not guessed: it lands
above the 99th percentile of the interval between two consecutive polls or
slot frees of a running mutator on the corpus, with a margin — bench
measures it, and the placeholder the implementer writes carries "not a
measured figure" until then. The blocked-thread garbage the fallback
accepts is not measured, and is the one figure that would reopen the
premise.

## Edge cases

Two Critic rounds of 2026-09-17, one on liveness and timing, one on memory
ordering and the withholding. Merged and ranked; each names the scenario,
what breaks, and where the draft above has a gap.

**E1. A failed withdrawal is read as a consent** (both Critics; certain from
the text). Collector C swaps `FREE → REQUESTED` on owner O and parks. O's
pressure path reads `REQUESTED`, swaps `REQUESTED → MUTATOR` and collects
in line. C's bound expires; its `REQUESTED → FREE` fails because the word
is `MUTATOR`; the draft's collector paragraph says a failed withdrawal
means "the mutator consented" and lets C trace: two traces over one
thread's blocks, the thing the token exists to prevent, and after O's
release O's free path returns memory under C's rows. The same misreading
on the exit's `REQUESTED → MUTATOR`: C traces blocks another thread now
owns through `abandon_all`/`adopt`. Gap: the failure branch names one
cause where the table allows three (`COLLECTOR`, `MUTATOR`, `FREE`); the
collector must act on the value the failed swap read back, and only
`COLLECTOR` is a grant.

**E2. The word names no requester, so a grant or a withdrawal is
misattributed across a record's lives** (Critic A). Sibling S swaps
`FREE → REQUESTED` on record R of thread T1 and parks. T1 exits
(`REQUESTED → MUTATOR`), R goes to the registry's free list; T2 draws R,
finishes init (`MUTATOR → FREE`). Elder E serves R: `FREE → REQUESTED`;
T2's free path consents `REQUESTED → COLLECTOR` and wakes the collector the
record names; E traces. S's bound expires, its `REQUESTED → FREE` fails
reading `COLLECTOR` — with E1 fixed to "only `COLLECTOR` is a grant", S
still cannot tell E's grant from its own: a double holder. The mirror: S's
late `REQUESTED → FREE` succeeds against E's fresh request, withdrawing a
request E is parked on; T2 reads `FREE` and returns memory, E's bound
expires with nothing. Gap: no row carries identity. `owner_record::take_record`
already treats a collector's pointer outliving a life as real. A fix has to
decide whether the byte encodes the requester's slot (two bits of state,
three of slot; `MAX_COLLECTORS` is 8), every collector-side CAS naming its
own `REQUESTED|slot` and `COLLECTOR|slot`.

**E3. The return direction is unargued, and a plain load breaks it on
ARM64** (Critic B, first). The collector acquire-loads slot S's class word
(its last row read), release-stores `COLLECTOR → FREE`; the mutator loads
the word `Relaxed`, reads `FREE`, pops S off the withheld stack,
`hand_back_and_free` writes S's flags and link, allocates S again and
stores its body. With a `Relaxed` load there is no synchronizes-with
between the collector's release and the mutator's stores: a data race by
the model, and the load-buffering shape ARM64 permits lets the collector's
not-yet-satisfied load return the new occupant's bytes. Second consequence:
the pressure path waits for `FREE` then reads R's `front` the collector
advanced before its release; read `Relaxed`, the compaction packs from a
stale `front` and disposes entries whose verdicts stand in P. Today
`is_held` is `Acquire` and its comment argues exactly this; the draft's
"one plain load, as before the fence" reads as `Relaxed`. Gap: every load
that acts on `FREE` — the slot entry, the per-pop check in
`make_returns_withheld_under_a_foreign_trace`, the chunk and block gates,
`returns_are_withheld`, the exit's — has to be `Acquire`. Loom: a slot the
taker reads before its release and the owner writes after a relaxed load
exhibits the race at once.

**E4. The collector's fence stands on the parked path alone** (Critic B).
Mutator stores the new storage head, fences, swaps
`REQUESTED → COLLECTOR`, frees the old chunk (sound). Collector's
withdrawal `REQUESTED → FREE` fails with a `Relaxed` failure ordering,
reads `COLLECTOR`, and traces with no fence between that load and its
first cell load: nothing synchronizes with the mutator's fence, the head
may read as the old chunk, and the trace strides memory the buffer arena
has handed out again — the execution `free_path_model.rs` pins as
`should_panic`. What the argument needs: `Release` on the mutator's
consent CAS (its `SeqCst` fence buys nothing over `Release` now that no
load of the mutator's is in the pair; on x86 `lock cmpxchg` is a full
barrier either way), and `Acquire` on whichever load returns `COLLECTOR` —
the parked wait's and the failed withdrawal's alike.

**E5. A mutator that never answers is never traced, and today's collector
traces it** (Critic A). A pooled worker finishes a request with its ring at
`SOFT_THRESHOLD` and blocks in `accept()`/`read()`/FFI for minutes; a thread
in a loop with no poll and no free is the same. Today the elder's round
traces it within `FALLBACK_INTERVAL_MAX`. Draft: request, park, withdraw,
every round; the owner counts as `saw_work` through `Served::TokenHeld`,
so the interval holds rather than doubling, and the garbage stands until
the thread's next free or poll. "Latency bounded by its wait" bounds one
request, not the time to a trace. Gap: in the premise — the collector's
progress becomes conditional on the mutator's activity. A fix has to
decide whether an owner that answered no request N times falls back to
today's fenced take (a fence the owner pays only on the path the fallback
armed) or is accepted as uncollected while idle.

**E6. The wait sits inside the round's serial walk** (Critic A). Collector
E serves owners A, B, C in `for_each_record` order; A is blocked (E5).
Each round: request A, park the whole bound, withdraw, then B and C — B at
backlog is served one batch per interval plus bound, k blocked owners cost
k bounds. A refusal (`REQUESTED → MUTATOR` on the pressure path or the
exit) wakes nobody, so it costs the full bound too. Today
`TraceScratchArena::open()` precedes `try_take`; in the draft the
workspace's blocks are held across the wait. No value for the bound is
named. A fix has to decide whether a round requests every owner first and
collects consents as they arrive, one wait per round with the arena
opened after the grant, or keeps the per-owner wait with a bound small
enough to bear k of them — and that a refusal wakes the collector.

**E7. A request left standing by a collector that unwinds strands the
owner** (Critic A). E swaps `FREE → REQUESTED` and unwinds before the
park (today's `ReleaseOnDrop` is installed only after `try_take`
succeeds). O's next free reads `REQUESTED`, fences, consents, wakes a
handle that is gone, withholds; every later return is withheld; O's
pressure path meets `COLLECTOR` and waits on the condition variable for a
release that never comes; O's exit waits the same; a reborn elder skips O
forever. Gap: no row for a `REQUESTED` or `COLLECTOR` whose requester is
gone. A fix has to install the unwind guard before the request — withdraw
on drop, and release if the withdrawal reads its own `COLLECTOR` — which
needs E2's identity.

**E8. The consent wake and the round-start wake are one `unpark`**
(Critic A). E requests O and parks; O's poll sends the block-filled signal
(`wake(0)`), or a pressure collection ends and wakes the elder, or
`park_timeout` returns spuriously. If E treats the return as expiry it
withdraws a request O is about to consent to: O's CAS fails, re-reads
`FREE`, returns the memory; a fence paid for nothing. A fix has to make
the wait a deadline loop that re-reads the word after every return and
treats only the word as the answer.

**E9. The poll's consent-and-skip leaves its arming's fate open, and a
poll meeting `COLLECTOR` is unspecified** (Critic A). The poll is armed —
the epoch moved, or `dispose_prefix_at_the_poll` found a proposed root in
P — and reads `REQUESTED`. Reading A: the poll consents and reaches
`take_arming()`, dropping the collection the compiler or P's proposal
armed; a root proposed twice is disposed of by nobody in between. Reading
B: the poll returns before `take_arming()`, the arming stands, the next
poll reads `COLLECTOR` and, per today's `HeldToken::take`, waits for the
batch — the cheap safepoint blocks for a trace its own consent created. A
fix has to decide whether the consenting poll keeps its arming, and
whether an armed poll meeting `COLLECTOR` waits or defers.

**E10. The collecting word is neither replaced nor placed** (Critic B).
The ordinary-path collection releases the token at the scan's end, its
window closes, the retirement frees slots through `ll_free` with the
collecting word still set; that free reads `REQUESTED`, fences, consents;
the collector now holds `COLLECTOR` while the owner rewrites P's slots and
R's blocks in place. Sound only while the collector's check of the
collecting word (`is_collecting_as_collector`) stays between observing
`COLLECTOR` and its first ring read, which the draft does not say. A fix
has to decide whether `MUTATOR` absorbs the collecting word — the ordinary
path would then hold `MUTATOR` through its teardown, changing what the
exit and the pressure path wait for — or the check is named in the
collector's paragraph.

**E11. A cross-thread free consults the freeing thread's word, not the
owner's** (Critic B). `ll_free` on thread B of thread A's slot reads B's
own record, sees `FREE`, posts the slot to A's block's remote stack,
writing a link into the dead slot's class word while A's collector holds
`COLLECTOR`. No freed memory is reached — `returns_are_withheld` holds A's
reclaim — but the collector's acquire load of that word now pairs with B's
link store, which A's consent fence does not order. Pre-existing; the rfc
lists cross-thread references as an open prerequisite (B3, B4). A fix has
to decide whose word a cross-thread free reads, or state that the
disjointness rule makes the case unreachable.

**E12. `REQUESTED` at the non-consenting readers is unspecified** (both
Critics). The slot entry consents; `withhold_chunk_under_a_foreign_trace`,
`withhold_block_under_a_foreign_trace`, `returns_are_withheld` (the remote
reclaim, `Heap::collect_remote`) and the per-pop check inside
`make_returns_withheld_under_a_foreign_trace` all read the word and are
given no arm for `REQUESTED`. Reading it as `FREE` is sound (a return
before consent is memory no cell names); reading it as `COLLECTOR` is
sound but withholds without consenting, so a thread whose frees are
chunks and blocks piles returns until the bound expires. A fix has to
decide one reading and say which entries consent, noting that
`BlockPool::put` runs from a thread-local's drop at exit and a consent
there wakes a condition variable from a destructor context.

**Survived both rounds:** the store-buffering pair itself (the collector's
first load is ordered after the mutator's *store* of `COLLECTOR`, not after
its load); a stale `FREE` while a collector holds (`COLLECTOR` is written
by the mutator's own CAS, coherence makes its later loads see it);
withdrawal against consent on one instant (one CAS, the loser re-reads);
"the release rewrote the cell before the free" in program order on every
path opened (`empty_cell` before `displaced` in the severs, `set_storage`/
`end_move` before `body_free` in the array's growth and dispose); nested
takes under the exit's kept claim; the initialisation hold as `MUTATOR`;
two siblings requesting one owner within one life; a store the mutator
makes after consent into a cell the reader cannot tolerate (none found:
the `+8` and class words are single atomic stores, a dead object is refused
on `slot_state`, an array on an incoherent head); a return before consent
that R or P still names (`CANDIDATE_BIT` refuses it before the token).

## Rulings

The Sage of 2026-09-17, one per case; each `Final`. The sections above are
the ruled form.

**E1 and E4 — one rule.** The collector acts on the value its failed swap
read back, and only its own `COLLECTOR|s` is a grant. The withdrawal is
`compare_exchange(REQUESTED|s, FREE, Relaxed, Acquire)`: success withdraws;
on failure `COLLECTOR|s` is the grant, the Acquire failure ordering pairs
with the mutator's Release consent, and the collector traces from that
read with no fence; `MUTATOR` is a refusal; `FREE` or another slot's value
is a record moved on. A grant read after the deadline is served then, not
released: the consent is paid, the owner is withholding, and the batch was
the round's purpose. The mutator's consent is Release on success — nothing
the mutator loads after the CAS is in the pair, so the draft's `SeqCst`
fence buys nothing — and Acquire on failure, because the failure's
read-back is the re-read the draft called for and a `FREE` read there is
acted on (E3). `Final`.

**E2 and E7 — one mechanism.** Identity in the byte, and the guard before
the request. Every collector-side CAS names its own slot; the mutator's
consent copies the slot bits it read and wakes the slot the byte carries,
not `hold.collector`, because in E2 the record's naming has moved with the
life and the byte has not. Both halves of E2 fall to the slot: a
withdrawal failing against `COLLECTOR|e` reads it as not mine, one failing
against `REQUESTED|e` withdraws nothing of e's. The guard replaces
`ReleaseOnDrop`, is installed before the request, and both transitions
have one writer; the arena is declared after the guard so that the rows
are reset before the token goes on the unwind as on the return, which
today's order (arena before `try_take`) does not give on the unwind.
`Final`.

**E3.** Every load that acts on `FREE` is Acquire; the mutator's take
CASes are Acquire on success and failure; both releases are Release
stores. The collector's request CAS is Acquire on success — so the grant's
reader sees the previous holder's stores through the request rather than
through the release sequence two RMWs would otherwise continue — and
Relaxed on failure, a failed request being a skip that reads nothing. The
budget holds: an acquire load is what the owner allowed. `Final`.

**E5, E6 and E8 — one mechanism.** The wait, its bound, and what an owner
that never answers costs, as the collector paragraph above has it. The
per-owner wait for answering owners keeps a consenting owner withholding
for at most one batch, where a request-all form would have every
consenting owner withhold for the round's length, moving the price onto
the mutators. The deadline loop reads only the byte, because the consent
wake and the round-start wake are one `unpark`. A refusal wakes slot s, so
a refused request ends the wait at once. The arena moves after the grant.
The first round's round-end sweep with one shared W for silent owners was
retired the same day by the second round (below): a request to a silent
owner stands until answered, so k blocked owners cost no wait at all. W:
not measured and not guessed; the fact that sets it is the tail of the
poll-or-free interval of a running mutator on the corpus, bench's to
measure. `Final`.

**E9.** The consenting poll keeps its arming; an armed poll meeting
`COLLECTOR` defers, returning before `take_arming()`. The armed poll
consents rather than takes because the batch is the trace taken off the
mutator and the in-line collection that follows one poll later reads its
verdicts; what Reading A feared is not lost — a batch that posted leaves
`POSTED` on the byte, which the next reading re-arms (the fourth round),
an epoch's re-offer stands in R where the batch reads it, and the pressure
path's arming stands in R the same way. The
rfc's "the gate is the one refusal that keeps the arming" gains a second
refusal. `Final`.

**E10.** `MUTATOR` absorbs the collecting word's exclusion: the in-line
collection holds `MUTATOR` from `CollectingThread::take` through its close
on both paths, so the retirement's frees read `MUTATOR` and return, no
consent stands on that path, and a request during the teardown fails on
`MUTATOR` in one CAS. The collecting word stays the mutator's own gate.
The rfc's "releases it after its last row read" is amended: that early
release was argued against a buffer-swap accelerator that no longer
exists, and under the two-ring design the collecting word already excluded
the collector for the collection's length, so the early release bought a
claim released at once; the rfc's open question — whether a worker may
take the token while a teardown still reads rows — closes as no. Nothing
waits longer: no thread but the mutator ever waits on `MUTATOR`, and on
the mutator's thread the gate refuses before any take. Keeping the
collecting word and naming the check was refused as the dearer form: a
consent per ordinary collection that meets a request in its teardown, a
wasted wake and release, a fourth state for the collector to reason about.
`Final`.

**E11 — out of scope.** A cross-thread free of an A-owned slot by thread B
is a reference from B into A's blocks, which the disjointness rule the
whole "Concurrency" section rests on (B3, B4) forbids; under it the case
is unreachable. The handshake adds nothing to what stands: B's link store
is unordered against A's collector today exactly as under the consent, and
B consenting on A's byte would order B's stores and not A's. When B3/B4
close, the ordering of a foreign thread's stores against A's collector is
a rule of that closure. `Final`.

**E12.** The slot entry and the poll consent; every other reader reads
`REQUESTED` and `POSTED` as `FREE`, as the free-path paragraph above has
it. The
consenting slot free withholds its own slot for uniformity: returning it
would be sound, and one slot until the batch's end is cheaper than a second
arm. `Final`.

### The second round: the silent owner and the asymmetric barrier

Edmond put the E5 question back to the Sage rather than taking it: whether
a pooled mutator blocked in a syscall keeping its cyclic garbage for the
length of its sleep is acceptable, or the asymmetric barrier is opened.

**The fact that decides it.** Under this design the collector frees
nothing. Its batch reads the owner's ring, traces a copy on its own arena,
posts one verdict per root into P and advances R; P is one block per
owner, and the batch is clamped to P's room. Every reduction of state —
the exact validation, the teardown, the slot return — is the owner's, at
its open-gate poll or in its in-line collection. A thread blocked in
`accept()` therefore holds its cyclic garbage until it wakes under every
protocol this design can carry: a collector that forced its way to the
ring while the thread slept would post at most one block of verdicts into
P, then find P without room and answer `Idle`, and the memory those
verdicts name stands until the owner's first poll disposes of them. The
barrier changes when the shortlist is made and cannot change when the
memory is returned. The figure the first round named as the one that
would reopen the premise — the memory idle pool threads' garbage holds —
is the same under the handshake and under the barrier, so it decides
nothing between them.

**What the garbage is.** A blocked thread's ring names entities that took
a non-final decrement since its last disposition. The request arena's
entities die at the reset regardless, so what a request leaves standing is
the escaped or heap-allocated residue, and of that the cyclic unreachable
part; its size on the corpus is not measured, its shape is known — a
sleeping thread registers nothing and frees nothing, so the quantity is
constant for the sleep's length and set by the last active stretch.
Growth needs activity, and activity is the poll, which consents.
Assumption stated and not verified in code: a ring entry naming a reset
arena's entity is refused before any trace reads through it; if false, it
is a defect of the ring, not of this question.

**(a) The silent owner's standing garbage is the rule.** `Final`. Bounded
in the mechanism by the amendment above: a request to a silent owner is
not withdrawn at the round's end; it stands until the owner answers or the
collector thread ends, each round sweeping the standing array first.
Served-within bound: one batch of the collector's next round after the
owner's first poll or slot free, with no probabilistic term — where a
request withdrawn at the round's end met a thread active in short bursts
only when a burst overlapped the request window. The transition table is
unchanged and no state is added; "no `REQUESTED` or `COLLECTOR` outlives
its requester" holds with the requester being the thread. The per-owner W
for an owner that answered its last request stands, for the first round's
other reason: with one outstanding request at a time at most one
consenting owner is waiting, where under request-all n owners consent
within microseconds of each other and the i-th withholds i batches. (The
reason first given here — a standing request on an active owner withholds
for the round's length — was retired by the third round: under
checkpoints every consent is served within batches.) Three interactions, each
answered by the byte's identity: an owner exiting under a standing request
refuses (`REQUESTED|s → MUTATOR`, wake), the sweep drops the entry, the
walk requests the next life afresh; a sibling ended by the elder withdraws
its standing requests in its drop, and a consent landing between the
`ENDING` word and the drop is released without a batch; an owner handed to
a sibling while the elder's request stands makes the sibling's request
fail on `REQUESTED|elder` (skip), the elder's sweep serves the grant, and
the naming word decides the next request.

**(b) The asymmetric barrier is refused, as the whole protocol and as the
fallback.** `Final`. As the whole: it lands nothing on the free path (E3's
return direction needs the same acquire load whatever the take does),
moves each batch's price onto every running core of the process
(`membarrier`: an IPI per running core, once per batch of 64
registrations, paid by threads that own none of the garbage), needs three
target forms and a fourth free path for a target with none (`membarrier`
is Linux ≥ 4.14 with a registration at startup, `FlushProcessWriteBuffers`
is Windows, macOS has neither), and places the one ordering the defect
lives in outside every instrument the crate runs: the mutator's side is an
acquire load and a compiler fence, and by the language model nothing
orders its earlier cell stores before the collector's loads — the argument
is the kernel's contract that the IPI is a full barrier on the interrupted
CPU, so loom and Miri either report the store-buffering execution or model
the syscall as a `SeqCst` fence and verify the fenced protocol of
2026-09-16 rather than the shipped one. The handshake is a release/acquire
protocol whole inside the model, exhibited and verified on the shipped
code. As the fallback (after N unanswered rounds the collector swaps
`REQUESTED|s → COLLECTOR|s` itself and issues the barrier): sound, but the
owner it would serve gains nothing — a sleeper's memory is freed at its
wake in either form — and the price is a second writer over `COLLECTOR|s`,
a second proof outside the model, the counter N and the platform code. No
owner exists that the hybrid serves and the handshake does not: emitted
code polls at every backedge and the runtime's own bulk loop carries its
poll. The barrier is not held in reserve against a measurement; the one
change that would reopen it is a change to owner-judges — the collector
freeing under an exact trace of its own — which is a premise change and
Edmond's alone.

**(c) No fallback, so the collector's behaviour is target-independent.**
`Final`. Should the barrier ever be opened on a premise change, the form is
the process-wide one; the per-thread signal is refused outright for the
`EINTR` it delivers to the blocking call it targets (`poll`, `epoll_wait`,
`select`, `nanosleep` do not restart under `SA_RESTART`, and an FFI
library whose loop does not retry fails — Go's `SIGURG` preemption of 1.14
is the precedent, cgo programs breaking on `EINTR`); a target with neither
would run the fenced take of 2026-09-16 on its free path, a second free
path per target, which is one of the reasons the whole is refused.

**(d) The instrument story.** `Final`. Loom models the byte, two cells, a
slot's class word and R's `front`, and W as a nondeterministic branch at
the wait rather than as time, so that withdraw-before-consent and
consent-before-withdraw are both explored; three executions are exhibited
under the wrong ordering and pass under the ruled one — the
store-buffering pair with a take and no consent (`free_path_model.rs`,
kept as `should_panic`), E3's return direction with a `Relaxed` load of
`FREE` at the pop, E4's failed withdrawal with a `Relaxed` failure
ordering — and three more pass: E1, a withdrawal against a pressure-path
refusal with no cell loaded after `MUTATOR`; E2, two collectors and one
record reborn, the slot bits separating the grants; the standing request,
the collector requesting, yielding, the mutator consenting later, the
collector reading the grant on its sweep, the byte the only channel. Miri
runs the crate's real tests over the diff's unsafe lines: the slot entry's
consent, the poll's consent, the exit's refusal, the guard's unwind under
a panic between the request and the wait, a record's rebirth under a
standing request, the hand-back after a release, the standing array's drop
at the thread's end. The stress test, release build, real threads, probe
counters on the collector's outcomes, shows four things: an owner blocked
on a pipe read for at least 2 × `FALLBACK_INTERVAL_MAX` with a ring of
cyclic garbage of known size gets zero batches while blocked and at least
one `Unanswered`, its byte reads `REQUESTED|s` before the pipe is written,
it gets one batch within one round after its first poll, and its
disposition frees the known count; k such sleepers beside one active owner
leave the active owner's batch interval equal to its interval alone within
the run-to-run spread; an owner freeing at full rate under continuous
requests balances consents against grants served plus refusals, makes
every withheld return at its next safepoint, and leaves the pool's counts
balanced; a consent landing mid-round starts the next round without the
timer, read off round timestamps. Bench, before the rfc amendment lands:
the poll's acquire load per statement, and the tail of the poll-or-free
interval of a running mutator on the corpus that sets W.

### The third round: the woken silent owner

Edmond's objection: a silent owner that wakes finds the standing request,
consents, and withholds from that instant — but the collector is mid-round
serving strangers and read the standing array only at the next round's
start, so the woken owner withholds for the remainder of a stranger's
round, up to (n − 1) × (W + batch), and its pressure path waits on the
condition variable for that remainder plus its batch. The second round
refused standing requests on active owners for exactly this figure and
priced the woken sleeper at its service time rather than its withholding
time. **Sustained.** `Final`.

**The fact that decides the form.** The withholding starts at the
consent's Release write and cannot be moved later: the collector's first
cell load is ordered after the mutator's stores only through the one
Release write its Acquire read pairs with, and every free the mutator
makes after that write and before the collector's read is unordered
against the collector's loads — one of them is the store-buffering
execution of 2026-09-16 exactly. No state exists in which the mutator both
returns memory freely and has given a consent the collector may later read
as a grant. What can shorten the woken owner's withholding is only when
the collector looks.

**Refused.** A soft consent — `CONSENTED|s` under which the owner keeps
returning until the collector acknowledges — is the defect the protocol
removes; making it sound needs a Release RMW per free in that window,
which the owner forbids. A mutator-side clearing of stale requests: the
byte carries no age, the slot free cannot separate a standing request from
one the collector is parked on, the poll cannot know it is the first after
a syscall return, and a refusal on every first touch defeats the standing
request's purpose. A revocable consent (`REQUESTED|s → CONSENTED|s` by
the owner, `CONSENTED|s → COLLECTOR|s` the collector's claim,
`CONSENTED|s → MUTATOR` the owner's revocation, `CONSENTED` withholding on
the free path exactly as `COLLECTOR`, a third state bit and the slot at
bits 3–5): sound, and recorded as the form to build should Edmond weigh
the pressure-path stall of a woken sleeper differently — it shortens that
wait and not the withholding — but refused here: a fifth state in every
reader's arms, one more RMW per batch, a new failure class on the grant's
reading, a second writer over the consented byte, a state more in the loom
model, against a wait of one batch on a path that is already memory
exhaustion and about to run a whole in-line trace.

**The mechanism: checkpoints on the collector's frame**, as the collector
paragraph above now has it. The bound on the woken owner's withholding:
one stranger's batch plus the batches of standing entries ahead of it that
consented in the same interval (at most k − 1) plus its own; neither W nor
the round's length enters; its pressure path and its exit wait the same
bound. In the ordinary case — one sleeper waking — one stranger's batch
plus its own, against an active owner's own batch alone; the k-way case is
the serialisation one collector with one arena imposes on any k owners
that consent at once. Cost: at most k Acquire loads and k branches per
checkpoint on the collector; nothing on the mutator. The transition table
is unchanged and no state is added; two of the collector's requests may be
outstanding at once — `REQUESTED|s` on the walk's owner and `COLLECTOR|s`
on a standing owner served inside that owner's deadline loop — which the
identity in the byte covers, the standing batch being served while the
walk's owner stands at `REQUESTED|s`, whose readers read it as `FREE`;
the standing entry's array is its guard, the walk owner's guard stands on
the frame below it, and the arena is opened inside the standing batch and
reset before its release, on the return and on the unwind. The soundness
argument gains one sentence: the checkpoint's loads are Acquire because
they act on `COLLECTOR|s`, and a checkpoint inside a stranger's deadline
loop reads the stranger's cells never. A consent landing mid-batch leaves
the park token set after its owner has been served at the next
checkpoint, so one between-rounds sleep is skipped for nothing — one empty
round per mid-batch consent at most, accepted. `Round` reads a standing
batch as a batch made, so the timer and the sibling birth see it as work.

**Instruments.** Loom's standing-request scenario gains an arm: the
collector parked on B's request, O consenting from its standing
`REQUESTED|s`, the collector serving O from inside B's loop, B consenting
during O's batch, B served after. The stress test gains a probe: a sleeper
that wakes while an active owner is being served gets its release within
one batch of the active owner after its consent, read off timestamps,
against the round's length it would take otherwise; and a pressure
collection fired by that sleeper right after its consent ends within the
same bound.

### The fourth round: the collector's batch as the mutator's trigger

**Edmond, 2026-09-17, in five lines.** The mutator accumulates roots in R.
The collector may walk them itself, and below X entries it does not take
the thread. The mutator does not collect its roots itself, except under
memory shortage. When the collector has collected P it hands them to the
mutator. The mutator then processes all of P; as an option to think
about, it also collects the entries of R whose refcount is zero. He also
ruled, against the draft's form: the trigger is made where `ll_free`
reads the byte, so the collector's release says "collect" through the
byte, and the poll is an additional caller of the same reading, not a
mechanism of its own; a refused block for R wakes the collector and does
not make the mutator collect; and the rfc is amended to the algorithm,
never cited as its authority.

**The form, after two Sage rounds and three Critic rounds** (the rulings
and the findings are in `ll-model`'s journals under 2026-09-17): the
fifth state `POSTED`, its invariant, the one reading function, the
two-valued arming word, the collection over P with its disposition on
every ending and `front` advanced last, the retirement pass holding
`POSTED` unswapped, the request's skip, the release carrying the posted
fact on the unwind, the collector born at the poll's first wake, the
non-consenting readers testing `state == COLLECTOR`, the P-only reading
leaving `signal_due` standing. What the Critic showed and the form
answers: a refused ending that left P undisposed behind `FREE` (the
disposition sits in the drop every ending reaches); a livelock of a
collection that answered `EmptyLane` before disposing of a P with no
proposed root (the count decides `EmptyLane`, the disposition runs
regardless); a root advanced past before it was traced (`front` moves
last); a mutex taken inside `ll_release` under a literal reading of
"wake" (`signal_due` is raised there, the poll sends); the stress
invariant on `POSTED` skips being ≥, not =, batches minus collections.
The zero-refcount pass over R stays an option: if built, it is bounded to
one block of R per fire by a cursor over the occupied run, the
front-block-only and capped forms refused, with a bench line before it is
called free. `Final`.

**Instruments the fourth round adds.** Loom: one more passing execution —
the collector posts a word into P and releases `POSTED`; the owner reads
`POSTED` with Acquire, arms, takes `POSTED → MUTATOR`, reads the word and
R's `front`; both read the collector's values — and E3's return-direction
exhibit run with the released value `POSTED`. Miri lines: the release to
`POSTED` after a batch, the take from `POSTED` on the poll's fire and on
the pressure path, the retirement pass around a `POSTED` P. Regression
tests, in place of those of `dispose_prefix_at_the_poll`: a batch of
read-live verdicts alone, one poll, the byte `FREE` and the roots
deferred; a retirement pass over a `POSTED` P of deaths, one poll, the
byte `FREE`; `P = [Proposed x]` with the trace refused by a forced pool
refusal, one poll, `x` found in R and P's `front` past it; a `POSTED`
owner, one collector round, `Served` neither a batch nor work and P
unchanged. The stress probe counts `POSTED` skips as rounds during which
the byte read `POSTED`.

## What is Edmond's

Nothing stands open after 2026-09-17: he approved the E10 amendment and
the fourth round's form with the rfc sentences they change, and `ll-model`
builds the whole as one stage, replacing the token's word, the record's
`owner_holds`, the collector's `serve` and the poll's reading of P. The asymmetric barrier is
closed by the second round's (b) and reopens only on a premise change of
his: the collector freeing under an exact trace of its own.
