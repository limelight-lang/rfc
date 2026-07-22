# Strings

## Scope

The string entity: memory layout, class semantics, mutability modes, and
the interpolated-string template class. Plugs into the Box/unboxed and COW
contracts defined in [values.md](values.md).

---

## Layout

```
RcHeader | hash (u64, lazy) | len (u64) | bytes... (inline)
```

One allocation per string: the bytes live inline after the header (as in
`zend_string`), so string access is one pointer dereference with no second
hop. The hash is computed on first use and cached.

---

## String Is a Class

**Decision**: `string` is a real class, with methods, attachable
interfaces (see Extension Interfaces in [classes.md](classes.md)), and
metadata. But it costs nothing at the instance level:

- **No per-instance class pointer.** The Box type tag (or the statically
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

## Mutability Modes: `StringInterface`, Two Classes

**Revised decision**: COW and mutable strings share the `string` entity
kind but have genuinely different memory layouts, so they are two
**physical representations** selected by a sub-mode bit in the string
header (not two class descriptors — a string carries no class pointer),
presented to the language behind a shared `StringInterface`:

- **COW string (default)** — the layout above: bytes inline after the
  header. Fixed size once allocated; a write with `refcount > 1`
  separates (copies). Never grows in place.
- **Mutable string (builder)** — `RcHeader | Buffer{data, len, capacity}`
  ([docs/memory-manager.md](https://github.com/limelight-lang/ll-model/blob/main/docs/memory-manager.md)
  Mutable Buffers): indirection is required because growth means moving
  the payload, and the `RcHeader` entity's own address must stay stable
  (non-moving GC, existing references must not dangle). In-place append
  via the buffer's extend-in-place/grow algorithm, no separation, ever.
  No PHP-level API is defined yet; the runtime representation supports
  it natively.

Both are managed entities: RC/COW-flagged, created in the language always
carrying RC. The exception is the FFI boundary, where a foreign buffer
may be viewed as a string without copying; see
[zero-abstraction.md](memory/zero-abstraction.md).

### Freeze: builder → immutable, a mode-bit flip

A string carries **no class pointer** (it is a non-object entity, kind =
`string` in the header flags, [classes.md](classes.md)). So the two
representations above are not two class descriptors reached through an
instance pointer — they are **one entity kind with a sub-mode bit** in
the string header: COW-inline, mutable-builder, or frozen-immutable. The
`StringInterface` split is a language-level abstraction; physically it is
this mode bit plus the layout it implies.

"Freezing" a builder into an immutable string (mentioned as a future
operation in docs/memory-manager.md) is therefore a **mode-bit flip**,
not a class-pointer swap: there is no class pointer to swap, and the
Ghost-object `!invariant.load` machinery does not apply here (it guards a
class-pointer load that a string never performs — string methods are
direct calls to the final `String`, devirtualized, with no vtable in the
entity). The free routine reads the same mode bit to pick teardown: a
frozen/COW string frees only its inline block, a builder also frees its
out-of-line `Buffer.data`.

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
