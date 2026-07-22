# FFI: Pure C Structures, Ownership, and Attributes

## Scope

How Limelight represents **pure C structures** — foreign data with
C-compatible layout, no managed header, no ARC — and the model that
keeps them safe: **every such structure must have an owner**. Builds on
[zero-abstraction.md](zero-abstraction.md), which gives the memory
mechanics (no header, tier binding); this document defines the
declaration surface (attributes on ordinary classes), the field/type
mapping (where `string` means a **C string**, not the managed string),
and the ownership rules.

Foreign *functions* and library import (signatures, calling conventions,
marshalling of calls) belong to the interop RFC and are only sketched
here under "Deferred".

---

## Declaring a C structure

Following the attributes principle ([attributes.md](../../attributes.md)),
no new syntax: an ordinary class becomes a pure C structure with the
`#[FFI]` attribute.

```php
#[FFI]
class Timeval {
    public int $tv_sec;      // i64 at offset 0
    public int $tv_usec;     // i64 at offset 8
}
```

An `#[FFI]` class is an **unmanaged entity** ([zero-abstraction.md](zero-abstraction.md)):
no `RcHeader`, no class pointer, C field order and alignment, invisible
to the GC. Its type exists only at compile time; a reference to it is
meaningful only where the compiler statically knows the type. The class
is implicitly `final`; methods are allowed but always compile to direct
calls.

Under plain Zend the attribute is inert and the class is an ordinary
object ([attributes.md](../../attributes.md)) — the standard degradation
contract.

---

## Field types: `string` means a C string

**Decision**: inside an `#[FFI]` class the field types denote **C
types**, not managed types. This is the load-bearing difference from an
ordinary class.

| Declared field | C meaning | Notes |
|---|---|---|
| `int` | `int64_t` by default | width set by attribute (below) |
| `float` | `double` | `#[F32]` for `float` |
| `bool` | `_Bool` (1 byte) | |
| `string` | **C string** — `char*`, NUL-terminated | not the managed string; see marshalling |
| a nested `#[FFI]` class | the struct **inline** (by value) | not a pointer, unless declared `*T` |
| `#[Ptr] T` | `T*` | an explicit pointer field |
| `#[FixedArray(N)] int` | `int64_t[N]` inline | by-value fixed array |

A managed `string` and a C `string` are different things: the managed
one is an `RcHeader`-prefixed entity with COW, the C one is a bare
`char*` a library owns or expects to own. Inside `#[FFI]` the plain word
`string` is the C one; a managed string only ever appears at the
boundary through an explicit conversion (below).

### String marshalling

Three modes, the standard FFI tri-state (Rust `CString`/`CStr`, C#
`LPStr`, PHP `FFI::string`):

- **owned-copy** — a NUL-terminated `char*` the structure owns and frees
  with it (the default for an assigned `string` field);
- **borrowed-view** — a `#[Borrow] string`: a `char*` into memory some
  other owner holds; the structure does not free it, and its lifetime is
  tied to that owner (below);
- **length-carrying** — `#[Str(len: 'n')]`: a `(char*, len)` pair where
  another field holds the length, for non-NUL-terminated buffers.

Reading a C `string` into the managed world **copies** the bytes into a
managed string (as `FFI::string` does); writing a managed string out to
a C `string` field copies (owned) or borrows (`#[Borrow]`).

---

## The owner model

**Decision**: a pure C structure **cannot exist in a vacuum** — it must
have an owner, resolved at compile time, and a structure the compiler
cannot anchor to an owner is a **compile error**. This is Rust's
lifetimes-must-anchor rule adapted to a language without lifetime
syntax: the compiler infers the owner instead of the programmer writing
it.

An owner is one of two things:

1. **A managed (ARC) object** — a property holds the C structure (or a
   pointer to it). The structure's lifetime is the owner object's: it is
   released in the owner's `dispose` (drop phase), before the owner's
   own memory is reclaimed. This is PHP FFI's rule made static — there,
   an owned `CData` lives and dies with the PHP object that holds it.
2. **The code itself** — a local binding or a tier-1/2 value the
   compiler destroys deterministically at a known point
   ([static-lifetimes.md](static-lifetimes.md)). The structure is freed
   by that scheduled death, exactly like any statically-scoped value.

