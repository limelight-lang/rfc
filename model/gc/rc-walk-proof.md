# rc-walk — proof by scenario replay

> **Status: in progress.** Step-by-step replay of the protocol of
> [rc-walk.md](rc-walk.md) against the model of
> [rc-walk-model.md](rc-walk-model.md): each scenario fixes a heap shape,
> plays every essential interleaving of the three actors action by
> action, and checks the claims against the ground-truth oracle `R*`
> (§4). Ordinary scenarios first, then the adversarial variants of
> [../../dev/TASK-rc-walk-proof.md](../../dev/TASK-rc-walk-proof.md).
> Contradictions found against the design documents are recorded here as
> numbered findings, per the task's constraint not to edit those
> documents.

## Method and notation

Configuration: one block, `S = 3` slots `s1..s3`, `k = 2` fields
`f1, f2`, `F = 2` frame slots. `rc(s)` is the true refcount, `crc[s]`
the collector's recorded read, `eb(s)` the epoch byte
(`0 | cur | old`), `cb(s)` the condemned byte. `R*` = entities reachable
from frame slots. A scenario is: shape, claim, trace (one action per
step, per the atomicity of [rc-walk-model.md](rc-walk-model.md) §2),
then a case analysis over the interleavings not shown.

Findings are numbered `F1, F2, …` across all scenarios.

## Scenario 1 — pure garbage cycle, quiet mutator

**Shape.** `s1.f1 = s2`, `s2.f1 = s1`, all other fields null. Frame
empty. `rc(s1) = rc(s2) = 1` (each held only by the other),
`eb = old` on both (they predate this epoch — see F3), `cb = 0`. `s3`
virgin. `R* = ∅`: both entities are garbage. No destructors.

**Claim.** One epoch confirms and frees both, exactly once, touching
nothing live (T4 vacuously; T5 for this epoch; I1–I6 throughout).

**Trace.** The mutator is quiet: its only actions are the checkpoints
(M5) the protocol itself requires.

