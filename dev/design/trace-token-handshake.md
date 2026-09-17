# The trace token as a handshake

Status: ruled 2026-09-17 — drafted by the model on Edmond's proposal of
that day, attacked by two Critics, ruled by the Sage; awaiting Edmond's
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
(`ll-model`, `cycle::owner_record`), five bits used. The low two bits are
the state; bits 2–4 are the requesting collector's slot (`MAX_COLLECTORS`
is 8). `FREE` and `MUTATOR` carry slot zero, so a collector's request
expects exactly 0. The byte replaces `TraceToken::held`, the record's
`owner_holds` byte, and the collector-facing reading of the collecting
word (E10).

| state | meaning |
|---|---|
| `FREE` (0) | nobody traces this thread; the mutator returns memory at once |
| `MUTATOR` (1) | the mutator holds its own token: an in-line collection through its close, the exit's final claim, the initialisation's hold on a record not yet claimable |
| `REQUESTED\|s` (2) | collector s asks to trace; the mutator has not consented |
| `COLLECTOR\|s` (3) | collector s traces; the mutator withholds every return |

The record leaves the registry `MUTATOR`, the initialisation's end stores
`FREE`, the exit's kept claim leaves `MUTATOR` on the free list; the
registry writes nothing to the byte across lives.

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
| `COLLECTOR\|s` | `FREE` | collector s | after the last row read and the arena's reset | store Release; lock; `notify_all` |
| `FREE` | `MUTATOR` | mutator | `CollectingThread::take` on both paths, the teardown-refusal retirement, the exit | CAS Acquire / Acquire |
| `REQUESTED\|s` | `MUTATOR` | mutator | the same takers: the request is refused | CAS Acquire / Acquire; then wake s |
| `MUTATOR` | `FREE` | mutator | the close's last store; the initialisation's end | store Release |
| `COLLECTOR\|s` | (wait) | mutator | the same takers: the condition variable under the token's mutex, re-tested by CAS | — |

No other transition exists. The collector writes over `COLLECTOR|s` alone
and only its own; the mutator never writes over `COLLECTOR`. Every load
that acts on `FREE` is Acquire.

## The two sides

**Mutator, free path.** One acquire load of the byte — a plain `mov` on
x86-64, `ldar` on ARM64. `FREE`: return the memory. `COLLECTOR|any`:
withhold it, as today. `MUTATOR`: the thread's own window decides, as
today. `REQUESTED|s`, at the slot entry with no window open: consent — CAS
`REQUESTED|s → COLLECTOR|s` (Release on success, Acquire on failure), wake
slot s read from the byte, withhold this slot; a swap that fails acts on
the value it read back. The other readers — the chunk gate, the block
gate, `returns_are_withheld` for the remote reclaim, the per-pop checks of
the three drains — read `REQUESTED` as `FREE` and return: before consent
the collector has read no cell, so no address it holds names the memory.
The slot drain needs no arm of its own — its hand-back re-enters the slot
entry, which consents at the first slot, and the next pop reads `COLLECTOR`
and splices the rest back. `BlockPool::put` from a thread-local's drop at
exit reads `MUTATOR` and returns; it never wakes a condition variable.

**Mutator, poll.** The poll reads the byte once, before the gate, one
acquire load per poll. `REQUESTED|s`: consent, wake s, continue; the
arming is kept — an arming is spent by a collection that ran and by
nothing else. An armed poll that read `COLLECTOR` returns before
`take_arming()`; the next poll re-reads. A request that lands between the
reading and the take is met by the take loop, which refuses; a
`COLLECTOR` that lands there is waited for, today's wait and bound. A
closed-gate poll consents all the same, since the reading precedes the
gate. The explicit fire waits as today.

