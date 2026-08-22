# rc-walk — a barrier-free concurrent cycle collector

> **Status: design, partially built.** Build steps 1–4 and the
> batched-checkpoint split are product code in `ll-model` (the
> `rc-walk` cargo feature, the default build since 2026-07-27); of the
> 2026-07-28 amendments, the forced verdict and the pressure ladder
> remain design ahead of code, each flagged "code lag" in place. The
> strategy registry
> ([strategies.md](strategies.md)) carries `rc-walk` alongside `nogc`,
> `rc`, `rc-trace` and `rc-satb`; selection stays build-time, as for
> every other strategy.

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

**The death-branch checkpoint acks; pickup rides teardown's exit**
(review finding, 2026-07-27 — found attacking the eager-death
amendment, but opened by the checkpoint move itself). Between the
death's committing zero store and its dispose, the dying entity is in
a state no user code may observe: committed dead, weak cell not yet
nulled. A checkpoint that picks up a verdict message there runs drain
destructors — user code — and a destructor holding a `WeakRef` to the
dying entity gets a strong reference to it (`get()` retains whatever
the cell holds): resurrection after commit, or a second teardown when
the drain's own release reaches zero first — DC0 through the front
door. So the checkpoint is split: the **death branch acks the
handshake only** (that is the part whose before-teardown position is
load-bearing — the activity bit is observed before this death's
frees); **message pickup and the parked flush run at the exit of the
outermost dispose**, when the entity is whole again — dead and
disposed, or resurrected and live. The poll and the explicit batched
checkpoint pick up as before: they run between operations, where
nothing is mid-commit.

**Batched releases.** Lowering may emit a run of releases at a scope
exit. For that it emits one explicit `ll_gc_checkpoint()` for the run,
then releases each reference with `ll_release_batch` — `ll_release`
minus the checkpoint test — so the run pays the test once, not per
reference. The unbatched `ll_release` stays checkpointing, so naive
FFI callers keep the protocol alive without knowing it exists. The
single-call vector form of the same contract is
`ll_release_vector` (`model/memory/bulk-operations.md`).

*Amended 2026-07-28: the batched checkpoint splits like the death
branch —* **ack before the run, pickup after it.** The original
single pre-run checkpoint picked up messages while the scope's
transients were still counted, which is the wrong instant twice over:
a drain observing a transient borrow acquits a component the very
next instruction returns to garbage, and a loop whose only
checkpoints are scope exits then presents *every* pickup with the
same held borrow — the phase-lock that defeats the forced verdict
below. After eager death the trailing pickup is nearly free: any
death inside the run already picks up at its dispose's exit, so the
trailing `ll_gc_checkpoint` matters only for death-free runs — and
those are exactly the runs whose releases just returned transients to
their true counts. The ack stays in front (handshake latency; the
activity bit is observed before the run's frees, as on the death
branch). **The same split binds `ll_release_vector`** — the vector
form's checkpoint-at-entry is the condemned pre-run pickup under
another name ([bulk-operations.md](../memory/bulk-operations.md)
amended). In code since 2026-07-28: `ll_gc_checkpoint_ack` fronts the
run, the trailing `ll_gc_checkpoint` picks up, and the vector form
carries the same split — pinned by a regression in the phase-lock
shape (a posted component judged against the very reference the run
releases).

The arrangement's accepted limit (2026-07-26, finding F2 in
[rc-walk-proof.md](rc-walk-proof.md), reshaped 2026-07-27): a thread
with no entity deaths — parked in a syscall, an FFI call, a pure
compute or pure-allocation loop — reaches no checkpoint, so once a
message is posted **the epoch waits for that thread's next death or
poll**: the ack and the drain ride checkpoints, and the epoch cannot
end before the drain. Deferred memory stays parked for the duration —
and (corrected 2026-07-27, worst-case review of the eager-death
amendment) it is bounded only by **churn rate × epoch duration**, not
by the live heap: every mid-epoch death parks, including entities
allocated after the epoch opened, and every buffer free parks with
them. The old "cannot exceed the live heap at epoch start" bound was
derived under the F5 deferral and did not survive it. A long walk
followed by a checkpoint-free stall can therefore park a multiple of
the live heap. Deliberately still without a mutator-side fallback: no
fairness mechanism is worth a per-operation cost, and the memory
returns at the thread's first death or poll. Two collector-side
bounding mechanisms are recorded in `BACKLOG.md` — an epoch abort on
a parked-volume watermark (sound while nothing is posted: the
identity obligation only runs from walk to drain of posted messages)
and a young-free exemption (an entity whose epoch byte reads
0/current at free time is in no snapshot row and no component; its
slot appears recyclable at the cost of one byte test on the cold
parked path, plus a publication of the current epoch number, which
nothing performs today) — both unbuilt, both needing their own proof
pass.

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
that carry no class pointer — string, array, ReferenceBox — take it from
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
only the object and lazy kinds carry a class pointer there, and reaching for
`traced_runs` through a class that does not exist is a wild read.

