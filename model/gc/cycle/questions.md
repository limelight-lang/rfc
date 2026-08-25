# The question graph

Every open question of `rc-cycle`, as a node with what would answer it and
what it blocks. A node carries a mark for what blocks it, the same legend
the closed graph of [`../walk/questions.md`](../walk/questions.md) used:
**today** — answerable with the code and instruments that exist;
**measure** — a number nobody has taken, on instruments that exist;
**design** — a decision to be made and written;
**read** — a paper or an implementation that has to be read first;
**corpus** — blocked on a measurement of real PHP programs;
**Edmond** — his to rule.

## The graph

```mermaid
flowchart TD
    Y1[Y1 what the mutator pays per store<br/>answered: the sliding view is refused] --> Y4 & Y5 & Y9
    Y2[Y2 how much later may a destructor run<br/>answered: when death is established] --> Y9
    Y3[Y3 the class filter and its direction<br/>answered: demotion by proof, a flag only promotes] --> Y7 & Y13
    Y4[Y4 what replaces trial deletion<br/>answered: a shadow count] --> Y5 & Y7
    Y9[Y9 candidate maturation<br/>answered: age in the epoch stamp] --> Y2 & Y7
    Y10[Y10 what the enrolment test excludes<br/>answered: proven acyclicity only] --> Y7
    Y11[Y11 two release operations, the compiler choosing<br/>answered: acyclic, or deathless at the site] --> Y6 & Y10
    Y3 --> Y10
    Y5[Y5 what survives from rc-walk<br/>answered: the ownership handshake]
    Y6[Y6 the candidate set is edge-triggered<br/>answered: the buffer grows] --> Y7 & Y12
    Y7[Y7 what the header must carry<br/>design: it must not grow]
    Y8[Y8 what becomes of rc-walk and its code<br/>answered: unneeded code is deleted]
    Y12[Y12 the root queue<br/>design] --> Y7
    Y13[Y13 traversal aggression<br/>design]
```

## Y1. What the mutator pays per store, and whether the view needs enumerated roots  [answered 2026-08-25: the sliding view is refused]

The load-bearing node, and it closed the day it opened. Two papers were
read, not one: the sliding-view machinery — the barrier, the four
handshakes, the snoop, the slow-path frequencies — is Levanoni and
Petrank's (TOPLAS 2006), and the cycle collector over it — the `CRC`, the
mark/scan/collect passes, the `k + 1` maturation buffers, the root
differencing (its §4.2) — is Paz, Bacon, Kolodner, Petrank and Rajan's
(TOPLAS 2007). "The paper" below names the one whose mechanism is at hand.

**The refusal's ground, as re-argued after the Critic round of 2026-08-25:
the log is a per-store soundness cost no proof can delete, where this
design's per-release cost is deletable precision.** The original ground —
`rc-walk`'s rule that the mutator does no per-operation work for the
collector ([`../rc-walk.md`](../rc-walk.md)) — died the day it was used:
`rc-cycle` itself puts the enrolling decrement, the already-enrolled
test-and-set and the queue write on the mutator (Y9, Y11, Y12), so "no
per-operation work" refuses this design too and refuses nothing. What
actually separates the two costs is elidability. A skipped enrolment is a
deferral by Y11's covering claim, so the compiler deletes the test at every
proven site and a missed deletion costs precision; a skipped log entry is a
hole in the view and a wrong collection, so no site can be exempted — and
beside the log sits an unconditional snoop test on every store and a fence
on a weakly ordered machine when the dirty word and the slot fall in
different coherence granules, paid whether or not a collection runs.

