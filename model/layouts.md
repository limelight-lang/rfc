# Value and Entity Layouts: the Visual Map

## Scope

Every byte layout of the value model in one place, under unambiguous
names. This document is a **derived map**: each layout is normative in
the linked document, and a change there must be mirrored here. The one
thing this document introduces itself is the naming convention below.

---

## Terminology

The word "Box" alone is banned — it has meant two unrelated things
(the 16-byte tagged value of [values.md](values.md) and the FFI
wrapper class of [ffi.md](memory/ffi.md)), and the collision caused
real confusion. Every structure carries a full name:

| Name here | What it is | Called elsewhere |
|---|---|---|
| **ValueBox** | the 16-byte tagged *value*, no header, inline in a slot | "Box", `Value` ([values.md](values.md), `ll-model/src/value.rs`) |
| **FFIBox** | entity kind 4 — wrapper attaching a raw C struct to the managed world | the built-in `Box` class ([ffi.md](memory/ffi.md), [classes.md](classes.md)), `EntityKind::Box` |
| **StringBox** | entity kind 1 — the string | string entity ([strings.md](strings.md)) |
| **ArrayBox** | entity kind 2 — the array | array entity ([arrays.md](arrays.md)) |
| **ReferenceBox** | entity kind 3 — the `&` cell | reference box ([values.md](values.md)) |
| Object, WeakRef, Lazy | entity kinds 0, 5, 6 | same everywhere |

Sibling documents keep their local usage until renamed; this table is
the bridge.

---

## ValueBox — 16 bytes, a value, no header

Lives inline in its owner's slot: an untyped property, a local, an
array element, a nullable scalar. It is copied freely and therefore
carries **no refcount of its own** — the count lives in the entity the
payload points to (see the last section). Normative:
[values.md](values.md) "Box Layout".

```
 +0                               +8    +9    +10
┌────────────────────────────────┬─────┬─────┬──────────────────┐
│            payload             │ tag │flags│     reserved     │
│ 8 B  union { i64 · f64 · ptr } │ 1 B │ 1 B │ 6 B, zeros       │
└────────────────────────────────┴─────┴─────┴──────────────────┘

tag:    0 Null · 1 False · 2 True · 3 Int · 4 Float · 5 String
        6 Array · 7 Object · 8 Resource · 9 Reference
flags:  bit 0 REFCOUNTED   payload is a counted entity pointer
        bit 1 UNDEF        property slot not initialized
        bit 2 WRITING      rc-satb store lock (satb.md, "Torn
                           16-byte Box reads"); reserved elsewhere
        bits 3-7           free
```

Sample fillings:

```
int 42          │ 42                │ Int    │ 00000000 │
float 2.5       │ f64 bit pattern   │ Float  │ 00000000 │
true            │ 0 (never read)    │ True   │ 00000000 │
null            │ 0                 │ Null   │ 00000000 │
"hi"            │ ptr → StringBox   │ String │ 00000001 │ RC
object          │ ptr → Object      │ Object │ 00000001 │ RC
undef slot      │ 0                 │ Null   │ 00000010 │ UNDEF
```

All-zeros is **null**, not undef — so a factory stamps UNDEF with one
store after the body zero-fill. Every store writes all 16 bytes,
clearing UNDEF for free — but the publish is **two** stores (payload,
then the tag word), not one atomic 16-byte write; a concurrent marker
could catch a torn pair, which is what the WRITING lock exists for
([satb.md](gc/satb.md)).

---

## The second contract: unboxed — declared types

A declared type occupies its machine representation; the ValueBox is
not involved. Both contracts are chosen per slot at compile time.
Normative: [values.md](values.md) "Unboxed Representation" and
"Uninitialized properties".

