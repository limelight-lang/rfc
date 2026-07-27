# rc-walk — a barrier-free concurrent cycle collector

> **Status: design.** Nothing here is implemented. The strategy registry
> ([strategies.md](strategies.md)) gains `rc-walk` alongside `nogc`, `rc`,
> `rc-trace` and `rc-satb`. Selection stays build-time, as for every other
> strategy.

## What this collector is for

Exactly one job: **find reference cycles**. Everything else is already
reclaimed without it.

- Request-scoped entities die wholesale at arena reset ([arena-reset.md](../memory/arena-reset.md)).
  The collector never sees them.
- Everything that outlived the request dies the moment its refcount reaches
  zero — immediately, deterministically, with `__destruct` on the spot.

What neither path takes is an island of entities holding each other in a
ring: the counts never reach zero and the arena is long gone. Finding those
islands is the whole of this collector's work.

Two consequences follow, and they shape every decision below:

- **The collector may skip.** A missed cycle is memory not yet reclaimed,
  never a wrong answer. So whenever it is unsure, it does nothing and
  retries next epoch.
- **The collector may be slow.** Its cost is off the mutator's path
  entirely, so trading collector time for mutator instructions is always
  the right trade here.

## The design constraint that produced this shape

**The mutator does no per-operation work for the collector.** No write
barrier, no snapshot queue, no root publication, no safepoint park for the
walk. That rules out SATB-style concurrent marking, which pays a flag test
on every reference deletion, and it rules out stop-the-thread walking.

What is left is the mutator's *existing* bookkeeping — the refcount it
already maintains for deterministic death and for copy-on-write — plus one
masking operation, and the collector's own patience.

Two things do run on the mutator's thread, and both are bounded by garbage
found, never by store traffic: answering a **soft handshake** (one callback,
a handful of times per epoch) and draining what the collector has condemned
(Phase 4 — the frees it would have performed anyway, plus one verification
pass). Neither is a per-operation cost, which is what the constraint
forbids.

**Both ride the death branch of `ll_release`, not a compiler-inserted
poll** (decision 2026-07-27; the checkpoint originally rode the entity
factory allocation). Death is the one mutator event the protocol
actually cares about — only deaths feed recycling — and the `1 → 0`
branch is already cold and expensive (teardown, destructors), so the
checkpoint test drowns there while the fast paths pay nothing: raw
allocation, raw free (the parking test stays, it is mechanism, not
signal), the factory, and every non-final release. The checkpoint
enters **after this release's own header store and before any
teardown**, so every free the death performs observes the epoch in
program order. The second home remains the compiler's poll
(`ll_gc_maybe_collect`).

**Batched releases.** Lowering may emit a run of releases at a scope
exit. For that it emits one explicit `ll_gc_checkpoint()` for the run,
then releases each reference with `ll_release_batch` — `ll_release`
minus the checkpoint test — so the run pays the test once, not per
reference. The unbatched `ll_release` stays checkpointing, so naive
FFI callers keep the protocol alive without knowing it exists. The
single-call vector form of the same contract is
`ll_release_vector` (`model/memory/bulk-operations.md`).

The arrangement's accepted limit (2026-07-26, finding F2 in
[rc-walk-proof.md](rc-walk-proof.md), reshaped 2026-07-27): a thread
with no entity deaths — parked in a syscall, an FFI call, a pure
compute or pure-allocation loop — reaches no checkpoint, so once a
message is posted **the epoch waits for that thread's next death or
poll**: the ack and the drain ride checkpoints, and the epoch cannot
end before the drain. Deferred memory stays parked for the duration —
bounded in volume (it can only hold what already existed, so the queue
cannot exceed the live heap at epoch start) but unbounded in time.
Deliberately left without a fallback: no fairness mechanism is worth a
per-operation cost, and the memory returns at the thread's first
death or poll.

## The central identity: roots are derived, not enumerated

For any heap entity:

```
RC = (references from walked heap containers) + (references from everywhere else)
```

"Everywhere else" means a stack local, a static block, an arena slot, an
immortal container, an FFI handle. Every one of those is *counted* — the
store barrier retains on any store regardless of the holder's category.

So if the walk counts the heap-internal in-edges itself, calling that `IN`:

```
RC - IN > 0   ⟺   something outside the walked heap references this entity
```

That is the root set, **computed rather than collected**. No stack maps, no
conservative stack scanning, no shadow stack, no handshake to enumerate
roots. This is what makes a barrier-free design possible at all.

**Corollary — an un-walked region is automatically a root source.** Its
edges appear in RC and never in IN, so its targets survive. Skipping the
arenas, the immortal region, buffers and `LongLived` entities is therefore
conservative, never unsound. Skipping costs recall, never correctness.

