# Class and Object Model

## Scope

Defines the low-level representation of PHP classes and objects: object layout, class descriptors, method dispatch (vtables and interface tables), and property access including PHP 8.4 property hooks.

Value representation for scalars, strings, and arrays is covered separately. Memory categories and GC coordination are defined in [arenas.md](memory/arenas.md) and [heap-design.md](../gc/heap-design.md).

---

## Common Refcounted Header

**Decision**: Every heap-managed entity (object, string, array, closure, reference) begins with the same 8-byte header at offset 0. Zero-abstraction `#[FFI]` entities are outside this rule: they carry no header at all ([zero-abstraction.md](memory/zero-abstraction.md)).

```
+0  refcount  u32
+4  flags     u32  (atomic)
```

**Why**: retain/release becomes a single type-agnostic code path: it operates on offset 0 of any counted entity without knowing its type. Zend (`zend_refcounted_h`) and CPython (`ob_refcnt` first) use the same layout for the same reason.

### Flags layout

| Bits | Meaning |
|------|---------|
| 0–1 | Memory category: `00` GC heap, `01` request arena, `10` long-lived, `11` immortal |
| 2–3 | GC state: `LIVE` / `SCANNING` / `DEAD`, the CAS handoff field (see [heap-design.md](../gc/heap-design.md)) |
| 4–5 | Cycle collector color |
| 6 | Cycle collector buffered bit |
| 7 | Has weak references (side table exists) |
| 8 | **Owes a `__destruct`** — set only when the user constructor has returned successfully, and what every teardown path dispatches on, not just the arena's ([object-lifecycle.md](../runtime/object-lifecycle.md)) |
| 9 | Copy-on-write: counted in every memory category |
| 10 | `__destruct` has already run (exactly-once guard) |
| 11 | Transient mark: part of the escaped subgraph during arena reset |
| 12 | The entity is an object (has a class pointer at +8) |
| 13 | Live escapee: `refcount` currently holds the escape hold-count |
| 14–31 | Position in the cycle collector's candidate buffer, as `index + 1`; zero means "position unknown" and costs a linear scan |

Nothing is reserved: bits 14–31 are the candidate index, so a new
per-object flag needs either a freed bit or a *class* flag, which has
room.

The retain/release fast path is a single branch covering both arenas and immortal objects, with one exception:

```
if ((flags & 0b11) && !(flags & COW)) return;   // non-zero category → no counting
```

This implements the immortal-object and arena-scoping optimizations from [arc-optimizations.md](memory/arc-optimizations.md) with one check.

---

## Object Layout

```
+0   refcounted header                      (8 B)
+8   class: pointer to Class descriptor     (8 B)
+16  declared property slots, fixed offsets
```

An object instance contains only per-instance state: refcount, flags, and property values. Everything shared between instances (name, methods, interfaces, reflection metadata) lives in the Class descriptor, reached through the single `class` pointer.

The class pointer is required at runtime because PHP is dynamically typed:

- `$obj->foo()` on an untyped receiver: the vtable can only be found through the object itself
- `instanceof`, `get_class()`: read the pointer directly
- GC scanning: the property layout (which slots hold references) is described by the class
- destruction: `__destruct` is found through the class

Declared properties occupy fixed slots at offsets computed at class link time. `$this->x` with a known type compiles to a load/store at a constant offset, no hashtable involved.

**Class references are full 8-byte pointers (final decision).** Compressed class ids (u32 index into a global class table, as in the JVM) were considered and rejected: the 4 saved bytes per object do not justify an extra dependent load on every dispatch and a global table on the hottest path. Simpler and more flexible.

**No object table.** Objects are referenced only by direct pointers: there is no analog of Zend's object store with handles. PHP 7 itself moved object access from handles to direct pointers for performance; the store's remaining duties are covered differently in Limelight: object enumeration by linear Immix block scanning (see [heap-design.md](../gc/heap-design.md)), shutdown/arena-reset destructors by the has-destructor flag bit, weak references by side tables. Non-moving GC means object addresses are stable for the object's lifetime, so `spl_object_id()` can be derived from the address.

### Slot kinds

**Decision**: a property slot is the machine representation of the
property's declared type, and nothing more. The 16-byte Box
([values.md](values.md)) appears inside an object **only** where the
property has no declared type — that is the one storage site in an
object where the type is not known statically.

| Declared as | Slot | Size / align |
|---|---|---|
| `int`, `float` | raw `i64` / `f64`, no tag | 8 / 8 |
| declared class type, `string`, `array` | bare pointer | 8 / 8 |
| `?T` for pointer-shaped `T` | the same pointer; `NULL` is PHP `null`, `1` is `UNINIT` (niche) | 8 / 8 |
| `?int`, `?float` | payload; the discriminant lives in the byte block | 8 / 8 + 1 bit-or-byte |
| `bool` | a byte, or a bit in the byte block (below) | 1 / 1 |
| untyped / `mixed` | Box | 16 / 8 |
| hooked property with no backing store (`virtual`) | none | 0 |

A typed property therefore costs what its type costs. An object with
four `int` fields is 16 bytes of header plus 32 bytes of payload, not
16 plus 64.

### Slot order

**Decision**: a class lays out its own properties in three runs —
**counted pointers, then Boxes, then everything else in declaration
order** — and the byte block last.

