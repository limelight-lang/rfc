# Domains — historical multi-mutator proposal

> **Status: historical proposal**, 2026-07-28; not part of the design of
> record. It extends the deleted `rc-walk` collector and has not been reconciled
> with `rc-cycle`. Nothing here is built. Scope: **threads**. Actors are not
> solved — see §11.
>
> What was tried and discarded on the way, and why, is in
> [domains-rejected.md](domains-rejected.md).

## The one rule everything serves

**The refcount of a `bound` or moved entity is written by exactly one
domain.** Every invariant, every restriction and every operation below
exists to keep that true without atomics. When a rule looks arbitrary,
this is what it protects. (`shared` is the declared exception and pays
for it with atomic counters — §11.)

## 1. Vocabulary

| Term | Meaning |
|---|---|
| **domain** | a memory scope with an owning executor: a thread, or an actor mounted on one. |
| **sub-domain** | a domain nested in another, sharing its executor — an **arena**. Own scope, own bulk death, no thread of its own. |
| **host** | the heap whose block holds the slot, and which reissues it. Found from any address: mask to the block, read `owner` in its header. |
| **holder** | the domain the entity is in now. For anything not moved, holder = host. |
| **bound** | the ordinary entity: only its holder references it, counters non-atomic, mutable. |
| **`#[Moved]`** | a class **declared** movable. Its instances may be handed to another domain; after the handover they are frozen. |
| **shared** | declared at the class, referenceable from any domain, never written. |
| **frozen** | fields fixed; mutation only through a copy. The state of a moved entity after its handover, and of a shared entity always. |

## 2. Invariants

**I1. Exclusive presence.** A moved entity is in exactly one domain at
a time. Its holder is the only one who may touch it — which is what
keeps its counters non-atomic although its memory belongs elsewhere.

**I2. A handover is legal only with no outstanding references.**
Otherwise it is a diagnosed error, not an edge case.

**I3. Frozen means frozen.** A moved entity is never written after its
handover; mutation produces a new entity in the writer's own memory
(§4). An ordinary store into a frozen entity raises. Because movability
is **declared** (§3), the compiler knows the types and emits the
checking barrier only where it is needed — ordinary objects pay
nothing.

**I4. No edge leaves a frozen entity into a domain's mutable state.**
For a moved entity this follows from I3: its edges were fixed before
the receiver's objects existed. For a shared entity it does not follow
and must be imposed — see the closure rule in §6.

**I5. Death is holder-bound, and complete.** Destructor, sever, and
every counter write happen at the holder. **Only the slot travels
home.** Nothing is sent home alive: severing releases children, and a
child may still be held by the holder, so a decrement performed
anywhere else would be a second writer of that child's counter.

**A shared entity is the exception, and safely so** (Edmond,
2026-07-28): it is destroyed by **the domain whose box died last**. The
reason the exception holds is the closure rule (§6) — a shared entity's
children may only be shared or immortal, so their counters are atomic
and any domain may sever them. The rule introduced for one purpose pays
for itself here. The slot still travels home to the creator's block by
the ordinary route. What it costs is that the destructor runs in an
arbitrary domain — see §11.

**I6. Crossing a domain boundary is registered, including a
sub-domain's.** An arena is a domain; an entity handed out of one must
be **promoted out of it**, not merely registered as an escape —
otherwise the holder mutates, from another thread, the very hold count
the dying arena's fixpoint reads to decide live-or-die.

Promotion here means **a copy into the GC heap, at the handover**, not
the lazy promotion the arena reset performs. Reset promotion retains
the arena *block* instead of moving the object, and a retained block is
outside the region registry (nobody walks it) and has no free path at
all — so a guest left there could never be validated and its slot could
never be returned. This is the one place in the model where a copy is
required.

## 3. `#[Moved]` is declared

Movability is a property of the class, checked where the class is
defined, not re-derived on every send. The declaration is what makes
the rest static:

- **Members' kinds.** A `#[Moved]` class may not hold a `&` cell (two
  names for one slot), a `WeakRef` (its table is per-domain and keyed
  by address), an `FFIBox` (foreign lifetime), or a lazy object
  (materializes in its own context).
- **Closure**: the fields of a `#[Moved]` class must themselves be
  `#[Moved]`, frozen or immortal. Otherwise a foreign domain reaches a
  `bound` entity — and its non-atomic counter — through the payload.
- **Acyclicity**: a frozen payload is never walked (§6), so a ring
  inside one would be reclaimed by nobody.
- **The destructor** is compiled under §5's rules.
- **The store barrier** stays free for everything else: the compiler
  emits the frozen check only for stores into declared-movable types.