**Why the stack never comes into it.** A reference held by a frame slot is
counted like any other, so it is already in RC and can never be in IN. The
frame announces itself through the count it takes; there is nothing left to
look up. The question "can we read the stack" belongs to strategies that
buy speed by *not* counting locals — deferred RC and stack deferral — and
must then find those references somewhere. Having paid the count, we are
owed the answer. [strategies.md](strategies.md) §2 has been corrected
accordingly.

## Prerequisite: entity blocks are segregated

Today `ll_object_new` routes `GcHeap` allocations through `ll_alloc` into
the same size-class blocks as raw `ll_malloc` buffers from the C ABI. A
walker cannot tell a live 40-byte object from a live 40-byte C buffer, and
reading the buffer's first eight bytes as a header is a wild pointer
dereference.

**Entities get their own block population** — a distinct block kind served
by its own instance of the same size-class heap. Only those blocks are
walked. This is not an Immix line allocator and does not need one; it is the
existing allocator with a separate block population.

Two more pieces of metadata:

- **The free-list link moves off the header.** A freed slot threads the
  block's free list — and the cross-thread `remote_free` stack — through
  its **first 8 bytes** (`heap.rs`, `FreeSlot`): exactly the refcount and
  flags. Any in-header stamp dies with the first free, which is why the
  first draft's FREE stamp could never have worked. In entity blocks the
  link lives at **bytes 8–15** instead; every size class is ≥ 16 bytes,
  and it is the same cache line, so the measured argument for the in-slot
  list ([heap-slot-allocation.md](../memory/heap-slot-allocation.md)) is
  untouched. Bytes 0–7 then keep the dead entity's final header —
  **refcount 0**, since an entity-block slot is freed only by entity
  teardown, which runs at count zero. `refcount != 0` is the occupancy
  test: an entity is invisible to the walker from the instant its count
  reaches zero, and there is no teardown stamp to forget.
- **A region registry**: the block pool counts regions but does not record
  their bases, so the walker cannot enumerate blocks. Eight bytes per 2 MB
  region. Registry indices are **stable handles**: entries are append-only
  while an epoch is in flight and a block is retired only between epochs,
  so `id = (registry index << k) | slot index` names the same slot for the
  whole epoch.

