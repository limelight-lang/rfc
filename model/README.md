# Model

Runtime data model: how PHP-level concepts are represented in memory. This
layer defines object layouts, vtables, dispatch tables, exception structures,
closures, and related mechanisms. It sits below language semantics and above
the execution substrate.

## Core terminology

- A **value** is a language-level datum. Dynamic values use `ValueBox`; declared
  immediate types may use an unboxed representation.
- An **entity** is a managed allocation with an `RcHeader`; objects, strings,
  arrays, and reference boxes are entity kinds.
- A **managed reference** participates in reference counting. A raw pointer does
  not imply ownership or lifetime.
- The **user destructor** is PHP's `__destruct`. **Teardown** also includes weak
  reference invalidation and field release; **storage reclamation** returns the
  allocation for reuse.
- An **arena** is an allocation region backed by one or more blocks and reclaimed
  as a unit; it need not occupy one contiguous virtual-address range.

The complete vocabulary and retired-term mapping is in
[`dev/GLOSSARY.md`](../dev/GLOSSARY.md).

## Documents

- [layouts.md](layouts.md) — the visual map: every byte layout (ValueBox, RcHeader, all entities) in one place, with the naming convention that separates ValueBox from FFIBox
- [classes.md](classes.md) — object layout, class descriptors, vtables, itables, dispatch, extension interfaces
- [lowering.md](lowering.md) — C structures and LLVM IR patterns for the class model
- [values.md](values.md) — ValueBox / unboxed value representation, COW protocol
- [weak-references.md](weak-references.md) — WeakReference / WeakMap machinery: the canonical weak cell, the per-thread weak table, death notification
- [strings.md](strings.md) — string layout, string-as-class, mutability modes, interpolated string class
- [arrays.md](arrays.md) — three storage implementations, transitions
- [memory/](memory/) — arenas, ARC optimizations
- [gc/](gc/) — GC research and heap design decisions