**Arrays are allowed, and they are a special kind** (Edmond,
2026-07-28 — deferred, [BACKLOG](../../BACKLOG.md)). A payload without
arrays is not a payload in PHP, so an array field is legal; but an
array does not declare its element types, so the class graph cannot
close over them. A movable array is its own kind with its own rules,
and until those are designed the static story above is partial: what
the class graph cannot settle falls back to a traversal at send time.
The same gap applies to `mixed` fields, to subclasses of a declared
field type, and to recursive types, which are class-graph-cyclic.

What is not declared movable is not moved: it is deep-copied at pack
time, which is what [actors.md](../../runtime/actors.md) already
prescribes for payloads the analysis cannot prove.

## 4. Two operations, both explicit in the source

**Move.** A separate operation. It verifies I2, checks that no member
carries `HAS_WEAK_REFERENCES`, sets the **moved bit** on every member
of the subtree, and hands it to the destination domain. The source
binding is dead afterwards. Addresses do not change: nothing is copied.

The weak check is per-instance and cannot be hoisted into the class
declaration: §3 forbids a movable class from *holding* a `WeakRef`, but
nothing stops one of its instances from being *named* by a weak cell.
That cell sits in the **donor's** weak table, keyed by the entity's
address, while the death now happens at the holder — whose table has no
row for it. Nothing would null the cell, and `get()` would hand out a
slot that has since been reissued. The bit is in the header word the
traversal already loads.

**CoW modification** — `$x->prop ~= value`. Rebinding, not mutation:
`$x` names a *different* entity afterwards, and any other name still
pointing at the old one keeps seeing the old one — which is what the
operator says, so nothing diverges silently.

- It **always clones into the writer's own memory**, even at one
  reference. Mutating a foreign-hosted entity in place would let it
  acquire an edge into local objects and break I4.
- **Modification at depth clones the whole path**: `$x->a->b ~= v`
  clones `b`, then `a`, then `$x`, because a new node may not hang off
  a frozen parent. Cost is the path's length, not the subtree's size —
  except through an array, where cloning copies the storage buffer too
  (§11).

The consequence worth naming: **the graph naturalizes with use.** Each
write brings one node home and usually kills the frozen original, so
the foreign-hosted part shrinks as the receiver works with it, with no
pass over the payload.

## 5. The destructor of a moved entity

`__destruct` runs at the **holder**, at the natural death point, like
every other refcount death. Two rules make that legal:

- **Writing `$this` inside its own destructor is allowed.** Freezing
  exists so that no one observes a change and no ring closes through
  the entity; during teardown neither is possible — the count is zero,
  one domain holds it, and every field is severed immediately after.
  The barrier's frozen check passes when the writer is the entity's own
  destructor; the teardown state is already in the header beside
  `DESTRUCTOR_RAN`.
- **Resurrection of a moved entity is an error.** It is the one way a
  new edge could outlive the destructor, and with it a ring through a
  frozen entity.

Allocation inside the destructor goes where every allocation goes: the
current domain's memory. Nothing special is owed.

Death at the *host* was considered and does not work: the destructor
must run before the sever, and the sever releases children the holder
may still hold — so the host would become a second writer of those
children's counters ([domains-rejected.md](domains-rejected.md)).

## 6. What the collector does

**Each domain collects itself, independently and in parallel.** No
coordination, and in particular:

> **Prerequisite, and it does not exist yet: a domain must be able to
> enumerate its own blocks.** Today's snapshot walks the **global**
> region registry — every entity block of the process, whoever filled
> it (§12) — so "its own blocks" names no mechanism. A per-domain
> registry, or an owner filter over the global one, is required before
> anything in this section is true. Everything below assumes it.

- **No collision on the epoch byte** *while slices stay disjoint.* The
  maturity stamp lives in each entity's own header, and an entity sits
  in the blocks of exactly one domain, so two collectors never write
  the same byte — **except across abandonment and adoption**, where a
  block changes domain while a walk may still be in flight over it: the
  previous owner's numbering then meets the adopter's, and a newcomer
  allocated by the adopter can read as mature to it. Open (§11).
- **No N-ack handshake.** Only a domain itself writes to its own
  entities (I1), so its walk needs an ack from nobody else.
- **No validation result routing, no owner field, no guest list, no census rows
  for guests.**

A frozen entity is skipped **totally** — no row, no edges, no validation result —
the same treatment an `FFIBox` gets today, and for the same reason:
nothing that cannot close a ring is worth walking.

- The **host** meets the slot while enumerating its own blocks, reads
  the moved bit in the header word it has already loaded, and skips.
  Without the bit it would validate an entity another domain is using: the
  block is its own, and nothing else in the header says otherwise.