```
+0   header (8) | class (8)
     counted pointers          ← contiguous run
     Boxes                     ← contiguous run
     remaining slots, in declaration order
     byte block: init bits, ?scalar discriminants, packed bools
```

Two things follow, and they are the reason for the grouping:

- **Initialization is one range.** A counted pointer must start as
  `NULL` or teardown would release garbage; a Box must start as the
  `null` tag. Both are all-zero bit patterns, so the two runs are
  cleared by a single store of a contiguous range. Raw scalars are
  **not** initialized at all: the compiler proves them assigned before
  use, or the property is tracked by the init bitmap.
- **GC tracing and teardown read ranges, not metadata.** The descriptor
  carries `(offset, count)` pairs; the collector strides them. No
  per-property flag is consulted on that path. This is HotSpot's
  `OopMapBlock` and V8's `FixedBodyDescriptor`, for the same reason.

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
inside what looks like the parent's trailing padding. Cloning and
copying always walk the *target* class's `prop_layout`.

### The byte block

One trailing region of the object holds everything that is smaller than
a slot: the init bitmap ([values.md](values.md)), the discriminants of
`?int` / `?float` properties, and packed `bool`s where the compiler
chooses to pack them. It is allocated from the same hole-filling pass
as the small slots, so in most classes it lands in alignment padding
and costs nothing.

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
3. **Place** the runs in order — counted pointers, Boxes, then the rest
   in declaration order. For each slot: align the cursor up, record any
   skipped interval as a hole, take the slot, advance.
4. **Fill holes** with 4/2/1-byte slots and the byte block before
   extending the cursor. Pointers and Boxes are never placed into a
   hole: that would break the contiguity of the runs.
5. **Finish**: `layout_end` is the cursor, `object_size` is it rounded
   up to 8.
6. **Record** the run table: the parent's `(offset, count)` pairs plus
   at most one pair of this class's own, for each of the two traced
   kinds.

---

## Class Descriptor

**Decision**: One descriptor per class, allocated in the long-lived arena at class link time. Its address is stable for the lifetime of the process; this is the foundation for inline caches (see below).

### Fields

Hot part (touched by dispatch and property access):

| Field | Purpose |
|-------|---------|
| `flags` | `final`, `abstract`, `interface` + magic-method presence bitmask (`__call`, `__get`, `__set`, `__destruct`, …) |
| `parent` | Parent class: inheritance chain for `instanceof`, `parent::`, vtable construction |
| `object_size` | Allocation size for instances |
| `layout_end` | First free byte, unrounded: where a subclass resumes laying out |
| `prop_layout` | Property table: name → (offset, slot kind, hook flags, declaration index) |
| `traced_runs` | `(offset, count)` pairs for the counted-pointer and Box runs: what initialization, GC tracing and teardown stride |
| `interfaces` | Sorted array: interface id → itable pointer |
| `methods` | Hashtable: name → method; slow path lookup, also the source for building subclass vtables |
| `statics` | Static properties and class constants |
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

### Offsets instead of pointers

All class metadata lives in the long-lived arena. Internal references between metadata structures (class → parent, class → itable, class → name) may be stored as u32 offsets from the arena base instead of 64-bit pointers: 4 bytes instead of 8, at the cost of one add per dereference. Constraint: metadata arena ≤ 4 GB.

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
- **Dynamic properties**: only `stdClass` and classes marked `#[AllowDynamicProperties]` carry one hidden object slot holding a lazily-allocated hashtable (name → value). All other classes do not have the slot at all; zero cost for the common case.

---

## Interned Names

All names known at compile time (classes, methods, properties, interfaces) are interned into the long-lived arena as **immortal strings**: one string = one address for the lifetime of the process.

- Name equality = pointer compare, no `memcmp`.
- The hash is computed once and stored next to the string.
- Immortal strings generate zero refcount traffic (flags category `11`).

Slow-path lookups (`$obj->$name()`, `__call`, dynamic property access) compare against interned names; a name string constructed at runtime is interned (or matched by precomputed hash) before the search.

---

## Inline Caches

Monomorphic IC per call site / property access site: cache the pair (class pointer, resolved target). Hit = one pointer compare + direct jump.

Two already-made decisions make ICs unusually cheap in Limelight:

1. **Non-moving GC** ([heap-design.md](../gc/heap-design.md)): object and class addresses never change; a cached class pointer cannot be invalidated by relocation.
2. **Classes are immutable after link**: PHP has no runtime monkey-patching of class methods. A conditionally-declared class (`if (...) { class A {} }`) produces a distinct descriptor at link time. Consequently ICs never require an invalidation mechanism.

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

**Conflict**: this contradicts the `!invariant.load` annotation on the
class-pointer load ([lowering.md](lowering.md)), which assumes "an
object's class never changes after construction." Resolution: a per-class
opt-in flag (alongside `has-destructor` in the flags bitmask) marks a
class as ghost-capable. Only instances of flagged classes lose
`!invariant.load` on their class-pointer loads; the overwhelming majority
of classes, never used as ghosts, keep the full optimization.

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
- **Class-as-object model (metaclass)**: representing the class itself as an object implementing a runtime interface: `__new` as the allocator, `__dispose`, reflection entry point (see the design story). Needs full design before inclusion: interaction with the memory manager and the immutable-after-link guarantee that inline caches rely on.

Lowering of this model to concrete C structures and LLVM IR is specified in [lowering.md](lowering.md).