**The concurrent walker is this walk, not a second one.** It differs only
in reading the entity's own words relaxed-atomically instead of plainly —
which it must, since a plain read against a live mutator's store is
undefined behaviour rather than the torn read Phases 3 and 4 exist to
repair — so it is the same per-layout stride under a different reader
([classes.md](../classes.md), "Why tracing stays data"). A separate copy
of each stride for the collector is how kinds came to be traced by one
walk and missed by another.

- **Object (0), lazy object (6)** — traced through the class's
  `traced_runs`.
- **Array (2)** — traced through the element ValueBoxes in its storage. Arrays
  are the spine of the commonest PHP cycle, `object → array → object`; a
  collector that skips them is decorative. The storage is a raw buffer, so
  the deferred-free bit must cover **buffer** frees too — a mid-epoch grow
  must queue the old storage, or the walker chases freed memory
  ([heap-design.md](heap-design.md)).
- **ReferenceBox (3)** — one Value; traced.
- **String (1), WeakRef (5)** — no out-edge can close a ring (a `WeakRef`
  never strong-references its referent); their singleton descriptors carry
  the acyclic flag and the skip is total, by the rule above.
- **`FFIBox` (4)** — wraps a C struct the walker cannot trace. Skipped
  totally: conservative, and cycles through FFI wrappers go uncollected
  (see "What this design does not solve").

## The one header byte

Deleting the candidate buffer (bits 15-31 today) and the cycle-collector
colour bits (4-6, now collector-private) frees the top half of the flags
word. The collector claims one byte-addressable piece of it; the
mutator's obligation to it is zero.

> *Amended 2026-07-27 (the eager-death amendment).* Until this date the
> design claimed a second byte — the **condemned byte** at offset 7,
> the collector's three-valued verdict, tested by the mutator on the
> reaching-zero path (the F5 deferral) and cleared by drain duties.
> Eager death (Phase 4 below) removed the deferral, and with it the
> byte's last reader: the Phase 3 filter re-reads counts and edge
> sources, not bytes (the narrow mutator had already ended the
> byte-clearing filter), and the death path no longer consults the
> collector at all. Condemnation is now **collector-private state**;
> the collector's only write to shared memory is the epoch stamp, and
> bits 24-31 return to the free pool
> ([layouts.md](../layouts.md) amended).

The refcount occupies bytes 0-3, the collector's byte sits at offset 6.
Different addresses, plain stores on both sides — **no atomic
read-modify-write anywhere**.

**The epoch byte — object offset 6, bits 16-23.** The collector's maturity
stamp, and the answer to a question no bump cursor can answer: did this
entity exist before the epoch began? `alloc` pops the block's free list
before it bump-carves (`heap.rs`), so a slot below any snapshotted cursor
can be handed out mid-epoch — a cursor test alone misclassifies every
reused slot. Instead: the initializing store writes the flags word with
byte 6 = 0, which costs the mutator nothing it was not already writing.
The walker, meeting an occupied slot whose byte reads 0 or the current
number, writes the current epoch number into the byte and skips the entity;
a slot stamped with an *older* epoch is walked. Numbers cycle 1-255, skipping 0: after a wrap an entity
can read as current and be skipped once more — latency, not error. Races
lose stamps, never invent them — and since the narrow-mutator amendment
(2026-07-27) the mutator's counter operations no longer store the flags
half at all, so the historical caveat about a whole-word store burying a
fresh stamp is confined to the factory's initializing store, which
writes a slot no stamp has met yet. The collector pays one byte store
per new entity per epoch; the mutator pays zero, per allocation and per
operation.

**No byte is a safety gate.** Phase 3 only decides what is worth
posting, and the exact test runs race-free in Phase 4; a lost or stale
read anywhere in the marking machinery can cost a wasted message or a
missed epoch, never a live entity.

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

- A condemned entity that stays live is caught without any byte. The
  Phase 4 exact test recomputes liveness from **current** fields on
  the owning thread; an outside reference shows up as
  `refcount > in-component in-degree` and the message is dropped
  whole.
- What is lost is only the filter's earliness. A component touched
  after condemnation either shows a count difference and is dropped —
  at the re-check or at the drain — or was touched-and-restored (ABA),
  in which case the exact test *confirms* and frees it: correct, since
  equality at drain time proves every reference is in-component right
  then. Transient borrows no longer buy an epoch of acquittal;
  destructors of borrowed-then-abandoned cycles run one epoch earlier.
- A bonus the original design listed as a caveat: with no flags-half
  stores on the mutator's *counted* hot paths, retain/release can no
  longer bury the collector's concurrent epoch stamps. Whole-word flag
  updates remain on cold mutator paths (weak bit, destructor bits, the
  dispose guard) and on the factory's initializing store; those races
  stay conservative-direction, as before.

