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

The request arena is the degenerate case of an **actor-owned arena**:
a request is an actor that receives one message and dies
([actors.md](../../runtime/actors.md)). Long-lived actors own arenas
with the same mechanics but repeated collection at message boundaries.
The same ownership machinery is available without the actor bundle as
`#[Region]` ([regions.md](regions.md)).

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

The category barrier is the strategy-independent layer of the **unified
store barrier slot** ([strategies.md](../gc/strategies.md)): the
compiler emits one hook per reference store, and the barrier composes
there with ARC operations and, in the `rc-satb` build, the SATB
deletion barrier ([satb.md](../gc/satb.md)). One door, not two.

### The dangerous direction: longer-lived ← shorter-lived

A heap or long-lived object storing a reference to a request-arena object
would dangle after arena reset. **Primary strategy — deferred promotion by
escape counting**: rather than remember the *slot*, the barrier counts the
*escape* on the escapee itself. Each request-arena object carries a
**hold-count** — how many longer-lived containers currently reference it —
kept in its otherwise-idle `refcount` field (arena objects are not
lifetime-counted). A store into a longer-lived container increments it
(the object joins the arena's escapee list on the 0 → 1 transition); an
overwrite, or the teardown of a holder, decrements it. Those two are the
**same event** — a slot let go of the escapee — so there is one decrement
rule, invoked from the store barrier and from holder teardown alike. At
arena death the escapees with a non-zero count are the survivors; their
fate is decided per 32 KB block — survivor-less blocks are freed, dense
blocks are retained in place, sparse blocks have their survivors
evacuated. The full algorithm, including why no statepoints are needed and
how identity is preserved, is specified in
[arena-reset.md](arena-reset.md).

**Why count the escapee, not remember the slot**: a remembered slot points
*into a longer-lived container*, which can itself die before the arena
resets. Reading that slot back at reset would dereference freed (and
possibly reused) memory — a use-after-free. Counting on the escapee
sidesteps it entirely: the count is kept truthful while every holder is
alive (a dying holder's own teardown does the final decrement), so reset
decides promotion from the count and **never dereferences a holder slot**.
The trade-off, accepted for now: only the count is kept, not *which* slots
hold the escapee, so an escapee cannot be **moved** — evacuation needs the
slots to fix references up. Back-pointers for evacuation are deferred until
evacuation and arrays are designed together (an array holder is many
elements, and its storage rehashes, so a per-slot back-pointer is both
expensive and unstable — the count is neither).

**deepCopy at the barrier** remains as the eager variant for value-like
data (COW strings/arrays), where copying is natural and reference identity
is not observable.

**Static vs dynamic resolution** ([arena-promotion.md](arena-promotion.md)):
when the compiler proves the escape within one function/scope, it
allocates the object directly in the target category up front — no
barrier fires at all. The barrier above is the dynamic fallback only:
origin unprovable (e.g. the object arrived as a parameter), so the check
happens at the store.

**Implementation note**: the escapee list lives **inside the arena's own
bump memory** ([buffers.md](buffers.md)), as an append-only list of the
escapee *entities* — not a separately-allocated structure, and not a list
of slots. It dies for free with the arena, exactly like the
destructor-tracking list. An escapee whose count returns to zero is simply
skipped at reset; a re-escape appends it again (harmless — the reset-time
subgraph mark deduplicates). The hold-count itself lives in each escapee's
`refcount`, not in the list.

**Completeness contract**: "the escape count is a complete registry
of external references" holds only because every reference store in
generated code goes through `ll_ref_store`. Native code at the FFI
boundary writes memory directly, past the barrier. The contract is
therefore: FFI/native code must either mutate managed containers
through the provided accessor API (which invokes the barrier
internally) or refrain from storing managed references into
longer-lived managed containers. Raw pointers handed *out* to native
code are the separate, already-covered case: such objects are pinned
and their blocks always retained ([arena-reset.md](arena-reset.md)).

### Between two request arenas: forbidden

The escape rule is really about **relative lifetime**, not "heap vs
arena": an escape exists whenever the holder outlives the value. Heap
and long-lived containers are just the always-longer case. A reference
from one request arena into a **different, longer-lived** request arena
is the same dangling hazard — and it is **not supported**.

Storing *within a single arena* is of course fine and is the common case
(`$node->next = $other`, both request-scoped): the two die together at
the same reset, no escape. What is forbidden is a store whose destination
slot lives in a *different* arena that outlives the source.

This is an **invariant, held by construction, not enforced by the
barrier**. The category barrier compares only the 2-bit category, so it
cannot tell one request arena from another — it treats every
`RequestArena → RequestArena` store as same-arena-safe. That is correct
only because cross-arena references do not arise: actor arenas are
isolated (actors share no direct references, only messages —
[actors.md](../../runtime/actors.md)), and there is at most one request
arena mounted per executing context. There is no scoped/nested request
arena that another can reference.

Why not simply extend the remembered set to cover it: the counting side
does not compose. A heap holder releases the promoted object through its
own refcounted teardown; an *arena* holder does not count references, so
it would have to acquire a release obligation for the promoted object,
and maintaining that obligation across overwrites and holder death
re-introduces exactly the dangling-record problem the remembered set
exists to avoid. Cross-lifetime arena references therefore need their
own design (an arena lifetime/depth order, and how a holder learns of a
promotion) — deferred until a feature actually requires them (nested
request scopes, fibers). Until then the invariant stands: **references
into a different, longer-lived arena must not be created.** Lifetimes of
any two arenas that *can* reference each other must be comparable
(nesting or isolation); partially-overlapping arena lifetimes are
likewise out of scope.

### The reverse direction: request arena ← heap

Not a dangling problem but a leak: arena reset skips per-object drop
(phase 2 of [object-lifecycle.md](../../runtime/object-lifecycle.md)), so
the heap entity's refcount is never decremented. The same barrier covers
it: storing a heap reference into an arena container does `retain(new)`
and appends the heap entity to the arena's *release-at-reset* list — and,
unlike an ordinary store, does **not** release the displaced old value.
At reset the list performs one release per entry.

**Why no release on overwrite**: the displaced value's own list entry
already owes it exactly one release; releasing at overwrite *and* from
the list would double-release (use-after-free). With the release side
owned entirely by the list, every store contributes one retain and one
list entry, so retains and releases pair one-to-one under any number of
overwrites — no deduplication, no slot revalidation, and the store
barrier gets cheaper. The costs, accepted: a displaced heap entity lives
until arena reset (the arena policy, extended to heap entities the arena
referenced), and COW refcounts can be temporarily inflated, causing a
spurious separation on write.

**Rejected: a per-entity deferred-release counter** instead of duplicate
list entries. The counter has nowhere cheap to live: the 8-byte header
has no room, and a side table means a lookup on every store, which costs
more than the 8-byte duplicate entry it saves. Pathological duplicate
growth (a hot loop re-storing heap refs into one arena slot) is exactly
what compiler ARC pairing elimination removes statically.

**Growth bound**: the list grows by 8 bytes per logged store only
(arena→arena stores, the dominant case, log nothing), lives in the
arena's own bump memory, and dies with it. It cannot be compacted
mid-request: deduplication would mean early releases while arena slots
may hold the only references. If real workloads ever show this list
dominating, the fallback is a hybrid: past a size threshold, switch to
logging slot addresses and revalidate them at reset — machinery
deliberately not built until measurements demand it.

### Relationship to escape analysis

The barrier is the runtime backstop, not the primary mechanism: escape
analysis should allocate objects that provably escape the request directly
in the heap or long-lived arena, so the barrier's slow path stays rare.
