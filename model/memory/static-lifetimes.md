# Static Lifetimes: Compiler-Tracked Ownership

## Principle

The compiler tracks ownership the way Rust does — with one inversion.
Rust's type system *rejects* programs it cannot analyze; a PHP compiler
must accept every program. So static lifetime analysis here is a
**ladder of proofs with a runtime fallback**: whatever the compiler
proves, it compiles to cheaper code; whatever it cannot prove falls to
the runtime strategy ([../gc/strategies.md](../gc/strategies.md)) —
never to a compile error.

The prize: for proven objects, *all* RC traffic disappears and the
destructor becomes a direct call at a known point — the object's whole
life is scheduled at compile time. Prior art: Perceus (Koka) inserts
precise drops and erases paired RC statically; Lobster removes ~95% of
RC ops this way; elephc ships a small version of this
(`Owned`/`Borrowed`/`MaybeOwned` metadata on locals). This document
supersedes items 1 and 3 of
[arc-optimizations.md](arc-optimizations.md) — they are the degenerate
rungs of this ladder.

---

## The Tier Ladder

Assigned **per allocation site**, conservatively — any doubt demotes.

| Tier | Proof | Emitted code |
|---|---|---|
| **1 — Local** | object never escapes the function | stack (or arena-inline) allocation, direct drop at death point, **zero RC** |
| **2 — Scheduled** | object escapes, but every alias is known and the death point X is statically certain | heap/arena allocation, direct `ll_object_die` at X, **zero RC** |
| **3 — Dynamic** | anything unproven | runtime ARC + the active strategy's cycle collection |

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
only**, optional per build strategy — the static tiers do the same job
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

**Move**: at a binding's last use, ownership transfers instead of
sharing — assignment or argument-pass emits neither `retain(new)` nor
`release(old)`; the source is dead, the sink inherits the obligation.
The pass is a last-use analysis over the CFG; joins that disagree
demote to Owned+RC. Function signatures record the convention per
parameter (borrows / takes ownership / escapes), inferred
whole-program where visible and assumed worst-case across unseen
boundaries.

This subsumes classic ARC pairing elimination: a retain/release pair
is just a move the analysis failed to name.

## Drop Point Policy

Where does the scheduled drop go — end of scope (Zend-observable
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
of reference edges between classes* — and feeds it to the cycle
collector. Cycles are the one thing RC cannot handle
([../gc/strategies.md](../gc/strategies.md)); today's runtimes discover
them by blind runtime heuristics (Zend: every non-zero decrement of any
object is "suspicious"). Most of that suspicion is statically
refutable.

### Level A — Acyclic classes (safe, ships first)

Compute each class's **field-type closure**: the set of classes
reachable through declared property types. If class `C` cannot reach
`C` (or a supertype admitting `C`), its instances **can never
participate in a cycle**: an `ACYCLIC` bit is set in the class flags,
and decrements of such objects never enter the cycle-candidate buffer.

- Typed properties make the closure real; untyped/`mixed`/`array`
  properties are conservative edges to "anything" — not acyclic.
- `#[AllowDynamicProperties]`, `__set`, reflection writes → not acyclic.
- Effect: the candidate buffer shrinks from "every object" to
  "instances of the (few) cycle-capable classes". CPython does a
  runtime version of this (untracking scalar-only tuples); we get it
  from the type system for free.

### Level B — Known cycle shapes (the parent/child case)

The classic PHP cycle is structural, not accidental:

```php
class Node {
    public ?Node $parent;        // back edge — points up the tree
    /** @var list<Node> */
    public array $children;      // ownership edges — point down
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
exploitations, both semantics-preserving (a backedge still counts —
this is *not* a weak reference):

1. **Precise candidate registration.** Constructing a marked cyclic
   edge registers the object as a cycle candidate *at that moment* —
   replacing Zend's "every non-zero decrement is suspicious"
   heuristic. Combined with Level A, the candidate buffer contains
   exactly the objects that demonstrably closed a cycle, and the
   collector's trigger threshold measures real risk, not noise.
2. **Shape-guided collection.** When the collector examines a
   candidate whose class declares its cycle shape, it traces only the
   declared edges (parent/children), not every refcounted slot — a
   targeted trial with a far smaller constant factor than a generic
   graph trace.

### Level C — Non-counting backedges (research)

The aggressive endgame: if the structure is a compiler-verified
**ownership tree** (children owned by parent, backedges only to
ancestors), the backedge needs no count at all — the ancestor provably
outlives the child *while the tree is intact*. The whole tree then
dies by refcount alone, no cycle collector involved: Rust semantics,
inferred.

The hazard is an interior node escaping the tree (`$n = $tree->find(...)`
outliving the tree): the barrier would have to detect the escape and
*upgrade* the region to counted mode. Escape-upgrade cost and
correctness under `&` references are unresolved — parked in the
backlog, not committed.

---

## Interactions

- **Arenas** ([arenas.md](arenas.md)): tier analysis and category
  inference are the same pass — tier-1 in a request context allocates
  in the request arena; "escapes the request" is just the coarsest
  escape level ([arena-promotion.md](arena-promotion.md)).
- **Strategies** ([../gc/strategies.md](../gc/strategies.md)): tiers
  1–2 objects never touch the active strategy at all; Levels A/B shrink
  the work handed to whichever cycle collector the build selected
  (`rc-trace` pauses get shorter, `rc-satb` epochs get rarer).
- **COW entities** ([../values.md](../values.md)): refcount doubles as
  the sharing test on COW values, so tiers 1–2 apply to them only when
  the analysis also proves no COW sharing is observable.

## Open Questions

- Inference vs annotation balance for Level B: how much of the
  parent/child pattern is detected without `#[Backedge]` — and the
  detected part is **materialized back into source** as `#[Backedge]`
  per the attributes principle ([../../attributes.md](../../attributes.md)),
  making deep-analysis results a persistent, reviewable cache.
- Signature ownership conventions across truly dynamic call sites
  (`$fn(...)`, `call_user_func`) — worst-case assumptions may eat
  tier-2 wins in callback-heavy code; measure.
- Level C escape-upgrade design (see backlog).
