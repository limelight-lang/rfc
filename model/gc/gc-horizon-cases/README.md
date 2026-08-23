# GC horizon — the case book

## Scope

Sixteen cases that instantiate [gc-horizon.md](../gc-horizon.md) on one
entity kind or one proof-ending event each. The algorithm document says
what the rule is; a case says what the rule does to a particular piece of
the runtime, which states it moves, and what a test would have to assert
about it. Where a case finds a hole in the algorithm, it records the hole
in its Open items and points at the numbered open question rather than
inventing a fix.

The state axes every case projects into are in
[gc-horizon-states.md](../gc-horizon-states.md). The algorithm stays
normative: a case that disagrees with it is wrong.

> **Status: written 2026-08-20, nothing implemented.** The design is
> closed pending Phase D and two of its three verification instruments
> need a compiler that does not exist, so most cases can name an oracle
> and not build it. Section 7 of each case says which.

## Terminology: three meanings of "borrow" in this repository

The word arrives from three directions and they are not the same thing.

- **An anchored borrow** is this design's term: an IR local holding an
  uncounted reference whose safety is a compiler proof
  ([gc-horizon.md](../gc-horizon.md#the-ownership-lattice)). Its
  **anchor** is the counted root its chain ends in.
- **`#[Borrow]`** is an attribute of the FFI surface: a field or
  parameter holding a `char*` or pointer into memory a managed entity
  owns, which the FFI layer must not free
  ([ffi.md](../../memory/ffi.md#the-owner-model)).
- **"Anchor" in [ffi.md](../../memory/ffi.md#the-owner-model)** already
  names the owning entity a foreign pointer is kept alive by. The two
  anchors coincide in intent — a live owner behind an uncounted view —
  and not in mechanism: this design's chain is counted at every edge and
  is checked by the collector's exact test, while the FFI one is checked
  by nothing at all.

A fourth sense, the **Borrowed** ownership state of
[static-lifetimes.md](../../memory/static-lifetimes.md#ownership-states-and-moves),
is the parent of the first: an anchored borrow is a Borrowed SSA value
whose owner is reached through the chain rule rather than held directly.

## The template

Every case carries these nine sections, in this order, with "none"
written out where a section is empty. A missing section is a defect; an
empty one is a fact.

1. **The case** — one paragraph and a PHP snippet small enough to read
   whole.
2. **The lattice verdict** — owned or anchored, and which base case or
   which cascade rung decided it.
3. **The horizon set** — every point in the snippet where a proof ends,
   each named as one of the eight kinds.
4. **The lowering** — today's pairs against the horizon lowering. Where
   the verdict is owned, the section says so in one line instead of
   printing two identical listings.
5. **States touched** — axes from
   [gc-horizon-states.md](../gc-horizon-states.md), one transition line
   each, and only the axes this case *moves*.
6. **The picture** — a mermaid diagram of the mechanism, not of the
   prose.
7. **The oracle** — what a test asserts, which instrument runs it, and
   whether that instrument exists today.
8. **Prior art in this repository** — the already-written cases and
   sections this one depends on or subsumes, cited by identifier.
9. **Open items** — holes this case found, each pointing at a numbered
   open question of [gc-horizon.md](../gc-horizon.md#open-questions) or
   naming what specification is missing.

**The citation contract.** Every asserted behaviour carries an inline
link to the section that states it. A sentence with no citation is
either the algorithm's own text or an open item, and it says which.

## The template, filled: one function, both lowerings

```php
function total(Cart $c): float {   // $c: owned by convention (parameter)
    $items = $c->items;            // owned: array, COW-eligible
    $tax   = $c->tax;              // anchored: Tax is closed, pure,
                                   //   destructor-free, typed field
    audit($c);
    return $tax->rate * count($items);
}
```

**Without a summary for `audit()`** the call is a horizon. `$tax` is
born at the load, and the promotion point is the latest point dominated
by that load which dominates every horizon, every exit and every raise
site of the live range and lies inside no cycle the load lies outside of
([gc-horizon.md](../gc-horizon.md#at-the-horizon-promotion), as ruled on
2026-08-22). Here that is immediately before the call, so the compiler
emits one retain there and the matching release at
today's drop point. `$tax` pays one pair — the same pair today's code
pays, over a shorter subrange:

```
$tax = load $c->tax          ; no retain
retain $tax                  ; the promotion, at the horizon
call audit($c)
...
release $tax                 ; the drop-point policy, unchanged
```

**With a summary** proving `audit()` severs nothing on the `$c->tax`
path and releases nothing impure, the horizon set is empty, no promotion
point is needed, and both instructions disappear:

```
$tax = load $c->tax          ; no retain
call audit($c)               ; summarized: not a horizon
...                          ; no release: nothing was acquired
```

That second lowering is the base case the whole design exists to
produce, and it is the only shape in this book where a borrow costs
nothing. `$items` pays today's pair in either world: the lattice never
elides a COW holder, because the separation test reads the count
([values.md](../../values.md#refcount-is-always-maintained-on-cow-entities)).
The narrower licence that document grants — a pair may be elided where
the compiler proved no second holder arises — is a different instrument
from this one and is not what the lattice applies here.

## The index

**Read the exclusions as one thing.** Six of the nine entity cases share
a single verdict: the referent is owned by a base case and the lowering
is today's exactly. The base cases are stated once, here, and each of
those files exists for the fact that *qualifies* the exclusion, not for
the exclusion itself. A reference is owned by construction when it is
the result of `new`, the result of a call, a receiver or by-value
parameter, a COW-eligible value, a target whose class is not
transitively destructor-free, a path crossing a unique-ownership entity,
or the value a weak-cell read produces — the last by Edmond's ruling 11
of 2026-08-22, counted always and elided never
([gc-horizon.md](../gc-horizon.md#the-ownership-lattice)).

### The entity cases

| Case | The fact it exists for |
|---|---|
| [object.md](object.md) | the anchorable kind: where a borrow is actually free, and where the first promotion lands. It carries the lazy kind too, the second anchorable one, whose verdict its open item 1 leaves undetermined |
| [array.md](array.md) | exclusion by COW — qualified by storage transitions, which move the referent under a live anchor without breaking `stable_path` |
| [string.md](string.md) | exclusion by COW — qualified by the sub-modes: an out-of-line string is not COW-eligible by kind alone |
| [weakref.md](weakref.md) | the uncounted `target` edge: a path through a weak cell is not a counted chain, and the value read through one is owned by the base case ruling 11 added |
| [reference-box.md](reference-box.md) | exclusion by COW — qualified by the by-reference escape, which is a horizon in its own right |
| [closure.md](closure.md) | **hole report**: capture is a store, and the closure's own entity kind and layout are unspecified in this repository |
| [ffi.md](ffi.md) | exclusion by the destructor rule — qualified by `#[Borrow]` views, whose invalidation is visible to no horizon kind |
| [unique-entity.md](unique-entity.md) | exclusion by the sentinel — qualified by the demotion fixpoint and by the inconsistent intersection with COW |
| [destructor-bearing.md](destructor-bearing.md) | exclusion by the purity closure — qualified by the ladder's tiers and by the scope-end pin it protects |

### The event cases

| Case | The fact it exists for |
|---|---|
| [call.md](call.md) | the horizon kind that pays for everything else: calls, dynamic dispatch, reflection, and the summaries that lift them |
| [store.md](store.md) | severing stores under the may-alias rule, and the store *to* an anchor that no other kind names |
| [release.md](release.md) | eager death at zero, the drop-point policy, and why a borrow is a use of its anchor |
| [checkpoint.md](checkpoint.md) | the drain's two threats, one discharged by construction and one gated on purity |
| [unwind.md](unwind.md) | placement under unwinding: the raise sites of a live range are not its call sites |
| [suspension.md](suspension.md) | **hole report**: a yield is a horizon by default, and the generator/fiber frame model is unspecified |
| [arena.md](arena.md) | the non-frame counted roots, and the two memory categories where a promotion retain buys nothing |

### Which cases can be tested today

**A lattice verdict and the premise under it are two assertions, and
they become buildable at different times.** Every verdict needs the
compiler, through the shadow-count lowering or the differential
lowering. A premise — what the runtime does to the entity the verdict is
about — is testable against the existing crate today, and ten of the
sixteen cases name one in their section 7. Five have a runtime oracle
and nothing else: [checkpoint.md](checkpoint.md), [arena.md](arena.md),
[weakref.md](weakref.md), [release.md](release.md) and
[destructor-bearing.md](destructor-bearing.md), whose assertions are the
destructor sequence, the death set, the weak-nulling order and the exact
test's verdict over a hand-built heap shape. Five more carry a runtime
premise beside a verdict that waits: [object.md](object.md) on a ghost's
walk behaviour, [array.md](array.md) on transitions and separation,
[string.md](string.md) on the three sub-modes,
[reference-box.md](reference-box.md) on the duplication collapse, and
[ffi.md](ffi.md) on a stale view under a correct count.
[store.md](store.md) is an eleventh of a different kind: its third
oracle is the corpus scan, compiler-free and able only to kill. Each
file's own "Buildable today" line is the authority; this paragraph
counts them.

The third candidate instrument, a model-checker scenario, carries a
recorded protocol drift: the TLC specs model the pre-amendment protocol
while eager death is the premise of the release horizon
([rc-walk-model.md](../rc-walk-model.md)). That document bounds the
drift itself — the battery is evidence for the superseded rule set
"except where a scenario exercises machinery the amendment kept (walk,
filter, exact test, sever, deferred queue), which is most of it" — so
the re-derivation is owed for a scenario that turns on condemnation,
death deferral or acquittal messages, and not for one that exercises the
kept machinery.

## Edmond's adversarial cases

Thirty-five attack shapes, PH1 to PH35, are in
[adversarial.md](adversarial.md) — written the same day as this book and
moved here whole. Several of them and several of the open questions in
[gc-horizon.md](../gc-horizon.md#open-questions) are the same finding
reached from two directions: PH5 and question 8 (the arena reset removes
a root category), PH9 and question 9 (promotion must dominate the
throwing edge, ruled 2026-08-22 as PH9 read it). The mapping of every PH
number into the sixteen cases is [coverage.md](coverage.md), made
2026-08-23; eight land in no case with a reason, and twenty of the
shapes opened eight questions, 14 to 21 — among them the weak break of
PH1 to PH3, which question 7 did not cover and ruling 11 did not
close.

## Coverage

The table mapping this book against the cases already written in the
repository is [coverage.md](coverage.md).
