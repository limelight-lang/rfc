# Strings

## Scope

The StringBox: memory layout, class semantics, mutability modes, and
the interpolated-string template class. Plugs into the ValueBox/unboxed and COW
contracts defined in [values.md](values.md).

---

## Layout

```
inline:   RcHeader | len (u64) | hash (u64, lazy) | bytes... (inline)
dynamic:  RcHeader | len (u64) | hash (u64, lazy) | data | capacity
                                                     └──▶ bytes...
```

One allocation per inline string: the bytes follow the header (as in
`zend_string`), so string access is one pointer dereference with no
second hop. A dynamic string holds its bytes out of line so they can be
reallocated as it grows, which costs one further dereference to reach
them.

**`len` and `hash` sit at the same offsets in both layouts**, +8 and
+16, so length and hash are read without deciding which layout this is.
Only the code that needs the bytes themselves branches. The dynamic
layout is a `Buffer` ([memory/buffers.md](memory/buffers.md)) with the
fields ordered to meet that constraint, not the `Buffer` struct embedded
verbatim.

The hash is computed on first use and cached. **Zero means "not
computed"**: an append clears it, and the hash function maps a genuine
zero to one so the sentinel stays unambiguous.

---

## String Is a Class

**Decision**: `string` is a real class, with methods, attachable
interfaces (see Extension Interfaces in [classes.md](classes.md)), and
metadata. But it costs nothing at the instance level:

- **No per-instance class pointer.** The ValueBox type tag (or the statically
  known type) already identifies the value as a string, and the String
  class is a final singleton; the class is known without reading the
  object.
- **Every method call devirtualizes.** `$s->upper()` compiles to a direct
  call: the receiver type is final, so the vtable is bypassed entirely.
- The layout above stays exactly as it is: a string is not a general
  object in memory, it only *behaves* as one in the language.

The same construction applies to `array` ([arrays.md](arrays.md)).

---

## Interned Strings

All compile-time-known strings (names, literals) are interned into the
long-lived arena as immortal entities: one string = one address, equality
= pointer compare, hash precomputed. See Interned Names in
[classes.md](classes.md). Writes to an immortal string always separate
(COW protocol, [values.md](values.md)).

---

## Two Layouts Behind `StringInterface`

**Revised decision**: inline and dynamic strings share the `string`
entity kind and differ only in where the bytes are, so they are two
**physical representations** selected by the **COW flag** already in the
header (not two class descriptors — a string carries no class pointer),
presented to the language behind a shared `StringInterface`:

- **Inline string, `COW = 1`** (the default) — bytes after the header,
  one allocation, fixed size once allocated.
- **Dynamic string, `COW = 0`** — bytes out of line, with spare capacity,
  so append extends them in place instead of reallocating the whole
  string. The indirection buys exactly that: growth moves the payload,
  while the entity's own address must stay fixed (the GC never moves
  entities, and the holders of a string are not enumerable). No PHP-level
  API is defined yet; the runtime representation supports it natively.

**The COW flag is set at creation and does not change during the
string's life.** No operation flips it: a string created without COW
stays without it. This is what makes the flag readable as the layout —
every path that needs to know where the bytes are reads a bit that
cannot have moved since allocation. It also means no sub-mode bit is
needed anywhere else in the header, which matters because the flags word
has no free bit left (`ll-model/src/refcount.rs`, the layout test).

Should a future operation ever need to change the flag, it changes the
layout with it, and it is a copy, not a bit flip — the same argument
that retired freeze below. No such operation exists.

**Both layouts occur in every memory category.** The request arena and
the GC heap differ in who releases the memory, not in how a string is
shaped: an arena string is reclaimed by the reset, a heap string by its
own refcount reaching zero.

**Which layout a string gets is a compile-time decision.** The compiler
allocates a string dynamic when it can see the string being appended to
— a concatenation loop, an accumulator — and inline otherwise. There is
no runtime promotion from one layout to the other: that would rewrite
the body under a header the collector may be reading concurrently, which
is the same objection that retired freeze below. A wrong guess costs
copies during growth, never memory corruption.

