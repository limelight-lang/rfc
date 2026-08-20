# rc-walk — danger cases for the adversarial test harness

> **Status: derived from scenario replay** in
> [rc-walk-proof.md](rc-walk-proof.md). Each case is a concrete trace
> that kills a specific defense (or the current design — DC0). These
> are the seeds for the adversarial tests of
> [rc-walk-review.md](rc-walk-review.md) "How to test it", layer 3: a
> test *forces* the trace's timeline with injected delays and asserts
> the stated outcome. A checker or test suite that cannot reproduce
> every one of these has not earned a green run.

Notation as in [rc-walk-proof.md](rc-walk-proof.md). Shapes reference
the minimum configuration: slots `s1..s3`, fields `f1, f2`, frame
`fr1, fr2`.

> **Runtime coverage as of build step 2** (2026-07-26, `ll-model`
> `src/walk.rs`, commit `96dd965`): the synchronous embodiments exist —
> DC1's arithmetic seed (`self_edges_do_not_mask_an_external_reference`),
> DC2's sound half (`an_unwalked_holder_roots_its_gc_heap_child`), DC5's
> runtime witness (`a_self_loop_is_collected`, doc-noted), and DC4 as a
> recorded revert-check (severing disabled → the pure-cycle test fails).
> The full DC1/DC2 kills (stale reads, `byte_only`), DC0 and DC3 need
> condemnation and mid-epoch allocation — they become forceable, and
> owed, at build step 3.
>
> **Runtime coverage as of build step 3** (2026-07-26, `ll-model`
> `src/collector.rs` / `src/epoch.rs`): the forceable timelines are
> forced against the **sound** design — the collector's walk is split
> into a count pass and a field pass precisely so a test can interleave
> mutator actions in DC1's window. Covered:
> `dc1_a_stale_count_masked_by_self_loops_is_caught_twice` (the
> machine-found 15-action trace, caught by the Phase 3 count re-read
> and, driven past the filter, by the Phase 4 exact test —
> independently); `dc0_a_death_while_condemned_confirms_balanced_and_`
> `tears_once` (the `0 = 0` confirm, exactly-once probed through the
> free list) plus the acquittal half
> (`an_acquittal_tears_deferred_deaths_and_clears_the_rest`);
> `dc3_a_deferred_death_keeps_its_slot_out_of_circulation` (the premise
> is unreachable: a deferred death never touches the free list before
> its drain). The **kills themselves** — a broken variant freeing a
> live entity — stay the TLC battery's job by design: in a real heap a
> use-after-free has no deterministic observable to assert on, so a
> runtime kill test would be a flake generator, not evidence.

## DC0 — dead member balances `0 = 0`: double teardown (CURRENT DESIGN)

*From scenario 7, finding F5. The only case in this file that targets
the design as written, not a stripped variant.*

- **Premise:** a posted component contains a member that migrated out
  (its recorded in-edge nulled) and then died normally before the
  drain. Reachability of the premise is open (F6) — the test should
  force it directly by constructing the message.
- **Trace:** member `s3`: `rc = 0`, parked, `DESTRUCTOR_RAN` set,
  fields null; its in-edge `s1.f2 = null`. Drain: exact test reads
  `rc(s3) = 0 = indeg_K(s3) = 0` → balances → guard `rc := 1` →
  destructor skipped → sever no-op → un-guard `rc := 0` → ordinary
  free path runs **again** → slot enqueued to the deferred queue a
  second time.
- **Assert:** a slot is never enqueued for free twice.
- **Fix on record (2026-07-26, superseded):** a condemned entity never
  dies on the ordinary path — a release reaching zero on a condemned
  entity skips teardown and leaves the entity to the drain, which tears
  it down exactly once. Under that rule the premise state (dead,
  already-torn-down member inside a posted component) was unreachable.
- **Fix on record (2026-07-27, eager death — current):** the deferral
  is gone; every death tears down at the natural point and the corpse
  stays parked. The premise is now *reachable* and *harmless*: the
  drain header-scans every member first and **drops the message whole
  on any `rc = 0` member**, before tracing a field or writing a guard
  ([rc-walk.md](rc-walk.md), Phase 4, the corpse rule). The regression
  test flips accordingly: force the corpse into a posted component and
  assert the drain drops without touching it — no guard write, no
  second enqueue, survivors re-judged next epoch.

## DC1 — stale count masked by self-loops, under `byte_only`

