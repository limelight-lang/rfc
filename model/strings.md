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
`hash` at shared offsets. The four-bit entity-kind field has eight assigned
codes and eight available codes, but assigning another code would not remove
those hot-path branches (`ll-model/src/refcount.rs`, `EntityKind`). When strings beyond 4 GiB
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
compiler-emitted constants — a long key is not a literal — so it stays
per-process random even in a build that folds the short path's hashes and
therefore fixes the short seed (below).

**The threshold is a measurement, and there is no number yet.** No
published scalar-to-SIMD crossover exists for either architecture;
xxh3's internal 240-byte boundary is one author's tuning. It is measured
in `ll-model`'s own harness before it is frozen.

**Seeding.** Each function carries one keying value — rapidhash's 64-bit
seed, HighwayHash's 256-bit key — and when the second arrives the two are
read independently rather than derived from a common master: the short
function is the weak one, and material shared with it hands an attacker
the long one along with it. Nothing here keys the `secret[8]` array
rapidhash takes beside its seed; those stay the reference's published
constants, and making them per-deployment would put eight loads inside
the bulk loop for no stated gain.

**Where the seed lives follows folding**, decided 2026-08-04 (below):
without folding it is drawn from the OS once per process, and with
folding it is fixed at build time and travels inside the artifact, where
anyone holding the artifact can read it. That is Java's and PHP's
position rather than Go's, and it is why the choice is a build option
rather than a default.

**Neither position is a defense, and the table owes one.** A per-process
seed raises the cost of hash flooding from reading a constant to mounting
a timing attack, and no further: rapidhash descends from wyhash and
claims no resistance to key recovery from observed collisions. Therefore
**the hash table carries a structural backstop**: a probe-length counter
with an escape hatch, so worst-case behavior is bounded without
depending on a secret. Until that exists, this design has no answer to an
attacker who supplies array keys.

*(2026-08-13: the backstop is specified in [maps.md](maps.md), "What the
flood ladder becomes", as the ladder's third rung — a refusal, raised as
a catchable error, fired when a trigger trips and no rebuild remains for
the offending kind. The same section requires the per-process key this
one reserves above: 32 bytes from the OS in every build, exempt from
folding, which the map classes need before either can exist.)*

**The zero remap belongs to the frozen definition**, not to the caller:
the hash function maps a genuine zero to a fixed non-zero constant, so
the "not computed" sentinel stays unambiguous and the compiler folds the
same value the runtime computes.

### Folding a literal key's hash is a build option, off by default

**Decision (2026-08-04),** replacing the open question this section used
to leave — whether the compiler folds the hash of a literal key at all.
It is not settled either way; it is selected, by one build option that
carries the seed with it. `ll-model` calls it `hash-folding`.

**Folding and the seed are one question, not two.** A compiler that folds
has to know the seed while it compiles, and a seed drawn when the process
starts is not knowable then. So the option selects a pair: folded plus a
build-time seed, or unfolded plus a per-process one. Off is the default,
because the default should be the arm an attacker cannot precompute
against.

**What folding buys is one load per literal-key access.** Not the "few
multiplies" an earlier draft of this section priced: a literal key is an
interned name, and an interned name is hashed once when it is created, so
its hash is already computed once per process and read from the entity.
Folding replaces a load from a permanently hot address with an immediate,
and generated code needs the interned pointer regardless, for the
identity compare. The gain is real and small, and it is unmeasured.

**What it costs is two obligations.** The seed becomes readable by anyone
holding the artifact, which is the whole of the security difference. And
the compiler and the runtime must agree bit for bit — same function, same
vendored version, same constants, same seed, same zero remap — across two
binaries that nothing in the linker compares. A disagreement is silent:
every folded constant is wrong and the symptom is lookups that miss.
Therefore **a folding build carries a stamp**: each side records the
identity of the hash it was built with, and generated code compares them
once at startup and stops on a mismatch. Without folding there is nothing
to stamp, and a program that folded anything mismatches by construction,
which is the correct outcome.

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

**Revised decision**: inline and dynamic strings differ only in where the
bytes are, so they are two **physical representations** rather than two
class descriptors — a string carries no class pointer — presented to the
language behind a shared `StringInterface`. Each takes an entity kind
code of its own, `8` and `9`, and "is a string" stays one mask test
because the pair shares the kind field's top three bits
([classes.md](classes.md), "Flags layout"):

- **Inline string** (the default) — bytes after the header, one
  allocation, fixed size once allocated.
- **Dynamic string** — bytes out of line, with spare capacity, so append
  extends them in place instead of reallocating the whole string. The
  indirection buys exactly that: growth moves the payload, while the
  entity's own address must stay fixed (the GC never moves entities, and
  the holders of a string are not enumerable). No PHP-level API is
  defined yet; the runtime representation supports it natively.

**The kind code is stamped at creation and does not change during the
string's life.** No operation restamps it, so every path that needs to
know where the bytes are reads a field that cannot have moved since
allocation.

