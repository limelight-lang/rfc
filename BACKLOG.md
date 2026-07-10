# Backlog

Deferred work, collected from all RFC documents. Items move out of here
into proper RFCs when picked up.

## Needs a working runtime first (cannot be resolved on paper)

- **Mode A/B thresholds** for arena reset — calibrate with real
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
- **SATB epoch trigger and queue overflow policy** — calibrate the
  candidate-bytes threshold; segment size and marker backpressure
  ([satb.md](model/gc/satb.md)).
- **Safepoint placement and barrier-slot codegen spec** — exact poll
  sites, how `ll_ref_store` layers are composed and inlined per
  strategy at build time ([strategies.md](model/gc/strategies.md));
  belongs with the execution pipeline RFC.

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