The same day's second amendment finished the movement: the reaching-zero
path originally kept one byte test — the F5 deferral, whose cold branch
minted a deferred-death marker for the drain duties to key on. **Eager
death** (Phase 4) deleted the deferral, the marker, and the byte itself;
the death branch now carries the checkpoint test and nothing else. The
history is kept in [rc-walk-proof.md](rc-walk-proof.md) (F5) and
[rc-walk-danger-cases.md](rc-walk-danger-cases.md) (DC0).

The mixed-size access pair this creates — the mutator's 4-byte counter
store against the collector's 8-byte word loads and 1-byte stores —
is the same class the collector's byte stores already were: disjoint
bytes, relaxed atomics, no read-modify-write. Miri cannot see
mixed-size races (`ll-model/dev/WORKFLOW.md`); the stepped forcing
tests and the TSO argument carry this, as they already did.

The drain itself never races the collector at all: from a component's
posted verdict to its acked drain the collector provably performs no
access to that component — the **drain-exclusivity window**, proven
and TLC-checked in [drain-window.md](drain-window.md) (2026-07-27).

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
walker races the mutator, so it can read a torn 16-byte ValueBox — a stale
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

1. **Condemn**: mark every member of every candidate component in the
   collector's private tables. *Amended 2026-07-27 (eager death): this
   step used to write 1 into a shared condemned byte; the byte is gone.
   Nothing is written to shared memory — the heap does not know a
   verdict exists.*
2. **Handshake**: raise the request flag; the mutator's next checkpoint
   runs a callback — a release fence and an ack — and continues. Nobody
   parks. After the ack, every mutator write that preceded the
   checkpoint is visible to the collector. (The soft-handshake idiom
   FUGC is built on.)
3. **Re-check**: re-read each member's refcount and each recorded in-edge
   source slot against the walk's snapshot. **Any difference acquits the
   whole component**: a changed count, a moved edge. The filter is
   snapshot comparison, not a recomputation of `RC − IN` (canonised
   2026-07-26: comparison is simpler, strictly more acquittal-prone —
   drift that happens to preserve the balance still acquits — and it is
   the filter the TLC battery verified; an earlier draft of this step
   described both filters in one breath).

A touch *before* the handshake shows in the re-read counts and slots.
The residue — a touch after the ack whose effects the racy re-read
happens to miss — survives the filter and is caught in Phase 4. One
touched member acquits the component, because the verdict is
per-component and so is the proof.

**An acquittal is collector-private** (amended 2026-07-27; from
2026-07-26 to this date it was a mutator-side message, because the
condemned-never-die rule left two duties behind every dropped verdict:
clearing the members' condemned bytes and tearing any member whose
death had been deferred to the drain). Eager death dissolved both
duties — there are no bytes to clear and no deferred deaths to tear; a
member that dies while condemned dies whole, on the ordinary path, at
the natural point. A dropped hypothesis is now dropped in the
collector's own tables: no message, no checkpoint work, and the
component is re-judged next epoch. Only confirmations are posted, and
the collector's writes to shared memory are exactly one kind — epoch
stamps. (The zombie race that once forced the message-based acquittal —
a collector-side byte-clear losing against a concurrent release that
still saw the byte — is not repaired but removed: there is no byte and
no deferral left for a race to strand.)

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

**The corpse rule: the drain header-scans before it trusts.** Per
member, the refcount word is read **first**; only when every member
reads `refcount > 0` does the drain touch any field. A member reading
zero is a corpse — it died ordinarily since the verdict was posted, its
teardown is complete, its free is queued — and its presence drops the
message whole, before any field is traced and before any guard is
written. A corpse must never be trusted past its first eight bytes:
the slot is parked, so bytes 0-7 still hold the final header
(refcount 0); the class word survives too — **parking is out-of-band**
(review finding, 2026-07-27: the first draft threaded an in-slot park
link through bytes 8-15, which is exactly the class word the walker
dereferences one pass after reading the header — a wild read under
the walker's feet; the park list lives beside the slots, and nothing
writes a parked slot until the post-epoch flush) — but the fields
beyond are teardown residue, and the drain has no business reading
them.

**The exact test.** The drain runs on the mutator's own thread, so nothing
races it: this is the one place a verdict can be checked against the true
graph at zero coordination cost. Per component:
every member's `refcount` equals its in-component in-degree, recomputed
from the members' **current** fields.
Counted references account exactly, so the equality says every reference
to every member comes from inside the component — garbage by the central
identity, and nothing can unsay it while the check holds the thread. Any
mismatch drops the message whole. A falsely posted component costs one
verification pass — never a destructor and never a free *of a live
member*; a drop leaves nothing behind to clean, because acquittal
carries no duties (Phase 3).

