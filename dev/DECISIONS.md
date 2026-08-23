# Architecture decisions

A changelog for architecture: what was decided and why, not what
changed in the code. Newest on top. A superseded decision is left in
place and replaced by a new entry, never edited away.

Format per entry (3–6 lines): date + one sentence on **what** was
decided; **why** (the problem or constraint); **rejected** alternatives
in one line; **cost** if any.

---

## 2026-08-23 — what a shared object is inside an actor, and what a moved one is

**Decided (Edmond).** An actor is a virtual thread and the memory manager
already works per thread, which is what makes both forms below work at actor
scope.

**Shared.** When a shared object reaches an actor, the message carries a
**copied pointer**, not the object. The object stays in the other, genuinely
shared memory; the actor reads it by dereferencing and **does not own it** — it
writes no count and can free nothing. In this design's own vocabulary the actor
holds an uncounted reference, the shape `model/gc/gc-horizon-cases/weakref.md`
describes for a cell's `target`.

**Moved.** A move into an actor is possible too. A moved object joins a
**list of moved objects** and is handled exactly as an object moved into
another thread is handled today.

**Why:** the payload table of [../runtime/actors.md](../runtime/actors.md)
described the share form as "immortal and frozen-COW values pass by reference",
and the value model of record carries no frozen-COW class, so the one stated
exception to "nothing enters an actor except through the queue" named something
that does not exist.

**Owed, and not decided here.** What guarantees a shared object's lifetime while
an actor dereferences it — the owner it was created under, or a lease for the
duration — asked and unanswered. How an actor's own collection avoids reading
the copied pointer as one of its own edges: it must be invisible to that walk
the way a weak cell's `target` is, or the exact test balances against memory the
actor does not own. And what the moved-objects list holds, who appends to it and
who clears it: the arena's escapee list with its hold-counts and its promotion
at reset is the analogue this generalizes
([../model/memory/arena-reset.md](../model/memory/arena-reset.md)), and no such
list exists in the crate or in these documents today.

## 2026-08-23 — a weak reference does not cross the actor queue

**Decided (Edmond):** two limits on what a message may carry. An object that
holds a `WeakReference` is not sendable at all — the cell is an entity of its
own, shared by every copy of the handle
([../model/weak-references.md](../model/weak-references.md)), and neither
packing form works on it: a deep copy would leave the copied cell's `target`
pointing into the sender's arena, which the queue exists to prevent, and
sharing is reserved for values with no mutable state. And an object that is
itself the **target** of a weak reference may not be moved: the move is a
pointer handoff, so the entity would leave the sending actor while its
subscription row stays in the sender's table. Move is refused for it and the
send falls back to a deep copy, whose result is a new entity nobody is
subscribed to — the sender's cell keeps naming the original and nulls when the
original dies.

**Why:** the payload discipline is chosen per allocation site
([../runtime/actors.md](../runtime/actors.md)), and weak subscription is not a
property of an allocation site — `WeakReference::create` can run at any later
moment. The enforceable test is per entity at pack time: flag 7,
`HAS_WEAK_REFERENCES` ([../model/classes.md](../model/classes.md)), is already
set on a subscribed entity, so packing reads it and refuses the move. The
holds-a-cell half is statically decidable wherever the class is closed.

**Cost:** a proven-transferable object that gains a subscriber before the send
pays a deep copy instead of a pointer handoff, and the compiler cannot predict
which objects those are, so the cost is unbounded in the static analysis and
bounded per send by the subgraph's size.

**What it does not close:** node E1. Both limits are about the queue, and the
weak table's failing shape is about **migration** — an actor creates a weak
reference while mounted on one thread, migrates between messages, and its
entity dies on another thread whose table holds no row for it. No message
crosses in that shape, so neither limit reaches it.

## 2026-08-23 — one word at the mount; an interior path takes the owner as a parameter

**Decided:** the scheduler installs exactly one word of per-thread runtime
state when it mounts an actor and clears it at unmount — the mounted-context
pointer. Slot 0 is the compiled fast path over the same value, and null stays
the legal no-context state, resolving through it. That word answers **which
actor executes on this thread**, and nothing else. It does not answer which
actor owns a piece of work, so an interior path — the arena reset's destructor
fixpoint, the verdict drain, the synchronous collection, the static-block
teardown — takes the owner it works on as a parameter and presents that
owner's context to any user code it runs. The mount is a fallback only where
the executing actor is the owner by construction, which mutator-path death is,
the queue being the only door.

**Supersedes**, in the first entry of this date, the sentence "Nothing is
installed, swapped or restored when the scheduler mounts an actor": one word
is installed and nothing else. It also strikes three claims the review chain
found in the working design — that the context is the single home of actor
state, that interior paths resolve through the mount, and that the C-standard
allocator surface does. That surface reads no context at all: it dispatches on
the block header and on the thread's heap, with a cross-thread path (`ll-model`
`src/memory/stdapi.rs`), and it stays that way. The second entry's rejection of
a thread-local owner read on the death paths is **reaffirmed**: with the owner
as a parameter those paths carry no thread-local read, which is what that
rejection's ground required.

**Why:** the mounted actor and the owning actor differ on a pool thread. With
actor B mounted, the synchronous collection can run actor A's destructor — it
enumerates process-wide (`ll-model` `src/walk.rs`, `src/memory/heap.rs`) — and
a store inside that destructor logs A's entity on the **mounted** arena's
escapee list (`src/memory/barrier.rs`). The reset that follows retains a block
the owning arena later returns to the pool, which leaves a live promoted entity
in recycled memory and a wild read for every walk after it.

**The convention stays one.** Entity teardown, release and the checkpoint gain
the context parameter, which the first entry's cost paragraph already priced.
An entry without the parameter asserts that it reads thread-owned resources
only and never resolves the mount; those entries are enumerated in one
inventory, so a new one is an edit to that inventory rather than a silent
addition.

**Thread exit needs a context of its own.** `ll_thread_exit` installs one
around the static-block teardown — the single step that runs `__destruct`
bodies, which allocate (`ll-model` `src/static_block.rs`) — and disposes it
before the steps that dispose what its reset touches. Without it the
no-context path panics, and a panic there cannot unwind out of a destructor:
under `panic = "abort"` it ends the process (`ll-model` `Cargo.toml`).

**The context's arena field changes only where the one-mounted-request-arena
premise holds** ([../model/memory/arenas.md](../model/memory/arenas.md)). A
region-shaped field is rejected: the barrier compares a two-bit category and
cannot tell two request arenas apart, and the reset's dirtiness test reads the
resetting arena's cursor while such destructors would move another's. Regions
stay deferred behind the cross-arena design `arenas.md` already names, with one
constraint recorded for it — a region-entering frame has at least four exits:
normal, unwind, a channel-R error return
([../runtime/exceptions.md](../runtime/exceptions.md)), and suspension, for
which this repository has no frame model.

**Rejected:** moving the six per-thread structures — weak table, the
non-default strategy's candidate buffer, the deferred-free park list, the reset
window with its died set, the drain gates, the static-block registry — into the
context. It would decide node E1 by construction and dismantle the explicit
thread-exit disposal order the crate rests on. Also rejected: recording that the
drain "runs while its owner is mounted", since the verdict queue carries no
owner field, so the drain's soundness condition until node D1 is the
single-mutator invariant.