- The **holder** never loads it: an edge into a block outside its
  snapshot fails the census lookup, which resolves by address alone.
  Verified 2026-07-28: `census_row` resolves by mask, binary search and
  division, and never loads at the child address.
- **Shared** entities are skipped for the same reason, and the
  foreign-activity stamp an earlier draft proposed — to keep the Phase 4
  exact test race-free with a shared member — is not needed: a shared
  entity is never a member.

**A shared entity is never named directly** (Edmond, 2026-07-28). User
code cannot hold or store the entity itself: the compiler hides it
behind a **box** — a cell in the referring domain that names the
target — and an assignment stores the box, never the target. The box is
an ordinary entity of its own domain, so local references to it count
non-atomically; the entity's own counter moves once per domain, when a
box is born and when it dies, instead of once per assignment. Identity
operations (`===`, the object id, hashing) dereference the box, as they
already must for the model's other transparent wrappers, so duplicate
boxes naming one target are legal and no canonicalizing table is owed.

**Only compiler-emitted code dereferences the box.** The guarantee is
the compiler's, not a convention a programmer must keep — the same
footing `#[Moved]` stands on, and the reason both survive where
Kotlin/Native's freezing did not.

The box is shaped like the canonical weak cell and reuses its
machinery: the entity *is* the cell, holders count the cell and never
the target, and a per-domain table keyed by the target's address gives
one box per domain per target — so reading a field is a lookup, not an
allocation, and boxes do not multiply per read. Two differences from
the weak cell: this box **holds** its target (that is what makes the
target's atomic counter move once per domain, at the box's birth and
death), and it therefore never needs nulling.

The collector sees the box, not the target: the box is walked as an
ordinary local entity and its one out-edge is dropped like any edge
into something skipped.

**A shared entity may reference only shared or immortal entities.**
Nothing else. I4's derivation — a frozen entity cannot point into the
*receiver's* state, because that state did not exist when its edges
were fixed — says nothing about the **creator's** state, which existed
first, so a shared entity whose field names a `bound` object of its
creator hands every domain a path to that object's non-atomic counter.

And the rule may **not** be relaxed to "shared, frozen or immortal": a
movable-frozen member has non-atomic counters, which is exactly what
exclusive presence (I1) buys — and reachability through a shared field
destroys exclusive presence, since every domain that loads the field
retains and releases that member. This is the `Arc<Rc<T>>` shape, which
`Arc` rejects; the constraint on `T` is the whole point.

### The class word must be validated after the fact

The walk reads a slot in two passes: pass 1 (`walk_rows`) reads the
header and records a row; pass 2 (`walk_edges`) goes to the recorded
address and loads the **class pointer at +8** to find the fields — and
performs no header read of its own. That is sound today only because
nothing writes a slot mid-epoch: local frees park **out of band**, so a
zero-count entity keeps refcount 0 in bytes 0–7 and its class word intact.

A foreign free breaks it. Linking a slot into the block's cross-thread
queue writes the "next" pointer into **the slot's own bytes 8–15** —
the class word — even though the slot is reissued to nobody. Pass 2
would then dereference a free-list link as a class pointer.

The fix is collector-side and needs no coordination: **pass 2 loads the
class word, then re-reads the refcount, and discards the row if it is
now zero.** The order is the whole trick. Reading the count *first*
leaves the race open (the count can be read live, then both stores
land, then the class word is read clobbered); reading it *after* closes
it, because the freeing side always writes zero into the count before
it writes the link — teardown drives the count to zero, and only then
does the free run.

- **Ordering.** The link write is a plain store today, racing pass 2's
  load — undefined behavior on every target, not only on AArch64. The
  publishing release must sit on **the link store itself**; the
  `Release` on the queue's CAS orders nothing pass 2 reads. So the
  foreign free path gains one atomic release store: cold, but a
  mutator-side cost, and the measurement must include it.
