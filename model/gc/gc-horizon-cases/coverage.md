# Coverage: the repository's own cases against this book

## Scope

Where every case already written in this repository lands in the sixteen
GC-horizon cases, and which ones land nowhere with the reason. The
population is bounded and enumerable: the collector family's named
identifiers, the critical review's findings, and the PHP-fenced worked
examples of the five documents that state ownership, borrow, death, weak
and COW semantics. Everything outside that population is excluded by
class, with one reason per class, rather than row by row.

A row saying "no case" is a result, not a gap in this table: it records
that the shape belongs to the collector's own correctness and is
untouched by the lattice.

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

## What this table does not check

That a case is *correct*. Coverage says a shape has a home; whether the
home states the truth about it is what the Critic rounds of
`dev/PLAN.md` S3 exist for, and they have not run.