| Declaration | Slot | "not initialized" is |
|---|---|---|
| `int` / `float` | 8 B raw, native arithmetic | an init-bitmap bit |
| `bool` | 1 byte | an init-bitmap bit |
| `Foo` / `string` / `array` | 8 B bare pointer | `NULL` itself — a legal null cannot occur |
| `?Foo` / `?string` / `?array` | the same 8 B pointer; null **is** the null pointer (niche, as `Option<&T>`) | an init-bitmap bit |
| `?int` / `?float` | ValueBox, 16 B — no third representation | the UNDEF bit |
| `mixed` / no type | ValueBox, 16 B | the UNDEF bit |

Only properties declared **without an initializer** are tracked; a
property with a default pays nothing. The init bitmap lives in the
object's byte block ([classes.md](classes.md) "The byte block");
zero-fill makes every tracked slot "uninitialized" for free except the
ValueBox slot, which takes the one UNDEF store. The priced trade-off:
a `?int` property costs 16 bytes where a packed discriminant would
cost 9 — the price of not carrying a third representation.

---

## RcHeader — 8 bytes, the shared entity header

Offset 0 of every heap entity. Normative: [classes.md](classes.md)
"Flags layout"; code `ll-model/src/refcount.rs`.

```
 +0                    +4
┌─────────────────────┬─────────────────────┐
│    refcount  u32    │      flags  u32     │
└─────────────────────┴─────────────────────┘

flags:  0-1    memory category (heap / arena / long-lived / immortal)
        2-3    GC state (CAS handoff; bit 2 doubles as arena-reset mark)
        4-5    cycle-collector color
        6      buffered (in the candidate buffer)
        7      HAS_WEAK_REFERENCES
        8-9    destructor pending / ran
        10     COW
        11     IS_ESCAPEE
        12-14  entity kind — what a bare pointer points at
        15-31  strategy-owned: rc-trace — candidate index (15-31);
               rc-walk — epoch byte (16-23) + condemned byte (24-31),
               bit 15 unused
```

Load-bearing invariants:

- **Publication is one 8-byte store, last.** While an entity is being
  built its slot reads refcount 0 ("not constructed"); the header
  store publishes it.
- Under `rc-walk` all header accesses are relaxed atomics. Recorded
  trap: a narrow store followed by a wide load kills store-forwarding
  (~3× measured, `ll-model/dev/BENCHMARKS.md`) — narrow stores demand
  narrow loads.
- **COW** (bit 10): the write barrier is
  `flags & COW && refcount > 1 → separate()`; a COW entity's refcount
  is maintained in **every** memory category — it answers "is this
  buffer shared?", not merely "when to free"
  ([values.md](values.md) "Copy-on-Write Protocol").

---

## Entities — every one starts with RcHeader

### Object — kind 0

```
┌──────────┬─────────┬───────────────┬───────────────────┬─────────┐
│ RcHeader │  class  │ pointer runs  │  ValueBox runs    │  rest   │
│   8 B    │ ptr 8 B │ 8 B each      │  16 B each        │ + byte  │
│          │         │ stride 8,     │  stride 16, skip  │  block  │
│          │         │ skip NULL     │  non-refcounted   │         │
└──────────┴─────────┴───────────────┴───────────────────┴─────────┘
```

The linker groups slots: counted pointers first, then ValueBoxes,
then everything else; the byte block (init bitmap, packed bools)
fills holes. Physical order therefore differs from declaration order
(kept as `declaration_index`). The GC traces by the two run lists,
never by property. Only Object and Lazy carry a class pointer at +8.
Normative: [classes.md](classes.md) "Slot kinds", "Slot order".

### StringBox — kind 1

```
COW (default):    │ RcHeader │ hash (lazy) │ len │ bytes… inline │
mutable builder:  │ RcHeader │ Buffer{ data, len, capacity }     │
                                  └──▶ │ bytes… │  reallocated
frozen/immortal:  as COW; a write always separates
```

One PHP type, three physical layouts: a sub-mode bit in the header
selects them (teardown must know whether bytes are inline; string ops
must know where `len` is). The header address stays stable — only the
buffer behind the builder moves. No class pointer: the kind resolves
the singleton `String` descriptor. Normative: [strings.md](strings.md).

