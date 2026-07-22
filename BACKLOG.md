# Backlog

Deferred work, collected from all RFC documents. Items move out of here
into proper RFCs when picked up.

## Needs a working runtime first (cannot be resolved on paper)

- **Per-block dense/sparse threshold** for arena reset (escaped bytes
  per block deciding retain vs evacuate) — calibrate with real
  workloads ([arena-reset.md](model/memory/arena-reset.md)). Blocked
  first by a design debt, not by measurement: evacuation needs to fix up
  the references to a moved escapee, and the barrier deliberately keeps
  no holder slots ([arenas.md](model/memory/arenas.md)), so there is
  nothing to fix up with. Retention is what the runtime implements.
- **`SplObjectStorage` / `WeakMap` after evacuation** — rehash
  address-keyed tables, or key by the stored lazy object id from the
  start ([arena-reset.md](model/memory/arena-reset.md)).
- **Memory-pressure modes and the buffer arena**: design decided, see
  [buffers.md](model/memory/buffers.md); only the mode thresholds and
  the critical-mode search bound *K* remain to calibrate against real
  workloads.

## Model — remaining documents

- **Array hashtable design** — bucket layout, collision strategy,
  iteration-order preservation, mechanics of the mixed-vector → hash
  migration ([arrays.md](model/arrays.md)).
- **Closures** — capture (by-value / by-ref), `$this` binding,
  first-class callable syntax.
- **Reference box representation** — revisit how a PHP `&` reference is
  represented (today: entity kind `3`, `RcHeader | Value`,
  [values.md](model/values.md)). Open question raised during the
  object-layout rework, deliberately deferred — reconsider whether the
  box is the right shape, how it interacts with the entity-kind field
  and the typed-slot reference, and its cost. Not urgent.
- **`__destruct` is not run for cyclically-dead objects** — a real
  divergence from PHP, where Zend does run it. The difficulty is
  structural rather than incidental: Bacon–Rajan finds cyclic garbage by
  *trial-deleting* internal edges, so at the moment the white set is
  known the reference counts are deliberately wrong. Running arbitrary
  PHP there — and `__destruct` is arbitrary PHP — means it may resurrect
  a white object, allocate, raise, or touch something already freed in
  the same pass, and a trial-mutated count cannot tell resurrection from
  bookkeeping.
  Zend's answer is a re-scan discipline: restore the counts, run the
  destructors over the whole white set with a per-object "already
  destructed" mark so none runs twice, then **re-detect**, because the
  destructors may have resurrected objects or created fresh garbage.
  PHP carried bugs here for years, which is a fair warning about the
  care needed. Memory safety is unaffected today — the objects are still
  freed — so this is a semantic gap, logged in the crate's `PLAN.md` as
  a phase-1 limit.

- **Execution modes** — the project targets several hosts: embedded in
  the real PHP runtime (with or without its VM), our own runtime, a
  hybrid of the two, WASM, the JVM, .NET, Android and iOS. Each has its
  own integration rules, and exceptions are the subsystem most affected
  — see the mode table in [exceptions.md](runtime/exceptions.md).

  The count matters less than it looks, because **the modes reduce to
  three memory models**: ours (own runtime, WASM, .NET, Android via the
  NDK, iOS — raw memory is available on all of them, so arenas and
  refcounting survive unchanged), Zend's when embedded (also refcounted,
  so semantically close), and a host tracing collector on the JVM (no
  arenas, no refcounting, and `__destruct` stops being deterministic).
  **The JVM is the only outlier**, and its cost is a branch of semantics
  rather than a port.

  Two constraints that fall out of the mobile targets and belong in the
  compiler design, not just here: **iOS forbids JIT entirely** — no
  executable pages for third-party apps, so the path is strictly AOT and
  nothing may work by patching instructions (inline caches must be data)
  — and **Apple platforms use a third unwind format**, Mach-O compact
  unwind, alongside ELF and Windows.

  The rest of the corpus assumes our own runtime and has not been
  revisited for the other modes.
- **Exceptions** — designed with **known open defects listed in the
  document**, see [exceptions.md](runtime/exceptions.md):
  two channels (table-driven unwinding, plus error-return for frequent
  exceptions) chosen by the compiler over the known class hierarchy;
  runtime→PHP callbacks always use the return channel so unwinding never
  enters Rust; traces materialize only the frames unwinding is about to
  destroy, with symbolization deferred. Open within it: generators and
  fibers (segmented stacks break the trace walk), how interface `catch`
  — including `Throwable` — avoids an itable search, the Windows funclet
  constraint on a custom personality, unwind registration for JIT code,
  and where the frequency hint comes from.
