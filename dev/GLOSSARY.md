# RFC terminology

> **Status: `dev/PLAN.md` S9.1.** The canonical tables are normative for new
> text. The deprecated table and the context-sensitive list are the input of
> S9.2, which renames. Checked against the active RFC set and against the
> crate's `ll-model/dev/CYCLE-TERMINOLOGY-AUDIT.md`, "Glossary check, 2026-09-01", on
> 2026-09-02.

This glossary defines the vocabulary the normative RFCs use as terms. A term
is a word or phrase a document uses with a meaning narrower than ordinary
English; ordinary English uses of the same word are outside the glossary.
Every entry states what the term denotes, the word the field uses for the
same thing, and a verdict a reader can check against the cited source.

## Writing rules

1. Prefer the established term from compiler, allocator, garbage-collector,
   concurrency or tracing literature. Where the field has a word, the
   documents use it.
2. Name an operation by its observable result. An allocation *fails* or
   *returns null*; a design alternative is *rejected*; a queue entry is
   *removed* or stays; storage an evacuation could not move is *pinned*.
3. Use one term for one concept and one concept per term. Legal, financial,
   architectural and physical metaphors are not terms: *door*, *escrow*,
   *floor*, *corpse*, *judge* and *acquit* each entered through one commit and
   spread because a metaphor contradicts nothing.
4. Introduce a project-specific term only when no established term denotes the
   same thing, and say in its entry why. Define it at first use and add it
   here.
5. RFC requirements use **must**, **must not**, **should** and **may** in their
   usual normative senses. Historical decisions use the past tense.
6. A citation quotes its heading exactly, even when the heading carries a
   retired word. The sentence around the quotation uses the canonical term.

## How to read an entry

- **Denotes**: what the term means in Limelight, stated positively, with the
  section that defines it where one exists.
- **Established equivalent**: the word the field uses for the same or the
  nearest thing, with its source: a paper by author and year, a system that
  uses the word, or both.
- **Verdict**: *keep* when the term is the field's word or a plain
  qualification of it; *project-specific* when no established term denotes
  the thing, with the reason; *rename* when the term is retired, with the
  literal replacement. The canonical tables carry *keep* and
  *project-specific*; the deprecated table carries *rename*.

Sources cited more than once: Jones, Hosking and Moss, *The Garbage
Collection Handbook* (2012), cited as the Handbook with its chapter; Bacon and
Rajan, *Concurrent Cycle Collection in Reference Counted Systems* (2001);
Ungar, *Generation Scavenging* (1984); Deutsch and Bobrow, *An Efficient,
Incremental, Automatic Garbage Collector* (1976); Dijkstra, Lamport, Martin,
Scholten and Steffens, *On-the-Fly Garbage Collection* (1978).

## Canonical terms

Only these tables define terms that new normative text may use without a local
definition.

### Execution, ownership and synchronization

| Term | Denotes | Established equivalent | Verdict |
|---|---|---|---|
| actor | Serial execution context with isolated mutable state and a mailbox (`runtime/actors.md`, "Definition") | actor (Hewitt, Bishop and Steiger 1973); Erlang process | keep |
| mailbox | The message queue that is an actor's only channel in (`runtime/actors.md`, "The mailbox is the only communication channel") | mailbox (Erlang; the actor model) | keep |
| mutator | Thread executing application code and changing the object graph | mutator (Dijkstra et al. 1978) | keep |
| owning mutator | The mutator whose thread owns a block, a candidate queue or a trace token; every state-reducing transition on them is its | owner thread of a thread-local heap (Hoard, Berger et al. 2000; mimalloc) | keep |
| collector worker | Optional thread that runs a speculative trace over an owner's blocks and sends the owner a validation batch (`model/gc/rc-cycle.md`, "Worker-to-owner handoff") | collector thread of an on-the-fly collector (Dijkstra et al. 1978) | keep; *worker* because the design allows several and requires none |
| ownership invariant | Clearing a candidate bit, removing a queue entry and returning a slot are done only by the owning mutator, on exact state (`model/gc/rc-cycle.md`, "Speculative tracing and exact validation") | single-writer rule | keep |
| trace token | Per-mutator word acquired by compare-and-swap and released by a release store; its holder may trace that mutator's blocks and read its live candidate queue; a worker that finds it held skips the owner, the owner waits for it (`model/gc/rc-cycle.md`, "Concurrency") | try-lock; the lock word of a test-and-set spin lock | keep |
| safepoint | Compiler-inserted poll at function entry and loop back-edge, at which the thread holds no half-built entity and no reference in flight; a point in time, not a root map (`model/gc/strategies.md`, "2. Safepoints") | safepoint (HotSpot); GC point (Agesen 1998) | keep |
| consistent point | Point between mutator operations at which slots and reference counts agree: after a store or a teardown has completed, at a poll, at a message boundary. Collection may start only there (`model/gc/strategies.md`, "Collection requests and triggers"; `runtime/actors.md`, "Collection at message boundaries") | GC-safe point (Handbook, ch. 11) | project-specific: *safepoint* is taken by the compiler's poll (`model/gc/strategies.md`, "2. Safepoints"), which is one consistent point among several: an explicit `ll_gc_collect_cycles`, a message boundary and the backedge of a bulk loop qualify without being safepoints. The consistent point names the property every trigger site needs, that counts and edges agree, which is what exact validation reads; `rc-cycle` suspends no thread |