**Every death takes the ordinary path — eager death** (amended
2026-07-27; replaces "a condemned entity never dies on the ordinary
path", decided 2026-07-26 against finding F5,
[rc-walk-proof.md](rc-walk-proof.md)). A release reaching zero
mid-epoch tears down immediately, condemned or not — `__destruct` on
the owning thread at the natural point, then weak notification, sever,
free (the canonical dispose order: during its own destructor the
object is still alive and `get()` must still produce it) — with the
free **queued, not recycled** (deferred release below). F5's
danger was never the death itself; it was the drain meeting the corpse
and acting on it — `0 = 0` balances, the guard resurrects the slot, the
free path runs a second time (DC0). The deferral rule kept the corpse
out of posted components; eager death admits the corpse and defangs it
instead: the parked slot preserves identity, the corpse rule above
refuses the whole message on sight, and the double teardown is
unreachable because the drain never acts on a component containing one.
What the exchange buys is the destructor contract this runtime exists
to honour — `__destruct` runs at the natural death point, on the owner
thread, for **every** refcount death; the previous rule's "deferred
past the last release" semantics is gone. The only destructors that run
later than their last release are cycle members' — their counts never
reach zero before the drain, which is the collector's purpose, not a
deferral. What it costs is latency: a component that partially died
between posting and drain waits an epoch for its survivors to be
re-judged — the collector's currency, spent on the collector's side.

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
normally and on time, `__destruct` included — since the eager-death
amendment with no condemned-entity exception; only reuse waits, so the
walker cannot read a slot that has become a different object underneath
it.

Now that every read is validated and every verdict re-derived, the
queue's real job is **identity**: an id must name one entity from walk to
drain. Without the queue a slot could be freed and recycled mid-epoch,
and the Phase 4 equality could balance by coincidence on an object that
was never judged. That is a soundness role — the queue is not optional.

**The epoch ends only after every posted confirmation is
acknowledged** (acquittals post nothing since the eager-death
amendment). The queue flush, block retirement and the next walk all
wait for them. This closes two holes
at once: a posted message can never name a slot recycled underneath it,
and the collector can never condemn the same entity twice with two
messages in flight — at most one epoch's verdict is outstanding, ever.

**The same gate binds the collector's unwind path** (review finding,
2026-07-27). An epoch abandoned by a panic owes no acquittals since
the amendment — there is no mutator-side state to heal — but it must
still wait for its posted confirmations to be acked before releasing
the deferral window: releasing early lets the next epoch open over an
undrained queue, putting two epochs' verdicts in flight. The unwind
may block until the owning thread's next checkpoint; a dying
collector thread is the one place this design accepts a wait.

A parked slot is **not written until the flush**: the park list is
out-of-band (no in-slot link — see the corpse rule above for what the
in-slot draft broke), so a walker that read a header one pass earlier
and now chases the class word, or follows a stale pointer, lands on
an intact corpse — refcount 0, class word live, fields nulled — never
on repurposed bytes.

This is one load and a predicted branch on the free path, active only
during an epoch.

## What the mutator pays, in total

| | |
|---|---|
| `retain` / `release` | nothing beyond the counter itself: one header load (the flags tests need it anyway), one narrow 4-byte counter store — no flags store, no masking (narrow-mutator amendment, 2026-07-27) |
| allocation | nothing — slot classification (free / new / mature) is collector-side, from the refcount word and the epoch byte |
| memory release | one flag test while an epoch is in flight; on the reaching-zero path only, the checkpoint test (the condemned-byte test is gone with the byte — eager-death amendment, 2026-07-27) |
| per epoch | a handful of handshake acks — one callback each, at a checkpoint |
| per confirmed component | the Phase 4 drain: one verification pass plus the frees it would have performed anyway |
| per forced verdict (ladder rung 4) | the same verification pass, on a component that may prove live — rationed by per-component backoff and the per-epoch cap ("Convergence") |
| everything else | nothing |

No barrier on reference stores. No queue. No park. No atomic
read-modify-write. In a build without this collector, none of the above is
emitted.

Against `rc-trace` as implemented today this is a net **reduction**:
`ll_release` loses the candidate-buffer test and call it performs on every
non-zero decrement, and the header loses 17 bits of candidate index.

## The birth count: a known in-degree is written at allocation

**Status: designed, not implemented (2026-08-17).** When the number of
counted references an entity will have received by the end of its
construction sequence is known at compile time, the factory writes that
number as the initial refcount, and the sequence's publications of the
entity emit no retain. The factory publishes the header as one 8-byte
store anyway, so the constant costs no extra operation, while each
omitted retain turns a counted publish into a plain slot store — about
2.4 ns per publication on the recorded machine (`ll-model`
`dev/BENCHMARKS.md`, 2026-08-16, "store and lifecycle canaries").

`$obj->property = new Property()` is the smallest case: in-degree 1,
written at birth, the property store plain. The release of the value the
store displaces is unchanged.

**Why the deferral is sound.** Until the sequence ends the entity is
reachable only through the constructing frame, and no counted reference
to it exists yet, so no release can reach zero while the count
understates. The constant must be complete before the first reference
escapes the sequence; from then on the entity is an ordinary counted
entity in every protocol above. Both GC builds carry the scheme
unchanged, with no new header state. Retain/release pair elision on the
constructing temporary is subsumed: the pair is not cancelled, it is
never created.

