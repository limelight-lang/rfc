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

**Decision**: `string` is a real class — with methods, attachable
interfaces (see Extension Interfaces in [classes.md](classes.md)), and
metadata. But it costs nothing at the instance level:

- **No per-instance class pointer.** The Box type tag (or the statically
  known type) already identifies the value as a string, and the String
  class is a final singleton — the class is known without reading the
  object.
- **Every method call devirtualizes.** `$s->upper()` compiles to a direct
  call: the receiver type is final, so the vtable is bypassed entirely.
- The layout above stays exactly as it is — a string is not a general
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

## Mutability Modes

Because COW is a per-object flag ([values.md](values.md)), strings come in
two modes:

- **COW string (default)** — PHP value semantics: assignment shares the
  buffer, a write with `refcount > 1` separates.
- **Non-COW string** — a freely mutable buffer (builder). In-place append
  and modification with no separation, ever. This is the answer to the
  classic "concatenation in a loop" pattern — no PHP-level API is defined
  yet, but the runtime representation supports it natively.

Both modes share the layout; they differ in one header bit.

---

## Interpolated String Class

**Decision**: `"... $x ..."` produces a **distinct class** — a structured
template object holding the literal parts and the embedded values
separately, not an eagerly flattened string.

```
parts:  ["SELECT * FROM users WHERE id = ", " AND status = "]
values: [$id, $status]
```

- A consumer that just wants a string gets the flattened result (exact
  flattening point TBD — likely on first use as a plain string).
- A structure-aware consumer receives the template object itself and
  processes parts and values independently. The canonical case is a SQL
  driver that parameterizes the values instead of splicing them — SQL
  injection becomes impossible by construction. Same for HTML escaping.
- Precedents: C# `FormattableString`, JS tagged templates.

**Planned extension (later)**: a public API on the template object, plus
compile-time machinery — an additional *type* and a *handler* attached at
the call site (tagged-template style), so libraries can define their own
template consumers. Deliberately out of scope for the first
implementation; the decision now is only that the interpolated string is
its own class with its structure preserved.