**The counts have customers the barrier cannot serve, and that refuses the
coalesced form on its own.** Levanoni and Petrank's bargain is that the
barrier *replaces* eager retain/release, with counts reconstructed at a
collection from logged slot histories. Here the live count is read
synchronously by machinery that has nothing to do with collection: the
copy-on-write separation test (`dev/DECISIONS.md`, 2026-08-22), the
`RC − IN` root identity and the Phase 4 exact test, and the prompt
count-zero death the seventh entry chose. A count that exists only at
collection time serves none of them, so the count-replacing configuration
is out however its per-store price compares — and with it the fourth
handshake's stack scan and the §4.2 root differencing, which exist only to
compensate for deferred counting. A hybrid — the coalescing log kept, the
exact counts kept beside it — escapes that objection and the stack-scan one,
and is refused by the previous paragraph alone: it pays the log's
undeletable per-store cost on top of the counts it was meant to spare.

**The barrier's own price, for the record**, since it bounds any future
proposal of the same shape: the fast path is a load, a test and a not-taken
branch on a per-object `LogPointer`, with the slow path — copy every
non-null reference field into a thread-local buffer — taken "less than once
in a hundred" for javac and "less than once in a thousand" for the rest of
the measured set.

**One inference the reading yields and the papers do not state:** exact
counted stack references *remove* the need for the root workaround. Because
a stack reference here is counted like any other, dropping a root is a real
decrement and is seen; the blanket young-object candidacy and the root
differencing exist only to compensate for deferred counting. What that
costs is the candidate set's size — without coalescing it is Bacon–Rajan's
plain set rather than the paper's `o₀`-only one. Y9's maturation bounds the
*tracing* of that set; the enrolment traffic and the buffer footprint
remain bought, scaled by what the program touched, and no measurement of
either exists yet — the paper's 40–80 % figure was taken downstream of
coalescing and does not transfer.

**What survives separation from the barrier** — six pieces, and the sixth
is `rc-walk`'s, not the papers': the acyclic-class filter and its extension
to the traversal; the `CRC` shadow count (Y4); candidate maturation (Y9,
whose mechanism has since moved to the epoch stamp); running mark, scan and
collect over all candidates at once, which is what makes it linear rather
than quadratic; the collect stage's discipline of marking members released
before tearing them down; and the owner-thread exact test of Y5, which is
the load-bearing one — the papers' own safety mechanism against freeing an
entity that gained a reference mid-collection is the snooped set, and it
dies with the barrier, so the exact test is what stands between a white
verdict and a mutator that has just loaded a member into a counted local.
How that test squares with the collector-side free the ninth entry permits
is an open seam recorded at Y5. What else dies with the barrier: the
known-live filter — its three signals are the dirty word, the root set and
the snooped set, all absent here — and the live-stack pre-pass it feeds.

## Y2. How much later may a destructor run?  [answered 2026-08-25: when death is established]

**Ruled by Edmond: the destructor runs as soon as the death is established,
and the call is decoupled from the memory.** A count that reaches zero
destructs on the spot, as today; a cyclic component destructs at the
collection that confirms it dead. Neither call frees the block — the arena
holds it until its reset — so memory never hurries the call and never
delays it.

**The permission it narrows** stands as ruled the same day
(`../../../dev/DECISIONS.md`, sixth entry): PHP promises no instant, so
deferred and coalesced counting are not disqualified by destructor timing,
and the refusal in Y1 stands on its other two legs.

**The arena needs no collection at all.** The reset's first step is already
a trace-and-`__destruct` fixpoint over every dying object
([`../../memory/arena-reset.md`](../../memory/arena-reset.md)), so cyclic
garbage that no collection confirmed before the request ends gets its
destructor from that pass. The final collection at request end that the
open bound seemed to demand has nothing to do; the reset is the backstop.

**What the earlier open list comes to.** Before the request ends — yes, by
the backstop. Before the arena reset — yes, inside its destructor pass.
Observability — the ruling adds no observable state: a count-zero death
destructs immediately as before, and an unreachable cycle looks live until
a collection finds it under any reference-counted design, today included.
The `WeakMap` eager cleanup of `../weak-references.md` keys on count-zero
deaths and is untouched. The order of two collection-time destructors was
not ruled, and no document promises one.

## Y3. The class filter, and which way its default runs  [answered 2026-08-25: demotion by proof, a flag only promotes]

