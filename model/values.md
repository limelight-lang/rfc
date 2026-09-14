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

A ValueBox is two 8-byte words, and the word at +8 says which of two arms the
box is on. On the **pointer arm** the +8 word is the counted pointer itself:
every entity begins with an 8-aligned `RcHeader` (the header is
`align(8)` in `ll-model`'s `refcount.rs`, and [maps.md](maps.md): "the
arena rounds to 8 and a class's object size is aligned to 8"), so bit 0 of a
pointer is clear, and a non-zero +8 word with bit 0 clear is a pointer and
nothing else.
On the **immediate arm** the +8 word is a *tag word* with bit 0 set. The +8
word alone decides the arm: on the pointer arm +0 is a tag word and has bit 0
set, on the immediate arm +0 is the value and is unconstrained — an odd
integer or an f64 whose low bit is set is not a pointer-arm box. `(0, 0)` is
null.

```
+0   payload   8 B   immediate arm: the value — a full i64, an f64 bit pattern
                     untouched, 0 for null/false/true (never read)
                     pointer arm: the tag word (below), carrying the entity's
                     tag code, so a type test never chases the pointer
+8   word      8 B   0            null — the all-zero box is null
                     bit 0 = 0    pointer arm: the counted entity pointer,
                                  non-zero, → an entity beginning with RcHeader
                     bit 0 = 1    immediate arm: the tag word

tag word (either position; byte 0 is the low byte — both targets are
little-endian, and the hex words below are written that way):
     byte 0   flags   bit 0 fixed to 1 (this is a tag word, not a pointer);
                      bit 1 undef (property slots only); bits 2-7 reserved,
                      unassigned — the cheapest spare room in the ValueBox,
                      since the byte is loaded on every type test
     byte 1   type    the tag code, table below
     bytes 2-3        zero
     bytes 4-7        zero in a slot; a container may use them for its own
                      per-element state (arrays-hashtable.md, the collision
                      link), and a read hands a box out with bits 16-63 of
                      the tag word cleared — so a null read out of a container
                      is (0, 0x0001), a second spelling every null test accepts
```

Sample boxes, as `(+0, +8)`:

```
int 42        ( 42,                 0x0301 )        tag word: Int (3) at byte 1, flags 0b01
float 2.5     ( f64 bits of 2.5,    0x0401 )
true          ( 0,                  0x0201 )
null          ( 0,                  0 )             a fresh null and the zero-fill; a null
                                                    read out of a container is (0, 0x0001)
                                                    and keeps that spelling wherever it is
                                                    stored next — the barrier writes the
                                                    box it is given
undef slot    ( 0,                  0x0003 )        flags 0b11: tag word + undef, tag Null
"hi"          ( 0x0501,             ptr → StringBox )
object        ( 0x0701,             ptr → Object )
```

**Decoding.** `tagword = (w8 & 1) ? w8 : w0` — one test and one `cmov` on
words a consumer of the value loads anyway; `(0, 0)` decodes to a tag byte of
`Null` (code 0) with no special case. **Is it counted?** `w8 != 0 && (w8 & 1)
== 0` — one word, one test; there is no separate refcounted flag, the arm is
the flag. **Type tests, by tag.** A test for `false`, `true`, `int` or `float` on a
box whose arm is unknown compares the low 16 bits of the +8 word — bytes +8
and +9 together — against the tag-word constant (`cmp word [box+8], 0x0301`
for `int`), never the type byte alone: bit 0 of every tag-word constant is 1
and bit 0 of every pointer is 0, so no pointer's low bytes can match, and the
width excludes a container's bytes above. A test for `null` is `(w8 & ~1)
== 0`: it accepts the barrier's `(0, 0)` and a container's `(0, 0x0001)`
alike, and rejects the undef slot (`0x0003`), every other tag word and every
pointer (all at least 8) — one instruction, and no normalization on a read.
A test for a pointer tag cannot look at +8, where the pointer is; it is the
arm test followed by a 16-bit compare of +0 (`(w0 & 0xFFFF) == 0x0501` for
`string`), because on the immediate arm +0 is the value and `int 1281` has
those low bytes — or the decode below, which answers every tag at once. A
byte-wide test of +9 is legal once the arm is known — statically, as for a
`?int` slot, or after the arm test. **The undef test** is `w8 & 2`, sound
on both arms because an 8-aligned pointer has bits 0–2 clear; it is one
instruction beside the decode, and a tracked property read makes it before
the value is used. **What the layout says about identity, and no more.** Bit 0 of a tag word
and its bytes above the tag byte — a container's link among them — are never
part of the value, and, once a `reference` has been followed to its referent,
two boxes whose tag bytes differ are never identical.
What identity means within a tag — integer equality, IEEE equality for
`float` (`NaN === NaN` is false, `-0.0 === 0.0` is true, so it is a
floating-point compare and not a word compare), object identity, string and
array content, a reference's referent — is the language's rule and lives in
the document that owns its operators, which is owed (`dev/PLAN.md`, S8.11).

**Why this shape.** A collector on another thread reads the +8 word alone,
with one relaxed 8-byte load, and decides from it whether to follow: bit 0
set — an immediate value, skip; zero — null, skip; otherwise a pointer, whose kind it
reads from the entity's `RcHeader`. It never interprets +0. A mutator's store
of a box is two 8-byte stores in either order, and a reader of one word sees
a value some store wrote, never a pair whose halves disagree — which is what
a 16-byte box with the tag in one word and the payload in the other cannot
promise (`dev/ALGORITHM-AUDIT.md`, A1, resolved 2026-09-14;
`dev/DECISIONS.md`, "A1 closes on a discriminating word"; the shipped
precedent is Go's interface value, `dev/CONCURRENT-SLOT-READS-SURVEY.md`).
The immediate value keeps +0 unboxed and every bit of a 64-bit `int` or `float`,
which is why the discriminator is a word of its own rather than a bit of the
payload.

**What a container's second word is not.** The hash entry's key word
([arrays-hashtable.md](arrays-hashtable.md)) has a convention of its own — a
sentinel below 8, otherwise the low three bits are the kind and the pointer is
the word with them masked — and is not a ValueBox word. It is read by a
trace all the same, so it is written under the same one-store rule as a
box's words ([lowering.md](lowering.md), "Property Access").

The `undef` flag (bit 1 of the tag word's flags byte) marks a ValueBox
property slot as uninitialized. A ValueBox has the room in its own tag word
to carry this, so a `mixed` / untyped property tracks its uninitialized state
**in the slot**, and the init bitmap below is left to the raw typed slots that
have no such room. The undef slot is `(0, 0x0003)`: a Null tag word with the
undef bit, stamped by one 8-byte store after the body's zero-fill.
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
| `resource` | open: the pointer arm if a resource becomes an entity beginning with `RcHeader` ([layouts.md](layouts.md), the open question), otherwise the immediate arm — an opaque handle at +0, invisible to the collector and uncounted on copy |
| `reference` | pointer → ReferenceBox (below) |

`string`, `array`, `object` and `reference` are the pointer arm; `null`,
`false`, `true`, `int` and `float` the immediate arm; `resource` goes with
whichever the open question above gives it. Retain/release on a ValueBox copy
is therefore one test of the +8 word with no tag decoding — the arm is the
counted flag. The pointer arm is reserved for
pointers to entities beginning with `RcHeader` and nothing else: a raw C
pointer never enters a ValueBox (`FFIBox`, [memory/ffi.md](memory/ffi.md),
wraps it), and that reservation is what lets a collector follow the +8 word
without a tag.

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

**There is no store lock.** A 16-byte ValueBox is published as two 8-byte
stores, and an earlier layout carried a `writing` bit that a background marker
tested so as not to read a torn pair; it went with the `rc-satb` strategy on
2026-08-26. The discriminating word makes the tear harmless without a lock:
the one word a concurrent reader interprets is written by one store. The
stores themselves are word-sized relaxed atomic stores wherever a trace may
read the slot ([lowering.md](lowering.md), "Property Access").

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
; $x = $x + 5   where $x: ?int  — payload +0, tag byte +9 (ValueBox layout);
; a ?int box is always on the immediate arm, so the byte test is legal here
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
  itself (above). A read loads the +8 word anyway, and the test is `w8 & 2`
  on it — one instruction beside the decode ("ValueBox Layout").
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
variant is a kind of its own, *typed slot reference*, taken from the
ring-closing reserve ([classes.md](classes.md), "Flags layout": four of the
low eight codes stand free, and the mutator's flag half is full) — so that the
one header load a trace makes already tells the two variants apart, and the
candidate gate's `kind < 8` admits it, as it must for a kind whose `owner`
edge can close a ring. The code that names the kind is `EntityKind`'s,
never this document's. **A trace
reads a typed slot reference's `owner` and nothing else of it.** `owner` is
retained, so it is a counted edge and a ring can close through it; a trace
that skipped it would read the owner as externally referenced and never
collect such a ring. `slot` is never read by a trace: it is an interior
pointer into an object body — to an 8-byte slot, or to a byte or a bit for a
`bool` ([classes.md](classes.md), "`bool`: a byte or a bit") — which,
whenever even and non-zero, the `+8` rule of "ValueBox Layout" would take
for an entity address, and a collector that followed it would read a header
out of the middle of an object. Putting a tag word at +16 with `slot` at +24 was refused: it would
make the generic box read skip the whole box, hiding the `owner` edge, and
dress a field as a ValueBox it is not (`dev/DECISIONS.md`, "A1 closes on a
discriminating word", the Sage's second round). The variant is published
like the ordinary ReferenceBox — the fence of [gc/rc-cycle.md](gc/rc-cycle.md),
"Concurrency" — and its `owner` word falls under the one-store-per-word rule.
`&` is rare in real code, and the entire cost is confined to the box; code
that does not use references pays nothing.

---

## ReferenceBox (`&`)

A reference is a separate refcounted box containing one Value slot.
Variables bound by `&` point to the same box. This is the only extra
indirection in the model, and only code that actually uses `&` pays it
(same design as `zend_reference`).

```
RcHeader | Value
```

**A box is allocated in the GC heap, whatever the holder's category.**
Every rule about a box asks how many holders it has, and the heap is the
one place a count means that: an arena entity is not counted at all
unless it is COW, and counting a box in the arena would break "counted
or escaping, never both" and put a kind test on the retain and release
of every arena entity. The price is that `&` is a heap allocation, which
is `zend_reference`'s own cost class, and that boxing an element of an
arena array copies an arena COW value to the heap once per boxing.

**Duplicating a container collapses a box with a single holder.** The
holder count decides it, and duplication is the only event that asks: a
copy of an array unwraps an element whose box nobody else holds and
takes the value behind it, and shares the box otherwise. Nothing else
collapses a reference — not `unset` of the binding, not a write through
the box, not a write to a neighbouring element — and a copy made because
a value crosses out of the request arena into a longer-lived holder is
not a duplication either: the program stores there, so the box travels
with the element and both containers go on naming it.

**In the request arena the holder count is an upper bound.** A container
there is reclaimed by the reset rather than by its own death, and the
release it owes a heap entity belongs to the reset log, so a box keeps
every hold an arena container ever took on it until the request ends. A
duplication therefore errs toward sharing, which is the safe direction:
every live holder carries a counted `+1`, so a count of one still proves
sole ownership, and only a collapse that PHP would have made can be
delayed. What that costs a program is written down in the runtime's
`dev/DECISIONS.md`, 2026-08-08, with the sequence that exhibits it.

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
