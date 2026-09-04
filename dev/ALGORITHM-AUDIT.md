# Algorithm and consistency audit

> **Audit date:** 2026-08-30  
> **Scope:** active RFCs, with emphasis on `model/gc/rc-cycle.md`, its question
> graph, allocator integration, actors, and object layout.  
> **Purpose:** record correctness issues separately from editorial changes.

This report does not choose new algorithms. It identifies requirements that are
contradictory, incomplete, or insufficient to implement safely. “Recognized”
means the RFC already contains the gap in some form; “new” means this review
found an additional contradiction or consequence.

## Summary

The synchronous owner-side form of `rc-cycle` remains the safest implementable
subset. The optional collector-worker path is blocked by concurrent slot reads,
an undefined candidate-queue swap, slot-reuse ordering, and block migration.
Memory-pressure guarantees are also not closed because mandatory queue capacity
and post-trace validation storage have no complete bound or lifetime protocol.

| ID | Severity | Status | Issue |
|---|---|---|---|
| A1 | Critical | New | Collector-worker reads race with non-atomic slot writes |
| A2 | Critical | Recognized | Candidate-queue swap has no linearization protocol |
| A3 | Critical | New contradiction | Deferred slot return has two incompatible instants |
| A4 | Critical | Recognized | Block migration can invalidate live trace rows |
| A5 | Critical | Recognized | Mandatory candidate registration has no proved capacity bound |
| A6 | Critical | Recognized | Validation data outlives its only specified arena |
| B1 | High | New | Zero-count member handling omits other roots' disposition |
| B2 | High | New contradiction | `heap-design.md` specifies a superseded and incomplete CAS collector |
| B3 | High | New contradiction | Per-thread trace closure conflicts with moved-object placement |
| B4 | High | Recognized | Zero-copy actor transfer has no compatible heap ownership model |
| B5 | High | New contradiction | Per-actor collection conflicts with arena exclusion |
| B6 | High | New defect | Actor weak-target transfer checks the wrong header bit |
| C1 | Medium | Recognized | Concurrent epoch commits have no update protocol |
| C2 | Medium | Recognized | OOM and trace-budget guarantees have no numeric bound |
| C3 | Medium | Recognized | FFI and sharing holes make thread isolation conditional |

## Critical blockers

### A1. Collector-worker slot reads are a data race

`rc-cycle.md`, “Speculative tracing and exact validation”, permits an off-thread
trace to observe fields and counts from different instants. `model/lowering.md`
defines pointer and `ValueBox` slots as ordinary, non-atomic storage. A
collector-worker read concurrent with a mutator store is therefore undefined
behavior in C and Rust; a wide `ValueBox` may also tear. This cannot be treated
as harmless staleness because the resulting pointer need not have been valid at
any instant.

Required resolution: specify an atomic slot representation, a seqlock/versioned
read for wide values, a write-barrier snapshot, or a stop-at-consistent-point
protocol. Until then, only synchronous owner-side tracing is memory-safe.

### A2. Candidate-queue swap is not linearized against registration

`cycle/questions.md`, Y12 clauses 1–3, combines an owner-only queue writer with a
collector worker that swaps the live buffer. The same document explicitly
leaves open which buffer receives a concurrent registration. Losing an entry
can make a cycle permanently undiscoverable; duplicating one can violate queue
and candidate-bit accounting.

Required resolution: define the atomic object being exchanged, the writer's
retry rule, segment-link publication order, and the linearization point for both
registration and swap. The collector-worker path must remain disabled until
this protocol exists.

### A3. Slot-return timing is contradictory

The previous `rc-cycle.md` text said both that a slot returns when the owner next
observes the trace token free and that the return instant is the token-release
store. A remote collector worker cannot safely modify the owner's heap/free
list at release, while an owner-side observation needs a handoff and a race-free
test against traces already starting.

Required resolution: specify an owner-owned deferred-reuse list and a handshake
or generation protocol that proves no old or newly started trace can access the
slot. Define exactly when block occupancy decreases.

### A4. Block migration can invalidate trace scratch rows

The concurrency proof assumes each trace remains within one thread's blocks.
However, `Heap::abandon_all` can clear ownership at thread exit and `adopt` can
assign the block, including its free slots, to another thread while the old
trace still indexes shadow rows by slot address. The new thread can reuse a slot
under the old trace.

