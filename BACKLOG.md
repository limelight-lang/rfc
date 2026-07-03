# Backlog

Deferred work, collected from all RFC documents. Items move out of here
into proper RFCs when picked up.

## Needs a working runtime first (cannot be resolved on paper)

- **Mode A/B thresholds** for arena reset — calibrate with real
  workloads ([arena-reset.md](model/memory/arena-reset.md)).
- **`SplObjectStorage` / `WeakMap` after evacuation** — rehash
  address-keyed tables, or key by the stored lazy object id from the
  start ([arena-reset.md](model/memory/arena-reset.md)).

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
- **GC phases 2–3** — concurrent marking, stack deferral, full LXR
  ([gc-research.md](model/gc/gc-research.md)).

## Explicit pack/optimize operation for long-lived structures

Structures that live long (caches, config trees, routing tables — 
typically long-lived-arena residents) should have an **explicit pack
operation**: compact the storage in one pass — drop vector slack and
hashtable tombstones, relayout for cache density, re-intern strings,
possibly relocate into the long-lived arena and mark immortal/COW.
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