- **Enums** (PHP 8.1) — immortal singletons; mostly falls out of the
  existing model, needs a short document.
- **Generators / Fibers** — execution-stack capture; heavily coupled to
  the runtime design, likely lives in `runtime/`.
- **Resources** — tag exists in [values.md](model/values.md), design and
  I/O coupling do not.
- **Generics via attributes** — `#[Template]`-family vocabulary
  (aligned with Psalm/PHPStan), variance, reification vs erasure,
  interaction with the value model; no new syntax per
  [attributes.md](attributes.md).
- **`#[FFI]` family beyond memory** — foreign function and library
  declarations, calling conventions, marshalling; belongs with the
  interop RFC
  ([zero-abstraction.md](model/memory/zero-abstraction.md)).
- **Direct import of C headers and Rust modules** — include a `.h`
  file or a Rust module straight into PHP code, with `#[FFI]`
  declarations and zero-abstraction types generated from the foreign
  source at compile time (à la Zig `@cImport`, bindgen). The in-memory
  Clang path from
  [ir-integration-research.md](interop/ir-integration-research.md)
  is the natural backend for the C side; Rust via `rustc` subprocess.

## Object model — open questions from the layout rework (to discuss)

Raised by an adversarial review after the object-layout rework. Each
needs a design decision, deferred deliberately.

- **Torn 16-byte Box read in the concurrent marker (`rc-satb`)** — a
  `store_box` writes the 16-byte Box non-atomically (payload, then tag)
  while the background marker reads the same slot to trace it, so the
  marker can see new payload + old tag and treat an `int` as an object
  pointer. The "one writer" invariant guards writers, not a concurrent
  reader. Needs a decision: a 16-byte atomic store/read on the marking
  path, a marker that reads tag-then-payload with a re-check, or another
  scheme ([satb.md](model/gc/satb.md), [values.md](model/values.md)).
- **`escape_lose` for a thread-local static block holding an arena
  escapee** — storing an arena object into `Foo::$bar` counts the escape
  (`gain`), but the decrement has no caller: `release` is a no-op for the
  arena category, and a static block has no `dispose` and is on no
  holder-teardown path, so an overwrite or thread exit never runs
  `escape_lose`. The escapee is pinned forever. Needs a decrement path
  for headerless static destinations
  ([strategies.md](model/gc/strategies.md), [arenas.md](model/memory/arenas.md)).
- **`mixed` → interface conversion on a `string`/`array`** — the
  conversion table still routes via `obj->class`, which a non-object has
  not got. The intended path (kind field → the type's singleton
  descriptor → its `interfaces`/itable) is now stated in the flags
  section but not written into the conversion machinery
  ([classes.md](model/classes.md) "Fat interface references" /
  "Extension interfaces").
- **`deep_clone` / `thread_move` atomicity on failure mid-copy** —
  allocation can fail partway through a large, possibly-cyclic graph
  copy; the identity map then holds a half-built cyclic subgraph that
  refcounting alone cannot tear down, and `thread_move` additionally
  leaves the source half-destroyed. The ownership model is already
  reserved; the rollback/atomicity of a partially-applied graph op is
  the unaddressed part ([classes.md](model/classes.md) lifecycle family).
- **Backed enum with a string value as an immortal singleton** — an
  enum case is an immortal object; a backed case carries a `value`, and
  for a string case that is a counted heap entity. An immortal object's
  never-decremented reference to a counted string leaks it unless the
  string is itself immortal/interned. State the constraint when enums
  are written (also listed under enums above).

## FFI document — review findings

An adversarial review of [ffi.md](model/memory/ffi.md) flagged two hard
contradictions and several holes. **Most are now resolved in the
documents** (2026-07-22); what remains open is at the end.

**Resolved** (folded into [ffi.md](model/memory/ffi.md),
[zero-abstraction.md](model/memory/zero-abstraction.md),
[classes.md](model/classes.md)):

- **Hidden `RcHeader` at −8** (was critical) — dropped. It never survives
  the offset-0 invariant; a `Box` is always a **separate wrapper**, the
  header on the `Box`, never at −8 of the C data.
- **"Mandatory owner or compile error"** (was critical) — dropped. An
  un-anchored foreign value is a tier-3 case and falls to an
  **auto-`Box`** (which supplies the missing `RcHeader`); no compile
  error, accept-every-program intact.
