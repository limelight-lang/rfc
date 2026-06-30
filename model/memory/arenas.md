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
