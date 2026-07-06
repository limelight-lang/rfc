# Actors: Isolated Execution Contexts with Owned Memory

## Definition

An actor is an execution context that **owns its memory**: one or more
arenas that belong to it exclusively, a mailbox, and the guarantee of
serial execution. Declared with an attribute:

```php
#[Actor]
class OrderProcessor {
    private array $pending = [];        // lives in this actor's arena

    public function submit(Order $o): Receipt { ... }
}
```

The compiler treats `#[Actor]` as a codegen and context boundary: code
*inside* the class compiles as ordinary calls against actor-owned
memory; every interaction *from outside* compiles into a queue
operation.

Prior art: Erlang/BEAM (per-process heaps, independent GC, message
copying), Pony/ORCA (capability-checked zero-copy sends), Swift actors
(serial executors hopping a thread pool).

---

## Serial Execution Without Thread Affinity

An actor is **not bound to a thread**. The scheduler runs it on
whatever pool thread is free (M:N); it may migrate between messages.
The invariant is weaker and sufficient: **at most one thread executes
a given actor at any moment**.

Consequences:

- **Non-atomic refcounts everywhere inside actor memory.** Serial
  execution is exactly the property biased RC
  ([../model/memory/arc-optimizations.md](../model/memory/arc-optimizations.md))
  tries to detect dynamically — actors provide it statically. The
  migration handoff (scheduler dequeue/enqueue) carries the required
  acquire/release fence for free.
- **The allocation context follows the actor, not the thread.** The
  "current arena" pointer is a field of the actor context, installed
  into TLS when the scheduler mounts the actor on a thread.

## The Queue Is the Only Door

**Decision**: all data transfer between actors — call arguments *and*
results — goes through mailbox queues. There is no other channel; a
reference into actor memory never crosses the boundary raw.

- **External call** (`$actor->submit($order)` from outside the actor's
  context) compiles to: pack the message → enqueue → if a result is
  expected, park the calling fiber; the reply arrives as a message to
  the caller and resumes the fiber. Synchronous *appearance*, two queue
  operations underneath.
- **Internal calls** (self-calls, calls on ordinary objects inside the
  actor) are plain direct calls — zero overhead.
- The compiler distinguishes the two statically by context (is the
  call site inside the `#[Actor]` class?), with a runtime check where
  the callee's actor-ness is erased.
- **Atomics live only in queues.** The MPSC mailbox is the single data
  structure touched by multiple threads. All other memory in the
  system is serial.
- The ordinary store barrier gains **no** actor layer — isolation is
  not enforced per-store, it is enforced by the queue being the only
  door.

## Message Payload Discipline

Applied at *pack time* — the one place references cross:

| Form | When | Cost |
|---|---|---|
| **copy** | semantic default | deep copy into recipient's arena (Erlang model) |
| **move** | compiler proves the subgraph isolated (ownership/move analysis, [static-lifetimes.md](../model/memory/static-lifetimes.md)) | reparent whole 32KB blocks to the recipient's arena — zero copy, sender's bindings dead |
| **share** | immortal and frozen-COW values | pass by reference; such values carry no mutable state and no non-atomic counts (interned strings, enum cases — cf. Erlang's shared refcounted binaries) |
| **actor handle** | reference *to an actor* | a shareable opaque handle; the mailbox pointer itself is the only thing shared |

## Actor Memory

- The actor owns its arenas; everything it allocates lands there
  (tier analysis may still stack-allocate tier-1 objects).
- **Actor death = arena reset**: O(1) reclamation via the existing
  machinery ([arena-reset.md](../model/memory/arena-reset.md)) —
  tracked pre-destructors run, escaped survivors are promoted, blocks
  return to the global pool.
- **A request is a degenerate actor**: one message, then death. The
  request arena ([arenas.md](../model/memory/arenas.md)) is the
  special case this design generalizes.

## Per-Actor Collection at Message Boundaries

Between two messages an actor's stack is empty and its state
consistent — **message boundaries are natural safepoints**. Cycle
collection for an actor's arenas runs there:

- no poll safepoints inside actor code at all;
- "pause" means the actor picks up its next message slightly later —
  other actors never notice (stop-the-actor, not stop-the-world);
- the collection scope is one actor's arenas — small by construction.

This delivers the Erlang pause story through the existing `rc-trace`
machinery, and shrinks the role of concurrent SATB
([../model/gc/satb.md](../model/gc/satb.md)) to what remains truly
shared: the general heap outside any actor.

## Per-Actor GC Selection

**Decision**: actors may use **different collectors**. The build
compiles in a *set* of strategies from the registry
([../model/gc/strategies.md](../model/gc/strategies.md)); each actor
binds one:

```php
#[Actor]                          // build's default, e.g. rc-trace
class Api { ... }

#[Actor(gc: 'none')]              // short-lived: never collect cycles,
class RequestHandler { ... }      // death resets everything anyway

#[Actor(gc: 'rc-trace', threshold: '64kb')]   // per-actor tuning
class SessionCache { ... }
```

What this costs — split by what actually differs:

- **The collector itself is free to vary.** It runs *between*
  messages, outside any hot path: which routine (none / trace /
  future variants) and which thresholds are per-actor metadata.
  Erlang precedent: per-process `min_heap_size`, `fullsweep_after`.
- **Store-path differences are not free.** A strategy that changes
  the store barrier or drops refcounting entirely (`nogc`-style
  actors) would need actor-specialized compilation of shared code
  (monomorphization) or a uniform store path. Open question below;
  the first implementation mixes only collectors, not store paths.

## Interactions

- [arenas.md](../model/memory/arenas.md): the actor is the
  generalized arena owner; "outlives the request" generalizes to
  "outlives the owning context".
- [strategies.md](../model/gc/strategies.md): strategy selection
  becomes two-level — build selects the compiled-in set, actors bind
  per-instance-class from it.
- [static-lifetimes.md](../model/memory/static-lifetimes.md): move
  analysis powers zero-copy sends; `#[Actor]` classes give the
  analysis hard isolation boundaries it can trust.
- [object-lifecycle.md](object-lifecycle.md): actor death runs the
  same three-phase teardown discipline as arena reset.

## Open Questions

- **Sync-call deadlock**: actor A parked awaiting B while B awaits A.
  Cycle detection on the waits-for graph, timeouts, or forbidding
  nested synchronous calls — undecided.
- **Supervision / links**: actor failure propagation, restart
  policies (Erlang OTP territory) — deliberately out of scope here.
- **Backpressure**: mailbox growth when producers outpace a consumer.
- **Monomorphization for store-path-divergent actors** (`nogc`
  actors sharing library code with RC actors).
- **Handle representation**: what an actor reference looks like in
  the value model ([values.md](../model/values.md)) — likely a
  resource-like immortal cell.