### Memory categories, blocks and arenas

| Term | Denotes | Established equivalent | Verdict |
|---|---|---|---|
| entity | Managed allocation beginning with a Limelight entity header: an object, a lazy object, an array, a reference box, a string, an `FFIBox` or a weak cell (`model/classes.md`, the entity-kind row of the flags table) | object, cell (Handbook) | project-specific: *object* is one entity kind among several and is PHP's word for that kind |
| entity kind | Four-bit header field naming which of those an entity is; it selects the teardown routine and, for a bare pointer, the descriptor | type tag | keep |
| memory category | Two-bit header field selecting an entity's lifetime discipline: request arena, long-lived, immortal or GC heap (`model/memory/arenas.md`, "Object Categories by Memory Strategy") | space, generation (Handbook) | project-specific: a space is an address range; a category is a per-entity discipline, and a retained block holds GC-heap entities in former arena memory |
| arena | Region whose allocations share a bulk lifetime and are bump-packed in 64 KiB blocks | arena (Hanson 1990); region (Tofte and Talpin 1997) | keep |
| immortal region | Bump region with no reset and no free: class descriptors, interned strings, the small constants (`model/memory/arenas.md`, "Immortal Objects") | immortal space (Handbook) | keep |
| block | 64 KiB unit of the block pool; arenas, the size-class heap, retained blocks and trace scratch are made of them | block (Immix, Blackburn and McKinley 2008); page (mimalloc) | keep |
| slot | Fixed-size cell of a size-class block holding one entity body | slot, cell (Handbook) | keep |
| large entity | Entity whose single allocation exceeds its category's packing unit, so it holds a pooled block of its own or an OS-direct run (`model/memory/large-entities.md`, "The invariant") | large object, large object space (Handbook) | keep |
| critical reserve | Per-mutator blocks withheld from ordinary allocation for the bounded operations that must complete after allocation failure (`model/memory/critical-reserve.md`, "Reserve users") | memory reserve (Linux `PF_MEMALLOC` reserves, `mempool`) | keep |
| allocation path | One of the routes a request for a block can take: the ordinary block pool, then the critical reserve (`model/memory/critical-reserve.md`, "Allocation paths") | allocation path | keep |
| allocation failure | A request that returned null on every path it was allowed | allocation failure; out of memory | keep |
| store barrier | The per-store operation generated code runs: the category barrier composed with the active strategy's micro-operations (`model/gc/strategies.md`, "1. The store barrier, as micro-operations") | write barrier (Handbook, ch. 11) | keep; *store* is the IR's word for the operation the barrier wraps |
| category barrier | The strategy-independent layer of the store barrier: it compares the categories of holder and value and records an escape when the holder outlives the value (`model/memory/arenas.md`, "Cross-Arena References") | generational write barrier (Ungar 1984) | keep |
| escapee | Request-arena entity referenced by a container of a longer-lived category; it is on its arena's escapee list and carries a hold-count | escaping object (escape analysis, Choi et al. 1999) | keep |
| hold-count | Number of longer-lived containers currently referencing an escapee, kept in its header while it is one; the reset's survivor test reads it | external reference count | project-specific: a reference count counts every holder; the hold-count counts only holders that outlive the arena |
| escapee list | Append-only per-arena list naming every entity that ever escaped and never the slot it escaped into (`model/memory/arenas.md`, "Implementation note") | remembered set (Ungar 1984) | project-specific: a remembered set records the holders, the old objects stored into (Ungar 1984) or their slots and cards in later collectors; the escapee list records the held entities and cannot enumerate holders |
| release-at-reset list | Per-arena list of the heap entities that arena slots owe a release to: the category barrier appends one on a heap-into-arena store, and the reset performs one release per entry (`model/memory/arenas.md`, "The reverse direction: request arena ← heap") | deferred decrement buffer (Deutsch and Bobrow 1976) | keep; replaces *release log* |