**Open, with owners:** which of the six structures are actor state, and the
epoch duty and re-entry slot a foreign crossing would need — node E1
([../model/gc/walk/questions.md](../model/gc/walk/questions.md#e1-actors-and-the-epoch-protocol--structures-resolved-2026-08-23-the-stamp-half-stays-open));
the message owner field and pickup routing — node D1; the entry shim for a
callback on a thread this runtime did not create, and a C-callable writer for
the mount word, which does not exist today (`ll-model`
`src/memory/context.rs`); the region design and the suspension frame model, as
above.

## 2026-08-23 — the actor context travels as an argument: context-aware functions

**Decided (Edmond):** a function that works with an actor takes the actor
context as an argument — a **context-aware** function. Nothing is installed,
swapped or restored when the scheduler mounts an actor: no per-thread copy of
actor state exists, so there is no base to re-point and no cache to
invalidate. A function that is not context-aware does not touch actor state
at all, and reaching one is a boundary crossing.

**Supersedes the second half of the entry below**, of the same day, which
served an extension's module globals by re-pointing one pointer at the mount.
That half is unnecessary where an extension is compiled against this
runtime's headers: the macro through which a module reads its globals is ours
and resolves through the context the function already received, so the
extension's source does not change either way. The first half stands — code
this compiler emits carries the context.

**Why:** every alternative buys the same reachability with a worse property. A
swapped base or a reserved register reaches the owner without an argument and
leaves open what happens at a boundary this runtime did not compile. Copied
cells leave two copies of one state, invalidate every address taken inside
them, and need a guaranteed write-back when a message ends in an abort. An
argument in a register is also cheaper to read than a thread-local, so the ABI
change is not a cost to defend.

**Cost:** the runtime's PHP-facing surface changes shape — release, entity
teardown and the epoch checkpoint gain a parameter they do not carry today.
Not measured.

**Open:** entry from code this runtime did not call — a callback from a C
library, a thread that library created — arrives with no context and needs an
entry shim to establish one. And a `static` inside libc or a third-party
shared object is reached by none of this: it needs a declaration from the
module or an actor pinned to a thread.

## 2026-08-23 — per-actor state: the compiler carries the context, the mount swaps one pointer

**Decided (Edmond):** state that must follow an actor is reached two ways,
and which one applies depends on who compiled the code. Code this compiler
emits takes the actor context the way it already takes the allocation
context — in a register, so no path it emits reads a thread-local to find
its owner. Code it does not emit, a C extension reading its module globals,
keeps its source and is served by the scheduler at mount: the pointer
re-pointed is `storage`, the first field of the per-thread TSRM entry, which
the module accessor reads as `(*(void ***) cache)[id]` (php-src `TSRM/TSRM.c`,
`struct _tsrm_tls_entry`; `TSRM/TSRM.h`, `TSRMG_BULK_STATIC`).

**Why:** a function called from an actor executes as the actor and knows
nothing about it, so a `static` inside it makes the actor's state outlive
the message. A process-global one races across threads and is overwritten
across actors on one thread; a thread-local one survives the actor and is
lost when the scheduler moves it. PHP's threaded build already reduced
every extension's globals to one indirection through a per-thread vector,
so re-pointing that indirection makes the ecosystem actor-local without a
line of it changing. CPython met the same problem in the same kind of
ecosystem and answered it by contract rather than by mechanism: module
state in a struct instead of statics (PEP 489), and a module that does not
declare support for several interpreters is refused (PEP 684).

**The pointer is swapped, never the contents.** Copied values leave two
copies and a rule about which is authoritative; one pointer leaves one
copy, in the actor.

**The module's own cache needs no invalidation.** Each shared object holds a
`__thread` copy of the cache pointer, and that pointer names the entry, not
the storage vector; the entry is per-thread and does not move, so a swap of
`storage` under it is invisible to every cached copy. What is not valid
across a change of thread is anything else derived from the old one.

**The swap is legal at a message boundary alone**, which is where the
scheduler mounts.

**One access path the swap does not reach.** The engine's own globals are
resolved by an offset from the entry block rather than through `storage`
(`TSRMG_FAST_BULK_STATIC`), so re-pointing `storage` does not move them.
Limelight has no Zend core and supplies those names from a shim header;
through what indirection the shim defines them is undecided.

**Rejected:** one universal runtime reading the owner from a thread-local
on every path. It puts a dependent load on the death paths, which are the
paths carrying no context, and buys nothing on the paths that already carry
one.

**Open, and not decided here:** how the runtime's own death paths — release,
entity teardown, the epoch checkpoint — reach the owner. They carry no
context today and do not read the extension vector, so neither half of this
decision reaches them
([model/gc/walk/questions.md](../model/gc/walk/questions.md#e1-actors-and-the-epoch-protocol--structures-resolved-2026-08-23-the-stamp-half-stays-open)).

## 2026-08-22 — copy-on-write outranks the unique-ownership proof

**Decided (Edmond):** where a COW-eligible entity is also proved uniquely
owned, COW wins and the count is maintained. The unique-ownership proof
establishes lifetime — one owning slot, death at the overwrite — and
lifetime is not what the separation test asks, so the proof neither
answers it nor licenses removing the count.

**Why:** the separation test reads the count to decide whether a write
copies ([values.md](../model/values.md#refcount-is-always-maintained-on-cow-entities)),
which is value semantics rather than bookkeeping. A count word holding the
occupancy sentinel would answer that test with a constant.

**The other road is a separate instrument.** The compiler may prove COW
itself unnecessary for an entity and **clear the COW flag**, one bit of
`RcHeader.flags`, non-COW arrays and objects already existing
([values.md](../model/values.md#cow-is-a-per-object-flag)). That proof is
explicit and owed on its own terms, and only after it does the entity
leave COW and become eligible for the unique-ownership treatment. Strings
are outside it: there the flag is the layout and is fixed at creation.

**Rejected:** reading `values.md`'s elision licence — "only where it has
proved that no second holder arises" — as discharged by the uniqueness
proof.

**Cost:** a uniquely-owned array keeps today's count and today's
separation check until the COW-clearing proof exists.

## 2026-08-22 — the capture-count regime is refused; the counted walk is the design of record

The second design (`model/gc/gc-horizon-v2/`) stopped counting heap edges
and left the concurrent walk to find them. Two findings closed it.

**Soundness.** A walk reads each entity once, at different times. A
reference moved from an unread entity into an already-read one is invisible
to it, and under the regime no count moves to record the move. With zero
per-store instructions the collector's observations are identical between
"moved and live" and "dropped and garbage" — node M of that folder's
`questions.md`, verified against the text in two review rounds.

**Semantics.** The count is not only a barrier. It frees promptly at zero,
answers the copy-on-write uniqueness test, and carries the arena's escape
hold-count. Removing it from heap edges costs prompt `__destruct` for every
entity held only through the heap, which `model/weak-references.md` already
refused for one map type, and which `model/gc/gc-horizon.md` refused once
before for Form B.

The design of record is `model/gc/walk/`: the counted heap edge stays the
write barrier, the walk stays the cycle collector, and the work moves to
making each cheaper. The rulings that bound it and the open questions are in
`model/gc/walk/questions.md`. `gc-horizon-v2/` is kept as the record of the
refused road; its nodes M and N are the argument and are not re-derived
elsewhere.

## 2026-08-21 — the horizon pays by publishing, and the second design gets its own folder

**Decided (Edmond):** the payment at a GC horizon is a publication the
collector reads, not a `retain`. The second design lives in
`model/gc/gc-horizon-v2/`, which is marked as the current one;
`model/gc/gc-horizon.md` stays in place as the record of the first
design and carries a banner pointing at the folder.

**Why:** the first design keeps the mutator's reference count on every
local that reaches a horizon, because the count is what makes a root
visible — `RC - IN > 0` is the only channel a stack-free collector has.
A publication carries the same fact for less: the epoch byte already
means "do not judge this slot", the mutator already writes it once per
entity at allocation, and the walk clears it by ageing, so nothing has
to be retracted. With publication available, a class of entities needs
no mutator-maintained count at all.

**Rejected:** a sticky local-root bit with a canonical owner, which the
first design's Form C proposes — it needs a clearing operation the
collector does not have, and `$b = $a; unset($a)` breaks the single
owner; a fifth memory-category code for the deferred regime, which would
take the entity out of the census that enrols only `GcHeap`; forbidding
a deferred entity in a compiler-owned field, which needs a test on every
store into such a field and so is a write barrier.

**Cost:** the epoch byte becomes a safety gate, and `rc-walk` states
today that no byte is one — a lost mark is a freed live entity, where a
lost stamp costs a wasted message. Phase 4's exact test has no count to
re-read for a deferred entity, and the ordering of a mark against a
concurrent walk is unsolved. Both are open questions in
`model/gc/gc-horizon-v2/top-level.md`, and no entity leaves the first
design until they close.

## 2026-08-20 — the borrow-elision design enters the RFC as GC horizon, and the chain rule amends two normative sections

**Decided (Edmond):** the algorithm named `proof-horizon` in the code
repository's design notes is called **GC horizon** and lives here, as
`model/gc/gc-horizon.md`, with its state set beside it and a case book
of sixteen files under `model/gc/gc-horizon-cases/`. The purity ladder
it depends on moved with it (`model/gc/pure-destructors.md`), two of the
eight horizon kinds having cited an instrument this repository did not
hold.

**Why:** the design was normative nowhere. Its text sat in a code
repository beside three reading aids, while the sections it contradicts
— [static-lifetimes.md](../model/memory/static-lifetimes.md), "What may
own a borrow", and [rc-walk.md](../model/gc/rc-walk.md), "Uncounted
borrows" — sat here saying a heap field never covers a borrow. Both now
carry the chain rule: a field covers a borrow on a counted path from a
root, with the borrow counting as a use of that root. DC5's mitigation
sentence follows them, and the case that made it condemns the same shape
under either reading.

**Rejected:** copying the algorithm and keeping the design note as a
working copy (two texts reading as normative drift silently); moving the
two reading aids as standalone RFCs (they would re-split the normative
surface the move exists to unify); a single combined cases file on the
`rc-walk-danger-cases.md` pattern (Edmond asked for a folder).

**Cost:** the algorithm's economics and measurement order now sit in the
specification while the process that revises them — the corpus veto, the
summary-language rulings — stays in `model/dev/DECISIONS.md`; the moved
document names that file as the place its open choices change. Dated
entries there keep the old name verbatim.

---

## 2026-08-07 — entity-kind codes leave the RFC; the enum is normative

**Decided (Edmond):** no document here prints the code of an entity kind.
A kind is named — Object, StringBox, ArrayBox, ReferenceBox, FFIBox,
WeakRef, Lazy — and where a code form is needed the text writes
`EntityKind::…`. The assignment of code to kind is normative in
`EntityKind`, `ll-model/src/refcount.rs`, and a consumer takes it from
the runtime's exported ABI rather than by transcription; a hardcoded code
is a defect even when its value happens to be right.

**Why:** the code is a detail of the encoding, and restating it here made
the design depend on it. The runtime's cycle-collector admission test was
written as a bitmask over the codes, could not express the set it needed,
and leaked a ring through a ReferenceBox until it became a set built from
the names (`ll-model` f2f2461). `classes.md` carried the same defect as a
parenthetical claiming the buffer holds only objects and arrays, which
bit 13 separates.

**The test for what may still print a number:** the sentence stays true
under any permutation of the code-to-kind assignment. The field's width
and position (three bits at 12–14) and the count of codes used and
reserved pass it; a kind-to-code pair, and any argument from the order,
adjacency or bit pattern of the codes, do not.

**Rejected:** one normative table of codes kept inside the RFC (it is the
thing the ruling removes); building an ABI header or `cbindgen` now (no
consumer exists, and the header's shape belongs to the whole ABI surface
rather than to this one row).

**Cost:** until that ABI surface exists, the assignment lives only in Rust
source, so a reader of `layouts.md` follows one link to see a concrete
byte. Historical documents keep the wording of their day, codes included,
and `layouts.md` says so where it introduces them. A grep is the standing
check: `grep -rnE '\bkind ?=? ?[0-7]\b' --include='*.md' .` may match only
under `dev/` and in the dated review records.

### 2026-08-06 — no cache in this runtime carries a replacement policy, and the personality routine gets a flag bit

**Decided:** `model/caches.md` is written, and its answer is negative — no LRU,
LFU, ARC or CLOCK anywhere. **Why:** nine production runtimes were read at source
level (Zend, V8, HotSpot, HHVM, CPython 3.12 and `main`, PyPy, LuaJIT,
JavaScriptCore, CoreCLR) and not one uses a classical policy for a dispatch,
property, method or type cache; every one overwrites in place, because the
entries are two or three words and any policy costs metadata work on every hit.
**The industry's one exception is a checklist Limelight fails.** HotSpot's code
cache qualifies because entries are kilobytes, the recency signal is free from an
entry barrier that already exists, reclamation batches into an existing pause,
and the policy disables itself under no pressure. `rc-walk` pauses the mutator
not at all, AOT calls are direct so there is no entry barrier, and nothing here
scans another thread's stack — so the conclusion is that **nothing qualifies,
including a future compiled-code region**, which therefore grows monotonically.
**Rejected imports:** HHVM's per-request generation byte, which names no site
here and is unsound for an actor that migrates between threads; and a CPython
class version stamp, which answers a question PHP cannot ask. **Also decided,
in `runtime/exceptions.md`:** the personality routine — the one genuinely
megamorphic site, since it sees a different class per call and has no site to
attach a cache to — takes a `Throwable` bit in the class flags plus the sorted
itable's binary search. A shared megamorphic table was rejected there: it would
buy back only the two-compare search while re-introducing the multi-writer
problem that per-site words avoid. **Standing rule recorded with it:** every
capacity limit names a degradation path, and it is never an abort — there is no
interpreter to fall back to here, so every path must be exact.

### 2026-08-06 — an inline cache site is one word pointing at an immutable pair

**Decided:** a site holds one word, published with a release store, pointing at a
`(class, target)` pair baked at class link time beside its method-table entry in
the immortal region and never written again. **Why:** the previous shape was two
independent process-global words, both written by the slow path on every thread
executing the site, so a reader could observe one thread's class beside another's
target and dispatch the wrong method on the wrong class — silently, with no
memory error, in a runtime that is multi-threaded by construction. Publishing a
pointer to an already-complete record removes the race by construction rather
than by ordering. **Baked, not allocated:** a pair allocated per cache update
would let a bimorphic site in a hot loop grow a region that is never reclaimed;
baking costs 16 bytes per method-table entry once per class, and a site
transition becomes one store with no allocation. An uninitialized site points at
a static `{null, null}` pair, so the fast path needs no emptiness test.
**Rejected:** a seqlock (two extra loads and a branch per hit); per-thread site
arrays (`sites x 16 B x threads`, cold start per thread); and packing a 48-bit
class pointer with a 16-bit vtable slot into one word — cheapest of all, and
sound because descriptors are immortal, but it stakes a claim on
virtual-address width that LA57 and ARM LVA make questionable. **Cost:** one
dependent load on the hit path, and one acquire load — free on x86-64, one
`ldar` on the ARM targets. **Invariant written down rather than assumed:** the
target half is valid only while compiled code is immortal, which phase 1
satisfies trivially and a tiering JIT would break; `lowering.md` names the two
shapes that survive tiering.

### 2026-08-06 — Ghost is the shim, and class metadata is immortal rather than long-lived

**Decided:** two contradictions inside `classes.md` are resolved by following
what another document already settled, so neither needed a new decision.
**Ghost:** `classes.md` described the mechanism twice and incompatibly — kind 6
keeping the real target class at `+8`, and a generated ghost-shim descriptor
swapped out on first touch. `lowering.md` had already settled it by dropping
`!invariant.load` for a class "whose class pointer is rewritten on first touch",
which describes the shim alone. The kind-6 passage is rewritten; kind 6 stays as
an instance marker for `clone` and reflection, which load flags anyway. **Why
the shim is also the only safe reading:** an inline cache's hit path compares the
class pointer and calls, never loading flags, so with the real class at `+8` a
warm cache would call a method on a zero-filled body — and teaching the hit path
to test kind 6 costs a load and a branch at every dynamic dispatch site.
**Residence:** `classes.md` said class descriptors and interned names live in the
long-lived arena while the crate puts both in the immortal region, and
`arenas.md` listed them under Long-Lived while its own Immortal row listed
interned strings. Immortal wins, following the code. It is load-bearing rather
than tidy: `arenas.md` leaves long-lived reclamation undecided, and a recycled
descriptor address re-issued to another class is a **false inline-cache hit**,
not a crash. **Retired with it:** the u32-offsets-from-an-arena-base option and
its 4 GB constraint — the immortal region is a chain of pool blocks with no base
and no bounded span. **Cost:** an `eval`'d or plugin class is never reclaimed,
which is acceptable while nothing supports unloading, and is now stated rather
than implied.

### 2026-08-06 — the chained index is the decision, not the default pending a measurement

**Decided:** the array hashtable indexes its entry array with chains, and the
question is closed rather than deferred. **Why now, without the equal-memory run
that was owed:** the margin lives at the sizes strategy 3 actually sees — 1.5x to
3x on build, both lookups and delete at N up to a few thousand, where the whole
table is cache-resident, so it is the cost of the path (two arrays and a group
probe against one slot read) rather than an effect of memory latency. An
equal-memory run would let the control-byte index run near load 0.55 and cheapen
its miss, but only at the large sizes where the two already meet within the
spread; it cannot move the small-N columns the decision rests on. **The
assumption it does rest on, stated so it can be attacked:** not that PHP arrays
are small — a small dense integer array is strategy 2 and never reaches the hash
— but that the tables reaching strategy 3 are mostly small and middling
associative ones. **Two non-performance grounds agree:** the flood backstop
counts entries with an equal full hash, which a chain walk visits exactly while a
probe run includes unrelated keys, so the counter is cleaner; and NEON has no
single-instruction movemask, so chains need no second probe implementation for
the ARM targets. **Cost:** about 3.4 bytes more index per entry, ~7 % of a
40-byte entry. The `next` field is not part of that cost — without it the entry
is 36 bytes, which the ValueBox's alignment rounds back to 40. **What reverses
it,** named in advance in the document: the control-byte index winning both
lookups by 1.5x or more on string keys at N from 56 to 28 672 without a worse
deletion margin.

### 2026-08-06 — the index comparison is measured at design load, and the control byte's advantage does not survive it

**Decided:** chains stay the default on measured grounds for integer keys. The
harness was rewritten after the retraction below: the slot count is now the power
of two for the control-byte index and the entry capacity seven eighths of it, so
a full table sits at 0.875 while the chained index sits at 0.4375 — each at its
own design maximum, printed with every row. Deletion follows hashbrown's
slot-anchored rule; a correctness pass over 200k keys with six rounds of churn
runs before anything is timed; every insert is lookup-then-insert; every timed
loop checks the count it produced; the two arms alternate. **Result:** the
absent-key lookup, which is the whole argument for a control byte, goes to chains
at every size but the largest, where the two are level — at 0.5 a chained miss
ends on the first slot read, while at 0.875 the control-byte probe walks two
groups on average and up to twelve. Deletion goes to chains everywhere by 1.3x to
3.1x. The control byte wins the build at the largest size only. **Not
established, and stated in the document:** string keys, where the seven-bit tag
filters a comparison a chain has to make in full; and the mixed workload, whose
run is discarded because the sizes gave one arm a full growth cycle of headroom
and the other none, so a single doubling sat inside the measurement and dropped
the table off its design load. **Cost:** the index memory is 9.1 bytes per entry
chained against 5.7 for the control byte, and that is the price of the default.

### 2026-08-05 — the index measurements are withdrawn, and the default stands on structure rather than on numbers

**Decided:** the benchmark numbers quoted in the entry below are retracted, and
`arrays-hashtable.md` no longer carries them. An independent review of the
harness found four defects: every table size was a power of two, so the
open-addressed index was allocated twice the slots it needed and never ran above
load 0.500 — the comparison the numbers claimed to make was never executed; the
mixed workload sized its tables for a theoretical peak and ran between loads
0.016 and 0.508; the tombstone rebuild that was supposed to separate two of the
runs could not fire at the sizes tested, so the explanation given for their
disagreement was false; and the deletion rule was not the one it was modelled
on, truncating the probe sequence of unrelated keys and losing live entries at
roughly one per seven hundred operations at realistic load. Two earlier defects
in the same harness had already been found and fixed — a timed `memset` of an
oversized index, and probing in insertion order, which walks the entry array
sequentially and erases the cost the control byte exists to avoid. **Why this is
recorded rather than quietly corrected:** the same numbers were used twice to
reverse a design conclusion in one day, and the failure mode is a harness that
silently measures a different structure than the one named. **Cost:** the choice
of index layer is now explicitly undecided; the requirements for a measurement
that would decide it are listed in the document's "Open" section. **What does
not change:** chains remain the default, on the structural argument — the dense
ordered entry array is required either way, PHP arrays are mostly small and
cache-resident where a control byte buys nothing, and deletion is frequent while
an open-addressed slot cannot be freed without leaving a tombstone.

### 2026-08-05 — the array hashtable is an index array over a dense insertion-ordered entry array, and the collision link moves out of the element

**Decided:** one allocation of `u32` index slots plus a dense 40-byte
entry array in insertion order; a lookup is two dependent accesses, and
no order-preserving design does better. The collision link is an explicit
`next` field at +16 rather than Zend's trick of threading it through the
element's own padding — `values.md` forbids per-slot state in bytes 10..15
because the store barrier writes all sixteen, so a value store would sever
the chain. The ValueBox sits last, at +24, so no write it performs reaches
the key or the link. **Rejected: SwissTable as storage** — insertion order
forces a dense ordered array to exist anyway, and iterating a control-byte
table costs about twice a dense stride (measured 6.8 against 1.2 ns per
element at 8 M). **Cost:** 40 bytes per entry against Zend's 32, plus 8
bytes of index at load 0.5.

### 2026-08-05 — the index layer is replaceable and the choice waits on a measurement nobody has

**Decided:** chains on `u32` are the default; the alternative is a `u64`
slot fusing a 7-bit fingerprint with the entry index, which is still two
dependent accesses. The entry array, promotion, the tracer and every
observable semantic are identical under both. **Why:** measured over a
byte-identical entry array, the fused slot wins absent-key lookups
(16.0 against 26.3 ns at 8 M) and loses badly after deletion (12.4 against
3.2 ns at 100 k), because an open-addressed slot cannot be freed and
becomes a tombstone, and a table that is deleted from and then only read
never reaches a rebuild. Moving the rebuild onto the delete path raised
deletion at 4 M from 18.7 to 61.3 ns. **What decides it:** the ratio of
`isset`-shaped lookups to reads in real PHP, unmeasured by anyone.

### 2026-08-05 — the flood backstop counts equal full hashes on insertion and escalates once to a keyed hash

**Decided:** count, per insert and against current state, the entries met
whose full 64-bit hash equals the new key's (constant threshold, since
eight-way agreement by chance needs ~2^56 keys) and the chain length.
Firing on the first escalates the table once to a keyed byte hash and sets
a one-way mode bit; firing on the second redraws the per-table salt.
Integer keys are indexed through a salted avalanche mix, not by value, so
`0, 1024, 2048, …` no longer share a bucket. **Why:** rapidhash is in the
family with published seed-independent multicollisions, so a salt over the
index cannot separate equal-hash keys, and redrawing it in response to
them is what made Perl's REHASH exploitable (CVE-2013-1667). **Rejected:
treeification** — the nodes fit neither beside a 16-byte ValueBox nor as
indices into an order-preserving array, and side allocation would make the
attacked path an attacker-triggered allocation. **Rejected: firing on
lookup** — `isset()` must not allocate, must not reallocate storage under
a live iterator, and has no synchronisation on a shared table. **Cost:**
one multiply on hash-resident integer keys, and folded hash constants go
unused in an escalated table.

### 2026-08-05 — the template object is an ordinary object, and nothing about it is generated per site except its class

**Decided:** parts and values alternate with empty parts allowed, so
there is always one more part than values and the offset map disappears —
the order is the encoding (JS tagged templates fix the same invariant).
Parts are interned immortal strings on the per-site class; the instance
is `RcHeader | class | Value[n]`, fixed size, walked by the ordinary
object tracer. **No new entity kind and no arrays**, which is what the
whole shape was chosen to avoid. **Dropped: the cached flattened
result** — rule 2 made the object's only consumer a structure-aware one,
which flattens rarely, so a slot on every instance serves a path most
never take. **Dropped: a generated flatten method per site** — rules 1
and 2 separated the cases, so the common path is straight-line code with
no object and the object path is rare; a function per site spends binary
size on what is seldom called, and the unroll threshold nobody could have
measured stops mattering. **Flattening** is Zend's two passes (sum,
allocate once, copy) with a value written into the result directly where
its length is knowable first, and with every `__toString` call completed
*before* the allocation, so user code cannot change what is being
assembled under it.

### 2026-08-05 — the template object is built only where the destination's declared type asks for it

**Decided:** materialization is the default everywhere; a template object
exists only when the declared type of the destination — a parameter, a
property, a typed local — is the template interface. `$db->query(...)`
with `query(InterpolateStringInterface $sql)` builds a template;
`$x = "$y 234"` builds a string, always. **Why:** the decision is one
lookup at the site, visible in the source, and the API author opts in
once for every caller — the arrangement C# uses, where the parameter type
selects the handler. **Rejected:** keeping the template wherever the
compiler cannot prove nobody wants the structure, which allocates at
every untyped site and makes the cost of an interpolation depend on an
analysis the reader cannot see; and forward flow analysis from the
assignment, which is more machinery for the same answer. **Cost, and it
is not small:** the protection follows the declared type, so a value that
reaches a call through an untyped variable was already materialized and
arrives as a string. SQL injection is impossible by construction where
the API declares the interface and the call reaches it directly, not
unconditionally — the section's earlier wording claimed more than that
and has been corrected.

### 2026-08-05 — an interpolated string used once and never stored is never built

**Decided:** the compiler decides at the interpolation site. Where it can
see that the result is consumed as a plain string and does not outlive the
expression, no template object exists at run time — the site compiles to
string assembly. `$x = "$y + 1"` is `$x = $y . ' + 1'`. **Why:** a template
that never escapes the expression gains nothing from being an object and
costs an allocation, a header and a free. **Assembly is one pass** — sum
the lengths, allocate once, copy each piece — because a chain of binary
concatenations produces an intermediate string per join; the two coincide
only at two pieces, which is why Zend keeps `FAST_CONCAT` beside its rope.
**Rejected:** guessing the result length the way C#'s handler does
(`literal_length + holes * 11`), because that trade assumes growth is
expensive and ours is not — a payload at the bump top grows without a copy;
and a stored lazily-flattened template for this case, which is LLVM
`Twine`'s shape and which `Twine` itself forbids storing. **Open:** the
rules for a structure-aware consumer and for a result whose type the
compiler cannot see.

### 2026-08-04 — folding a literal key's hash is a build option, and the seed goes with it

Supersedes the "Open" clause of the entry below, which left folding
undecided and defaulted to not folding. **Decided:** neither, it is
selected — one option (`hash-folding` in `ll-model`, off by default)
carries folding and the seed's home together, because a compiler that
folds must know the seed while it compiles and a per-process seed is not
knowable then. Off draws the seed from the OS per process; on fixes it at
build time and folds. **Why optional:** the trade is real in both
directions and belongs to whoever ships, not to the language. **Why off
by default:** the folded arm puts the seed inside the artifact, and an
attacker holding the artifact can then precompute colliding array keys.
**What folding buys is one load per literal-key access**, not the "few
multiplies" the entry below priced — a literal key is interned and its
hash is computed once per process at intern time — and that gain is
unmeasured. **Cost:** folded constants live in the program while the
function lives in the runtime, and nothing in the linker compares them, so
a folding build must carry a stamp of the hash's identity and check it at
startup. **Still not answered by either arm:** hash flooding. rapidhash
claims no resistance to key recovery from observed collisions, so the
table's probe-length backstop remains the only real defence, and it is
undesigned.

### 2026-08-04 — the string hash is chosen when the runtime is built, and defaults to rapidhash v3

The hash becomes a build-time axis like the GC strategy already is — an
`ll-model` cargo feature — with rapidhash v3 (vendored, constants
pinned, scalar) as the default short-input function, a frozen length
threshold, and a slot for a long-input function whose first occupant is
the same one. **Why build time:** we compile runtime bitcode and
generated IR together and re-optimize, so a build-time constant reaches
every call site as an inlined body, while a runtime choice would put a
function pointer on the hot path and cost the constant-folding of a
literal key's hash. **Why rapidhash:** fastest function passing SMHasher3
clean, no vector or crypto instructions, therefore inlinable in every
build mode including portable AOT. **Rejected:** xxh3 (its win is bulk
throughput this workload never reaches; seed-independent collisions on
record from its development), wyhash (superseded by the same author,
still failing the seed families), gxhash and aHash (need AES, so either a
pointer or a build that will not inline into baseline-featured IR).
**Long side is a strength decision, not a speed one:** an attacker picks
key length and so picks the function, making total resistance the weaker
of the two — HighwayHash-64 is the named candidate because it can carry a
per-process 256-bit key even where the short path's seed is baked into
the artifact. **Cost:** in the AOT modes the seed is extractable by
anyone holding the binary, so the hash table must carry a structural
backstop (probe-length counter with an escape hatch) rather than relying
on a secret. **Open:** the threshold is a measurement not yet taken, and
whether the compiler folds a literal key's hash at all — default until
measured is not folded, which keeps the seed out of the artifact.

### 2026-08-04 — a string is capped at 4 GiB, and the length gives up half its width to pay for capacity

`len` becomes `u32` at +8; the dynamic layout spends the four bytes of
padding at +12 on its `capacity`, taking that header from 40 bytes to
32. `hash` stays 64-bit at +16, so the shared-offset rule is untouched.
**Why:** an 8-byte `hash` must be 8-aligned, so a narrow length leaves
that padding whatever we do with it — capacity rides for free, and the
inline layout pays nothing, staying at 24 bytes. **Cost:** a 4 GiB limit
on strings, which is language-visible; every growth path checks against
it through one choke point and raises, since a silent 32-bit truncation
would write past the buffer. More generous than Java and C# (`2^31 - 1`
since release) and than V8; stricter than PHP, whose `zend_string` uses
`size_t` — a program reading a 5 GiB file into one string works there
and fails here. **Rejected: narrowing `hash` to 32 bits too**, which
would save a further 8 bytes and drop a 9-byte string from the 48-byte
size class to the 32-byte one — but that hash must serve both the bucket
index and the Swiss-table control byte, and full-hash collisions would
begin around 65k keys; revisit when Phase D shows the real length
distribution. **Rejected: a transparent long-string form** — it would
add a branch to every string operation and spend the last free
`EntityKind` code (seven of eight taken). Strings beyond the cap arrive
later as a separate class the programmer chooses, a stream or a rope.

### 2026-08-03 — the COW flag is the string layout, and a dynamic string never copies on write

Supersedes the sub-mode bit and the separating append in the entry
below (Edmond). `COW = 1` means bytes inline, `COW = 0` means a dynamic
string with its bytes out of line; the flag is set at allocation and
never flips, so every path reads the layout from a bit that cannot have
changed. **Why:** the flags word has no free bit — the layout test in
`ll-model/src/refcount.rs` accounts for all 32 — and a dynamic string is
exactly what the non-COW form of that flag has always denoted: freely
mutable, no copy on write, no sharing test. **Consequence:** a dynamic
string is outside the barrier rule, so its safety rests on the compiler
allocating one only where it has proved a single owner; where the proof
fails it allocates inline COW. **Rejected:** carrying the sub-mode in the
high bit of `len` (free by construction, since no string reaches 2^63
bytes) — unnecessary once the COW flag answers it, and it would have put
a mask on every length read.

### 2026-08-03 — strings: two layouts, no freeze, and the COW rule reads the category first

Freeze is dropped and the two string layouts are settled (Edmond).
Inline and dynamic differ only in where the bytes are; `len` and `hash`
sit at the same offsets in both, so only byte access and teardown branch
on the sub-mode. The layout is chosen by the compiler at allocation —
dynamic where it sees the string being appended to — and there is **no
runtime promotion between layouts**: rewriting the body under a header
`rc-walk` may be reading concurrently is the same objection that killed
freeze, and it is symmetric. **Why freeze fails:** it was specified as a
mode-bit flip, and no bit moves bytes from inline to out of line. Its job
is done instead by the ordinary COW rule, which now reads **category,
then `IS_ESCAPEE`, then the count** — an immortal entity's count is
pinned at 1 by the retain/release early-outs, so a bare count test would
have grown an interned literal in place and overwritten its neighbour.
A separating write on a dynamic string produces a **dynamic** copy, so
an append loop stays linear after it. **Arena survivors:** promotion
keeps the header where it is and reallocates the payload into the heap,
because promotion retains the block the header lies in and would
otherwise leave `data` pointing into a block returned to the pool;
an OS-direct payload transfers ownership instead of being copied.
**Rejected:** a third frozen sub-mode (keeps the dereference and the
spare capacity for life); a single inline-only layout in the heap
(makes `$obj->buf .= $x` quadratic). **Cost:** dynamic strings pay one
dereference to reach their bytes, and surviving arena strings pay a copy
of their payload at reset. The old `builder` name goes too:
`ClassBuilder` already holds that word in `ll-model`, and `Buffer` is the
primitive a dynamic string owns rather than is.

### 2026-08-03 — a COW entity's refcount equals its number of holders

The sharing test is only as good as the count, so the count is exact
(Edmond): a second holder retains before it can write, and the compiler
may elide a retain/release pair only where it proved no second holder
arises. **Why:** deferred ARC lets the count lag the stack until the next
safepoint. For lifetime that is harmless — the stack scan repairs it —
but the COW test is consumed at the instant of the write and never
revisited, so a lagging count means writing in place into a string
somebody else holds, and the value is corrupted silently. **Rejected:**
keeping deferred ARC for COW entities behind an analysis that proves
non-sharing; that is tiers 1-2, which already carve COW out, and tier 3
is precisely where no such proof exists. **The `IS_ESCAPEE` case is not
covered by exactness at all:** while bit 11 is set the field holds the
arena escape hold-count, so there is no reference count to read, and the
rule there is to separate unconditionally — which promotes
`ll-model/src/memory/barrier.rs`'s `debug_assert` into a normative rule
in the conservative direction. **Cost:** strings and arrays forgo the
deferred-ARC traffic reduction, the same price Zend pays for the same
oracle.

### 2026-08-03 — `rc-satb` stays designed and unbuilt, with named triggers

`rc-walk` overtook it on the one axis it was registered for. **Why:**
`rc-satb` promises near-zero pauses and pays a deletion barrier on every
overwriting store plus two all-thread safepoints per epoch; `rc-walk`
pauses the mutator not at all and charges nothing on a reference store,
because its roots are derived from the counts rather than enumerated.
`satb.md` predates `rc-walk` and never mentions it. **Rejected:
retiring it** the way MMTK was retired the same day — that was a slot
with neither code nor plan behind it, whereas this has both a plan and
properties `rc-walk` cannot acquire: marking terminates by
construction, floating garbage is bounded by one epoch, liveness comes
from reachability rather than completeness of the counts (the only
defence against an ARC-elided borrow), and it is the recorded door to
deferred reference counting. It is also the only spare collector whose
failure modes do not overlap `rc-walk`'s. **Cost of keeping it:** a
design that must be re-derived before use — and one defect found while
deciding, now recorded in it as blocking: the root set omits FFI
handles, so an entity held only by one would be swept under a live C
pointer, turning `rc-walk`'s conservative leak into a use-after-free.
**Triggers to build:** a measured `rc-walk` failure surviving a *built*
escalation rung 4; `domains.md` failing on its largest hole after an
honest attempt; or a decision to elide ARC past the covering-root rule.

### 2026-08-03 — MMTK is out; the registry offers no third-party backend

MMTK will not be built (Edmond). The `mmtk:<plan>` row leaves the
strategy registry and nothing replaces it, so the contract now serves
Limelight's own strategies only. **Why:** the shipped collectors own
their heap directly and have since `rc-walk`; keeping a backend row
nothing implements made the registry advertise a slot that no code,
and no plan, stands behind. **Rejected:** keeping the row as a
standing offer — it is the drift class this repo already pays for.
**Cost:** one supporting argument for Rust as the core language
disappears (`runtime/implementation-language.md`); the decision itself
stands on memory safety and is already executed. The surveys in
`heap-design.md` and `gc-research.md` stay as the record of what was
considered.

### 2026-07-28 — The forced verdict replaces the parked mutator; the allocation-failure path is the pressure trigger

The escalation ladder's rung 3 (park the mutator) is deleted — it
violated design principle 4 and, per the channel analysis, bought
nothing: parking at a checkpoint inside a borrow's hold window
re-reads the same inflated count. New endgame: after `R` consecutive
acquittals of the same component (trigger-only identity: slot-set
hash, invalidated on flush; the posted message is always the current
walk's product), the collector bypasses the Phase 3 filter and posts
the component — the Phase 4 exact test, race-free on the owner
thread, is the final arbiter: balanced → collected, mismatch →
provably live at that instant, corpse → part-dead, re-judged.
Rationing is mandatory: per-component exponential backoff, a
per-epoch cap, weak-subscribed components first (the only perpetual
touch channel to true garbage is `WeakRef::get`). Prerequisite that
became load-bearing: the batched/vector checkpoint splits — ack
before the release run, pickup after it — else a scope-exit poller
phase-locks every pickup inside its hold window. Second load-bearing
order: weak nulling only after the exact test passes
(weak-references.md reconciled). Companion section "When the
collector runs": the allocation-failure path climbs the mutator's
self-help ladder (flush parked → drain verdicts → signal pressure,
rations lift → synchronous `collect_cycles`, gated by the walk-active
bit joining the pickup gate → honest OOM); principle 4 forbids
outside pauses, not one's own spent time.
- **Why:** the design already owns a quiescent re-check — the drain —
  so the park was strictly dominated; prior art has no forced-verdict
  precedent because no other system has a race-free final gate to
  force *to* (Recycler retries forever; FUGC terminates by
  monotonicity, which the forced verdict restores here).
- **Rejected:** condemned-aware `WeakRef::get` (per-get mutator cost,
  and it would resurrect the byte eager death just deleted); early
  weak nulling at condemn time (unsound for live false candidates);
  backoff without a final gate (Zend GH-9266: starvation becomes a
  sanctioned leak).
- **Cost:** rare rationed `O(component)` verification passes on live
  components; all of it is design ahead of code ("code lag" flags in
  place: `ll_gc_checkpoint_ack`, the trailing pickup, the vector
  split, the walk-active pickup gate). Open question 1 keeps only its
  cadence half.

### 2026-07-27 — Eager-death review: ack-only death checkpoint, out-of-band parking, unwind waits for acks

Two fresh-context adversarial passes over the eager-death amendment
surfaced two BLOCKERs that predate it, plus one spec gap; all three are
now design rules.
- **The death-branch checkpoint acks only; message pickup and the
  parked flush ride the outermost dispose's exit.** Between the
  committing zero store and dispose, the dying entity is
  committed-dead with a live weak cell; a drain destructor's
  `WeakRef::get()` there returns a strong reference to it —
  resurrection after commit, or double teardown (DC0 through the
  front door). Opened by the 2026-07-27 checkpoint move to the death
  branch, universal since eager death.
- **Parking is out-of-band.** The in-slot park link at bytes 8-15
  overwrote the class word mid-epoch, under a walker that reads the
  header in one pass and dereferences `+8` in the next — a wild read.
  A parked slot is now never written until the post-epoch flush;
  corpses stay intact (header 0, class live, fields nulled).
- **The epoch's unwind path waits for posted confirmations** before
  releasing the deferral window, or the next epoch opens over an
  undrained queue — two epochs' verdicts in flight.
- **Corrected in passing:** the F2 volume claim ("parked memory cannot
  exceed the live heap at epoch start") was derived under the F5
  deferral and is false under eager death — the true bound is churn
  rate × epoch duration. Two collector-side bounding mechanisms
  (epoch-abort watermark, young-free exemption) recorded in BACKLOG.
- **Cost:** parking allocates (a side list, cold path, epoch-only);
  drain latency moves from the death's checkpoint to its dispose exit
  (microseconds, same event).

### 2026-07-27 — Eager death: every refcount death tears down at the natural point; the condemned byte is retired

A release reaching zero mid-epoch now runs full teardown immediately —
`__destruct` on the owner thread, weak notify, sever, free — with only
the memory parked (the existing deferred queue); the F5 deferral, the
deferred-death marker and the shared condemned byte are deleted, and
condemnation becomes collector-private. The drain header-scans first
and drops any message containing an `rc = 0` member (the corpse rule),
which closes DC0 without acting on the corpse. Acquittals post no
message — both drain duties (byte clears, deferred-death tears)
dissolved with the mechanisms they served.
- **Why:** the deferral traded destructor timeliness — the one
  userland-visible semantic — for drain simplicity; the parked slot
  already guarantees corpse identity, so refusing the message is as
  safe as preventing the corpse, and the mutator's death path drops
  its last collector test.
- **Rejected:** keeping the byte as a Phase 3 filter (after the narrow
  mutator nothing writes it but the collector — it carried no
  information); zeroing corpse payloads (a torn ValueBox for the
  walker; the parked slot makes stale pointers safe to follow, so
  nothing needs zeroing).
- **Cost:** a component that partially dies between posting and drain
  waits an epoch for its survivors' re-judging; the TLA+ battery
  models the pre-amendment protocol until re-derived (noted in
  rc-walk-model.md and the tools README).

### 2026-07-27 — The weak cell is the canonical WeakReference; a per-thread table delivers death

Weak references designed ([weak-references.md](../model/weak-references.md)):
no separate side entry — PHP's canonical-instance guarantee lets the
`WeakRef` entity itself be the shared cell, so death notification is one
store into its target field. The dying object finds the cell through a
per-thread weak table (address → subscriber row, tagged: canonical cell /
map); rows are runtime-internal, no user-facing death callbacks. `WeakMap`
cleanup is eager at notification time.
- **Why:** the cell must be findable by the dying object without an 8-byte
  field in every object; per-thread because every notification site
  (teardown, drain checkpoint, arena reset) runs on the owning thread, so
  the table needs no locks.
- **Rejected:** a Swift-style separate side entry (an allocation and a
  hand-rolled refcount that `RcHeader` already provides); Java-style lazy
  map expunge (stale entries hold values hostage — javadoc-documented);
  a global Zend-style table (a mutex per create/death).
- **Cost:** ephemeron entries (value references its own key) are not
  collected — PHP 8.0–8.2 behaviour, 8.3 parity deferred to BACKLOG.

### 2026-07-25 — A safepoint is a moment, not a root map; and rc-walk's checkpoints live in the allocator

Two corrections that turned out to be one. A poll safepoint says *when*,
not *what*: it makes roots enumerable only for a strategy that also pays
the compiler to publish them. Counting a frame's references is the
alternative payment, and `rc-walk` has already made it, so it never reads
a stack. Separately, the checkpoints `rc-walk` does need — the handshake
ack and the Phase 4 drain — belong in the **memory manager**, not in
compiler-inserted polls.
- **Why:** the allocator is called constantly, already owns the numbers
  that decide whether collection is worth doing, and is the natural place
  to choose the moment. It also dissolves the parked-thread problem: a
  thread inside a syscall or an FFI call reaches no checkpoint, but it
  allocates nothing and mutates nothing, so nobody waits on it. A compute
  loop that releases without allocating is bounded by the live heap at
  epoch start.
- **Rejected:** marking entry to and exit from foreign code so the runtime
  can ack for a blocked thread (FUGC's move) — two writes on every call
  out, and PHP calls out constantly.
- **Cost:** [strategies.md](../model/gc/strategies.md) §2 reworded; the
  obligation to publish roots now sits explicitly with `rc-satb`, which
  does not have the mechanism. Compiler polls stay in the project for
  their other duty, raising an exception after a failed reserve refill.

### 2026-07-25 — A borrow's owner must be a root, not merely something alive

When the compiler elides a `retain` because some other reference keeps the
object alive, that other reference must be one the cycle collector counts
as a **root**: a frame slot, an arena slot, a static, an immortal, an FFI
handle. A field of a heap object never qualifies.
- **Why:** liveness-by-refcount is strictly weaker than liveness. `$x =
  $obj->other; $obj = null;` with `$obj` in a cycle is sound under plain
  refcounting (the ring merely leaks) and unsound the moment a collector
  frees the ring. The narrow scope is the good news: anything that leaves
  the frame is stored, every store is counted, so an uncounted borrow can
  only live in a frame slot and the obligation is a within-frame property.
- **Rejected:** relaxing the rule for holders of acyclic classes. An
  acyclic holder cannot be a cycle *member*, but it can be garbage held
  *by* a cycle and dies in the cascade that frees it.
- **Cost:** none to the collector; it constrains the borrow analysis of
  [static-lifetimes.md](../model/memory/static-lifetimes.md), where the
  rule and its three worked cases now live ("What may own a borrow").

### 2026-07-25 — The cycle collector's licence to skip, and the acyclic-class flag that spends it

`rc-walk` operates under two standing permissions: it **may skip** (a
missed cycle is memory not yet reclaimed, never a wrong answer) and it
**may be slow** (its cost is off the mutator's path, so collector time
buys mutator instructions at any exchange rate). The skip lemma makes the
first safe: omitting an entity from the walk only removes in-edges, so
`RC − IN` grows and its targets are pinned as roots. The first thing that
licence buys is the **acyclic-class flag** — a class whose node lies on no
cycle of the class-reference graph is skipped entirely, in the walk and as
an edge target.
- **Why:** skipping is recall-only in both directions, so an *unsound*
  flag can only leak, never free a live entity — the analysis can ship
  imprecise and tighten later. Bacon and Rajan compute the same flag for
  the Recycler and report the candidate population falling by roughly an
  order of magnitude.
- **Rejected:** a per-object dynamic version (an object currently holding
  only scalars is acyclic in fact) — it needs a re-check on every store,
  which is the per-operation mutator cost the strategy exists to avoid; a
  header bit — bits are scarce and a collector-side class load is free.
- **Cost:** skipping must be **total**. An edge recorded into an entity
  whose `rc[]` row was omitted reads as a negative derived root and frees
  a live object. Recall loss is bounded by one epoch, since an acyclic
  entity dies on the ordinary path once its holder does. The analysis
  needs a closed class set: a field typed `T` reaches every subclass of
  `T`, so anything registered later (`eval`, late autoload, an
  FFI-installed descriptor) is cyclic by default.
- Written up in [rc-walk.md](../model/gc/rc-walk.md), "The compiler's
  acyclic flag".

### 2026-07-24 — A `#[Region]` is an allocator class: it may supply its own alloc, free, and GC traversal

A `#[Region]` ([regions.md](../model/memory/regions.md)) is the runtime's
**allocator class**: an object that owns memory and governs the objects
it creates. Beyond binding a named collector, a region may supply its own
allocation and free policy and — the new capability — its own **GC
traversal** of its objects. Its contents are `gc_state = OWNED`; the
global collector skips them and the region's own collector handles them.
- **Why:** unifies arenas, per-class pools, slotmap/movable containers,
  and custom allocators under one first-class object — matching Verona
  regions and Zig/Ada custom allocators, and adding a user-supplied GC
  walk those do not have (the novel part). Movement stays confined to a
  region's key/handle store (the only relocation the runtime does).
- **Traversal safety contract:** over-approximation — a custom traversal
  must report a superset of live outgoing references and only references
  the object actually holds, never a fabricated address. Over-report is
  harmless (one extra cycle); under-report is a use-after-free and is
  forbidden — the same rule as release-at-reset and SATB marking. The
  runtime does not verify a hand-written traversal; that unsafety is
  accepted for now and revisited separately.
- **Deferred:** verifying/restricting a hand-written traversal so it
  cannot under-report; the attribute spelling (`#[Region]` vs
  `#[Allocator]`); explicit `reset()`/`pack()` lifecycle.
- **Written:** [regions.md](../model/memory/regions.md), "The region as
  an allocator class".

### 2026-07-24 — Proxy is the runtime's one indirection; movement is opt-in through it

Box (kind 4), WeakRef (kind 5), and Ghost/lazy (kind 6) are unified as
instances of one **Proxy** pattern — a surrogate that intercepts all
access to a target for one dereference — and a fourth effect, a movable
handle, joins them. Object movement exists **only** behind a movable
proxy (or an extract-to-access container); the general heap stays strictly
non-moving.
- **Why:** fragmentation is handled without a global moving collector.
  Confining relocation to an opt-in proxy pool keeps the common path on
  direct pointers (no read barrier, no global pinning) and localizes the
  compactor; identity rides the stable proxy, so `spl_object_id` stays
  address-derived. The shape is the GoF taxonomy (virtual proxy = Ghost,
  smart reference = WeakRef, handle = movable), and PHP 8.4 already names
  its lazy strategies Ghost and Proxy. No mainstream language unifies
  weak + lazy + movable under one primitive, so this consolidates known
  effects rather than inventing.
- **Rejected:** a global moving/compacting collector — read barriers plus
  pinning for FFI-escaped addresses plus header identity-hash, all to move
  objects the FFI load often pins anyway (see the non-moving research).
  The committed fragmentation answer is the movable proxy, not arena-reset
  sparse-block evacuation, which stays deferred.
- **Cost:** one pointer-chase per access on proxied objects; a scoped
  compactor for the movable-proxy pool if/when built.
- **Deferred:** consolidating kinds 4–6 (one family) to reclaim
  entity-kind bits — noted, not designed.
- **Written:** [classes.md](../model/classes.md), "The Proxy family".

### 2026-07-24 — Captured heap objects carry `gc_state = OWNED`, skipped by the collector

A general-heap object (category `00`) captured by an arena/actor stays
physically in the heap but is marked with a fourth `gc_state` value,
`OWNED`. Both CAS handoffs start from `LIVE`
([heap-design.md](../model/gc/heap-design.md)), so an `OWNED` object
fails both and is skipped by collector and mutator alike; its lifetime is
the owning arena's responsibility until it escapes to shared and is
re-armed to `LIVE`.
- **Why:** a transferable object is allocated in the general heap for a
  zero-copy handoff ([actors.md](../runtime/actors.md)) but is owned by
  one actor at a time. The collector must not touch a captured object;
  saying so with `gc_state` costs zero new bits (2-bit field, only 3
  values used) and needs no new collector branch — a non-`LIVE` state
  already fails the handoff CAS. It also makes the "needs no atomic
  counts" claim exact: the single owner is the sole writer of `refcount`.
- **Rejected:** a dedicated flag bit (the flags word is full, bits 0–31
  all assigned); a fifth `mem_category` (2 bits, all four values used);
  reusing entity-kind `7` (conflates identity with collectability).
- **Cost:** `heap-design.md` state field is now four-valued; `classes.md`
  flags table and `actors.md` updated.
- **Not fully worked out.** The escape event that flips `OWNED → LIVE`
  (an object becoming reachable by ≥2 actors) rides the existing
  escape/category machinery; its exact trigger and the in-transit
  A→queue→B ownership window are not yet pinned. Provisional.

### 2026-07-24 — The marker's root set includes live arenas' heap references

The concurrent marker's roots are `stacks + globals` **plus every live
arena's references into the general heap** (its *release-at-reset* list),
not stacks + globals alone. Transport depends on the arena's thread: a
same-thread arena (request / ordinary) is scanned directly at the
SNAPSHOT safepoint; an actor arena on another thread **publishes** its
list in the mailbox handshake (variant B), so the marker never reads a
running actor's memory.
- **Why:** a general-heap object reachable *only* from an arena slot is
  on no stack or global, and the marker does not walk arenas, so a
  stacks+globals-only trace would sweep it while live — a use-after-free
  at reset. Prior art (Pony/ORCA, Go, HotSpot, OCaml-multicore/DLG)
  overwhelmingly reads a running mutator's roots by cooperative
  self-publish at a safepoint/handshake, not by concurrent direct reads.
- **Rejected:** the marker reading a running actor's list directly (the
  earlier `actors.md` wording) — only ZGC/Shenandoah approximate
  concurrent root reads and even they gate with a stack-watermark
  barrier; an unsynchronized read also contradicts actor isolation.
- **Deferred, larger:** a capability restriction on what may cross an
  actor boundary into the general heap (immutable or unique only, à la
  Pony `val`/`iso`) — what buys barrier-free collection. Its own entry
  when designed.
- **Cost:** `satb.md` root set and `actors.md` root transport reworded.
- **Not fully worked out.** A direction chosen from prior art, not a
  verified mechanism: the SNAPSHOT "all-threads safepoint" wording still
  sits in tension with the actors' "no stop-the-world" handshake, and the
  handshake payload and same-thread watermark/SATB interaction are
  unproven. `actors.md` and `satb.md` both flag it provisional; re-verify
  at implementation.

### 2026-07-23 — A reserved region must state its extent explicitly

Any reserved or padding region in a layout must state where it starts,
how large it is, and why it is unused; the regions must sum to the
declared total.
- **Why:** the first run of the fact-base checker (`efen-lang/kolvir`)
  found that the value Box was declared 16 bytes while its fields summed
  to 15 — payload 8, type_tag 1, flags 1, reserved 5 — leaving byte 15
  belonging to nobody. `reserved` had to be 6 bytes (+10..15), which
  PHP's `zval` confirms independently: `u1.v.u.extra` (2 B) and `u2`
  (4 B) occupy exactly that span. A loosely worded reserve hid a whole
  missing byte.
- **Rejected:** treating an unexplained "reserved" as harmless slack.
- **Cost:** none of substance; layout tables get slightly more verbose.
- Fixed in [values.md](../model/values.md), "Box Layout". What to put in
  those six bytes is deliberately deferred, see [BACKLOG.md](../BACKLOG.md),
  "Deferred optimizations".

### 2026-07-25 — rc-walk checker: TLA+/TLC, not PHP or SPIN

The rc-walk interleaving checker (`TASK-rc-walk-proof.md`) is a TLA+
spec model-checked by TLC, resolving the choice `rc-walk-model.md` §11
left open.
- **Why:** the state space is finite by construction, so the right
  search is full breadth-first exploration with sound deduplication and
  no depth bound — exactly what TLC does, and what kills all three traps
  the thrown-away hand-rolled checker hit (depth-bounded memoisation,
  tight bounds, minimal counterexamples come free). The `R*` oracle is a
  transitive closure, native in TLA+; T5 is a liveness property under
  fairness, which TLC checks and a hand-rolled enumerator realistically
  cannot. Java verified present on the working machine.
- **Rejected:** PHP enumerator (hand-rolled DFS re-creates the traps);
  SPIN/Promela (the `R*` oracle would need embedded C); Coq/Isabelle
  theorem proving for the unbounded claim (weeks of work against a
  design still moving — revisit if the design freezes).
- **Cost:** one external toolchain (`tla2tools.jar`, pinned); TLC
  counterexample traces must be translated by hand into the adversarial
  harness tests `rc-walk-model.md` §11 describes.
- State-space accounting that informed this:
  [rc-walk-states.md](../model/gc/rc-walk-states.md).

### 2026-07-26 — rc-walk: resolutions from the scenario-replay findings

The scenario replay and TLC runs (`rc-walk-proof.md`, findings F1–F9)
were resolved in one pass; `rc-walk.md` and `rc-walk-model.md` carry
the edits, each stamped with this date.
- **Condemned entities never die on the ordinary path** (F5): a
  release reaching zero on a condemned entity defers teardown to the
  drain — exactly-once teardown, destructor deferred past the last
  release is accepted semantics. Replaces the vacuous dead-member
  acquittal claim.
- **Phase 2 groups by weak connectivity**: linked garbage dies in one
  epoch; one touched member acquits the whole group for an epoch.
- **Masquerade closed, not screened**: the manager commissions blocks
  with zeroed slot headers (free for fresh OS commits; explicit pass
  for recycled or lazily-decommitted memory), and the object factory
  publishes the header last as one 8-byte store. `ll_object_new`
  reorder lands with build-order step 1.
- **Drain is non-reentrant** via the allocator's own mid-drain state
  (F8); **re-verify discounts the guard** (F1); **M3 releases last**,
  a compiler obligation (F7); **frame slots represent external
  holders**, §11 corrected to 3 heap entities (F9); **T5 carries an
  explicit fairness premise** and the stalled-epoch case is accepted
  without a fallback (F2).
- **Checker runs are scenario-scripted**: the free mutator blows the
  state space past 30M states without exhausting. Each run binds the
  mutator to a fixed 2–4-action script (the danger-case shapes); the
  only nondeterminism is the placement of those actions between
  collector micro-steps. Runs land at 10²–10⁴ states and seconds of
  wall clock; the claim is per-scenario, stated with every result.
  Free-mode exhaustion remains available (`ScriptName = "free"`) as an
  optional offline run.
- **Cost:** one condemned-byte test on the reaching-zero path; a
  header-zeroing pass when commissioning non-fresh blocks.

### 2026-07-26 — rc-walk: second-audit resolutions (acquittal message, total skip, canonical filter)

A second fresh-context audit attacked the same-day amendments and the
checker; two design changes and one canonisation came out of it.
- **An acquittal is a message.** The collector performs no acquittal
  cleanup itself: the owning thread's checkpoint clears condemned
  bytes and tears deferred deaths. Every condemned component ends in
  exactly one mutator-side message (confirm or acquit); the epoch
  waits for all of them.
- **Why:** the draft ran destructors/releases on the collector thread
  and had a byte-clear race that minted permanently invisible zombies
  (rc = 0 reads as free; destructor never runs; children pinned
  forever).
- **The allocate-black skip is total**: child-pointer validation also
  requires the target's epoch byte to read an older epoch, else the
  edge is dropped (conservative). Closes row-absent/edge-present
  arising in the sound design.
- **Phase 3 filter canonised as snapshot comparison** (any observed
  change acquits); the "recompute RC − IN" reading is retired —
  comparison is simpler, strictly more acquittal-prone, and is what
  the TLC battery verifies.
- **Checker**: 4 slots / 3 frame slots; the audit's 4-entity
  near-false-post shape passed exhaustively (35 202 states, full
  invariants) — strongest F6 evidence so far. Battery is 22 scenarios,
  all matching expectations; SC-memory-only and narrow-destructor
  limits recorded in rc-walk-proof.md.
- **Cost:** acquitted components keep their bytes until the owner's
  next checkpoint; one more message kind on the queue.