Required resolution: order abandonment and adoption against the old owner's
trace token, and define who may collect live entities in an abandoned block.
Tracked in `dev/PLAN.md` S8.9.

### A5. Mandatory candidate registration has no capacity proof

The design says candidate registration cannot fail, but the overflow buffer is
finite and its capacity depends on an unspecified maximum number of barrier
operations between polls. A closed collection-entry gate can extend the period
during which teardown registers candidates while ordinary and reserve
allocation both fail. The process-abort edge is therefore reachable under the
current specification.

Required resolution: define and verify a poll/registration bound, provision
capacity from that bound, or provide a growable allocation mechanism with an
independent failure guarantee. “Never drop an entry” alone does not establish
capacity.

### A6. Exact-validation data has no allocator lifetime

The trace token release resets the trace scratch arena before exact validation
and finalization. Those later stages still require component-member lists, but
the RFC names only the already-reset arena as their allocator. Referring to the
critical reserve identifies a source of memory, not the allocator object,
ownership, or lifetime.

Required resolution: introduce a separate validation arena, retain selected
scratch blocks through owner pickup, or copy the validation batch into an
explicitly owned inbox allocation before releasing the token. Account for this
storage in the critical-reserve bound.

## High-severity inconsistencies

### B1. Zero-count member handling omits other queue entries

Cycle finalization drops a proposed component when one member already has count
zero. It does not specify what happens to other candidate roots in that
component. Their candidate bits may remain set even though their queue entries
were consumed, preventing future registration and causing a permanent leak.

Required resolution: requeue or defer every remaining candidate entry, or prove
that a component containing a zero-count member cannot contain another enrolled
root.

### B2. `heap-design.md` specifies a superseded CAS collector

`model/gc/heap-design.md`, “GC / Mutator Coordination”, refers to deleted
`rc-satb` and `rc-trace` designs as active. Its `LIVE/SCANNING/DEAD/OWNED` state
machine omits completion transitions and says the collector may reclaim an
object after winning the CAS. `rc-cycle.md` instead requires the owning mutator
to run weak-reference invalidation, user teardown, and reclamation. The global
activity-bit alternative also has a check-versus-start race when used without a
separate synchronization protocol.

Required resolution: remove the superseded section or rewrite it entirely for
`rc-cycle`, including every state transition and owner-side finalization rule.

### B3. Trace closure conflicts with moved-object placement

`rc-cycle.md` assumes a trace for one owner cannot reach another thread's
blocks. `model/gc/domains.md` describes a moved object logically held by thread
B while it remains physically allocated in thread A's block. Address-derived
shadow-row lookup follows physical placement, so the trace crosses the stated
ownership boundary.

Required resolution: define separate allocator host and logical owner concepts,
then either synchronize cross-host row access, move/copy storage at transfer, or
prohibit tracing such edges.

### B4. Zero-copy actor transfer lacks a compatible heap

`runtime/actors.md` requires moved values to be allocated in a neutral “general
heap”, but its rejected-alternatives section and the memory RFCs say no such heap
exists and blocks are thread-owned. Non-atomic reference counts, actor migration,
remote release, and per-thread collection therefore do not compose for a
zero-copy transfer.

Required resolution: choose storage ownership for transferable values and
specify reference-count, release, adoption, and collection operations for that
ownership class.

### B5. Per-actor cycle collection conflicts with arena exclusion

`runtime/actors.md` promises cycle collection for actor arenas and cites deleted
collectors. `rc-cycle.md` stops traversal outside the cycle-collected heap, and
the strategy contract says arenas are invisible to the collector. Reference
cycles in a long-lived actor arena therefore survive until actor destruction.

Required resolution: state that actor-arena cycles live until arena reset, or
define a separate arena-cycle algorithm and its interaction with destructors.

### B6. Actor weak-target transfer checks the wrong bit

`runtime/actors.md` says `HAS_WEAK_REFERENCES` is header bit 7.
`model/classes.md` and `model/lowering.md` assign the weak-reference bit to 12;
bit 7 is the arena-reset mark. An implementation following the actor RFC could
move a weak target without migrating or rejecting its subscriber state,
creating a use-after-free path.