### Arena reset and promotion

| Term | Denotes | Established equivalent | Verdict |
|---|---|---|---|
| arena reset | The bulk end of an arena: a fixpoint over survivor discovery, escaped-subgraph tracing and destructors, then a per-block decision, then the blocks return to the pool (`model/memory/arena-reset.md`, "Step 1 — Validate, trace, destruct: a fixpoint loop") | region deallocation (Tofte and Talpin 1997); arena reset (Hanson 1990) | keep |
| survivor | Arena entity still held when its arena resets: an escapee whose hold-count is non-zero, or an entity the escaped subgraph reaches | survivor (Ungar 1984) | keep |
| destructor effect class | The reset's static classification of a `__destruct`: *pure* creates nothing and stores no managed reference, *dirty* allocates in the same arena, *heap-effecting* creates heap entities or stores across categories (`model/memory/arena-reset.md`, "What keeps the fixpoint going — destructor purity") | effect classification | keep; *pure* here is the class name, and `model/gc/pure-destructors.md` uses P0 to NR for its own record |
| arena promotion | Rewriting a survivor's category from request arena to its new category at reset, with an exact reference count rebuilt from the hold-count, the internal arena edges and one compensating retain per held heap entity (`model/memory/arena-reset.md`, "Retention (dense blocks)") | promotion, tenuring (Ungar 1984; Lieberman and Hewitt 1983) | keep |
| evacuation | Copying a survivor of a sparse block, or the out-of-line storage of any survivor, into a block of its new category and rewriting the pointer that named it (`model/memory/arena-reset.md`, "Evacuation (sparse blocks)"; `model/memory/arena-promotion.md`, "Entities with out-of-line storage") | evacuation (HotSpot G1; Immix opportunistic evacuation) | keep |
| carry | The reset's operation on a survivor's out-of-line storage, dispatched on the entity kind or on the class's hook: the storage is evacuated, transferred, or left as a pinned payload (`model/memory/arena-promotion.md`, "Entities with out-of-line storage") | — | project-specific: a copying collector moves an object and its out-of-line storage alike; here the header keeps its address and only the storage moves, and the literature has no word for that step alone. `ExternalCarry` and `OutsideCarry` are its result types |
| transfer | Change of owner of a survivor's OS-direct storage at reset: the run's record leaves the arena's large-allocation list and passes to the promoted entity, and the address does not move (`model/memory/arena-promotion.md`, "Entities with out-of-line storage"; `model/memory/large-entities.md`, "An arena large entity is transferred at the reset, never copied, and the reset needs four more rules to do it") | ownership transfer (move semantics: C++ `std::move`, a Rust move) | keep |
| retained block | Former arena block whose survivors were promoted in place; stamped with its kind, kept out of the pool, and returned when its last survivor and its last pinned payload are gone (`model/gc/rc-cycle.md`, "The survivor list of a retained block") | region kept after an evacuation failure (HotSpot G1) | keep |
| in-place promotion | Arena promotion of a survivor that keeps its address: the category and the count are rewritten where the entity stands and the block holding it becomes a retained block; the reset's default, evacuation being the alternative (`model/memory/arena-reset.md`, "The category and the reset's own mark are rewritten in place") | promote in place of a dense young region (Generational Shenandoah) | keep; a plain qualification of *arena promotion* |
| pinned block | Retained block held for payload bytes rather than for occupants; its count word carries pinned payloads beside live survivors | pinning (Immix pinned objects; .NET pinned handles) | keep |
| pinned payload | Out-of-line storage of a survivor whose evacuation could not allocate its destination: the bytes stay in their source block, the block is retained and pinned for them, and the free of the owning entity spends the pin. Neither an allocation failure nor a denial: the reset retains the block and continues (`model/memory/arena-reset.md`, "Why carrying stragglers is acceptable"; `model/gc/rc-cycle.md`, "The survivor list of a retained block") | pinned object, an address that may not move (Immix; .NET pinned handles); object left in place after a promotion failure (HotSpot Serial and Parallel collectors, self-forwarded objects) | keep. The identifier is `Pinned`: `ExternalCarry::Pinned(block)` and `OutsideCarry::Pinned { memory }` replace the two `Refused` variants |
| reset window | The interval of one arena reset on its thread, from before the fixpoint to after the last pass over the survivor list; while it is open the thread's large-entity frees are deferred and completed teardowns are recorded; windows nest when a destructor drives a second reset (`ll-model/src/memory/reset_window.rs`) | read-side critical section (RCU, McKenney and Slingwine 1998) | keep; *window* is ordinary English for an interval, and the reset is the only reader |
| deferred free | The reset window holds a large-entity body freed while it is open and frees it on the ordinary path after the last reader is done; a nested window hands its bodies to the outer one | deferred free (RCU `call_rcu`); retire list (hazard pointers, Michael 2004) | keep; replaces `park_large` and `parked_large`. Distinct from *deferred slot reuse*, which is the collector's and delays a slot's reissue rather than a body's return |
| torn-down entity | Entity whose teardown completed while a reset window was open on the thread; the window records it and no later pass of that reset reads its fields (`ll-model/src/memory/reset_window.rs`) | dead object (Handbook) | project-specific: *dead* names unreachability, which a cycle member reaches before any teardown; the reset needs the later fact that teardown ran. Replaces *corpse* and *death* in `reset_window` and `promote`: `CORPSE_WALKS` counts walks over torn-down entities |
| deferred increment | A `+1` owed to a COW child's count at the reset's reconciliation: an edge a torn-down holder held at its promotion, whose release is inside the child's delta and which no walk finds (`ll-model/src/memory/reset_window.rs`, `Corrections`) | deferred increment (Deutsch and Bobrow 1976); increment buffer (Bacon, Attanasio, Lee, Rajan and Smith 2001) | keep; replaces `ResetWindow::escrow` and `Corrections::escrowed` |
| deferred decrement | A `-1` owed at the same reconciliation: the compensating retain the counting pass gave an already promoted COW child, whose edge the walk finds as well | deferred decrement (same sources) | keep; replaces `ResetWindow::credits`, `credit` and `Corrections::credited` |

