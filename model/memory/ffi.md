# FFI: Pure C Structures, Ownership, and Attributes

> **Partially revised.** The review's two hard contradictions and the main
> holes are now resolved in this document: the hidden-`RcHeader`-at-−8 form
> is dropped (offset-0 invariant); an un-anchored foreign value falls to a
> tier-3 auto-`Box` rather than a compile error (accept-every-program); a
> foreign property is always a `Box`, so there is no bare "owned-foreign"
> slot kind; freeing is the class's own `__destruct` (no separate hook);
> and the `Box` records its wrapped type as an instance field. Still open,
> in [BACKLOG.md](../../BACKLOG.md): the `#[Borrow]`-into-`Box` UAF and the
> smaller naming/marshalling contradictions.

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
have an owner. Wherever the compiler can anchor it to one at compile time
it does, and the lifetime is fully static (below). Where it cannot — the
value escapes into `mixed`, a container, an unbounded call — the structure
does **not** become a compile error (that would break
accept-every-program, [static-lifetimes.md](static-lifetimes.md)); it
falls to the **tier-3 fallback: a managed `Box` wraps it**, supplying the
`RcHeader` the headerless struct lacks, and the `Box` becomes the owner.
This is Rust's lifetimes-must-anchor rule adapted to a language without
lifetime syntax and without rejection: infer the owner where possible, box
where not.

An owner is one of two things:

1. **A managed (ARC) object** — a property anchors the C structure. A
   managed object never stores a raw headerless struct inline; the
   property holds a **`Box`** wrapping it (a store into a class property is
   exactly an escape, "Escape" below). The structure's lifetime is then the
   `Box`'s, released in the owner's `dispose` (drop phase) before the
   owner's own memory is reclaimed. This is PHP FFI's rule made static —
   there, an owned `CData` lives and dies with the PHP object that holds it.
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

Freeing is the FFI class's own **`__destruct`**: you write an ordinary
destructor that calls the library's release function
(`sqlite3_close($this->handle)`), and the compiler lowers it into the
type's `dispose`, invoked at the structure's scheduled death — the owner's
`dispose`, the end of a tier-1/2 scope, or a wrapping `Box`'s teardown. A
class with no `__destruct` owns nothing to free (borrowed foreign memory)
and its death is a no-op beyond dropping the reference. There is **no
separate `free:` attribute**: a headerless struct cannot run a destructor
by refcount, so the compiler runs it directly at the death point it
already schedules.

### Escape: attaching to the managed world with `Box`

When a C structure must enter the dynamic world — stored into `mixed`, a
container, a class property, returned into untyped code — it can no longer
be a bare compile-time-typed reference (the managed world needs a tag and
a lifetime the raw structure cannot carry). It is attached through
**`Box`**, the built-in wrapper class (entity kind 4,
[classes.md](../classes.md)):

- `Box` is a managed, refcounted, GC-visible entity, always a **separate
  wrapper**: the C structure stays truly headerless and the `Box` holds a
  pointer to it. There is no hidden-header form — the offset-0 `RcHeader`
  invariant ([classes.md](../classes.md)) forbids a header at −8 of the C
  data, where the library's own fields live.
- The `Box` kind (4) is a single class-less singleton but wraps
  *different* FFI types, so the `Box` records its **wrapped type as an
  instance field** in its body: a descriptor pointer carrying the type's
  layout (for transparent `$box->field` access) and its `dispose`. Teardown
  runs that `dispose` — the wrapped class's lowered `__destruct`. This is
  `FFI\CData` / Rust `Box<T>`-around-a-raw-pointer, made explicit.
- A C structure that never escapes — provably confined to a tier-1 local —
  pays none of this: it stays a pure headerless value bound to its owner,
  freed by the compiler's scheduled `dispose`, and `Box` never
  materializes. Boxing is the tier-3 fallback for everything else.

`Box` appears **only** where a C structure is attached to the managed
world; code that keeps its FFI values in typed locals never sees it. A
managed object's property is such an attachment, so a foreign-typed
property holds a `Box`, not a bare struct — there is no separate
"owned-foreign" property slot kind.

**Terminology note.** This raw-struct `Box` is a different thing from the
*value* Box of [values.md](../values.md) — the 16-byte tagged cell for
`mixed`. Same word, two contexts; they share nothing but the name.

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
