# Static Lifetimes: Compiler-Tracked Ownership

## Principle

The compiler tracks ownership the way Rust does, with one inversion.
Rust's type system *rejects* programs it cannot analyze; a PHP compiler
must accept every program. So static lifetime analysis here is a
**ladder of proofs with a runtime fallback**: whatever the compiler
proves, it compiles to cheaper code; whatever it cannot prove falls to
the runtime strategy ([../gc/strategies.md](../gc/strategies.md)),
never to a compile error.

The prize: for proven objects *all* RC traffic disappears and the
destructor becomes a direct call at a known point; the object's whole
life is scheduled at compile time. Prior art: Perceus (Koka) inserts
precise drops and erases paired RC statically; Lobster removes ~95% of
RC ops this way; elephc ships a small version of this
(`Owned`/`Borrowed`/`MaybeOwned` metadata on locals). This document
supersedes items 1 and 3 of
[arc-optimizations.md](arc-optimizations.md): they are the degenerate
rungs of this ladder.

---

## The Tier Ladder

Assigned **per allocation site**, conservatively: any doubt demotes.

| Tier | Proof | Emitted code |
|---|---|---|
| **1 (Local)** | object never escapes the function | stack (or arena-inline) allocation, direct drop at death point, **zero RC** |
| **2 (Scheduled)** | object escapes, but every alias is known and the death point X is statically certain | heap/arena allocation, a direct call to the class's `dispose` at X, **zero RC** |
| **3 (Dynamic)** | anything unproven | runtime ARC + the active strategy's cycle collection |

Tier 2 is the new rung: escape alone no longer condemns an object to
refcounting. An object handed to a callee that provably does not store
it (a *borrow*), or stored into a container whose own lifetime is
tier-1/2, inherits a statically known death point.

What demotes to tier 3: storing into `mixed`/untyped containers the
compiler cannot bound, `&` references, dynamic property names,
reflection, crossing an autoload boundary the compiler has not seen,
capture by an escaping closure.

Deferred RC ([../gc/gc-research.md](../gc/gc-research.md)) is hereby
repositioned: it is a **runtime optimization for tier-3 leftovers
only**, optional per build strategy; the static tiers do the same job
(eliminate RC traffic) without sacrificing deterministic destruction.
The fatter tiers 1–2 get, the less deferred RC matters.

---

## Ownership States and Moves

Every SSA value carrying a reference has a compile-time state:

- **Owned** — this binding is responsible for one count (or, in tiers
  1–2, for the scheduled drop).
- **Borrowed** — someone else owns it and provably outlives this use;
  no RC, no drop.
- **Unknown** — tier-3; runtime RC rules apply.

**Move**: at a binding's last use ownership transfers instead of
sharing; assignment or argument-pass emits neither `retain(new)` nor
`release(old)`, the source is dead and the sink inherits the
obligation. The pass is a last-use analysis over the CFG; joins that
disagree demote to Owned+RC. Function signatures record the convention
per parameter (borrows / takes ownership / escapes), inferred
whole-program where visible and assumed worst-case across unseen
boundaries.

This subsumes classic ARC pairing elimination: a retain/release pair
is just a move the analysis failed to name.

### What may own a borrow

A borrow is only as safe as whatever the analysis nominated as its
owner. The rule, and it is not the obvious one:

**The owner must be a reference the cycle collector treats as a root —
a frame slot, an arena slot, a static block, an immortal, an FFI
handle. A field of a heap object qualifies only through the chain rule
below, and never on its own.**

Three cases show why, in order of increasing subtlety.

*Ordinary ARC already forbids the first.* The owner dies before the
borrow does:

```php
$node = $graph->head;   // borrow; retain elided, $graph owns it
unset($graph);          // owner dead
$node->run();           // borrow outlives its owner
```

If `$graph` held the last reference, `head` dies on the spot by plain
refcounting and `$node` dangles. No collector involved; any ARC
compiler must emit the retain or postpone the drop.