Promoted arena survivors live in **retained** former-arena blocks
([arena-reset.md](../memory/arena-reset.md)), which are not entity blocks
and are not in the registry: never walked, root sources by the corollary.
Their free path is a no-op — `ll_free` ignores non-heap block kinds — and
nothing ever reads the dead slot, so the case that motivated the first
draft's FREE stamp dissolves. The cost is that a ring living entirely in
retained blocks is never collected (see "What this design does not
solve").

## The compiler's acyclic flag

A class is **acyclic** when no instance of it can ever be a member of a
cycle: in the class-reference graph — a node per class, an edge per field
that can hold an instance — its node lies on no directed cycle. Bacon and
Rajan compute the same flag for the Recycler and report the candidate
population falling by roughly an order of magnitude.

The flag lives in the **class descriptor**, not in the object header. The
walker already loads the class to reach `traced_runs`, header bits are
scarce, and a collector-side load is free by the trade at the top. Kinds
that carry no class pointer — string, array, reference box — take it from
their singleton descriptor ([classes.md](../classes.md), "Entity kind").

**The walk skips an acyclic entity completely: no `rc[]` row, no out-edge
from it, no in-edge to it.** This is the corollary of the central identity
applied per class instead of per region — an omitted source only removes
in-edges, so `RC - IN` grows and the entity's targets are pinned as roots.
Both directions are conservative, so an *unsound* flag can only leak: a
wrongly marked class is never judged and its neighbours are pinned, and no
live entity is ever freed by it.

**Skipping must be total.** An edge `A → C` recorded while `rc[C]` is
omitted reads as `0 - 1 < 0`; C is then judged garbage while a live local
holds it. Row omission and edge omission are one decision, taken at one
test.

**The pinning costs at most one epoch.** An acyclic entity sits in no
cycle, so when the cycle that held it is freed its count reaches zero on
the ordinary path and its children go with it. What the flag costs is
latency, not recall.

**What the compiler owes.** A class is acyclic only if it holds for every
instance that will ever exist:

- an untyped or `mixed` field, a dynamic-property table, or a `&` reference
  box makes the class cyclic — the field can hold anything;
- an array or object field is cyclic unless the element type is known and
  itself acyclic;
- a field typed `T` reaches **every subclass of `T`**, so the graph closes
  only over a closed class set. A class that appears later — `eval`, a late
  autoload, an FFI-installed descriptor — is cyclic by default.

Every one of these is a recall decision, never a correctness one, which is
what makes the flag safe to ship before the analysis is precise.

## What the walker traces: entity kinds

An entity announces its kind in header bits 12–14 ([classes.md](../classes.md),
"Entity kind"), and the walker dispatches on it **before** touching `+8`:
only kinds 0 and 6 carry a class pointer there, and reaching for
`traced_runs` through a class that does not exist is a wild read.

- **Object (0), lazy object (6)** — traced through the class's
  `traced_runs`.
- **Array (2)** — traced through the element Boxes in its storage. Arrays
  are the spine of the commonest PHP cycle, `object → array → object`; a
  collector that skips them is decorative. The storage is a raw buffer, so
  the deferred-free bit must cover **buffer** frees too — a mid-epoch grow
  must queue the old storage, or the walker chases freed memory
  ([heap-design.md](heap-design.md)).
- **Reference box (3)** — one Value; traced.
- **String (1), WeakRef (5)** — no out-edge can close a ring (a `WeakRef`
  never strong-references its referent); their singleton descriptors carry
  the acyclic flag and the skip is total, by the rule above.
- **`Box` (4)** — wraps a C struct the walker cannot trace. Skipped
  totally: conservative, and cycles through FFI wrappers go uncollected
  (see "What this design does not solve").

## The two header bytes

Deleting the candidate buffer (bits 15-31 today) and the cycle-collector
colour bits (4-6, now collector-private) frees the top half of the flags
word. The collector claims two byte-addressable pieces of it; the
mutator's whole obligation to both is one masking operation.

**The condemned byte — object offset 7, bits 24-31.** The collector's
verdict, three-valued.

- The **collector** writes 1 into that byte to condemn an entity.
- The **mutator** does not touch it on the hot paths (amended
  2026-07-27, "The narrow mutator" below; the original design had every
  `retain`/`release` clear it as an early acquittal filter). It is read,
  in the word the release already loaded, only on the reaching-zero
  path — the F5 deferral test — whose cold branch writes **2**, the
  deferred-death marker the drain duties key on.

The refcount occupies bytes 0-3. Different addresses, plain stores on both
sides — **no atomic read-modify-write anywhere**.

**The epoch byte — object offset 6, bits 16-23.** The collector's maturity
stamp, and the answer to a question no bump cursor can answer: did this
entity exist before the epoch began? `alloc` pops the block's free list
before it bump-carves (`heap.rs`), so a slot below any snapshotted cursor
can be handed out mid-epoch — a cursor test alone misclassifies every
reused slot. Instead: the initializing store writes the flags word with
byte 6 = 0, which costs the mutator nothing it was not already writing.
The walker, meeting an occupied slot stamped 0, writes the current epoch
number into the byte and skips the entity; a slot stamped with an *older*
epoch is walked. Numbers cycle 1-255, skipping 0: after a wrap an entity
can read as current and be skipped once more — latency, not error. Races
lose stamps, never invent them — and since the narrow-mutator amendment
(2026-07-27) the mutator's counter operations no longer store the flags
half at all, so the historical caveat about a whole-word store burying a
fresh stamp is confined to the factory's initializing store, which
writes a slot no stamp has met yet. The collector pays one byte store
per new entity per epoch; the mutator pays zero, per allocation and per
operation.

**The byte is a filter, not the safety gate.** A mutator whole-word store
that clobbers a concurrent condemnation reads back as 0 and the verdict is
dropped — conservative. The reverse race — a touch landing just before the
collector's write of 1 — leaves the byte reading 1 with the touch
invisible, so the byte alone can *confirm falsely*. That is why
confirmation never frees anything: Phase 3 only decides what is worth
posting, and the exact test runs race-free in Phase 4. A lost update in
either direction can cost a wasted message or a missed epoch, never a live
entity.

One demand on codegen: the header word is read by another thread, so the
mutator's header load/store and every collector access compile as
**relaxed atomics** — the same instructions on x86-64 and AArch64, but
without the annotation the race is undefined behaviour and the compiler
may cache the header in a register across a whole loop. Still no atomic
read-modify-write anywhere.

### The narrow mutator (amended 2026-07-27)

The original design had every `retain`/`release` clear the condemned
byte — "one masking operation on a word already loaded". Measurement
(`ll-model/dev/BENCHMARKS.md`, 2026-07-27) showed what that phrasing
hid: to clear the byte the mutator must *store* the whole word, so the
counter update — a narrow `incl`/`decl [mem]` in an rc-trace build —
became a load / modify / mask / merge / store chain on every counted
operation, +0.5–0.6 ns per retain+release pair.

The amendment: **the mutator's hot paths touch only the refcount
bytes.** `retain` and a non-final `release` load the header word once
(the flags tests need it anyway), then store the *4-byte counter half
only*. No flags store, no byte clear, no whole-word reconstruction.

Why this is sound — the clear was a filter, never the gate:

- A condemned entity that stays live simply carries its byte to the
  drain. The Phase 4 exact test recomputes liveness from **current**
  fields on the owning thread; an outside reference shows up as
  `refcount > in-component in-degree`, the message is dropped whole,
  and the drop runs the acquittal duties — which clear the members'
  bytes (`walk.rs, drain_confirmed`). Every posted component ends in
  exactly one byte-clearing drain in either outcome, so byte hygiene
  never depended on the hot-path clear.
- The reaching-zero path still reads the byte it already loaded — the
  F5 deferral (a condemned entity never dies on the ordinary path) is
  untouched, and it now **mints the deferred-death marker**: the cold
  F5 branch stores the full word with the condemned byte set to **2**
  ("death deferred") and the count at zero. The acquittal duties tear
  exactly the members reading byte 2 — never a slot that died
  ordinarily before the condemnation landed and was parked, whose byte
  reads 1 over a refcount of 0. (Review finding, 2026-07-27: the
  original duties keyed on `rc == 0` alone, which could tear such a
  corpse — its class word already overwritten by the parked-free
  link. The marker is the discriminator, and it must precede or
  accompany this amendment.) The exact test gates the same way: a
  member at `rc 0` without the marker died ordinarily — the message is
  dropped without tracing that member's edges.
- What is lost is only the filter's earliness. A component touched
  after condemnation either shows a count difference and is dropped —
  at the re-check or at the drain — or was touched-and-restored (ABA),
  in which case the exact test *confirms* and frees it: correct, since
  equality at drain time proves every reference is in-component right
  then. Transient borrows no longer buy an epoch of acquittal;
  destructors of borrowed-then-abandoned cycles run one epoch earlier.
- **The collector's panic path owes acquittals.** The hot-path clear
  used to self-heal a byte stranded by a collector that condemned and
  then died before posting; with it gone, `Epoch`'s unwind path must
  post an Acquit for every condemned-but-unposted component, or a
  later ordinary death of such an entity defers to a drain that never
  comes — a permanent zombie.
- A bonus the original design listed as a caveat: with no flags-half
  stores on the mutator's *counted* hot paths, retain/release can no
  longer bury the collector's concurrent epoch stamps or condemnation
  bytes. Whole-word flag updates remain on cold mutator paths (weak
  bit, destructor bits, the dispose guard) and on the factory's
  initializing store; those races stay conservative-direction, as
  before.

The mixed-size access pair this creates — the mutator's 4-byte counter
store against the collector's 8-byte word loads and 1-byte stores —
is the same class the collector's byte stores already were: disjoint
bytes, relaxed atomics, no read-modify-write. Miri cannot see
mixed-size races (`ll-model/dev/WORKFLOW.md`); the stepped forcing
tests and the TSO argument carry this, as they already did.

## The algorithm

### Phase 1 — WALK (collector thread, no synchronisation)

The epoch opens by snapshotting the region registry and each block's bump
cursor. The cursor only bounds the scan; the epoch byte, not the cursor,
decides maturity — a free-list pop hands out slots far below any cursor
mid-epoch, so a cursor test alone misclassifies every reused slot.

> *Amended 2026-07-27 (build step 3):* the implementation snapshots **no
> cursor at all**. Reading it soundly would make the mutator's bump
> increment a relaxed-atomic store, which measured **+14% on larson**
> (`ll-model/dev/BENCHMARKS.md`) — a per-allocation cost this design
> exists to refuse. The zeroed-slot-headers commissioning rule already
> makes the full-block scan sound: a virgin slot reads refcount 0 and
> skips on the occupancy test, exactly like a freed one. The extra
> virgin-tail scan is collector-side work — the side this collector
> always chooses to pay on.

Enumerate the snapshotted blocks in address order. Per slot, a three-way
classification, entirely collector-side:

1. **Free or virgin** — `refcount == 0`, or the slot index is past the
   snapshotted cursor: skip. The occupancy test also retires the old
   mid-teardown special case — a dying entity reads zero from the moment
   teardown begins.
2. **New** — occupied, epoch byte 0 or current: created since the last
   epoch. Stamp the current epoch number and skip. **Allocate-black:**
   everything the epoch judges predates the epoch; a new entity and its
   targets are pinned as roots by the corollary.
3. **Mature** — occupied, stamped with an older epoch: walk. Skip if the
   category is not `GcHeap` or the class is acyclic; else record
   `rc[id] = refcount`, then trace by kind (above) and append every child
   that maps to a walked slot as a compact id to a flat `edges[]` array
   with per-source offsets.

The carve-to-first-store window is **closed by two rules**, not
screened (decided 2026-07-26, replacing the first draft's "screened
like every other stale read"):

- **The manager commissions every block with zeroed slot headers.**
  Free for a fresh OS commit — the kernel zero-fills anonymous pages as
  a security guarantee, paying lazily off our path. An explicit
  8-bytes-per-slot pass for any other provenance: an in-process
  recycled block, or memory returned through lazy decommit
  (`MADV_FREE` / `MEM_RESET`), which may retain stale contents.
- **The object factory publishes the header last.** Body zeroed, class
  written, then the refcount-and-flags word stored once — a single
  8-byte relaxed store, never refcount and flags separately (a torn
  pair would expose garbage kind bits and a garbage epoch byte behind a
  live count). Today's `ll_object_new` writes the header first; it is
  reordered as part of build-order step 1.

Under the two rules a slot reads `rc = 0` from block commissioning
until the instant it is a fully formed new entity, and the three-way
classification never meets bytes that lie.

**A child pointer is validated before it is dereferenced**: it must land
in a snapshotted entity block, on a slot boundary, occupied, **and the
target's epoch byte must read as an older epoch** (added 2026-07-26,
second audit). Without the epoch-byte clause the allocate-black skip is
not total: a slot reused mid-epoch passes the occupancy test, its
in-edge gets recorded while its row is skipped, and the difference
reads `0 − 1 < 0` — a live newcomer judged a non-root inside the sound
design, violating "skipping must be total". Dropping the edge instead
is the conservative direction: the newcomer's holders are already in
its `RC`, so it and its targets stay rooted. The
walker races the mutator, so it can read a torn 16-byte Box — a stale
`object` tag over a payload that is already an integer — or a slot
mid-initialization; validation makes the worst case a phantom edge or a
missed one, never a wild dereference. `rc-satb` closes the same tear with
a mutator-side WRITING bit ([satb.md](satb.md)); here the collector
absorbs it instead, because a phantom edge only costs precision — every
verdict is re-derived exactly before anything is freed (Phase 4).

Reads are unsynchronised and stale — expected; Phases 3 and 4 exist to
repair it.

### Phase 2 — DIFF and MARK (collector thread, private memory)

`in[]` is accumulated from `edges[]`; roots are `{ id : rc[id] - in[id] > 0 }`;
marking is a breadth-first walk of `edges[]` from those roots. Unmarked
entities are grouped into **weakly** connected components — edges
followed in both directions — so a garland of linked garbage rings is
judged and freed as one unit in one epoch (decided 2026-07-26; strong
connectivity would free a chain one ring per epoch, each costing a full
walk). The price is granularity: one touched member acquits the whole
group until the next epoch. **A cycle is judged and freed as a unit,
never member by member.**

All of this happens inside the collector's own arrays. It touches no
mutator memory and contends for no cache line.

The snapshot is not free in space: `rc[]` and `edges[]` materialize the
walked graph in collector-private memory — roughly 12 bytes per entity
plus 4 per edge, so a million entities with four million edges hold
~30 MB for the epoch. It scales with the walked heap, not the process,
and the re-checks below touch only the candidate subset. This is the
collector-side bill for keeping the mutator's side at zero.

### Phase 3 — CONDEMN and FILTER

The walk read a moving graph, so every component is a hypothesis. Phase 3
filters hypotheses cheaply; it does not prove them — proof belongs to
Phase 4, where it can be had race-free.

1. **Condemn**: write 1 into the condemned byte of every member of every
   candidate component.
2. **Handshake**: raise the request flag; the mutator's next trip through
   the allocator runs a callback — a release fence and an ack — and
   continues. Nobody parks. After the ack, every mutator write that
   preceded the checkpoint is visible to the collector. (The soft-handshake
   idiom FUGC is built on.)
3. **Re-check**: re-read each member's refcount and each recorded in-edge
   source slot against the walk's snapshot, then re-read the bytes. **Any
   difference acquits the whole component**: a changed count, a moved
   edge, a cleared byte. The filter is snapshot comparison, not a
   recomputation of `RC − IN` (canonised 2026-07-26: comparison is
   simpler, strictly more acquittal-prone — drift that happens to
   preserve the balance still acquits — and it is the filter the TLC
   battery verified; an earlier draft of this step described both
   filters in one breath).

The windows dovetail. A touch *before* the condemnation is invisible to
the byte — it cleared a byte that was already 0, and the write of 1 then
buried the evidence — but the post-handshake re-read sees its effect on
the counts and slots. A touch *after* the condemnation clears the byte.
The residue — a touch after the ack whose effects the racy re-read happens
to miss — survives the filter and is caught in Phase 4. One touched member
acquits the component, because the verdict is per-component and so is the
proof.

**An acquittal is a message too** (2026-07-26, second audit — this
replaces the same-day draft that had the collector perform the
cleanup itself). The condemned-never-die rule leaves two duties behind
every dropped verdict: clear the members' condemned bytes, so a later
ordinary death does not defer to a drain that is no longer coming, and
tear down any member whose count already reached zero while
condemned — its deferred death has no other hand left to run it. Both
duties are **mutator work** — the tear runs destructors and releases —
so the collector must not perform them: it posts an *acquittal
message*, and the owning thread's next checkpoint clears the bytes and
tears the deferred deaths on its own thread, race-free, under the same
shelter as the drain. Every condemned component therefore ends in
exactly one mutator-side message — confirm or acquit — and the
collector's writes to shared memory remain exactly two: stamps and
condemnation bytes. (The collector-side draft had an unfixable race:
its byte-clear could lose against a concurrent release that still saw
the condemned byte, minting a zombie after the cleanup had already
scanned — permanently invisible at `rc = 0`, destructor never run, its
children pinned forever.) The component is re-judged next epoch.

### Phase 4 — VERIFY and RELEASE (mutator thread, by message)

Confirmed components are posted to the owning mutator thread, which drains
the queue at its next checkpoint — a death or the poll. The collector never
frees anything itself — and the drain trusts nothing it was told.

**The drain is not re-entrant** (decided 2026-07-26, finding F8;
restated for the 2026-07-27 checkpoint move). A destructor run by the
drain releases references, and a release hitting zero is a checkpoint
inside the drain. One thread-local mid-drain bit closes the recursion:
the nested entry acks a pending handshake, but never picks up a
message.

**The exact test.** The drain runs on the mutator's own thread, so nothing
races it: this is the one place a verdict can be checked against the true
graph at zero coordination cost. Before anything else, per component:
every member's `refcount` equals its in-component in-degree, recomputed
from the members' **current** fields.
Counted references account exactly, so the equality says every reference
to every member comes from inside the component — garbage by the central
identity, and nothing can unsay it while the check holds the thread. Any
mismatch drops the message whole. A falsely posted component costs one
verification pass — never a destructor and never a free *of a live
member*; the drop still performs the acquittal duties, and tearing a
member that died while condemned runs the destructor that death
already owed.

**A condemned entity never dies on the ordinary path** (decided
2026-07-26; replaces the first draft's false claim that a dead member
always reads a mismatching in-degree — under I1 a dead member's
in-degree is always zero and `0 = 0` would balance, finding F5,
[rc-walk-proof.md](rc-walk-proof.md)). A release that reaches zero on
an entity whose condemned byte is set skips teardown: the count stays
zero and the entity now belongs to the drain, which finds it balanced
(`0 = 0`), runs its still-unrun destructor, severs and frees it —
exactly once, merely later. The release observes the byte in the header
word it already loaded, *before* its own masking clears it. Deferring
`__destruct` past the last release for these entities is accepted
semantics. A death *before* the condemnation is caught earlier, by the
Phase 3 count re-read. One consequence for the acquittal path: a
dropped message must still tear down any member whose count reached
zero while condemned — its death was deferred to exactly this drain —
and clear the dropped members' condemned bytes (see Phase 3).

Then the discipline `run_cyclic_destructors` (`gc.rs`) already proves,
minus its restore step — `rc-trace` verifies by trial deletion and must
first undo it; rc-walk's counts are already real:

1. **Guard** every member (`refcount += 1`): a release from inside a
   destructor stops at the guard, never at zero.
2. **Run** each pending `__destruct` exactly once (`DESTRUCTOR_RAN`). PHP
   code, on the request thread, with its own context; it may resurrect —
   a store retains normally.
3. **Re-verify** the exact test, **discounting the guards**: while the
   Phase 4 guard is outstanding, the equality is
   `refcount − 1 = indeg_K`. Without the discount the literal test can
   never pass — the guard itself unbalances every member, every
   component acquits, and nothing is ever freed (finding F1,
   [rc-walk-proof.md](rc-walk-proof.md)). A destructor that stored a
   member anywhere gave it `RC > IN` beyond the guard: the component is
   acquitted, guards come off through `ll_release`, and the survivors
   live on with true counts and their destructors behind them.
4. **Sever and free**: each member releases its current children through
   `ll_release`, nulling the slot — in-component children stop at their
   guards; children outside the component die ordinarily, destructors and
   all. Then un-guard through `ll_release`: every member reaches a true
   zero and takes the ordinary free path (`dispose` finds the fields
   already null and `DESTRUCTOR_RAN` already set). *Amended 2026-07-26
   (build step 2):* the drops of severed **external** children are
   deferred until after the members are freed, so between sever and free
   no user code runs at all. The exact test already proves an external
   `__destruct` could not name a member; the deferral makes the
   no-resurrected-hollow-member property structural rather than
   proof-dependent — the property survives weak references and FFI,
   where the proof does not. (CPython reaches the same safety from the
   other side: PEP 442 requires a finalized object to tolerate cleared
   referents.)

The first draft said "un-guard and let ordinary teardown decide". That was
wrong twice: without severing, a pure cycle's members keep
`refcount = in-degree` and never reach zero, so nothing is ever freed; and
`rc-trace` only escapes this because `mark_gray` already trial-deleted the
internal edges and deliberately never restored them. Severing is the price
of validating with real counts instead of trial ones.

### Deferred physical release, and when an epoch ends

While a walk is in flight, memory released by ordinary refcount death is
**queued rather than recycled** — the GC activity bit of
[heap-design.md](heap-design.md), which must cover raw buffer frees as
well as entity slots (the walker chases array storage). The entity dies
normally and on time, `__destruct` included; only reuse waits, so the
walker cannot read a slot that has become a different object underneath
it.

Now that every read is validated and every verdict re-derived, the
queue's real job is **identity**: an id must name one entity from walk to
drain. Without the queue a slot could be freed and recycled mid-epoch,
and the Phase 4 equality could balance by coincidence on an object that
was never judged. That is a soundness role — the queue is not optional.

**The epoch ends only after every verdict message — confirmation or
acquittal — is acknowledged.** The queue flush, block retirement and the
next walk all wait for them. This closes two holes
at once: a posted message can never name a slot recycled underneath it,
and the collector can never condemn the same entity twice with two
messages in flight — at most one epoch's verdict is outstanding, ever.

This is one load and a predicted branch on the free path, active only
during an epoch.

## What the mutator pays, in total

| | |
|---|---|
| `retain` / `release` | nothing beyond the counter itself: one header load (the flags tests need it anyway), one narrow 4-byte counter store — no flags store, no masking (narrow-mutator amendment, 2026-07-27) |
| allocation | nothing — slot classification (free / new / mature) is collector-side, from the refcount word and the epoch byte |
| memory release | one flag test while an epoch is in flight; on the reaching-zero path only, one test of the condemned byte (in the word already loaded) and the checkpoint test |
| per epoch | a handful of handshake acks — one callback each, at a checkpoint |
| per confirmed component | the Phase 4 drain: one verification pass plus the frees it would have performed anyway |
| everything else | nothing |

No barrier on reference stores. No queue. No park. No atomic
read-modify-write. In a build without this collector, none of the above is
emitted.

Against `rc-trace` as implemented today this is a net **reduction**:
`ll_release` loses the candidate-buffer test and call it performs on every
non-zero decrement, and the header loses 17 bits of candidate index.

## Where the errors point

Staleness is not symmetric, and the first draft's blanket "always
conservative" was false. Toward **leaking**, which is safe: a missed edge,
a stale-high refcount, a skipped kind, a skipped region, allocate-black.
Toward **false condemnation**, which must be caught: a duplicate edge from
a reference read in both its old and new homes mid-migration; a dead
entity's out-edges read racing the final decrement (the occupancy test
closes the teardown window down to that one racy read); a
phantom edge from a torn Box; a stale-low refcount read before a retain.
Everything in the second list survives at most to the Phase 3 re-check,
and nothing survives the Phase 4 exact test. The honest claim is not "the
walk is conservative" — it is "the walk may be wrong in both directions,
because nothing it says is acted on until a race-free test agrees."

