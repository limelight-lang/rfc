# Value Representation

## Scope

How PHP values are represented in Limelight: the boxed representation for
dynamically-typed contexts, unboxed representations for declared types, and
the copy-on-write protocol. Strings and arrays have their own documents
([strings.md](strings.md), [arrays.md](arrays.md)); this one defines the
contracts they plug into.

---

## Two Contracts: ValueBox and Unboxed

**Decision**: Limelight uses two value representations, chosen per storage
site at compile time.

1. **ValueBox** — a 16-byte tagged value. Used where the static type is
   unknown: elements of mixed arrays, untyped parameters/locals/returns,
   `mixed`, dynamic properties.
2. **Unboxed** — a raw `i64` / `f64` / pointer, no tag. Used where the
   type is declared or proven by the compiler: typed properties, typed
   parameters, locals with inferred types. Arithmetic on unboxed values is
   native machine arithmetic.

The mixed world is large in real PHP code, so the ValueBox is not an edge case;
but every type declaration the programmer writes moves storage into the
unboxed contract for free.

**Terminology.** The ValueBox (a 16-byte tagged value, PHP's `zval` in
spirit) is a different thing from the built-in **`FFIBox` class**
(a built-in class with an entity kind of its own, [classes.md](classes.md), [ffi.md](memory/ffi.md))
that wraps a raw `#[FFI]` C structure for the managed world. Both were
once called "Box"; the 2026-07-27 rename ([layouts.md](layouts.md))
removed the collision, and the bare word is no longer used.

**In an object, a ValueBox appears only where the property has no declared
type.** A declared property occupies its machine representation and
nothing more — a bare pointer for an object or string, eight raw bytes
for an `int`. The ValueBox is not the object's storage format; it is the
storage format of one kind of property. See
[classes.md](classes.md), "Slot kinds".

---

## ValueBox Layout

```
+0   payload   8 B   union { i64, f64, ptr }
+8   type      1 B   type tag
+9   flags     1 B   bit 0 refcounted; bit 1 undef (property slots only);
                     bit 2 writing (rc-satb concurrent-marking lock, below);
                     bits 3-7 reserved, unassigned. This is the cheapest
                     spare room in the ValueBox: the byte is already loaded and
                     tested on every ValueBox copy (the refcounted bit), so a
                     future per-value boolean costs nothing to read here,
                     unlike one placed in the reserved bytes at +10
+10  reserved  6 B   bytes 10..15, through the end of the ValueBox: alignment
                     padding, not usable as per-slot state — the store
                     barrier writes all 16 bytes of the ValueBox
```

The `undef` flag (bit 1) marks a ValueBox property slot as uninitialized. A
ValueBox has the room in its own `flags` byte to carry this, so a `mixed` /
untyped property tracks its uninitialized state **in the slot**, and the
init bitmap below is left to the raw typed slots that have no such room.
The flag is meaningful only in a property slot and is never set on a ValueBox
in a local, parameter, return, array element, or ReferenceBox — the
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
| `string` | pointer → StringBox ([strings.md](strings.md)) |
| `array` | pointer → ArrayBox ([arrays.md](arrays.md)) |
| `object` | pointer → Object ([classes.md](classes.md)) |
| `resource` | pointer |
| `reference` | pointer → ReferenceBox (below) |

The `refcounted` flag in the ValueBox duplicates what the tag implies so that
retain/release on ValueBox copy is a single bit test, with no tag decoding.

There is deliberately **no `undef` tag**. Uninitialized is not a type,
so it does not take a tag value that `gettype` or a `switch` on the tag
would have to reckon with. It is the `flags` bit above (for a ValueBox slot)
or an init-bitmap bit (for a raw slot) — metadata beside the value,
never a tag inside the value's type space.

`IS_UNDEF` in Zend is a general VM value that flows through locals and
hashtables, which is what makes it an implementation detail leaking
into semantics. Here it cannot flow: the flag is confined to property
slots and reading one throws, and the bitmap is separate metadata.
Hashtable holes remain a separate, container-internal marker
([arrays.md](arrays.md)), unrelated to this.

