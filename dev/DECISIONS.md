# Architecture decisions

A changelog for architecture: what was decided and why, not what
changed in the code. Newest on top. A superseded decision is left in
place and replaced by a new entry, never edited away.

Format per entry (3–6 lines): date + one sentence on **what** was
decided; **why** (the problem or constraint); **rejected** alternatives
in one line; **cost** if any.

---

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
