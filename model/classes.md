# Class and Object Model

## Scope

Defines the low-level representation of PHP classes and objects: object layout, class descriptors, method dispatch (vtables and interface tables), and property access including PHP 8.4 property hooks.

Value representation for scalars, strings, and arrays is covered separately. Memory categories and GC coordination are defined in [arenas.md](memory/arenas.md) and [heap-design.md](gc/heap-design.md).

---

## Common Refcounted Header

**Decision**: Every heap-managed entity (object, string, array, closure, reference) begins with the same 8-byte header at offset 0. Zero-abstraction `#[FFI]` entities are outside this rule: they carry no header at all ([zero-abstraction.md](memory/zero-abstraction.md)).

```
+0  refcount  u32
+4  flags     u32  (atomic)
```

**Why**: retain/release becomes a single type-agnostic code path: it operates on offset 0 of any counted entity without knowing its type. Zend (`zend_refcounted_h`) and CPython (`ob_refcnt` first) use the same layout for the same reason.

### Flags layout

Re-laid on 2026-08-26, when the two old collectors were deleted and
`rc-cycle` became the only design ([DECISIONS](../dev/DECISIONS.md), "the flags
word is re-laid for one collector"). The order is chosen so that three
predicates are mask tests and the enrolment gate is one.

| Bits | Meaning |
|------|---------|
| 0–1 | Memory category: `00` GC heap, `01` request arena, `10` long-lived, `11` immortal. Position 0 is the category's because more sites read its **value** than the kind's, and a mask test is position-free |
| 2–5 | **Entity kind**, four bits. `0` object, `1` lazy object (Ghost/Proxy, uninitialized until first touch), `2` array, `3` ReferenceBox (a PHP `&` reference: `RcHeader \| Value`), `8` string, `9` string with its bytes outside the body, `10` `FFIBox` (built-in class wrapping a C struct), `11` `WeakRef` (built-in `WeakReference` class). **Codes 0–7 are held for kinds that can close a ring** and 4–7 of them are free, so adding such a kind is a code assignment rather than a renumbering; codes 12–15 are free for kinds that cannot. Selects the free routine at teardown, and for a bare non-object pointer the per-tag descriptor (below) |
| 6 | Copy-on-write: counted in every memory category |
| 7 | Arena reset mark: the transient mark of the reset's escaped-subgraph trace, cleared when a survivor is promoted ([arena-reset.md](memory/arena-reset.md)). It is safe here because a reset never runs against a collection on the same entity — an arena entity is never a candidate |
| 8 | Acyclic gate: this instance's class is proven unable to hold a reference to a ring-closing kind, so it never enters the candidate set ([rc-cycle.md](gc/rc-cycle.md)) |
| 9 | Ownership mark: this entity's owner is proven, so no trace need consider it |
| 10 | Enrolled: a queue entry names this entity. Cleared by the owner at death and at no other point |
| 11 | Live escapee: `refcount` currently holds the escape hold-count |
| 12 | Has weak references (side table exists) |
| 13 | **`DESTRUCTOR_PENDING`** — this instance owes a `__destruct`: set only when the user constructor has returned successfully, **and** only for a class that has a destructor. What every teardown path dispatches on, not just the arena's ([object-lifecycle.md](../runtime/object-lifecycle.md)) |
| 14 | **`DESTRUCTOR_RAN`** — `__destruct` has already run (exactly-once guard) |
| 15 | Free |
| 16–17 | Epoch, the collector's own. **Byte 6 has one writer**: epoch, age and reserve share it, and each is written by a byte-wide read-modify-write, so a second writer would lose the first's bits with no wider access anywhere to blame |
| 18–19 | Candidate age used by the traversal cutoff |
| 20–23 | Collector reserve |
| 24–31 | Free |

**Which code names which kind is still the encoding's own business** —
normative in `EntityKind` (`ll-model/src/refcount.rs`), and a consumer takes
the assignment from the runtime's exported ABI, never by transcription. What
this table fixes is the *shape*: four bits at 2–5, and the low eight codes
held for ring-closing kinds, of which four stand free.

The three predicates the order buys, over the whole flags word:

| Question | Test |
|---|---|
| closes a cycle | `flags & 0b100000 == 0` |
| carries a class at `+8` | `flags & 0b111000 == 0` |
| is a string, either layout | `flags & 0b111000 == 0b100000` |

and the enrolment gate is `flags & 0x723 == 0` over five conditions at once:
category zero, kind below eight, class not acyclic, ownership not proven, not
already enrolled.

**The reserve is four free codes, not a boundary drawn round the kinds that
exist.** An earlier form of this table held codes 0–3 while four ring-closing
kinds filled them exactly, so the fifth would have taken code 8 and the mask
would have refused it permanently with nothing red — the failure
[Y6](gc/cycle/questions.md) names. The bound is enforced in the crate as a
`const` assertion that a kind's classification and its code agree, so a kind
filed on the wrong side of eight fails the build
([DECISIONS](../dev/DECISIONS.md), "the ring-closing reserve is widened to
codes 0–7").

### Entity kind and non-object teardown

**Decision**: the kind field (bits 2–5) is what makes a **bare heap
pointer self-describing** for freeing. An object frees through
`obj->class->dispose`, reachable from its `class` at +8; a string, array
or ReferenceBox has no `class`, so its free routine is selected by the
kind field instead — one `flags` load (already loaded at free time for
the category dispatch) and a small switch: object → `dispose`, string →
free-string, array → free-array (release element ValueBoxes, then the
storage), reference → free the box.

This is why an entity's kind lives on the **entity**, not on each list
slot that references it: the release-at-reset list, the cycle-candidate
buffer and every teardown path hold bare pointers, and would otherwise
each need an extra word per entry to say what they point at. The kind
bit costs four bits once per entity, in a word that is read at free time
anyway; a per-entry tag would cost 8 bytes per *reference*, of which
there are far more than entities. The candidate set never needs the switch
at all: it admits exactly the kinds that hold counted slots a cycle can close
through — Object, Lazy, Array, ReferenceBox — which is why those four hold
codes 0–3 and the question is a mask test.

Whether `+8` holds a class pointer is itself a function of the kind —
object and lazy carry one, every other kind does not — so no
separate flag records it. The old "is there a class at +8" flag bit was
removed: the one path that asks (an unknown-type free or dispatch) is
already switching on the kind, which subsumes the test.

The same field answers "what type is this non-object" for a `mixed` →
interface conversion on a `string`/`array`: the ValueBox tag is gone once you
hold a bare pointer, so the kind selects the type's **singleton
descriptor** ([strings.md](strings.md), [arrays.md](arrays.md)) whose
`interfaces`/itable the conversion needs.

This runtime path is only for a **genuinely unknown** value. When the type
is statically known — a typed `string`/`array`, or a `mixed` the compiler
has already proven — the value is in the **Known** group: the compiler
hardwires the type's singleton-descriptor address, and usually the vtable
slot and target method with it, exactly as for a known object class ("Why
the class pointer lives in the body" below). `"str"->foo()` on a known
string is a direct call — no `obj->class`, no kind switch, no itable
search. The kind-field resolution runs **only** where the type survives to
runtime as an open `mixed`.

**`FFIBox` and `WeakRef` are singleton built-in classes and
carry no class pointer** — the kind *is* the class, exactly as `string`
resolves to the singleton `String`. A `FFIBox` wraps a C struct to attach
it to the managed world ([FFI](memory/ffi.md)); a `WeakRef` is
`WeakReference`. There is only one class per kind, so `+8` holds no class
pointer (8 bytes saved), methods are direct calls, and `get_class` /
teardown / conversion resolve through the kind's singleton descriptor.
Teardown by kind: a `FFIBox` runs the wrapped struct's `dispose` (the FFI
class's lowered `__destruct`; [ffi.md](memory/ffi.md)), a `WeakRef` clears
its weak-table registration and never strong-releases its referent
(machinery: [weak-references.md](weak-references.md)). The
`FFIBox` kind is a single singleton, but it wraps *different* FFI types, each
with its own layout and `dispose`; the wrapped type is therefore recorded
in the `FFIBox` **body** as an instance field (a descriptor pointer), not at
`+8` and not in the flags.

**Lazy objects (Ghost/Proxy) carry a class pointer like an
ordinary object, and it is the generated ghost-shim descriptor** — see
"Lazy Objects: Ghost and Proxy" below, which is where the mechanism is
specified. A Ghost impersonates an arbitrary target class
(`new LazyGhost(Money::class)` must satisfy `instanceof Money` and
materialize a `Money`), and the shim carries that target's `object_size`,
`traced_runs`, `display`, `destruct_slot` and `dispose`, so a walker or a
teardown that reaches an untouched ghost through `obj->class` behaves
exactly as it would for an all-uninitialized instance of the real class.
The first touch runs the initializer, rewrites `+8` to the real
descriptor, and flips the kind Lazy → Object.

**Why the shim and not the real class at `+8` from birth.** An inline
cache's hit path is a class-pointer compare and a direct call
([lowering.md](lowering.md)); it never loads the flags word. With the real
class at `+8` a warm cache would compare equal on an untouched ghost and
call the method on a zero-filled body, and making the hit path see the
lazy kind
costs a load and a branch at every dynamic dispatch site. With the shim it
compares unequal, misses, and takes the slow path, which materializes.
`lowering.md` already assumes this reading: it drops `!invariant.load`
precisely for a class "whose class pointer is rewritten on first touch".

Ghost-*capability* remains a **class** flag (a class opts in, beside the
magic-method bits). The lazy kind stays as an instance marker for the paths that
load flags anyway and need to know an instance is untouched — `clone`,
which must materialize before copying rather than duplicate the shim
pointer, and reflection's initialization state.

Eight kind codes stand free — 4–7 for a kind that can close a ring, 12–15
for one that cannot.

### The Proxy family: FFIBox, WeakRef, Ghost, and movable handles are one pattern

Kinds 1, 10 and 11 are not three unrelated built-ins but three instances of one
shape, the **Proxy**: an indirection standing in for a target that
intercepts every access to it, paying one dereference to attach an effect
the target and its callers never see. This is the Gang-of-Four *Proxy*
taxonomy directly — a *virtual proxy* (materialize on first touch) is the
**Ghost/lazy** object; a *smart reference* (do work on access) is
the **WeakRef** (an access that can go dead) and the **FFIBox**
(wrapping a foreign struct into the managed world,
[ffi.md](memory/ffi.md)); a *movable handle* is a fourth effect (below).
PHP 8.4's own lazy-objects feature already names its two strategies
*Ghost* and *Proxy*; the movable handle is the classic engine handle
(V8 `Local`, Zend's pre-7 object store), an indirection whose only job is
to keep a client reference stable while the runtime relocates the target.

Two properties follow from the shape and hold for every member:

- **Identity rides the proxy, not the target.** The proxy's own address
  is the stable identity, so `spl_object_id` stays address-derived (see
  "No object table" below) even for a movable proxy whose target moves. A
  *ghost* keeps one identity (it materializes in place); a *proxy*
  forwarding to a separate real instance carries an identity distinct from
  it — the ghost-vs-proxy split PHP 8.4 documents.
- **The cost is one pointer-chase per access, and it is opt-in.** Only an
  object placed behind a proxy pays it; everything else is reached by a
  direct pointer, the PHP-7 choice this runtime keeps for the common case.

**Movement is a proxy effect, and the only one.** The general heap is
strictly non-moving ([heap-design.md](gc/heap-design.md)); an object
relocates *only* behind a **movable proxy** (or inside an
extract-to-access container), where every access already goes through the
handle, so relocation invalidates no raw pointer. This confines the
compactor, forwarding, and identity work to an opt-in pool instead of
taxing the whole runtime with read barriers and global pinning — the
reason a global moving collector is rejected ([DECISIONS](../dev/DECISIONS.md)).
An address that escapes through FFI pins its target (or extraction
copies), just as a non-proxied object never moves at all.

*Deferred, not decided:* because FFIBox, WeakRef, and Ghost are one family,
they may later be consolidated into a single Proxy kind, dropping the used
codes from seven to five — which is where a code for `resource` would come
from ([layouts.md](layouts.md), the open question). It buys codes and not a
bit: five kinds still need three of them. Not done — the kinds stay
distinct until a consolidation is designed.

The retain/release fast path is a single branch covering both arenas and immortal objects, with one exception:

```
if ((flags & 0b11) && !(flags & COW)) return;   // non-zero category → no counting
```

This implements the immortal-object and arena-scoping optimizations from [arc-optimizations.md](memory/arc-optimizations.md) with one check.

---

## Object Layout

`LLObject` — the in-memory object, the entity a ValueBox with tag `object`
points at:

```
+0   RcHeader   8 B   the common entity header (refcount + flags), so an
                      object is a valid ValueBox pointer target like any entity
+8   class      8 B   pointer to the Class descriptor
+16  property slots, fixed offsets ("Slot kinds")
```

An object instance holds only per-instance state: refcount, flags, and
property values. Everything shared between instances (name, methods,
interfaces, reflection metadata) lives in the Class descriptor, reached
through the single `class` pointer. The header is **16 bytes** before
the first property.

### Why the class pointer lives in the body

A value's type is needed at runtime in exactly one situation, and known
in the other:

1. **The compiler knows the type** (`Foo $x`, or a proven `mixed`):
   dispatch goes through the statically-known vtable, and the class is
   not read from the object at all.
2. **The compiler does not know the type**: the class must be in memory.

For the second case, *where* in memory follows **who holds the
reference**:

- **In the calling convention** — a register/stack value typed `object`
  or an interface — the class travels beside the pointer as a fat
  reference `{ptr, class}` (the same `iface_ref` shape used for
  interface dispatch). The class is in hand with no load from the
  object.
- **In the heap** — release, GC scanning, graph traversal all hold a
  bare heap reference, not a typed variable, and the fat pair does not
  reach them (the collector walks memory, not registers). So the class
  lives in the **body**, `obj->class`, reachable from the bare pointer.

Two facts make the body the right home rather than fattening every heap
reference to `{ptr, class}`:

- **The size math.** For an object with *K* references, class-in-body
  costs `16 + 8K` (a body carrying the class, plus K bare 8-byte refs);
  class-in-every-reference costs `8 + 16K`. The difference is `8(K−1)`
  — equal at one reference, worse for every shared object, and objects
  in PHP are usually shared. Fattening also doubles the width of every
  object reference, which is worse for cache.
- **The ValueBox cannot carry the pair.** A ValueBox is 16 bytes with an 8-byte
  payload — one pointer, no room for `{ptr, class}`. A `mixed` holding
  an object stores just the pointer and recovers the class from
  `obj->class`. Carrying the pair would force the ValueBox to 24 bytes, paid
  on *every* ValueBox including those holding an `int` or a `string` — absurd
  for how large the `mixed` world is. So `mixed` needs the class in the
  body regardless; once it is there for `mixed`, no heap reference needs
  to be fat.

So the class pointer stays in the object body. The fat `{ptr, class}`
reference exists only in registers and on the stack, where the class is
already at hand; in the heap an object reference is always a single
8-byte pointer, and the four runtime consumers — dynamic dispatch on an
`object`-typed receiver, `instanceof` / `get_class`, GC scanning (the
property layout that says which slots are references), and teardown
(`dispose`) — read the class from `obj->class`.

**Class references are full 8-byte pointers (final decision).**
Compressed class ids (u32 index into a global class table, as in the
JVM) were considered and rejected: the 4 saved bytes per object do not
justify an extra dependent load on every dispatch and a global table on
the hottest path. Full removal of the pointer is heavier still — it
breaks GC scanning and `mixed` storage, per the reasoning above.

### Rejected: moving the class out of the object body

A whole family of designs for removing the 8-byte class pointer from the
object was worked through and **rejected**. Recording it here because the
reasoning is the valuable part — the designs are seductive and will be
proposed again.

- **Fat references everywhere** — carry `{ptr, class}` (and
  `{itbl, ptr, class}` for interfaces) not just in registers but in
  every heap slot, so the class rides the reference and the body drops
  it. This loses in aggregate. References outnumber objects in any
  reachable heap (edges ≥ nodes), and references *dominate* heap memory:
  V8 measured tagged values at ~70% of the heap, and halving reference
  width gave up to −43% heap ([v8.dev/blog/pointer-compression]). A
  per-reference class word widens the dominant cost to save the smaller
  per-object one; for shared objects (the norm — most heap types are
  aliased) it is a net loss. Every mainstream dynamic runtime — JVM,
  .NET, CPython, V8, Ruby, Zend — keeps the class word *in the object*;
  none moved it into references, and those fighting header size (JVM
  Lilliput) *compress* the class word rather than relocate it.

- **Final-class optimization** — drop the class from the body only for
  `final` classes with no interfaces, since their exact type is known
  statically. It works and keeps references thin, but it creates a hole:
  a `final` object placed into an `object`/`mixed`/interface slot loses
  its static type, and the collector, arriving by a bare pointer, cannot
  recover the real class to trace its fields. Closing the hole needs
  either escape analysis or class-in-the-polymorphic-slot, and it makes
  the GC, `traced_runs`, and the compiler carry per-kind slot cases. The
  saving (8 bytes on the subset of final objects that never escape to an
  untyped context) does not pay for that complexity. Devirtualization of
  `final` calls stands on its own and is kept; only the body-shrink is
  dropped.

- **Type-from-address** — store the class nowhere, recover it from the
  object's address by segregating each class into its own memory pool
  (Go's span-based approach). It is the cleanest of the three and has no
  hole, but it forces per-class/per-size memory segregation and turns
  every "what class is this" from one `obj->class` load into an
  address→pool→class chain, on the GC's hottest path. Not worth it here.

**Conclusion.** The class pointer stays in the object body for every
object. The fat `{ptr, class}` / `{itbl, ptr, class}` reference exists
**only** in registers and on the stack (the calling convention), where
the class is already at hand and no body load is on the path. The one
change that *did* survive this analysis is orthogonal: strings and
arrays are not objects at all (no class pointer; identified by tag —
[values.md](values.md), [strings.md](strings.md), [arrays.md](arrays.md)),
so the question never applies to them.

**No object table.** Objects are referenced only by direct pointers: there is no analog of Zend's object store with handles. PHP 7 itself moved object access from handles to direct pointers for performance; the store's remaining duties are covered differently in Limelight: object enumeration by linear block scanning (see [heap-design.md](gc/heap-design.md)), shutdown/arena-reset destructors by the `DESTRUCTOR_PENDING` flag bit, weak references by side tables. Non-moving GC means a direct-pointer object's address is stable for its lifetime, so `spl_object_id()` can be derived from it; a movable-proxy target's identity is instead its proxy's stable address ("The Proxy family" above).

### Slot kinds

**Decision**: a property slot is the machine representation of the
property's declared type, and nothing more. The 16-byte ValueBox
([values.md](values.md)) appears inside an object **only** where the
property has no declared type — that is the one storage site in an
object where the type is not known statically.

| Declared as | Slot | Size / align |
|---|---|---|
| `int`, `float` | raw `i64` / `f64`, no tag | 8 / 8 |
| declared class type, `string`, `array` | bare pointer; `NULL` means **uninitialized** (a non-nullable type has no valid null), read compares and throws ([values.md](values.md)) | 8 / 8 |
| `?T` for pointer-shaped `T` | the same pointer; `NULL` is PHP `null` (niche). Uninitialized, if possible, is an init-bitmap bit ([values.md](values.md)) | 8 / 8 |
| `?int`, `?float` | ValueBox — a nullable scalar has no representation of its own ([values.md](values.md)) | 16 / 8 |
| `bool` | a byte, or a bit in the byte block (below) | 1 / 1 |
| untyped / `mixed` | ValueBox | 16 / 8 |
| hooked property with no backing store (`virtual`) | none | 0 |

A typed property therefore costs what its type costs. An object with
four `int` fields is 16 bytes of header plus 32 bytes of payload, not
16 plus 64.

### Slot order

**Decision**: a class lays out its own properties in three runs —
**counted pointers, then ValueBoxes, then everything else in declaration
order** — and the byte block last.

```
+0   header (8) | class (8)
     counted pointers          ← contiguous run
     ValueBoxes                     ← contiguous run
     remaining slots, in declaration order
     byte block: init bits, packed bools
```

The grouping has **one** beneficiary: the garbage collector. It holds
only `obj`, reads `obj->class`, and must find the counted pointers
without knowing the class statically. Grouping them into runs makes
that a stride over a short list of `(offset, count)` pairs — HotSpot's
`OopMapBlock`, .NET's `GCDesc` series — instead of a per-property flag
test. Contiguous references also trace as a tight, prefetch-friendly
loop. This is the trace map, `traced_runs`, and it is the **only**
consumer that reads the layout as data at runtime; §"Construction and
teardown" gives the other two consumers, which are code.

`traced_runs` is a **list** of pairs, not one range. A root class whose
pointers lead the layout has exactly one; a subclass adds its own run
after the parent's scalars, so at depth *d* there are up to *d* pairs.
That is the normal shape — HotSpot and .NET both carry a list and
merge adjacent runs only when a hierarchy happens to make them
adjacent. The single-range case is the reward for a shallow hierarchy,
not a guarantee. (The only layout that keeps one range at every depth
is bidirectional — pointers left of the origin, scalars right, Bacon/
Fink/Grove — and its signed offsets and interface-layout cost are why
no production VM adopted it.)

**Two lists, by run kind.** A counted-pointer run and a ValueBox run are
walked differently — a pointer element is 8 bytes and "empty" is `NULL`,
a ValueBox element is 16 bytes and "empty" is the `refcounted` flag clear —
so a single flat list of `(offset, count)` could not tell a strider
which stride and which skip-test to use. `traced_runs` is therefore
**two typed lists**: pointer runs (stride 8, skip `NULL`) and ValueBox runs
(stride 16, skip by flag). A typed class's ValueBox list is usually empty.

**Every stride null-checks.** A counted-pointer slot can hold `NULL` at
any time — an uninitialized non-nullable pointer starts `NULL`, and
`unset()` returns any pointer slot to `NULL` ([values.md](values.md)) —
and no analysis excludes it, because `unset()` is always reachable. So
**every** consumer that strides the pointer runs — `clone`'s retain
stride, `deep_clone`/`thread_*`, the GC trace, `dispose`'s release — must
skip `NULL` before touching the slot. This is one predicted-taken branch
per pointer (the pointer is almost always non-null), not a defeat of the
grouping; the run is still contiguous and prefetch-friendly, it is just
not literally branch-free. The store barrier already skips `NULL` in its
`ptr` form; the stride consumers do the same, explicitly.

**Initialization does not read this map.** At a `new` site the class is
known, so the compiler emits the initializer as straight-line code: one
zero-fill over the object body — which makes every raw slot `null`/`0`
and every init-bitmap bit clear (i.e. uninitialized) at once — then the
few explicit stores: a default value where the property has one, and a
`undef` flag on a `mixed`/untyped slot declared **without** a default,
since an all-zero ValueBox is `null`, not undefined ([values.md](values.md)).
No loop, no `traced_runs` read. The map serves initialization only on
the out-of-line path where the class is dynamic (§"Construction and
teardown").

Physical order therefore differs from declaration order. Declaration
order remains observable — `serialize()`, `(array)`, `foreach` over an
object, reflection — so `prop_layout` carries each property's
declaration index. It costs metadata in the descriptor and nothing in
the instance.

### Inheritance, and the parent's tail padding

**Decision**: a class descriptor carries two sizes: `object_size`, the
allocation size, and `layout_end`, the first free byte before any
rounding. A subclass starts laying out its own properties at the
parent's `layout_end`, not at the parent's `object_size`.

Inherited slots never move: a parent's offsets are compiled into the
parent's own code, and subclasses are linked in an open world. But the
padding at the end of the parent is not spoken for, and the subclass
takes it. (HotSpot gained the same rule in JDK 15, JDK-8237767.)

**Consequence, stated because it is easy to violate**: an object may
not be copied by "the size of its parent". A subclass field can live
inside what looks like the parent's trailing padding. A copy is always
sized by the *whole* object's `object_size` — `clone` is a
`memcpy(object_size)` followed by a retain stride over `traced_runs`,
never a per-property walk.

**Two slots the retain stride is not enough for**, because a `memcpy`
duplicates the *pointer* where the copy needs its own entity:

- the **dynamic-properties** hidden slot (below): it is a pointer to a
  per-object hashtable, so `memcpy` + retain would make the clone and
  the original share one table — a mutation through either is visible in
  both, and both dispose paths would free it. `clone` gives the copy an
  independent hashtable (a deep copy of the table, itself shallow in its
  values under the usual COW recursion). This slot is not in
  `traced_runs`; `clone` handles it specially, as does `dispose`.
- the **weak side-table** bit: the copy is a new object with no weak
  references yet, so the `WEAK` flag is cleared on the clone and no
  side-table entry is created — a `WeakReference` to the original must
  not resolve to the copy.

### The byte block

One trailing region of the object holds everything that is smaller than
a slot: the init bitmap ([values.md](values.md)) and packed `bool`s
where the compiler chooses to pack them. It is allocated from the same
hole-filling pass as the small slots, so in most classes it lands in
alignment padding and costs nothing.

### Layout targets exact bytes

**Decision**: the layout algorithm minimizes the exact byte count.
Rounding to an allocator size class is a property of the *allocation
site*, not of the class, and the layout must not be tuned to one
allocator's class table: the same class can be instantiated in the GC
heap (size classes, see
[heap-slot-allocation.md](memory/heap-slot-allocation.md)), in a
request arena (bump, every byte real), or out of a pool the compiler
generated for that one class (stride = `object_size`, no rounding at
all).

The compiler knows which strategy a site uses; the runtime does not
guess. Where it matters, the compiler decides — including whether the
saved bytes are worth anything at that site at all.

### `bool`: a byte or a bit

**Decision**: the runtime supports both, and the choice is the
compiler's, per class. A byte is the default.

A bit is smaller but not free: reading it is a load, a shift and a
mask, and writing it is read-modify-write instead of a store. Packing
pays only when it actually changes the allocated size, which depends on
the strategy above. A class with many `bool`s allocated from a
per-class pool is the case where it does.

`&$obj->flag` on a packed `bool` has no byte to point at. It is served
by the typed slot reference of [values.md](values.md) — `RcHeader |
owner | slot | type` — whose `type` additionally carries the bit index.
`&` is rare, and the whole cost stays inside that box.

### The link-time algorithm

Per class, once, when it is linked:

1. **Classify** each own property by its declared type into a slot kind
   (table above). `virtual` properties take no slot.
2. **Start** the cursor at the parent's `layout_end`, or at 16 for a
   root class. The hole list is empty.
3. **Place** the runs in order — counted pointers, ValueBoxes, then the rest
   in declaration order. For each slot: align the cursor up, record any
   skipped interval as a hole, take the slot, advance.
4. **Fill holes** with 4/2/1-byte slots and the byte block before
   extending the cursor. Pointers and ValueBoxes are never placed into a
   hole: that would break the contiguity of the runs.
5. **Finish**: `layout_end` is the cursor, `object_size` is it rounded
   up to 8.
6. **Record** the trace map: the parent's `(offset, count)` pairs, plus
   at most one new pair per traced kind for this class's own run. The
   result is a list, one pair per class in the hierarchy that
   contributed pointers or ValueBoxes.

---

## Construction and Teardown

The layout has three consumers, and they run at different frequencies,
so each gets a different form.

- **Construction** runs once per object. It is **code**: the compiler
  emits an allocate-and-initialize routine per class.
- **Teardown** runs once per object. It is **code**: the compiler emits
  a destructor per class.
- **Tracing** runs on every live object every collection cycle. It is
  **data**: the GC strides `traced_runs`, with no indirect call per
  object.

Only the third reads the layout as data at runtime. The first two are
compiled straight-line, so they never interpret a map. This retires the
generic runtime interpreters an earlier design carried — an
`ll_object_new` that read `object_size` and walked the map to
initialize, and an `ll_object_die` that walked it to release.

### The factory

**Decision**: each class carries a pointer to a compiler-generated
**factory**, `factory(ctx, category)`, which allocates an instance and
initializes it in straight-line code — the object body in one store,
then the few typed slots that start non-zero. The address of the arena
lives in `ctx`; `category` selects among the four memory categories
that one `ctx` can allocate into (`GcHeap`, request arena, long-lived,
immortal), so it stays a parameter.

A static `new User()` inlines the factory or calls it directly. A
dynamic `new $class` reads `class->factory` and makes one indirect
call — which runs specialized code, not a map walk. That is the whole
reason the factory lives in the descriptor: the dynamic path.

**There may be more than one factory, and only the canonical one is in
the descriptor.** The others are members of the lifecycle family below.

### The lifecycle operation family

**Decision**: allocation, teardown, and every whole-object copy or move
are **compiler-generated methods per class**, specialized to the class's
layout. They are one family, built the same way; which of them the
descriptor carries a pointer to is decided per operation by whether a
*dynamic* (class-in-a-register) path needs it.

| Operation | What it does | In descriptor? |
|---|---|---|
| `factory(ctx, category)` | allocate + initialize | yes — `new $class` |
| `dispose(obj)` | release counted fields, run `__destruct` | yes — the collector holds only `obj` |
| `clone(obj)` | shallow copy: `memcpy(object_size)` + retain stride over `traced_runs` | maybe — `clone` on a dynamic type |
| `deep_clone(obj)` | recursive copy of the whole graph | maybe |
| `thread_clone(obj, dst)` | copy into another thread | maybe |
| `thread_move(obj, dst)` | move into another thread, source gives up ownership | maybe |

Two rules shape the whole family:

- **Recursion is through the same operation on the field's type.**
  `deep_clone` of an object copies its scalar slots and calls
  `deep_clone` on each counted child; `thread_move` copies scalars and
  calls `thread_move` on each child. A resource-holding type (a socket,
  a file descriptor) is not memcpy-able across threads — it carries its
  own implementation of these hooks (`dup` the fd for `thread_clone`,
  hand it over and null the source for `thread_move`), and the parent's
  generated operation calls it like any other field. **How the compiler
  decides a field needs the hook is the compiler's business and not part
  of the runtime model** — the runtime only sees the generated call.

- **A transfer leaves no reference behind** (Edmond, 2026-08-29,
  [../dev/DECISIONS.md](../dev/DECISIONS.md), "a transfer leaves no
  reference behind"). `thread_move` and `thread_clone` require the graph
  that arrives in the destination thread to hold no reference to an object
  that stays in the source thread. What crosses is closed: the destination
  reaches nothing the source still owns. A graph that cannot satisfy it
  cannot be transferred, and the operation refuses rather than producing a
  reference across the boundary.

- **A graph copy needs an identity map.** `deep_clone`, `thread_clone`
  and `thread_move` walk a graph that may have cycles and shared nodes,
  so they thread an old→new map (as `unserialize` does), not a plain
  recursion. The map is a runtime structure; the per-field dispatch is
  still compiled.

The specialized-by-category factory (category a compile-time constant,
signature just `(ctx)`, the four-way selection gone) and the
Ghost/Proxy shims for lazy objects and `unserialize` are members of the
same family. A new operation is a new generated symbol; adding one does
not change the descriptor unless it needs the dynamic path.

**Reserved, semantics not yet decided**: whether `deep_clone`
copies COW entities (strings, arrays) eagerly or leaves them shared to
separate on first write. The ownership model of `thread_move` /
`thread_clone` was open here until 2026-08-29 and is now share-nothing by
the rule above: the alternative it was weighed against — transfer of
ownership with atomic counting — leaves a reference across the boundary
and is refused with it. What still arrives with multi-threading is the
mechanism, not the choice.

### dispose — the internal destructor

**Decision**: each class carries a pointer to `dispose(obj)`, a
compiler-generated **internal** destructor. Every class has one, even
without a user `__destruct`. It releases the counted fields in
straight-line code — release slot 1, release slot 2, … — frees internal
resources, and calls the user `__destruct` when the class has one.

`dispose` is not `__destruct`. `__destruct` is the optional,
side-effecting, resurrection-capable PHP destructor; `dispose` is the
mandatory internal teardown that *invokes* it. The collector, holding a
dead object, does `obj->class->dispose(obj)` — one indirect call into
specialized code, the teardown analog of the factory. This is the
`__dispose` named in "Deferred" as part of the metaclass model, made
concrete.

### Generated body shape: unrolled for a small class, a loop for a large one

**Decision**: the counted-field strides of a generated lifecycle
operation — `dispose`'s releases, the retain strides of
`clone`/`deep_clone`/`thread_*`, and the non-zero-default stamps of
`factory` — are emitted **unrolled** for a class with few counted fields,
and **as a loop over `traced_runs`** once the count crosses a threshold.
The RFC's "straight-line code, release slot 1, release slot 2, …" above is
the small-class shape, not an unconditional one.

**Why unroll the common case.** These bodies run once per object, so path
length is what counts, and a class carries a handful of counted fields far
more often than dozens. Unrolled, `dispose` is `release(a); release(b); …`
with no loop counter and no `traced_runs` load, the releases free to
schedule and to cancel against a matching retain (the ARC optimizer). It
is the same straight-line shape the factory's construction path already
has.

**Why loop the large case.** Code size is paid per class *per operation* —
a class with dozens of counted fields would emit those dozens of
instructions in `dispose`, again in `clone`, again in each `thread_*`,
bloating the instruction cache for an object whose own work dwarfs a loop
counter. Past the threshold the loop is a few instructions total, and it
reads the **same `traced_runs` the GC strides** — so a large class needs
no second teardown map: the trace map serves both the data consumer (the
GC, inline) and the looped code consumer (`dispose`, behind its indirect
call).

**The threshold is a codegen tuning parameter, not a model constant.** It
is calibrated against real workloads once the pipeline can run them, like
every other size threshold here; the crossover is on the order of a few
tens of counted fields. The model fixes the two body shapes and the rule
that chooses between them, not the number.

### Why tracing stays data

Construction and teardown touch an object once in its life, so an
indirect call into specialized code is cheap and wins on path length.
Tracing touches every live object every cycle, so an indirect call per
object is not affordable; the GC reads `traced_runs` and strides it
itself. V8 uses a per-map visitor function and pays exactly that call;
for our collector the map as data is the right form. Construction is
code, teardown is code, tracing is data — each shaped to its frequency.
The one qualification is code size: past a field-count threshold the
generated body loops over `traced_runs` rather than unrolling ("Generated
body shape" above), converging on the trace's own form — but still reached
by the indirect call the trace never pays.

**"Data" does not mean one stride per consumer.** Several operations walk
the same runs — the quiescent tracer, the drain's sever, the arena reset,
and a concurrent collector — and they differ in how the memory is read,
not in where the children are. A concurrent walker must read the entity's
own words atomically, since a plain read racing a mutator store is
undefined behavior rather than a torn value, while a descriptor and a
template shape are immortal and are read plainly by every walker. So the
stride is written once and parameterized by the reader; each instantiation
still monomorphizes to a bare loop, and the indirect call the trace never
pays is not reintroduced. Writing the stride out per consumer instead is
what the runtime did until 2026-08-06, and it cost a defect on each
layout change: the interpolated template's per-instance value count had to
be taught to three walkers, and the third was found only by review.

---

## Class Descriptor

**Decision**: One descriptor per class, allocated in the **immortal region** at class link time. Its address is stable for the lifetime of the process; this is the foundation for inline caches (see below).

The region matters, and an earlier draft of this document said "long-lived arena". It is immortal — bump allocation with no reset and nothing ever freed (`ll-model/src/memory/immortal.rs`, and invariant 14 of that crate's `ARCHITECTURE.md`). The long-lived arena leaves its reclamation strategy explicitly undecided ([arenas.md](memory/arenas.md)), and a reclaimed descriptor address that is later re-issued to a different class would not crash an inline cache — it would produce a **false hit**, dispatching one class's method on another's instance. "ICs never require invalidation" is a theorem under immortal residence and a hope under any other.

### Fields

Hot part (touched by dispatch and property access):

| Field | Purpose |
|-------|---------|
| `flags` | `final`, `abstract`, `interface` + magic-method presence bitmask (`__call`, `__get`, `__set`, `__destruct`, …) |
| `parent` | Parent class: inheritance chain for `instanceof`, `parent::`, vtable construction |
| `object_size` | Allocation size for instances |
| `layout_end` | First free byte, unrounded: where a subclass resumes laying out |
| `factory` | Canonical constructor `factory(ctx, category)`: allocates and initializes an instance ("Construction and teardown") |
| `dispose` | Internal destructor `dispose(obj)`: releases counted fields and runs `__destruct` if present |
| `prop_layout` | Property table: name → (offset, slot kind, hook flags, declaration index, and for a bitmap-tracked slot its init-bit position in the byte block, [values.md](values.md) "Uninitialized properties") |
| `traced_runs` | The trace map the GC strides: **two** typed lists of `(offset, count)` — pointer runs (stride 8, skip `NULL`) and ValueBox runs (stride 16, skip by flag) |
| `undef_runs` | ValueBox slots declared **without** a default, as `(offset, count)` runs (stride 16, always a sub-range of the ValueBox trace runs): the out-of-line factory stamps their `undef` flag after the zero-fill ([values.md](values.md), Construction). Construction-only — the GC and teardown never read it |
| `display` | Cohen display: ancestors root→self indexed by depth, for O(1) `instanceof` |
| `destruct_slot` | Vtable slot of `__destruct`, or a sentinel when the class has none |
| `interfaces` | Sorted array: interface id → itable pointer |
| `methods` | Hashtable: name → method; slow path lookup, also the source for building subclass vtables |
| `statics` | TLS offset of this class's thread-local static block — its **own** declarations only (see below) |
| `static_vtbl` | Static-method table pointer; own table only when the class overrides an inherited static method, otherwise points to the parent's table (see below) |
| `vtbl[]` | **Inline trailing array** of code pointers |

Cold part (reached via a metadata pointer):

| Field | Purpose |
|-------|---------|
| `name` | Class name string |
| `reflection` | Attributes, doc comments, declaration info |
| `traits` | List of used traits; reflection only (see below) |

The cold block is also what a *new* class links against when one has to
be built while the program runs: it carries the interface method lists
in slot order, the method names behind vtable slots, and the property
declarations behind offsets. That is not a separate structure — it is
the same metadata reflection already needs, and the same pointer.

### Linking is the compiler's job

**Decision**: class descriptors — vtable, itables, property offsets,
Cohen display, `object_size` — are built **by the compiler**, and the
runtime only reads them. Deriving a subclass's tables from its parent's
is compilation, not execution. There is no runtime linker on any path
that a normal program takes.

A class that did not exist at compile time is still possible: `eval()`,
a plugin loaded after the build, code the JIT compiles from outside the
unit. That case is served by the **cold metadata**, not by keeping a
linker in the runtime. The descriptor points at its metadata block; the
metadata block already carries what building a derived descriptor
requires, and nothing on a hot path ever reads it.

The consequence for the hot tables is that they hold **only** what
dispatch needs. Recipes for rebuilding them live in the metadata, one
pointer away and one temperature colder.

### Inline trailing vtable

The vtable is not a separately allocated table: it is the tail of the descriptor itself. A virtual call is two dependent loads:

```
class = obj->class
call class->vtbl[slot]
```

This equals the cost of a C++ virtual call (vptr → slot) while keeping the full class descriptor one load away for `instanceof`, reflection, and GC.

### Offsets instead of pointers — withdrawn

All class metadata lives in the immortal region, and that retires the u32-offset option this section used to propose (class → parent, class → itable, class → name as 4-byte offsets from an arena base, at the cost of one add per dereference, with the metadata arena capped at 4 GB). The immortal region is a chain of 64 KB blocks drawn one at a time from the same global pool that serves request arenas and the heap, interleaved with them in address space: there is no base to take an offset from, and no bound on the span. Class references are full 8-byte pointers, which this document had already decided elsewhere. Self-relative offsets within one allocation — a descriptor to its own trailing vtable and itables — would still be expressible, and are not worth a second addressing mode.

### Traits

Traits are flattened into the class at link time: their methods become ordinary class methods with ordinary vtable slots. The runtime has **no trait mechanism at all**. The list of used traits is kept only in reflection metadata for `getTraits()`.

---

## Vtable

Slot assignment rules, applied at class link time:

- A subclass inherits the parent's slot layout unchanged: inherited methods keep their indices.
- New virtual methods are appended after the parent's slots.
- An override writes its function pointer into the existing slot.
- **Private methods get no slot**: they are not polymorphic in PHP and always compile to direct calls.
- **Final methods occupy a slot** (uniform layout) but calls devirtualize to direct calls whenever the static type is known.
- **Property hooks occupy vtable slots** like methods: this gives hook inheritance and overriding the ordinary vtable semantics for free.

---

## Static Methods and Late Static Binding

`self::foo()`, `parent::foo()`, and explicit `Foo::bar()` resolve at compile time to **direct calls**, no dispatch machinery involved. The only dynamic cases are `static::` (late static binding) and `$var::foo()`.

**Decision**: every class carries a `static_vtbl` pointer. A class that overrides at least one inherited static method gets its own physical table; a class that overrides nothing inherits the parent's table pointer; physical tables exist only where overriding actually happened. The call site is uniform and branch-free:

```
call cls->static_vtbl[slot](cls, ...)
```

A static method thus differs from an instance method only in its implicit first argument: the called class instead of `$this`. Slot indices are assigned at first declaration and never change down the hierarchy.

Note on compilation order: a subclass is always linked with full knowledge of its parent (PHP requires the parent to be loaded first), so subclass tables are built correctly and finally. The reverse is not true: a parent's `static::foo()` call site is compiled before future subclasses exist (autoloading = open world). This is why the base dispatch always goes through `static_vtbl`, and compiling such sites as direct calls is only possible optimistically, with site patching when an overriding subclass loads (CHA-style; deferred to the JIT phase).

---

## Static Properties and Constants

### The static block

**Decision**: static properties are **thread-local**. A class's static
block — one contiguous region per class, laid out by the object layout
algorithm above — exists **once per thread**, in that thread's TLS. It
is not part of the descriptor: the descriptor is immortal and shared
across threads, and the block is per-thread mutable state, which is
exactly what must not sit inside a structure inline caches assume never
changes.

Thread-local is the decision, not an option, and it buys share-nothing:
no two threads see the same static cell, so `Foo::$bar` needs no lock
and no atomics, and the whole class of static-property data race is
gone by construction. It also matches how PHP is deployed — a worker
owns its request — made intrinsic rather than left to a process model.

**Access is TLS-relative.** The descriptor does not hold a pointer to
the block — it could not, since every thread's block is at a different
address. It holds a **TLS handle**, and a thread resolves `Foo::$bar` as
*its* TLS base + that handle + the field offset.

The handle has two forms, because static TLS and dynamically-loaded TLS
are addressed differently. For a class compiled into the image the
handle is a **link-time-constant offset**, and the access is the
platform's normal `fs`/`gs`-relative load (the fast-TLS path the heap
already uses). A class loaded later (`eval`, autoload, a plugin) lives
in **dynamic TLS**, addressed by a `(module, offset)` pair through the
DTV, not a flat offset — so the descriptor's handle is a small tagged
union (flat offset *or* dynamic slot), and late-class access takes the
`__tls_get_addr`-style path, not the fast one. A `uint32_t` offset alone
cannot encode the dynamic case; the field is sized for the union.

The per-thread root walk (below) reads each class's handle to find the
block. A thread that never touched a given late-loaded class has **no
block allocated** for it, so the walk must treat an unallocated dynamic
slot as an empty root set (nothing to trace), not fault on it — image
classes always have their block (BSS-backed, zero-filled), late classes
only after first use in the thread.

Inside, the block is an object: the same slot kinds, the same three
runs with counted pointers first, the same `traced_runs`, the same
zero-fill for the slots that start at zero.

### Initializing the block, per thread

A thread's TLS region starts zeroed, which is the *correct* start only
for slots whose initial value is zero: a `null` pointer or ValueBox, a `0`
scalar, a clear init-bitmap bit. Everything else needs code. A
`public static int $n = 5` holds a non-zero scalar; `public static array
$m = ['a' => 1]` and `public static string $s = 'x'` hold counted heap
entities that cannot pre-exist in TLS at all. So each class carries a
**compiler-generated static initializer** that stamps these — the
static analog of the instance factory.

It runs **per thread**, when the class first becomes usable *in that
thread*: at thread start-up for classes compiled into the image, at
class load for classes loaded later. Each thread runs it once and builds
its own copy of the counted defaults. So start-up does no work for the
zero-start slots the OS zero-fills, and a class with non-zero static
defaults pays for exactly those, once per thread that uses it.

A running constant initializer (PHP 8.1 `new` in a constant expression)
is *not* stamped here — it stays lazy, evaluated on first access in the
thread through its init-bitmap bit ("Constants" below), because it may
run arbitrary code and observe order that eager stamping would fix too
early.

### Actors are the exception (reserved)

Thread-local is correct for the thread-owns-a-request world. **Actors
break the assumption it rests on**: an actor is not bound to a thread —
the scheduler runs it on whatever pool thread is free and it may migrate
between messages ([actors.md](../runtime/actors.md)). Plain thread-local
statics would then leak across the isolation boundary: an actor would
see the static cells of whatever thread it currently runs on, shared
with every other actor that thread also hosts — the opposite of the
share-nothing that thread-local was meant to give.

The direction, not yet specified: static state of an **actor** class
belongs to the **actor**, not the thread, and follows the actor exactly
as its allocation arena already does — mounted into the accessed TLS
base when the scheduler places the actor on a thread, so the same
TLS-relative access keeps working while what it resolves to travels with
the actor ([actors.md](../runtime/actors.md), "the allocation context
follows the actor, not the thread").

**Reserved, to design with the actor runtime**: whether a *non-actor*
class's statics, touched from inside an actor, are per-thread (and thus
shared between actors on that thread — a hole in isolation) or are
pulled into the actor's set too; and how the compiler tells the two
cases apart at a static access site. Named here so thread-local statics
are understood as the non-actor rule, with actors a known exception, not
an oversight.

### Statics do not inherit by prefix

**This is where statics differ from objects.** In PHP a subclass that
does not redeclare a static property **shares the parent's storage**:
`Child::$x` and `Parent::$x` are one cell, and writing through either
is visible through both. So the "parent's slots first, own appended"
rule of object layout does not apply here. A class's block holds
**only what that class declares**, and `Child::$x` resolves — at
compile time, at no runtime cost — to the slot in the block of the
class that declared it.

### Constants

A constant whose initializer is a literal or a constant expression is
folded at the use site and needs no storage at all.

A constant whose initializer must run (PHP 8.1 allows `new` in constant
expressions) needs a slot and a "not yet computed" state. That state is
a bit in the static block's init bitmap ([values.md](values.md)), the
same mechanism uninitialized properties use: the constant's slot starts
zero with its bit clear, and the first access sees the clear bit and
runs the initializer. Where an uninitialized *property* with a clear
bit throws, an unevaluated *constant* with a clear bit initializes; the
compiler knows which slot it is emitting for, so the two read the same
bit to different effect with no extra runtime check.

### GC roots

Static blocks are a root set **per thread**: a thread's collector walks
its own TLS blocks, and never another thread's — share-nothing again.
The compiler already emits a class table (reflection and `class_exists`
need one), so tracing takes each class's static TLS offset and
`traced_runs` from it; there is no runtime root registration, the set is
known at link time.

Because the block is thread-local, its lifetime is the **thread's**, not
the program's — so the cycle-held-by-a-static problem is disposed of by
thread exit, the way PHP-FPM disposed of it by process exit per request.
A worker thread that ends releases its static blocks and everything they
root; a long-lived worker still accumulates within its own lifetime, and
an explicit cycle collector covers that as it does any other cycle.

### Teardown at thread exit

> **Built**, 2026-08-03 (`ll-model` `src/static_block.rs`). One thing
> the design did not anticipate: this is the first work that makes
> thread exit run *user code*, and the `__destruct` bodies it reaches
> touch per-thread runtime structures. Rust registers a `thread_local!`
> with drop glue for TLS destruction, destruction order is unspecified,
> and on glibc it is reverse registration order — which destroys the
> exit hook last, because it registers first. So the structures the
> pass needs were reliably already gone, and the resulting panic cannot
> unwind out of a destructor. Every such structure is now a pointer cell
> with no drop glue, and thread exit disposes of them in an order it
> fixes itself: static blocks, then the collector's per-thread state,
> then the weak table, then the heaps.

The counterpart of the static initializer above, and where a static
block's roots are actually released. Without it a worker pool accumulates
their graphs forever: the escape hold-count a static places on a
request-arena object has no other decrement point — an overwrite
mid-request is the store barrier's `drop`
([strategies.md](gc/strategies.md)), thread exit is the other end
([arenas.md](memory/arenas.md)).

- **Registry.** Each thread appends a block to a thread-local list the
  first time it initializes that block — one append per class-block per
  thread, beside the initializer that already runs there.
- **Order.** The list is walked in **reverse initialization order** (LIFO),
  as C++ tears down function-local statics: a later block may have been
  initialized against an earlier one.
- **Per block**, the compiler-emitted teardown walks the block's reference
  slots — the same `traced_runs` the collector uses — and runs `drop` on
  each, exactly the store barrier's `drop` micro-op: a request-arena
  escapee decrements its escape hold-count (`escape_lose`), a heap
  reference releases and cascades, an immortal/long-lived one is a no-op.
  The block is headerless, which does not matter: `drop` operates on the
  displaced entity, and the destination's `owner_cat` (long-lived) is a
  compile-time constant.
- **`__destruct` runs** wherever a release drives a refcount to zero —
  these are the shutdown destructors of the thread's end of life, in
  refcount-determined order.
- **Every thread exit does this in full**, including the process's last
  thread, because PHP runs destructors at end of life and their side
  effects must fire. Only the raw memory-free of that final teardown is
  redundant (the OS reclaims the address space regardless); the destructor
  pass is not skipped, so observable behavior is unchanged. Actors are the
  reserved exception above — their static state follows the actor, not the
  thread.

---

## Interface Tables (itables)

**Decision**: An interface is an ABI contract: the declaration order of its methods permanently fixes their slot indices. A class carries **one itable per implemented interface**: an array of code pointers into the class's own methods, built eagerly at class link time. This is the COM model.

Diamond composition is a non-issue by construction: PHP allows `interface C extends A, B`; a class implementing `C` simply carries three itables, for `C`, `A`, and `B`. Each itable has its own independent layout; nothing needs to be merged.

### Pure pointer tables, one trailing train

**Invariant**: every dispatch table — vtbl, itables, `static_vtbl` — is
a bare array of code pointers, nothing else. All metadata lives in the
descriptor and in the `interfaces` entries, beside the tables, never
inside them. C++-style table headers (offset-to-top, RTTI pointer) are
unnecessary here: an object points at the *descriptor*, not at a
table, so the descriptor is the vtbl's header; and no conversion ever
navigates from an itable back to metadata (super-interface and
mixed-value conversions go through `obj->class`).

Because the tables are homogeneous, they ride **one trailing
allocation** of the descriptor: `[Class][vtbl][itable A][itable B]…`.
The `interfaces` entries point into this tail. One metadata allocation
per class instead of 1+N, and all of a class's dispatch targets sit in
one contiguous region next to the descriptor that every call has just
loaded. Slot maps (below) are cold link-time data and stay off the
train.

### Re-linking inherited itables

An itable is a *baked* artifact — resolved code addresses — and a baked
address does not say which vtable slot it came from. A subclass that
inherited an interface and overrode one of its methods must not
inherit the parent's itable as-is: it would keep pointing at the
parent's implementation, silently bypassing the override on every
interface-typed call. Its itables are therefore built fresh, from its
own vtable.

**This is compilation.** The compiler knows the interface's method
order and which slots the subclass overrode, and it emits both tables
finished. Nothing is rebuilt while the program runs, and the itable
carries no map, no back-reference, no metadata — only code pointers.

For the late case (`eval`, a plugin, JIT code from outside the unit)
the recipe is in the **cold metadata**: the interface's method list in
slot order, resolved against the new class's methods by interned name.
Slot indices are stable down the hierarchy, so an override lands
automatically. A previous revision of this document kept that recipe as
a *slot map* stored beside every itable, in hot metadata, permanently,
for a case that occurs approximately never. It does not belong there.

### Fat interface references

**Decision**: a value statically typed as an interface is represented as a pair, COM's `interface_pointer_t` model:

```
struct interface_ref { object *obj; itable *itbl; }  // 16 bytes; registers/stack only
```

A call through an interface-typed receiver is then a single indirect call, with no lookup of any kind at the call site:

```
call ref.itbl[slot](ref.obj, ...)
```

The itable lookup does not disappear: it moves to the conversion point (object → interface), where it is usually free:

| Conversion | Cost |
|------------|------|
| Concrete class known statically | itable address is a link-time constant: zero runtime cost |
| Interface → same interface | pass-through |
| Interface → super-interface | `find` via `ref.obj->class` (IC applies) |
| Untyped / `mixed` value → interface | `find(class->interfaces, interface_id)`: sorted array + IC |

The `find` step is the analog of COM's `QueryInterface`: a sorted array keyed by interface id (classes implement few interfaces, so a short array beats a hashtable on cache locality); an inline cache reduces it to one compare in hot code.

**Fat references exist only in the calling convention**: registers, stack, interface-typed parameters and locals. In the heap (properties, array elements, `mixed`) an object reference is always a single 8-byte pointer; the fat reference is materialized at load/conversion time. Heap values stay uniform, while repeated calls through an interface-typed parameter cost exactly a C++ virtual call.

### Extension ("friend") interfaces

**Decision**: any type, including primitives like `string` and `array`,
can have interfaces attached to it from outside the type's declaration.
This is a Limelight extension; PHP has no such feature. Precedents: C#
extension methods, Kotlin extension functions, Rust trait impls on foreign
types.

- The attachment is resolved **purely by the compiler at compile time**;
  the fact is recorded in the type's class metadata.
- The runtime needs nothing new: at class link time the attached
  interface's itable is generated into the type's descriptor alongside the
  declared ones, and the ordinary itable dispatch serves it. A `string`
  passed as a `Comparable $x` parameter goes through exactly the machinery
  above.

---

## Dispatch Decision Tree

Chosen by the compiler per call site, in order of preference:

| # | Static knowledge | Dispatch |
|---|------------------|----------|
| 1 | Final class or final method | Direct call, no indirection |
| 2 | Concrete class known | `vtbl[slot]` |
| 3 | Interface known | Fat reference: `ref.itbl[slot]`; lookup paid once at conversion, not per call |
| 4 | Nothing (untyped receiver, `$obj->$name()`) | Inline cache → `methods` hashtable → `__call` |

Most PHP code is untyped, so path 4 with an effective inline cache is not an edge case: it is the common case, and paths 1–3 are the reward for type hints.

---

## Property Access

Each entry in `prop_layout` carries access flags: `plain` / `get-hook` / `set-hook` / `virtual`.

- **Plain property, type known**: load/store at constant offset. The fast path.
- **Hooked property** (PHP 8.4 `get`/`set` hooks): access compiles to a call through the hook's vtable slot. A `virtual` property has no backing slot at all, only hook calls.
- **Type unknown**: property inline cache (cache the class pointer → offset or hook slot), same mechanism as method ICs. Standard practice in JS engines.
- **`__get`/`__set`**: class-wide fallback, taken on `prop_layout` miss for classes whose magic-method bitmask has the corresponding bit set.
- **Asymmetric visibility** (`private(set)`): compile-time check only; no runtime representation, the byte layout is identical.
- **`readonly`**: a compile-time fact, and the byte layout is identical. On a statically-resolved write the compiler enforces the write-once rule directly, usually with no runtime code at all. The dynamic paths that do not know the property statically — `$obj->$name = …`, `ReflectionProperty::setValue()` — read the `readonly` flag from `prop_layout` (the metadata is there for exactly this) and enforce at runtime. "First write vs violation" is not a new mechanism: it is the property's uninitialized state (a `NULL` non-nullable pointer, an init-bitmap bit, a ValueBox `undef` flag) — a write to an uninitialized readonly slot is the one allowed initialization, a write to an initialized one throws.
- **Dynamic properties**: only `stdClass` and classes marked `#[AllowDynamicProperties]` carry one hidden object slot holding a lazily-allocated hashtable (name → value). All other classes do not have the slot at all; zero cost for the common case.

---

## Interned Names

All names known at compile time (classes, methods, properties, interfaces) are interned into the **immortal region** as immortal strings: one string = one address for the lifetime of the process. The region is load-bearing twice over — it is what makes the address permanent, and [values.md](values.md)'s COW rule branches on the category, taking the immortal arm (count pinned, a write always separates) rather than the long-lived one.

- Name equality **between interned names** = pointer compare, no `memcmp`. The qualifier is load-bearing; see the runtime-built name below.
- The hash is computed once and stored next to the string.
- Immortal strings generate zero refcount traffic (flags category `11`).

### A runtime-built name is matched, never interned

**Decision**: a name string constructed at runtime — `$obj->$name()`, `$obj->{$expr}`, `call_user_func` — is **canonicalized by one comparison at the boundary and never enters the immortal region**. The slow path hashes it, probes `methods` by that hash, and confirms the candidate by length plus `memcmp` against the interned key. On a match the search proceeds with the canonical interned pointer, so every path downstream still compares by pointer; on a miss it goes to `__call` or the error.

**Why not the two options this replaces.** *Interning on first use* makes an append-only, never-freed, process-wide table reachable from attacker-shaped input in a long-lived worker — and in the crate as it stands it is worse than unbounded growth: `immortal_alloc` refuses nothing above one block payload, so `$obj->{str_repeat('a', 100000)}()` would terminate the worker rather than raise. It also puts a global lock on a dispatch path. *Hash-only matching* keeps the table clean but breaks the pointer-equality invariant above in the direction that cannot be detected: two distinct names sharing a 64-bit hash resolve to each other, so `$obj->$a` reads `$b`'s property. Constructed collisions in this hash family are the premise of the array table's own flood defense ([arrays-hashtable.md](arrays-hashtable.md)), so this is a reachable case, not a theoretical one.

**What it costs**: one `memcmp` on a path that is already the slow path, and no pointer identity for a dynamically built name — a site that dispatches the same constructed name repeatedly pays hash plus `memcmp` every time. Whether such sites are common enough to earn a per-site cache keyed on (class, name) is a question for profiling, not for now.

---

## Inline Caches

Monomorphic IC per call site / property access site, holding the pair (class pointer, resolved target). Hit = one pointer compare + direct jump.

**The site is one word holding a pointer to that pair, not two words holding its halves** — the pair is immutable, baked at class link time beside its method-table entry, so a site update publishes a complete record rather than assembling one in place. Two independent mutable words would let a reader on one thread pair another thread's class with a third thread's target and dispatch the wrong method silently; the IR, the ordering and the alternatives are in [lowering.md](lowering.md), "Unknown receiver".

Three already-made decisions make ICs unusually cheap in Limelight:

1. **Non-moving GC** ([heap-design.md](gc/heap-design.md)): class descriptors and direct-pointer objects never move, so a cached class pointer cannot be invalidated by relocation (a movable-proxy target keeps the same class-pointer value regardless).
2. **Classes are immutable after link**: PHP has no runtime monkey-patching of class methods. A conditionally-declared class (`if (...) { class A {} }`) produces a distinct descriptor at link time.
3. **Descriptors are immortal** ("Class Descriptor" above): an address is never recycled, so a stale cache entry cannot become a *false* hit on a different class.

Consequently the class half of an IC never requires an invalidation mechanism. **The target half requires one invariant, which is stated because it is the thing a tiering JIT would break: compiled code is immortal.** Phase 1 is pure AOT and satisfies it trivially. `lowering.md` carries what changes if that ever stops being true.

---

## Lazy Objects: Ghost and Proxy

PHP 8.4 introduces lazy objects (`ReflectionClass::newLazyGhost` /
`newLazyProxy`): an instance that defers real initialization until first
touch. Two shapes, two different mechanisms here.

### Proxy — no new mechanism

A proxy is a separate wrapper instance with its own fixed class; it holds
one field pointing at the real (not yet constructed) instance, using the
existing `UNINIT` slot state ([values.md](values.md)). First forwarded
call materializes the real instance and stores it; the field transitions
`UNINIT → initialized` exactly like any lazily-initialized typed property.
No conflict with anything already decided.

### Ghost — class-pointer swap, opt-in cost

A ghost object preserves the target class's identity (`instanceof` must
match the real class, not a wrapper). The object is allocated at full
size up front, but its `class` field initially points at a **generated
ghost-shim** descriptor for that class: same `object_size`, a `vtbl`
whose every slot runs the initializer then rewrites `class` back to the
real descriptor before retrying the call. After first touch, the object
is indistinguishable from an eagerly-constructed instance: zero ongoing
cost.

The shim must carry the **same `traced_runs`, `display`,
`destruct_slot` and `dispose`** as the real class, not only its
`object_size`. A ghost can be traced or torn down before it is ever
touched — the collector reaches it through `obj->class` = the shim — and
its body is zero-filled, i.e. every slot reads as uninitialized (a
`NULL` pointer, a clear init bit), which the stride's `NULL`-skip
handles. So the shim traces and frees exactly as the real class would
for an all-uninitialized instance; a `dispose` on an untouched ghost
runs no user `__destruct` (its `DESTRUCTOR_PENDING` is unset until the
constructor completes) and releases nothing (all slots `NULL`). Entity
kind is lazy until first touch, then object — see the flags
layout above.

A `clone` of an *untouched* ghost must not copy the shim pointer as an
ordinary field (that would make the copy a second ghost that re-runs
`__construct` on first touch). Cloning forces materialization first,
then clones the real instance.

**Cost against `!invariant.load`**: the annotation on the class-pointer
load ([lowering.md](lowering.md)) assumes "an object's class never changes
after construction", and a ghost's does. Resolution: a per-class opt-in
flag (alongside `has-destructor` in the flags bitmask) marks a class as
ghost-capable. Only instances of flagged classes lose `!invariant.load` on
their class-pointer loads; the overwhelming majority of classes, never
used as ghosts, keep the full optimization. `lowering.md` carries the
matching exception, and it is what settles the shim as the design: it
names the exempt case as a class "whose class pointer is rewritten on
first touch", which describes the shim and nothing else.

### `instanceof` under Ghost/Proxy

`instanceof` (and `get_class()`, reflection) must report the **target**
class identity in both shapes, never the physical ghost-shim descriptor
or a generic proxy-wrapper descriptor. For Ghost this falls out of the
swap itself once triggered by the check; before the first touch,
`instanceof` triggers initialization like any other access (the shim's
"vtbl slot" for the type-check path is not exempt). For Proxy,
`instanceof` reads the target class recorded on the proxy, not the
proxy's own class.

---

## Deferred

Resolved design questions live in the sections above. Intentionally postponed:

- **Optimistic devirtualization of `static::` call sites** with patching on subclass load: JIT phase.
- **Interning of runtime-built name strings** (intern on first use vs hash-only matching): decide during stdlib work.
- **Class-as-object model (metaclass)**: representing the class itself as an object implementing a runtime interface: `__new` as the allocator, `__dispose`, reflection entry point (see the design story). The allocator and destructor are concrete as the `factory` / `dispose` of the lifecycle family ("Construction and Teardown"); what stays deferred is exposing the class *as an object*. Needs full design before inclusion: interaction with the memory manager and the immutable-after-link guarantee that inline caches rely on.

Lowering of this model to concrete C structures and LLVM IR is specified in [lowering.md](lowering.md).