### Candidate collection

| Term | Denotes | Established equivalent | Verdict |
|---|---|---|---|
| reference cycle | Set of entities each reachable from the others through counted references, which reference counting alone cannot reclaim | cycle (Handbook, ch. 5) | keep |
| cycle candidate | Header-bearing entity registered after a non-final decrement because it may belong to a reference cycle | possible root, purple object (Bacon and Rajan 2001) | keep |
| candidate registration | Edge-triggered insertion of an entity into the candidate queue after a non-final decrement; it takes no lock, and the design requires that it never drop an entry (`model/gc/cycle/questions.md`, Y6); the capacity proof is open, `dev/ALGORITHM-AUDIT.md`, A5 | `PossibleRoot` buffering (Bacon and Rajan 2001) | keep |
| candidate bit | Header bit set at registration and cleared by the owner at the entity's death; while set, no second registration happens | buffered flag (Bacon and Rajan 2001) | keep |
| candidate gate | The mask test `flags & 0x723 == 0` that admits an entity to registration: GC-heap category, cycle-capable kind, eligible class, unproven ownership, clear candidate bit (`model/gc/rc-cycle.md`, "Zero-count entities pending slot reuse") | conjunctive predicate | keep; *gate* is ordinary English for one |
| acyclic-class filter | Static proof that instances of a class cannot participate in a reference cycle; such instances fail the gate (`model/gc/cycle/questions.md`, Y10) | acyclic type filter, green objects (Bacon and Rajan 2001) | keep |
| candidate queue | Per-owner queue of registered candidates, written by the owner and read behind it by a trace; not a set of stack or global roots (`model/gc/cycle/questions.md`, Y12) | root buffer (Bacon and Rajan 2001) | keep |
| queue base block | The block held for the queue's whole life: the owner's queue state in its first cache line, the overflow buffer in the rest | — | keep; a plain description |
| overflow buffer | Bounded, lifetime-funded storage in the queue base block that takes a registration when no queue segment can be acquired | overflow buffer, overflow list | keep |
| deferred-candidate buffer | Per-mutator buffer holding candidates validated as externally referenced until the epoch changes, so they are not traced again within it | rotating candidate buffers over `k` collections (Levanoni and Petrank 2006, as `model/gc/cycle/questions.md`, Y9, records) | keep |
| epoch | Process-global counter that scopes candidate-age stamps; a stamp is current only for the epoch that wrote it. When it advances is open, `dev/ALGORITHM-AUDIT.md`, C1 | epoch (epoch-based reclamation, Fraser 2004); collection number | keep |
| candidate age | Saturating age a validation commit stamps on each externally referenced component: the minimum current member age plus one, beside the epoch stamp (`model/gc/cycle/questions.md`, Y9) | object age (Ungar 1984) | keep |
| traversal age threshold | Candidate age at which a non-root trace target with a current stamp is treated as an opaque external live reference and not descended into | tenuring threshold (Ungar 1984; HotSpot `MaxTenuringThreshold`); `YrcPromoteAge` | project-specific: tenuring moves the object to another space; here nothing moves, and what the threshold changes is the traversal's treatment of the target |
| synchronous collection | Collection the owning mutator runs itself: exact by construction, no handoff, the required form (`model/gc/cycle/questions.md`, Y14) | synchronous collection, run on the mutator's thread (Handbook) | keep |
| speculative trace | A trace run by a collector worker over an owner's blocks; its result is a proposal because fields and counts may come from different instants | concurrent tracing (Dijkstra et al. 1978) | keep; *speculative* because the result is validated, never applied |