## Convergence and the failure mode

Validation can starve: a workload that keeps touching the same entities
never lets a component stay untouched long enough to be confirmed. Then
nothing is collected and memory grows.

The escalation ladder, in order, with the mutator never drafted into
collector work:

1. Re-run the epoch — cheap, and the population of true cycles is stable
   while the population of hot objects is not.
2. Re-walk only the candidate set to a fixpoint: condemn, handshake,
   re-check, repeat until two consecutive rounds agree. Candidates are a
   small fraction of the heap, so rounds are cheap. (FUGC terminates its
   marking the same way.)
3. As a last resort, park the mutator at one checkpoint for the length of a
   candidate re-check — bounded by candidate count, not by heap. This is
   a pause, and it is the fallback, not the design.

The queue of deferred releases also grows for the duration of an epoch: a
slower collector costs memory. Both of these are measurements, not
arguments — they must be taken on real workloads before any threshold is
fixed.

## Rejected: OS dirty-page tracking

The first draft validated with a second mechanism — `GetWriteWatch` /
soft-dirty — claiming it "costs the mutator nothing; the MMU already
tracks it". Both halves failed inspection. It was load-bearing, not
complementary: the condemned byte cannot testify about the window before
the condemnation (the write of 1 buries the evidence), so dirty pages were
the only cover for the walk-to-condemn window — soundness, not recall. And
it is not free: a Linux soft-dirty reset write-protects the PTEs, costing
a TLB flush per reset and one write fault per touched page per epoch, paid
by the mutator; Windows demands `MEM_WRITE_WATCH` at reservation time; and
4 KB pages against 64-byte headers turn every hot neighbour into a false
acquittal. The handshake re-check covers the same window for less, and the
Phase 4 exact test ends the soundness question. Dirty pages buy nothing
the two together leave unbought.