**The boundary.** Only references *to* the entity, created inside its
sequence, fold into the constant. A store out of the entity into an
older counted target retains that target as today: the target's other
holders release concurrently with the sequence, so its count must never
understate.

## Unique ownership: one owning slot and no count

**Status: designed, not implemented (2026-08-17).** An entity the
compiler proves is owned by exactly one heap slot for its whole life
carries no reference count. The proof obligations, all static:

- one heap slot holds the entity's only counted reference from
  publication to death;
- every other copy of the reference is a borrow that is dead before the
  slot is overwritten and before the owner dies, and does not survive a
  checkpoint;
- no weak reference, FFI handle, or static reaches the entity except
  through the owner;
- the entity may be COW: uniqueness statically answers the separation
  test, so a copy-on-write value under this policy emits neither count
  nor uniqueness check and writes in place.

**What the mutator pays: nothing.** The owning slot's store is plain in
both directions — no retain of the new value, and the release of the
displaced one is replaced by eager destruction: the overwritten
reference was the entity's only one, so the overwrite itself is the
death, and owner teardown destroys the entity the same way. Destructor
timing is therefore today's last-release timing, and physical release
takes the same deferred path any death takes while an epoch is in
flight.

**The header.** The count word holds the non-zero occupancy sentinel 1,
which no operation touches; the death path writes 0 before the slot
returns, so the walker's occupancy test is unchanged. The collector
must not read the sentinel as a count, which needs a discriminant: one
bit of the retired condemned byte (bits 24–31, free since the
eager-death amendment) or a reserved count value — undecided.

**The collector.** The walker traces unique entities as ordinary nodes,
so their out-edges into counted targets are recorded in `IN`, matching
the retain those stores paid. Their own root equation disappears: a
unique entity is never an external root, by the borrow clause, and the
collector never condemns or frees one directly — it is destroyed by its
owner, including when the owner falls in a condemned component and the
Phase 4 drain tears it down.

**The open rule: the move.** Re-seating the unique reference into a
different slot is an edge insertion no count reports and a concurrent
snapshot cannot see; behind an already-walked destination it frees a
live entity. Until ruled otherwise, a move copies the entity, or the
proof includes "never moved", or the move emits a barrier. The choice
is open, and it bounds how much code qualifies.

**What was narrowed away** (decision 2026-08-17, `ll-model`
`dev/DECISIONS.md`): the shared-anchor generalization — any live anchor
in place of one owner — keeps the sealed-topology proof while
forfeiting eager death and COW eligibility; the deferred-count window —
uncounted stores reconciled by a later scan — fails on deletions, whose
overwritten value no scan can recover.

## Where the errors point

Staleness is not symmetric, and the first draft's blanket "always
conservative" was false. Toward **leaking**, which is safe: a missed edge,
a stale-high refcount, a skipped kind, a skipped region, allocate-black.
Toward **false condemnation**, which must be caught: a duplicate edge from
a reference read in both its old and new homes mid-migration; a dead
entity's out-edges read racing the final decrement (the occupancy test
closes the teardown window down to that one racy read); a
phantom edge from a torn ValueBox; a stale-low refcount read before a retain.
Everything in the second list survives at most to the Phase 3 re-check,
and nothing survives the Phase 4 exact test. The honest claim is not "the
walk is conservative" — it is "the walk may be wrong in both directions,
because nothing it says is acted on until a race-free test agrees."

## Convergence and the failure mode

Validation can starve: a component the filter keeps acquitting is never
confirmed, nothing is collected, and memory grows. The first draft
treated "a workload that keeps touching the same entities" as one
undifferentiated threat and ended its ladder in a pause. The channels
deserve to be counted, because they are few and they are not equal
(analysis 2026-07-28, two independent review passes):

- **A live component falsely condemned by a stale walk.** Ordinary
  mutator work touches it; the filter acquits. That is the filter
  doing its job — a live component must *never* be confirmed, and its
  perpetual acquittal is correctness, not starvation. The cost is
  wasted collector CPU.
- **Cascading deaths from a neighbouring drain or a late external
  death.** Each such touch is an event that happens once; deaths are
  monotone. One epoch of latency per event, bounded by the component's
  size.
- **Stale and torn walk reads.** Garbage is quiet: the next epoch's
  walk reads it accurately. One epoch of latency.