**Mutator, in-line collection.** `CollectingThread::take` takes `MUTATOR`
after the gate and after `set_collecting`: `FREE → MUTATOR`;
`REQUESTED|s → MUTATOR` with the refusal wake; `COLLECTOR` waited out on
the condition variable. The claim is released in the guard's drop after
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
reset with the line at a re-take — the request stands, guarded, through
the rest of the round in a fixed array on the round's frame (a silent
owner past the array is skipped this round); at the round's end, if any
silent request stands, the collector waits W once and sweeps: a
`COLLECTOR|s` is served, anything else withdrawn. An owner served from the
sweep loses its mark. Withdrawal: CAS `REQUESTED|s → FREE` (Relaxed
success, Acquire failure); on failure the read-back decides —
`COLLECTOR|s` is the grant and is served then, not released; `MUTATOR` is a
refusal; `FREE`, or a value with another slot, is a record moved on — the
collector holds nothing. On the grant: `TraceScratchArena::open()` (a
refusal releases at once and answers `Idle`), the batch as today, the
arena's reset, then release `COLLECTOR|s → FREE` (Release), lock,
`notify_all`. The guard's drop is the withdrawal above, and a failure
reading its own `COLLECTOR|s` releases; `note_traced_owner(null)` in the
same drop; the arena is declared after the guard and drops before it.
`Served` gains `Unanswered`, which is neither a batch nor work: the
interval doubles. A refusal is work as today.

**Fallback for an owner that never answers: none.** It is withdrawn from
and stands uncollected while silent; its garbage is held for as long as it
is blocked, and it is served within one round interval plus W of its first
poll or slot free after it wakes. This is Edmond's rule as given, and the
only sound form under the one-load budget: a forced take needs a barrier
on the mutator's side of the pair, and the free path's load cannot decide
to fence on a value it has not loaded. The one sound forced take is a
process-wide barrier after the collector's CAS (`membarrier(2)`
private-expedited on Linux, `FlushProcessWriteBuffers` on Windows), which
replaces the handshake's premise rather than completing it; it is refused
here as Edmond's to open, against one figure: the memory that idle pool
threads' standing garbage holds on the corpus.

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
not measured; since the poll is emitted per statement, bench measures it
before the rfc amendment lands. The collector pays per batch one request
CAS, a wait of at most W, one acquire load per wake inside it, the arena
opened after the grant, the batch as today, the arena's reset, and one
Release store with a lock and notify; per silent owner one request and one
withdrawal per round plus one shared W at the round's end; per refusal one
wait ended early by the wake. W is not measured and not guessed: it lands
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
the mutators; the round-end sweep puts k blocked pool threads at one
shared W instead of k·W. The deadline loop reads only the byte, because
the consent wake and the round-start wake are one `unpark`. A refusal
wakes slot s, so a refused request ends the wait at once. The arena moves
after the grant. No fallback for an owner that never answers — the ruling's
reason is in the collector paragraph, and the process-wide barrier that
would be the one sound forced take is Edmond's to open against the
blocked-thread garbage figure. W: not measured and not guessed; the fact
that sets it is the tail of the poll-or-free interval of a running mutator
on the corpus, bench's to measure. `Final`.

**E9.** The consenting poll keeps its arming; an armed poll meeting
`COLLECTOR` defers, returning before `take_arming()`. The armed poll
consents rather than takes because the batch is the trace taken off the
mutator and the in-line collection that follows one poll later reads its
verdicts; what Reading A feared is not lost — a proposal standing in P
through the batch is re-read and re-armed by `dispose_prefix_at_the_poll`
at the next open-gate poll, an epoch's re-offer stands in R where the batch
reads it, and the pressure path's arming stands in R the same way. The
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
`REQUESTED` as `FREE`, as the free-path paragraph above has it. The
consenting slot free withholds its own slot for uniformity: returning it
would be sound, and one slot until the batch's end is cheaper than a second
arm. `Final`.

## What is Edmond's

Three things this document leaves to him. Whether the handshake's
premise stands against the blocked-thread garbage figure (E5) or the
process-wide barrier is opened instead. The rfc amendment E10 implies —
the claim held through the close rather than released after the last row
read — which changes a sentence of "Concurrency" and closes its open
question. And the reading of the whole before `ll-model` builds it, since
it replaces the token's word, the record's `owner_holds`, the collector's
`serve` and the poll's reading in one stage.
