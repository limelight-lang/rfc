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
  "current arena" pointer is a field of the actor context, and it reaches
  the code that needs it as an argument rather than through a thread-local
  ([DECISIONS](../dev/DECISIONS.md), 2026-08-23).
- **So does every other piece of state that must follow the actor**, and it
  travels the same way: as an argument — below.

## Where Per-Actor State Lives

A function called from an actor executes as the actor and knows nothing about
it, so a `static` inside it makes the actor's state outlive the message. A
process-global one races across threads and is overwritten across actors
sharing a thread; a thread-local one survives the actor on that thread and is
lost when the scheduler moves it.

**The answer is the calling convention.** A function that works with an actor
takes the actor context as its ordinary first argument: a **context-aware**
function ([DECISIONS](../dev/DECISIONS.md), 2026-08-23). An extension becomes
context-aware by recompilation rather than by rewriting, the macro through
which a module reads its globals being supplied by this runtime's headers and
resolving through the context the function already received.

**The scheduler installs one word at mount and clears it at unmount**: the
mounted-context pointer. Slot 0 is the compiled fast path over that same
value, and null is the legal no-context state, resolving through it.

**That word answers which actor executes here, not which actor owns a piece of
work**, and on a pool thread the two differ. So an interior path — the arena
reset's destructor fixpoint, owner-side cycle finalization, the synchronous collection, the
static-block teardown — takes the owner it works on as a parameter and presents
that owner's context to any user code it runs. The mount is a fallback only
where the executing actor is the owner by construction, which mutator-path
teardown is, because the mailbox is the only actor communication channel.

**A crossing into foreign code carries nothing.** Neither an epoch mark nor a
re-entry deposit is specified here; both are obligations on the owner question
below, and the 2026-07-25 rejection of marking entry to and exit from foreign
code stands.

**Thread exit installs a context of its own** around the static-block
teardown, the one step that runs `__destruct` bodies, which allocate.

Three things stay open. Which per-thread structures are actor state at all —
the weak table, the deferred-reuse list, the reset window, the drain gates, the journal
ring — is bounded by two facts of this document rather than by a ruling, as of
2026-08-23: an actor's own memory is collected by the actor, at its own message
boundary, on the thread executing it, so inside an actor there is never a second
thread to disagree with; and the slot reuse that the deferred-reuse list delays is bound to the
heap that issued the block, which is a thread's
(`ll-model` `src/memory/deferred_free.rs`). What is left of the question is the
weak table's residence, which is node E1
(../model/gc/walk/questions.md),
and whether two epochs are ever in flight at once, which E1 handed to node E3
on 2026-08-24.
Entry from code this runtime did not call arrives with no context, and what
establishes one is undecided. And a `static` inside a foreign shared object is
reached by nothing here: it needs a declaration from the module or an actor
pinned to a thread. Until it does, the guarantee that nothing enters an actor
except through the queue holds for language code and is unenforced against
foreign code.

**One debt against that guarantee.** The share row's mechanism was decided on
2026-08-23 — a copied pointer to memory the actor does not own — and what stays
undecided is what keeps that memory alive while the actor reads it, and how the
actor's own collection is kept from following the pointer as one of its own
edges. Uncontrolled FFI entry is the second hole, immediately above.

## The mailbox is the only communication channel

**Decision**: all data transfer between actors (call arguments *and*
results) goes through mailbox queues. There is no other channel; a
reference into actor memory never crosses the boundary raw.

- **External call** (`$actor->submit($order)` from outside the actor's
  context) compiles to: pack the message → enqueue → if a result is
  expected, suspend the calling fiber; the reply arrives as a message to
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
  not enforced per-store; it is enforced at the mailbox boundary.

### Globals cannot bypass the mailbox

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
| **share** | a genuinely shared object, immortal values among them | the message carries a **copied pointer**, not the object: the object stays in the other memory, the actor reads it by dereferencing, and the actor **does not own it** — no count is written and nothing is freed by it. Decided 2026-08-23 ([../dev/DECISIONS.md](../dev/DECISIONS.md)), which also records what is owed: the lifetime guarantee behind the pointer, and how the actor's own collection is kept from reading it as one of its edges |
| **moved** | an object moved into this actor | it joins a **list of moved objects** and is handled as an object moved into another thread is handled; the arena's escapee list with its hold-counts and its promotion at reset is the analogue this generalizes ([../model/memory/arena-reset.md](../model/memory/arena-reset.md)). Decided 2026-08-23; what the list holds, who appends and who clears is owed |
| **actor handle** | reference *to an actor* | a shareable opaque handle; the mailbox pointer itself is the only thing shared |