## What this design does not solve

- **Uncounted borrows.** A `retain` the ARC optimiser elided is invisible:
  no count, no cleared byte — and no trace in the Phase 4 exact test
  either, which balances *counted* references only. If the covering
  reference lives in an object that turns out to be cyclic garbage, the
  borrowed entity is freed under a live local. The rule the optimiser must
  follow: an elided borrow is legal only when covered by a counted
  reference the collector treats as a **root** — a frame slot, an arena
  slot, a static, an immortal, an FFI handle. Covering "by a field of some
  heap object" is not enough, because that object may itself be garbage,
  and the acyclic flag does not rescue it either. This obligation is
  independent of which collector is chosen — it applies to `rc-trace`
  today — and is now written down with its worked cases in
  [static-lifetimes.md](../memory/static-lifetimes.md), "What may own a
  borrow".
- **Weak references.** Designed, not yet built — see
  [weak-references.md](../weak-references.md) (2026-07-27). The shape
  refined the earlier side-entry sketch: the canonical `WeakRef` entity
  *is* the shared cell (holders count the entity, never the target), and
  the dying object finds it through a per-thread weak table whose row
  lists its subscribers; the drain nulls the cell's target field. One
  obligation is binding on that design (2026-07-26): **every weak cell
  naming a confirmed member is nulled before the drain runs any user
  code** — a weak load is the one channel that can hand a destructor a
  pointer counted references cannot account for, and the drain's safety
  argument ("no external reference to a member exists" — the exact test)
  holds only in the counted world. CPython closes the identical window
  the same way: PEP 442 clears weak references to cyclic garbage before
  any finalizer runs. The nulling runs in the mutator's drain checkpoint,
  so the collector thread never touches the weak table.
