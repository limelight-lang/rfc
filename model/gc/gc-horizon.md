# GC Horizon: borrow protection paid where the proof ends

## Scope

The compiler-side rule that decides which local references carry a
reference count and which do not, and where the ones that do not pay for
their safety. It owns the ownership lattice over IR locals, the list of
points at which a borrow's proofs stop covering it, the promotion that
pays at such a point, and the composition with the three other members of
the ownership family — the birth count and unique ownership
([rc-walk.md](rc-walk.md), "[The birth count](rc-walk.md#the-birth-count-a-known-in-degree-is-written-at-allocation)"
and "[Unique ownership](rc-walk.md#unique-ownership-one-owning-slot-and-no-count)")
and the purity ladder ([pure-destructors.md](pure-destructors.md)). The
collector is not a party to it: nothing in this document changes
`rc-walk`'s protocol, the header layout, or what the mutator does at a
checkpoint.

> **The proof side below is in force; the design of record is
> [walk/](walk/README.md)** (2026-08-22). Its open questions are carried
> into [walk/questions.md](walk/questions.md), section G.
>
> [gc-horizon-v2/](gc-horizon-v2/README.md) proposed replacing the payment
> at a horizon with a publication the collector reads, and was **refused**
> on 2026-08-22 — the walk cannot judge an uncounted heap edge, and the
> count also supplies prompt destruction, the copy-on-write uniqueness test
> and the arena's escape hold-count (`dev/DECISIONS.md`). That folder is a
> record; nothing here defers to it.
>
> **Status: design sketch, closed pending Phase D.** Nothing is
> implemented and no pre-Phase-D step can open it: the corpus scan below
> can only kill, the publish census that could open it is undated and
> gated outside this design, and both verification instruments need a
> compiler that does not exist. Pre-D work is instrument preparation.
>
> **Author of the algorithm:** Edmond, 2026-08-18. Revision 5 by four
> Critic rounds the same day; all four records are at the end. Revision
> 6, 2026-08-21, records the Form C selective-counting candidate and its
> prior art without adopting it. Named
> `proof-horizon` while it lived in the code repository's design notes;
> renamed 2026-08-20 with the move here, the old name kept verbatim in
> dated `dev/DECISIONS.md` entries and in `model/docs/history/`.
>
> Successor to the stack-exit epoch model
> (`model/docs/history/stack-exit-epoch-gc-2026-08-18.md`, superseded the
> day it was recorded), shaped by that model's five-axis review
> (`model/dev/STACK_EXIT_EPOCH_GC_REVIEW.md`) and by the two standing
> refusals in `model/dev/DECISIONS.md`, 2026-08-17 and 2026-08-18.
>
> Open choices — the corpus names, the family-wide borrow-analysis
> ruling, the summary language — are revised in `model/dev/DECISIONS.md`,
> which is where the design process lives; this document follows those
> entries rather than leading them.

## The algorithm in two sentences

A local is either **owned** — a counted holder paying today's
retain/release pair — or an **anchored borrow**, paying nothing while
the compiler's proofs hold: `live(anchor) ∧ stable_path`, with every
anchor chain ending in a counted root. A borrow pays only at a **GC
horizon** — a point its proofs stop covering — and the payment is
promotion to owned by an ordinary retain, emitted once per lifetime at a
point that dominates every horizon in its live range.

The cost model is the idea: protection is priced per point of doubt,
not per read, per copy or per store. Lean-style call summaries push
the horizon outward; a borrow no summary covers is promoted at its
first horizon, once, and a borrow whose lifetime reaches no horizon
pays nothing at all.

**The sound configuration's free region, named honestly.** Before
any analysis lands, the conservative defaults compose to: a borrow
survives only a lifetime containing no object store, no release of a
non-pure-closure class, no owned death and no unsummarized call —
read-only lifetimes over destructor-free data, roughly one statement
in idiomatic untyped code. Every widening is bought by a named
instrument: summaries widen calls, the may-alias lifter below widens
stores, purity classification widens releases, and the "free region
grows call-deep" sentence in the literature section holds only
through callees that are transitively store-free with pure-closure
internal releases. The corpus scan measures the bought region, not
the dream.

## The ownership lattice

Every IR local is in one of two states, assigned by the compiler
over SSA-form borrows — the phi is the disagreement detector the
failure default reads.

