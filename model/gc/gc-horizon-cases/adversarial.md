# GC horizon — adversarial cases PH1 to PH35

> Written by Edmond, 2026-08-20, as `dev/design/proof-horizon-breaking-use-cases.md`
> in the code repository, and moved here whole with the rename. The text
> below is his; nothing was edited except this banner and the title.
> Where a case here and a case file disagree, this document is the older
> and more adversarial reading, and the disagreement is a finding rather
> than a typo.
>
> **The mapping into the sixteen cases is
> [coverage.md](coverage.md)**, section "Edmond's adversarial cases",
> made 2026-08-23 as step S2.5 of `dev/PLAN.md`. Every number lands in
> the case that owns its shape or in a row saying why it lands in none,
> and twenty of the shapes opened eight new questions, 14 to 21, of
> [gc-horizon.md](../gc-horizon.md#open-questions).


**Status:** adversarial review, 2026-08-20. This file targets revision 5 of
[`gc-horizon.md`](../gc-horizon.md). It does not repeat the four Critic
rounds recorded there. Cases marked **break** expose a missing semantic or
soundness rule in the current text. Cases marked **must reject** are negative
compiler fixtures: the design remains sound only if they fall back to owned.

The oracle is stronger than “no use-after-free”. For each case compare classic
and proof-horizon lowering for: returned values, weak observations, destructor
order, death checkpoint batch, final counts, and the set of reachable objects.

## PH1 — destructor-free does not mean death-unobservable

**Inherited semantic prerequisite:** the owned-from-birth exclusion protects
`__destruct`, but the shared Drop Point Policy's “unobservable” premise omits
weak observation.

```php
$weak  = WeakReference::create($owner->child); // observer exists first
$child = $owner->child;       // candidate anchored borrow; Child has no destructor
consume_last_use($child);     // summarized, no horizon
unset($owner->child);         // after the borrow's IR live range
$seen = $weak->get();         // still inside the source scope
```

Current Zend-style scope lifetime keeps `$child` counted and `$seen` receives
it. Last-use lowering, including the Drop Point Policy already referenced by
proof-horizon, can let the sever reach zero and null the weak cell, so `$seen`
is `null`. `Child` is transitively destructor-free and non-COW.

The sever is outside the borrow's live range and therefore cannot promote it;
making it a horizon does not help. This is a language-visible lifetime change,
not a collector race. If last-use death is already accepted language policy,
PH1 is not a proof-horizon delta; it is still a prerequisite the algorithm
inherits and its differential oracle must state explicitly.

The observer is deliberately installed before the candidate borrow. Creating
it afterwards would itself be a call horizon and a by-value convention retain,
allowing promotion to disarm the test accidentally.

**Required rule:** any weak-subscribed target is owned, or the language
explicitly weakens object lifetime to last use. A static class rule cannot know
whether an instance later gains a weak subscriber; absent runtime state, every
weak-reference-capable entity may need the conservative treatment.

**Assert:** `$seen` and weak-cell nulling order match classic lowering.

## PH2 — WeakMap observes the same early death without `WeakReference::get`

**Inherited semantic prerequisite: independent witness for PH1.**

Install the destructor-free child as a `WeakMap` key before acquiring the
candidate borrow, end the borrow's last use,
sever the anchor, then inspect membership through an already-owned `WeakMap`.
Zend scope lifetime retains the key; last-use lowering can remove the entry
early. This catches an attempted fix that special-cases explicit
`WeakReference` cells but forgets weak-key tables or future weak subscribers.

**Assert:** key membership and weak cleanup order match the classic build.

## PH3 — the differential oracle declares the weak break legal

**Verification ambiguity inherited from the lifetime policy.**

Run PH1 with no destructors and arrange both frees in the same checkpoint
batch. The recorded differential oracle compares destructor sequence and the
death set per checkpoint batch; both can be identical while `$weak->get()`
returns different values between the two deaths. Its text explicitly permits
a destructor-free target's free to move into the parent's cascade.

**Required rule:** the differential oracle must also compare weak-cell
transitions, WeakMap removals, and values returned by weak loads, or must first
prove that lifetime movement of weak-observable objects is excluded.

## PH4 — an always-provable elision becomes somebody else's counted root

**Break: composition ambiguity in the hybrid.**

The hybrid permits an always-provable rule to remove a pair from a counted
class's local. The chain invariant separately allows an “owned local” as the
counted root of another anchored borrow. Consider:

```php
$a = $root->a;       // pair removed by an always-provable rule
$b = $a->b;          // anchored chain is recorded as ending in local $a
use($b);
```

If `$a` is still labelled `Owned` after its pair is removed, `$b`'s proof ends
in an uncounted local and rc-walk's exact test can condemn the heap chain under
the live borrow (the DC5 shape). If the first elision relabels `$a` Anchored,
the second chain must be concatenated through `$a` to the original counted
root; the current always-provable-rule contract does not say so.

**Required rule:** “owned” must mean an actually emitted live count, not a
source/classification label. Pair elision either changes lattice state and
transitively rewrites dependent chains, or forbids the local from anchoring
another borrow.

**Assert:** force a verdict over the heap path while `$b` is live; the exact
test must see a genuine external counted edge.

## PH5 — arena reset removes a root category without an explicit horizon kind

**Break unless reset summaries carry a mandatory invalidation.**

The chain may end in an arena slot, which rc-walk treats as a counted root.
Borrow through such a slot, keep the borrow live, then reset the arena through
an intrinsic or a trusted summarized helper. Reset destroys the root and may
promote only a survivor subgraph selected by the reset protocol. A summary that
says “no ordinary store and pure releases” can otherwise lift the call horizon
while the anchor category disappears wholesale.

**Required rule:** arena reset is an unconditional horizon for every chain
ending in that arena unless the borrow is promoted or the reset's promotion
fixpoint explicitly retains its entire path. It must not be liftable by an
ordinary call summary.

**Assert:** after reset, use of the borrow is safe and its target is either
owned or demonstrably in the promoted survivor closure.

## PH6 — fiber or generator suspension carries an arena borrow across reset

**Known open question, mandatory kill fixture.**

Suspend after borrowing through an arena-rooted chain. Let another scheduler
turn reset the arena and run a collection, then resume and use the borrow. The
frame exists but the root category on which its chain proof relied does not.

**Assert:** until resumption summaries exist, every suspension promotes all
live anchored borrows before yielding. Test fibers, generators, async
callbacks, cancellation, and exception injection at suspension separately.

## PH7 — a summary describes direct effects but misses a transitive alias

**Must reject; summary-language test.**

```php
$b = $a->left->target;
safe_helper($alias_to_a_right);  // summary says it does not write left
use($b);
```

Make `right` contain a PHP reference, dynamic property hook, shared container,
or user-defined proxy that aliases `left` and severs `target`. A field-name
effect summary passes while the storage location changes underneath the
borrow. This is the may-alias oracle residue the certificate admits it cannot
check.

**Assert:** unresolved references, hooks, proxies, `mixed`, and dynamic
properties make the call a horizon. Only a storage-location disjointness proof
may lift it.

## PH8 — FFI mutates a managed path behind a trusted “pure” call

**Must reject.**

Give C code a registered handle to the anchor or an interior managed slot. A
call summary records no language-level store, but C replaces or clears the
edge, invokes a callback, or retains the raw child beyond the call. The IR sees
neither the sever nor the new owner.

**Assert:** an FFI summary may lift a horizon only if it forbids managed-slot
mutation, raw/interior pointer retention, callbacks, and ownership transfer;
otherwise every live reachable chain is promoted. A registered FFI root alone
does not prove `stable_path`.

## PH9 — promotion must dominate the throwing edge, not merely its landing pad

**Must reject or place correctly.**

Borrow `b`, then call an unsummarized function which severs the anchor and
throws. A `finally` block or exception handler uses `b`. Promotion inserted on
the normal edge, at handler entry, or in a landing-pad owned-set update is too
late: destruction happened inside the call.

**Assert:** the retain is before the invoke on every normal and exceptional
path. The landing pad releases the promoted value once; it does not acquire it.
Repeat with nested `finally`, destructor-thrown exceptions, and a loop back-edge.

## PH10 — closure capture silently converts a borrow into a heap publication

**Must reject or transfer ownership.**

Capture an anchored borrow by value in a closure whose escape analysis first
looks local, then publish the closure through a return, callback registry,
object property, or exception backtrace. The captured reference outlives both
the borrow live range and its anchor. Capture by reference adds a writable
alias to the local as well.

**Assert:** escaping capture is an ownership transfer and emits a retain before
publication. By-reference capture is a by-reference horizon. A non-escaping,
immediately invoked closure may remain free only if its body and invocation
are included in the same horizon/alias proof.

## PH11 — late class loading invalidates destructor-freedom after callers ship

**Must reject under open-world loading.**

Compile a borrow against a destructor-free base or interface, then load a
subclass through autoloading, plugin code, `eval`, or a separately built unit.
The subclass adds `__destruct`, a property hook, or an override called from an
otherwise pure method. An old call summary and class bit now admit an elision
that changes destructor timing or severs the path.

**Assert:** the actual most-derived class set is closed and versioned across
all separately compiled units. Loading a widening class invalidates/recompiles
dependants or forces counted lowering at the original polymorphic site.

## PH12 — summary version matches, but a dependency's summary changed

**Break in versioning unless versions are transitive.**

Function `A` calls summarized `B`; `B` calls `C`. Recompile only `C` after it
gains a severing store or impure release, leaving `B`'s own source and summary
identifier unchanged. A caller validating only `B`'s direct summary version
accepts stale proof.

**Required rule:** summary identity includes the transitive dependency digest
and closed-class/purity inputs, not just the callee's source version. Dynamic
linking must reject an incompatible summary graph before executing old code.

## PH13 — checkpoint purity is data-dependent but lowering is static

**Break unless every potentially draining checkpoint defaults to horizon.**

The checkpoint lift asks whether the condemned set's downward closure is pure,
but the compiler cannot know which runtime component a checkpoint will drain.
At one execution it drains only P0 objects; at another, the same instruction
drains an impure destructor which mutates the anchor path.

**Required rule:** a static checkpoint is safe only when *every verdict it may
drain* has a pure downward closure, a property normally equivalent to a
closed-world global restriction. A runtime observation that “the current
verdict is pure” cannot retroactively promote a borrow before the checkpoint.

**Assert:** inject an impure verdict at a checkpoint compiled as lifted; the
borrow must already be owned or the checkpoint must not run user code.

## PH14 — alias born after analysis through reflection or `eval`

**Must reject, and test the conservative default.**

Borrow along `a.x.y`, then use reflection, `eval`, variable variables, a
property hook, or a PHP reference created by an included file to acquire a
writable alias to `x` and clear `y`. These mechanisms may not mention the
borrow's SSA value or statically named path.

**Assert:** each operation is an unconditional horizon for all live paths it
cannot prove disjoint. A per-site certificate must not turn absence from the
shared alias oracle into evidence of non-aliasing.

## PH15 — phi merges equal pointers with different proof roots

**Must fall back to owned.**

Two branches load the same target through different anchors. One anchor
survives; the other is severed before the joined use. Pointer equality at the
phi does not make the proofs equal: `live(anchor) ∧ stable_path` is about the
path, not the target identity.

**Assert:** a phi is Anchored only when the same chain dominates every incoming
edge. Target equality, common static type, or common terminal field is
insufficient.

## PH16 — the proof removes the checkpoint fabric that must complete its epoch

**Liveness break, already budgeted but not ruled.**

Construct a loop consisting entirely of accepted destructor-free borrows and
pure summarized calls. Elide its whole scope-exit release run, so neither the
batched ack/pickup pair nor a final-release checkpoint remains. Start an epoch
before the loop and post a verdict owned by that mutator. The loop makes
unbounded progress while the epoch, verdict, and deferred-free memory never
close.

This does not free a reachable entity, but it can turn a successful allocation
workload into unbounded parked-memory growth or OOM. Calling it merely an
economic effect understates that the collector's progress premise has changed.

**Assert:** a compensating poll rule gives a finite instruction/time/allocation
bound to ack and pickup, including the all-elided fast class. Measure that rule
as new mutator work rather than charging it outside the optimisation.

## PH17 — internal finalization exists without `__destruct`

**Break: the class predicate is too narrow.**

A suspended `Generator` can have no userland `__destruct`, yet its destruction
closes the frame and executes pending `finally` blocks and releases. The same
audit is owed for `Fiber` and internal classes with native `free_obj` or other
observable teardown handlers.

```php
$log = [];
$g = (function () use (&$log) {
    try { yield 1; } finally { $log[] = 'closed'; }
})();
$g->current();
$owner->g = $g;
unset($g);                 // owner is the only counted holder
$borrow = $owner->g;       // candidate anchored borrow
unset($owner->g);          // after borrow's last IR use
$seen = $log;
```

Classic lowering keeps the frame alive to the local's drop point; elision may
run `finally` at the sever. DCE of the apparently unused borrow has the same
obligation: it is legal only after proving death unobservable.

**Required rule:** the exclusion is transitively *observable-finalization
free*, including engine/native handlers and suspended-frame teardown, not just
absence of `__destruct`.

## PH18 — implicit PHP invokes are horizons too

**Must reject unless represented in effectful IR.**

Property hooks and magic access, casts such as `__toString`, iteration hooks,
autoload, error handlers, custom stream wrappers and engine callbacks can run
user code without an explicit source call. Make one clear the anchor path and
then use the borrow. A pass enumerating only call instructions sees no horizon.

**Assert:** every implicit invoke has normal and exceptional effects in the
final IR. Unknown callback targets carry arbitrary alias/sever/release effects.

## PH19 — exception diagnostics publish borrowed values

**Must reject or own before the throwing operation.**

A supposedly store-free callee throws. Exception traces, `debug_backtrace`,
configured argument capture, or an error/exception handler exposes and stores
the borrowed argument beyond the anchor's lifetime. The summary may correctly
say “no ordinary heap store” and still miss this publication channel.

**Assert:** may-throw summaries cover backtrace argument capture, handlers and
unwind publication. Otherwise passing a borrow is a horizon and convention
ownership is established before the invoke.

## PH20 — phi liveness belongs to incoming edges

**Compiler kill fixture.**

```text
E: b = borrow a.child; branch c, L, R
L: goto J(b)
R: goto J(null)
J: x = phi [b@L, null@R]; use(x)
```

A last-use pass treating the phi use as if it occurred only in `J` may release
or move `a` at the tail of `L`, before the edge transfers `b`. Borrow-is-use
must extend the transitive anchor through the specific incoming edge.

**Assert:** no release/move of an anchor precedes a phi-edge use carrying its
borrow; the verifier uses edge liveness, not block liveness.

## PH21 — inlining deletes the convention retain that was the root

**Break unless ownership is recomputed after ARC optimisation.**

Out of line, a callee's by-value parameter is counted and an inner borrow may
legally end its chain at that parameter. After inlining, ordinary ARC cleanup
can delete the parameter retain/release pair while leaving the borrow metadata
ending at a now-uncounted SSA copy. This recreates DC5 through a legal compiler
transformation.

**Assert:** after inlining and convention-pair elimination, rebuild chains:
preserve the retain, concatenate through the caller's real counted root, or
make the dependent borrow owned. Certificates are checked after optimisation.

## PH22 — shared landing pads need edge-sensitive ownership

**Compiler kill fixture.**

In a loop, one branch creates and promotes `b`; another reaches the same
throwing invoke without creating it. Both exceptional edges share a landing
pad and a reused stack slot. A union cleanup releases stale/uninitialized `b`
(possibly twice); an intersection cleanup leaks the promoted edge.

**Assert:** landing-pad state is per edge and SSA generation, using split pads,
an ownership phi or a tag. Release exactly once iff the retain dominates that
exceptional edge. Include nested `finally` and repeated loop iterations.

## PH23 — a late lowering pass introduces a horizon after certification

**Break in phase ordering.**

The proof accepts a mid-level region containing no call, store, release or
checkpoint. Later lowering expands a property/type operation, allocation slow
path, safepoint, hook or helper into an invoke/checkpoint capable of draining
or reentrancy. The certificate remains true only for obsolete IR.

**Assert:** independently enumerate horizons on final effectful IR after every
helper/safepoint insertion. LICM, PRE, loop rotation/unrolling/unswitching and
inlining must invalidate placement when they change births, backedges, exits
or effect sites.

## PH24 — external roots are revocable capabilities

**Break: PH5 generalizes to every non-frame root category.**

A chain ends in a static, immortal registry entry or owning FFI handle. A
trusted helper unregisters the handle, tears down the static table, unloads a
module/request or revokes the root without an ordinary managed-slot store.
`stable_path` inside the heap is unchanged, but the counted root disappeared;
a drain can now free under the live borrow.

**Required rule:** every root category defines identity, ownership and
creation/revocation operations. Revocation is a non-liftable horizon for every
chain ending there unless promotion precedes it.

## PH25 — not every FFI handle is a counted root

**Break in the chain vocabulary.**

Raw, weak, borrowed and pinned-address handles may keep an address stable while
emitting no retain. Treating any such handle as a root gives the exact test no
external count. A live anchored borrow can therefore coexist with a balanced,
condemnable heap component.

**Assert:** only a leased owning handle which actually emits or absorbs a
count may terminate a chain. Raw/weak handles never qualify, regardless of
address stability.

## PH26 — foreign mutation can occur between all IR events

**Break under asynchronous FFI.**

Register an async native callback, then acquire a borrow from the exposed
root/path. The foreign thread later revokes the owning handle or changes an
interior slot between two ordinary IR instructions. Promoting borrows live at
the registration call does not protect borrows born afterwards.

**Required rule:** a root/path exposed to asynchronous native mutation is
ineligible for Anchored until a join/unregister barrier proves exclusion, or a
runtime lease/pin protocol protects it. Static horizons alone cannot cover an
event with no IR site.

## PH27 — root and summary identities suffer ABA

**Representation/versioning break.**

Close handle-table slot `(index, generation 1)`, reuse the same index for a new
root, and let an old chain certificate identify only the slot. Likewise unload
and reload a module with the same name/version/hash but a new root universe.
The anchor appears live and the summary appears fresh while both capabilities
belong to a different incarnation.

**Assert:** certificates include non-reusable root generations/lease tokens and
a monotonic loader-incarnation epoch. Summary freshness includes residency and
the root universe, not only source/transitive digests.

## PH28 — shadow count cannot prove `stable_path`

**Break in verification coverage.**

```text
R -counted-> T
S -counted-> T
b = borrow R.x
bug: R.x = null without a horizon
use(b) while S still owns T
```

The borrow proof is false, but `shadow(T) > 0` thanks to unrelated owner `S`,
so no zero divergence occurs. The bug can remain latent indefinitely.

**Required oracle:** in verification builds, record allocation generations and
the identity of every edge in each live chain. At invalidating operations the
chain is unchanged or the borrow is already promoted. Shadow count is only a
first-divergence detector, not a proof of the path invariant.

## PH29 — one-sided shadow zero misses duplicate promotion

**Break in verification coverage.**

Emit promotion retain twice but only one release. The shadow count stays high,
never reaches the diagnostic zero, and the object leaks or dies late. The same
blind spot exists for overflow and release without a matching promotion.

**Assert:** reconcile the full equation at quiescent points and check both
directions. When no live elisions remain, shadow and classic counts agree.
Every promoted path has exactly one retain and one release; zero crossing is
irreversible for an allocation generation and is checked at each transition,
not only at batch end.

## PH30 — the certificate and checker can share the same omission

**Break in the proposed independent check.**

If the producer hands the checker its computed horizon set, a missed implicit
invoke/store is absent from both and the certificate verifies. Binding only to
summary IDs also does not prove that the emitted retain remains before an
exceptional edge after late scheduling.

**Required rule:** the checker independently reconstructs CFG, live ranges and
dangerous operations from final lowered IR. The producer supplies discharge
proofs, not the authoritative list of horizons. It verifies concrete emitted
retain IDs, counted root instructions, edge dominance, exceptional/cancel/
suspend/deopt edges, and one release on every promoted path.

## PH31 — a cold horizon makes promotion hot

**Economic model break.**

A borrow reaches an unsummarized call only on a 1% branch, but the placement
rule hoists one promotion to a point dominating the horizon and every exit.
The retain/release pair then executes on 100% of invocations. “Horizon
crossings per lifetime” reports 1% and predicts a saving that emitted code does
not have.

**Assert:** measure acquisition, promotion and horizon executions separately;
`promotions / acquisitions`, not crossings, prices cost. Sweep branch
probability from 0 to 1 and reconcile predicted with emitted dynamic pairs.

## PH32 — proof metadata can grow quadratically

**Economic/compiler scalability case.**

Generate `N` simultaneously live candidate borrows and `H=N` throwing horizons
with distinct live subsets. Per-site landing-pad sets, certificates and unwind
metadata can hold `Theta(N*H)` entries for linear source.

**Assert:** sweep `N=32..2048` and record compiler wall time/RSS, object text,
unwind and certificate bytes. Impose a fallback-to-owned cap or a compact
representation before superlinear growth reaches production inputs.

## PH33 — finite checkpoint thinning is max-straggler dominated

**Liveness/tail case beyond PH16's infinite loop.**

With several mutators, let one run a finite 10–500 ms allocation-free pure
region whose former scope-exit pairs supplied ack/pickup, while the others
retire aggressively. The epoch and parked memory wait for the slowest thread;
mean throughput can improve while p99 RSS/latency or OOM headroom regresses.

**Assert:** bound and measure `epoch start -> last ack`, `verdict -> pickup`
and maximum parked bytes across duration and mutator count. Any compensating
poll is charged to marginal savings and tested on zero-allocation loops, long
straight-line/vectorized work and summarized native calls.

## PH34 — pair elision batches reclamation into a latency spike

**Performance/semantic scheduling case.**

Classic local drops can distribute child decrements. Eliding them can move a
large destructor-free subtree's final releases into one owner sever or
checkpoint. Total RC instructions fall while one request performs a deep
cascade with allocator/cache pressure.

**Assert:** sweep subtree size and record p50/p99/max release and checkpoint
duration, cascade work and stack/queue depth. Pair count alone cannot approve a
variant that violates the tail budget.

## PH35 — the release counter needs a conservation law

**Measurement break.**

Exceptions, early returns, transfers and loop-carried SSA can make executed
acquisitions differ from a counter attached only to elided drop sites. Static
site-list equality between builds does not reconcile dynamic ownership.

**Assert:** assign stable lifetime/acquisition IDs and check
`acquired = dropped + transferred + unwind-dropped + live-at-termination`.
Run normal, return, throw and loop paths. Also stratify pair cost by header
sharing, NUMA, working set and final/non-final path; a scalar 1.85 ns multiplier
must cover the measured error band rather than define it.

## Minimum acceptance battery

Before lowering is enabled:

1. PH1–PH3 must settle weak-observable lifetime semantics and extend the
   differential oracle.
2. PH4 must prove that every anchor root owns an actual emitted count after all
   elision passes compose.
3. PH5–PH6 must make arena reset and suspension explicit horizon families.
4. PH7–PH8 and PH11–PH14 must run as negative fixtures against summaries,
   aliasing, FFI, late loading, and runtime-dependent checkpoint drains.
5. PH9–PH10 and PH15 must be pinned in SSA/exception/closure lowering tests.
6. PH16 needs a finite progress rule before savings can remove the last
   existing checkpoint in a loop.
7. PH17–PH19 extend semantic horizons to native finalization, implicit invokes
   and diagnostic publication.
8. PH20–PH23 are final-IR compiler mutation tests, including inlining and EH.
9. PH24–PH27 make external roots owning, revocable and generation-bearing.
10. PH28–PH30 replace one-sided shadow confidence with independent final-IR
    and path verification.
11. PH31–PH35 gate the design on emitted dynamic cost, metadata scaling,
    finite epoch tails, reclamation bursts and ownership conservation.

The first direct semantic blocker is PH17: proof-horizon's destructor-free
predicate does not exclude observable native/frame finalization even though
the shared Drop Point Policy does. PH1–PH3 separately require an explicit
language ruling on weak-observable last-use death. The first collector-
soundness blocker is PH4: an elision pass must not erase the count later used
as the root of another borrow's chain proof.