- **No slot kind for a foreign-typed property** — dissolved. A foreign
  value in a managed property is **always a `Box`** (the store is an
  escape); a managed object never holds a bare headerless struct, so there
  is no "owned-foreign" slot kind. Bare foreign lives only in
  proven-non-escaping tier-1 locals, freed by the compiler's scheduled
  `dispose`.
- **Class-less kind-4 `Box` free-hook storage** — resolved. Freeing is the
  wrapped class's `__destruct` lowered into its `dispose`; the `Box` body
  carries the wrapped FFI type's descriptor (with that `dispose`) as an
  instance field. The separate `free:` attribute is removed.
- **Arena-owned foreign free leak** — no longer FFI-specific. The foreign
  value in an arena is a `Box`, an ordinary destructor-bearing managed
  object, so its C memory is freed by the standard destructor path,
  including arena reset's fixpoint over tracked dying objects
  ([arena-reset.md](model/memory/arena-reset.md) Step 1). Any residual is
  the general "arena reset runs destructors" behaviour, not FFI.

**Still open:**

- **Boxing a struct with a live `#[Borrow]` field → UAF** (deferred;
  direction agreed 2026-07-22, to confirm and write into ffi.md). Model
  `#[Borrow]` as a `Box` sub-kind carrying a **don't-free** flag — but that
  alone only rules out the double-free, not the dangling read. PHP cannot
  fabricate a raw borrow: it always originates from a foreign call or a
  `#[Borrow]`-view of managed memory, so the only hazard is boxing an
  already-obtained borrow that then outlives its source. Leaning: at the box
  point, a borrow into **managed** memory makes the `Box` keep its owner
  alive (retain the `RcHeader` holder); a borrow into **raw C** memory
  (nothing to retain) is **not boxable** and raises a runtime exception there
  — no compile error, accept-every-program intact.
- **Smaller contradictions:** owned-copy `string` field vs "nothing to
  free" (who frees the copy); "reading a C string copies" vs the zero-copy
  borrowed view (which a two-representation managed string cannot express);
  nested inline `#[FFI]` pointer-field ownership; no memory-category value
  for foreign memory. (The "Box" name collision is **accepted, not
  renamed** — two contexts, value-box vs raw-struct box, clarified in
  values.md and ffi.md.)

## Deferred optimizations

- **No zeroing by default, anywhere** — the memory manager must not
  clear memory it hands out, and object creation must not clear property
  slots as a matter of course. Zeroing is work proportional to the
  allocation on the hottest path in the system, paid for data that is
  usually about to be overwritten. **The factory constructor decides**:
  it owns the allocation (see [object-lifecycle.md](runtime/object-lifecycle.md),
  "Two constructors"), so it is the one place that knows which slots get
  real values immediately, which need a defined initial state, and which
  can be left alone. The concrete site today is `ll_object_new`, which
  null-fills every property slot unconditionally. What has to be worked
  out: which initial states the
  value model actually requires (UNINIT discriminants, refcounted slots
  that teardown will read), what `ll_calloc` and friends still owe their
  C callers, and how the compiler proves a slot is written before it is
  read.
- **Regions from the OS, not from `std::alloc`** — `BlockPool::carve_region`
  takes its 2 MB regions through the Rust global allocator. Replacing
  that with `VirtualAlloc` / `mmap` behind a small `region::map/unmap`
  interface is not a speed change in itself (carving happens once per
  2 MB), but it is the prerequisite for three things that are:
  **huge pages** — a region is exactly 2 MB, so it *is* a huge page, and
  `MEM_LARGE_PAGES` / `MADV_HUGEPAGE` is the last large untaken win on
  the hot path; **reserve/commit split**, which makes it possible to
  return memory to the OS at all (today the pool only grows, and a
  region lives until the process exits); and it removes the
  self-reference that currently makes the crate unusable as a Rust
  `#[global_allocator]` — carving re-enters `ll_alloc` with an alignment
  it refuses.

  **And there is more than one OS behind it**, which is why this should
  be an interface rather than `#[cfg]`s sprinkled through `block_pool`.
  Windows: `VirtualAlloc`, granularity 64 KB = one block, so alignment
  comes free, and reserve/commit is native. Linux and Android: `mmap`
  with no alignment guarantee (the usual over-map-and-trim) plus
  `MADV_HUGEPAGE`; Android also has `prctl(PR_SET_VMA_ANON_NAME)` if we
  want regions nameable in a memory profile. macOS and iOS: `mmap`, no
  `MADV_HUGEPAGE` — the equivalent is `VM_FLAGS_SUPERPAGE_SIZE_2MB`
  through `mach_vm_allocate` — and on iOS nothing may be JIT-shaped, so
  the mapping code stays plain data pages. WASM: **none of this exists**
  — one linear memory that only grows, so the layer degenerates to a
  bump over it and unmapping is impossible. JVM/.NET: memory belongs to
  the host and the layer is replaced, not ported.

  That spread is the design constraint: the interface has to be small
  enough that a host which cannot unmap and cannot choose alignment can
  still implement it honestly.
  **Constraint that must not be lost:** Miri cannot execute either
  syscall, and Miri is the only tool that sees this crate's formal-UB
  class — so the `std::alloc` path stays as a `cfg(miri)` fallback and
  must stay exercised.