The **writing** flag (bit 2) is the concurrent-marking lock: because a
16-byte ValueBox is published as two stores (payload, then tag), a background
marker reading the slot could otherwise catch a torn pair and trace a
non-pointer as a pointer. It is set and cleared only by `store_box` on the
`rc-satb` strategy and read only by that strategy's marker; every other
build leaves the bit permanently clear. The mechanism is in
[satb.md](gc/satb.md), "Torn 16-byte ValueBox reads".

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
`T` uses its own null; a scalar `T` uses the ValueBox.

- **Pointer `T`** (`?object`, `?string`, `?array`): **niche
  optimization**: null is the null pointer, size stays 8 bytes (exactly
  as `Option<&T>` in Rust). No tag and no sentinel — this is not a
  wrapper, it is the pointer. Its uninitialized state, if the property
  can have one, is a bit in the init bitmap, not a reserved pointer
  value.
- **Scalar `T`** (`?int`, `?float`): the **ValueBox**, with the compiler
  knowing statically that only two tags can occur.

An earlier revision specified a separate `Optional` construction,
`{ u8 discriminant, T value }`, for the scalar case. It bought nothing:
that is 16 bytes with alignment, exactly what the ValueBox costs, and the
unwrap is a one-byte compare either way, since a statically-known `?int`
can only be tagged `null` or `int`. What it did cost was a third value
representation, which every path handling a nullable scalar would have
had to implement beside the other two. SpiderMonkey removed its
`UnboxedObject` for that reason and measured a **gain** on real
workloads from having one representation less; the microbenchmark that
regressed 23% did not save it.

```llvm
; $x = $x + 5   where $x: ?int  — payload +0, tag +8 (ValueBox layout)
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

- **ValueBox slot** (`mixed` / untyped): the `undef` flag bit in the ValueBox
  itself (above). A read decodes the ValueBox anyway, so testing the bit is
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
- `unset()` returns the property **to** uninitialized, through whatever
  marker the slot has: a non-nullable pointer is stored `NULL` (a
  pointer can always be reset this way, its marker is free), a
  bitmap-tracked `?T`/scalar has its bit cleared, a ValueBox gets its `undef`
  flag. A raw scalar that carries no bit — one the compiler proved
  always-assigned, where `0` is a real value and there is nothing to
  clear — cannot be expressed as uninitialized; `unset()` on it is a
  **compile-time warning**, since the state it asks for does not exist.
  After a valid `unset()`, `isset()` reads false and a plain read throws
  (or reaches `__get` where the class defines one), matching PHP;
- `isset()` and `ReflectionProperty::isInitialized()` read it;
- `get_object_vars()`, `(array)` casts, `var_dump()`, `serialize()` and
  `foreach` over an object skip properties that read uninitialized,
  matching PHP. Lazy-proxy patterns (à la Doctrine) that probe state via
  reflection work unchanged.

So `Error`-on-uninitialized-read matches PHP without a test on every
typed read: the check rides only the properties that can be
uninitialized, and for a ValueBox slot it is free.

This state is metadata, never a language-level type: `gettype()`,
`is_*()` and every other value reflection are unreachable for it,
because the read throws before any of them runs.

**Construction.** Most of it is the zero-fill. A non-nullable pointer's
uninitialized marker is `NULL` (zero), and a bitmap-tracked slot's clear
bit is zero, so the body zero-fill sets "uninitialized" for both for
free. Only a ValueBox slot's `undef` flag is *not* zero (an all-zero ValueBox is
`null`), so a `mixed` property with no default takes one flag store
after the zero-fill — the same shape as stamping any non-zero default,
and only for that uncommon case. At a compiler-known `new` site those
stores are straight-line code; the out-of-line factory reads them from
the descriptor's `undef_runs` — the defaultless ValueBox slots as
`(offset, count)` runs, grouped by the layout into the tail of the
ValueBox trace run so the stamp is one contiguous stride
([classes.md](classes.md), "Class Descriptor").

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

## ReferenceBox (`&`)

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
COW by default; both can exist in non-COW form. For a string the flag
carries a second meaning it does not carry elsewhere: it **is** the
layout — set means bytes inline, clear means a dynamic string with its
bytes out of line — and it is fixed at creation for the life of the
entity ([strings.md](strings.md)). Plain objects may opt *into* COW,
giving value semantics.

Write barrier, identical everywhere. Separation allocates a new entity,
so the barrier takes the old pointer and returns the one the holder must
store; the address of an existing entity never changes:

```c
ptr = ll_cow_separate(ptr);   // no-op unless the rule below fires
```

The holder performs the write-back at its own store site: a local
ValueBox, a property slot, an array element, and a ReferenceBox's inner
ValueBox each store the returned pointer. An FFI handle cannot: the
foreign side holds its own copy of the pointer, so a borrowed
`const char*` into string bytes is invalidated by any mutation of that
string ([memory/ffi.md](memory/ffi.md)).

The rule that fires it:

```c
category is Immortal               → separate (the count is pinned at 1)
category is LongLived              → separate (the count is maintained,
                                      but is no sharing signal)