| # | Actor | Action | State after |
|---|---|---|---|
| 1 | A5 | trigger epoch | epoch in flight; deferred-free active |
| 2 | C1 | snapshot | registry `{block}`, cursor = 2 → walk set `{s1, s2}` |
| 3 | C2/C3 | walk `s1`: occupied, `eb = old` → mature | `crc[s1] = 1`; edge `s1→s2` recorded |
| 4 | C2/C3 | walk `s2`: same | `crc[s2] = 1`; edge `s2→s1` recorded |
| 5 | C | diff (private) | `in = {s1:1, s2:1}`; `crc − in = 0, 0` → no roots; mark from ∅ marks nothing; component `K = {s1, s2}` |
| 6 | C5 | condemn | `cb(s1) = cb(s2) = 1` |
| 7 | C6 | request handshake | flag raised |
| 8 | M5 | checkpoint | ack + release fence |
| 9 | C7 | observe ack | ordering edge; no prior mutator writes existed |
| 10 | C | re-check | re-read `rc = 1, 1` (unchanged), re-read edge sources (unchanged), `RC − IN = 0, 0`, `cb = 1, 1` → `K` survives |
| 11 | C8 | post `K` | message queued; epoch cannot end until drain acks (I6) |
| 12 | M5 | checkpoint → drain, exact test | `rc(s1) = 1 = indeg_K(s1)`, `rc(s2) = 1 = indeg_K(s2)` from current fields → pass, race-free (mutator's own thread) |
| 13 | M | guard | `rc = 2, 2` |
| 14 | M | destructors | none pending |
| 15 | M | re-verify | **see F1** — passes only if the test discounts the guards: `rc − guard = 1 = indeg` |
| 16 | M | sever `s1` | release(`s2`): `rc(s2) = 1` (stops at guard, no teardown); `s1.f1 = null` |
| 17 | M | sever `s2` | release(`s1`): `rc(s1) = 1`; `s2.f1 = null` |
| 18 | M | un-guard `s1` | `rc(s1) = 0` → true zero → ordinary teardown; fields already null; free → deferred (epoch in flight) → `s1` parked |
| 19 | M | un-guard `s2` | same → `s2` parked |
| 20 | M | ack drain | message drained |
| 21 | A4 | flush at epoch end | `s1, s2` free; epoch closed |

**Interleaving analysis.** With a quiet mutator the only free choices
are the walk order (3↔4) and where the checkpoints land. Walk order is
symmetric here (the shape is). The checkpoints can only be *later* than
shown, which delays steps 9–21 without changing any read value: no
mutator action exists to change state between any two collector reads.
So every interleaving of this scenario reaches the same verdict through
the same values. The claim holds on all of them.

**Invariant spot-checks.** I1: every `rc` change in the trace pairs
with a real reference change (guard counts as the Phase 4 guard term).
I2: `s1, s2` reach `rc = 0` only after both fields are nulled and the
frame never held them. I3: freed slots park (18, 19) and recycle only
at 21. I6: one message in flight; the epoch ends at 21 only after the
ack at 20.

### Findings

- **F1 — the re-verify as written can never pass.**
  [rc-walk.md](rc-walk.md) Phase 4 step 3 says "re-verify the exact
  test" after guarding (step 1) — but the guard added +1 to every
  member, so the literal test `rc(m) = indeg_K(m)` now reads
  `indeg + 1 ≠ indeg` for every member, every component is acquitted,
  and **the collector can never free anything**. The intended test is
  evidently guard-aware — `rc(m) − 1 = indeg_K(m)` while the member's
  guard is outstanding — but the document does not say so, and the
  first draft's Phase 4 already failed once on exactly this class of
  arithmetic (the un-guard-without-sever error). One clause fixes it;
  it must be stated, not assumed.
- **F2 — T5 (progress) rests on an unstated fairness premise.** Both
  the handshake ack (step 8) and the entire drain (steps 12–20) run
  only when the mutator reaches an allocator checkpoint. A mutator that
  stops allocating — an idle worker, a pure compute loop — never acks
  and never drains: the epoch cannot end (I6), parked slots are never
  flushed, and deferred memory is held indefinitely.
  [rc-walk.md](rc-walk.md) argues the parked-in-syscall thread is
  harmless because "nobody is waiting on it" — but the epoch *is*
  waiting on it once a message is posted. The model's T5 proof sketch
  ("the drain is bounded by the posted components") silently assumes
  the drain runs at all. T5 is true only under "the mutator reaches
  checkpoints infinitely often"; the fairness assumption must be
  stated, and the design may want a fallback (e.g. epoch abort on a
  quiescent thread) — recall, not safety. The hold is unbounded in
  *duration*, not volume: the deferred queue is size-bounded by the
  live heap at epoch start (review-pass correction).
- **F3 — a cycle is collectible no earlier than its second epoch.**
  The shape's precondition `eb = old` requires a previous epoch to have
  stamped the entities: in their creation epoch they read as new and
  are skipped (allocate-black). Consistent with the design's stated
  latency trade; recorded so the recall numbers are read correctly.

## Scenario 2 — live cycle, held from the frame, touched mid-walk

**Shape.** `s1.f1 = s2`, `s2.f1 = s1` as before, but frame slot 1
holds `s1` throughout: `rc(s1) = 2` (frame + `s2.f1`), `rc(s2) = 1`.
`eb = old` on both. `R* = {s1, s2}`: both live. To give the race
something to bite on, the mutator borrows the cycle's other member
mid-walk: `load(fr2, s1.f1)` (retain, `rc(s2) = 2`) and later
`drop(fr2)` (release, `rc(s2) = 1`).

**Claim.** In every interleaving of the borrow with the walk, no
component is ever condemned: Phases 3 and 4 never run, both entities
survive (T4), and staleness only ever manifests as extra pinning.

**Replay.** The collector's six reads are `rc(s1)`, `rc(s2)` and the
four per-field reads (`C3` is per-field, §2), in any order (§1:
arbitrary permutation), each falling before, between, or after the two
mutator actions. The values they can observe (the two `f2` reads are
constantly null and drop out):

| Read | Possible values | Why |
|---|---|---|
| `crc[s1]` | 2 | frame ref and `s2.f1` never change |
| `s1.fields` | `f1 = s2` | never written |
| `crc[s2]` | 1 or 2 | 2 iff read inside the borrow window |
| `s2.fields` | `f1 = s1` | never written |

Diff, by cases:

- `in[s1] = 1` (from `s2.f1`), `crc[s1] = 2` → `RC − IN = 1 > 0`:
  **`s1` is a root in every interleaving** — the frame's retain is
  what the central identity picks up, with no stack scan.
- `in[s2] = 1` (from `s1.f1`). If `crc[s2] = 1`: `RC − IN = 0`, `s2`
  is not a root — but mark from `s1` follows the recorded edge
  `s1→s2` and marks it. If `crc[s2] = 2` (stale-high read inside the
  borrow window): `s2` is spuriously a root — strictly more pinned.

Either way the marked set is `{s1, s2}`, the unmarked set is empty,
there is no component, nothing is condemned, and the epoch closes
after the walk. The borrow's retain/release also cleared `cb` bytes
that were already 0 — harmless.

**Invariant spot-checks.** I1 holds through the borrow
(retain/release pair with the frame bind/unbind). I4: both slots
stamped `old`, walked once. I5: the collector wrote nothing but
private arrays this epoch. I6 vacuous — no message.

### Findings

None. The scenario confirms the two claims it was built to test: a
frame-held entity is a derived root in every interleaving (the
identity replaces root enumeration), and a stale-high count read can
only add pinning — the leak direction of
[rc-walk.md](rc-walk.md) "Where the errors point", never the
condemnation direction, because condemnation requires `RC − IN ≤ 0`
and a concurrent borrow only raises `RC`.

## Scenario 3 — ordinary refcount death during an epoch

**Shape.** `s1` (X) held only by frame slot 1, `rc(s1) = 1`;
`s1.f1 = s2` (Y), and frame slot 2 also holds Y: `rc(s2) = 2`.
`eb = old` on both, `s3` virgin. `R* = {s1, s2}`. Mid-walk the mutator
drops X: `drop(fr1)` → `rc(s1) = 0` → teardown: no destructor, release
children (`rc(s2) = 1`), null fields, slot to `A` → epoch in flight →
**parked** (A3).

**Claim.** In every interleaving: Y is never condemned; X's slot parks
and is not reused before epoch end (I3); every stale read the walker
can make points leak-ward.

**Replay.** The walker's reads of `s1` straddle the death. Cases by
what `C2(s1)` observes:

- **`C2(s1)` after the death**: reads `rc = 0` → occupancy test →
  skip, no row, no `C3`. Y's row: `crc[s2] ∈ {2, 1}` (before/after the
  teardown's child release), `in[s2] = 0` → root either way. Nothing
  unmarked. ✓
- **`C2(s1)` before the death** (`crc[s1] = 1`): X is walked. Each
  `C3(s1, f)` is its own action, so the field reads land before the
  death (edge `s1→s2` recorded) or after (null — teardown nulled it).
  Worst combination: `crc[s1] = 1`, edge `s1→s2` recorded,
  `crc[s2] = 1` read after the child release. Diff: `in[s1] = 0` →
  `RC − IN = 1` → **the dead X is a phantom root**, and the phantom
  edge marks Y from it. Y also independently roots if its count was
  read as 2. Every case: Y marked or rooted. ✓

The dangerous-looking pair — a recorded edge from a dying source plus
an already-decremented target count — is exactly the review's finding
7 window, and it resolves leak-ward here because a walked source with
no recorded in-edges is always a root (`in = 0`), so its targets are
marked. The occupancy test closes the rest: once `rc = 0` is
observable, the source contributes nothing at all.

**Model-fidelity note.** The model folds child-release + field-null +
park into one atomic action, while real teardown is a store sequence.
No observable is lost: the collector's reads are per-cell (`C2`, `C3`
per field), so any real intermediate observation — e.g. "edge still
present, child count already decremented" — is reproduced in the model
by placing `C3(s1, f1)` before the death action and `C2(s2)` after it.
Every real straddle maps to a model straddle.

