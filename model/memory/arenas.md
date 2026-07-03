# Memory Arenas

## Concept

Limelight uses arena-based memory allocation. An arena is a contiguous memory region with bump-pointer allocation. Objects allocated in an arena are freed together when the arena is reset or destroyed — no per-object bookkeeping required.

The number and types of arenas is not fixed. The architecture supports multiple arenas with different lifetimes and strategies.

---

## Object Categories by Memory Strategy

| Category | Arena | RC Strategy |
|---|---|---|
| Immortal | Global | None — immortality flag, all retain/release ignored |
| Long-lived | Long-lived arena | Minimal RC or explicit free |
| Request-scoped | Request arena | None — entire arena reset at end of request |
| General | GC heap (Immix) | Deferred ARC + Biased RC + escape analysis |

---

## Request Arena

Most PHP objects are created and die within a single request. These objects are allocated in the request arena:

- Bump-pointer allocation — no locking, no free-list, ~1–3 cycles per allocation
- No reference counting during the request — objects are assumed live until the arena is reset
- At end of request: reset the arena pointer — O(1) reclamation of all request-scoped memory
- Destructors that have side effects must still be tracked and called before the reset

This is the dominant allocation path for typical PHP workloads.

## Long-Lived Arena

Objects that outlive a single request but are not immortal: class definitions, interned strings, opcode caches, shared data structures. These are allocated in a long-lived arena with a separate lifecycle from the request arena.

Exact reclamation strategy (explicit free, reference counting, or epoch-based) is TBD per object type.

## Immortal Objects

Objects that never die: `null`, `true`, `false`, small integers, permanently interned strings. Allocated once, never freed. All retain/release operations on these objects are no-ops checked via an immortality flag in the object header.

---

## Relationship to GC

The GC (Immix + MMTK) operates only on the **general heap** — it never scans or collects request arena or long-lived arena objects. This dramatically reduces GC pressure: most objects (request-scoped) are invisible to the GC entirely.

---

## Cross-Arena References

**Decision**: every reference store is a **category barrier**. When a
reference to entity S is stored into a longer-lived container D (object
slot, array element, captured variable), the memory categories of the two
are compared — 2 bits in each flags word, one XOR + test, and the flags
are already loaded by retain. Same category (the overwhelmingly common
case): no extra work. Different categories: escape handling.

### The dangerous direction: longer-lived ← shorter-lived

A heap or long-lived object storing a reference to a request-arena object
would dangle after arena reset. **Primary strategy — deferred promotion**:
the barrier only logs the referencing slot into the arena's **remembered
set**; the fate of escaped objects is decided lazily at arena death — few
survivors are evacuated, many survivors keep their blocks. The full
algorithm, including why no statepoints are needed and how identity is
preserved, is specified in [arena-reset.md](arena-reset.md).

**deepCopy at the barrier** remains as the eager variant for value-like
data (COW strings/arrays), where copying is natural and reference identity
is not observable.

### The reverse direction: request arena ← heap

Not a dangling problem but a leak: arena reset skips per-object drop
(phase 2 of [object-lifecycle.md](../../runtime/object-lifecycle.md)), so
the heap entity's refcount is never decremented. The same barrier covers
it: storing a heap reference into an arena container logs the heap entity
into the arena's *release-at-reset* list.

### Relationship to escape analysis

The barrier is the runtime backstop, not the primary mechanism: escape
analysis should allocate objects that provably escape the request directly
in the heap or long-lived arena, so the barrier's slow path stays rare.
