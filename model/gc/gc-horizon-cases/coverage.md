# Coverage: the repository's own cases against this book

## Scope

Where every case already written in this repository lands in the sixteen
GC-horizon cases, and which ones land nowhere with the reason. The
population is bounded and enumerable: the collector family's named
identifiers, the critical review's findings, Edmond's thirty-five
adversarial cases, and the PHP-fenced worked examples of the five
documents that state ownership, borrow, death, weak and COW semantics.
Everything outside that population is excluded by class, with one reason
per class, rather than row by row.

A row saying "no case" is a result, not a gap in this table: it records
that no entity kind and no proof-ending event owns the shape, because it
belongs to the collector's own correctness, to the placement rule, to the
verification instruments or to the economics instead.

## Danger cases

Source: [rc-walk-danger-cases.md](../rc-walk-danger-cases.md). These are
the kill traces the collector's test harness is seeded from, so a
lattice that re-creates one of them is unsound by the repository's own
standard.

| Case | Lands in | Why |
|---|---|---|
| DC0 — dead member balances `0 = 0` | no case | a corpse-rule defect inside the drain; the lattice adds no member and reads no verdict |
| DC1 — stale count masked by self-loops | no case | a variant-mode defect (`byte_only`), retired with the narrow mutator |
| DC2 — `non_total` with `byte_only` | no case | as DC1 |
| DC3 — slot recycled mid-epoch | [checkpoint.md](checkpoint.md) | the deferral window is what makes a stale walker land on an intact corpse, which is the premise the reclamation discharge rests on |
| DC4 — pure cycle under `no_sever` | [checkpoint.md](checkpoint.md), [destructor-bearing.md](destructor-bearing.md) | the sever is the drain arm that runs no user code, and it is what the reclamation threat is about |
| DC5 — uncounted borrow | [weakref.md](weakref.md), and the chain rule of [gc-horizon.md](../gc-horizon.md#the-ownership-lattice) | DC5 is this design's own failure mode. `weakref.md` reaches it by a route DC5 does not name: an uncounted `target` edge instead of an elided retain |

## Proof scenarios and findings

Source: [rc-walk-proof.md](../rc-walk-proof.md), scenarios 1–9 and
findings F1–F9, plus the two design-changing audit findings B1 and A8.

| Identifier | Lands in | Why |
|---|---|---|
| Scenario 1, pure garbage cycle | [checkpoint.md](checkpoint.md) | the baseline drain a borrow must survive |
| Scenario 2, live cycle held from the frame | [checkpoint.md](checkpoint.md), [object.md](object.md) | the acquittal path; a chain rooted in a frame slot is exactly this shape |
| Scenario 3, refcount death during an epoch | [release.md](release.md) | eager death at the release site, with an epoch open |
| Scenario 4, allocate-black | no case | a walk-maturity rule; the lattice creates no entity |
| Scenario 5, reference migration | [store.md](store.md) | the safety-critical shape is a store that moves a reference, which is the severing-store horizon read from the collector's side |
| Scenario 6, `non_total` | no case | a retired variant |
| Scenario 7, `no_defer` | [checkpoint.md](checkpoint.md) | slot identity across the epoch, the deferral window again |
| Scenario 8, `no_sever` | [destructor-bearing.md](destructor-bearing.md) | the immortal cycle, and what a sever is for |
| Scenario 9, `uncounted` | [weakref.md](weakref.md) | the scenario DC5 was distilled from |
| F1, guard discounted in re-verify | [destructor-bearing.md](destructor-bearing.md) | the guard exists for resurrection, which purity removes |
| F2, epoch abort and parked volume | [release.md](release.md) | the ack-rate thinning is priced in epoch duration |
| F3, parked memory bounded by churn | [release.md](release.md) | same currency |
| F4, edge validation | [store.md](store.md) | a dropped edge is the conservative direction the chain argument relies on |
| F5, deferred-death marker | no case | retired by the eager-death amendment |
| F6, near-false post | [checkpoint.md](checkpoint.md) | the exact test's acquittal is the reclamation discharge |
| F7, M3 releases last | [release.md](release.md) | a compiler obligation on release order, adjacent to borrow-is-use |
| F8, drain is non-reentrant | [checkpoint.md](checkpoint.md) | with [drain-window.md](../drain-window.md), the third link of the discharge |
| F9, frame slots represent external holders | [arena.md](arena.md) | the root categories the chain invariant may end in |
| B1, an acquittal is a message | [checkpoint.md](checkpoint.md) | which checkpoints can drain a verdict |
| A8, the allocate-black skip is total | no case | a walk rule with no lattice reader |

## Review findings

Source: [rc-walk-review.md](../rc-walk-review.md), findings 1–11.
Findings 1–10 are collector-internal and land in no case: they concern
the condemnation's evidence, the header switch, racing child reads,
double condemnation, the memory model, the FREE stamp, `id` stability,
dirty-page tracking and the snapshot's memory — none of which the
lattice reads or writes. **Finding 11, "Two RFCs disagree about
roots", lands in [arena.md](arena.md)**, because the root set is what an
anchor chain must end in, and a disagreement about roots is a
disagreement about which chains are lawful.

Source: `model/dev/RC_WALK_CRITICAL_REVIEW.md` in the code repository,
findings 1–10, cited by section title because that review numbers by
heading. It is in scope for one reason: three of its findings price the
currency this design spends. "Epoch progress has no bound" and
"Deferred memory is unbounded in epoch duration" are what the ack-rate
thinning of [release.md](release.md) is charged against, and "Phase 4 can
create an unbounded mutator pause" is the pause
[checkpoint.md](checkpoint.md) inherits. The other seven — the
production driver, the free path's allocation, per-epoch metadata,
`debug_assert` in soundness transitions, the unimplemented acyclic
optimization, repeated acquittal under mutation, and the single-mutator
protocol — land in no case.

## Edmond's adversarial cases

Source: [adversarial.md](adversarial.md), PH1 to PH35, written 2026-08-20
against revision 5 of [gc-horizon.md](../gc-horizon.md). Every number lands
in the case that owns its shape, or in a row saying "no case" with the
reason; eight land in no case. Twenty of the thirty-five named a hole the
algorithm did not carry, and they opened eight questions, 14 to 21, of
[gc-horizon.md](../gc-horizon.md#open-questions).

| Case | Lands in | Why |
|---|---|---|
| PH1 — destructor-free is not death-unobservable | [weakref.md](weakref.md) | the target is destructor-free, so the drop-point policy drops it at last use ([static-lifetimes.md](../../memory/static-lifetimes.md#drop-point-policy)); a weak subscriber makes that death observable, which the policy's premise does not admit — question 14 |
| PH2 — WeakMap observes it without `get()` | [weakref.md](weakref.md) | PH1's independent witness, through a weak-key table instead of a cell; the table's own mechanism is node D6 of [walk/questions.md](../walk/questions.md#d6-weakmap-ephemerons--open-the-cost-was-overstated-and-a-cheaper-shape-exists) |
| PH3 — the differential oracle declares the break legal | no case | an obligation on the differential lowering, whose oracle is the destructor sequence and the death set per batch ([gc-horizon.md](../gc-horizon.md#verification-artifacts-a-precondition-of-implementation)); weak-cell transitions are in neither — question 14 |
| PH4 — an elided pair was another chain's root | [object.md](object.md), [unique-entity.md](unique-entity.md), [arena.md](arena.md) | the chain ends in an owned local, and PH4 asks what "owned" names when no live count was emitted; the always-provable route is bounded away from PH4's own snippet, the unique-crossing base case emits a retain against a standing sentinel, which is a second such local, and a promotion retain in a counted-out category is a third — question 16, and question 8 for the third |
| PH5 — arena reset removes a root category | [arena.md](arena.md) | the reset is the case's own second uncovered event, recorded there under question 8 |
| PH6 — suspension carries an arena borrow across a reset | [suspension.md](suspension.md), [arena.md](arena.md) | the hole report's item 3, and the second half of question 2 |
| PH7 — a summary misses a transitive alias | [call.md](call.md), [store.md](store.md) | a summary claims "severs no path", and the may-alias rule is what it claims against |
| PH8 — FFI mutates a managed path behind a pure call | [ffi.md](ffi.md) | a constraint on question 11: an FFI summary lifts a horizon only if it forbids managed-slot mutation, pointer retention, callbacks and transfer. Ruling 7 of 2026-08-22 bounds what the C side can reach ([walk/questions.md](../walk/questions.md#rulings-of-2026-08-22)), and folding it into ffi.md is step S5.7 |
| PH9 — promotion must dominate the throwing edge | [unwind.md](unwind.md) | ruled 2026-08-22, and the ruling is PH9's reading: the raise sites are in the placement quantifier ([gc-horizon.md](../gc-horizon.md#at-the-horizon-promotion)) |
| PH10 — closure capture publishes a borrow | [closure.md](closure.md), [reference-box.md](reference-box.md) | the hole report's item 6; by-reference capture is the escape kind reference-box.md owns |
| PH11 — late class loading widens a closed set | [destructor-bearing.md](destructor-bearing.md), [call.md](call.md) | the exclusion is computed by a closed-world closure and loading is open-world — question 19 |
| PH12 — a dependency's summary changed | [call.md](call.md) | item 5's versioning rule, carried by question 1; PH12 states that summary identity must include the transitive dependency digest |
| PH13 — checkpoint purity is data-dependent | [checkpoint.md](checkpoint.md) | item 1: the discharge has no compile-time form, and PH13 is why a runtime observation cannot supply one |
| PH14 — an alias born after analysis | [store.md](store.md) | reflection and `&` are horizon kinds already; what is left is the may-alias rule's conservative default, which this case states |
| PH15 — a phi merges equal pointers with different proofs | [object.md](object.md) | a phi's verdict is a lattice verdict, and this is the lattice case; the rule itself is in the promotion section, which carries PH15 by number: a phi falls to owned unless one chain dominates every incoming edge |
| PH16 — the elision removes the checkpoint fabric | [checkpoint.md](checkpoint.md), [release.md](release.md) | release.md item 3 owns the thinned ack rate and names the compensating-poll rule as owed; PH16 states what that rule must bound, including the all-elided class |
| PH17 — internal finalization without `__destruct` | [destructor-bearing.md](destructor-bearing.md), [suspension.md](suspension.md) | the ladder's P0 row reads "no `__destruct` in the hierarchy" ([pure-destructors.md](../pure-destructors.md#the-purity-ladder)), and a suspended generator's teardown runs `finally` under it — question 15 |
| PH18 — implicit invokes are horizons too | [call.md](call.md) | a hook, a cast, autoload or an error handler runs user code with no call in the source, so every one of them owes its effects in the final IR before the horizon list can be read off it — question 17 |
| PH19 — exception diagnostics publish borrowed values | [unwind.md](unwind.md) | the default trace mode publishes nothing — scalars by value, truncated strings, the class name for an object ([exceptions.md](../../../runtime/exceptions.md#arguments-must-not-hold-references)) — so what PH19 reaches is the heavier array-form `getTrace()` mode, whose capture is unspecified |
| PH20 — phi liveness belongs to incoming edges | [release.md](release.md) | borrow-is-use is this case's rule; the promotion section carries PH20's edge form by number |
| PH21 — inlining deletes the convention retain | [call.md](call.md) | the by-value parameter's counted reference is this case's base case, and ARC cleanup after inlining can delete it — question 16 |
| PH22 — shared landing pads need edge-sensitive ownership | [unwind.md](unwind.md) | pad state is per exceptional edge and per SSA generation ([gc-horizon.md](../gc-horizon.md#at-the-horizon-promotion)) |
| PH23 — a late lowering pass introduces a horizon | no case | phase ordering, which belongs to no entity kind and no event — question 17 |
| PH24 — external roots are revocable capabilities | [arena.md](arena.md) | the non-frame roots are this case's subject, and revoking a static or a registry entry is in no horizon kind — question 18 |
| PH25 — not every FFI handle is a counted root | [ffi.md](ffi.md) | item 4 records that an FFI-handle root is checked by nothing; the handle taxonomy PH25 supplies — raw, weak, borrowed, pinned — this repository does not define, and ruling 7 of 2026-08-22 answers it in PH25's own direction — question 18 |
| PH26 — foreign mutation between IR events | [ffi.md](ffi.md) | an asynchronous callback mutates at no IR site, so no static horizon covers it; how much it can reach is bounded by ruling 7 — question 18 |
| PH27 — root and summary identities suffer ABA | no case | certificate content: root generations and a loader-incarnation epoch — question 18 |
| PH28 — shadow count cannot prove `stable_path` | [store.md](store.md) | this case's oracle rests on the shadow-count lowering as the only instrument that sees a may-alias error, and PH28 is the shape it does not see — question 20 |
| PH29 — one-sided shadow zero misses duplicate promotion | no case | the same instrument in the other direction: two retains and one release never cross zero — question 20 |
| PH30 — the certificate and the checker share an omission | no case | an obligation on the certificate gate: the checker reconstructs horizons from final IR rather than reading the producer's list — question 20 |
| PH31 — a cold horizon makes promotion hot | no case | the census channel "horizon crossings per borrow lifetime" prices the wrong quantity; the ratio that prices cost is promotions per acquisition ([gc-horizon.md](../gc-horizon.md#economics)) — question 21 |
| PH32 — proof metadata can grow quadratically | no case | compile time and code size are named as costs and carry no bound; PH32 names the sweep and the fallback-to-owned cap that would bound them — question 21 |
| PH33 — finite checkpoint thinning is max-straggler dominated | [release.md](release.md) | the finite form of PH16; its several-mutator half waits on what an owner is, node E1 of [walk/questions.md](../walk/questions.md#e1-actors-and-the-epoch-protocol--structures-resolved-2026-08-23-the-stamp-half-stays-open) |
| PH34 — pair elision batches reclamation into a spike | [release.md](release.md) | eager death and the cascade are this case's subject, and the economics carries no tail budget |
| PH35 — the release counter needs a conservation law | no case | an obligation on the release-build elision counter ([gc-horizon.md](../gc-horizon.md#economics)): executed acquisitions differ from executed drops, and the document does not say which end the counter sits at — question 21, which also records that the one measured pair is a different pair |

**Two cases receive no PH number**: [array.md](array.md) and
[string.md](string.md). The battery attacks no COW-by-kind exclusion at
all, which is what both files exist for. It does attack the sentinel,
through PH4's demand that "owned" name an emitted count, so
[unique-entity.md](unique-entity.md) carries that number rather than
none.

### What the mapping found

Nine disagreements between a PH case and a document in force. Each is
recorded here and fixed nowhere, which is what the step asked for.

1. **PH1 against the drop-point policy.** The policy splits by
   observability and defines observability as a `__destruct` or a
   finalizable resource
   ([static-lifetimes.md](../../memory/static-lifetimes.md#drop-point-policy)).
   A weak subscriber observes the death of a class with neither, so the
   "unobservable" premise is false for every weak-subscribed target.
   Question 14.
2. **PH17 against the purity ladder's P0 row.** P0 is "no `__destruct` in
   the hierarchy" ([pure-destructors.md](../pure-destructors.md#the-purity-ladder)),
   and [destructor-bearing.md](destructor-bearing.md) reads P0 as
   destructor-free for the exclusion. A suspended generator is P0 by that
   reading and still runs pending `finally` blocks at teardown. Question 15.
3. **PH28 against store.md's oracle.** [store.md](store.md) section 7 calls
   the shadow-count lowering the only instrument that sees a may-alias
   error. PH28's shape keeps the shadow word non-zero through an unrelated
   owner, so a false path proof produces no divergence at all. Question 20.
4. **PH25 against the root list.** The root list does not omit the
   requirement, it asserts the opposite: every root category is counted,
   "the store barrier retains on any store regardless of the holder's
   category" ([rc-walk.md](../rc-walk.md#the-central-identity-roots-are-derived-not-enumerated)),
   and the exact test's derivation rests on that assertion.
   [ffi.md](ffi.md) and [arena.md](arena.md) repeat the list, and so does
   the lattice's own anchor definition. PH25 says the assertion is false
   for a handle that keeps an address stable while emitting no count.
   Ruling 7 of 2026-08-22 answers in PH25's direction for the wrapper
   ([walk/questions.md](../walk/questions.md#rulings-of-2026-08-22)), and
   the root list still names a handle. Question 18.
5. **PH31 against the census channel list.** The economics owes a channel
   for horizon crossings per borrow lifetime
   ([gc-horizon.md](../gc-horizon.md#economics)). A single promotion
   hoisted to dominate a cold horizon executes on every call, so crossings
   under-report the emitted pairs by the branch probability.
6. **PH4 against the always-provable elision licence, and the bound
   that keeps them apart.** The granularity ruling makes per-site elision
   lawful in both regimes and the chain rule lets a chain end in an owned
   local, so the two applied to one local produce a chain ending in an
   uncounted root ([gc-horizon.md](../gc-horizon.md#the-ownership-lattice)).
   The round-4 bound stops PH4's own snippet from reaching it: a rule
   enters the always-provable set only where the enclosed region holds no
   call, no store, no release and no checkpoint
   ([gc-horizon.md](../gc-horizon.md#the-hybrid-counted-class-horizon-class)),
   and PH4's borrow is passed to a call. What survives is PH21, which
   deletes the same count by inlining and is bound by no region rule, and
   one unstated thing: whether the convention pairs are in the set at
   all. Question 16.

7. **PH6 against arena.md's central finding.** PH6 has every suspension
   promote its live anchored borrows before yielding, and that remedy is
   the promotion retain alone. [arena.md](arena.md) states what the
   retain does on an arena referent: retain and release return early on
   the category test, so "this borrow costs one call pair in both worlds
   and is protected in neither". PH5 is not in this finding — its rule
   carries a second disjunct, the reset's own promotion fixpoint
   retaining the whole path, which is the escapee hold-count and the
   escaped-subgraph trace of
   [arena-reset.md](../../memory/arena-reset.md#step-1--validate-trace-destruct-a-fixpoint-loop),
   and that mechanism works. PH5's primary rule — the reset is a horizon
   no ordinary call summary may lift — stands whatever the retain costs,
   and it is what question 8 is missing.
8. **PH16 against the ack budget's classification.** The economics puts
   the thinned scope-exit ack among the three costs that sit outside the
   formula, and [release.md](release.md) item 3 calls the effect "named
   and unpriced". PH16 says the classification is the error: a loop whose
   whole release run is elided leaves the epoch no ack site, so what
   changed is the collector's progress premise rather than a cost term.
9. **PH34 against the scheme's cost bound.** The promotion section
   states that per borrow the scheme never costs more than the current
   code and that overpayment "loses savings, never adds cost"
   ([gc-horizon.md](../gc-horizon.md#at-the-horizon-promotion)). PH34
   measures a currency that sentence does not cover: eliding a
   destructor-free subtree's pairs moves its releases into one sever or
   one checkpoint, so the instruction count falls while one request pays
   the whole cascade.

Two further disagreements are not this step's to record, both of them
between a case file and a ruling of 2026-08-22. Open item 1 of
[unwind.md](unwind.md) still offers the raise-site quantifier as an open
reading, which question 9 settled. Open item 1 of
[weakref.md](weakref.md) still poses question 7 as two open halves, while
ruling 11 supplied the first and refused the second for forbidding more
than the hazard; section 4 of the same file argues the refused
precondition. Folding the rulings back into the sixteen cases is step
S5.7 of `dev/PLAN.md`, which names the weak-reference case by item.

## Worked examples in the entity and memory RFCs

The population is every PHP-fenced block in
[static-lifetimes.md](../../memory/static-lifetimes.md),
[values.md](../../values.md),
[weak-references.md](../../weak-references.md),
[ffi.md](../../memory/ffi.md) and [arenas.md](../../memory/arenas.md),
cited by document and heading. Three of the five carry none, which is
itself worth recording: the ownership rules of this repository are
stated in prose and only `static-lifetimes.md` argues them in PHP.

| Document and heading | Blocks | Lands in |
|---|---|---|
| static-lifetimes.md, "What may own a borrow" | 3 | the owner dying before the borrow → [release.md](release.md); the heap-field owner inside a cycle → [object.md](object.md) and the chain rule; the capture that is a store → [closure.md](closure.md) |
| static-lifetimes.md, "Level B — Known cycle shapes" | 2 | [object.md](object.md), as the parent/child shape a typed-property chain runs along |
| ffi.md, "Declaring a C structure" | 1 | [ffi.md](ffi.md) |
| values.md | 0 | its examples are C and LLVM listings, mapped through the COW rows above |
| weak-references.md | 0 | its examples are untagged listings; the semantics they show are covered by [weakref.md](weakref.md) |
| arenas.md | 0 | its cross-arena rules are prose, covered by [arena.md](arena.md) and [store.md](store.md) |

## Excluded classes

Named as classes, with one reason each, rather than enumerated:

- **Hashtable flood defence** ([arrays-hashtable.md](../../arrays-hashtable.md)):
  the rung ladder, the per-process key and the index benchmarks concern
  collision behaviour inside one entity's storage. A borrow of an
  element is covered by [array.md](array.md); no lattice verdict turns
  on a rung.
- **Dispatch, inline caches and itables** ([classes.md](../../classes.md),
  [caches.md](../../caches.md)): a cache decides which callee runs, and
  the lattice reads only whether the class set is closed, which
  [call.md](call.md) states once.
- **String hashing and interning benchmarks** ([strings.md](../../strings.md)):
  memo state a borrow does not move, except for the immortality of an
  interned string, which [string.md](string.md) carries.
- **Layout arithmetic** ([layouts.md](../../layouts.md),
  [classes.md](../../classes.md) slot order): byte offsets change no
  verdict.
- **Exception channel selection** ([exceptions.md](../../../runtime/exceptions.md)):
  which channel a function uses is an ABI property;
  [unwind.md](unwind.md) takes only the raise sites and the `isThrow`
  property from it.
- **The rc-satb strategy** ([satb.md](../satb.md)): a second build-time
  collector, deliberately unbuilt. Its store barrier would change what a
  store costs, not what a proof covers.

## Named as uncovered

Two shapes belong to neither half of this table, and naming them is the
whole of what this section does.

**Maps** ([maps.md](../../maps.md)). A map is an ordinary object of the
object entity kind, so [object.md](object.md)'s verdict covers a borrow
*of* a map. A borrow of an *entry* is another matter: a map's counted
children are its keys and values, and they "live in the table's chunk,
outside the object", where the walker's per-entity descriptions cannot
describe them and only the optional hook family — stage S18 of the
crate, which does not exist — reaches them. The chain invariant's
premise is that every path edge is a counted heap edge, discharged by
the exact test finding an external counted in-edge; for a map entry that
in-edge is in a chunk the walk cannot enter, so `RC − IN` inflates
toward roothood. That is the conservative direction, and it is the same
incoherent-skip argument [array.md](array.md) makes for a storage
buffer, unstated for maps. No case owns the shape and no excluded class
covers it; the case that would own it waits on the same hook the
collector waits on.

**The by-reference escape has no event case.** The plan's destination
promises one case per event that can end a proof, and the escape's home
is a section of [reference-box.md](reference-box.md), an entity case
whose subject is the COW exclusion. The kind has no lift and no
measurement channel either (that file's open item 3), so it is the one
horizon kind carried entirely inside a case written for something else.

## What this table does not check

That a case is *correct*. Coverage says a shape has a home; whether the
home states the truth about it is what the Critic rounds of
`dev/PLAN.md` S3 exist for. Round 1 ran on 2026-08-23 in three lenses
and produced twenty-five findings, every one of them fixed; round 2
followed it the same day.