- **Huge objects** in OS-direct block runs are outside the pool regions and
  cannot be enumerated by the registry. Cycles through them are not
  collected; the edge is skipped, which is conservative.
- **Cycles through FFI wrappers.** A `Box` (kind 4) wraps a C struct the
  walker cannot trace, so it is skipped totally and a ring passing through
  one is never collected. Conservative; revisit if FFI-heavy workloads
  leak.
- **Cycles among promoted survivors.** Retained former-arena blocks sit
  outside the registry, so their occupants are never walked — root
  sources, by the corollary. A ring living entirely in retained blocks is
  never collected. Conservative; revisit if promotion-heavy workloads
  leak.
- **Multiple mutator threads** sharing `GcHeap` entities. Refcounts are
  non-atomic today, so the crate is single-mutator; actors will force this
  question and may force a per-thread epoch protocol — and will take the
  Phase 4 exact test with them, since its race-freedom *is* the
  single-mutator guarantee.

## Open questions before implementation

1. **When the collector decides to run at all.** The runtime owns the
   trigger signals: how much deferred memory, how many suspected
   components, how long since the last epoch. Every threshold here is a
   measurement nobody has taken.
2. **Relaxed-atomic header accesses** are asserted zero-cost on x86-64 and
   AArch64; verify against generated code that no coalescing or fusion is
   lost before the cost table's claim is committed.
3. **Whether the fixpoint rung of the ladder earns its keep** over plain
   epoch re-runs — a measurement, on a workload that actually starves.

## Build order

1. Entity block segregation, the free-list link moved to bytes 8–15, the
   region registry with stable indices, the kind-dispatched tracers.
   Required by any walking collector, useful on its own as a heap census.
2. A synchronous walk fired at an explicit call: diff, mark, components,
   then the full Phase 4 drain — exact test included — inline. No
   collector thread, no filter: a whole-heap leak detector and the exact
   test's correctness harness.
3. The collector thread, the epoch and condemned bytes, the handshake
   filter, the message queue and the epoch/drain ordering, the
   deferred-free bit extended to buffers.
4. Weak references.
5. The escalation ladder past rung 1, if measurement shows starvation.

`rc-trace` (`gc.rs`, Bacon–Rajan) stays in the registry throughout as the
single-threaded strategy, so the two can be compared on the same workload.