**I3 check.** `s1` parks at the death and recycles only at the flush;
no id names two entities within the epoch.

### Findings

None new. Confirms the occupancy test retires the mid-teardown window
(review finding 7) *given* per-cell read granularity, and that a
phantom root from a dying entity costs pinning for one epoch, never a
verdict.

## Scenario 4 — allocation mid-epoch (allocate-black)

**Shape.** Frame slot 1 holds `s1` (A, live, `eb = old`,
`rc(s1) = 1`). Snapshot happens with cursor = 1 (only `s1` existed).
Mid-walk the mutator allocates: `new(fr2)` → `s2` (C), `rc(s2) = 1`,
`eb(s2) = 0`, then `store(s2.f1, fr1)` → `s2.f1 = s1`,
`rc(s1) = 2`. `R* = {s1, s2}`.

**Claim.** In every interleaving C is never walked, never judged, and
its targets only gain roots (allocate-black); a lost stamp costs one
epoch of latency, never a verdict.

**Replay.** Three ways the walker can meet `s2`:

- **Past the snapshot cursor** (allocation after C1): the walk never
  visits `s2` at all. No row, no edges from it. Its store into `s1`
  raised `rc(s1)` to 2 while `in[s1]` records at most the walked
  heap's edges (none) → `RC − IN ≥ 1` → A pinned. ✓ (T1: an unwalked
  source only adds roots.)
- **Visited, reads `eb = 0`** (allocation before the visit, same
  registry slot pre-existing — reuse path): classified **new** → stamp
  `cur`, skip. Same arithmetic as above. ✓