Edmond's own, 2026-08-25: classes that have held cyclic references are
suspect, and only they enter the candidate set.

**The direction has to be the other one.** "Has not been in a cycle so far"
is a fact about a run, and the next request refutes it; a class demoted on
that evidence loses its cycles for ever, because enrolment is edge-triggered
(Y6). So a class is **suspect by default** and leaves the set only by proof.

**The proof is available today, with no compiler.** A class whose declared
slots cannot hold a reference to a kind that can close a ring cannot be a
cycle member, and the crate already carries the slot kinds it needs to
decide that (`ll-model` `src/class.rs`, `SlotKind`). That is finer than
`CANDIDATE_KINDS`, which decides per entity kind, and it needs neither the
compiler ruled out of scope on 2026-08-23 nor a run's history.

**Edmond confirmed the direction on the map and added the other half:** the
runtime proves cyclicity, not just the compiler acyclicity. A collection
that finds a class's instances in a confirmed cycle may stamp the class
with a flag. The flag runs one way — it strengthens suspicion and never
demotes a class out of the set — and what it feeds is not enrolment but the
traversal's aggression, node Y13.

**What remains, and it is S6.3 unchanged:** the demotion rule written
against `SlotKind`, and the share of a real corpus's classes it demotes —
which the corpus scan already reports classes for.

## Y4. What replaces trial deletion's mutation of live counts  [answered 2026-08-25: a shadow count]

Bacon–Rajan's trial deletion decrements the object's own count during
`markGray`/`scan` and restores it in `scanBlack`. Beside a running mutator
that is a write race on the word the mutator owns, and beside a **destructor**
it is worse: user code could observe a count in a torn state.

**The answer is the paper's `CRC`, a second count field.** Mark sets
`obj.CRC := RC` on first reach and decrements the shadow thereafter; mark,
scan and collect operate solely on it, "leaving the reference count field
unmodified — thus, they do not need to be restored". The real count is
touched in exactly one place, the collect stage, and only for the non-white
children of a cycle actually reclaimed. The paper carries the shadow for its
own reason — its live set is not fixed during the algorithm — and notes that
a true snapshot would make it unnecessary; here it is load-bearing for a
different reason, and a better one: it is what lets trial deletion run at all
without disturbing the counts prompt destruction depends on.

**What it costs:** a second count field per entity, which the paper packs
with the colour and buffered bits into one 32-bit word plus an overflow hash
table. What that costs *here* is node Y7's business, and it is the same
header the candidate index already crowds.

**The alternative shape, recorded and not chosen:** Nim's YRC computes the
verdict entirely off-heap — Tarjan into a side table, deadness as array work
over the condensation — and touches the heap only at commit, where it
rechecks each member's count against the captured value. An aborted
collection then costs zero heap writes. It is worth reading before Y7 is
written, since a side table and a shadow field are two answers to one
question.

## Y5. What survives from `rc-walk`  [answered 2026-08-25: the ownership handshake]

**The census dies, the ownership discipline survives.** Ruled by Edmond on
the map: the full-heap walk leaves the design entirely — the collection
traces from the candidate set alone, and the maturation of Y9 with the
enrolment gates of Y10 and Y11 bound even that. Phase 1's census and full
edge build have no successor.

**Release is two-sided, with an asymmetric right to destruct.** Both the
mutator and the collector may free, but the collector itself may only run a
destructor proven pure ([`../pure-destructors.md`](../pure-destructors.md) —
the purity ladder returns here after leaving Y10) or tear down an entity
that has no destructor. An impure destructor runs on the owning thread.
That narrows `rc-walk`'s ruling 5 — the collector judged and only the
mutator freed — and it is what the surviving machinery is for: the
handshake, the Phase 4 exact test against current fields, the deferred-free
parking that keeps a slot from being recycled under an identifier in
flight, and eager death.

