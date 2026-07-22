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
+9   flags     1 B   bit 0 refcounted; bit 1 undef (property slots only)
+10  reserved  6 B   alignment; not usable as per-slot state — the
                     store barrier writes all 16 bytes of the Box
```

The `undef` flag (bit 1) marks a Box property slot as uninitialized. A
Box has the room in its own `flags` byte to carry this, so a `mixed` /
untyped property tracks its uninitialized state **in the slot**, and the
init bitmap below is left to the raw typed slots that have no such room.
The flag is meaningful only in a property slot and is never set on a Box
in a local, parameter, return, array element, or reference box — the
same confinement `IS_UNDEF` lacks in Zend, which is why Zend's leaks
into semantics and this does not.

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

The `refcounted` flag in the Box duplicates what the tag implies so that
retain/release on Box copy is a single bit test, with no tag decoding.

There is deliberately **no `undef` tag**. Uninitialized is not a type,
so it does not take a tag value that `gettype` or a `switch` on the tag
would have to reckon with. It is the `flags` bit above (for a Box slot)
or an init-bitmap bit (for a raw slot) — metadata beside the value,
never a tag inside the value's type space.

`IS_UNDEF` in Zend is a general VM value that flows through locals and
hashtables, which is what makes it an implementation detail leaking
into semantics. Here it cannot flow: the flag is confined to property
slots and reading one throws, and the bitmap is separate metadata.
Hashtable holes remain a separate, container-internal marker
([arrays.md](arrays.md)), unrelated to this.

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
  as `Option<&T>` in Rust). No tag and no sentinel — this is not a
  wrapper, it is the pointer. Its uninitialized state, if the property
  can have one, is a bit in the init bitmap, not a reserved pointer
  value.
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

### Uninitialized properties

**Decision**: the uninitialized state is tracked by **where the slot has
room to say it**, and only for properties that can actually have it.

- **Box slot** (`mixed` / untyped): the `undef` flag bit in the Box
  itself (above). A read decodes the Box anyway, so testing the bit is
  part of that decode and costs nothing extra.
- **Non-nullable pointer** (`Foo`, `string`, `array`): **`NULL` itself**.
  A non-nullable type can never legally hold null, so a null in the slot
  is unambiguously "not written yet". The read compares to null and
  throws on it — no bitmap, one compare. After that compare the value is
  provably non-null, which is exactly where `!nonnull` is legal
  ([lowering.md](lowering.md)).
- **`?T` pointer and raw scalar** (`?Foo`, `int`, `float`, `bool`): no
  spare value — `null` is a real value for `?T`, `0` is a real value for
  a scalar — so a bit in a per-object **init bitmap**. A class carries a
  bitmap only when it has such properties, one bit each.

**Which properties, in both cases.** The criterion is the declaration,
not the type: a property **declared without an initializer** can be
uninitialized and is tracked; a property **with a default** (`= 1`,
`= null`, `= ''`) starts with that value and is never uninitialized, so
it is tracked by neither mechanism and reads with no check. This holds
whether the property is typed or `mixed`, instance or static — the
common default-carrying property pays nothing.

The check is consulted **only** by operations about initialization
state, and an untracked property is never checked:

- reading a tracked property tests its flag/bit; uninitialized throws
  `Error`, exactly PHP's behavior for an uninitialized typed property;
- a write clears the state (stores the value; for a raw slot, sets the
  bit);
- `unset()` restores it, so `unset()` + `isset()` behave as in PHP;
- `isset()` and `ReflectionProperty::isInitialized()` read it;
- `get_object_vars()`, `(array)` casts, `var_dump()`, `serialize()` and
  `foreach` over an object skip properties that read uninitialized,
  matching PHP. Lazy-proxy patterns (à la Doctrine) that probe state via
  reflection work unchanged.

So `Error`-on-uninitialized-read matches PHP without a test on every
typed read: the check rides only the properties that can be
uninitialized, and for a Box slot it is free.

This state is metadata, never a language-level type: `gettype()`,
`is_*()` and every other value reflection are unreachable for it,
because the read throws before any of them runs.

**Construction.** Most of it is the zero-fill. A non-nullable pointer's
uninitialized marker is `NULL` (zero), and a bitmap-tracked slot's clear
bit is zero, so the body zero-fill sets "uninitialized" for both for
free. Only a Box slot's `undef` flag is *not* zero (an all-zero Box is
`null`), so a `mixed` property with no default takes one flag store
after the zero-fill — the same shape as stamping any non-zero default,
and only for that uncommon case.

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