*From scenario 5 and the TLC run. Kills: confirmation by
condemned-byte re-read alone (first draft's Phase 3), no exact test.*

**This trace is machine-found**: TLC's minimal counterexample
(16 states, `MC_dc1.cfg`), and it is *simpler* than the hand-built
migration — no migration at all. The trick: inflate `IN` to meet a
stale `RC` by storing self-edges between the count read and the field
reads.

- **Shape:** the standard seed — cycle `s1↔s2` (`f1`), `s1.f2 = s3`,
  `fr1 = s1`, `rc = 2, 1, 1`.
- **Trace (15 actions):**
  1. `load(fr2, s1.f1)` — fr2 borrows `s2`, `rc(s2) = 2`
  2. `drop(fr1)` — `rc(s1) = 1`
  3. `store(s2.f1, fr2)` — **self-loop**: releasing the old value
     `s1` kills it, cascading to `s3`; now `s2.f1 = s2`,
     `rc(s2) = 2` (fr2 + self)
  4. epoch triggers; walk skips the free `s1`, `s3`; reads
     `crc[s2] = 2`
  5. `store(s2.f2, fr2)` — **second self-loop**, `rc(s2) = 3`,
     between the count read and the field reads
  6. walk reads `s2.f1 = s2`, `s2.f2 = s2` — two recorded self-edges
  7. diff: `crc[s2] − in[s2] = 2 − 2 = 0` → non-root →
     `K = {s2}`; the frame reference is exactly the masked term
  8. condemn `s2`; handshake; byte re-read: 1 (no touch since) →
     confirmed
  9. free `s2` → **freed while `fr2` holds it**
- **Assert (variant on):** T4 violated. In the sound design the count
  re-read catches it (`rc = 3 ≠ crc = 2`), and the exact test
  independently (`3 ≠ indeg 2`).
- **Reachability note (learned mechanizing this):** the hand-built
  migration variant of this kill — null the old home (`m2`) so the
  edge survives only in the snapshot — is **unreachable**: the walk
  reads a slot's count before its fields, so recording the edge before
  `m2` forces `crc[s1]` to be read before the drop and `s1` roots the
  component. Duplicate/self edges are the shape that actually defeats
  `byte_only`; tests should force this trace, not the migration one.

## DC2 — `non_total` compounded with `byte_only`

*From scenario 6, finding F4. Kills: total-omission rule, when Phase 4
is also absent. Alone, `non_total` costs a false post and collateral
recall, never a free.*

- **Shape:** garbage cycle `s1↔s2`, `s2.f2 = s3`, `fr1 = s3`
  (`rc(s3) = 2`, live). Walker policy bug: no `crc` row for `s3`, but
  the edge `s2→s3` is recorded.
- **Trace:** diff reads absent row as 0: `0 − 1 = −1 < 0` → `s3`
  judged non-root, dragged into `K = {s1, s2, s3}`; policy-consistent
  re-check confirms; `byte_only` confirm frees `K` → **live,
  frame-held `s3` freed**.
- **Assert:** with full Phase 4, message dropped (`rc 2 ≠ indeg 1`) —
  the test asserts the false post and the collateral acquittal of the
  real garbage; with `byte_only` compounded, T4 violation.

## DC3 — slot recycled mid-epoch under `no_defer`

*From scenario 7. Kills: deferred-release queue (I3).*

- **Premise:** as DC0 — a posted `K` whose member `s3` died after its
  in-edge was nulled.
- **Trace:** `no_defer` frees `s3` to the free list immediately.
  Branch A (slot still free at drain): exact test balances `0 = 0`,
  guard writes `rc = 1` into a **free-listed slot** while the
  allocator may hand it out concurrently — two owners of one slot.
  Branch B (slot already recycled to a live, frame-held Y): acquitted
  by luck (`rc 1 ≠ indeg 0` — a frame ref never balances), showing
  the test must force branch A, not B, to demonstrate the kill.
- **Assert:** no drain action ever writes to a slot whose occupancy is
  free/virgin; no slot has two owners.

## DC4 — pure cycle under `no_sever`

*From scenario 8. Kills: the sever step. Recall failure, not safety.*

- **Shape:** scenario 1 (pure garbage cycle, quiet mutator).
- **Trace:** drain passes the exact test, guards, runs destructors,
  re-verifies (guard-aware), **skips sever**, un-guards: counts return
  to `1, 1` — each member still held by the other — no zero, nothing
  freed. Next epoch repeats the entire pipeline on the same component,
  forever.
- **Assert:** liveness under fairness ("garbage cycle untouched since
  snapshot is eventually freed") — fails. Plus the work assertion:
  the same component must not be posted in two consecutive epochs
  without a mutator touch in between.
- **Test-design note:** F1 unfixed (guard-blind re-verify) yields the
  same observable through a different step — assert *where* the drain
  bails, not just "nothing freed".

## DC5 — uncounted borrow

*From scenario 9. Kills: I1, the premise of everything. Expected to
defeat every gate; the point is that the checker notices.*

- **Shape:** DC1's shape, but the borrow is `fr2 := s1.f2` **without
  retain** — `rc(s3)` stays 1, no byte clear.
- **Trace:** m3 drops the cycle; the walk needs no staleness:
  `crc[s3] = 1`, edge `s1→s3` (never nulled), `crc[s1] = 1` →
  `K = {s1, s2, s3}` condemned; re-check sees nothing changed
  (the borrow left no trace anywhere); exact test balances
  (`rc(s3) = 1 = indeg 1` — the frame ref is exactly the uncounted
  one); destructor runs, sever, free → **use after free through
  `fr2`**.
- **Assert:** T4 violated with every gate passing honestly — the
  checker must detect the free of an `R*` member even though no
  protocol invariant flagged it earlier. Mitigation is the compiler
  obligation of [static-lifetimes.md](../memory/static-lifetimes.md#what-may-own-a-borrow),
  "What may own a borrow"; this case is the regression test that
  obligation must forever pass. The chain rule that amended it on
  2026-08-20 condemns this shape too, and by the same reading: `fr2` has
  no anchor chain, because m3 dropped the frame reference that would have
  been its root, so no counted in-edge reaches the path from outside
  ([gc-horizon.md](gc-horizon.md#the-ownership-lattice)).
