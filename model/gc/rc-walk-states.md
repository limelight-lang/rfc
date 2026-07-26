# rc-walk — state-space accounting

> **Status: paper accounting, nothing run.** This document instantiates
> the state vector of [rc-walk-model.md](rc-walk-model.md) §3 at the
> minimum configuration of §11, derives every factor's cardinality, and
> multiplies them out. Its purpose is to decide whether exhaustive
> checking is feasible and with what tool. Every number here is derived,
> not measured; the only number that matters — the count of *reachable*
> states — cannot be derived on paper and is explicitly not asserted.

## 1. Configuration

From [rc-walk-model.md](rc-walk-model.md) §11: `N = 4` entities,
`k = 2` fields, `S = 3` slots in one block, `F = 2` frame slots.

**One tension, flagged rather than fixed** (per the task's constraint
not to edit the model): §11 counts the external holder among the
`N = 4` entities, but §1 replaces arenas/statics/FFI by an external
holder that is *not* a heap entity — and the seeded shape (two-member
cycle + holder + child) needs four live entities if the holder is
heap-resident, which does not fit `S = 3` slots. The counts below take
the §1 reading: the holder lives outside the heap, at most 3 entities
are live at once, and `N = 4` bounds entity identities over time
(slot reuse). If the holder must be heap-resident, `S = 4`; the last
section shows what that costs.

## 2. The factors

### Per slot (×3)

| Component | Values | Count |
|---|---|---|
| occupancy | virgin, live, free, parked | 4 |
| refcount | `0..R`; by I1, `R = F + S·k + guard = 2 + 6 + 1 = 9` | 10 |
| epoch byte | 0, current, old (§3 collapse) | 3 |
| condemned | 0, 1 | 2 |
| fields | `(slots ∪ {null})^k = 4²` | 16 |

Per slot: `4 · 10 · 3 · 2 · 16 = 3 840`.
All slots: `3 840³ = 56 623 104 000 ≈ 5.7 × 10¹⁰`.

### Frame

A multiset of at most `F = 2` references over 3 slots:
`1 + 3 + 6 = 10`.

### Memory manager `A`

| Component | Count |
|---|---|
| free set ⊆ slots | 8 |
| parked set ⊆ slots | 8 |
| epoch flag (idle / in flight — the §3 three-value collapse leaves nothing more to distinguish) | 2 |

Total: `8 · 8 · 2 = 128`.

### Collector `C`

Phases from [rc-walk.md](rc-walk.md): idle, walking, condemning,
awaiting ack, re-checking, posted, flushing — 7 program-counter values.

| Component | Values | Count |
|---|---|---|
| phase | above | 7 |
| snapshot cursor | `0..S` | 4 |
| walk position | `0..S` | 4 |
| `rc[]` | per slot: absent or `0..9` → `11³` | 1 331 |
| `edges[]` | per (source, field): unrecorded, null, or one of 3 slots → `5⁶` | 15 625 |
| candidate set ⊆ slots | | 8 |
| posted message | none, or a nonempty subset (I6: at most one outstanding) | 8 |

Total: `7 · 4 · 4 · 1 331 · 15 625 · 8 · 8 = 149 072 000 000 ≈ 1.5 × 10¹¹`.

## 3. The raw product

```
5.66 × 10¹⁰  (slots)
×        10  (frame)
×       128  (A)
× 1.49 × 10¹¹ (C)
≈ 1.1 × 10²⁵
```

This is the naive upper bound: every combination of every factor. It is
astronomically loose, and its only use is honesty about what "the state
vector is finite" means before structure is applied.

## 4. What structure removes — on paper

These collapses are identities of the model, not search heuristics; each
removes a factor from the *reachable* count exactly.

1. **I1 makes the refcount derived.** In any state satisfying I1,
   `refcount = frame refs + field refs + guard` — a function of the
   pointer configuration, not a free variable. Removes the `10³`
   refcount factor. (Broken variants that violate I1 re-open it, but
   only along the violating trajectory.)
2. **Occupancy duplicates `A`'s sets.** The free set *is*
   `{s : occupancy(s) = free}`, the parked set likewise. Removes the
   `8 · 8` factor.
3. **Non-live slots hold nothing.** Fields of virgin/free/parked slots
   are null (I2 + teardown nulling), and their epoch/condemned bytes are
   never tested. A non-live slot has ~1 state per occupancy value, not
   96. Per-slot factor falls from 3 840 to `16·3·2 + 3 = 99`.
4. **`C`'s state is phase-gated.** `rc[]`, `edges[]`, cursor, walk
   position, candidates and the message are only populated in the phases
   that write them, and `rc[]`/`edges[]` can only hold values the walk
   actually read from some earlier heap state — a set no paper argument
   can count, because it is exactly the interleaving structure.

After collapses 1–3 the heap-side product (slots × frame × epoch flag)
is `99³ · 10 · 2 ≈ 1.9 × 10⁷`. Multiplying by the *uncollapsed* `C`
bound gives a post-structural ceiling of `≈ 2.9 × 10¹⁸`.

## 5. The bracket, and why only a run closes it

```
heap-side alone:            ~2 × 10⁷      (hard floor of the product)
post-structural ceiling:    ~3 × 10¹⁸     (collapse 4 not applied)
reachable states:           unknown — the checker's to report
```

The gap between floor and ceiling is entirely collapse 4: how many
distinct `(rc[], edges[])` snapshots the interleavings can actually
produce. That is not computable by counting; it *is* the enumeration.
Explicit-state model checkers handle `10⁷–10⁹` states routinely; whether
reachability lands inside that window is the feasibility question, and
no number in this document answers it.

Two levers if it does not:

- **Symmetry over slot ids.** Sound only because §1 already replaces
  address-order walking by an arbitrary permutation — the spec is then
  invariant under slot renaming. Divides by up to `S! = 6`.
- **Seeding** (per the task): start from the interesting shape instead
  of the empty heap. Shrinks the explored region and weakens the claim
  to "for this shape" — which the proof document must then say.

## 6. Sensitivity: the heap-resident holder

If the §11 reading wins and the holder occupies a slot (`S = 4`,
`R = F + S·k + 1 = 11`): per-slot factor
`4 · 12 · 3 · 2 · 25 = 7 200`, all slots `7 200⁴ ≈ 2.7 × 10¹⁵` —
the slot factor alone grows by ~4.7 × 10⁴. Growth in `S` is steep;
the configuration choice is not cosmetic and the checker must report
counts for whichever is run.

## 7. Consequence

The bracket is wide enough that feasibility must be established by
running, and the three traps recorded in the task (depth-bounded
memoisation, tight bounds, seed cost) are all artifacts of hand-rolled
depth-first search. A finite state space wants full breadth-first
exploration with sound deduplication and no depth bound at all — which
is what an off-the-shelf explicit-state checker (TLC) does, producing
minimal counterexample traces as a side effect. The tool decision and
the work plan live in
[../../dev/TASK-rc-walk-proof.md](../../dev/TASK-rc-walk-proof.md).
