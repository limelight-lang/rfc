# What the compiler must prove, and by which analysis

The counted walk moves its work to the compiler: every retain the compiler
removes is a pair the mutator never pays. What one removal is worth differs
by proof and has to be derived, because the measurement and the elision are
not over the same object. Node A1 of [questions.md](questions.md) measured an
overwriting store's pair — a retain of the new target and a release of the
old, so two foreign headers — at 2.9 ns with both warm and 33 ns at a
population of a million (`ll-model` `dev/BENCHMARKS.md`, 2026-08-22), which
splits into about 2.9 ns of instructions and about 15 ns per cold header. The
proofs below then remove one touch or two: the birth count removes a
construction retain and leaves the matching release, anchor-chain elision
removes an adjacent pair whose second touch is warm, and unique ownership
removes a retain and a release separated by the entity's whole life. **So the
range is about 3 ns to about 33 ns per elision, derived and unmeasured**, and
A1 carries the table. The 88 ns of the first probe of that day is retracted
in the same file and enters no calculation here.

This document names the analyses that removal needs — one section per proof,
each with what it must decide, the published algorithm that decides it, what
the front end must supply, and which PHP construct defeats it.

It does not restate the rules being proved. Ownership and moves are
[`../../memory/static-lifetimes.md`](../../memory/static-lifetimes.md); the
lattice and the horizon list are [`../gc-horizon.md`](../gc-horizon.md); the
purity ladder is [`../pure-destructors.md`](../pure-destructors.md). The
descriptions of published work are taken from this repository's own survey,
[`../gc-research.md`](../gc-research.md), not from the papers.

## The structure three of the five share

Three of the five proofs below — unique ownership, the acyclic flag and the
purity closure — are closures over the **class field-type graph**: a node per
class, an edge from a class to every class its declared fields can hold.
Build it once and all three read it. The other two, anchor-chain elision and
the birth count, are intraprocedural and read the graph not at all.

All three also fail on the same three constructs, and fail closed:

- a field typed `mixed`, or untyped;
- an array whose element class is unknown;
- an open class, one a subclass can extend at run time, which widens what a
  field of that type may hold.

That gives one corpus measurement rather than three: how often those three
constructs appear in real PHP field declarations bounds all three proofs at
once. Node A6 of [questions.md](questions.md) is that measurement, and it is
why A6 is drawn as the root of the section rather than as one node among the
others. The two intraprocedural proofs are bounded by a different quantity —
how often a call's effects are unknown — which A6 must measure separately.

## 1. Anchor-chain elision — is this borrow covered by a live count

**What it must decide.** A borrow is a reference held with no count. It is
sound while some other reference with a count — the anchor — provably
outlives it. The compiler must establish, for each borrow, an anchor whose
live range covers the borrow's, and that the borrow does not survive a
horizon ([`../gc-horizon.md`](../gc-horizon.md), the horizon list).

**The analysis.** Two passes over SSA form. First, an aliasing analysis that
decides when two SSA values name the same entity — Swift calls this **RC
Identity Analysis** and uses it for exactly this purpose. Second, a forward
scan pairing a retain with the release that cancels it and deleting both when
nothing in between can release the entity — Swift's **ARCOpt**. The precise
form, where an object is freed at its last use rather than at scope exit, is
**Perceus** (Koka, PLDI 2021), formalised in a linear resource calculus with
a garbage-free proof.

**What the front end must supply.** SSA over PHP, and an effect summary per
call: whether a callee can release the anchor.