**Open seam, found by the Critic round of 2026-08-25:** the exact test's
warrant is that the owning thread holds the entity, so nothing races the
read of its current fields. A collector-side free has no such warrant — the
collector cannot read a component's counts at one instant without the
snapshot Y1 refused — so what check licenses the collector's own free of a
destructor-free entity is undesigned. The ruling names who may call the
destructor; it does not yet say what the freeing side re-verifies.

## Y6. The candidate set is edge-triggered, and a refusal is permanent  [answered 2026-08-25: the buffer grows]

Buffering fires on a decrement that does not reach zero, so a refused
enrolment is never re-offered: if that decrement was the last external
release of a garbage cycle, no later collection can find it
([`../../../runtime/exceptions.md`](../../../runtime/exceptions.md)). A derived
population has the opposite property — it is re-derived every epoch, so a
miss costs one epoch. This is the strongest recorded argument against
sourcing candidates from the mutator and it is not a cost but a class of
failure.

**The overflow rule is ruled: enrolment never drops a root.** Dropping the
candidate on a full buffer was proposed on the map and refused by Edmond —
a dropped enrolment is exactly the permanent miss this node records — and
the full-walk fallback goes with it. The buffer grows instead. Growth is
therefore a property the queue must supply natively, and the queue is node
Y12's; the double-buffered SPSC queue named there doubles its buffer on
overflow.

## Y7. What the header must carry  [design; ruled 2026-08-25: the header does not grow]

Under `rc-trace`'s shape the cycle collector owns **twenty of the flags
word's thirty-two bits**: two for the colour, one for buffered, seventeen
for the candidate index (`ll-model` `src/refcount.rs`). Bit 15 is also the
string's out-of-line bit, safe only because a string never enters the
buffer, and pinned by a test rather than by construction.

