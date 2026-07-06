# Value Representation

## Scope

How PHP values are represented in Limelight: the boxed representation for
dynamically-typed contexts, unboxed representations for declared types, and
the copy-on-write protocol. Strings and arrays have their own documents
([strings.md](strings.md), [arrays.md](arrays.md)); this one defines the
contracts they plug into.

---

## Two Contracts: Box and Unboxed

**Decision**: Limelight uses two value representations, chosen per storage
site at compile time.

1. **Box** — a 16-byte tagged value. Used where the static type is
   unknown: elements of mixed arrays, untyped parameters/locals/returns,
   `mixed`, dynamic properties.
2. **Unboxed** — a raw `i64` / `f64` / pointer, no tag. Used where the
   type is declared or proven by the compiler: typed properties, typed
   parameters, locals with inferred types. Arithmetic on unboxed values is
   native machine arithmetic.

The mixed world is large in real PHP code, so the Box is not an edge case —
but every type declaration the programmer writes moves storage into the
unboxed contract for free.

---

## Box Layout

```
+0   payload   8 B   union { i64, f64, ptr }
+8   type      1 B   type tag
+9   flags     1 B   refcounted / collectable
+10  reserved  6 B   alignment; available for future caches
```

**Why not NaN-boxing (8 bytes)?** JS engines fit everything into a double's
NaN space, but that gives ~51 bits for integers — PHP integers must be full
64-bit. Boxing large ints on the heap would break both semantics and
arithmetic speed. Zend reached the same conclusion; 16 bytes it is.

### Type tags

| Tag | Payload |
|-----|---------|
| `null` | — |
| `false` | — (false and true are **separate tags**: `if ($x)` never reads the payload) |
| `true` | — |
| `int` | i64 |
| `float` | f64 |
| `string` | pointer → string entity ([strings.md](strings.md)) |
| `array` | pointer → array entity ([arrays.md](arrays.md)) |
| `object` | pointer → Object ([classes.md](classes.md)) |
| `resource` | pointer |
| `reference` | pointer → reference box (below) |

The `refcounted` flag in the Box duplicates what the tag implies so that
retain/release on Box copy is a single bit test, with no tag decoding.

There is deliberately **no `undef` tag**: Limelight targets PHP language
semantics, not Zend internals, and `IS_UNDEF` is a Zend VM implementation
detail. Its duties are dissolved elsewhere: uninitialized typed properties
→ the `UNINIT` slot state (below); hashtable holes → container-internal
markers invisible to the language.

All pointer payloads point to entities that begin with the common
`RcHeader` (refcount + flags at offset 0, see [classes.md](classes.md)).

---

## Unboxed Representation

A declared scalar type occupies exactly its machine size in the slot:
`int $x` is 8 raw bytes, `float $x` is an f64, an object of a known class
is a bare pointer. No tag, no flags — the type lives in `prop_layout` /
the function signature.

### Optional — nullable types

**Decision**: `?T` is represented as **Optional** — the Rust `Option<T>` /
Swift `Optional` construction. Not boxed, no dynamic type tag: the type is
static, the only runtime information is a discriminant.

- **Scalar `T`** (`?int`, `?float`): `{ u8 discriminant, T value }` —
  16 bytes. An operation like `$x + 5` compiles to one discriminant test
  (the unwrap) followed by native arithmetic; the null branch takes PHP's
  coercion path.
- **Pointer `T`** (`?object`, `?string`, `?array`): **niche
  optimization** — null is the null pointer, size stays 8 bytes (exactly
  as `Option<&T>` in Rust).

```llvm
; $x = $x + 5   where $x: ?int
%d = load i8, ptr %x.disc
br %d == NULL → %coerce, else → %add
%add:                                  ; hot path
  %v = load i64, ptr %x.value
  %r = add i64 %v, 5                   ; bare machine arithmetic
%coerce:                               ; PHP: null + 5 = 5 (deprecation)
```

- **Uninitialized typed properties**: **Decision** — the `UNINIT` state
  is kept only where it can be encoded for free; a slot is never widened
  to carry it.

  | Slot | `UNINIT` encoding | Cost |
  |------|-------------------|------|
  | `?int`, `?float` | third discriminant value (the byte already exists) | free |
  | `?object`, `?string`, `?array` | sentinel pointer `1` (the null pointer already means PHP `null`) | free |
  | non-nullable pointer | null pointer | free |
  | non-nullable scalar | **not represented** | would widen 8 → 16 B |

  Reading an `UNINIT` slot compiles to throwing `Error` (PHP semantics).
  Where definite-assignment analysis proves initialization (e.g.
  constructor promotion), the state is never materialized and the check
  disappears.

  **Deliberate deviation**: a non-nullable scalar property whose
  initialization definite-assignment analysis cannot prove is
  zero-initialized; reading it before the first write yields `0` / `0.0`
  instead of PHP's `Error`, and `unset()` cannot return it to the
  uninitialized state. Doubling every escaping `int $x` slot to catch
  this one case was judged not worth the memory. Lazy-proxy patterns
  that rely on uninitialized state (à la Doctrine) use object/nullable
  properties, which keep full `UNINIT` support.

  `UNINIT` is a slot state, never a language-level type.

### References into unboxed slots

**Decision**: `&$obj->typedProp` uses a second variant of the reference
box — a typed slot reference:

```
RcHeader | owner (ptr, retained) | slot (ptr) | type
```

Reads box the raw value on the fly; writes type-check and store raw. The
variant is distinguished by a flag bit in the box's own header. `&` is
rare in real code, and the entire cost is confined to the box — code that
does not use references pays nothing.

---

## Reference Box (`&`)

A reference is a separate refcounted box containing one Value slot.
Variables bound by `&` point to the same box. This is the only extra
indirection in the model, and only code that actually uses `&` pays it
(same design as `zend_reference`).

```
RcHeader | Value
```

---

## Copy-on-Write Protocol

### COW is a per-object flag

**Decision**: COW is not hard-wired to types. Any heap entity can carry
the COW flag (one bit in `RcHeader.flags`). Strings and arrays are created
COW by default; both can exist in non-COW (freely mutable) form — see
[strings.md](strings.md) for mutable string buffers. Plain objects may opt
*into* COW, giving value semantics.

Write barrier, identical everywhere:

```c
if ((flags & LL_COW) && refcount > 1) separate();
```

### Refcount is always maintained on COW entities

**Decision**: for COW-flagged entities the refcount is part of the value
semantics — it answers "is this buffer shared?" — not merely lifetime
bookkeeping. It is therefore maintained **in every memory category,
always**.

The memory category (see [arenas.md](memory/arenas.md)) changes only the
reaction when the count reaches zero:

| Category | On refcount = 0 |
|----------|-----------------|
| GC heap | free |
| Request arena / long-lived | nothing — arena reset reclaims |
| Immortal | unreachable by construction: retain/release are no-ops, and a write **always** separates (as with Zend interned/immutable data) |

Non-COW entities (objects without the flag) keep the plain rule from
[arc-optimizations.md](memory/arc-optimizations.md): arena and immortal
categories skip counting entirely.
