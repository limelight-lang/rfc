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
  tries to detect dynamically; actors provide it statically. The
  migration handoff (scheduler dequeue/enqueue) carries the required
  acquire/release fence for free.
- **The allocation context follows the actor, not the thread.** The
  "current arena" pointer is a field of the actor context, installed
  into TLS when the scheduler mounts the actor on a thread.

## The Queue Is the Only Door

**Decision**: all data transfer between actors (call arguments *and*
results) goes through mailbox queues. There is no other channel; a
reference into actor memory never crosses the boundary raw.

- **External call** (`$actor->submit($order)` from outside the actor's
  context) compiles to: pack the message → enqueue → if a result is
  expected, park the calling fiber; the reply arrives as a message to
  the caller and resumes the fiber. Synchronous *appearance*, two queue
  operations underneath.
- **Internal calls** (self-calls, calls on ordinary objects inside the
  actor) are plain direct calls with zero overhead.
- The compiler distinguishes the two statically by context (is the
  call site inside the `#[Actor]` class?), with a runtime check where
  the callee's actor-ness is erased.
- **Atomics live only in queues.** The MPSC mailbox is the single data
  structure touched by multiple threads. All other memory in the
  system is serial.
- The ordinary store barrier gains **no** actor layer: isolation is
  not enforced per-store; it is enforced by the queue being the only
  door.

### Globals are not a door

References into actor memory must not leave through global state
either: storing into a global variable, a static property, or
`$GLOBALS` from actor context admits **share-compatible values only**
— immortal and frozen-COW entities, exactly the class of values the
`share` row below admits. A global is, in effect, a message to
everyone, so it obeys the message discipline. A mutable managed
reference stored globally would hand another actor a raw pointer into
this actor's serial memory — non-atomic refcounts and all — so it is
an error, not a copy.

Enforcement mirrors the call-site rule above:

- store sites inside `#[Actor]` classes are known statically; the
  compiler rejects non-share-compatible stores to global slots at
  compile time;
- shared library code, compiled once and callable from both worlds,
  gets a runtime check on global-slot stores (in actor context and
  value not share-compatible → error). Global stores are rare; the
  check is cold.

## Message Payload Discipline

Applied at *pack time*, the one place references cross:

| Form | When | Cost |
|---|---|---|
| **move** | compiler proved at the allocation site that the object will be transferred (ownership/move analysis, [static-lifetimes.md](../model/memory/static-lifetimes.md)) | the object was born in the general heap (see below): the send is a pointer handoff through the queue, zero copy, sender's bindings dead |
| **copy** | everything arena-born the analysis could not prove | deep copy into recipient's arena (Erlang model — which copies *always*, so this is the worst case, not the norm) |
| **share** | immortal and frozen-COW values | pass by reference; such values carry no mutable state and no non-atomic counts (interned strings, enum cases; cf. Erlang's shared refcounted binaries) |
| **actor handle** | reference *to an actor* | a shareable opaque handle; the mailbox pointer itself is the only thing shared |

**Rejected: block reparenting** (moving arena-born subgraphs by
re-owning their 32 KB blocks, zero-copy). An arena block is bump-filled
with whatever the actor allocated in sequence: alongside the
transferable subgraph live unrelated objects, and reparenting the block
would move them too. The trick only works for subgraphs segregated into
dedicated blocks from birth — but anything the compiler can prove that
early is allocated straight into the general heap instead, which is
strictly cheaper (no reparenting at all). Two paths, not three.

### Allocation-site selection

The compiler computes, per allocation site, whether the object is
**actor-local** or **will be transferred** to another actor. A proven
transferable object is allocated **directly in the general heap**, not
in the actor's arena: the eventual move is then a pointer handoff
through the queue, with no copy and no block reparenting. Ownership
still transfers wholly (sender's bindings die), so serial access is
preserved and the object needs no atomic counts.

This is the same discipline as arena-promotion
([arena-promotion.md](../model/memory/arena-promotion.md)): static
analysis allocates in the destination directly, and the pack-time deep
copy remains the runtime fallback for what analysis could not prove.

## Actor Memory

- The actor owns its arenas; everything it allocates lands there
  (tier analysis may still stack-allocate tier-1 objects).
- **Actor death = arena reset.** O(1) reclamation via the existing
  machinery ([arena-reset.md](../model/memory/arena-reset.md)):
  tracked pre-destructors run, escaped survivors are promoted, blocks
  return to the global pool.
- **A request is a degenerate actor**: one message, then death. The
  request arena ([arenas.md](../model/memory/arenas.md)) is the
  special case this design generalizes.

## Per-Actor Collection at Message Boundaries

Between two messages an actor's stack is empty and its state
consistent: **message boundaries are natural safepoints**. Cycle
collection for an actor's arenas runs there:

- no poll safepoints inside actor code at all;
- "pause" means the actor picks up its next message slightly later;
  other actors never notice (stop-the-actor, not stop-the-world);
- the collection scope is one actor's arenas, small by construction.

This delivers the Erlang pause story through the existing `rc-trace`
machinery, and shrinks the role of concurrent SATB
([../model/gc/satb.md](../model/gc/satb.md)) to what remains truly
shared: the general heap outside any actor.

## The Global Collector Speaks Mailbox

The concurrent general-heap collector (`rc-satb`,
[satb.md](../model/gc/satb.md)) never inspects a running actor. What it
needs from one is small — the actor's roots into the general heap, and,
for mark termination, the actor's SATB buffer — and both travel the
same road as everything else: **a system message in the mailbox**
(prior art: Pony's ORCA, whose whole GC protocol is actor messages).

- The collector enqueues a handshake message; the actor handles it at
  its next message boundary — stack empty, state consistent, the moment
  the actor itself knows is safe — flushing its SATB buffer in the
  reply. Mark termination = every actor has replied. A parked actor is
  woken by the message like by any other.
- Roots need no stop either: the release-at-reset list
  ([arenas.md](../model/memory/arenas.md)) is an append-only registry
  of every general-heap reference the arena holds, readable by the
  marker up to a watermark while the actor runs. It over-approximates
  (a stale entry keeps an object alive one extra cycle) — safe for
  marking. Stack-only references are covered by allocate-black plus the
  SATB deletion barrier; mailbox contents are scannable shared
  structures. (Completeness of this root story to be re-verified at
  implementation time.)
- The queue stays the only door — for the collector too: no poll
  safepoints, no external inspection of a running actor's state.

The residual case is a long message (a batch chewing for minutes): the
actor reaches no boundary, and mark termination waits on it. The fix is
not a GC-specific poll but a general **system-signal check** compiled
into unbounded loops — one mechanism serving GC handshakes,
cancellation, timeouts, and supervision alike (Open Questions,
[BACKLOG](../BACKLOG.md)).

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

What this costs, split by what actually differs:

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
  becomes two-level: build selects the compiled-in set, actors bind
  per-instance-class from it.
- [static-lifetimes.md](../model/memory/static-lifetimes.md): move
  analysis powers zero-copy sends; `#[Actor]` classes give the
  analysis hard isolation boundaries it can trust.
- [object-lifecycle.md](object-lifecycle.md): actor death runs the
  same three-phase teardown discipline as arena reset.

## Open Questions

- **Sync-call deadlock**: actor A parked awaiting B while B awaits A.
  Cycle detection on the waits-for graph, timeouts, or forbidding
  nested synchronous calls; undecided.
- **Supervision / links**: actor failure propagation, restart
  policies (Erlang OTP territory); deliberately out of scope here.
- **Backpressure**: mailbox growth when producers outpace a consumer.
- **Monomorphization for store-path-divergent actors** (`nogc`
  actors sharing library code with RC actors).
- **Handle representation**: what an actor reference looks like in
  the value model ([values.md](../model/values.md)); likely a
  resource-like immortal cell.
- **System-signal check in unbounded loops**: loops with no provable
  bound get an iteration guard — a counter in the actor context,
  decrement + branch on the back-edge, on zero: peek system signals,
  reset (BEAM reduction counting). Lets a long-running message answer
  GC handshakes, cancellation, and supervision probes. The counter's
  budget and placement heuristics TBD.
