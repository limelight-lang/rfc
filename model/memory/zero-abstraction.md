# Zero-Abstraction Objects: `#[FFI]`

## Motivation

FFI and IR-level interop ([../../interop/README.md](../../interop/README.md))
need objects the runtime does not manage: a struct returned by a C
library, a buffer owned by Rust code, a memory-mapped region. Such an
object must be **memory as-is**: C-compatible layout, no hidden header,
no ARC, invisible to any GC strategy. Wrapping every foreign value in a
managed object by default would tax exactly the code that exists for
performance or binary compatibility.

Following the attributes principle ([../../attributes.md](../../attributes.md)),
no new syntax is introduced: a class is declared zero-abstraction with
the `#[FFI]` attribute.

```php
#[FFI]
class Timeval {
    public int $tv_sec;      // i64 at offset 0
    public int $tv_usec;     // i64 at offset 8
}
```

## Definition

An `#[FFI]` class is an **unmanaged entity**:

- **No `RcHeader`, no class pointer.** The common-header rule of
  [classes.md](../classes.md) applies to *managed* entities only; an
  `#[FFI]` object's layout is exactly its declared properties, at
  C-compatible offsets.
- **Typing is compile-time only.** There is nothing in memory to
  identify the type at runtime, so a reference to an `#[FFI]` object is
  meaningful only where the compiler statically knows the type.
- **Invisible to memory management.** No retain/release, no cycle
  candidacy, no arena category bits. The GC strategy contract
  ([../gc/strategies.md](../gc/strategies.md)) never sees these objects.
- **A raw `#[FFI]` reference never enters a Box** ([../values.md](../values.md)):
  the Box requires a tag and lifetime rules the object cannot carry.
  Only its wrapper (below) may enter the dynamic world.

## Lifetime: two compiler strategies

ARC is unavailable, so the tier ladder of
[static-lifetimes.md](static-lifetimes.md) applies with a different
bottom rung. In tier order:

### 1. Owner binding (the primary path)

The compiler determines the **owner**: the binding or host object whose
lifetime contains the `#[FFI]` object's use. Then the lifetime is
simple and fully static:

- owned by a local or a tier-1/2 object: freed by the scheduled drop
  of the owner, exactly like any statically scheduled death;
- owned by a managed object (a property holds it): released in the
  owner's drop phase ([../../runtime/object-lifecycle.md](../../runtime/object-lifecycle.md)),
  before the owner's memory is reclaimed.

This is the expected case for FFI code: acquire, use within a known
scope, release with the owner.

### 2. `Box` attachment (the fallback)

When the reference escapes to where static lifetime cannot be proven
(stored into `mixed`, a container, captured by an escaping closure,
returned into untyped code), the compiler attaches it through **`Box`**,
the built-in wrapper class (entity kind 4, [classes.md](../classes.md);
full model in [ffi.md](ffi.md)).

- `Box` is a normal managed citizen: refcounted, GC-visible; its
  teardown invokes the declared release hook.
- The hook comes from the declaration: `#[FFI(free: 'lib_close')]`;
  absent a hook, `Box` frees nothing and only carries the pointer
  (borrowed foreign memory).
- Two physical forms, the compiler's choice: a **hidden `RcHeader` at
  −8** on the structure itself (`Box` points at the C data, offset 0
  stays C-compatible), or a **separate** `Box` object pointing at a
  headerless structure ([ffi.md](ffi.md), "Escape").
- Analogy: PHP's `FFI\CData`, Rust's `Box<T>` around a raw pointer.
  `Box` appears only where escape actually happens; code that stays in
  tier 1–2 pays zero.

## Strings and arrays at the FFI boundary

In-language strings and arrays remain **managed RC/COW entities**
exactly as specified in [../strings.md](../strings.md) and
[../arrays.md](../arrays.md): they are created by PHP code, and RC/COW
is their value semantics.

The exception is the boundary. A foreign buffer (a C string, a numeric
array from a native library) may be viewed as a PHP `string` or
`array` **without copying**: a borrowed view over zero-abstraction
memory. The view follows the same two strategies: bound to an owner
while the compiler can prove the buffer outlives it, or carried by a
wrapper when it escapes. A write to a borrowed view separates it into
an ordinary managed entity (the COW rule generalizes: the view is
"shared with the outside world", so any write copies).

## Interactions

- [static-lifetimes.md](static-lifetimes.md): `#[FFI]` objects are
  tier-1/2-only citizens; the wrapper is how they buy a ticket into
  tier 3.
- [../classes.md](../classes.md): the common `RcHeader` rule is scoped
  to managed entities; `#[FFI]` classes have no header, no vtable, no
  itables. Methods on an `#[FFI]` class are allowed but always compile
  to direct calls (the class is implicitly final).
- [../values.md](../values.md): raw `#[FFI]` references live only in
  unboxed, statically typed slots; the Box may carry only the wrapper.
- [../../attributes.md](../../attributes.md): `#[FFI]` joins the
  attribute registry; plain PHP degradation contract: under Zend the
  attribute is inert and the class behaves as an ordinary object.

## Open questions

- **The wider `#[FFI]` family**: declaring foreign *functions* and
  libraries (import signatures, calling conventions, marshalling
  rules); belongs with the interop RFC.
- **Extension interfaces on `#[FFI]` classes**
  ([../classes.md](../classes.md)): attaching interfaces requires an
  itable, which requires a class descriptor at conversion time; the
  wrapper could carry it, the raw object cannot. Decide when the
  interop RFC lands.
- **Mutable borrowed views**: whether a native caller may observe
  writes through a view (shared mutable memory) or separation is always
  forced; leaning to always-separate for PHP semantics.