**The constraint, ruled by Edmond on the map: the header does not grow** —
no second word, no extra byte. Two directions came with the ruling. The
collection tag is first tried in the **epoch byte** `rc-walk` already
carries at offset 6 ([`../rc-walk.md`](../rc-walk.md#the-one-header-byte)),
written as today by single-byte atomic stores rather than through the flags
word. And the seventeen-bit candidate index is not needed at all: a
buffered entity is found through its entry in the root queue (Y12), which
frees the bits that made unique ownership `rc-walk`-only.

**What would answer it:** the layout of what the freed bits and the epoch
byte must now carry between them — the epoch, the maturation age (Y9), and
the mark that tells a stamp from a claim — under the same one-store
discipline the epoch byte lives by today. The layout is this repository's
to design; Edmond ruled the constraint and left the split open.

## Y8. What becomes of `rc-walk`, its registry row and its code  [answered 2026-08-25: unneeded code is deleted]

**Ruled by Edmond on the map: the code does not wait under a banner —
everything `rc-cycle` makes unneeded is deleted from `ll-model`.** That
reverses this node's opening premise, which reasoned from the
capture-count precedent (refused, kept as a record) to "superseded cannot
mean deleted"; the precedent holds for documents, which stay the record,
and not for code. The deletion follows the build: a piece goes when
`rc-cycle`'s replacement for it lands, not before there is one.

**What is still evidence-gated:** when the registry's default moves — Y1's
answer and a measurement, not a preference.

## Y9. Candidate maturation  [answered 2026-08-25: age in the epoch stamp]

**Maturation is kept, and its residence is ruled: an age carried in the
header's stamp, not a carousel of `k + 1` rotating buffers.** The rotating
form was Levanoni and Petrank's — only candidates that stayed candidates
across the last `k` collections are traced, measured there at 40–80 % of
the candidates their other filters had already passed — and Edmond chose
YRC's representation of the same idea on the map: a collection's commit
stamps each proven-live component with the current epoch and an age, the
minimum over the component's members plus one; a later claim reads the age
back, and a member whose stamp is current and whose age has reached the
promote bound has its edge pruned for the rest of the epoch instead of
being traced again. Ageing whole components rather than cells is what keeps
a component's members from maturing apart (`yrc.nim`, read 2026-08-25:
promote age 3, epoch advanced every 64 collections).

**Three more of YRC's economies come with it, taken on Edmond's ruling
("бери эти алгоритмы на вооружение"):** an *already-enrolled* bit taken by
atomic test-and-set, so an entity sits in exactly one buffer and a repeat
decrement re-enrols nothing; a start threshold deciding when a collection
runs at all — YRC's is adaptive, starting at 128 roots and moving by
outcome, which is the *trigger* lever `rc-trace`'s fixed ten thousand and
Nim ORC's `rootsThreshold` also pull, distinct from maturation's *which*
lever; and a separate suspects buffer for stamped survivors, which on
YRC's generational bench removed the 56 % of captures that were the same
survivors re-registering every collection.

**What would answer the rest:** the promote bound `k` — a measurement on a
real workload, YRC's 3 being the only known value — and the stamp's exact
residence in the header, which is Y7's layout under its no-growth rule.

## Y10. What the enrolment test excludes at the decrement  [answered 2026-08-25: proven acyclicity only]

**Ruled by Edmond on the map: the gate is one — proven acyclicity. Purity
has no bearing on enrolment.** His first phrasing named "a pure object" as
a second exclusion; shown that a class with a pure destructor still holds
references and closes rings like any other, he withdrew it: the exclusion
he meant was always the provably acyclic object. The gate is therefore
Y3's — a class property read from a bit the factory stamps into the
header, so the test is already in the word the release path loads — and
`CANDIDATE_KINDS` is the same gate at entity-kind granularity.

**Where purity does hold** is not here but in Y5: the collector may itself
run only a destructor proven pure. The purity ladder of
[`../pure-destructors.md`](../pure-destructors.md) keeps that one customer.

**What remains:** nothing at this node; the gate's cost is the one bit in
the loaded word, and the compiler's removal of the whole test is Y11.

## Y11. Two release operations, and the compiler choosing between them  [answered 2026-08-25: acyclic, or deathless at the site]

Edmond, 2026-08-25, and it is the sharpest of the three: the compiler emits
**two** decrements — a plain one, and one that also enrols a suspect — and
uses the plain one wherever it can prove the entity is held. His example is
the horizon's own shape: a reference extracted from a container that is
itself held cannot orphan a cycle by being dropped, so no suspicion arises.

**Why it matters more than the gates of Y10.** Those gates make the test
cheap; this removes the test. The candidate branch disappears entirely at
every site the proof discharges, so the mutator pays only where the compiler
could not prove anything — which is the same bargain the count elisions of
`../gc-horizon.md` struck, applied to enrolment rather than to the count
itself.

**What this repository owes, and what it does not.** The compiler's proof
logic is outside these documents since the scope ruling of 2026-08-23; what
is ours is the **contract**: two entry points on the release path, what each
guarantees, and the obligation the cheap one places on its caller. The
obligation has to be stated as a covering claim rather than as a hint,
because a wrong use of the cheap operation is not a lost optimisation — it is
a cycle no later collection can find (Y6), the enrolment being edge-triggered.
That asymmetry is what makes this node a contract question and not a
performance one.

**The covering claim is settled, 2026-08-25.** The plain decrement is legal
at exactly two kinds of site. Either the entity is provably acyclic — Y3's
proof hoisted to compile time, so the gate the enrolling form would test is
known false — or the entity provably cannot die at this site: it is held by
a reference whose own release comes later, and that later release will be
the enrolling form, so the enrolment is deferred rather than lost. Edmond's
examples of the second kind: the entity is a parameter, or was read out of
another entity that is itself held. Bare "someone still holds it after the
decrement" does not qualify — the holder may lie in the same ring, and then
this decrement was the cycle's last external release.

**What remains:** the two signatures written down, and the default without
a proof — the enrolling form everywhere, which is what the crate does
today.

## Y12. The root queue: written by the mutator, read behind it by the collector  [design]

Filed by Edmond on the map, 2026-08-25. Candidates come from the release
path itself, so the enrolment write lands on the hottest path in the
system, while the collector reads the queue in the background without
stopping the writer. The node is the algorithm with both properties, under
Y6's rule: no root is ever dropped, so the buffer grows on overflow.

**The named candidate is already built:** the double-buffered SPSC handoff
queue of the `spsc-refactor` tree, `Zend/zend_spsc_queue.{c,h}`. Its top
comment claims a writer that pays a `fetch_add` and no CAS, a reader that
pays two CAS per batch taking one buffer while the writer fills the other,
and a full buffer that doubles — but the struct comment in the same header
describes a mutex-based handoff with a resize fallback, and the
specification the file points to, `spsc-handoff-queue.md`, is absent from
the tree, so the figures are the comment's claim and S6.4 verifies them
against the code, not against a document. One writer and one reader per
queue fits enrolment — the owning thread writes, the collector reads — at
one queue per thread. Edmond also recalled, unsure, that the algorithm was
in `true-async-server`; its `src/core/thread_queue.cc` wraps the moodycamel
queues, and their SPSC fails when full instead of growing, so that tree
holds a different queue.

**Rejected the same day: YRC's striped queues.** 64 process-wide stripes of
256 fixed slots each; on overflow the writer drains the stripe itself,
becoming the collector on its own hot path, and the stripe never grows.
Both properties fail the rule above.

**A boundary the growth rule has not drawn:** growth is an allocation, and
[`../../../runtime/exceptions.md`](../../../runtime/exceptions.md) rules —
in force and implemented — that buffering a candidate root is refusable
work under allocation failure, the root dropped as a known leak. The tenth
`dev/DECISIONS.md` entry ruled the full-buffer case; whether "never drops a
root" extends to the growth allocation failing under memory exhaustion is
a price that ruling did not name, and it is Edmond's, not yet asked.

**What would answer it:** the queue's contract written for enrolment — who
owns each queue's read side, where the already-enrolled bit of Y9 is
tested relative to the queue write, what the collector's batch takes, and
the OOM boundary above — against `zend_spsc_queue.{c,h}` read first-hand.

## Y13. Traversal aggression, and what the class flag feeds  [design]

Edmond on the map, 2026-08-25: the collection will not trace every
candidate at once — some measure of aggression decides how much is traced
and when — and the flag a proven-cyclic class receives (Y3) raises that
aggression rather than gating enrolment. In his words, deliberately
unfinished: the flag "can influence the degree of aggressiveness; we will
not traverse everything at once; this is not yet clear."

**Open on purpose.** The node holds the question so the half-decision is
not lost; it interacts with Y9's trigger lever (when a collection runs) and
with maturation (which candidates it traces), and none of the three is the
same dial.

## Prior art, as of 2026-08-25

Read against this design rather than surveyed for its own sake. Nim's
**YRC** is the nearest working thing: concurrent, thread-local candidate
buffers, no stack scan, Tarjan into a side table, commit-time validation,
in devel and in no release. Its source was read first-hand on 2026-08-25
(`lib/system/yrc.nim`, devel, 1884 lines) and the read split its fate: the
striped enrolment queues are refused (Y12), while the devices against
repeated work are taken — the epoch stamp with a per-component age and
edge pruning (Y9), the already-enrolled bit, the adaptive start threshold,
the separate suspects buffer for stamped survivors, and the header word
that doubles as the cell-to-index map with stale collection tags never
swept. **scheme-rs** implements the paper's concurrent
Σ/Δ form in Rust inside a real runtime and defers every destructor.
**Samsara** is the small version of the side-table idea and is an abandoned
prototype. **bacon_rajan_cc** is the synchronous shape with deterministic
release, single-threaded by construction. **CIRC** does not collect cycles
at all — its users break them by hand — and is deferred reference counting
over epoch-based reclamation. The older reading, LXR, arborescent GC and
Kim et al.'s partial tracing, stands in
[`../gc-research.md`](../gc-research.md) and in the closed graph's F1 to F3.