**Owned** — a counted reference, today's code exactly: acquisition
retains (or absorbs the creation reference of `new`), release per
the drop-point policy
([static-lifetimes.md](../memory/static-lifetimes.md#drop-point-policy)),
eager death at zero, `__destruct` at the release that reaches it. Owned
by construction:

- the result of `new`;
- **every call result** — the callee retains the returned reference
  before its epilogue, and that retain precedes the batched
  scope-exit release run and the epilogue checkpoint, so the value
  cannot die under it. A borrowed return would surface behind the
  epilogue checkpoint, outside any caller-side promotion, so
  borrowed returns do not exist until the summary language learns
  callee-side promotion (open question 1);
- **the receiver and every by-value parameter** — the callee frame
  holds a counted reference for each, today's calling convention,
  because an anchored parameter's chain would end in the caller's
  frame, and per-function horizon detection cannot see a re-entrant
  store that kills the caller's slot mid-call. Cheapening this via
  caller-guarantee summaries is open question 6;
- every reference to a COW-eligible value — array, string, reference
  box — because their uniqueness test reads the count and an
  uncounted holder falsifies it
  ([values.md](../values.md#refcount-is-always-maintained-on-cow-entities)).
  This base case outranks the unique-ownership proof, ruled 2026-08-22:
  that proof establishes lifetime, and lifetime is not what the
  separation test asks. An entity leaves the case only by a proof that
  clears the COW flag itself
  ([dev/DECISIONS.md](../../dev/DECISIONS.md));
- **the value a weak-cell read produces** — a cell references its
  target with no count
  ([weak-references.md](../weak-references.md#the-weak-cell-is-the-canonical-weakreference-itself)),
  so a chain anchored through one is anchored on nothing. Counted
  always, elided never, by Edmond's ruling 11 of 2026-08-22; this is
  what the calling convention already does for a call result, and the
  ruling makes it a rule rather than an accident of lowering
  ([walk/questions.md](walk/questions.md#g1-the-weak-cell-is-an-uncounted-edge--closed));
- **every borrow whose target's class is not transitively
  destructor-free**: eliding such a borrow's count lets a severing
  store between the borrow's last use and the scope's end reach
  zero early, moving `__destruct` off the drop-point policy's
  scope-end pin — a Zend-observable timing change. Owned from birth
  keeps the pin. "Transitively destructor-free" is computed by the
  same closed-world closure purity uses
  ([pure-destructors.md](pure-destructors.md#purity-is-transitive)): an
  open hierarchy under the static class, or an unresolvable field,
  defaults to not destructor-free and the borrow to owned — a
  destructor-free base with a destructor-bearing subclass must not
  pass. The corpus scan prices the exclusion by its own channel;
- **every borrow whose path crosses a unique-ownership entity**: the
  chain invariant's premise is that every path edge is a counted
  heap edge, and a unique entity's owning slot pays no count — the
  composition happens to stay sound (the entity is never condemned
  and its overwrite is a may-alias severing store), but the
  invariant as stated fails, so the case compiles owned;
- every local the analysis fails on, and every borrow whose birth
  does not dominate every horizon and every exit of its live range —
  the direct, checkable form of the failure default; a borrow born
  inside a loop with a horizon reachable over the back-edge fails it
  and is owned. Analysis failure selects owned, never guesses
  anchored.

**Anchored** — an uncounted borrow, `$b = $a->property` as a plain
load. The chain invariant: the anchor is a counted root — an owned
local, and equally any root category rc-walk names: an arena slot, a
static, an immortal, an FFI handle
([rc-walk.md](rc-walk.md#the-central-identity-roots-are-derived-not-enumerated))
— or a borrow whose own chain ends in one. **Every point of a live
borrow is a use of its transitive anchor for every last-use consumer**
— the drop-point policy's release sites and the move rule's transfer
sites alike: both are computed over the borrow's live range, not the
anchor's own last syntactic use, otherwise either one frees or moves
the anchor under the borrow it covers.

The invariant **extends** rc-walk's legality rule for uncounted
borrows rather than restating it. The rule
([rc-walk.md](rc-walk.md#what-this-design-does-not-solve), "Uncounted
borrows";
[static-lifetimes.md](../memory/static-lifetimes.md#what-may-own-a-borrow))
requires the covering counted reference to be a root and says a heap
field never qualifies; a chained borrow's immediate cover *is* a heap
field. The extension's own soundness argument: every edge of the
anchor path is a counted heap edge, so at any drain a condemned
component intersecting the path has an external counted in-edge
traceable to the root, the exact test acquits it whole
([rc-walk.md](rc-walk.md#phase-4--verify-and-release-mutator-thread-by-message)),
and the walk reaches the target through the live chain — an
incoherent-array skip on the path only inflates `RC − IN` toward
roothood, conservative in the safe direction (`model/src/walk.rs`, the
incoherent-head give-up through `StorageHead::coherent`). Both
sections above carry the extension and the borrow-is-use amendment
since 2026-08-20; DC5's mitigation sentence
([rc-walk-danger-cases.md](rc-walk-danger-cases.md)) follows them.

Anchor identity survives representation changes: the anchor is the
owned local itself, not the entity it referenced at borrow time, and
`stable_path` means counted reachability from the anchor's current
referent — a COW separation re-seating the anchor's array, or a
`sort()` that keeps every element counted, does not invalidate the
borrow ([arrays.md](../arrays.md#transition-rules): a transition
replaces the storage under the same entity, leaving identity, refcount
and COW state alone) — while any mutation through the anchor local is a
horizon, and so is **any store to a local on the anchor chain**:
assignment and `unset` of the anchor end `live(anchor)` regardless of
the released class's purity, the anchor local being a path base for
stores *to* it and not only through it. Without this, `$a = null`
on a pure-class anchor is a release the purity gate exempts, and
the borrow dangles at a site no other horizon kind names.

## Inside the horizon: what the borrow must prove

The borrow's three obligations are the anchor outliving it, the
anchor-to-target path staying intact, and every operation able to
invalidate either being visible in the IR. The same IR analysis is
meant to serve unique ownership's borrow clause
([rc-walk.md](rc-walk.md#unique-ownership-one-owning-slot-and-no-count))
with a different invalidation discipline — one analysis with two
invalidation disciplines, whose family-wide ruling is still owed (open
question 5).

Path visibility is bounded by aliasing, and the rule is conservative:
**a store through any may-alias of a path base is a severing store.**
The must-not-alias instrument that lifts it is named, because
without one the rule makes most object stores horizons: closed-class
typed properties give type-incompatibility disjointness — the same
closed types the hybrid already targets — and nothing else is
assumed. The corpus scan carries a severing-store channel so the
free fraction is measured under the sound rule. COW values are the
self-repairing case — a foreign alias copies before writing
([values.md](../values.md#copy-on-write-protocol)) — so typed-array
paths are the cheap population.

## The horizon list

A GC horizon is any of:

- a call for which the compiler lacks sufficient trusted, fresh effects
  from any admitted source;
- dynamic dispatch whose possible-target set or joined effects the
  compiler cannot bound;
- reflection;
- a by-reference escape;
- **a release of a class whose transitive-purity closure is not
  pure** — any store displacement, `unset`, `null` assignment or
  scope exit, with NR counting as impure, because NR admits external
  writes that sever live paths. Eager death runs `__destruct` at the
  release site, no drain involved, so the destructor hazard is a
  property of releases. The predicate is deliberately the one purity
  computes — one boolean per class over the field-type closure
  ([pure-destructors.md](pure-destructors.md#purity-is-transitive)) —
  and deliberately over-approximate; a finer store-effect analysis of
  destructor bodies is a separately owed instrument if the coarse
  rule proves too expensive. No finality conjunct: "may reach zero"
  is never dischargeable without count-value analysis nobody plans,
  so every such release is a horizon. The lemma that keeps the rule
  from swallowing pure cascades: an object that reaches zero is off
  every live anchor chain, so the own-slot stores of a dying pure
  cascade never sever a live path. The lemma holds because every
  cascade entry point is itself some horizon: a summarized callee's
  internal release cannot zero a path member (each keeps a counted
  in-edge from its path predecessor, the root live by
  borrow-is-use), scope-exit batches fail the same way, checkpoint
  drains are acquitted by the chain invariant, and the one formerly
  unguarded door — explicit displacement of a pure-class anchor —
  is closed by the store-to-anchor rule above;
- a checkpoint that fails the condition below;
- an own-code store that severs a borrowed path, under the may-alias
  rule above.

A checkpoint threatens a borrow in two distinct ways, and only the
second survives as a condition.

**Reclamation.** The drain severs and frees condemned components
whether or not destructors exist — the P0 raw-sever arm of
[pure-destructors.md](pure-destructors.md) runs no user code. The chain
invariant answers this unconditionally: the exact test balances
counted references and the chain ends in a counted root, so no
component on the anchor path is condemnable. Discharged by
construction, at every checkpoint, including the hand-off drain's
collector-side sever between checkpoints, and including the
drain-exclusivity window the collector holds
([drain-window.md](drain-window.md)).

**Path severing by drain destructors.** A `__destruct` the drain
runs can store into the anchor path. The condition binds **any
checkpoint that can drain a verdict** — under the hand-off design
that is two arms: the prologue visit, which runs P2 calls, and the
unchanged whole drain that an NR-or-impure component takes at
whatever death or poll picks the verdict up; if the purity ladder's
open questions move user-code duties into the sliced tail, every
checkpoint carrying a slice inherits the condition. The discharge is
reverse reachability whose root set is the **downward closure of
the condemned set** — the sever releases external children
"destructors and all", so the cascade's classes are in scope, and
that closure is exactly what transitive purity computes: a condemned
set whose closure is pure certifies the checkpoint. Until the
analysis exists, a checkpoint not proven safe is a horizon.

## At the horizon: promotion

The payment is promotion: one ordinary retain, after which the
borrow is an owned local, released per the same drop-point policy as
any other — so promotion changes no lifetime against today's owned
lowering of the same borrow. Placement rules:

- The promotion point is the **latest point dominated by the borrow's
  birth that dominates every horizon, every exit and every raise site
  of the borrow's live range**. A phi is an overwrite: the value it
  replaces is released there, so a promotion at a loop-header phi pairs
  one retain per value produced with one release per value killed, and
  no execution-count clause is owed. The birth always qualifies, so the
  rule is total, and promotion at the birth is today's lowering for
  that borrow. Those points form a dominator chain, so the latest is
  unique. The word was "closest" until 2026-08-22, and it reads as the
  latest: read as the earliest it names the birth always, and the
  mechanism would buy nothing over marking the borrow owned. **The
  raise sites are in the quantifier**, which is the first of the two
  readings open question 9 offered, and which PH9 and three case files
  assert
  ([gc-horizon-cases/adversarial.md](gc-horizon-cases/adversarial.md));
  the cost is that a promotion is not hoisted past an allocating store.
  Every set the rule quantifies over — horizons, exits, raise sites —
  and the liveness behind them are computed over the control-flow graph
  **including its exceptional edges**: a use inside a `catch` is a use,
  and deleting those edges would put the drop point of a value the
  handler reads before the raise site.
- Promotion cannot precede the birth: the retain's operand exists
  only after the load. This is also the static argument that death
  order is preserved — a promoted borrow holds its count over a
  subrange of exactly the lifetime today's owned borrow holds it.
- A loop containing a horizon promotes before the loop when the
  borrow is born before it; born inside, the back-edge fails the
  dominance test and the borrow is owned.
- On unwind, what a landing pad releases depends on whether the frame
  survives it, and that turns on where phase 1 selected the handler
  ([exceptions.md](../../runtime/exceptions.md#channel-u-how-the-tables-work)).
  Selected in an outer frame, this frame dies and its pad releases the
  owned set live at the raise site. Selected in this frame — a `catch`
  here, or a `finally` that returns — the frame runs on, and the pad
  releases only those owned values that are dead where control resumes:
  a value the handler reads cannot be released before it runs.
- **A pad release is a release.** The horizon list names a release of a
  class whose purity closure is impure, because eager death runs
  `__destruct` at it, and a pad's releases are not exempt: a destructor
  run there can store into a live anchor path exactly as one run on the
  normal path can. With the raise sites in the placement quantifier the
  promotion dominates the pad, so the hazard is paid rather than
  unnamed.
- **Pad state is per edge, not per site.** A `finally` is one pad
  reached from several raise sites, and a value born on one branch and
  not another is owned on one incoming edge and not on the other; the
  pad carries the state per exceptional edge and per SSA generation, by
  split pads or an ownership phi, which is what PH22 asserts
  ([gc-horizon-cases/adversarial.md](gc-horizon-cases/adversarial.md)).
  PH22's third option, a tag, is a runtime flag written on the normal
  path, which the granularity ruling of 2026-08-18 excludes. The kinds
  of raise site this repository supports are listed in
  [gc-horizon-cases/unwind.md](gc-horizon-cases/unwind.md), which also
  records that the set is not enumerable while runtime entries are
  unclassified.
- **A borrow of a unique-ownership entity cannot be promoted**: the
  count word holds the occupancy sentinel and a retain written into
  it protects nothing. And the convention retains are the same
  hazard: the all-returns-transfer retain and the parameter pair
  are counted references, so **the uniqueness prover counts every
  convention retain site — return transfer, receiver, by-value
  parameter — as a second counted reference**, and an entity that
  is ever returned or passed is by proof never unique; otherwise
  `getE() { return $this->e; }` writes the sentinel in the owner's
  own unit with no horizon in sight. A horizon-reaching borrow
  demotes the uniqueness proof — and demotion is a **whole-program
  fixpoint**, not a local lowering: the owner's unit compiled the
  plain-store overwrite and the sentinel factory, so a
  later-compiled borrower forces the owner's recompile, an upstream
  blast radius the economics prices; the fixpoint's trigger set is
  the convention sites plus the horizon-reaching borrows. The
  conservative default until the fixpoint exists: uniqueness is
  lawful only for entities whose every access site compiles in the
  same session. Recorded also in
  `model/dev/design/owned-slots-and-the-walk.md`, with the corollary
  that demotion revives the COW check for the entity's writers.
- **Promotion is payment only where a retain is honoured.** In the
  immortal and request-arena categories retain and release return
  early ([arenas.md](../memory/arenas.md#object-categories-by-memory-strategy)),
  so the retain buys nothing and the borrow's protection has to come
  from the referent's own lifetime instead. Open question 8.

The rule bounds the scheme's cost: a promoted borrow pays one pair
over a subrange of the lifetime today's code pays it over, so per
borrow the scheme never costs more than the current code, and the
whole difference is the borrows that are never promoted. Overpayment
— a promotion point on a path that reaches no horizon — loses
savings, never adds cost.

The collector is untouched: promotion is a compiler-emitted retain,
with no protection set, no candidate-test arm and no death-branch
test.

## The hybrid: counted class, horizon class

Whether locals referencing a class's instances enter the lattice at
all is a class property in policy and a per-site decision in
mechanism. In form A the two regimes differ only in where the
compiler emits pairs, so the class bit is the default the emitter
follows, and every anchored site still owes its site-local proof.

- **A counted class**: locals are owned, today's code, no proofs and
  no horizon bookkeeping by default; the always-provable rules below
  may still take a pair at any site.
- **A horizon class**: locals enter the lattice — anchored where the
  proofs hold, promoted at horizons.

A slot whose static class the compiler cannot narrow (`mixed`, an
open hierarchy) is counted, and analysis failure selects counted:
both defaults land on today's behaviour. A subclass may differ in
regime from its parent; a parent-typed site follows the parent's
bit over any instance, which in form A is a cost decision only,
since instances of both regimes are runtime-identical. The selection
heuristic is economic: horizon classes are the closed,
summary-friendly types in provable scopes; counted classes are the
ones crossing reflection, callbacks and suspensions, where analysis
costs more than the pairs it removes.

Granularity — **ruled by Edmond, 2026-08-18** (`model/dev/DECISIONS.md`,
"proof-horizon granularity", bounded after round 4). The class bit
stays the emitter's default; on top of it, a closed set of
**always-provable elision rules** applies at any site in either
regime. Round 4 bounded what qualifies, and the bound follows from
Edmond's own criterion rather than weakening it: a rule is in the
set only when it is decidable from IR shape alone — the enclosed
region contains no call, no store, no release and no checkpoint —
because a "horizon-free" proof that consults the may-alias oracle
is exactly the fallible class the ruling bars; and the lattice's
owned base cases are preconditions, not competitors — the elided
pair's target is non-COW-eligible, transitively destructor-free and
non-unique, since horizon-freedom was never the predicate that
protects COW, timing or the sentinel. What Swift's precedent
licenses here is the mechanism — semantics-licensed, unconditional
elision — and not the contract: Swift bought its elisions by
guaranteeing lifetimes only to last use, while this design keeps
the Zend-observable destructor timing pinned, so every rule in the
set must preserve it. Each admitted rule gets its own
`model/dev/DECISIONS.md` entry — statement, proof sketch, reviewer,
date — and its elisions enter the shadow lowering's journal like any
lattice elision, so no elision class is uninstrumented. A counted
class's local may lose its pair under such a rule. Summary-driven
or heuristic per-site deviation stays barred until two instruments
exist together, neither sufficient alone: a **per-site certificate** —
anchor chain, summary IDs, horizon set per entry — whose independent
checker soundly warrants the checkable surface (chain well-formedness,
syntactic-horizon coverage, summary-version freshness) and cannot
warrant may-alias completeness, which any checker would inherit from
the shared oracle; and the shadow-count lowering, whose dynamic
cross-check is the only detector for what the certificate cannot
see. The ruling's standing constraint: no rule of either kind
introduces a write barrier or any other mutator work beyond the
program's own code.

## The two forms

**Form A — over maintained heap RC. This is the design.** Heap
counts, owned-local counts, eager death, `__destruct` timing, COW,
the arena's counted promotion and rc-walk's protocol are today's.
The elision applies to anchored borrows only.

**Form B — without heap RC** is the superseded model's road, not
pursued: the architecture inventory dies with the count and
deterministic destruction needs the count back (the five-axis
review), and the walk's write barrier *is* the count (the 2026-08-18
stack-bit refusal, `model/dev/DECISIONS.md`).

**Form C — selective collector-computed counts** is a candidate
extension, not this design and not Form B. It retains exact mutator-
maintained RC for entities that need prompt death, and gives a proven
subset a deferred regime in which the collector enumerates internal
edges. The candidate, its prior art and the gates that keep it from
silently breaking Form A are specified below.

## Candidate inversion: selective collector-computed counts

This section is **an integration proposal, not an adopted lowering**.
It reopens the 2026-08-18 no-heap-RC refusal only for a partition of the
heap while preserving Form A as the fallback. No implementation may
select Form C until its root-bit contract, cross-regime edge rules and
collector validation have independent proofs and differential tests.

### The prior art found

This design space has a name. Blackburn and McKinley's **Ulterior
Reference Counting** (URC, OOPSLA 2003) generalises deferred RC from
stacks and registers to selected heap objects and fields. It partitions
the heap into RC and non-RC populations, permits logical per-object tags
or physical spaces, defines an *integrate event* that moves a deferred
pointer into RC, discusses the reverse transition for highly mutated
objects, and offers three ways to recover deferred edges: trace them,
remember mutated fields, or remember mutated objects. The last costs one
bit per remembered object and coalesces repeated mutations
([paper](https://www.steveblackburn.org/pubs/papers/urc-oopsla-2003.pdf)).

Its concrete BG-RC collector used a copying non-RC nursery and an RC
mature space. On its 2003 Jikes RVM/SPEC JVM experiment it matched the
throughput of the generational mark-sweep comparator (reported 2% better
on average in moderate heaps), reduced maximum pauses by a factor of four
on average, and reduced the modified-object load of RC by about fiftyfold.
Those are historical results on a 2 GHz Xeon and are evidence that the
partition is viable, not performance evidence for Limelight.

The line continued rather than ending with URC:

- **Age-Oriented Collection** applies tracing to young objects and RC to
  old objects in an on-the-fly collector
  ([paper](https://www.steveblackburn.org/pubs/papers/aogc-cc-2005.pdf)).
- **Down for the Count?** (ISMM 2012) uses small sticky counts, backup
  tracing and an implicitly-dead treatment of new objects; its combined
  optimisations removed a measured 30% gap between the prior RC baseline
  and mark-sweep in that study
  ([paper](https://openresearch-repository.anu.edu.au/server/api/core/bitstreams/1135b993-0283-49c4-bfe2-ac77e996624d/content)).
- **RC Immix** (OOPSLA 2013) leaves new objects uncounted until their
  first collection discovers an incoming reference, uses three-bit
  sticky object counts plus per-line live counts, and repairs stuck
  counts and cycles with backup tracing. It reported a 12% average
  improvement over its preceding RC implementation and overflow in
  0.65% of objects with three count bits
  ([paper](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/rcix-oopsla-2013.pdf)).
- **LXR** (PLDI 2022) combines coalescing RC for young and old objects,
  implicitly-dead new objects, concurrent decrements, Immix regions and
  occasional concurrent SATB tracing for cycles and stuck counts. Its
  unified field-logging barrier measured 1.6% mutator overhead. Its
  arXiv extended version reports, for the Lucene search engine in a
  tight heap, 7.8 times the throughput and 10 times better 99.99%
  tail latency than Shenandoah, and across 17 workloads in a moderate
  heap 4% over G1 and 43% over Shenandoah on throughput — figures
  specific to those configurations
  ([extended version](https://arxiv.org/pdf/2210.17175)). An earlier
  revision of this section cited six times the throughput and thirty
  times lower 99.9-percentile latency; those numbers are not in the
  extended version and the camera-ready has not been read here. As of the current
  [MMTk status](https://www.mmtk.io/status), LXR exists in MMTk/OpenJDK
  forks and is not merged into MMTk master.

The unifying result is literal: tracing and RC are dual graph
computations, and practical deferred and generational collectors occupy
points between them rather than two disjoint families
([A Unified Theory of Garbage Collection](https://research.ibm.com/publications/a-unified-theory-of-garbage-collection)).
What is not supplied by this prior art is Limelight's proposed
combination: no stack scan, a compiler-maintained local-root bit,
anchor-chain proofs, and horizon placement choosing how protection is
materialised.

### What MMTk supplies, and what it does not

MMTk is a toolkit of collector plans and VM-binding interfaces, not an
automatic URC switch. Its current status page lists LXR as an RC/tracing
plan available in separate `mmtk-core` and OpenJDK forks and explicitly
not merged into MMTk master
([MMTk status](https://www.mmtk.io/status)). Adopting stock MMTk therefore
does not by itself select URC, RC Immix or LXR; using LXR means taking its
plan fork, its matching VM binding and the runtime changes that binding
requires.

MMTk's ordinary liveness contract starts a collection from roots supplied
by the VM binding through `Scanning` and `RootsWorkFactory`, then follows
object edges
([root-scanning API](https://docs.mmtk.io/api/mmtk/vm/scanning/index.html)).
A tag in a local slot may help the binding recognise the slot, but the
binding must still enumerate it. MMTk's `pin_object` is unrelated to this
obligation: pinning promises that an object will not move; it does not make
an otherwise unreachable object live
([pinning API](https://docs.mmtk.io/api/mmtk/memory_manager/fn.pin_object.html)).

The no-stack-scan integration is consequently a new binding contract:
compiler operations publish and withdraw canonical root tokens in a
registry outside the stack, and the binding reports that registry as the
root source. If `LOCAL_ROOT` lives only in object metadata, a custom plan
must enumerate the set bits; stock MMTk plans do not search the heap for a
language-defined root bit. A dense side bitmap would make such a search
possible but would turn root discovery into heap-metadata scanning. A
published-root registry preserves work proportional to root transitions
and live root tokens, which is the candidate this section selects for the
first prototype.

### Selected experimental substrate: LXR, not a new collector from zero

The working implementation choice for Form C is to reuse the LXR fork as
the collector substrate and put Limelight's object semantics above it.
This is a choice of mechanisms, not adoption of LXR's Java semantics or a
claim that stock MMTk already implements Form C.

The reusable LXR mechanisms are:

- the Immix block-and-line heap, bump allocation and line/block
  reclamation;
- implicitly-dead new objects whose counts are materialised only when an
  incoming edge is discovered;
- field logging and coalesced RC, so a chain of writes pays for its
  initial and final targets rather than every intermediate value;
- short RC epochs, remembered sets and lazy concurrent decrement
  processing;
- occasional concurrent SATB tracing for cycles and stuck counts;
- bounded opportunistic copying for fragmented blocks; and
- survival-rate and work-budget triggers for collection scheduling.

Limelight remains responsible for everything whose meaning is language-
specific:

- selecting `ImmediateCounted` or `DeferredCounted` from class, entity
  and escape proofs;
- preserving immediate `1 -> 0` death and destructor order for the
  Immediate regime;
- keeping COW uniqueness, weak-reference ordering and FFI ownership out
  of the Deferred regime until separately proved;
- publishing canonical local-root tokens instead of requiring a stack
  scan;
- proving anchor chains and placing retain or root-token promotion at GC
  horizons; and
- performing one-way integration before an actor send, unknown escape or
  any other operation that invalidates Deferred eligibility.

The ownership boundary is strict: LXR may schedule and reclaim the
Deferred space, but it does not decide the semantic regime of an entity.
An Immediate entity is never placed behind delayed LXR decrements. On any
classification disagreement, Limelight selects Immediate and today's
retain/release semantics.

The first implementation retains LXR's original root scan as a debug
oracle while also constructing Limelight's published-root registry. The
two root sets and their transitive closures must agree over the Deferred
space. Stack scanning may be removed only after that differential oracle
is clean; it is not removed merely because `LOCAL_ROOT` lowering exists.

### Two entity regimes, and two decisions rather than one

Form C adds an entity regime distinct from the existing *class regime*.
The class regime chooses whether the compiler attempts borrow elision;
the entity regime chooses who maintains the entity's liveness account.

- **ImmediateCounted** — today's exact header RC. Stores and owned locals
  maintain it, `1 -> 0` performs eager death, and `rc-walk` reads it.
- **DeferredCounted** — no exact mutator-maintained count for internal
  Deferred-to-Deferred edges. The collector enumerates those edges and
  traces from explicit boundary roots. Reclamation is delayed until a
  collection and therefore cannot carry prompt-death semantics.

URC's important separation is retained: a **deferral policy belongs to a
pointer slot**, deciding whether a mutation emits count work, while a
**collection policy belongs to an entity**, deciding which algorithm may
reclaim it. A single `target.is_deferred` test is not a complete policy.

The conservative first eligibility rule is deliberately narrow:

```
DeferredCounted requires:
    GC-heap category
    non-COW entity
    transitively destructor-free class
    no weak-reference timing obligation
    no FFI-owned resource
    no unique-ownership sentinel
    compiler-known layout for edge enumeration

anything unresolved -> ImmediateCounted
```

COW needs an exact current uniqueness answer; destructor-bearing and FFI
entities need prompt death; weak references expose clearing order; arena
and immortal categories already have their own lifetime; and the unique
sentinel has no count to reconstruct. These exclusions keep the first
candidate semantically below Form A rather than asking the collector to
emulate all of its observable timing.

### The edge matrix

Every reference store is classified by the source slot and target regime.
This matrix is the minimum complete contract:

| Source slot -> target | Required accounting |
|---|---|
| immediate -> ImmediateCounted | today's retain/release |
| deferred -> ImmediateCounted | today's retain/release; an immediate target must never undercount |
| deferred -> DeferredCounted | no hot-path RC; collector enumerates the final edge |
| immediate -> DeferredCounted | an explicit boundary hold or remembered boundary edge |

The last row is the dangerous one. An ImmediateCounted source may die and
remove its outgoing edge between two collector reads. Form C must choose
one of two instruments before it is sound: a precise **boundary count**
maintained only for entries into Deferred space, or a write barrier and
snapshot protocol that remembers the edge. The first preserves the
current no-general-write-barrier goal and makes a Deferred header count
external holds only; the second is URC/LXR's route and contradicts the
standing Form-A constraint. The first implementation should therefore use
boundary counts and measure their traffic before considering a barrier.

With a boundary count `EXT`, collector-enumerated internal in-degree `IN`
and the local-root state below, the collector may reconstruct a diagnostic
snapshot count:

```
snapshot_RC(o) = EXT(o) + IN(o) + LOCAL(o)
```

That number alone does not collect cycles: an unreachable cycle has a
positive `IN`. Reclamation must trace the Deferred graph from `EXT > 0`,
local roots and other admitted root categories, or equivalently compute
components and their external in-edges. Calling this collector-computed RC
does not remove the reachability step.

### The local-root bit, without a stack scan

`LOCAL_ROOT` means **one compiler-owned logical root token exists**, not
"one or more machine locals happen to contain this address". A boolean
cannot count two independent locals:

```php
$a = new A();
$b = $a;
unset($a);       // must not clear A.LOCAL_ROOT while $b is live
```

The compiler must therefore coalesce local aliases under one canonical
root owner; every other local is a borrow from that token. A move transfers
the token, and only destruction of the last statically proved owner clears
the bit. A copy that cannot remain a borrow, re-entrancy that loses the
owner proof, an escaping closure, cross-thread sharing, suspension, or
analysis failure demotes the entity to ImmediateCounted unless a wider
root representation exists. A plain sticky bit that mutators only set is
not enough: without a stack scan or a reassertion handshake the collector
has no sound operation that clears it.

The first candidate is thus single-token and fail-closed:

```
NoRoot --acquire canonical owner--> LocalRoot
LocalRoot --move owner-----------> LocalRoot
LocalRoot --last owner dies------> NoRoot
LocalRoot --unprovable alias-----> integrate ImmediateCounted
```

Whether the bit is per entity, per actor, or encoded in the count word is
an ABI question. A global per-entity bit needs atomic ownership transfer
under cross-thread access; the simpler first rule confines
DeferredCounted entities to one actor and integrates them before a send.

### Horizon lowering under Form C

The proof side of GC Horizon stays useful. What changes is the payment at
the horizon:

```
ImmediateCounted target:
    Anchored --retain-----------> Owned

DeferredCounted target:
    Anchored --acquire root-----> LocallyRooted
```

Before the horizon, an intact path from an existing local-root token or
boundary root covers the borrow. At the horizon, the compiler materialises
the least protection the target regime understands. `retain` remains the
operation for ImmediateCounted; `LOCAL_ROOT` acquisition or transfer is
the operation for DeferredCounted. The same dominance placement applies,
but its cost and release action are regime-specific.

This creates a three-state compiler lattice for Form C:

```
Anchored(chain)
    -> OwnedCounted       by retain
    -> LocallyRooted      by root-token acquisition
```

`LocallyRooted` ends by clearing or transferring the token, never by
`release`. A mode test on every promotion would recreate the load-path
problem of the superseded design, so the target regime must be known from
IR type/region facts or the site must use the ImmediateCounted fallback.

### Collector and transition protocol

Form C cannot reuse `rc-walk` unchanged. Its central `RC - IN` identity
assumes every external root is counted, and its occupancy test treats
header count zero as a free slot. Deferred entities require an explicit
occupancy state and a separate exact-test arm rooted by `EXT` and
`LOCAL_ROOT`.

Mode transitions occur only at a collector-owned integration boundary:

- **Deferred -> Immediate:** enumerate every incoming deferred edge while
  the view is stable, initialise the exact RC, flip the mode, then make
  all future slot mutations immediate. This is URC's integrate event.
- **Immediate -> Deferred:** first close or reconcile outstanding count
  updates, split external from internal inputs, install the boundary/root
  state, and only then permit deferred slots. No ordinary mutator store
  performs this transition.

The initial implementation must not attempt both directions. Allocation
into a statically eligible Deferred space followed by one-way integration
to ImmediateCounted on escape is enough to test the premise. Adaptive
reintegration of hot mature objects belongs after the static form is
measured.

### Build order and acceptance gates

1. **Reproduce LXR before specialising it.** Build the matching LXR
   `mmtk-core` and OpenJDK forks, preserve their benchmark baseline, and
   identify the Java-specific pieces that the Limelight binding must
   replace. A version-pinned upstream baseline is required before any
   performance claim.
2. **Shadow census, no changed reclamation.** During an existing walk,
   compute `EXT`, `IN`, root-token candidates, eligible classes,
   cross-regime edges and the reconstructed counts while real RC remains
   authoritative. Any disagreement only logs.
3. **Static Deferred allocation.** Restrict it to destructor-free,
   non-COW, actor-local classes with compiler-known layouts. Keep a debug
   real count and compare it against collector reconstruction.
4. **Dual root discovery.** Keep LXR/MMTk stack scanning as the oracle and
   report the compiler-published root registry in parallel. Compare root
   sets, Deferred transitive closures and death sets before allowing the
   registry to become authoritative.
5. **Root-token lowering.** Add canonical-owner inference and horizon
   promotion to `LocallyRooted`; reject every phi, escape or re-entrant
   shape the proof cannot coalesce.
6. **One-way integration.** On a disqualifying escape or actor send,
   integrate at a checkpoint with a stable edge view, then remain
   ImmediateCounted for life.
7. **Remove the stack oracle only after equivalence.** The release build
   may stop scanning stacks only when the published-root protocol has an
   independent checker and the dual-root corpus has no divergence.
8. **Only after the above:** evaluate reverse transition, per-object
   adaptation, count-bit compression and changes to LXR's coalescing
   barrier.

The Phase D census gains these channels: eligible allocation share;
stores by edge-matrix row; boundary-count traffic; local-root acquisitions,
transfers and clears; integrations and their scanned-edge cost; bytes
retained until Deferred collection; prompt deaths preserved by the
Immediate regime; cycle/reconstruction work; and the fraction forced back
to Immediate by COW, destructors, weak references, FFI, sharing or analysis
failure. Form C opens only on its marginal result against Form A; the
historical URC, RC Immix and LXR numbers are priors, never acceptance data.

## What the superseded model's problems become

The history file's supersession banner records three: a critical
untouch/retirement race, a load path that dominates the RC pair it
replaces, and the loss of deterministic destruction.

- The untouch race is gone: promotion is a plain retain that
  precedes the horizon, so nothing is retracted and nothing races
  the collector.
- The load path is gone: an anchored borrow costs zero instructions
  between horizons, with no per-load guard.
- Deterministic destruction is preserved by the lattice, and only by
  it: owned locals keep the count that drives eager death, and
  destructor-bearing targets never lose a holder to elision.

## Named against the literature

Deutsch–Bobrow defer stack counts and keep a zero-count table whose
reconciliation scan is the *freeing* mechanism for stack-only
objects. This design keeps freeing on the owned count instead, so
nothing replaces the table: owning locals never leave the count, and
proofs replace reconciliation for borrows only. In Perceus terms the
dup/drop pairs stay at ownership transfers and the borrow inference
is pushed across summarized calls. The delta from plain borrow
inference is the trusted-effect system: without sufficient effects from
any admitted source every call is a horizon and the scheme reduces to the
five-axis review's extraction — a covering-borrow elision over maintained
RC; with those effects the free region grows call-deep, through callees
that are transitively
store-free with pure-closure internal releases — the condition the
sound-configuration paragraph states (`model/dev/RESEARCH.md`,
2026-08-18, the static family).

## Economics

```
saved = (borrow acquisitions whose lifetime reaches no horizon) × pair cost
```

with the pair at 1.84–1.87 ns (`model/docs/performance-case.md`, "The
pair: retain and release") as a **unit** cost; the in-situ marginal
cost of a pair disperses by context, and **the band is unmeasured**
— the 10.2 ns figure an earlier revision cited is the cost of a
banned lowering shape, not of the pair in a context — so the
product's error bar is unknown until the pair-cost-over-contexts
sweep runs. That sweep is pre-D buildable in a shape the crate
already owns: the store probe's skeleton
(`memory::barrier::tests::what_a_store_costs_by_working_set` — two
working sets, hot and cold halves, a null-sweep control) pointed at
`ll_retain`/`ll_release` with an independent-work interleave axis.
The population excludes the owned base cases — `new` results, call
results, parameters, COW-eligible values, destructor-bearing targets,
unique-crossing paths — and the horizon list prices releases and
may-alias stores; every exclusion has a scan channel.

The counting instrument is an **elision-site counter in the release
lowering behind a build flag**: the compiler statically knows the
elided sites, and counting their executions perturbs less than the
debug journal. Three disciplines keep the instrument honest: the
counter is measurement work, exempted by name in the granularity
ruling's scope from the no-mutator-work constraint; the counting
build is never clocked — an increment per elided pair is a 15–30 %
perturbation of the very effect, so the wall-clock cross-check runs
on the unflagged build; and the flag's effect on the elision set is
checked, not assumed — the two builds' static elision site lists
are compared, both being compiler outputs. The shadow build's count
is a verification by-product, not the economics' number — its
lowering can flip lattice outcomes the release build would not.

Three costs sit outside the formula and are named rather than
implied away. Compile time and code size: the borrow analysis,
summary computation and per-site landing-pad sets are paid per
function at every build. The recompilation blast radius, in **both
directions**: downstream, a stdlib update that adds a destructor or
a severing store invalidates every caller compiled against the old
summary; upstream, a uniqueness demotion forces the owner-unit
recompile. The scan's blast-radius channel sizes the downstream
half. And the ack budget: an elided borrow's release was non-final
by the borrow's own obligations, so the death-branch ack rate is
unchanged; what thins is the batched scope-exit ack pair for scopes
whose whole release run is elided, and pickup sites that move when a
destructor-free death nests into a cascade — a different site and
magnitude than the fast class's death-branch thinning in
`model/dev/design/owned-slots-and-the-walk.md`, but the same
epoch-progress budget, and the compensating-poll rule (that
document's open question 3) is the shared dependency.

The baseline is marginal, not gross, and the rule is asymmetric: **a
gross number may only kill, only the marginal number may open.** The
kill and open bars carry no values yet, deliberately: they are owed
to the census specification alongside the channel list, and no
verdict is readable until both are recorded.
Unique ownership's borrow clause and the birth count elide
overlapping slices of the same traffic, so the census carries
**per-acquisition coverage flags** from each family analysis —
which concedes that the classifiers of unique ownership and the
birth count are census instrumentation, built before any verdict.
The full channel list is owed to `model/dev/DECISIONS.md` **before the
Phase D census is specified**, not on acceptance — a census built
without the flags can price this design only grossly, and a gross
number opens nothing.

Confirmation is by count, not by clock: confirmed saving is the
release-build counter's elided pairs × the unit cost, within the
dispersion band. A wall-clock A/B is a cross-check only, on a
workload whose density clears the floor's upper edge: at 1.85 ns
per pair, 3 % of a second is about 16 M pairs, and no existing
bench has that shape — the Phase D bench plan owes one.

Measurement order, and what each can decide:

1. **Corpus scan, compiler-free, graded.** Per *lifetime*: a
   lifetime is horizon-free only when every operation it spans is
   proven, so the scan walks lifetimes, not call sites. Every site
   is classified three ways — provably-horizon, provably-free,
   unresolved — and **provable horizons stay horizons in both
   bounds**: a visible severing store, a release of a provably
   impure closure. The deliverable is the doubt map — where the
   unresolved mass concentrates — through these channels: the
   free-fraction bracket over the graded classification; the
   unresolved-receiver share; the severing-store share; the
   per-release purity tier (P0-syntactic / closure-unresolved /
   provably-impure, under the ruled reading of the child-release
   order — specified, P2 keeps its call — with a P2-share
   sub-channel); the destructor-bearing-target share; the referent's
   static class where known; and the **summary-dependency channel**
   — per stdlib or vendor class, the transitive share of corpus
   functions whose call graph reaches it, reported as its own
   bracket under an under-approximate and an over-approximate
   receiver resolution, because transitivity amplifies every proxy
   error to corpus scale; **only the under-approximate number
   carries kill authority**, matching the gross-may-only-kill
   asymmetry. Two structural limits are stated rather than
   discovered later: compiler-placed checkpoints do not exist in
   source, so checkpoint horizons are absent from both bounds; and
   "provably-free" is near-empty for calls without receiver
   resolution, so the kill rule reads the **bracket**, not one
   bound — kill when the graded optimistic bound is low, or when
   the unresolved mass exceeds a share recorded with the census
   bars, at which point the scan proves nothing and the closed
   status simply persists. The corpus is deployed PHP applications
   with their vendor trees — the working choice, Edmond's veto
   open: WordPress, one Laravel application (Monica) and one
   Symfony application (Sylius) — recorded before the scan runs.
2. **The Phase D publish census** — with the channels this design
   needs: borrow-acquisition density per class, horizon crossings
   per borrow lifetime, live borrows per horizon, and the family
   coverage flags above. The census as recorded
   (`model/dev/DECISIONS.md`, 2026-08-17 and 2026-08-18) counts
   publishes, which prices birth count and unique ownership but none
   of these.

The operational status, stated without decoration: **closed, and no
pre-D step can change that status** — the scan's verdict cannot
open (kill-only), the census is undated and gated outside the code
crate, and every verification artifact needs the compiler. Pre-D
work is instrument preparation: the graded scan, the channel-list
recording, and the summary-language question, whose rulings inside
(who writes stdlib summaries, the versioning rule) are Edmond's.
`model/PLAN.md` carries the line.

## A simpler first economics

The first economic reading does not need a complete compiler cost
model.  A borrow lifetime has only a small, explicit set of events
that can end its proof:

- `unset`, displacement of its anchor, or a store that may sever its
  anchor path;
- an unsummarized call, including a call whose transitive callees are
  not proved safe;
- suspension through a coroutine, `yield` or a fibre;
- reflection, callback or by-reference escape;
- an impure-destructor release or an unsafe checkpoint.

Classify each lifetime by its first such event.  A lifetime with no
event removes one retain/release pair; for a deliberately conservative
lower bound, every lifetime with an event may be credited with zero
saving.  Recording the event class, the position of the first event
and its execution frequency is enough to refine that bound later.
This finite case table should precede a more elaborate census: it can
say whether the free population is material without waiting for full
lowering or trying to price every secondary compiler effect.

The comparison with a runtime write barrier is asymmetric.  A write
barrier charges every relevant store, including stores made while no
borrow needs protection, and puts a check, branch and metadata traffic
on the store path.  Proof horizons add no runtime write barrier; they
charge one ordinary retain/release pair only to a live borrow that
actually crosses a potentially severing store.  The primary comparison
is therefore:

```text
runtime barrier cost = relevant dynamic stores * barrier unit cost
proof-horizon cost   = live borrows crossing dangerous stores * RC pair cost
```

The barrier's unit cost is expected to be high enough that avoiding it
is a design constraint, not a marginal detail.  Measurement is still
owed for the magnitude, but the first question is the simple event
count above: how often a dangerous store coincides with a live borrow,
not how often stores occur in general.

## Verification artifacts, a precondition of implementation

Form A's virtue — the collector never learns the feature exists —
removes every runtime detection point: a misplaced horizon and a
correct elision are the same instruction stream, so a compiler bug
surfaces as corruption far from its cause. Three instruments are
owed before any lowering ships; none is buildable before Phase D
supplies the compiler, which is part of why the design is closed
until then.

- **Shadow-count lowering.** The **classic pairs drive the real
  header count** — so the walk's occupancy test, COW's uniqueness
  read, the release asserts and death itself behave exactly as the
  classic build — and the elided stream feeds a shadow word. The
  two streams run **two release schedules in one binary**: the
  shadow's decrements at the elided build's sites, borrow-is-use
  extensions included, the real count's at the classic sites — with
  one schedule for both, a sound elision fires the signal and the
  diagnostic is dead on arrival. Under the dual schedule the
  false-positive rate is provably zero: shadow(target) equals
  real(target) minus the live elided borrows, and a shadow zero
  under a live borrow means no counted holder exists in the elided
  stream, which a sound elision's intact chain forbids. The
  divergence signal is the shadow reaching zero while the real
  count is nonzero, logged with the per-object journal of
  elided-acquisition site IDs that names the sites whose retains
  are missing — always-provable-rule elisions in both regimes enter
  the same journal, so no elision class is uninstrumented. (The
  reverse wiring, elided-authoritative, breaks the debug runtime it
  instruments: a real count of zero on a live object reads as a
  free slot to the walker and as "unique" to COW.)
- **Differential lowering.** The same program built with horizons
  off and on. The oracle is **the destructor sequence and the death
  set per checkpoint batch** — not "timing": an elided borrow of a
  destructor-free target legitimately moves the *free* from its own
  release into the parent's cascade, same teardown, different
  nesting; destructor-bearing targets are owned from birth, so
  their timing is pinned and any destructor-sequence diff is a real
  defect.
- **Summary versioning.** A summary is a soundness assumption about
  a callee, so a stdlib update that adds a destructor or a severing
  store invalidates every caller compiled against the old summary.
  Open question 1 carries the versioning rule; without one, every
  stdlib update is a silent soundness event.

## Composition with the designed family

- **Unique ownership:** one borrow analysis, two invalidation
  disciplines — the ownership clause bans checkpoint crossing
  outright, this design substitutes the chain invariant plus the
  path-severing condition. The family-wide ruling the review asked
  for does not exist yet and is open question 5. The sentinel
  constraint and the demotion fixpoint above are the second
  composition point, recorded in both documents.
- **Birth count:** adjacent populations, marginal accounting per the
  economics above.
- **Pure destructors:** transitive purity is the instrument for both
  destructor horizons — the release horizon's closure predicate and
  the checkpoint condition's condemned-set closure; the P0 fast
  paths and death itself are untouched, because owned locals keep
  the count. The checkpoint condition binds every verdict-draining
  checkpoint, so the purity ladder's open hand-off questions are a
  named dependency: if user-code duties move to the sliced tail, the
  condition moves with them.
- **rc-walk and the collector crate:** the collector code is
  untouched; the protocol dependency is the ack-budget paragraph in
  the economics.

## Open questions

1. The summary language: what a summary states — severable paths,
   destructor reachability of internal releases, callee-side
   promotion for borrowed returns, the uniqueness-demotion
   constraint — who writes stdlib summaries, the conservative
   default at every unknown (a horizon, always), and the versioning
   rule from the verification section. The rulings inside are
   Edmond's.
2. Borrow scopes across suspensions: a yield is a horizon unless the
   summary system learns resumption points, and a fiber suspended
   across an arena reset carries frame borrows the reset cannot see
   — one question, and it shapes the IR early.
3. ~~The corpus names for the scan~~ — working choice recorded
   2026-08-18 with Edmond's veto open: WordPress, Monica (Laravel),
   Sylius (Symfony), each with its vendor tree.
4. ~~The hybrid's granularity~~ — ruled by Edmond, 2026-08-18: the
   class bit is the default, always-provable Swift-style elision is
   lawful per site in both regimes, fallible per-site deviation
   stays behind the certificate-plus-shadow-lowering gate, and no
   rule introduces a write barrier (`model/dev/DECISIONS.md`,
   "proof-horizon granularity"; the hybrid section carries it).
5. The family-wide borrow-analysis ruling: one IR-level borrow
   analysis parameterized by the invalidation set, serving unique
   ownership and this design — asked by the five-axis review. The
   working default, recorded 2026-08-18 with Edmond's veto open:
   one analysis, two invalidation sets.
6. Anchored parameters: whether caller-guarantee summaries can lift
   the receiver and by-value parameters out of the owned default,
   and what the re-entrancy obligation costs there.

Questions 7 to 11 were opened by the case-book review of 2026-08-20,
which read the algorithm against the entity and memory RFCs. Each is a
gap in this document, not in the case that found it; the case files
under [gc-horizon-cases/](gc-horizon-cases/) carry the failing shape.

7. ~~**The weak cell is an uncounted edge, and no base case excludes
   it.**~~ Closed by Edmond's ruling 11 of 2026-08-22: the value a
   weak-cell read produces is an owned base case, counted always and
   elided never
   ([walk/questions.md](walk/questions.md#g1-the-weak-cell-is-an-uncounted-edge--closed)).
   The precondition the question offered as the alternative — "the
   region contains no weak-cell load" — was refused for forbidding more
   than the hazard. The question as it stood: A weak cell's `target` field references its referent without
   a count ([weak-references.md](../weak-references.md#the-weak-cell-is-the-canonical-weakreference-itself)),
   so a path through it is not the counted chain the invariant
   requires, and the exact test — which balances counted references
   only — would free the referent under a live borrow. `get()` returns
   a call result, which is owned by convention and therefore safe
   today; the question is whether the owned base-case list must name
   the weak-cell edge outright, and whether the always-provable rules
   need "the region contains no weak-cell load" among their
   preconditions.
8. **Promotion buys nothing in the counted-out memory categories.**
   Widened 2026-08-22: the early return in `ll_retain` is on any
   non-zero category bar COW ([lowering.md](../lowering.md#retain--release)),
   so it covers long-lived entities too, and those do die by explicit
   free or minimal RC. A `#[Region]` arena also resets mid-message,
   when the region object's own count reaches zero
   ([regions.md](../memory/regions.md#definition)), so an arena
   referent does not reliably outlive the frame that borrows it. Both
   shapes need no fiber and no message boundary
   ([walk/questions.md](walk/questions.md#g2-promotion-buys-nothing-in-the-counted-out-categories--open-and-wider-than-the-question)).
   The question as first written:
   Retain and release return early on immortal entities and are absent
   for request-arena ones
   ([arenas.md](../memory/arenas.md#object-categories-by-memory-strategy)),
   so the promotion retain is a no-op there. The lattice reads the
   static class and never the category. Two sub-questions: whether the
   category belongs in the lattice as an axis, and what protects a
   borrow of an arena-resident referent across an actor's message
   boundary, where the arena resets
   ([actors.md](../../runtime/actors.md#per-actor-collection-at-message-boundaries)).
   The arena reset's own destructor fixpoint
   ([arena-reset.md](../memory/arena-reset.md#step-1--validate-trace-destruct-a-fixpoint-loop))
   runs user code in rounds and is a severing point the horizon list
   does not name.
9. **The placement rule is stated over horizons and exits, and stores
   raise.** Ruled 2026-08-22, and the ruling is the reading this
   question offered first: the raise sites join the quantifier,
   every set in it is computed over the graph including its exceptional
   edges, a pad release is a release like any other, and pad state is
   per edge. PH9 and three case files asserted the same, and the reading
   that avoided the clause was tried and failed — a horizon inside a
   `catch` is dominated by no promotion placed after the raise site,
   and a handler pad's releases run destructors that sever. The phi rule above is what
   closes the loop-header shape, and a suspended generator's pads need
   no rule of their own: the frame dies, so the cleanup set applies with
   the suspension point standing in for the raise site. The argument and the three review rounds are in
   [walk/questions.md](walk/questions.md#g3-placement-raise-sites-and-what-a-landing-pad-releases--ruled-one-sentence-owed-to-gc-horizonmd).
10. ~~**The COW and unique-ownership base cases intersect
    inconsistently.**~~ Ruled by Edmond, 2026-08-22: COW wins. The
    unique-ownership proof establishes lifetime, and lifetime is not
    what the separation test asks, so a COW-eligible entity keeps its
    count whatever else is proved about it and the intersection is
    empty ([dev/DECISIONS.md](../../dev/DECISIONS.md)). The separate
    instrument the ruling names is a proof that COW itself is
    unnecessary, which clears the flag and takes the entity out of the
    COW base case altogether. **What the question exposed and the
    ruling does not settle:** the demotion trigger set names convention
    retains and horizon-reaching borrows, and a base-case retain
    against the occupancy sentinel fires none of them, while an owned
    temporary's drop-point release drives that sentinel to zero
    ([walk/questions.md](walk/questions.md#g4-cow-and-unique-ownership-intersect--ruled-the-trigger-set-stays-open)).
11. **The trusted-effect boundary is not specified.** A stored callee
    summary is not the compiler's only source of effect knowledge:
    interprocedural body analysis, builtin and intrinsic models, runtime
    ABI contracts, and the joined models of a closed multi-target call may
    establish the same facts. Read literally, "without a trusted summary"
    rejects those sources and makes common effect-known calls horizons;
    drawing the line at PHP calls instead would reject valid knowledge in
    the other direction. The design needs one source-independent rule for
    sufficiency, trust, composition, freshness and invalidation of call
    effects.
12. **Selective collector-computed counts are a candidate, not a
    composition rule yet.** Form C needs decisions for the canonical
    local-root token and its multiplicity, the `ImmediateCounted` /
    `DeferredCounted` header discriminant, the cross-regime boundary
    count, actor-send integration, occupancy independent of RC, and the
    collector's exact validation under concurrent mutation. An MMTk
    binding may host the experiment, but neither stock MMTk nor its
    pinning API discharges these obligations. Until all six are ruled,
    every entity remains Form A.

13. ~~**"Closest" names one end of a dominator chain and the document
    does not say which.**~~ Closed 2026-08-22: the latest. Read as the
    earliest it names the birth, and the mechanism buys nothing over
    marking the borrow owned. The leak the latest reading admits — a
    `do {} while ()` body always executes, so with a live-range exit
    inside the loop and every horizon outside it the latest point is in
    the body and the retain runs once per iteration — is what the
    execute-at-most-once condition beside the quantifier excludes, and
    its exact form is open question 9. A back-edge poll does not
    exclude it: actor code carries no poll safepoints at all
    ([actors.md](../../runtime/actors.md#per-actor-collection-at-message-boundaries))
    and the strategies that never stop threads compile the poll away
    ([strategies.md](strategies.md)).

## The record

The name is `gc-horizon`; it was `proof-horizon` until 2026-08-20.
The superseded model and its review stay as the map of the space
already searched: the refusals of 2026-08-17 and 2026-08-18 closed the
no-heap-RC roads, and this design keeps every count they defended —
including the owned locals' — and removes only the pairs the proofs
make redundant.

Revision 6, 2026-08-21, adds Form C after identifying Ulterior Reference
Counting and its descendants as the existing selective-RC family. It does
not reverse the Form-A decision: the section records an independently
gated experiment, selects the LXR fork as its experimental substrate,
records the MMTk integration boundary and states the root-token proof that
would be required to reopen a partition of the heap.

Critic round 1, 2026-08-18, three lenses. **Soundness:** uncounted
owning locals leak every acyclic local-only object and move
`__destruct` timing in both directions; the checkpoint hazard is the
drain's own sever-and-free, so the destructor-freedom lift was
inverted; COW's uniqueness test read a falsified count; the
protection-set paragraph contradicted "no walk-side changes"; loop
and conditional horizons made "pay once" unsound without a placement
rule. **Composition:** the elision re-entered rc-walk's
uncounted-borrows prohibition and dropped Deutsch–Bobrow's freeing
half while citing the deferral; "the same three obligations"
misquoted unique ownership's borrow clause; the superseded model's
third recorded problem is deterministic destruction, which revision
1 did not dissolve; the pair-cost citation named the wrong section;
the ack-thinning dependency went unnamed. **Verification:** the
per-call-site scan bounds no lifetime fraction; the census lacks
every channel this design needs; the publication rule's per-crossing
reading admits unbounded negative savings; family savings
double-counted at the shared gate; no falsification artifact
existed. Accepted in full; revision 2 was the fix.

Critic round 2, 2026-08-18, on revision 2's fixes. **Soundness:**
eager death runs severing destructors at ordinary releases the
horizon list did not name (critical); the checkpoint condition's
root set omitted the sever cascade; parameters and `$this` had no
lattice state and re-entrancy killed the caller-frame chain; a
borrowed return surfaces after the callee's epilogue checkpoint,
outside any caller-side promotion; severing stores were undecidable
without a may-alias rule; a promotion retain against a
unique-ownership sentinel protects nothing; COW-container borrows
needed the anchor-identity definition; promotion pinned to scope
exit regressed the drop-point policy. The chain invariant's
reclamation claim survived attack. **Composition:** the horizon
list's openness over eager death, independently; the chain
invariant claimed to restate the rule it extends; the ack-thinning
caveat named the wrong site; the differential oracle's "timing
identical" flags correct compiles; "analysis failure selects owned"
was cited to a do-not-rely file; the checkpoint condition depended
on the hand-off's drain shape without naming it; the code
repository's `dev/INDEX.md` still described revision 1; the
family-wide ruling was dropped, not answered. **Verification:** the
placement rule was unsatisfiable for branch-born borrows; the scan's
kill authority failed on unresolved receivers; no planning artifact
recorded the closed status; the marginal baseline was not computable
from the named channels; the density gate demanded the clock where
the crate's method counts; the shadow count detects only if death
defers to it; the decision log graded itself. Accepted in full;
revision 3 was the fix.

Critic round 3, 2026-08-18, on revision 3's fixes. **Soundness:**
the drop-point policy released an anchor at its last syntactic use
under a live borrow, and the return-site retain's order against the
epilogue was unstated (critical); uniqueness demotion had no sound
lowering local to the borrower's unit (critical); the shadow build's
elided-authoritative death broke the walk's occupancy test, COW and
the release asserts; "can reach a severing store" was not the
predicate purity computes, in both directions; the finality conjunct
was never dischargeable; the placement rule needed SSA and the
back-edge case; the sound configuration's free region is read-only
lifetimes, unstated. Survived a second consecutive round: the chain
invariant's reclamation discharge (re-verified against the
implemented exact test), the release-horizon relocation, the owned
base cases, promotion as a plain retain. **Composition:** eliding a
borrow of a destructor-bearing target moved `__destruct` off the
scope-end pin the design itself cites, and the document both denied
and licensed the move; the owned-slots cross-note dropped "against a
counted entity" and admitted a sentinel-retain reading; the release
horizon's predicate was not purity's; the checkpoint condition's
event binding named the prologue while the dangerous drains run at
arbitrary pickups; the chain extension owed forward notes to the
RFC; the unique-entity path broke the invariant's premise silently.
**Verification:** the two trivial bounds made the kill gate unable to
fire — the optimistic bound discarded the very horizons revision 3
added; the purity closure is the same unavailable inference as
receivers, with no channel; the shadow count was the wrong economics
instrument and "exact" hid the pair-cost dispersion; the channel list
was owed too late ("if accepted"); the certificate overclaimed alias
completeness; the blast radius had no instrument. Accepted in full;
revision 4 was the fix, with the corpus names still open with Edmond.

Critic round 4, 2026-08-18, on revision 4's fixes and the recorded
granularity ruling. **Soundness:** explicit displacement of a
pure-class anchor (`$a = null`) fell under no horizon kind — a
store *to* the anchor is not a store *through* a path base, and the
purity gate exempts the release (critical); the ruling's model case
re-created round 1's COW critical and the heap-field cover, because
horizon-freedom was never the predicate protecting COW or ownership
(critical); the all-returns-transfer retain wrote the unique
sentinel inside the owner's own unit, with the demotion trigger
blind to convention sites; the destructor-free exclusion read the
static class and readmitted the timing bug through a subclass; the
shadow lowering's zero-false-positive property needed the
dual-schedule statement. Survived a third consecutive round: the
chain invariant's reclamation discharge, borrow-is-use for
scheduled releases, destructor-bearing targets owned from birth,
the shadow swap direction, the owned base cases, promotion as a
plain retain. **Composition:** the ruling's "always-provable" class
was defined by an example resting on the may-alias oracle; the
Swift analogy imported a precedent whose lawfulness comes from the
timing-weakening this design refused; the counted-class bullet
contradicted the ruling three paragraphs below; the no-mutator-work
constraint collided with the compensating poll without a scope
sentence; the borrow-is-use amendment owed a debt line to "Drop
Point Policy" and the move rule; the session condition owed one to
"Unique ownership"; a citation named a mechanism ("version-bracket
skip") by a phrase absent from its source. **Verification:** the
always-provable set had no registry, and its counted-class elisions
escaped the shadow journal; the graded optimistic bound still could
not fire the kill on call-shaped horizons, and checkpoint horizons
were structurally absent from both bounds unstated; the
summary-dependency channel's kill authority stood on an
unbracketed proxy graph; the dispersion band's sole citation was a
banned lowering shape; the release-build counter was unexempted
mutator work whose build must not be clocked; the asymmetric gate
carried no bars. Accepted in full; revision 5 is the fix, the
ruling's entry bounded in place with Edmond's criterion kept.

Case-book review, 2026-08-20, one round over the plan for
[gc-horizon-cases/](gc-horizon-cases/) rather than over the algorithm's
text. It read revision 5 against the entity and memory RFCs and
produced open questions 7 to 11 above, the chain extension's forward
notes to [static-lifetimes.md](../memory/static-lifetimes.md#what-may-own-a-borrow)
and [rc-walk.md](rc-walk.md#what-this-design-does-not-solve), and the
move of the purity ladder into [pure-destructors.md](pure-destructors.md),
without which two horizon kinds cited an instrument this repository did
not hold.