- **Stamp lost to the race** ([rc-walk.md](rc-walk.md): a mutator
  whole-word store can bury the collector's stamp): `s2` reads as new
  again next epoch — one more epoch of skipping. Latency, no verdict
  change. ✓ *Alphabet gap (review pass): no §2 mutator action writes
  the epoch byte, so a §2-faithful checker cannot generate this
  branch; it is replayed from the protocol document, and the model's
  alphabet needs the burying store added if the checker is to cover
  it.*

In all cases nothing about C enters `rc[]`/`edges[]`, so no component
can contain it: condemnation of C is unreachable this epoch, and its
retains are visible only as extra `RC` on its targets — the safe
direction.

### Findings

None. Allocate-black holds by construction: the only records the
verdict pipeline consumes are rows and edges of *walked* entities, and
a new entity contributes neither.

## Scenario 5 — reference migration (the safety-critical shape)

**Shape.** `s1` (A) and `s2` (B) form a cycle via `f1`; `s1.f2 = s3`
(X). Frame slot 1 holds A. `rc(s1) = 2`, `rc(s2) = 1`, `rc(s3) = 1`.
All `eb = old`. `R* = {s1, s2, s3}`. The mutator migrates X out of the
dying cycle:

    m1  load(fr2, s1.f2)     rc(X) 1→2, cb(X) := 0
    m2  store(s1.f2, null)   rc(X) 2→1, cb(X) := 0
    m3  drop(fr1)            rc(A) 2→1, cb(A) := 0   (cycle now garbage)

After m3: `R* = {s3}`. A and B may be freed; X must not.

**The dangerous walk** (reachable, and the walk order matters): the
walk reads `crc[s3] = 1` *before* m1, records the edge `s1→s3`
*before* m2, and reads `crc[s1] = 1` *after* m3. Then
`in = {s1:1, s2:1, s3:1}`, `crc − in = 0` everywhere, no roots,
`K = {s1, s2, s3}` — a live entity inside a condemned component. The
question is which gate catches it, by cases on where m1–m3 fall:

- **Migration completes before the re-check** (the trace above).
  Re-check re-reads the recorded edge source `s1.f2` → **null** → a
  moved edge acquits `K` whole. Even if every count re-reads unchanged
  (`rc(s3)` is 1 again after m2), the edge re-read cannot miss: m2
  precedes the re-check by assumption. ✓
- **Any migration step lands between condemn and the byte re-read.**
  m1 and m2 are retain/release on X, m3 a release on A — each clears
  the member's condemned byte, and the re-check reads bytes *last*.
  A cleared byte acquits `K`. ✓
- **Migration entirely after the re-check.** Unreachable, not merely
  caught: the dangerous walk needs `crc[s1] = 1`, which requires m3
  before the walk read — and m2 < m3 always (m2 needs the frame to
  still reach A). So "migration after the re-check" contradicts the
  condemnation it presupposes: with the migration late, `crc[s1] = 2`,
  A is a root, and no component containing these slots exists. The
  orderings pinch. ✓
- **Everything slips through to a post** (the document's "residue"):
  Phase 4 exact test on the mutator's thread: `rc(s3) = 1`,
  `indeg_K(s3)` from *current* fields `= 0` (m2 nulled it) →
  mismatch → message dropped before any destructor. ✓

**The windows dovetail with no gap**: evidence before condemnation
survives in counts and edges (re-check recomputes both); evidence
after condemnation survives in the byte (read last); whatever a racy
re-check could in principle miss dies at the exact test, which runs
race-free. This is the "window algebra" the review demanded, replayed
concretely.

**Where it turns into a kill.** Remove the count/edge re-read and the
exact test — the first draft's `byte_only` — and a live entity is
confirmed and freed: T4 violated, use after free.

**Mechanization postscript.** The "dangerous walk" as stated above is
in fact **unreachable**: the walk reads a slot's count before its
fields, so recording the `s1→s3` edge before m2 forces `crc[s1]` to
be read before m3 — `crc[s1] = 2`, A roots, no component forms. The
case analysis above is still the right gate map for the shapes that
do reach condemnation (borrow without null, where the count re-read
is the catcher), but the trace that actually defeats `byte_only` is
different and was found by TLC, not by hand: stale count masked by
freshly stored self-loops — **DC1** in
[rc-walk-danger-cases.md](rc-walk-danger-cases.md), machine-minimal
at 15 actions.

### Findings

- **F6 — the Phase 3 filter is stronger than the document claims, for
  this shape.** [rc-walk.md](rc-walk.md) concedes a "residue — a touch
  after the ack whose effects the racy re-read happens to miss". For
  the migration shape the hand analysis finds no such residue: the
  orderings pinch (m2 < m3, the dangerous walk needs `crc[s1]` after
  m3, bytes are read last), so every interleaving is caught by
  Phase 3 already and the exact test never sees a live member here.
  Not a bug — the conservative claim is safe — but whether *any* shape
  produces a false post in the current design is exactly the kind of
  question hand analysis cannot close and the model checker can.
  Deferred to the TLC run.

## Scenario 6 — variant `non_total`: skipped row, recorded edge

**Shape.** Garbage cycle `s1↔s2` via `f1` (as scenario 1);
`s2.f2 = s3` (X), and frame slot 1 holds X: `rc(s3) = 2`.
`R* = {s3}`. Variant: X's class is acyclic-flagged, and the broken
walker omits X's `crc` row while still recording the edge `s2→s3`.

**Replay.** Walk: rows for `s1, s2` (both 1), edges `s1→s2`, `s2→s1`,
`s2→s3`, no row for `s3`. Diff: `in[s3] = 1` against an absent row
read as 0 → `0 − 1 = −1 < 0` → X is a **non-root by arithmetic
error** — T1's corollary, reproduced. No roots at all, so
`K = {s1, s2, s3}`: a live, frame-held entity condemned
(`cb(s3) := 1` written onto a live object). The policy is consistent,
so the re-check reproduces the same omission and confirms; `K` is
posted.

**Phase 4**: exact test reads the *real* count: `rc(s3) = 2` against
`indeg_K(s3) = 1` → mismatch → message dropped whole. X survives; the
legitimate garbage A, B is acquitted with it and waits another epoch.

### Findings

- **F4 — `non_total` does not violate T4 in the current design; the
  task's expectation is wrong as stated.**
  [../../dev/TASK-rc-walk-proof.md](../../dev/TASK-rc-walk-proof.md)
  groups this variant with the unsafe ones, but the exact test is
  policy-independent — it reads real counts and current fields, so a
  row/edge mismatch upstream costs a false post and collateral recall
  (the garbage riding in the same component is acquitted too), never a
  free. The unsafe demonstration requires compounding with `byte_only`
  (**DC2**). Two corollaries worth recording: (a) the walk-level rule
  "omission must be total" is a *precision* rule in the final design,
  promoted to a *safety* rule only if Phase 4 is ever weakened; (b) a
  negative `RC − IN` is not per se a bug signature — the sound design
  reaches it transiently through duplicate-edge staleness (a reference
  read in both its old and new homes mid-migration), which is benign
  for the same reason.

## Scenario 7 — variant `no_defer`: slot identity across the epoch

**Premise.** A member of a posted component dies normally between
confirmation and drain — the document itself contemplates this
("a member that died since confirmation"). Scenario 5's analysis
(F6) could not construct a false post by hand, so this scenario runs
on the document's own premise rather than a hand-built trace; whether
the premise is reachable is a TLC question.

**Replay, current design (defer ON).** Falsely-posted X (`s3 ∈ K`)
migrates out (its recorded in-edge `s1.f2` was nulled by m2) and then
dies: `drop(fr2)` → `rc(s3) = 0` → teardown, destructor runs,
`DESTRUCTOR_RAN` set, slot **parked**. Drain arrives: exact test on
`s3` reads `rc = 0` against `indeg_K(s3) = 0` (the in-edge is null) —
**`0 = 0` balances**, the member passes as garbage. Guard writes
`rc(s3) = 1` into a parked slot; destructor skipped
(`DESTRUCTOR_RAN`); sever finds fields null; un-guard → `rc = 0` →
the ordinary free path runs **a second time** → the slot is queued to
the deferred list twice → after the flush the free list hands the
same slot to two allocations. Heap corruption in the current design.

- **F5 — the exact test's death-acquittal defense is vacuous, not
  merely holed** (sharpened by the independent review pass).
  [rc-walk.md](rc-walk.md) claims "occupancy rides free: a member that
  died since confirmation reads count zero against an in-degree of at
  least one, and the mismatch acquits". Under I1 the "at least one" is
  **impossible for every dead member, migration or not**: a member
  field currently pointing at `e` is a counted reference, so `e` with
  such an in-edge cannot have died; and a dead member's own fields
  were nulled by its ordinary teardown. Every member dead at drain
  time therefore reads `rc = 0` against in-degree 0 — the advertised
  mismatch can never fire, and `0 = 0` always balances. The fix is one
  clause: a member reading `rc = 0` (or non-live occupancy) acquits
  the component regardless of balance; equality may only confirm on
  live members. The concrete double-teardown remains conditional on a
  false post being reachable (open, see F6), but the *defense as
  written defends nothing*.

**Replay, `no_defer` variant.** Same trace, but the dead slot is
recycled before the drain: a live Y now occupies `s3`
(`rc = 1`, frame-held). Exact test: `rc(s3) = 1` vs `indeg_K = 0` →
mismatch → acquitted — by luck, because a frame ref never balances.
The kill needs the slot still on the free list at drain time
(`0 = 0` balances as above): guard then writes `rc = 1` into a
**free-listed** slot while the allocator may hand it out
concurrently — two owners of one slot (**DC3**). And if the recycled
occupant is judged by coincidence, its destructor runs unjudged. I3
is what makes all of this unreachable: an id names one entity from
walk to drain.

## Scenario 8 — variant `no_sever`: the immortal cycle

**Replay.** Scenario 1's shape and trace through step 15, with the
guard-aware re-verify (F1's fix assumed, else nothing frees anyway).
Skip the sever: un-guard releases bring `rc(s1), rc(s2)` from 2 to 1 —
each member still held by the other's field — no zero, no teardown,
no free. The component's slots stay live-looking; next epoch walks
them, finds them unchanged, condemns, confirms, posts, drains,
balances, guards, un-guards — forever (destructors excepted:
`DESTRUCTOR_RAN` gates them to the first pass). **A pure cycle is
never freed and the guard/verify/un-guard pipeline re-runs every
epoch for it**: recall failure plus unbounded repeated work, no
safety violation (**DC4**). This is the
review's finding 2 replayed; severing is the price of validating with
real counts instead of trial-deleted ones.

Note for the test harness: F1 unfixed (guard-blind re-verify) and
`no_sever` produce the *same observable* — nothing is ever freed — so
a test that only asserts "cycle eventually freed" cannot tell them
apart; the traces differ at step 15 (acquit at re-verify) versus
step 18 (un-guard to 1).

## Scenario 9 — variant `uncounted`: the borrow the counts cannot see

**Shape.** Scenario 5's shape, but the compiler elided the retain:
`fr2 := s1.f2` binds X to a frame slot **without** touching
`rc(s3) = 1` or the condemned byte. Then m3 drops the cycle.
`R* = {s3}` — X is live through `fr2`. I1 is violated from this
moment: two references, count of one.

**Replay.** The walk needs no staleness at all: `crc[s3] = 1`,
edge `s1→s3` recorded (never nulled — nothing rewrote the field),
`crc[s1] = 1` after m3 → `K = {s1, s2, s3}` condemned. Re-check:
nothing changed — the borrow performed no retain, no release, no byte
clear; counts, edges and bytes all re-read identical → confirmed,
posted. Exact test: `rc(s3) = 1 = indeg_K(s3) = 1` — **balances**,
because the frame's reference is exactly the one that was never
counted. Guard, destructor of X runs, sever, free: **X is freed while
`fr2` points at it** (**DC5**). Every gate passed honestly; the
violated premise was I1 itself, upstream of the collector.

### Findings

None new — this is the designed-in exclusion
([rc-walk-model.md](rc-walk-model.md) §10) demonstrated end-to-end:
no count-based test can defend against an uncounted reference, which
is why "an elided borrow must be covered by a counted root" is a
compiler obligation
([static-lifetimes.md](../memory/static-lifetimes.md)), and why the
checker must include this variant to prove it *notices* I1 breakage
rather than assuming it.

## Scenario tally

| # | Scenario | Verdict | Findings |
|---|---|---|---|
| 1 | pure garbage cycle, quiet mutator | freed once, safely | F1, F2, F3 |
| 2 | live cycle, touched mid-walk | never condemned | — |
| 3 | ordinary death mid-epoch | leak-ward only; I3 holds | — |
| 4 | allocation mid-epoch | allocate-black holds | — |
| 5 | reference migration | caught at Phase 3 in every interleaving; Phase 4 as backstop | F6 |
| 6 | `non_total` | negative root reproduced; T4 holds via exact test | F4 |
| 7 | `no_defer` (+ current-design hole) | `0 = 0` double-teardown; free-list corruption | **F5** |
| 8 | `no_sever` | immortal cycle, unbounded rework | — |
| 9 | `uncounted` | live entity freed, all gates pass honestly | — |

## TLC scenario battery (run 2026-07-26)

Mechanical check of the replay: the spec (`dev/tools/rc-walk/RcWalk.tla`,
TLC 2.19) plays each actor's alphabet with the mutator bound to a fixed
per-scenario script; the only nondeterminism is where the mutator's
steps land between collector micro-steps — the collisions, not
free-play. The Phase 4 drain is phased (test → guard → destructor
steps → guard-aware verify → sever/free) so destructor scenarios are
expressible; the guard is a real `+1` and I1 carries it as its own
term. All runs exhausted their state space (except where a violation
stops the search); every state count below is from the final battery,
and every run finishes in 1–3 s wall clock.

| Run | Config | Expected | Result | Distinct states |
|---|---|---|---|---|
| self-loop kill | `byte_only` | frees live entity | **SafeHeap violated** ✓ | 5 509 |
| self-loop | sound | safe | pass, incl. `PostClean` | 5 852 |
| borrow (review's finding 1) | `byte_only` | frees live entity | **SafeHeap violated** ✓ | 819 |
| borrow | sound | safe | pass, incl. `PostClean` | 817 |
| migrate (null the old home) | sound | safe | pass, incl. `PostClean` | 1 235 |
| uncounted borrow | sound gates | frees live entity | **SafeHeap violated** ✓ | 520 |
| quiet | `no_sever` | cycle never freed | **liveness violated** ✓ | 321 |
| quiet | sound | garbage collected | pass (liveness) | 175 |
| held child | `non_total` | false post, no free | **PostClean violated** ✓ / SafeHeap passes ✓ | 299 / 300 |
| held child | `non_total` + `byte_only` | frees live entity | **SafeHeap violated** ✓ | 284 |
| borrow-drop | `OldDeath` (pre-F5-fix) | premise probe | pass — premise unreachable here | 1 352 |
| borrow-drop | current rule | safe | pass, full invariants | 1 352 |
| borrow-drop-alloc | `no_defer` + `OldDeath` | premise probe | pass — premise unreachable here | 1 603 |
| borrow-drop-alloc | `no_defer`, current rule | safe | pass, full invariants | 1 603 |
| garland (ring + linked self-ring) | sound, quiet | whole garland collected (weak grouping) | pass (liveness) | 183 |
| allocate-black (virgin slot filled mid-walk) | sound | newcomer never judged | pass, full invariants | 692 |
| destructor resurrects its member mid-drain | sound | re-verify acquits, member survives | pass, full invariants | 72 |
| destructor allocates mid-drain | sound (non-reentrant) | allocation served, no nested pickup | pass, liveness + invariants | 112 |
| destructor allocates mid-drain | `reentrant_drain` (F8 hazard) | nested pickup wedges collection | **liveness violated** ✓ | 832 |
| migrate-then-kill (child dies after its home is nulled) | sound | safe; probes the deferred-death drain half | pass, full invariants | 1 954 |
| **second home** (4 entities, 3 frame slots, 7-action migration through a second heap home — the audit's nearest-to-false-post shape) | sound | safe, no false post | pass, full invariants incl. `PostClean` | **35 202** |

One assertion was corrected while building the destructor rows:
`PostClean` originally said "a message never contains a reachable
entity", which the resurrection scenario legitimately violates
mid-drain — resurrection is what the re-verify exists for. It is
scoped to the queue-waiting phase: *the filter* never posts a live
entity; what a destructor then does to the posted member is the
drain's business.

Readings:

- **Every broken variant that must kill, kills**, each with a
  machine-minimal trace in `dev/tools/rc-walk/SC_*.out`. The
  `non_total` pair confirms F4 exactly: false post produced, no free.
- **The sound design passes every scenario with `PostClean`** — no
  live entity is ever posted in these scenarios, which closes **F6
  for these shapes**: the Phase 3 filter admits no false post here,
  so the F5/DC0 premise is unreachable in every scenario tried, under
  the old rule as well. F5's fix stands as defense in depth plus the
  vacuity correction; F6 in full generality would need the
  free-mutator exhaustion run (optional, expensive — a free-play run
  passed 30 M distinct states without exhausting before it was
  stopped).
- An earlier free-mutator run also killed `byte_only`
  (41 M states generated, depth 24, 10 min) with the self-loop trace
  now scripted as the first row — the free and scripted searches
  found the same kill.

## Independent review pass

An adversarial reviewer with fresh context audited scenarios 1–9,
findings F1–F6 and DC0–DC5 against the design documents, with the
instruction to refute. Verdicts: **F1–F5 confirmed** (F5 sharpened —
see its updated text; F2's memory-hold claim corrected to
duration-only), **F6 could not be refuted** after systematic attempts
(all walk-read permutations; extra borrows; a second heap home over a
fourth entity — which does place a live member in a condemned
component, with only the single edge-source re-read standing between
it and a post). Four trace errors were found and are fixed in place.
The pass also surfaced three new findings against the documents:

- **F7 — the store barrier's internal order is a defect in the model
  as written.** [rc-walk-model.md](rc-walk-model.md) §2 M3:
  "`retain(y)`, `release(x.f)`, then `x.f := y`". The release can
  reach zero and run an arbitrary destructor sequence *while `x.f`
  still points at the corpse*; since `x` is frame-held, that
  destructor may legally `load(fr, x.f)` — retaining an entity whose
  count is 0, violating I2 inside the model's own semantics (a
  use-after-teardown in the real system). The write of `x.f` must
  precede the release, or the release must be the action's last
  effect; neither document stated the requirement. **Fixed** in
  [rc-walk-model.md](rc-walk-model.md) §2 (M3 reordered:
  retain, write, release-last; emitting the order is a stated
  compiler obligation). The TLA+ spec already implements the fixed
  order.
- **F8 — drain re-entrancy is undefined.** M5's effect is "ack a
  pending handshake, drain a pending message"; an allocation inside a
  destructor that the drain itself is running is a checkpoint *inside
  the drain*. Whether the in-progress message counts as undrained
  (I6), and whether the nested checkpoint may re-enter it, is
  specified nowhere.
- **F9 — the external holder is promised but not in any alphabet.**
  [rc-walk-model.md](rc-walk-model.md) §1 replaces
  arenas/statics/immortals/FFI by "one external holder that takes and
  drops counted references"; §2 contains no holder actions, and by
  §2's own standard ("if an actor can do something not on its list,
  the enumeration proves nothing") the reduction "frame slots stand in
  for all external holders" must be stated and `F` sized with it — it
  currently is not.

**Model-fidelity notes from the pass** (constraints on what any
checker built from §2/§3 can show): the parked population is a *set*,
so DC0's double-enqueue is unrepresentable unless the checker carries
an explicit never-enqueued-twice assertion; the 3-value epoch collapse
cannot produce the wrap alias (leak-ward only, so sound for T4, but
the abstraction lemma's "strictly more permissive" is overstated
there); the "k reference fields" reduction cannot express the
array-storage-grow hazard [rc-walk.md](rc-walk.md) itself worries
about; scenario 3's straddle-mapping argument holds only for
destructor-free teardown.

## Resolutions (2026-07-26)

Every finding was resolved in one pass after discussion; the design
documents now carry the fixes, each stamped with this date.

| Finding | Resolution |
|---|---|
| F1 | re-verify discounts the guard (`rc − 1 = indeg`) — [rc-walk.md](rc-walk.md) Phase 4 |
| F2 | accepted limitation, premise made explicit in T5; no fallback mechanism |
| F3 | latency note, no change needed |
| F4 | task expectation for `non_total` corrected to "false post, no free" |
| F5 | superseded rule: a condemned entity never dies on the ordinary path — deferred to the drain, torn down exactly once; destructor-later is accepted semantics |
| F6 | open — closes with the TLC exhaustive run |
| F7 | M3 reordered (retain, write, release-last); compiler obligation stated |
| F8 | drain non-reentrant via allocator's own state |
| F9 | frame slots represent all external holders; §11 config corrected to `N = 3` heap entities |

Further decisions from the same discussion: Phase 2 groups by **weak
connectivity**; the masquerade window is closed by the **zeroed-slot-
headers invariant** (manager commissions blocks with zeroed headers;
factory publishes the header last, one 8-byte store) instead of being
screened; heavy checker runs are **fuel-bounded** (mutator limited to a
fixed action budget per epoch, the bound stated with every result).

## Second adversarial audit (2026-07-26, fresh context)

A second independent auditor attacked the amended design, the spec's
fidelity, and the battery's substance. Verdicts and what changed:

- **B1 (design-changing, confirmed and fixed): the acquittal duties
  ran on the wrong thread.** The same-day draft had the collector
  clear bytes and tear deferred deaths itself — destructors and
  releases on the collector thread, plus an unfixable byte-clear race
  minting permanently invisible zombies. **Resolution: an acquittal is
  a message too** — the owning thread's checkpoint performs both
  duties, race-free; every condemned component now ends in exactly one
  mutator-side message, and the collector's shared-memory writes are
  back to stamps and condemnation bytes (I5 restored). Design, model
  (I6) and spec all updated; the battery re-ran green through the
  message path.
- **A8 (design-changing, confirmed and fixed): the allocate-black skip
  was not total.** Child validation tested occupancy but not maturity,
  so an edge into a mid-epoch newcomer or reused slot was recorded
  while its row was skipped — `0 − 1 < 0` inside the sound design.
  **Resolution: the epoch-byte clause** — an edge is recorded only if
  the target reads an older epoch. Design and spec updated.
- **Re-check filter canonised**: the document described two
  non-equivalent filters in one sentence (recompute `RC − IN` vs
  any-change-acquits). Snapshot comparison is now canon — simpler,
  strictly more acquittal-prone, and the filter the battery actually
  verified.
- **Battery substance fixes**: the two runs named after F5 provably
  explored identical graphs (nothing died in their script) — a
  migrate-then-kill scenario was added; the audit's 4-entity
  near-false-post shape was inexpressible in a 3-slot spec — the spec
  now has 4 slots and 3 frame slots, and that exact shape **passed
  exhaustively (35 202 states, all invariants)**, the strongest F6
  evidence to date; every sound configuration now checks the full
  invariant set (the earlier liveness configs checked none), plus
  `I4Virgin`.
- **Honest limits the audit put on record, still standing**: all
  results are sequential-consistency results — the design's relaxed
  atomics and its one fence are not modelled; the destructor alphabet
  is two bodies on one slot, far narrower than the model's "arbitrary
  M-sequence", so the abstraction lemma does not hold for the spec;
  re-entrancy is modelled as message theft (liveness kill), while real
  re-entrancy could also resume the outer drain over a torn message —
  a safety shape the spec understates; DC0's "never enqueued twice"
  has no spec counterpart (the parked population is a set); ordinary
  cascade deaths run no destructor in the model.

**Unreplayed scenarios the pass accepted as gaps** (open items for
the checker or a later pass): a destructor that resurrects a member
during the drain; a destructor that *allocates* during the drain
(F8's shape); a member with edges into a second component (the
component-grouping rule is underdetermined in the design); self-loops
and duplicate edges from one source; the init-window masquerade —
garbage bytes in a carved-but-uninitialized slot fabricating a row
and phantom edges, which can reproduce scenario 6's
row-absent/edge-present shape *inside the sound design*.