- **`WeakRef::get` on a member of a dead cycle.** The one channel
  through which live code can touch *unreachable* memory, repeatedly
  and forever: a dead-but-uncollected cycle's weak cell still
  resolves, and `get()` retains whatever the cell holds. A registry
  that polls its weak references each tick re-touches the corpse
  every epoch. **This is the sole unbounded-leak channel.** True
  garbage whose whole weakly-connected component carries no weak
  subscriber cannot be touched again once the neighbouring cascades
  settle: every delaying event — a cascade edge, an epoch-byte wrap
  skip, the F3 maturity epoch (counted from the walk that first
  stamps it) — is finite and unrepeatable, so its collection is
  **bounded, not perpetual**. (The component scoping matters: a
  weakless garbage ring garland-linked to a weak-polled one shares
  its component's fate — which is what rung 3 exists to cut apart.)

So the honest statement of the failure mode is narrow: *perpetual*
starvation of *true garbage* requires a weak-reference poller;
everything else is bounded latency or deliberately-spent collector
CPU. The ladder ends accordingly — not in a pause, but in front of
the judge the design already owns.

The escalation ladder, in order, with the mutator never drafted into
collector work:

1. **Re-run the epoch** — cheap, and the population of true cycles is
   stable while the population of hot objects is not.
2. **Re-walk only the candidate set to a fixpoint**: condemn,
   handshake, re-check, repeat until two consecutive rounds agree.
   Candidates are a small fraction of the heap, so rounds are cheap.
   (FUGC terminates its marking the same way — though its guarantee
   rests on monotone marking, which this rung alone lacks: one touch
   resets the round. The guarantee is restored by rung 4.)
3. **Stratify a repeatedly-acquitted garland** (optional refinement).
   Weak-connectivity grouping (Phase 2) lets one hot member acquit a
   whole garland of linked rings. On repeat acquittals the collector
   may condense the component into its strongly-connected strata and
   condemn separately the strata with no in-edges from the acquitted
   remainder — freeing the quiet rings while only the hot stratum
   waits. Collector-private arithmetic on the recorded edges; no new
   shared state.
4. **The forced verdict.** After `R` consecutive acquittals of the
   same component, the collector stops filtering and posts it as an
   ordinary confirmation — the Phase 3 re-check is skipped for that
   component (the handshake is not: other components still need it).
   The drain then decides against the true graph: the corpse rule and
   the exact test run exactly as for any posted component, and either
   every member's count balances its in-component in-degree — garbage,
   collected on the spot — or some member is held from outside *at
   the instant of the drain*, and the message is dropped because the
   component is, right now, provably alive. The only other outcome is
   the corpse-rule drop — a member died ordinarily since posting,
   which is progress by itself and re-judged next epoch. So **no
   component starves: every forced drain the thread reaches either
   collects it, observes it live, or observes it part-dead.** The F2
   premise is unchanged and worth restating here: a drain still needs
   a checkpoint, and a thread that reaches none drains nothing —
   forcing does not repair that stall, it only inherits it. A program
   that holds a strong reference at every drain the collector ever
   forces has, by `get()`'s own contract, kept the object reachable —
   that is liveness, not starvation, and no ladder in any collector
   frees it.

Rung 4 is sound because the Phase 3 filter was never a safety gate —
"no byte is a safety gate" has been canon since the narrow mutator,
and the scenario battery already drove the exact test against
comparable inputs (the 2026-07-26 battery, pre-amendment protocol: a
broken walker's false post, finding F4 — dropped, no free). What the
filter buys is precision;
rung 4 spends precision to buy termination, and only where termination
is actually threatened. Three rules keep it honest:

- **The trigger is a heuristic; the message is not.** "Same component
  `R` epochs running" is tracked as a hash of the member slot set,
  invalidated whenever a member slot is flushed — and it is only a
  *trigger*. The posted message is always built from the **current**
  epoch's walk and pinned by the current epoch's deferred-free queue,
  like every other confirmation; the history never names slots. A
  spurious hash match (recycled slots re-forming a lookalike cycle)
  costs one early forced drain, which the next rule bounds.
- **Forcing is rationed.** `R` doubles per forced drop for that
  component (a component that keeps being observed live is live), and
  forced posts are capped per epoch. Without the ration, one weak
  poller over a large ring would tax the mutator with an `O(ring)`
  verification every `R` epochs, forever — the budget line "a falsely
  posted component costs one verification pass" priced an accident,
  not a subscription. Zend's threshold backoff shows the opposite
  failure (backoff alone converts starvation into a sanctioned leak,
  php-src GH-9266); backoff *plus a decisive final gate* has neither
  problem.
- **Prefer the leak channel.** A component with no weak-subscribed
  member (no member carries `HAS_WEAK_REFERENCES`) that keeps
  acquitting is live by the channel analysis above — forcing it can
  only confirm liveness at `O(component)` cost. The collector
  therefore forces weak-subscribed components first, and others only
  under memory pressure (below). The bit is readable from the walk's
  own header loads; no new shared state.

Two texts become load-bearing with rung 4 and are stated here so no
future edit un-states them. First, the batched checkpoint's split
(ack before the run, **pickup after it** — "Batched releases" above):
with the pre-run pickup, a loop whose only checkpoints were scope
exits presented every drain with the same transiently-held borrow,
and the forced verdict dropped forever — the phase-lock. The trailing
pickup observes the transients dead, the exact test balances, and the
cycle frees. (The parked mutator of the deleted rung died on the same
trace: parking at a checkpoint inside the hold window re-reads the
same inflated count. The pause never bought what it cost.) Second,
the drain's ordering: **weak cells are nulled only after the exact
test passes** (Phase 4 order: corpse scan, exact test, guards, weak
nulling, destructors). While only true garbage could be posted this
was incidental; once rung 4 can post a live component, a drop must
leave its weak cells untouched — nulling a live component's cells
would be observable semantic damage. The code has always ordered it
so; now the order is contract.

One boundary unchanged by rung 4: the exact test balances **counted**
references only, so an uncounted borrow (DC5) passes a forced drain
exactly as it passes an ordinary one. The covering-root obligation of
[static-lifetimes.md](../memory/static-lifetimes.md) remains the sole
defense, and forcing more posts rolls that die more often — one more
reason the ration above is mandatory, not advisory.

**Rejected: parking the mutator** (the previous rung 3, deleted
2026-07-28). It bought a quiescent re-check — but the design already
owns a quiescent re-check that costs no pause: the Phase 4 exact
test, run by the mutator on its own thread at a checkpoint it was
reaching anyway. The park is strictly dominated (it dies on the
phase-lock trace above, pauses the mutator, and violates design
principle 4 — the mutator is never stopped — for nothing in return).
Prior art agrees on the shape: the Recycler retries candidate cycles
forever without a pause but has no race-free final gate to force a
verdict *to*; this design has one, and that asymmetry is the whole
answer.

The queue of deferred releases also grows for the duration of an epoch:
a slower collector costs memory ("Deferred physical release" above and
the bounding mechanisms in `BACKLOG.md`). `R`, the per-epoch cap and
the stratification threshold are measurements, not arguments — they
must be taken on real workloads before any number is fixed.

## When the collector runs: the pressure ladder

Half of open question 1 has an answer that costs no new mechanism:
**the allocation-failure path is the trigger.** In the normal regime
allocation is served from free lists and blocks, the collector runs on
its own cadence (thresholds still to be measured), and the mutator
pays nothing. When the manager cannot serve a request from what it
holds — pool empty, reserve unfilled — it is already on a rare, cold
path that was about to ask the OS for a block. On that path, and
before honest failure, the mutator climbs its own ladder of self-help,
cheapest first:

1. **Flush its own parked memory**, if an epoch has closed and left a
   backlog — the flush was waiting for the next checkpoint anyway;
   this is that checkpoint, run early. No user code.
2. **Drain the verdict queue now.** Posted confirmations are finished
   dossiers: the cheapest memory in the process — one verification
   pass per component plus frees the mutator already owed.
3. **Signal pressure to the collector**, which escalates: epochs on
   demand rather than on cadence, the fixpoint rung, forced verdicts
   with smaller `R` — and the rations above relax, including the
   weak-subscribed preference: under pressure a paid `O(component)`
   pass beats an allocation failure, so even weakless perpetual
   acquittals get their forced day in court. The rations exist to
   bound steady-state cost, not to protect a process out of memory.
4. **Run the synchronous collection itself** —
   `walk::collect_cycles`, the build-step-2 whole-heap form, on its
   own thread. This is not the deleted pause: principle 4 forbids
   stopping the mutator *from outside*; a mutator that chooses to
   spend its own time instead of failing an allocation is exercising
   the same ownership that makes it the judge. (Zend fires
   `gc_collect_cycles` from its allocator under the same logic.)

   Step 4 may run while an epoch is in flight, and the argument is
   the epoch's own machinery: frees still park (identity for posted
   messages holds); a member the synchronous collection kills reads
   `rc 0` at the epoch message's later drain and drops it by the
   corpse rule; a member the synchronous collection currently guards
   fails that drain's balance. One gate becomes explicit rather than
   incidental: the synchronous collection is a drain-class activity,
   so **message pickup is refused while it runs** — its walk-active
   bit joins the mid-drain bit and the teardown depth in the pickup
   gate. Without that, an allocating destructor inside the collection
   could pick up an epoch message naming members the collection
   already holds guarded, violating the drain's no-other-guards
   contract. (In code since 2026-07-28, pinned by a regression: a
   checkpoint firing inside the synchronous collection leaves the
   message pending.)
5. **Fail the allocation honestly.**

Two gates, inherited rather than new: steps 2 and 4 run user code
(destructors), so they obey the same reentrancy gates as any pickup —
never mid-drain, never mid-teardown; if the gates are closed the
mutator takes the OS block (or fails) now, and the ladder runs at the
next safe point. And the ladder never crosses threads: the thread
feeling the pressure is the thread that needs the memory, its parked
list and its verdicts are thread-local, and no other mutator is
paused, signalled, or waited on.

What remains of open question 1 is the *cadence* half — how much
deferred memory or how many suspects justify a background epoch when
nothing is failing — and that remains a measurement.

## Rejected: OS dirty-page tracking

The first draft validated with a second mechanism — `GetWriteWatch` /
soft-dirty — claiming it "costs the mutator nothing; the MMU already
tracks it". Both halves failed inspection. It was load-bearing, not
complementary: the condemned byte of that draft could not testify about
the window before the condemnation (the write of 1 buried the evidence),
so dirty pages were
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
  no count — and no trace in the Phase 4 exact test
  either, which balances *counted* references only. If the covering
  reference lives in an object that turns out to be cyclic garbage, the
  borrowed entity is freed under a live local. The rule the optimiser must
  follow: an elided borrow is legal only when covered by a counted
  reference the collector treats as a **root** — a frame slot, an arena
  slot, a static, an immortal, an FFI handle. Covering "by a bare field of
  some heap object" is not enough, because that object may itself be
  garbage, and the acyclic flag does not rescue it either. A field covers
  a borrow only on a **counted path from such a root**, every edge of it
  counted and the borrow itself counting as a use of the root: the chain
  rule of [gc-horizon.md](gc-horizon.md#the-ownership-lattice), amended
  into [static-lifetimes.md](../memory/static-lifetimes.md#the-chain-rule-and-the-borrow-as-a-use-of-its-anchor)
  on 2026-08-20. This obligation is independent of which collector is
  chosen — it applies to `rc-trace` today — and is written down with its
  worked cases in
  [static-lifetimes.md](../memory/static-lifetimes.md#what-may-own-a-borrow).
- **Weak references.** The collector delegates them; the machinery that
  discharges the obligation below is built (`ll-model` `src/weak.rs`,
  2026-07-27) and specified in
  [weak-references.md](../weak-references.md). The shape
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
- **Cycles through FFI wrappers.** A `FFIBox` wraps a C struct the
  walker cannot trace, so it is skipped totally and a ring passing through
  one is never collected. Conservative; revisit if FFI-heavy workloads
  leak.
*(**Cycles among promoted survivors** stood here until 2026-08-03.
Retained former-arena blocks were unwalkable for want of a stride, so
their occupants were root sources and a ring living entirely among them
never died. The reset now keeps its survivor list as each retained
block's object index and both walkers enumerate through it —
[retained-block-walk.md](retained-block-walk.md).)*
- **Multiple mutator threads** sharing `GcHeap` entities. Refcounts are
  non-atomic today, so the crate is single-mutator; actors will force this
  question and may force a per-thread epoch protocol — and will take the
  Phase 4 exact test with them, since its race-freedom *is* the
  single-mutator guarantee.

## Open questions before implementation

1. **The collector's background cadence.** The pressure half of the
   trigger is decided ("When the collector runs", 2026-07-28: the
   allocation-failure path climbs the mutator's self-help ladder);
   what remains is when a *background* epoch is worth running while
   nothing is failing — how much deferred memory, how many suspects,
   how long since the last epoch. Every threshold is a measurement
   nobody has taken, as are the forced-verdict numbers: `R`, its
   doubling, the per-epoch forced-post cap, the stratification
   threshold.
2. **Relaxed-atomic header accesses on AArch64.** x86-64 is settled:
   the generated release code is plain `mov`s with no lock prefix and
   no read-modify-write, and `ll_release` loses the candidate-buffering
   call tail (`ll-model` `8c2b0fe`, 2026-07-26). The instruction half
   of the AArch64 claim is settled too (2026-08-16, `ll-model`
   `dev/BENCHMARKS.md`, "AArch64 reads the header with plain loads and
   stores"): plain `ldr`/`str` on both header paths, no exclusive
   pair, no LSE atomic, no fence. What stays open is the **cost**
   half — no ARM hardware has paired those instructions with a clock,
   and the x86 store-forwarding lesson is why instruction identity is
   not yet a cost claim.
3. **Whether the fixpoint and stratification rungs earn their keep**
   over plain epoch re-runs plus the forced verdict — a measurement,
   on a workload that actually starves.

## Build order

1. Entity block segregation, the free-list link moved to bytes 8–15, the
   region registry with stable indices, the kind-dispatched tracers.
   Required by any walking collector, useful on its own as a heap census.
2. A synchronous walk fired at an explicit call: diff, mark, components,
   then the full Phase 4 drain — exact test included — inline. No
   collector thread, no filter: a whole-heap leak detector and the exact
   test's correctness harness.
3. The collector thread, the epoch byte, the handshake
   filter, the message queue and the epoch/drain ordering, the
   deferred-free bit extended to buffers.
4. Weak references.
5. The escalation ladder past rung 1 — stratification and the forced
   verdict with its rationing — if measurement shows starvation; with
   it, the pressure ladder's allocator hook. Its prerequisites — the
   batched/vector checkpoint split (`ll_gc_checkpoint_ack` + trailing
   pickup) and the walk-active pickup gate — landed ahead of it,
   2026-07-28.

`rc-trace` (`gc.rs`, Bacon–Rajan) stays in the registry throughout as the
single-threaded strategy, so the two can be compared on the same workload.