### Tracing, validation and finalization

| Term | Denotes | Established equivalent | Verdict |
|---|---|---|---|
| trace | Trial-deletion traversal over cycle candidates using shadow counts: mark copies counts into rows and subtracts internal edges, scan classifies; qualified at first use as speculative or synchronous | trial deletion (Christopher 1984; Martinez, Wachenchauzer and Lins 1990); mark and scan (Bacon and Rajan 2001) | keep |
| shadow count | Trace-local working copy of an entity's reference count in a side row, with defined saturation; the live count is never written (`model/gc/rc-cycle.md`, "Where the shadow count lives") | trial-deletion count, which Bacon and Rajan decrement in place | keep; *shadow* is the established word for a side copy, as in shadow memory and shadow stack |
| trace scratch arena | Per-trace bump arena of 64 KiB blocks holding shadow rows, row-initialization bitmaps and worklist segments; drawn from the pool, then the critical reserve; returned whole at the trace's end (`model/memory/critical-reserve.md`, "Collection working memory") | collector scratch space; mark stack | keep |
| row-initialization bitmap | Per-row-array bitmap recording which groups of shadow rows the trace has initialized | lazy-initialization bitmap | keep |
| touched list | Per-trace intrusive list of the row arrays the trace allocated, threaded through a prologue of each array; the clear at the end of scan walks it to null every listed block's shadow-row pointer (`ll-model/src/cycle/arena.rs`) | undo log | project-specific: an undo log stores prior values to restore; the touched list stores only identities to null, and each entry is the row storage itself, so listing a block cannot fail apart from allocating its rows. This is the sweep-list sense of *enrolment*: the verb is *attach*, the state *on the touched list*, and the operation at the end of scan is a *clear*, not a *sweep* |
| candidate component | Candidate subgraph a trace tests as one unit | candidate subgraph (Bacon and Rajan 2001) | keep |
| validation batch | Components a speculative trace proposes to the owner for exact validation | — | project-specific: the concurrent collectors of the literature decide reachability on the collector thread; this design hands the set to the owner, and no literature term names a set proposed for validation |
| exact validation | Owner-thread check that a component's current member counts are fully explained by component-internal edges and guard references (`model/gc/rc-cycle.md`, "Speculative tracing and exact validation") | the Σ-test and Δ-test of the concurrent algorithm (Bacon and Rajan 2001) | keep; those tests run on the collector thread over buffered counts, this one on the owner over current fields |
| validation result | Outcome of exact validation: *externally referenced*, *unreachable* or *zero-count member* | — | keep; a plain description |
| externally referenced | Validation result for a component whose counts exceed its internal edges; the candidate bit stays set and the root is re-offered | live | keep; replaces *acquitted* |
| unreachable | Validation result for a component whose counts are fully explained; it is selected for cycle finalization | garbage; white (Bacon and Rajan 2001) | keep; replaces *condemned* |
| zero-count member | Validation result for a component one of whose members already reached zero count; the proposal is dropped, and what becomes of its other roots is `dev/ALGORITHM-AUDIT.md`, B1 | — | keep; replaces *corpse* in the collector |
| guard reference | Temporary `+1` strong reference on each member of a validated component that prevents recursive zero-count teardown during cycle finalization | keep-alive reference (.NET `GC.KeepAlive`) | keep |
| cycle finalization | Ordered guard, weak-reference invalidation, user destructors, revalidation, severing and reclamation of a validated unreachable component (`model/gc/rc-cycle.md`, "Cycle finalization and reclamation") | finalization (Handbook, ch. 12) | keep; qualified as *cycle* because ordinary object teardown is the other protocol |
| deferred slot reuse | Delay between an entity's teardown and its slot's reissue while a queue entry or a trace can still identify the old occupant; the owner returns the slot after both conditions are false (`model/gc/rc-cycle.md`, "Zero-count entities pending slot reuse") | deferred reclamation; safe memory reclamation (Michael 2004) | keep |

