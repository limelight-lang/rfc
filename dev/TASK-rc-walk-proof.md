# Task — model-check rc-walk with TLA+/TLC

> **Status: DONE (2026-07-26).** Every deliverable shipped: the spec and
> configs in `dev/tools/rc-walk/` (run, `tla2tools.jar` vendored), all
> five broken variants killed with traces plus the reentrant-drain kill,
> the 22-run battery and its limits in
> [../model/gc/rc-walk-proof.md](../model/gc/rc-walk-proof.md), README
> and INDEX entries, linkcheck clean. Follow-on: the danger cases now
> have runtime embodiments — see the status note in
> [../model/gc/rc-walk-danger-cases.md](../model/gc/rc-walk-danger-cases.md).
> Kept as the brief for re-running or extending the battery (relaxed
> memory, wider destructor alphabet — deferred until design freeze).

> A standalone brief. Hand this to a fresh session; it needs no other
> context than the documents it names.

## What exists

- [../model/gc/rc-walk.md](../model/gc/rc-walk.md) — the collector being
  checked.
- [../model/gc/rc-walk-model.md](../model/gc/rc-walk-model.md) — **the
  specification for this task.** §2 gives each actor's complete action
  alphabet, §3 the state vector and its finiteness, §4 the ground-truth
  oracle, §5 the invariants I1–I6, §6 the theorems, §11 the minimum
  configuration.
- [../model/gc/rc-walk-states.md](../model/gc/rc-walk-states.md) — the
  state-space accounting: factor cardinalities, the raw product
  (~10²⁵), the structural collapses, the feasibility bracket, and the
  §11 configuration ambiguity (heap-resident holder or not) that the
  spec author must resolve and record.
- [../model/gc/rc-walk-review.md](../model/gc/rc-walk-review.md) — the
  failures the earlier design had; the five variants below come from it.

## What to build

A TLA+ specification of the three actors over the bounded
configuration, model-checked exhaustively with TLC. The spec carries
`R*` (reachability from frame slots) as a defined operator — TLA+ has
transitive closure natively, which is why TLC was chosen over
SPIN/Promela — and states T4 and I1–I6 as invariants checked on every
reachable state.

Spec and TLC configs live under `dev/tools/rc-walk/`. Toolchain: Java
(19.0.1 verified present on the working machine) plus `tla2tools.jar`;
pin the jar version in the directory's README.

Fallback: if TLC cannot close the state space at the needed
configuration even with symmetry and seeding (see
[rc-walk-states.md](../model/gc/rc-walk-states.md) §5), fall back to a
bespoke enumerator in Rust beside `ll-model` — but on measured state
counts from real TLC runs, not taste.

## The rule that governs the whole task

**A checker that reports "no violations" proves nothing until it has
been shown to catch violations that are really there.** A mis-transcribed
alphabet or a too-weak invariant produces a green run in TLA+ exactly as
it does in hand-rolled code. So the order of work is fixed: first make
the spec catch known-broken protocols, then and only then run the
current design.

Implement the protocol variants as spec constants (one `CONSTANT` flag
per variant, default off) and produce a concrete counterexample trace
for each:

1. **`byte_only`** — Phase 3 as the first draft had it: condemn, re-read
   the condemned byte, free on that alone, no Phase 4 exact test. Must
   free a live entity (the reference-migration shape).
2. **`non_total`** — an edge into an entity recorded while its `rc[]`
   row is omitted. Expectation (corrected 2026-07-26 after the replay
   proved the exact test catches this solo): must produce the
   `0 − 1 < 0` negative-derived-root **false post** — a live,
   frame-held entity inside a posted component, with the co-condemned
   real garbage acquitted alongside it — and **no free**. The unsafe
   free requires compounding with `byte_only` (DC2 in
   [../model/gc/rc-walk-danger-cases.md](../model/gc/rc-walk-danger-cases.md)).
3. **`no_defer`** — slots reusable during an epoch. Must produce the
   identity failure I3 exists for: an exact test that balances by
   coincidence on a recycled slot.
4. **`no_sever`** — Phase 4 un-guards without severing intra-component
   edges. Must show a pure cycle that is never freed. This is a recall
   failure, not a safety one — a liveness property, checked under
   fairness, not an invariant; report it as such.
5. **`uncounted`** — an action that binds a frame slot without a retain,
   violating I1. Must free a live entity. Expected to fail: the point is
   that the checker notices, since the mitigation is a compiler
   obligation ([../model/memory/static-lifetimes.md](../model/memory/static-lifetimes.md),
   "What may own a borrow").

Only after all five produce traces does the current design get run.

## What TLC settles, and what it does not

A first hand-rolled attempt at this checker (thrown away, not in the
repo) reported "no violation" for variant 1 — false, for three reasons
recorded at the time: depth-bounded memoisation hiding states, a depth
bound with no slack, and the cost of building the interesting shape from
an empty heap. The first two are artifacts of depth-first search under a
bound and **do not exist under TLC**: the state space is finite by
[rc-walk-model.md](../model/gc/rc-walk-model.md) §3, TLC explores it
breadth-first to exhaustion with sound deduplication and no depth bound,
and its counterexamples are minimal.

What TLC does *not* settle:

- **Spec fidelity.** The five variants above are the only defence
  against a spec that quietly diverges from the model. There is no
  shortcut past them.
- **Seeding still applies.** If the full space proves too large, an
  `Init` predicate seeding the interesting shape — a two-member garbage
  cycle, an external holder, and a child referenced from inside the
  cycle — shrinks the run at the cost of the claim becoming "for this
  shape". Say so in the proof document, and list which shapes were run.
- **Slot-order reachability.** For variant 1 the collector must read the
  child's refcount *before* the mutator borrows it, and the holder's
  fields *after*. The model walks in an arbitrary permutation (§1), so
  the ordering is reachable regardless of slot numbering — but if the
  spec fixes a walk order for state-count reasons, check that the
  numbering still admits the trace. Symmetry reduction is sound only
  while the walk order stays an arbitrary permutation
  ([rc-walk-states.md](../model/gc/rc-walk-states.md) §5).

## Deliverables

- The spec and configs in `dev/tools/rc-walk/`, actually run.
- `../model/gc/rc-walk-proof.md` — what was enumerated, the five
  counterexample traces written out action by action, what the current
  design produced, the state counts and wall-clock from real TLC runs,
  and an explicit list of what the enumeration does **not** establish:
  the §10 exclusions, plus whatever the configuration leaves out (more
  entities, more fields, other seeded shapes, liveness properties not
  checked).
- One-line entries in `../model/gc/README.md` and [INDEX.md](INDEX.md).
- `php dev/tools/linkcheck.php` clean.

## Constraints

- Every number reported comes from a run. Anything not run says so in
  those words.
- Do not edit `rc-walk.md`, `rc-walk-model.md` or `rc-walk-review.md`
  beyond adding a cross-link. If the enumeration contradicts something
  they claim, write the contradiction into `rc-walk-proof.md` rather than
  quietly fixing the other document.
- Write to disk early and iterate in place. A broken spec on disk beats
  a finished one held back.
- A green run is the least trustworthy outcome in this task. If nothing
  is found, report why it might be finding nothing: alphabet
  incomplete, invariant too weak, shape too special, variant flag not
  actually wired into the transition it claims to break.
