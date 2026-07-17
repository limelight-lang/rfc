# Backlog

Deferred work, collected from all RFC documents. Items move out of here
into proper RFCs when picked up.

## Needs a working runtime first (cannot be resolved on paper)

- **Per-block dense/sparse threshold** for arena reset (escaped bytes
  per block deciding retain vs evacuate) — calibrate with real
  workloads ([arena-reset.md](model/memory/arena-reset.md)).
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
- **Exceptions** — exception object layout, throw/catch lowering in LLVM
  (landing pads vs alternatives), stack traces, `finally`.
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

## Deferred optimizations

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
  arena death, keeping the cluster repackable after remembered-set
  completeness is gone. Requires the general interception proxy
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