Acquire, use within a known scope, release with the owner — the expected
FFI shape. Because ownership is proven at compile time, the dangling and
double-free failures that runtime-keepalive FFI (cffi, PHP `FFI::new`)
can hit are ruled out by construction: there is no owned pointer without
a proven anchor, and no anchor is dropped while a borrow is live.

### Freeing

The release action comes from the declaration: `#[FFI(free: 'lib_close')]`
names the function that frees the structure's foreign memory; absent a
hook, the structure owns nothing to free (it is borrowed foreign memory)
and its death is a no-op beyond dropping the reference.

### Escape: attaching to the managed world with `Box`

When a C structure must enter the dynamic world — stored into `mixed`, a
container, returned into untyped code — it can no longer be a bare
compile-time-typed reference (the Box needs a tag and a lifetime the raw
structure cannot carry). It is attached through **`Box`**, the built-in
wrapper class (entity kind 4, [classes.md](../classes.md)):

- `Box` is a managed, refcounted, GC-visible entity holding the C
  structure (or a pointer to it) plus the release hook. Its teardown
  runs the hook. This is `FFI\CData` / Rust `Box<T>`-around-a-raw-pointer,
  made explicit.
- Two physical forms, the compiler's choice by whether the structure
  escapes:
  - **hidden-header** — the C structure carries an `RcHeader` **hidden
    at −8**, so `Box` points straight at the C data (offset 0 stays
    C-compatible: the library sees the fields, our code reads the header
    at −8). Costs 8 bytes on the structure, saves the separate wrapper
    allocation. Zend does the same with the refcount ahead of the data.
  - **separate wrapper** — the C structure stays truly headerless and
    `Box` is a distinct managed object holding a pointer to it. Zero
    overhead on the structure, one extra allocation and indirection.
- A C structure that never escapes pays neither: it stays a pure
  headerless value bound to its owner, and `Box` never materializes.

`Box` appears **only** where a C structure is attached to the managed
world; code that keeps its FFI values in typed locals never sees it.

---

## Strings and arrays at the boundary

An in-language `string`/`array` remains a managed RC/COW entity
([strings.md](../strings.md), [arrays.md](../arrays.md)). The boundary
exception (from [zero-abstraction.md](zero-abstraction.md)): a foreign
buffer may be *viewed* as a managed `string`/`array` without copying — a
borrowed view over zero-abstraction memory, bound to an owner or carried
by a `Box` when it escapes. A write to a borrowed view separates it into
an ordinary managed entity (the COW rule generalizes: shared with the
outside world, so any write copies).

---

## Attribute catalog

| Attribute | On | Meaning |
|---|---|---|
| `#[FFI]` | class | the class is a pure C structure |
| `#[FFI(free: 'fn')]` | class | function that frees the structure's foreign memory |
| `#[FFI(pack: N)]` | class | packed layout / alignment override (Rust `repr(packed)`, C# `Pack`) |
| `#[I32]` / `#[I16]` / `#[I8]` / `#[U32]` … | field | integer width/signedness (default `int` = `i64`) |
| `#[F32]` | field | `float` instead of `double` |
| `#[Ptr]` | field | the field is `T*`, not inline `T` |
| `#[FixedArray(N)]` | field | inline by-value array `T[N]` |
| `#[Borrow]` | field | borrowed pointer/string: not owned, not freed, anchored to an owner |
| `#[Str(len: 'field')]` | field | length-carrying string; the named field holds the length |
| `#[Encoding('utf8'\|'utf16'\|…)]` | `string` field | char encoding at the boundary |

Attributes are resolved purely at compile time and recorded in the
type's metadata; the runtime needs nothing new for them.

---

## Deferred

- **Foreign functions and libraries** — declaring imported C functions
  (signatures, calling conventions, per-argument marshalling); belongs
  with the interop RFC.
- **Extension interfaces on `#[FFI]` classes**
  ([classes.md](../classes.md)) — attaching an interface needs an itable
  reached from a descriptor at conversion time; a `Box` can carry it,
  the raw structure cannot. Decide with the interop RFC.
- **Mutable borrowed views** — whether a native caller may observe
  writes through a view (shared mutable memory) or separation is always
  forced; leaning to always-separate for PHP semantics.