- **Optimistic devirtualization of `static::` call sites** with patching
  on subclass load (CHA-style) — JIT phase
  ([classes.md](model/classes.md)).
- **Interning of runtime-built name strings** — intern on first use vs
  hash-only matching; decide during stdlib work
  ([classes.md](model/classes.md)).
- **`?float` niche via non-canonical NaN payloads** — would shrink
  `?float` back to 8 bytes; requires NaN canonicalization on stores;
  considered too subtle for phase 1 ([values.md](model/values.md)).
- **Deferred RC / LXR-style strategy** — stack deferral, 2-bit
  saturating counts as a future build strategy reusing the SATB
  machinery; applies to tier-3 objects only
  ([static-lifetimes.md](model/memory/static-lifetimes.md),
  [satb.md](model/gc/satb.md),
  [gc-research.md](model/gc/gc-research.md)).
- **Level C non-counting backedges** — compiler-verified ownership
  trees where `#[Backedge]` edges carry no refcount; needs the
  escape-upgrade barrier design and `&`-reference correctness
  ([static-lifetimes.md](model/memory/static-lifetimes.md)).
- **Ownership conventions across dynamic call sites** — how much of
  tier 2 survives `call_user_func`-heavy code; measure, then decide if
  signature metadata needs a runtime side channel
  ([static-lifetimes.md](model/memory/static-lifetimes.md)).
- **Actor runtime** — sync-call deadlock policy, supervision/links,
  mailbox backpressure, monomorphization for store-path-divergent
  actors, actor handle representation in the value model
  ([actors.md](runtime/actors.md)).
- **Proxy-mediated movability for cold long-lived data** — opt-in: a
  container that knows its contents are cold and long-lived (sessions,
  warm caches) has them wrapped in canonical per-object proxies at
  arena death, keeping the cluster repackable once the arena's own
  bookkeeping is gone — the escape hold-count says *how many* references
  exist, never *where*, so nothing else can find them to fix up. Requires the general interception proxy
  (reference-returning reads must translate neighbors to their
  proxies). Rejected as the core arena-reset mechanism — see the
  rejected-alternatives section of
  [arena-reset.md](model/memory/arena-reset.md); natural companion to
  the explicit pack/optimize operation (below).
- **SATB epoch trigger and queue overflow policy** — calibrate the
  candidate-bytes threshold; segment size and marker backpressure
  ([satb.md](model/gc/satb.md)).
- **Periodic interruption of unbounded loops (system-signal check)** —
  loops with no provable bound get an iteration guard: a counter in
  the actor context, decrement + branch on the back-edge, on zero peek
  for system signals (GC handshake, cancellation, timeout,
  supervision) and reset — BEAM reduction counting. One general
  mechanism instead of GC-specific polls; counter budget TBD
  ([actors.md](runtime/actors.md)).
- **Safepoint placement and barrier-slot codegen spec** — exact poll
  sites, how `ll_ref_store` layers are composed and inlined per
  strategy at build time ([strategies.md](model/gc/strategies.md));
  belongs with the execution pipeline RFC.

## Compiler-declared block shapes (type-segregated blocks)

Let the compiler declare a block whose slots are exactly one class's
instances — `ll_alloc_shape(SHAPE_POINT)` instead of `ll_malloc(size)`.
Classic idea with a name and a graveyard: **BiBOP** (Big Bag of Pages), as
in SML/NJ, older Lisps, Boehm's "kinds". We are already half-way there —
blocks are segregated by *size*; this segregates by *type*.

**The obvious motivation is already dead, so don't re-derive it.** Exact
slot sizing buys nothing: `object_size = 16 + 16 * nprops` is always a
multiple of 16, and the size classes step by 16 up to 128. A 2-property
class is 48 bytes and lands in the 48 class — exact. Rounding only appears
at 8+ properties (144 → 160, ~10%).