**The layout is not `COW`, and that separation is load-bearing**
(2026-08-10, [memory/large-entities.md](memory/large-entities.md)). `COW`
said both things until a string had to be out of line *by size*: past
what a memory category's allocator packs in one slot the inline layout
cannot be allocated at all, and such a string is copy-on-write like any
other. One bit cannot express that combination. `COW` means
copy-on-write and nothing else: it also decides whether an arena entity
is counted and whether it is copied or held when it escapes, and a
string built out of line by size keeps all three behaviors.

**Code `9` means bytes outside the body, whatever the reason** — a
compiler proof of single ownership or a size past the slot limit — and
not "growable". The distinction matters because the second kind of
out-of-line string keeps `COW`, so an append may not write into it in
place.

The layout took a header bit of its own until 2026-08-26, when the flags
word was re-laid and the kind field widened to four bits: a code says the
same thing in a field every teardown and trace path already loads, and it
says it without a second bit ([DECISIONS](../dev/DECISIONS.md), "the
ring-closing reserve is widened to codes 0–7").

Should a future operation ever need to change the representation, it
changes the layout with it, and it is a copy, not a restamp — the same
argument that retired freeze below. No such operation exists.

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

The by-size form obeys the same two exclusions, and only the reasons
change hands. A long-lived string past its limit is refused because
nothing reclaims its payload, which is the reclamation policy's question
rather than this one's. An immortal string past its limit keeps the
inline layout whole, in the block-aligned run the immortal allocator
already serves for a request over one block payload; it is never freed
and never walked, so nothing about it needs the payload machinery.

**Which layout a string gets is decided at its allocation, by two
inputs.** The compiler allocates a string dynamic when it can see the
string being appended to — a concatenation loop, an accumulator — and
inline otherwise; a wrong guess there costs copies during growth, never
memory corruption. The factory then overrides inline with out-of-line
whenever the content exceeds what the category's allocator packs in one
slot, because there the inline layout has no home. The first input also
clears `COW`, the second never does. There is no runtime promotion from
one layout to the other: that would rewrite the body under a header the
collector may be reading concurrently, which is the same objection that
retired freeze below.

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

The free routine reads the layout flag to pick teardown: an inline string
frees only its own block, an out-of-line one frees its payload as well.

**A non-COW string never copies on write.** The barrier rule in
[values.md](values.md) fires on `COW && refcount > 1`, and the form the
compiler allocates for a proved single owner carries `COW = 0`, so it is
outside that rule by construction. A write goes in place, always, and no
sharing test is performed. A string that is out of line only because of
its size carries `COW = 1` and takes the ordinary rule, separating into
a fresh out-of-line entity when a second holder writes.

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

- A consumer that just wants a string gets the flattened result. **Where
  that flattening happens is decided at the interpolation site by the
  compiler** — rules below.
- A structure-aware consumer receives the template object itself and
  processes parts and values independently. The canonical case is a SQL
  driver that parameterizes the values instead of splicing them, and it
  gets that **only where it asked for it** — see rule 2. Same for HTML
  escaping.
- Precedents: C# `FormattableString`, JS tagged templates.

### Rule 1: a template used once and never stored is never built

**Decision (2026-08-05).** When the compiler can see that the
interpolation's result is consumed as a plain string and does not outlive
the expression, **no template object exists at run time**. The site
compiles to string assembly and nothing else. `$x = "$y + 1"` really is
`$x = $y . ' + 1'`.

**Assembly is one pass, not a chain of concatenations.** Sum the lengths
of every piece, allocate the result once, copy each piece into place. A
chain of binary `.` produces an intermediate string per join; the single
pass produces none. The two coincide at exactly two pieces, which is why
Zend keeps `FAST_CONCAT` for that case and its rope for the rest —
`ZEND_ROPE_INIT` / `ROPE_ADD` fill a flat array of string pointers in
compiler-allocated frame slots, and `ZEND_ROPE_END` sums, allocates once
and memcpys (`Zend/zend_vm_def.h`).

**A value that is not already a string is written straight into the
result** where its length can be known before writing — an integer's
digit count is cheap to compute. Zend does not do this: it builds a
temporary string per value and copies that in, paying two copies.
C# avoids the same cost through `ISpanFormattable`, writing into the
destination buffer directly.

**Rejected: guessing the length.** C#'s handler is constructed with the
literal length and the hole count and reserves
`literal_length + holes * 11` characters, growing if it guessed low. That
trade favours a runtime where growth is expensive. Ours is not: a
long-lived payload that is still the last chunk bumped grows by moving
the bump, with no copy (`memory/buffers.md`). Exact measurement costs one
pass over pieces already in cache and removes the guess entirely.

**Rejected: a stored template that flattens lazily, for this case.** It
is the shape LLVM's `Twine` has, and `Twine`'s own documentation forbids
storing one — it holds pointers to temporaries. A template that never
escapes the expression has nothing to gain from being an object and costs
an allocation, a header and a later free.

### Rule 2: the template object is built only where the destination asked for it

**Decision (2026-08-05).** Materialization is the default everywhere. A
template object exists only when the **declared type of the destination**
is the template interface — a parameter, a property, or a typed local:

```php
function query(InterpolateStringInterface $sql) { ... }

$db->query("SELECT * FROM users WHERE id = $id");   // template
$x = "$y 234";                                       // string, always
```

The decision is made at the site from the signature. **No forward flow
analysis is required**, and none is performed: the compiler does not ask
where a value will end up, only what the thing receiving it declares. An
explicit accessor on the interpolation is the same mechanism written by
hand, for the case where no declared type is in reach.

**Why the destination and not the source.** The alternative is to keep
the template whenever the compiler cannot prove nobody wants its
structure, and materialize otherwise. That defaults to allocating in
every untyped site, which in this language is most of them, and it makes
the cost of an interpolation depend on an analysis the reader cannot see.
Deciding from the declared type is one lookup, it is visible in the
source, and the author of an API opts in once for all of its callers —
the arrangement C# uses, where the parameter type selects the
interpolated-string handler.

**The consequence, stated rather than buried.** The protection follows
the declared type, so it is lost when a value reaches the call through an
untyped variable:

```php
$q = "SELECT * FROM users WHERE id = $id";   // no declared type: materialized here
$db->query($q);                              // receives a string; nothing to parameterize
```

Writing `InterpolateStringInterface $q = "..."` keeps it. So SQL
injection is impossible **by construction wherever the API declares the
interface and the call reaches it directly** — not unconditionally, and
the earlier wording in this section said otherwise.

### Rule 3: the shape of the template object, and how it flattens

**Decision (2026-08-05).**

**Parts and values alternate, and empty parts are allowed.** A template is
part, value, part, … part, so there is always exactly one more part than
there are values. `"$a$b"` is three parts, the first and last empty. This
is what removes the offset map: with the order fixed, there is nothing
left to encode. JS tagged templates fix the same invariant
(`strings.length === values.length + 1`) for the same reason.

**The parts live in the site's static data, the values in the instance.**
The parts are compile-time constants shared by every pass through that
site — interned immortal strings, so no refcounting and nothing for the
collector to trace — and the compiler emits them once per site as a
**shape**: a count and a pointer to that many parts, never allocated and
never freed. The instance is `RcHeader | class | shape | Value[n]`: an
ordinary entity, no new entity kind, no arrays.

**One class serves every site** (Edmond, 2026-08-05, amending this rule's
first draft, which gave each site a generated class). The site's identity
is its shape, and a class per site would generate a class per string
literal for no gain — the consumer's declared type is the same interface
either way. What it costs is that the number of values is a property of
the instance rather than of the class, so the body's length comes from
the shape, and the three walks that read an object's children take one
branch on the class flag instead of reading the class's box runs. That
branch is the whole price, and it is paid in one place.

**No cached flattened result.** An earlier draft gave the object a slot
for one. Rule 2 removed the reason: an object now exists only where the
destination declared the interface, so its consumer is structure-aware by
construction and flattens rarely, if at all. Eight bytes on every
instance to serve a path most instances never take is the wrong trade —
whoever flattens keeps the result.

**One shared flattening routine, not a generated method per site.** The
unroll-or-loop question dissolves once rules 1 and 2 separate the cases:
the common path builds no object and is straight-line generated code,
where unrolling is a codegen decision; the object path is the rare one,
and emitting a function per site for it spends binary size on what is
seldom called. The shared routine walks the site's shape. No
threshold to measure.

**Flattening is two passes**, as in Zend's `ZEND_ROPE_END`: sum the
lengths, allocate the result once, copy each piece into place. Two
refinements on it:

- A value that is not already a string is written **into the result
  directly** where its length can be known first — an integer's digit
  count is cheap. Zend builds a temporary string per value and copies
  that in, paying two copies; C# avoids the same cost through
  `ISpanFormattable`.
- **All user code runs before the allocation.** `__toString` is user
  code and may do anything, so the first pass performs every such call
  and holds the strings it produced; only then is the result allocated.
  The values have been read into locals by that point, so user code
  cannot change what is being assembled. What it can still do is flatten
  the same template again, producing a second result — harmless unless
  `__toString` is impure, and Zend is exposed to exactly the same thing.

**The instance is an ordinary object**, so the ordinary memory-category
rules apply. Its typical shape — built at a call site and consumed by the
callee — puts it in the request arena.

**Planned extension (later)**: a public API on the template object, plus
compile-time machinery: an additional *type* and a *handler* attached at
the call site (tagged-template style), so libraries can define their own
template consumers. Deliberately out of scope for the first
implementation; the decision now is only that the interpolated string is
its own class with its structure preserved.
