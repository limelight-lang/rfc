# Model

Runtime Data Model — describes how PHP-level concepts are represented in memory at a low level.

This includes object layouts, vtables, method dispatch tables, exception structures, closures, and other language mechanisms. This layer sits below the language semantics but above the VM: it defines *what PHP objects look like in memory*, not how they are executed.

## Documents

- [classes.md](classes.md) — object layout, class descriptors, vtables, itables, dispatch, extension interfaces
- [lowering.md](lowering.md) — C structures and LLVM IR patterns for the class model
- [values.md](values.md) — Box / unboxed value representation, COW protocol
- [strings.md](strings.md) — string layout, string-as-class, mutability modes, interpolated string class
- [arrays.md](arrays.md) — three storage implementations, transitions
- [memory/](memory/) — arenas, ARC optimizations
- [gc/](gc/) — GC research and heap design decisions
