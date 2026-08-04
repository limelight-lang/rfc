# Strings

## Scope

The StringBox: memory layout, class semantics, mutability modes, and
the interpolated-string template class. Plugs into the ValueBox/unboxed and COW
contracts defined in [values.md](values.md).

---

## Layout

```
          +0         +8          +12              +16           +24
inline:   RcHeader | len (u32) | (spare)        | hash (u64) | bytes... (inline)
dynamic:  RcHeader | len (u32) | capacity (u32) | hash (u64) | data
                                                                └──▶ bytes...
```

One allocation per inline string: the bytes follow the header (as in
`zend_string`), so string access is one pointer dereference with no
second hop. A dynamic string holds its bytes out of line so they can be
reallocated as it grows, which costs one further dereference to reach
them. Header sizes: 24 bytes inline, 32 dynamic.

**`len` and `hash` sit at the same offsets in both layouts**, +8 and
+16, so length and hash are read without deciding which layout this is.
Only the code that needs the bytes themselves branches. The dynamic
layout is a `Buffer` ([memory/buffers.md](memory/buffers.md)) with the
fields ordered to meet that constraint, not the `Buffer` struct embedded
verbatim.

**`len` is 32-bit so that `capacity` rides for free** (decided
2026-08-04). An 8-byte `hash` has to start at a multiple of 8, so a
32-bit length leaves four bytes of padding at +12 whatever we do with
them; the dynamic layout spends them on its capacity. That takes the
dynamic header from 40 bytes to 32 and costs the inline layout nothing —
it keeps the padding empty and stays at 24. Narrowing `hash` as well
would buy a further 8 bytes and drop short strings a size class (the
heap steps by 16, so a 9-byte string moves from the 48-byte class to the
32-byte one), but a 32-bit hash has to serve both the bucket index and
the Swiss-table control byte, and full-hash collisions would start
around 65k distinct keys. Not taken; revisit when Phase D says which
string lengths actually dominate.

The hash is computed on first use and cached. **Zero means "not
computed"**: an append clears it, and the hash function maps a genuine
zero to one so the sentinel stays unambiguous.

### A string holds at most 4 GiB

**Decision (2026-08-04)**: `len` and `capacity` are 32-bit, so a string
is capped at `2^32 - 1` bytes. This is a limit of the language, not an
implementation detail, and it belongs in the language reference.

The cap is more generous than three of the runtimes we are measured
against: Java and C# have capped strings at `2^31 - 1` since their first
release, and V8 caps far lower still. It is stricter than PHP, whose
`zend_string` carries a `size_t` length — a program that reads a 5 GiB
file into one string works there and fails here. That case is real in
batch and CLI work and absent from the web workloads the language is
aimed at; PHP's own default `memory_limit` of 128 MB puts it out of
reach of most deployments anyway.

**Every path that grows a string checks the result against the cap and
raises, through one shared choke point.** Concatenation, append, repeat,
and whole-file reads all route through it. A silent truncation to 32
bits would produce a write past the end of the buffer, which is the
worst defect class available here, and one choke point is also the
single place a future wider string would hook into.

**Strings above the cap do not get a transparent representation.** A
third physical form would put a branch in every string operation —
comparison, concatenation, hashing, table lookup, promotion, teardown —
which is exactly what the two-layout design avoids by keeping `len` and
`hash` at shared offsets. It would also spend the last free entity kind:
the kind field is three bits and seven of eight codes are taken
(`ll-model/src/refcount.rs`, `EntityKind`). When strings beyond 4 GiB
are genuinely needed, they arrive as a **separate class the programmer
chooses** — a stream or a rope — not as a `string` that silently behaves
differently.

### The hash function is a build-time choice, defaulting to rapidhash v3

**Decision (2026-08-04).** The string hash is **selected when the
runtime is built**, exactly as the GC strategy already is — that is a
cargo feature in `ll-model` with two implementations claiming the same
header bits, and the hash is the second axis of the same kind. Nothing
selects a hash at run time, so no call goes through a pointer on the
path that matters, and a deployment whose threat model differs from the
default's changes a build flag rather than the language.

This is available to us because we compile the program ourselves:
runtime bitcode and compiler-generated IR are merged and re-optimized
together (`../runtime/implementation-language.md`), so a build-time
constant reaches every call site as an inlined body. A library shipping
one binary to unknown machines cannot do this and pays with a function
pointer; we are only in that position in the portable-AOT mode, and only
for the long path below.