*The second is the one the collector adds.* The owner is a heap field,
and the analysis reasons — correctly, for refcounting — that the object
stays alive because a live object references it:

```php
$x = $obj->other;   // borrow; retain elided, $obj->other owns it
$obj = null;        // $obj sits in a cycle: its count never reaches
                    // zero, so plain ARC keeps it alive forever
$x->run();
```

Under refcounting alone the reasoning holds and the cycle simply leaks.
Under a cycle collector it does not: the collector finds the ring, frees
`$obj` and `other` together, and `$x` dangles. **What the compiler
proved is liveness-by-refcount, and that is strictly weaker than
liveness.** This is why the owner has to be a root and not merely alive.

*The third shows how narrow the problem is.* Anything that leaves the
frame is counted by construction, because leaving means a store and
every store goes through the barrier:

```php
$x = $obj->other;
$f = function () use ($x) { $x->run(); };   // capture is a store: +1
```

So an uncounted borrow can only ever live in a frame slot, and both it
and its owner are decided by one compilation of one function. The
obligation is a within-frame property, not a whole-program one.

**The acyclic flag does not relax this.** An acyclic holder cannot be a
cycle member (../gc/rc-walk.md, "The compiler's
acyclic flag"), but it can still be garbage *held by* a cycle, and it
dies in the cascade the moment the collector frees that cycle. Its field
is therefore no safer an owner than any other.

### The chain rule, and the borrow as a use of its anchor

The deleted GC-horizon analysis introduced the following chain rule; the rule
is retained here independently of that collector. A heap field covers a
borrow when the field sits on a **counted path from a root**: the anchor
is a root by the rule above, every edge from the anchor to the borrowed
entity is a counted heap edge, and the borrow's live range ends at the
first point that can break either half.

The extension is sound for the same reason as the strict rule. During exact
validation, a candidate component that intersects the path carries an external
counted in-edge traceable to the root, so the whole path is classified as
externally referenced
([../gc/rc-cycle.md](../gc/rc-cycle.md), “Speculative tracing and exact
validation”). The second case above fails not because the
cover is a field but because `$obj = null` removes the root, leaving the
path with no counted in-edge from outside — which is why a store to any
local on the chain ends the coverage.

**A live borrow is a use of its transitive anchor.** The drop point
below and the move rule above are both computed over the borrow's live
range rather than over the anchor's own last syntactic use; otherwise
the drop releases the anchor, or the move transfers it, while a borrow
still leans on it. The points that end coverage are retained in
[`../gc/cycle/questions.md`](../gc/cycle/questions.md), Y11: a store to a chain
local, a store through a may-alias of a path base, a release of a class whose
destructor-effect closure is impure, an unsummarized call, and a consistent
point that can run collection.

## Drop Point Policy

Where does the scheduled drop go: end of scope (Zend-observable
timing) or last use (Swift-style, faster, but destructors fire
"early")?

**Decision**: split by observability.

- Class (transitively) has **no `__destruct`** and holds no
  finalizable resources → drop timing is unobservable → the compiler
  drops at **last use**. This is the overwhelming majority of objects.
- Otherwise → drop at **scope end**, exactly where Zend semantics
  would free. No `withExtendedLifetime`-style escape hatches needed.

---

## Relationship Analysis

Beyond single-object lifetimes, the compiler classifies the *character
of reference edges between classes* and feeds it to the cycle
collector. Cycles are the one thing RC cannot handle
([../gc/strategies.md](../gc/strategies.md)); today's runtimes discover
them by conservative runtime heuristics (Zend: every non-zero decrement of any
object is a possible cycle root). Most of that candidacy is statically
refutable.

### Level A — Acyclic classes (safe, ships first)

Compute each class's **field-type closure**: the set of classes
reachable through declared property types. If class `C` cannot reach
`C` (or a supertype admitting `C`), its instances **can never
participate in a cycle**: an `ACYCLIC` bit is set in the class flags,
and decrements of such objects never enter the cycle-candidate buffer.

- Typed properties make the closure real; untyped/`mixed`/`array`
  properties are conservative edges to "anything", hence not acyclic.
- `#[AllowDynamicProperties]`, `__set`, reflection writes → not acyclic.
- Effect: the candidate buffer shrinks from "every object" to
  "instances of the (few) cycle-capable classes". CPython does a
  runtime version of this (untracking scalar-only tuples); we get it
  from the type system for free.

### Level B — Known cycle shapes (the parent/child case)

The classic PHP cycle is structural, not accidental:

```php
class Node {
    public ?Node $parent;        // back edge: points up the tree
    /** @var list<Node> */
    public array $children;      // ownership edges: point down
}
```

The compiler detects the pattern (a class whose type closure reaches
itself through exactly identified properties), or the programmer
declares it:

```php
class Node {
    #[Backedge] public ?Node $parent;
    ...
}
```

The marked edge is recorded in the class's GC shape metadata. Two
exploitations, both semantics-preserving (a backedge still counts;
this is *not* a weak reference):

1. **Precise candidate registration.** Constructing a marked cyclic
   edge registers the object as a cycle candidate *at that moment*,
   replacing Zend's "every non-zero decrement is suspicious"
   heuristic. Combined with Level A, the candidate buffer contains
   exactly the objects that demonstrably closed a cycle, and the
   collector's trigger threshold measures real risk, not noise.
2. **Shape-guided collection.** When the collector examines a
   candidate whose class declares its cycle shape, it traces only the
   declared edges (parent/children), not every refcounted slot: a
   targeted trial with a far smaller constant factor than a generic
   graph trace.

### Level C — Non-counting backedges (research)

The aggressive endgame: if the structure is a compiler-verified
**ownership tree** (children owned by parent, backedges only to
ancestors), the backedge needs no count at all: the ancestor provably
outlives the child *while the tree is intact*. The whole tree then
dies by refcount alone, no cycle collector involved: Rust semantics,
inferred.

The hazard is an interior node escaping the tree (`$n = $tree->find(...)`
outliving the tree): the barrier would have to detect the escape and
*upgrade* the region to counted mode. Escape-upgrade cost and
correctness under `&` references are unresolved; parked in the
backlog, not committed.

---

## Interactions

- **Arenas** ([arenas.md](arenas.md)): tier analysis and category
  inference are the same pass: tier-1 in a request context allocates
  in the request arena; "escapes the request" is just the coarsest
  escape level ([arena-promotion.md](arena-promotion.md)).
- **Strategies** ([../gc/strategies.md](../gc/strategies.md)): tiers
  1–2 objects never touch the active strategy at all; Levels A/B shrink
  the work handed to whichever cycle collector the build selected
  (`rc-trace` pauses get shorter, `rc-satb` epochs get rarer).
- **COW entities** ([../values.md](../values.md)): refcount doubles as
  the sharing test on COW values, so tiers 1–2 apply to them only when
  the analysis also proves no COW sharing is observable. Deferred ARC
  (tier 3, [arc-optimizations.md](arc-optimizations.md) item 2) does not
  apply to them at all: the count must equal the number of holders at
  every instant a write can read it, and deferral is the one
  optimization that breaks that invariant rather than preserving it
  (`values.md`, "Refcount is always maintained on COW entities").

## Open Questions

- Inference vs annotation balance for Level B: how much of the
  parent/child pattern is detected without `#[Backedge]`; the detected
  part is **materialized back into source** as `#[Backedge]` per the
  attributes principle ([../../attributes.md](../../attributes.md)),
  making deep-analysis results a persistent, reviewable cache.
- Signature ownership conventions across truly dynamic call sites
  (`$fn(...)`, `call_user_func`): worst-case assumptions may eat
  tier-2 wins in callback-heavy code; measure.
- Level C escape-upgrade design (see backlog).
