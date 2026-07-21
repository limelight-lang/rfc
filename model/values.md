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

The mixed world is large in real PHP code, so the Box is not an edge case;
but every type declaration the programmer writes moves storage into the
unboxed contract for free.

**In an object, a Box appears only where the property has no declared
type.** A declared property occupies its machine representation and
nothing more — a bare pointer for an object or string, eight raw bytes
for an `int`. The Box is not the object's storage format; it is the
storage format of one kind of property. See
[classes.md](classes.md), "Slot kinds".

---

## Box Layout

```
+0   payload   8 B   union { i64, f64, ptr }
+8   type      1 B   type tag
+9   flags     1 B   refcounted / collectable
+10  reserved  6 B   alignment; not usable as per-slot state — the
                     store barrier writes all 16 bytes of the Box
```

**Why not NaN-boxing (8 bytes)?** JS engines fit everything into a double's
NaN space, but that gives ~51 bits for integers; PHP integers must be full
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
| `uninit` | — (a **slot state**, not a value; see the restriction below) |

The `refcounted` flag in the Box duplicates what the tag implies so that
retain/release on Box copy is a single bit test, with no tag decoding.

### `uninit` is a slot state, and only a slot state

**Decision**: the tag space carries `uninit`, and it is confined to
**property slots**. It is the Box's equivalent of the sentinel pointer
`1` that already encodes the same state in a pointer slot: the storage
says "nothing has been written here yet", in the room the storage
already has.

The restriction is the whole design, and it is what separates this from
Zend's `IS_UNDEF`:

- A Box tagged `uninit` may exist **only** in a property slot. Never in
  a local, a parameter, a return value, an array element, or a
  reference box.
- Reading such a slot throws `Error`, per PHP semantics for
  uninitialized typed properties. The read decodes the tag anyway, so
  the check costs nothing.
- Therefore it cannot escape into a value context: the only operation
  that could carry it out of the slot is the one that throws.

`IS_UNDEF` in Zend is a general VM value that flows through locals and
hashtables, and that generality is what makes it an implementation
detail leaking into semantics. Here it is a state of one storage site,
with the language never able to observe it as a type: `gettype()`,
`is_*()` and every other reflection of "what is this" are unreachable
for it, because reading the slot throws first.

Hashtable holes remain a separate, container-internal marker
([arrays.md](arrays.md)), invisible to the language and unrelated to
this tag.

**`null` keeps tag value 0, and `uninit` does not.** An all-zero Box is
`null`, which is what an untyped property must start as and what makes
object initialization a single range store
([classes.md](classes.md), "Slot order"). A `?int` property starts as
`uninit` instead, so its slot takes one explicit tag store after that
range is cleared. Untyped properties are the common case in real PHP
and pay nothing; nullable scalar properties pay one store each at
construction. The reverse numbering would invert that trade.

All pointer payloads point to entities that begin with the common
`RcHeader` (refcount + flags at offset 0, see [classes.md](classes.md)).

---

## Unboxed Representation

A declared scalar type occupies exactly its machine size in the slot:
`int $x` is 8 raw bytes, `float $x` is an f64, an object of a known class
is a bare pointer. No tag, no flags: the type lives in `prop_layout` /
the function signature.

### Nullable types

**Decision**: `?T` introduces **no third representation**. A pointer-shaped
`T` uses its own null; a scalar `T` uses the Box.

- **Pointer `T`** (`?object`, `?string`, `?array`): **niche
  optimization**: null is the null pointer, size stays 8 bytes (exactly
  as `Option<&T>` in Rust). No tag exists, because none is needed —
  this is not a wrapper, it is the pointer.
- **Scalar `T`** (`?int`, `?float`): the **Box**, with the compiler
  knowing statically that only two tags can occur.

An earlier revision specified a separate `Optional` construction,
`{ u8 discriminant, T value }`, for the scalar case. It bought nothing:
that is 16 bytes with alignment, exactly what the Box costs, and the
unwrap is a one-byte compare either way, since a statically-known `?int`
can only be tagged `null` or `int`. What it did cost was a third value
representation, which every path handling a nullable scalar would have
had to implement beside the other two. SpiderMonkey removed its
`UnboxedObject` for that reason and measured a **gain** on real
workloads from having one representation less; the microbenchmark that
regressed 23% did not save it.