Required resolution: update the actor RFC to bit 12 and prefer the symbolic
flag name over a numeric literal.

## Medium-severity open invariants

### C1. Concurrent epoch commits have no update protocol

Several owners may finish validation concurrently after releasing their trace
tokens. The process-global epoch counter has no specified atomic increment,
collection-count rule, or ordering against per-entity age stamps. Lost updates
change promotion and deferred-candidate timing.

### C2. OOM and trace-budget guarantees have no numeric bound

The first trace after an epoch change may prune nothing, the work budget remains
policy rather than a value, reserve shares are unpartitioned, and queue growth
depends on unmeasured registration rate. Statements that work is “bounded” are
therefore design goals, not implementable invariants.

### C3. Thread isolation is conditional on unresolved FFI and sharing rules

`runtime/actors.md` permits foreign entry without an installed actor context and
admits that shared-reference lifetime and collector exclusion are unresolved.
The `rc-cycle` disjoint-block proof must state those constraints as prerequisites
until FFI and sharing close every route for cross-thread managed pointers.

## Direct document inconsistencies corrected by this audit

- The repository overview now describes the two exception channels U and R;
  the rejected bailout channel is no longer presented as active.
- `runtime/actors.md` must use the symbolic weak-reference flag (bit 12), not
  bit 7.
- `model/strings.md` must describe the current four-bit `EntityKind` field, not
  the superseded three-bit layout.

The remaining issues above require design decisions and must not be closed by
editorial substitution.

## Resolutions since the audit

Each entry names the ruling that closed a clause, where the ruling is recorded,
and where the specification states it. The issue rows above are left as they
were written on 2026-08-30.

**A3, for the in-line collection (2026-09-03).** The free path tests the two
conditions in order and only one of them writes anything down. A slot whose
entity still has a candidate-queue entry is recorded nowhere, that entry naming
the slot already; a slot freed
while the thread's own trace is open waits for that trace's close and returns
through the ordinary free path once its last row is gone. Block occupancy
decreases at that return. The withheld fact costs no allocation: its first 1,024
records stand in a fixed region of the thread's collection workspace, and past
that it fits in the dead slot itself, which is what Edmond's ruling of the same
day put there in place of a growing list. A thread runs at most one trace at a
time, which is what proves no trace of its own can address a returned slot; the
generation or handoff protocol is still owed for a collector worker.
`model/gc/rc-cycle.md`, "Zero-count entities pending slot reuse"; `ll-model`,
`dev/DECISIONS.md`, "the withheld returns' first 1,024 records are the
workspace's second region" and "under memory starvation a collection ends itself
and gives back everything".

**A4, first clause (2026-09-04, ruled by Edmond).** A thread does not exit while
any trace holds rows over its blocks: it waits, collects, retires its queue and
only then hands its heap over, so `abandon_all` and `adopt` never run under a
live trace. The second clause stands open — what that last collection could not
take keeps its candidate bit and is a bounded leak with no collector, and an
estate a worker could claim is refused until the accelerator exists.
`model/gc/rc-cycle.md`, "Concurrency"; `ll-model`, `dev/DECISIONS.md`, "a thread
waits for the trace, collects, and then exits".

**A6, for the in-line collection (2026-09-03, ruled by Edmond).** When the arena
goes back depends on why the collection ran. Off the safepoint poll it does not
go back before the teardown, which reads the shadow rows directly and needs no
member list at all. Started by an allocation failure, the collection harvests
the unreachable rows into a fixed region of the thread's workspace, returns
every block, and runs the teardown off that region. The membership data draws
nothing: the region is part of a block the thread holds from its first
collection to its exit, so what it adds to the critical-reserve bound is zero,
and the trace's rows past that block draw the pool and then the reserve as
before. Whether a worker's trace may hold its arena the same way is open.
`model/gc/rc-cycle.md`, "Concurrency"; `ll-model`, `dev/DECISIONS.md`, "the
member list is the pressure path's alone".

**A2, restated (2026-09-04).** The swap this issue names is now a detach: the
tracer moves two words, the head segment and its fill, and draws nothing
(`cycle/questions.md`, Y12 clause 2). The issue itself is unchanged — the two
words are ones the writer is about to write, and their linearization against a
concurrent registration is still owed.
