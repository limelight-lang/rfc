# Architecture decisions

A changelog for architecture: what was decided and why, not what
changed in the code. Newest on top. A superseded decision is left in
place and replaced by a new entry, never edited away.

Format per entry (3–6 lines): date + one sentence on **what** was
decided; **why** (the problem or constraint); **rejected** alternatives
in one line; **cost** if any.

---

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