```llvm
; $x = $x + 5   where $x: ?int  — payload +0, tag +8 (Box layout)
%t = load i8, ptr %x.tag
br %t == TAG_NULL → %coerce, else → %add
%add:                                  ; hot path
  %v = load i64, ptr %x.payload
  %r = add i64 %v, 5                   ; bare machine arithmetic
%coerce:                               ; PHP: null + 5 = 5 (deprecation)
```

The cost is paid in one place and named: a `?int` **property** occupies
16 bytes where a discriminant packed into the object's byte block would
have taken 9. Classes with many nullable scalar properties pay it. That
is the trade for not carrying a third representation through every path
that touches a value.

- **Uninitialized typed properties**: **Decision**: the `UNINIT` state
  never widens a slot. It is encoded in-slot where that is free, and in
  a per-object sidecar **init bitmap** otherwise.

  | Slot | `UNINIT` encoding | Cost |
  |------|-------------------|------|
  | `?object`, `?string`, `?array` | sentinel pointer `1` (the null pointer already means PHP `null`) | free |
  | non-nullable pointer | null pointer | free |
  | `?int`, `?float`, untyped / `mixed` | the `uninit` tag (the tag byte already exists) | free |
  | non-nullable scalar | bit in the init bitmap; the slot itself is zero-initialized | ~free (bits usually fit the object's alignment padding) |

  Every boxed slot therefore encodes the state in itself, and the
  bitmap is left serving one case: raw scalar slots, which have no room
  to say anything but their own value.

  The bitmap exists only in classes that have non-nullable scalar
  properties escaping definite-assignment analysis; where the analysis
  proves initialization (e.g. constructor promotion), no state is
  materialized at all.

  The bitmap is **not consulted on ordinary reads**: the hot path pays
  nothing. It is maintained and queried only by operations explicitly
  about initialization state:

  - a write to a tracked property sets its bit (one `or` store);
  - `unset()` clears the bit, so `unset()` + `isset()` behave as in PHP;
  - `isset()` and `ReflectionProperty::isInitialized()` read the bit;
  - `get_object_vars()`, `(array)` casts, `var_dump()`, `serialize()`
    and `foreach` over an object skip properties whose bit is clear,
    matching PHP's skipping of uninitialized properties. Lazy-proxy
    patterns (à la Doctrine) that probe state via reflection work
    unchanged.

  For every in-slot-encoded kind — the pointer rows and the boxed rows
  — reading `UNINIT` throws `Error` per PHP semantics; the read decodes
  the slot anyway, so the check is free.

  **Deliberate deviation**, now down to one row: directly reading an
  uninitialized **non-nullable scalar** property yields `0` / `0.0`
  instead of throwing `Error`. Guarding that would put a bitmap test on
  every escaping `int $x` read, which is exactly the cost this design
  refuses. The bit is still maintained, so every operation that is
  *about* initialization — `isset()`, reflection, `serialize()`,
  `foreach` — answers correctly; only the direct read is unguarded.

  `UNINIT` is a slot state, never a language-level type.

### References into unboxed slots

**Decision**: `&$obj->typedProp` uses a second variant of the reference
box, a typed slot reference:

```
RcHeader | owner (ptr, retained) | slot (ptr) | type
```

Reads box the raw value on the fly; writes type-check and store raw. The
variant is distinguished by a flag bit in the box's own header. `&` is
rare in real code, and the entire cost is confined to the box; code that
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
COW by default; both can exist in non-COW (freely mutable) form; see
[strings.md](strings.md) for mutable string buffers. Plain objects may opt
*into* COW, giving value semantics.

Write barrier, identical everywhere:

```c
if ((flags & LL_COW) && refcount > 1) separate();
```

### Refcount is always maintained on COW entities

**Decision**: for COW-flagged entities the refcount is part of the value
semantics (it answers "is this buffer shared?"), not merely lifetime
bookkeeping. It is therefore maintained **in every memory category,
always**.

The memory category (see [arenas.md](memory/arenas.md)) changes only the
reaction when the count reaches zero:

| Category | On refcount = 0 |
|----------|-----------------|
| GC heap | free |
| Request arena / long-lived | nothing; arena reset reclaims |
| Immortal | unreachable by construction: retain/release are no-ops, and a write **always** separates (as with Zend interned/immutable data) |

Non-COW entities (objects without the flag) keep the plain rule from
[arc-optimizations.md](memory/arc-optimizations.md): arena and immortal
categories skip counting entirely.