### Lifecycle

| Term | Denotes | Established equivalent | Verdict |
|---|---|---|---|
| zero-count transition | Reference-count change that reaches zero and starts ordinary object teardown | count reaching zero (Handbook, ch. 5) | keep |
| ordinary object teardown | The three phases a zero-count entity runs at once: user destructor, field/resource teardown, storage reclamation, with weak references invalidated before the fields are released (`runtime/object-lifecycle.md`, "Teardown: three phases") | object deallocation | keep |
| user destructor | PHP `__destruct` | finalizer (Handbook, ch. 12); destructor (C++) | keep; *destructor* is PHP's word |
| field/resource teardown | Runtime release of an entity's owned fields and internal resources, `drop` at the ABI | drop glue (Rust); `tp_clear` (CPython) | keep |
| weak-reference invalidation | Nulling every weak reference to an entity before its storage can be reclaimed (`model/weak-references.md`, "Death notification") | weak-reference clearing (Handbook, ch. 12) | keep |
| storage reclamation | Return of an entity's storage to its allocator or the operating system | reclamation, freeing | keep |
| thread-exit teardown | Release of a thread's runtime state at thread exit; its ordering against traces and block adoption is `dev/ALGORITHM-AUDIT.md`, A4 | thread exit cleanup | keep |
| live | Reachable through an external counted reference, or conservatively treated as such | live (Handbook) | keep |

### Values, objects and FFI

| Term | Denotes | Established equivalent | Verdict |
|---|---|---|---|
| ValueBox | 16-byte tagged dynamic value: a tag word and a payload (`model/values.md`, "ValueBox Layout") | tagged value; `zval` (Zend) | keep; a named type |
| immediate value | Value carried in the ValueBox payload with no pointer: integer, float, boolean, null | immediate (Smalltalk-80) | keep |
| unboxed slot | Declared-type property or local holding its machine representation with no tag (`model/values.md`, "Unboxed Representation") | unboxed value (Peyton Jones and Launchbury 1991) | keep |
| COW | Copy-on-write, a per-entity flag; a COW entity's count equals its number of holders (`model/values.md`, "Copy-on-Write Protocol") | copy-on-write | keep |
| class descriptor | Immortal per-class structure holding the vtable, the interface tables and the metadata (`model/classes.md`, "Class Descriptor") | class object; vtable (C++) | keep |
| headerless FFI value | Value of C layout with no Limelight entity header, declared `#[FFI]`; its ABI layout is specified separately (`model/memory/zero-abstraction.md`, "Definition") | unmanaged type; blittable type (.NET) | project-specific: *unmanaged* says the value is not an entity without naming what is missing, and the header is what is missing |
| FFIBox | Entity kind 10: the managed box that attaches a headerless FFI value to the managed world | handle; `SafeHandle` (.NET) | keep |

### Hash table

| Term | Denotes | Established equivalent | Verdict |
|---|---|---|---|
| collision defense | The table's bounded response to constructed collisions: two thresholds tested on insert, and the states their crossing moves the table between (`model/arrays-hashtable.md`, "Defense against constructed collisions") | hash-flooding defense (Crosby and Wallach 2003) | keep; replaces *flood ladder* |
| collision-defense state | One of four states of a table's index: ordinary indexing, salted rebuild, keyed-hash escalation, admission denial (`model/arrays-hashtable.md`, "Defense against constructed collisions"; `model/maps.md`, "What the flood ladder becomes") | hash-flooding defense (Crosby and Wallach 2003); keyed hashing (SipHash, Aumasson and Bernstein 2012) | keep |
| chain-length threshold | Chain length whose crossing advances the table's collision-defense state: a salted rebuild at the first firing, keyed-hash escalation at the second, admission denial after that (`model/maps.md`, "What the flood ladder becomes") | — | keep; a named number |
| equal-hash threshold | Count of distinct keys sharing one full hash whose crossing escalates a string table to the keyed hash, drawing the salt on the way, and denies admission where no rebuild remains (`model/maps.md`, "What the flood ladder becomes") | — | keep; a named number |
| admission denial | Non-memory failure to admit a new key after the defenses are exhausted; the caller catches it, and it is never an allocation failure | — | project-specific: the literature's defenses degrade the hash and none refuses a key; the terminal state here refuses, and its difference from an allocation failure is the one a rename can destroy |

### Journal