**A weak reference does not cross.** An object that holds a
`WeakReference` is not sendable in any form: the cell is an entity of its
own, shared by every copy of the handle
([../model/weak-references.md](../model/weak-references.md#the-weak-cell-is-the-canonical-weakreference-itself)),
so a deep copy would leave the copied cell's `target` pointing into the
sender's arena and sharing is reserved for values with no mutable state.
An object that is the **target** of a weak reference may not be moved:
the move is a pointer handoff, and the entity would leave while its
subscription row stays in the sender's table. Pack time tests
`HAS_WEAK_REFERENCES` (currently flag bit 12;
[../model/classes.md](../model/classes.md#flags-layout)),
and falls back to the deep copy, whose result is a new entity with no
subscriber. Decided 2026-08-23 ([../dev/DECISIONS.md](../dev/DECISIONS.md)).

**Rejected: block reparenting** (moving arena-born subgraphs by
re-owning their 64 KB blocks, zero-copy). An arena block is bump-filled
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
through the queue, with no copy and no block reparenting. The object
stays a general-heap resident (category `00`) but is marked
`gc_state = OWNED` while captured, so the concurrent collector skips it
([heap-design.md](../model/gc/heap-design.md)) and exactly one arena
owns it at a time. That single owner is the sole writer of its
`refcount`, so the object needs no atomic counts.

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

## Collection at message boundaries

Between two messages, an actor has no active message frame and its mutable state
is consistent. A message boundary is therefore a natural **consistent point**
at which the owning thread may run synchronous collection.

This observation does not yet define per-actor cycle collection:

- `rc-cycle` traverses only the cycle-collected heap and treats arena entities as
  external. A reference cycle entirely inside a long-lived actor arena therefore
  remains until arena reset under the current design.
- Candidate queues and trace tokens are per mutator thread, while actors may
  migrate between pool threads. The RFC does not yet specify how candidate state
  follows an actor or how it is transferred safely.
- The deleted `rc-trace` and `rc-satb` designs used actor handshakes and
  per-actor collector selection. Those mechanisms are historical and are not
  part of the `rc-cycle` design of record.

Consequently, this RFC does not currently promise per-actor GC selection. The
first implementation may run the process-selected `rc-cycle` strategy at a
message boundary only after the ownership and migration rules above are
resolved. The blockers are recorded in
[`dev/ALGORITHM-AUDIT.md`](../dev/ALGORITHM-AUDIT.md), B4, B5, and C3.

## Interactions

- [arenas.md](../model/memory/arenas.md): the actor is the
  generalized arena owner; "outlives the request" generalizes to
  "outlives the owning context".
- [strategies.md](../model/gc/strategies.md): the build selects the active GC
  strategy; per-actor selection remains unresolved.
- [static-lifetimes.md](../model/memory/static-lifetimes.md): move
  analysis powers zero-copy sends; `#[Actor]` classes give the
  analysis hard isolation boundaries it can trust.
- [object-lifecycle.md](object-lifecycle.md): actor death runs the
  same three-phase teardown discipline as arena reset.

## Open Questions

- **There is no general heap** (2026-07-28). Allocation-site selection
  above assumes a heap owned by no domain, into which a provably
  transferable object is born so the send is a pointer handoff. The
  memory model has none: every block belongs to a thread's heap, and a
  nobody's-heap would require exactly the shared allocation and free
  that per-thread ownership avoids. Worse, an actor is not bound to a
  thread. Its *mutable* state is safe — that lives in its own arena,
  which belongs to the actor and migrates with it — but a transferable
  entity has nowhere neutral to be born: promoted out of the arena, it
  lands in the entity heap of whichever pool thread was mounting the
  actor, so its host is a thread while its holder is an actor. The
  payload table and allocation-site selection are owed a re-derivation;
  the GC side of the problem is in
  [../model/gc/domains.md](../model/gc/domains.md).
- **Sync-call deadlock**: actor A blocked awaiting B while B awaits A.
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