- **Still required:** the slot must not be *reissued* during the epoch,
  or the count reads non-zero again — from a different entity. §7 is
  supposed to give that and does not yet (§7's own note).
- **MEASURE** (`dev/BENCHMARKS.md` protocol): one extra load per row in
  pass 2 on the collector, plus the release store on the foreign free.
  Agreed 2026-07-28 subject to that measurement.

## 7. Memory

A moved entity dies at its holder, so its slot is freed by a thread
that is not the host. The free resolves the address to the block
header, sees a foreign `owner`, and pushes the slot onto **that
block's** `remote_free` queue — the path the heap already implements. A
slot in that queue is on no free list until the host drains it.

**The queue is not drained while an epoch is in flight over that
block.** That is what keeps a block from emptying, retiring to the pool
and being re-commissioned with a different stride while a walk is still
iterating it from the snapshot. The host's own frees park as they
already do.

A thread-local "my epoch is running" test is not enough on its own,
because two paths drain that queue on behalf of a *different* thread:
`abandon_all` at thread exit drains unconditionally and retires emptied
blocks to the pool, and adoption drains on the adopter's refill path. A
dying or adopting thread testing *its own* epoch says nothing about the
walk the block's previous owner still has in flight. So the test must
be readable from the block: the block header carries the **epoch number
it was snapshotted in**, and every drain — the owner's, the
abandoner's, the adopter's — compares it against the epoch still
running over that block. The header is in hand on all three paths.

> **This is necessary and not sufficient, and the gap is open.** Two
> reissue paths do not go through the queue at all. `abandon_all` sends
> an **already-empty** block straight to the pool, so a class's empty
> reserve — owned, registered, snapshotted — can be re-commissioned at
> a different stride while its former owner's walk still iterates it
> from the snapshot. And a thread that **adopts** a block allocates
> from the block's *pre-existing* local free list, reissuing slots that
> were freed before the epoch, with no drain involved. What is actually
> needed is the shipped registry rule — a block is retired or
> re-commissioned only between epochs — re-derived per domain; the
> field gates the queue only. The comparison also needs a readable
> right-hand side, and today there is none at all: no epoch number is
> published outside the collector — `deferred_free` exports one activity
> bit and the counter behind `Epoch::open` is a private static
> (`ll-model`) — so the right-hand side has to be built before it can be
> read. Built, a bare number 1–255 still does not say *whose* epoch it is
> or whether it has closed, and after abandonment the block's `owner` is
> null.

## 8. Sequence: an object sent to another thread

1. A creates `X` in its own entity block `Z`.
2. A moves `X` to B: the bit is set on every member, A's binding dies,
   the address does not change.
3. B stores `X` into a field of its own object `O` — an ordinary store
   barrier. `X`'s counter grows, written by B, in memory hosted by A.
4. **B's walk** enumerates `O`, finds the pointer to `X`, and drops the
   edge because block `Z` is not in B's snapshot — *which assumes the
   per-domain enumeration §6 flags as missing; under today's global
   snapshot `Z` is in it.* `X` is not validated.
5. **A's walk** enumerates the slot of `X` in `Z`, reads the header,
   sees the moved bit, skips. `X` is not validated.
6. Nobody validates `X` — and nothing is lost, because frozen means it can
   never be in a ring.
7. B drops the last reference: `__destruct` at B, sever at B, then the
   slot to `Z`'s `remote_free`; A reissues it at its next drain, which
   waits for any epoch running over `Z`.
8. Had B written into `X` instead, `~=` would have cloned the node into
   B's memory; the clone is ordinary and mutable, and a ring between it
   and `O` lies wholly inside B's slice and is collected there.

## 9. The cases

Every case is answered by the same six questions: who **holds** it
(may reference it, and buries it), who **hosts** it (whose block, who
reissues), who **walks** it, who may **validate** it, whose executor runs
the **destructor**, and what stops the slot being reissued mid-walk.

| Case | holder | host | walked / validated by | destructor |
|---|---|---|---|---|
| home-grown entity | A | A | A | A |
| moved A → B | B | A | nobody — skipped by both | B |
| `shared` | any, through a box | its creator | nobody — skipped | the domain whose box died last |
| arena entity, never escapes | A's arena | arena blocks | nobody | A, in the reset fixpoint |
| arena escapee, promoted at reset | A | retained block | nobody (outside the registry — unless retained-block-walk.md lands) | A |
| frozen / immortal | any | immortal region | nobody | never |
| host thread exited, entity moved | B | the adopter | nobody — skipped, as row 2 | B |
| host thread exited, entity is the adopter's own | the adopter | the adopter | the adopter | the adopter |

The arena rows are not gaps: an unwalked region is a **root source** by
the derived-roots corollary — its edges appear in `RC` and never in
`IN`, so its targets survive. Skipping costs recall, never correctness.
An arena's collection is its reset: a bulk death of the whole
sub-domain.

Cycles, by shape:

| Shape | Collected? |
|---|---|
| wholly inside one domain's blocks | yes |
| arrived payload ↔ receiver's own state | impossible — a frozen entity gains no edges (I4) |
| between `bound` entities of two domains | impossible — I1 forbids the cross-domain reference |
| inside a payload, closed before it froze | no — refused at the class (§3) |
| among shared entities, fixed at creation | no |
| through an arena, a retained block, the immortal region | no — unwalked regions are root sources |
| through an `FFIBox` or a huge OS-direct allocation | no — existing recorded limits |

## 10. What is not collected

Conservative, never unsound: the last four rows of the table above.

## 11. Open

- **Frozen from birth or frozen after the send?** Deferred (Edmond,
  2026-07-28; "after the send" is the working answer). Frozen always
  gives a uniform semantics the compiler settles statically, at the
  price of a construction phase like `readonly`. Frozen after the send
  lets the creator build the object normally, but one type then behaves
  two ways and the store check may fall back to runtime.
- **Actors — deferred** (Edmond, 2026-07-28).
  [actors.md](../../runtime/actors.md)'s allocation-site selection
  assumes a **general heap** — memory owned by no domain — into which a
  transferable object is born. This memory model has none: every block
  belongs to some thread's heap. An actor's *mutable* state is safe
  (its arena belongs to it and migrates with it), but a transferable
  entity promoted out of that arena lands in the entity heap of
  whichever pool thread was mounting the actor, so its host is a thread
  while its holder is an actor. The payload table and allocation-site
  selection are owed a re-derivation.
- **The movable array** — deferred to
  [BACKLOG](../../BACKLOG.md); §3 above.
- **`~=` on a DAG.** If one node is reachable by two paths from the
  same variable, cloning one path un-shares it from the other, inside a
  single name. Also: re-exporting a payload after `~=` — the clone
  shares frozen children with the original, so I2 refuses the second
  move until those are released.
- **The move's counter semantics.** "The source binding is dead" must
  not be lowered as a release: the count has to transfer without
  crossing zero, or eager death tears the payload down in flight.
- **A domain dying mid-epoch**: an epoch nobody will close, a parked
  list, a weak table. Abandonment and adoption also break §6's
  disjoint-slice premise and §7's gate — see the notes there. This is
  the largest hole in the model.
- **Per-domain enumeration does not exist** (§6's prerequisite): the
  snapshot is global today.
- **What the arena copy of I6 owes**: the original left behind is an
  ordinary dying arena object, so the reset fixpoint would run its
  `__destruct` a second time unless the move stamps it
  `DESTRUCTOR_RAN`; arena-internal references are uncounted, so I2
  cannot be read off a counter there; and identity (`spl_object_id`,
  weak state) names the original, which contradicts §4's "addresses do
  not change" for this one case.
- **Where the resurrection ban is raised.** The barrier's frozen check
  guards stores *into* a movable type, not stores *of* a reference to
  one, so the ban needs a check at dispose exit (moved bit and a
  non-zero count) rather than at the store.
- **A posted validation result whose member then moves.** Rung 4 posts live
  components deliberately; the drain needs a rule (dropping the message
  on a member's moved bit is the obvious one — the zero-count-entry scan already
  loads that word).
- **The drain-exclusivity window** is proven for one mutator
  (drain-window.md); the re-derivation is owed.
- **May a `shared` class have a destructor at all?** (Recorded as a
  question, 2026-07-28.) It runs in whichever domain dropped the last
  box — an arbitrary one — so anything with thread affinity in it is a
  trap the programmer gets no warning about. Forbidding it makes shared
  entities pure data; allowing it puts "the destructor of a shared
  class runs in an arbitrary domain" into the language contract.
- **`shared` still needs atomic counters**, but few: with the box (§6)
  the entity's own counter moves only when a domain's box is born or
  dies, not per assignment. What the box costs is an entity kind — and
  the kind field has exactly one code left, which `resource` also wants
  ([layouts.md](../layouts.md)).
- **Throughput of §7's gating.** Holding the remote drain for an
  epoch's duration recreates the refill-forever pattern
  `collect_owned` exists to prevent; a cost line is owed once measured.

## 12. What is single-mutator in the code today

Not a plan — an inventory, so nobody re-derives it.

- `epoch.rs` — one process-global handshake flag (the first domain to
  ack lowers it for everyone), one ack counter, one global validation result
  queue, one outstanding-validation result counter.
- `deferred_free.rs` — the deferral window is one process-global bool;
  the parked list is thread-local and flushed by its own thread.
- `heap.rs::snapshot_entity_blocks` walks the **global** region
  registry: every entity block of the process, regardless of which heap
  filled it. The walk is already domain-agnostic; the protocol around
  it is not.
- `ll_heap_free` (`context.rs`) calls the heap's free directly,
  bypassing the deferral test `ll_free` performs. Harmless while the
  walker chases no raw buffers; not harmless once arrays land.
- The drain-exclusivity proof lists a second mutator as its unmodelled
  kill variant.