| Term | Denotes | Established equivalent | Verdict |
|---|---|---|---|
| journal | Debug-mode event log: one ring per thread, fixed 32-byte records written by the owning thread without a lock and read by an investigator between two marks (`ll-model/dev/design/debug-modes.md`, "9. The event journal") | trace buffer; per-CPU ring buffer (ftrace, LTTng) | keep; *trace buffer* is the field's word and *trace* is reserved here |
| journal ring | A thread's ring buffer of records, named by a registration identity rather than by its address | ring buffer | keep |
| journal window | The interval between two marks, answered per ring: its records, or why it cannot answer (`ll-model/dev/design/debug-modes.md`, "9.3 The ring, and how a window is marked") | trace window; snapshot interval | keep |
| never-journaled thread | Thread that never obtained a ring, because the allocator returned none or the thread cannot guarantee the ring's retirement; it is in no window, and the count of such threads is cumulative for the process. A thread whose journaling ended is not one: its later records are what `Window::Lost` counts (`ll-model/src/journal/mod.rs`) | — | project-specific: tracers report lost, discarded or overrun records (perf `LOST`, ftrace overrun, LTTng discarded events) and allocate their buffers when a session starts, so they have no per-thread outcome for a buffer never obtained; *untraced* is the natural derivation and *trace* is reserved, and *unjournaled* would also describe a thread whose journaling ended. `Window::NeverJournaled { threads }` replaces `Window::Refused { threads }` |

## Deprecated terms

Each row is one sense and one literal replacement. A word with two senses has
two rows. A heading that carries one of these words is quoted as it stands
(writing rule 6); the table governs the prose around the quotation and every
identifier.

| Deprecated term | Where it stood | Rename to |
|---|---|---|
| accelerator | collector | collector worker |
| acquit, acquitted | validation | externally referenced |
| class filter | collector | acyclic-class filter |
| clean point | collector | consistent point |
| collection arena | collector | trace scratch arena |
| condemn, condemned | validation | unreachable |
| corpse | collector, a member whose count reached zero | zero-count member; for the entity itself, zero-count entity |
| corpse | reset window and `promote` | torn-down entity |
| credit, credited | reset window | deferred decrement |
| critical door | allocation | reserve allocation path |
| death, `record_death`, `has_died`, `DIED`, `DEATHS` | reset window | completed teardown, `record_completed_teardown`, `is_torn_down`, `TORN_DOWN`, `TEARDOWNS` |
| dirty pass | collector | speculative trace |
| dirty reader | collector | collector worker |
| enrol, enrolment, enrolled | candidate queue | register, candidate registration, registered |
| enrolment bit | candidate queue | candidate bit |
| enrolment gate | candidate queue | candidate gate |
| enrol, enrolment | sweep list of `cycle/arena` and `memory/heap` | attach to the touched list, touched-list attachment |
| escrow | candidate queue | overflow buffer |
| escrow, escrowed | reset window and `promote` | deferred increment |
| exact judgement, exact test | validation | exact validation |
| flood ladder | hash table | collision defense |
| in-line collection | collector | synchronous collection |
| judge | validation | validate |
| judgement | validation | validation |
| law | ownership | ownership invariant |
| mature candidate | collector | candidate at the traversal age threshold |
| met bit, met bitmap | trace scratch | row-initialization bitmap |
| ordinary door | allocation | ordinary allocation path |
| park a slot, parked slot | collector | defer slot reuse, deferred slot |
| park, `park_large`, `parked_large` | reset window | deferred free, `defer_large_free`, `deferred_large_frees` |
| pre-destructor | lifecycle | user destructor |
| promote bound | collector | traversal age threshold |
| real destructor, when it means `drop` | lifecycle | field/resource teardown |
| refused, as a carry outcome (`ExternalCarry::Refused`, `OutsideCarry::Refused`) | arena reset | pinned, `Pinned` |
| refused, as a journal answer (`Window::Refused`) | journal | never journaled, `NeverJournaled` |
| release log, release-at-reset log | arenas and the store barrier | release-at-reset list |
| ring, when it means a graph | collector | reference cycle |
| root queue | collector | candidate queue |
| rung | hash table | collision-defense state |
| shortlist | collector | validation batch |
| suspects buffer | collector | deferred-candidate buffer |
| sweep, of the touched list | trace scratch | clear |
| trace claim | collector | trace-token acquisition |
| unmanaged entity | FFI | headerless FFI value |
| verdict | validation | validation result |
| zero-abstraction type, zero-abstraction entity | FFI | headerless FFI value; the file name `zero-abstraction.md` waits for its own migration |

