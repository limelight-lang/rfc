# What the compiler must prove, and by which analysis

The counted walk moves its work to the compiler: every retain the compiler
removes is a pair the mutator never pays, worth up to 88 ns where the two
foreign headers miss (`ll-model` `dev/BENCHMARKS.md`, 2026-08-22). This
document names the analyses that removal needs — one section per proof, each
with what it must decide, the published algorithm that decides it, what the
front end must supply, and which PHP construct defeats it.

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

**What defeats it.** A dynamic call, whose callee is unknown and must be
assumed to release anything. Reflection. `&$x`, which makes a second name for
a slot the analysis is not tracking. Variable variables. Each turns into a
horizon: the borrow pays a pair there rather than being refused.

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
PHP does not have; the practical form here is class-level rather than
value-level, which is weaker and decidable on the graph.

**What the front end must supply.** The closed class set, and the declared
type of every slot.

**What defeats it.** Subclassing, which admits an instance into slots the
analysis did not count. Arrays, which hold anything. `mixed`.

**The open rule, and it is not a detail.** `../rc-walk.md` leaves three
options for a move of the owning slot: copy the entity, include "never moved"
in the proof, or emit a barrier. This design narrows the rule to the first
two: a barriered move readmits the fatal ordering of node M
([`../gc-horizon-v2/questions.md`](../gc-horizon-v2/questions.md)) — the
reference leaves a slot the walk has not read and arrives in one it has.

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
obligation at all. Most PHP classes have no destructor, so the collector-side
freeing path of ruling 5 has a population from day one.

## What this leaves

Every proof above is blocked on the same two things: a compiler, and a corpus
that says how much of real PHP survives the three constructs. Until both
exist, the counted walk pays the full pair on every store the runtime cannot
elide dynamically, and the levers that work today are collector-side —
nodes B1, B3 and C2 of [questions.md](questions.md).