COW && refcount > 1                → separate
otherwise                          → write in place
```

**There is no `IS_ESCAPEE` arm** (2026-08-04). There used to be, because
while bit 11 is set the field holds an arena escape hold-count rather
than a reference count. A COW entity can no longer carry that bit: the
store barrier **copies** a COW value out of the arena instead of counting
an escape into it (below), so the two readings of those four bytes never
meet. The arm was a branch on the write path testing a bit nothing can
set.

Category before count, for a different reason in each of the two
categories. On an **immortal** entity retain and release return early and
leave the count at 1 forever (`ll-model/src/refcount.rs`), so reading
that 1 as "sole owner" would overwrite an interned string shared
process-wide. A **long-lived** COW entity takes neither early return —
the first needs the COW flag clear, the second needs the Immortal
category — so its count is maintained in full, and "pinned" does not
describe it. It separates because the count is maintained by a relaxed
load and a relaxed store rather than a read-modify-write
(`refcount::refcount_store`, the narrow-mutator amendment), which makes
it unreliable the moment the entity is reachable from a second thread,
and because `string_die` reclaims only the GC heap, so an in-place write
would land in memory nothing releases. Both halves are recorded at
`ll-model/src/refcount.rs::cow_separation_needed`.

**A COW value leaving the arena is copied at the store, not counted.**
When a store puts a request-arena COW entity into a longer-lived slot,
the store barrier allocates a copy in the GC heap and the slot takes the
copy; the escape hold-count is never touched. This is the deep copy
[arenas.md](memory/arenas.md) names for value-like data, and it is what
makes the rule above have no `IS_ESCAPEE` arm: a COW entity cannot be an
escapee, so bit 11 and the exact holder count never describe the same
four bytes. Identity is the reason it is allowed — a COW value has none
that a program can observe, while an object does and is therefore
promoted instead of copied.

**The store can therefore fail**, since a copy is an allocation.
`ll_store_ptr`, `ll_store_box` and `ll_ref_store` report it: on refusal
the slot and every count are exactly as they were. That is what makes the
refusal safe, and it is also what the caller must respect — an
overwriting store is the publish **and then, only if it succeeded**, the
drop of the displaced entity. Dropping after a refused publish releases
the reference the slot still holds. Generated code then raises
memory-exhausted ([exceptions.md](../runtime/exceptions.md)). The
log reserve that funds the barrier's own allocations does not extend
here — it works because a log record is fixed-size, and a copy is the
size of the value.

### Refcount is always maintained on COW entities

**Decision**: for COW-flagged entities the refcount is part of the value
semantics (it answers "is this buffer shared?"), not merely lifetime
bookkeeping. It is therefore maintained **in every memory category,
always**.

**Invariant (2026-08-03)**: on a COW entity the refcount equals the
number of holders. A second holder retains before it can write, and the
compiler may elide a retain/release pair only where it has proved that
no second holder arises. Deferred ARC ([memory/arc-optimizations.md]
(memory/arc-optimizations.md), item 2) therefore does not apply to COW
entities at any tier: it lets the count lag behind the stack until the
next safepoint, and the sharing test is consumed at the instant of the
write, where a lagging count means an in-place write into a string
somebody else holds. A lifetime undercount is repaired by the next stack
scan; a COW undercount corrupts the value silently and is never
repaired.

The invariant is checkable in a debug build: at the entry to a write,
compare the count against the holders reachable from the frame.

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