**The default: rapidhash v3 for short inputs**, vendored with its
constants pinned, scalar, inlined at every call site. It is the fastest
function that passes SMHasher3 clean, uses no vector or crypto
instructions — so it inlines in every build mode including portable AOT —
and is seedable. **Rejected: xxh3**, whose advantage is bulk throughput
this workload never reaches and whose own tracker records
seed-independent collisions found during development; **rejected:
wyhash**, frozen at final4, superseded by rapidhash from the same author,
and still failing the seed-sensitivity families; **rejected: gxhash and
aHash**, which need AES instructions and therefore either a runtime
dispatch or a build that will not inline into baseline-featured IR.

**A frozen length threshold and a slot for a second function.** The
threshold is part of the hash definition: compiler and runtime compare
`len` against the same constant. The slot's first and only occupant is
the short function, so the split ships as structure with nothing in it,
and a later release can activate the second arm without touching the
compiler/runtime contract — hashes never outlive a build artifact, so
changing the algorithm between releases costs nothing.

**HighwayHash-64 is the named candidate for that slot, and it is a
security upgrade rather than a speed one.** Every published measurement
puts it behind scalar rapidhash on bulk throughput, so a speed-motivated
long path does not exist. A strength-motivated one does: an attacker
picks key length and therefore picks which function processes their
input, so total resistance is the weaker of the two, and the long side
must be at least as strong as the short one or the split is a
self-inflicted downgrade. HighwayHash's 256-bit key is never folded into
compiler-emitted constants, so it can be per-process random even in the
build mode where the short path's seed cannot be.

**The threshold is a measurement, and there is no number yet.** No
published scalar-to-SIMD crossover exists for either architecture;
xxh3's internal 240-byte boundary is one author's tuning. It is measured
in `ll-model`'s own harness before it is frozen.

**Seeding.** Two secrets, both derived from one master seed, never
sharing raw material: the short function is the weak one, and a shared
seed would hand an attacker the long one along with it. The master is
per-process where the compiler runs in-process (JIT) and per-build
otherwise. In the AOT modes the seed is extractable from the artifact by
anyone holding it, which is Java's and PHP's position rather than Go's —
therefore **the hash table carries a structural backstop**: a probe-length
counter with an escape hatch, so worst-case behaviour is bounded without
depending on a secret.

**The zero remap belongs to the frozen definition**, not to the caller:
the hash function maps a genuine zero to a fixed non-zero constant, so
the "not computed" sentinel stays unambiguous and the compiler folds the
same value the runtime computes.

**Still open: whether the compiler folds the hash of a literal key at
all.** Folding removes the work from every literal-key access and
requires compiler and runtime to share a seed inside one artifact; not
folding costs a few multiplies per access and removes the shared secret
entirely. The default until measured is **not folded**, because it is
the option that keeps the security story simple, and because the cost it
pays is the one this design is least short of.

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

**The inline layout occurs in every memory category; the dynamic one
only in the GC heap and the request arena.** The request arena and the
GC heap differ in who releases the memory, not in how a string is
shaped: an arena string is reclaimed by the reset, a heap string by its
own refcount reaching zero. The two categories the dynamic layout is
refused in follow from its being the freely mutable non-COW form. An
immortal dynamic string would be a process-wide shared string written in
place, which is what the COW rule exists to prevent. A long-lived one
would keep its payload forever: `string_die` returns the entity block
only in the GC-heap category, and the arena payload is left to the reset,
so nothing reclaims a long-lived string's out-of-line bytes.
`ll_string_new_dynamic`
returns null for both rather than redirecting the allocation, so a wrong
category is a failure at the creation site instead of an entity in the
wrong block (`ll-model/src/string.rs`).

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

**When the copy is refused** (2026-08-04, added with the
implementation): the payload's block is retained after all, alongside the
survivors' own, and the string reads its old bytes for the rest of its
life. This is the one case where something other than a header's block
stays out of circulation, and it exists because a reset has no caller
left to report a refusal to — it runs at the end of a request, after the
frame that could have raised. Teardown recognizes a payload in a retained
block and leaves it alone; the block goes home when the retained block
itself does. The transfer route cannot reach this case, since it
allocates nothing — which is the second reason it is a transfer and not a
copy.

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