## Context-sensitive words

A word here has one ordinary sense that stays and one or more term senses that
resolve by subject. The subject selects the replacement.

- *carry*, of a survivor's out-of-line storage at reset, is the canonical
  term above, and *evacuation*, *transfer* and *pinned payload* are its
  outcomes; prose names which. Elsewhere the verb stays ordinary English: a
  header *carries* a count.
- *claim* stays ordinary English for an assertion. Synchronization uses
  *acquire the trace token* or *trace-token ownership*.
- *death* and *destructor*, unqualified, resolve to the phase meant: the
  *zero-count transition*, the *user destructor*, *field/resource teardown*,
  *weak-reference invalidation* or *storage reclamation*. A heading such as
  `model/weak-references.md`, "Death notification", is quoted as it stands.
- *dirty* as a destructor effect class stays (*a dirty destructor*, the
  reset's class). *Dirty pass* and *dirty reader* are deprecated above.
- *dispose* and *drop* stay as ABI and source identifiers. Prose names the
  operation they perform: *user destructor invocation*, *field/resource
  teardown* or *storage reclamation*.
- *door* resolves to *allocation path* (a route a request for memory takes),
  *entry point* (a function a caller reaches: an ABI entry, a store function),
  *mailbox*, *channel* or *store-barrier form* (one of the barrier's
  micro-operation sequences, `store_ptr` or `store_box`). An OS resource is
  named exactly. The crate's `ll-model/dev/design/door-sites.md` classified its sites
  against this list.
- *floor* stays for a mathematical lower bound. Provisioned memory is the
  *queue base block*, an *initial segment*, *baseline capacity* or an exact
  byte count.
- *native* resolves to *machine code*, *standard PHP*, the *machine stack* or
  *foreign code*.
- *owner* in a cross-module contract says which: *containing entity*,
  *owning mutator*, *block owner*, *lifetime anchor* or *unique-ownership
  proof*. A local variable may stay short where its type fixes the role.
- *park* of a thread, actor or fiber stays: `std::thread::park` and Java's
  `LockSupport.park` are the field's word. *Park a slot* and the reset
  window's *park* are deprecated above. The *park set* of
  `model/memory/large-entities.md` belongs to the deleted collector's epoch
  (`dev/PLAN.md`, Fog) and is a record until that document is re-based.
- *pin* has two established senses and both stay: a *pinned object* is one
  whose address escaped and which may not move; a *pinned block* is a retained
  block held for a *pinned payload*, storage a carry left in place.
- *pure*, of a destructor, is the reset's effect class when the subject is
  what a round of destructors can add, and P0 to NR when the subject is the
  ladder of `model/gc/pure-destructors.md`, which is a record. Otherwise it
  means no observable side effect.
- *refusal* and *refused* resolve by subject: a request that returned null on
  every allocation path is an *allocation failure*; a placement a class does
  not support is an *unsupported placement*; a key the table will not admit is
  an *admission denial*; a bounded structure at its limit is at its *capacity
  limit*; a design alternative is *rejected*; storage an evacuation left in
  its source block is a *pinned payload*; a thread that never obtained a
  journal ring is *never journaled*.
- *retained* is the arena reset's word: a *retained block*. A candidate exact
  validation keeps is *externally referenced*; a queue entry that is not
  removed *stays*.
- *scalar* names a PHP scalar type only where that type set is meant.
  Representation text uses *immediate value*, *non-pointer value* or the exact
  primitive type.
- *sweep* is reserved for the mark-sweep phase, which `rc-cycle` has none of.
  The end-of-scan operation over the touched list is a *clear*.
- *teardown* is qualified where more than one protocol is in scope: *ordinary
  object teardown*, *field/resource teardown*, *thread-exit teardown* or
  *cycle finalization*. It never means storage reclamation alone.
- *trigger* stays ordinary English for what started a collection and for the
  barrier's edge-triggered registration
  (`model/gc/strategies.md`, "Collection requests and triggers"). The hash
  table's *trigger* is the *chain-length threshold* or the *equal-hash
  threshold*, whichever the site tests.
- *window* is a term only as the *reset window* and the *journal window*.
  Other windows are ordinary intervals.
- *live*, *held*, *top* and *drain* stay ordinary English outside the
  candidate queue's renamed identifiers.

## Spelling and style

The RFC uses US English: *behavior*, *materialization*, *serialize*,
*judgment*, *color*. Names copied from an external API retain that API's
spelling. A sentence states the rule first and its history or evidence second.
Decision dates belong in a short rationale paragraph, not in the normative
sentence itself.
