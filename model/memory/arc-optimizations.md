# ARC Optimizations

> Items 1 and 3 are superseded by
> [static-lifetimes.md](static-lifetimes.md) — the compiler now tracks
> ownership and moves as a general tier ladder (stack / scheduled drop /
> runtime ARC), of which pairing elimination and escape analysis are
> the degenerate rungs. Deferred ARC (item 2) is repositioned there as
> an optional runtime optimization for tier-3 objects only.

## 1. Compiler ARC Pairing (static elimination)

The LLVM ARC optimization pass eliminates paired retain/release calls when the code between them provably cannot trigger a release. Most temporary objects inside a function produce zero refcount operations after this pass.

Modeled after Swift's ARCOpt pass and clang's ObjC ARC optimizer.

## 2. Deferred ARC (runtime, stack deferral)

Local variables do not update refcounts continuously. Only heap→heap pointer writes update counts immediately. The stack is scanned at epoch boundaries (safepoints) to account for stack-held references.

Eliminates the dominant source of refcount traffic — local variable scoping. Reduces refcount operations by up to 80%.

## 3. Escape Analysis → Stack Allocation

If the compiler proves an object does not escape the current function, it is allocated on the stack or freed on function exit with no refcount at all. Zero RC operations, zero GC involvement.

## 4. Biased Reference Counting

Most objects are accessed from a single thread. While an object is thread-local, non-atomic increments/decrements are used (~1 cycle). When an object escapes to another thread, the bias is revoked and atomic operations take over (~10–40 cycles uncontended).

Eliminates atomic bus traffic for the common single-threaded case.

## 5. Immortal Objects

Objects that never die (null, true, false, small integers, permanently interned strings) carry an immortality flag in the object header. All retain/release operations on these objects are no-ops. No RC overhead ever.

## 6. Arena-Scoped Objects

Objects in the request arena or long-lived arena are not reference counted at all during their lifetime. They are reclaimed by arena reset (request arena) or explicit lifecycle management (long-lived arena). See `arenas.md`.

---

## Priority Order

| Optimization | Impact | Complexity |
|---|---|---|
| Compiler ARC pairing | High | Low — LLVM pass |
| Arena scoping | Very high | Medium |
| Deferred ARC | High | Medium |
| Escape analysis → stack alloc | Very high | High |
| Immortal objects | Medium | Low |
| Biased RC | High (multi-threaded) | High |