Both are managed entities: RC/COW-flagged, created in the language always
carrying RC. The exception is the FFI boundary, where a foreign buffer
may be viewed as a string without copying; see
[zero-abstraction.md](memory/zero-abstraction.md).

### Writes obey the COW rule; there is no freeze operation

**Decision (2026-08-03)**: a dynamic string is never frozen. A write to
an **inline** string runs the barrier rule in [values.md](values.md):
immortal and long-lived separate always, `IS_ESCAPEE` separates always,
`refcount > 1` separates, and only a sole owner writes in place. A
**dynamic** string is outside that rule entirely (above): its write
always goes in place and extends the buffer.

Freeze was specified as a mode-bit flip, and a bit cannot perform one:
the two layouts hold their bytes in different places, so moving between
them is a copy. **Rejected**: a third, frozen sub-mode that closes a
dynamic string for writing in place. It keeps the address and skips the
copy, but the string then carries the extra dereference and its unused
spare capacity for the rest of its life.

The two sub-modes are not class descriptors: a string carries **no class
pointer** (a non-object entity, kind = `string` in the header flags,
[classes.md](classes.md)). The Ghost-object `!invariant.load` machinery
therefore does not apply here — it guards a class-pointer load that a
string never performs, since string methods are direct devirtualized
calls to the final `String`.

The free routine reads the same flag to pick teardown: an inline string
frees only its own block, a dynamic string frees its out-of-line payload
as well.

**A dynamic string never copies on write.** The barrier rule in
[values.md](values.md) fires on `COW && refcount > 1`, and a dynamic
string carries `COW = 0`, so it is outside that rule by construction —
it is the non-COW, freely mutable form that flag has always denoted. A
write goes in place, always, and no sharing test is performed.

That is safe because the compiler only allocates a string dynamic where
it has proved a single owner — an accumulator, a local builder, a value
that never reaches a second holder. Where the proof fails it allocates
inline COW instead, and the ordinary rule applies. The obligation is the
same one already stated for tiers 1-2 in
[memory/static-lifetimes.md](memory/static-lifetimes.md): a COW carve-out
holds only where no sharing is observable. Here it is not a carve-out
from counting but the allocation choice itself.

### An arena string that survives the reset takes its payload with it

A dynamic string in the request arena keeps its header in one arena
block and its bytes in another, since the payload is reallocated as it
grows. Promotion retains the block the **header** lies in
(`ll-model/src/promote.rs`) and reads nothing inside the entity, so the
payload's block would be returned to the pool while the promoted string
still points into it.

**Decision**: promotion is layout-aware. A surviving dynamic string
keeps its header where it is — the address must not change, because the
holders are unknown — and its payload is reallocated in the heap and
copied, with `data` rewritten. Nothing else in the arena is retained on
its behalf. A payload larger than a block is OS-direct rather than in a
block ([memory/buffers.md](memory/buffers.md)), so it is not copied at
all: its record moves out of the arena's large-allocation list and its
ownership passes to the heap entity.

Only surviving strings pay this, and they are the minority by
construction: the rest die with the reset at no cost. The same
obligation falls on arrays, whose storage is likewise out of line
([arrays.md](arrays.md)).

---

## Interpolated String Class

**Decision**: `"... $x ..."` produces a **distinct class**: a structured
template object holding the literal parts and the embedded values
separately, not an eagerly flattened string.

```
parts:  ["SELECT * FROM users WHERE id = ", " AND status = "]
values: [$id, $status]
```

- A consumer that just wants a string gets the flattened result (exact
  flattening point TBD, likely on first use as a plain string).
- A structure-aware consumer receives the template object itself and
  processes parts and values independently. The canonical case is a SQL
  driver that parameterizes the values instead of splicing them; SQL
  injection becomes impossible by construction. Same for HTML escaping.
- Precedents: C# `FormattableString`, JS tagged templates.

**Planned extension (later)**: a public API on the template object, plus
compile-time machinery: an additional *type* and a *handler* attached at
the call site (tagged-template style), so libraries can define their own
template consumers. Deliberately out of scope for the first
implementation; the decision now is only that the interpolated string is
its own class with its structure preserved.