### ArrayBox — kind 2

```
│ RcHeader │ storage … │     three storage strategies behind one
                             class; transitions swap the storage
                             under the same entity (stable header)
```

Layout sketch only — the hashtable design is a future document.
Normative: [arrays.md](arrays.md).

### ReferenceBox — kind 3

```
value form:  │ RcHeader │ ValueBox (16 B) │        the & cell
typed-slot:  │ RcHeader │ owner │ slot │ type │    &$obj->typedProp:
                                                  reads box on the fly,
                                                  writes type-check
```

The two variants are distinguished by a flag bit in the box's own
header. Only code using `&` pays for any of this. Normative:
[values.md](values.md) "Reference Box", "References into unboxed
slots".

### FFIBox — kind 4 (design; not built)

```
│ RcHeader │ type descriptor │ ptr ──▶ │ raw C struct, headerless │
             layout + dispose
```

A header at −8 of the C data is forbidden — the library's own fields
live there — so the wrapper is always separate. The wrapped type is a
body field (one singleton kind wraps many FFI types). Normative:
[ffi.md](memory/ffi.md) "Escape: attaching to the managed world".

### WeakRef — kind 5

```
│ RcHeader │ target │     16 B; always GC-heap; target nulled
                          by the referent's death via the
                          per-thread weak table
```

Normative: [weak-references.md](weak-references.md).

### Lazy — kind 6 (Ghost/Proxy; design)

```
│ RcHeader │ target class │ body of that class … │
```

The one non-object kind that keeps the class pointer — the class is
not fixed by the kind. First touch materializes in place and flips
kind 6 → 0. Normative: [classes.md](classes.md) "Lazy objects".

---

## The two discrimination levels

Type is answered at two levels, deliberately redundant:

```
value level — tag, one load,            entity level — kind, bits 12-14,
no dereference                          for bare pointers

mixed $s │ ptr │ String │ RC │ ───┐
                                  ├──▶ │ rc=2 │ flags: kind=1 │ hash │ len │ "hi" │
string $t │ ptr │ (compiler) ─────┘         one StringBox, one count
```

| ValueBox tag | → | entity kind |
|---|---|---|
| String = 5 | → | StringBox = 1 |
| Array = 6 | → | ArrayBox = 2 |
| Object = 7 | → | Object = 0 · FFIBox = 4 · WeakRef = 5 · Lazy = 6 |
| Reference = 9 | → | ReferenceBox = 3 |
| Resource = 8 | → | **no kind — open question** (below) |
| Null/False/True/Int/Float | | no entity; the payload is the value |

The tag serves the mixed world without touching the entity; the kind
serves every holder of a bare pointer (GC walk, teardown dispatch,
barriers). The mapping is not 1:1: tag Object covers four kinds —
WeakRef and Lazy are full PHP objects — and refinement reads the kind.
Reading a *type* by tag touches nothing, but *copying* a refcounted
ValueBox retains — one access to the entity header (a potential cache
miss); the RC bit cheapens the branch, not the access.

Why a ValueBox has no refcount: a count inside a freely-copied value
would be duplicated by the copy — two holders, two counters, both
wrong. A count must live at one stable address every holder shares,
which is exactly the entity. (Zend split the same way: zval carries no
count; `zend_refcounted_h` sits behind the pointer.) A 2026-07-27
review of a proposed generalization confirmed the split: the pointer
world is already unified by RcHeader, and no code path holds "a word
of unknown nature" that a shared discriminator would serve.

**Open question — `resource` has no entity kind.** The tag exists and
carries a pointer payload, but no kind backs it: a bare resource
pointer is not self-describing for teardown, violating the rule that
makes bare heap pointers freeable ([classes.md](classes.md) "Entity
kind and non-object teardown"). The kind field is nearly full (7 of 8
codes taken; consolidation of the Proxy family 4–6 is deferred in
classes.md). To resolve when resources are designed.
