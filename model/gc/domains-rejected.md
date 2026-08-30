# Domains — what was rejected, and why

Companion to [domains.md](domains.md). Every shape and mechanism
considered for running `rc-walk` with more than one mutator and then
dropped, with the reason that killed it. Kept so none of them is
re-invented; all of it is from 2026-07-28 unless dated otherwise.

## Whole shapes

**Guests validated by their holder, found through a registration list.**
The receiving domain would register each arrived subtree, and its walk
would enumerate its own blocks *plus* trace from that list, so a ring
between an arrived payload and the receiver's own state stayed inside
one slice. Killed by adversarial review on three counts, each fatal on
its own: the list is **incomplete** (the receiver stores an interior
node and drops the root — the node leaves the list but stays live), the
entries are **not identity-stable** (an entry outlives the entity, the
slot is recycled, and revalidation by address plus occupancy then walks
the next tenant), and **re-handover** leaves the entry behind, so two
domains validate one component and two drains race over the same
non-atomic headers.

**Mutable handover** — the moved entity stays ordinary and writable for
its new holder. This is what the receiver would want, and it is what
`actors.md` describes. It cannot hold the one rule: a mutable guest
acquires edges into the holder's objects, so rings pass through it,
so it must be validated, so it needs a census row from a block outside
the validator's snapshot — and exact validation then reads counters
in memory another domain hosts. Everything that made the frozen shape
cheap disappears at once.

**Physical relocation at the handover** (copy the subtree into the
receiver's blocks). Deletes the most machinery of any option — owner
and host coincide again, no moved bit, no routing, no cross-thread
entity frees, no two-domain drain window — and makes a per-thread walk
complete. Rejected because it kills the zero-copy send, which is the
point of a move.

**A general heap owned by no domain**, into which transferable objects
are born (this is `actors.md`'s allocation-site selection). It would
dissolve the problem rather than solve it: no entity would ever be a
guest. Rejected because the memory model has no such population —
every block belongs to a thread's heap, and a nobody's-heap needs
exactly the shared allocation and free that per-thread ownership
exists to avoid. The consequence is filed as the actor open question.

**Domani-style sticky global tier** — an entity that escapes its
domain is marked global, stays where it is, and local slices skip it;
a rarer whole-heap pass collects the global tier. Prior art:
*Thread-Local Heaps for Java*, whose collector is likewise non-moving.
Rejected as the primary mechanism because the tier only grows (nothing
demotes) and its garbage waits for a pass that must cover every domain
at once.

## Mechanisms

**A foreign cell per cross-domain reference** — wrap the reference in
an entity of its own, in the referring domain, naming the target and
its owner. Real merits: local references count the cell, so they stay
non-atomic and the target's atomic counter moves once per domain
rather than once per assignment (this is what Pony's ORCA buys with
messages); and the walk finds the cell by ordinary enumeration.
Rejected for `moved`: an array of received objects pays an indirection
per element and the load cannot be hoisted out of the loop, which
contradicts "the receiver works with an ordinary object". **Adopted for
`shared`** the same day (domains.md §6): there the entity is never
named directly at all, so the box is not an extra layer over a
reference — it *is* the reference.

**An owner field in the entity header** (a byte in the flags word,
free since the eager-death amendment) so a validation result could be routed to
the holder. Unnecessary once the holder is the validator: a walk that
reaches a guest at all is the holder's, by exclusive presence.

**A hold on a moved entity's memory for as long as it is away.**
Proposed so that any address a walk resolves names the same entity.
Dropped: nothing dereferences a moved entity, and the real exposure is
narrower and differently shaped — the *link write* that a foreign free
performs into bytes 8–15 (§6 of the model), which is answered by
validating the class word after the fact rather than by holding memory
with no release point.

**A foreign-activity stamp for the Phase 4 exact test** — a counter
bumped by non-owner operations, read before and after the test, so a
drain could tell whether any foreign counted operation happened during
it (a seqlock over foreign traffic, not over data). Needed only if a
shared entity can be a member of a component confirmed as unreachable; it cannot,
once shared entities are frozen and skipped.

**Sending a dying moved entity home alive**, with the transfer channel
holding the last reference and `DESTRUCTOR_PENDING` set, so its
destructor could run at home on an unfrozen object. Rejected: the
destructor must run before the sever, and the sever releases children
the holder may still hold — the host would become a second writer of
those children's counters.

**Refusing to move any class with a destructor.** Simple and complete,
but it cuts by class rather than by behavior, and `__destruct` in PHP
is usually trivial cleanup unrelated to threads. Replaced by allowing
`$this` writes during the entity's own teardown and forbidding
resurrection.

**Per-domain epochs rejected on the epoch byte.** Argued at one point
that two concurrent walks would clobber each other's maturity stamps.
Wrong: the stamp lives in each entity's own header and slices are
disjoint, so no two collectors ever write the same byte. Recorded
because the argument was made and is wrong.

**One epoch at a time, sliced by blocks.** A middle road: divide the
heap into slices and run them in sequence, so a domain whose blocks are
not in the current slice parks nothing. Rejected in favour of genuinely
independent per-domain collection, which is what the requirement was.

## Prior art consulted

| System | Cross-domain references | Who frees |
|---|---|---|
| CPython 3.13/3.14 free-threaded | biased reference counting: an owner id plus split local/shared counters in **every** object header, no declaration | a non-owner queues the object to the owner thread |
| Nim 2.x (ORC) | shared heap, **non-atomic** counters; whole subgraphs move (`Isolated[T]`), otherwise deep copy; `--mm:atomicArc` is a separate mode | the subtree's owner |
| Pony (ORCA) | per-actor counts for foreign objects, deltas travel as messages, no atomic counter anywhere | only the allocating actor |
| Rust | split at the type level: `Rc` cannot cross, `Arc` can | whoever drops last; **cycles are never reclaimed, by documented design** |
| OCaml 5 | per-domain private minor heap, shared major heap; anything shared is promoted into the major heap first | the domain's own collector |
| GHC (local heaps) | pointers from the global heap into a local heap are forbidden; an escaping object is globalised, with read barriers and proxy indirections | the owning capability |
| Java thread-local heaps (Domani et al.) | on escape, the transitive closure is marked **global and left in place** — the collector is non-moving | the local collector, for local objects only |
| PHP (ZTS) | nothing is shared; interned and immutable strings carry `GC_IMMUTABLE` and leave counting entirely | — |
| Kotlin/Native (old model) | sharing required freezing — a runtime discipline, not a type | — (deprecated in 1.7.20, removed in 1.9.20) |

Two things this table settles. First, the invariant every local-heap
system enforces one way or another: **no pointer from outside into a
private heap** — by promotion out of it (OCaml, GHC) or by marking in
place (Domani), and marking is what a non-moving collector can afford.
Second, the lesson from the last row: the same restriction succeeds
when the compiler carries it (Rust, Pony, Swift) and fails when a
programmer must remember it. That is why movability is declared.

Sources: Choi, Shull, Torrellas, *Biased Reference Counting* (PACT'18);
CPython free-threading documentation; Nim memory-management manual;
Clebsch et al., *Orca* (OOPSLA'17); `std::sync::Arc` documentation;
Marlow and Peyton Jones, *Multicore GC with Local Heaps*; Domani et
al., *Thread-Local Heaps for Java*; Multicore OCaml GC notes;
Kotlin/Native migration guide.