**What defeats it.** Every kind on the horizon list
([`../gc-horizon.md`](../gc-horizon.md#the-horizon-list)), because the anchor
beyond a horizon does not cover the borrow before it. There are eight, and
this analysis meets all eight: a call whose effects it cannot obtain fresh
and trusted, dynamic dispatch whose target set it cannot bound, reflection, a
by-reference escape, a suspension — a `yield`, a fiber switch, a parked
external call — a release of a class whose transitive-purity closure is not
pure, a checkpoint that can drain a verdict, and an own-code store that may
alias a borrowed path. `&$x` is the fourth kind, and variable variables reach
the analysis as the eighth: `$$name = null` is a store to a slot the aliasing
analysis cannot name, not a call whose targets it cannot bound. None of the
eight refuses the borrow: each turns into a horizon, and the borrow pays a
pair there.

The last three bound the shape of the pass rather than its verdict. A region
holding no dynamic call and no reflection is not therefore free of horizons,
since an ordinary store, an ordinary release of an impure class and an
ordinary checkpoint each end a borrow's cover, so the pass cannot certify a
region by scanning it for calls.

**What transfers directly.** Swift annotates `swift_retain` as having no
memory side effects, which lets LLVM reorder and cancel it, and cannot
annotate `swift_release`, because release can run a destructor
([`../gc-research.md`](../gc-research.md)). `ll_retain` has the same shape and
can carry the same annotation; `ll_release` cannot.

## 2. The birth count — how many references will this constructor produce

**What it must decide.** The number of counted references an entity will hold
when its construction sequence ends, so the factory writes that number as the
initial count and the sequence's publications emit no retain
([`../rc-walk.md`](../rc-walk.md), "The birth count").

**The analysis.** A bounded count over the constructor's control-flow graph:
every publication of the entity inside the sequence, on every path, must
produce the same total, and the sequence's end must dominate the first point
at which the entity escapes. Where paths disagree the constant is the
minimum and the difference is emitted as ordinary retains. The published
analogue is Perceus's **drop specialization** — emit the exact decrements
rather than call a generic routine — applied to the increment side.

**What the front end must supply.** The construction sequence's boundary, and
an effect summary saying no callee inside it publishes the entity.

**What defeats it.** A constructor calling a method that publishes `$this`.
`__set` and dynamic properties, where the publication site is not a
statically known slot. A throw inside the sequence, which ends it early with
a count already written.

## 3. Unique ownership — is exactly one heap slot ever going to hold this

**What it must decide.** That one heap slot holds the entity's only counted
reference for its whole life, that every other copy is a borrow dead before
the slot is overwritten, and that no weak reference, FFI handle or static
reaches it except through the owner
([`../rc-walk.md`](../rc-walk.md), "Unique ownership").

**The analysis.** Escape analysis plus a single-writer check over the
field-type graph: the set of declared slots whose type admits this class must
have exactly one member reachable from the entity's construction site. The
strict published form is an affine type system — Rust's ownership — which
PHP does not have. The practical form here tests the class where node A3 of
[questions.md](questions.md) states the property of a value, and the class
test is **necessary and not sufficient**: it is decidable on the field-type
graph, which the value-level property is not, and passing it does not
establish that property.

The gap is that a declared slot is a declaration site while the property is
about run-time slots, and the two differ by the instance count of the holder
class. `class Node { public Payload $p; }` has exactly one declaring slot for
`Payload` and ten thousand instances, so `$a->p = $b->p; unset($b);` puts one
entity in two run-time slots, the elided count frees it at the first death,
and `$a->p` is a dangling reference. So the graph narrows the candidates and
the escape-and-single-writer half must discharge the rest, by proving no
store copies the entity between two slots of one declared type. That
obligation is stated here and discharged nowhere. A round of review on
2026-08-23 read the class form as the *stronger* obligation and was wrong: as
a decision procedure it admits more entities, not fewer.

**What the front end must supply.** The closed class set, and the declared
type of every slot.

**What defeats it.** Subclassing, which admits an instance into slots the
analysis did not count. Arrays, which hold anything. `mixed`.

**The open rule, and it is not a detail.** `../rc-walk.md` leaves three
options for a move of the owning slot: copy the entity, include "never moved"
in the proof, or emit a barrier. This design narrows the rule to the first
two, on `../gc-horizon.md` open question 4 as Edmond ruled it 2026-08-18: no
rule introduces a write barrier. The unbarriered move is what carries the
hazard — the reference leaves a slot the walk has not read and arrives in one
it has — and a barrier is one of the answers node M of the refused regime
asks for rather than the defect M names.

## 4. The acyclic class flag — can an instance of this class sit on a ring

**What it must decide.** That no chain of declared field types leads from the
class back to itself. Such an instance cannot be a member of a cycle, so the
walk may skip its row entirely
([`../rc-walk.md`](../rc-walk.md), "The compiler's acyclic flag").

**The analysis.** Strongly connected components over the class field-type
graph — Tarjan's algorithm, one pass. A class is acyclic exactly when its
node lies on no cycle of the graph.

**What the front end must supply.** The graph, closed.

**What defeats it.** The same three constructs, and each of them collapses a
large part of the graph into one component rather than spoiling one class:
a single `mixed` field makes its class reach every class, so everything
reachable from it becomes cyclic. The flag is therefore all-or-nothing on a
codebase's typing discipline, which is a corpus question and not a design
one.

**Available without the compiler.** The kind-level form: a string, a weak
reference or a plain scalar box holds no reference to a class and cannot ring
whatever the graph says. Node B1 of [questions.md](questions.md) takes it
today.

## 5. The purity closure — can the collector run this destructor

**What it must decide.** That a destructor's body writes nothing observable
and that every destructor reachable through the death cascade does the same
([`../pure-destructors.md`](../pure-destructors.md), "Purity is transitive").

**The analysis.** Three parts. An intraprocedural effect analysis over the
destructor body, classifying writes as own-scalar, own-counted-slot, or
external. A no-throw proof, because an exception leaving `__destruct` carries
`$this` in its backtrace. A transitive closure over the field-type graph,
which is the same closure as the acyclic flag and fails on the same three
constructs. The developed published form of the first part is an effect
system; this repository's survey names none, so the reading is owed.

**What defeats it.** PHP 8 arithmetic and typed properties can throw, so the
no-throw obligation is the hardest part, and
[`../pure-destructors.md`](../pure-destructors.md) records the hypothesis
that it prunes the passing population more than any other rule.

**Available without the compiler.** Rung P0 — no `__destruct` anywhere in the
hierarchy — is computed by the class linker today, with no compiler
obligation at all. Most PHP classes have no destructor, so the population is
large. **It is not yet safe to free:** node G11 of
[questions.md](questions.md) shows P0 reading `__destruct` and no other
finalization, and both a suspended generator and a weak cell satisfy P0 while
still finalizing. Ruling 5's collector-side path has its population from day
one only once that predicate is rewritten over observable finalization.

## What this leaves

Every proof above is blocked on the same two things: a compiler, and a corpus
that says how much of real PHP survives the three constructs. Until both
exist, the counted walk pays the full pair on every store the runtime cannot
elide dynamically, and the levers that work today are collector-side —
nodes B1, B3 and C2 of [questions.md](questions.md).