What would actually be bought, in descending order of interest:

- **Trace by block, not by object.** The collector currently reads
  `obj->class` → `prop_layout.refcounted_slots()` per object. A typed block
  has one layout for all ~1300 of its objects: one lookup per block, and a
  linear sweep instead of pointer chasing. This is the real prize, and it is
  a *GC* prize, not an allocator one.
- **8 bytes off every object.** `Object` is `{ rc: 8, class: 8, props… }`.
  If a block holds one class, the class pointer belongs in the block header.
  40 bytes instead of 48 for a 2-property class — 17%.
- **Constant-folded allocation.** A compile-time shape index kills the
  `CLASS_LUT` load, the `SIZE_CLASSES[ci]` load, and turns `idx * class_size`
  into a `lea`. Roughly halves the fast path.

Four things any design has to answer, and none of them are small:

1. **The hot path gets nothing.** PHP request objects go to the request
   arena (`ll_object_new`: `RequestArena => arena.alloc(size)`), which is a
   pure bump — no size classes, no lookup, size already constant-folds.
   Shapes only apply to `GcHeap`/`LongLived`, the *minority* of objects in a
   request. They happen to be the ones the collector traces, which is why the
   GC win above is the one worth chasing.
2. **Variable block size breaks the pointer→block trick.** `of_ptr` is one
   `and` (`ptr & !BLOCK_MASK`) and works only because every block is the same
   size *and* aligned to it; 17 places depend on it. Mixing 32 KB and 64 KB
   blocks needs mimalloc's answer — fix a granularity, keep a per-region unit
   table, map any address through it — which costs a **dependent load on
   every free**, taxing the whole allocator to serve shapes. Regions would
   also have to become `REGION_SIZE`-aligned (today they are `BLOCK_SIZE`-
   aligned). Cheaper alternative: keep one block size and solve the footprint
   with policy (below) instead.
3. **Header elision may be a net loss.** Removing `obj->class` means every
   virtual dispatch, `instanceof`, and layout-dependent access reads it from
   the block header instead — an `and` plus a load from another line, on
   paths far hotter than allocation. Only pays if the compiler really does
   monomorphise most dispatch, which is the design's central unvalidated bet
   (see PLAN.md's vertical slice). Do not assume it; measure it first.
4. **Footprint is what killed BiBOP.** One block per shape per thread: 500
   classes × 8 threads × 64 KB ≈ 256 MB of half-empty blocks. We have just
   paid for one 170x memory bug (`heap-slot-allocation.md`, fix 7a); this
   would reintroduce the same failure through the front door. Needs a policy
   — which classes earn a shape, who decides (compiler, PGO, a runtime
   instance counter), and what the fallback to size classes looks like.

Verdict: plausible, but it is a **GcHeap design item, not a `Heap` one**, and
it should be scoped by the GC win rather than the allocation win. Revisit
when the Immix-shaped `GcHeap` is designed ([heap-design.md](model/gc/heap-design.md));
by then the vertical slice should also say how much dispatch survives
compilation, which decides point 3.

## Explicit pack/optimize operation for long-lived structures

Structures that live long (caches, config trees, routing tables,
typically long-lived-arena residents) should have an **explicit pack
operation**: compact the storage in one pass, dropping vector slack and
hashtable tombstones, relayouting for cache density, re-interning
strings, possibly relocating into the long-lived arena and marking
immortal/COW.
Long-lived data is written rarely and read constantly, so a one-time
explicit optimization pays for itself; the runtime cannot always guess
the right moment, hence an explicit operation. Needs a design pass:
what exactly it does per structure kind, and how it interacts with
reference identity and the category barrier.

## Strings — planned extensions

- **Interpolated string API** — public API on the template object,
  compile-time handler/type attachment (tagged-template style), exact
  flattening semantics ([strings.md](model/strings.md)).
- **Mutable string (non-COW) PHP-level API** — the runtime
  representation exists; the language surface does not.

## The big one

- **Execution pipeline RFC** — how PHP source becomes LLVM IR: parser,
  own IR or straight to LLVM, AOT/JIT split, autoloading in a compiled
  world. Everything in `model/` assumes this compiler exists; nothing
  specifies it yet.
- **Vertical slice** — minimal "hello world" through the whole stack
  (PHP → IR → executable) on the simplest memory setup, to start
  validating the design with running code.
