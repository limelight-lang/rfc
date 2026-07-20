# Limelight RFC

Design documents for **Limelight**: a compiled runtime for PHP with a
memory-first architecture. PHP source compiles through LLVM to native
code; memory is managed by arenas, compiler-tracked ownership, and
pluggable garbage collection instead of a one-size-fits-all VM heap.

> **Status**: design phase. These RFCs fix the architecture before the
> first vertical slice is built. Deferred work lives in
> [BACKLOG.md](BACKLOG.md).

## Architecture at a glance

| Pillar | Idea | RFC |
|---|---|---|
| Memory categories | Every object lives in a category: request arena, long-lived, immortal, or GC heap. Most objects die with their arena in O(1) and are invisible to the GC | [arenas](model/memory/arenas.md), [arena-reset](model/memory/arena-reset.md) |
| Static lifetimes | The compiler tracks ownership and moves, Rust-style but with a runtime fallback instead of compile errors. Proven objects get zero refcounting and a scheduled destructor call | [static-lifetimes](model/memory/static-lifetimes.md) |
| Pluggable GC | The collector is a build-time strategy behind a fixed contract. Default `rc-trace`: ARC + arenas + stop-the-thread cycle tracing. Flagship against pauses: concurrent SATB marking | [strategies](model/gc/strategies.md), [satb](model/gc/satb.md), [heap-design](model/gc/heap-design.md) |
| Actors | `#[Actor]` classes own their arenas and execute serially; queues are the only door between actors. Collection runs per actor at message boundaries; each actor may bind its own GC | [actors](runtime/actors.md) |
| Object model | C++-grade dispatch for PHP: inline-trailing vtables, COM-style itables, fat interface references, inline caches that never invalidate | [classes](model/classes.md), [lowering](model/lowering.md) |
| Exceptions | Two channels — table-driven unwinding, plus an error-return channel for exceptions known to be frequent — with the **compiler** choosing per function, not the programmer. `try` itself costs no dynamic instructions. Runtime→PHP callbacks always use the return channel, so unwinding never crosses into Rust | [exceptions](runtime/exceptions.md) |
| Values | 16-byte Box for the dynamic world, raw unboxed slots for declared types, COW as a per-object flag | [values](model/values.md), [strings](model/strings.md), [arrays](model/arrays.md) |

## Document map

### `model/` — language and memory model

- [values.md](model/values.md) — Box/unboxed contracts, Optional, `UNINIT`, COW protocol
- [strings.md](model/strings.md) — string layout, string-as-class, interpolated template class
- [arrays.md](model/arrays.md) — one `array` class, three storage strategies
- [classes.md](model/classes.md) — object layout, class descriptors, vtables, itables, property access
- [lowering.md](model/lowering.md) — the C structures and LLVM IR behind the model
- [model/memory/](model/memory/README.md) — arenas, arena reset, static lifetimes, ARC optimizations
- [model/gc/](model/gc/README.md) — GC strategies, SATB, heap design, research survey

### `runtime/` — execution substrate

- [implementation-language.md](runtime/implementation-language.md) — Rust core + thin C++ LLVM layer
- [object-lifecycle.md](runtime/object-lifecycle.md) — `new` and the three-phase teardown
- [actors.md](runtime/actors.md) — actor contexts, message queues, per-actor GC
- [exceptions.md](runtime/exceptions.md) — `throw`/`try`/`finally`: two error channels, trace materialization, and why `try` costs nothing

### Other areas

- [interop/](interop/README.md) — IR-level interop with C++/Rust (research)
- [io/](io/README.md), [stdlib/](stdlib/README.md) — placeholders, not yet designed
- [attributes.md](attributes.md) — the attributes principle (root document)
- [BACKLOG.md](BACKLOG.md) — deferred work, collected from all RFCs

## The key principle

**[Attributes are the language surface](attributes.md).** Limelight
adds zero new keywords and zero new syntax to PHP. Every capability
(actors, GC hints, generics) enters through native PHP 8 attributes
under the `Limelight\` namespace, and the compiler's whole-program
analysis materializes its findings back into source as the same
attributes. A Limelight program is, syntactically, a valid PHP program.

## Reading order

New to the project? Read in this order:

1. [attributes.md](attributes.md) — the principle everything hangs on
2. [model/memory/arenas.md](model/memory/arenas.md) — memory categories, the core bet
3. [model/gc/strategies.md](model/gc/strategies.md) — how collection is organized
4. [model/values.md](model/values.md) and [model/classes.md](model/classes.md) — what a value and an object are
5. [runtime/actors.md](runtime/actors.md) — the concurrency story
