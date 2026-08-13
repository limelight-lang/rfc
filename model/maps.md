# Maps

## Scope

`Map` and `MapMixed`: two classes the runtime provides, each an ordered
hash whose keys are wider than an array's. This document fixes what they
are to the runtime, what a key may be, how each key kind is hashed and
compared, who owns a key, and what copying one means.

The table underneath them is not redesigned here. It is the ordered hash
of [arrays-hashtable.md](arrays-hashtable.md), unchanged: one allocation
of `u32` index slots over a dense array of 32-byte entries in insertion
order. The class descriptor and its behaviour pointers are
[classes.md](classes.md). The value representation is
[values.md](values.md), and the arena rules a key crosses are
[memory/arenas.md](memory/arenas.md).

One dependency is named rather than assumed: a map's entries lie outside
the entity, so the collector reaches them only through the optional
`walk` hook on the class descriptor. That hook is `ll-model`'s stage S18,
raised for a coroutine whose waker cells lie outside its object. This
design may be read before the hook exists; it cannot be built before it.

---

## Two classes, and the border between them

**Decision**: two classes, with no inheritance between them.

| Class | Keys | Equality |
|---|---|---|
| `Map` | object | address |
| `MapMixed` | integer, string, object, array | value, bytes, address, content |

The border is not how many kinds each admits. It is where equality comes
from. An object key is equal by address, so `Map` has no key kind to
dispatch on, no numeric-string canonicalisation, no string-key ownership,
and one shape of counted child. An array key is equal by content, which
is what brings in a content hash and a recursive walk, and `MapMixed`
pays for that alone. This is the shape `SplObjectStorage` has; it falls
out of the border rather than being aimed at.

**Integer and string keys with reference semantics are not a gap.** An
array already serves them. What an array does not offer is a second name
rather than a value, and a program that wants that with string keys takes
a `MapMixed`.

**One class with a set of admitted kinds was refused.** The admitted set
would be tested on every write, the content-hash machinery would be
linked into maps that never see an array key, and hashing a key would
become a dispatch ahead of every lookup.

**Inheritance was refused because it runs the wrong way.** `MapMixed`
admits more keys, so substituting one where a `Map` is expected is safe
for writing and unsafe for reading: a reader of `Map`'s keys is entitled
to assume they are objects.

---

## What a map is to the runtime

**Decision**: a map is an ordinary object. Entity kind `Object`, a class
the runtime provides, and the crate's generic table in its body. No kind
code of its own, and not a fourth storage strategy of the array kind.

What that buys is everything the object machinery already does. Teardown
is the descriptor's `dispose`. The rc-trace candidate gate already admits
`Object`, so a ring closing through a map is collected by the pass that
exists. Promotion, the walk and the store barrier serve objects already.
The table itself costs nothing to reuse: it allocates no entity, calls no
store barrier and names no entity kind, which is what it was made
parameter-by-parameter to be.

A kind code of its own would have bought the opposite. Every kind switch
in the runtime gains an arm, and each arm is a place where an omission
leaks rather than fails. The code space is nearly spent: `7` is reserved
and `4`–`6` are the family the model wants consolidated.

**Iteration order is insertion order**, because the table's is. A map
inherits it rather than promising it separately.

---

## The cells that lie outside the entity

A map's counted children are its entries: every key that is an entity,
and every value. They live in the table's chunk, which is not inside the
object, so `ptr_runs` and `box_runs` cannot describe them. The class
descriptor's `walk` hook is how a walker reaches them, and three of its
rules are the map's:

- **It yields cells, not children.** The collector records a cell's
  address and its raw word and re-reads both in Phase 3, so a hook that
  yielded only the child could not serve it.
- **The chunk is not freed while an epoch is in flight.** It goes through
  `deferred_free`, which exists for exactly this.
- **Keys and values pass through it alike.** A key that is an entity is a
  counted child with no lesser standing than a value, and a walk that
  yields values only leaks a ring closing through a key, with no pass
  able to find it.

The hook is inherited the way `dispose` is, so a subclass of a map class
is walked without redeclaring anything.

---

## The four key kinds

| Kind | Bucket from | Equality |
|---|---|---|
| integer | the value, until the flood ladder draws a salt | the value |
| string | the hash cached in the string entity at +16 | the bytes, after the full hash agrees |
| object | the object's id, rotated | the address |
| array | the content hash stored in the entry | the content, after the full hash agrees |

**An object key's identity already exists.** `spl_object_id` is derived
from the address while the object stays put, stored lazily in the object
and carried with it when an arena reset evacuates one
([memory/arena-reset.md](memory/arena-reset.md)). So the hash of an
object key is that id and equality is pointer equality. No user code runs
on the lookup path, which is what separates this from a map keyed by
`__equals`.

**The id is rotated before it indexes.** Entity slots are aligned and
evenly spaced, so the low bits of an address carry almost no entropy, and
indexing by the id as it stands would seat neighbouring objects in
neighbouring buckets. A rotation is one instruction and it is a
bijection, so it loses nothing. The amount is chosen against the slot
stride and is arithmetic rather than a decision.

**Against a deliberate flood the rotation does nothing**, being a
bijection with no salt, and it does not have to. An object key is a key
like an integer key, and the table's existing ladder covers both: a table
starts unsalted, counts on each insert the entries whose full 64-bit hash
equals the new key's, and on the threshold escalates once to a keyed hash
over the key bytes. Maps build nothing new for flooding.

---

## Where `MapMixed` reads a key's kind

**Decision**: in the low bits of the `key` word, which the walker already
reads atomically and already tests by value.

The array's entry distinguishes three states in that word: `0` is an
integer key, `1` is a hole, and anything above is a string pointer. That
last test is the one a *walker* makes on the raw word, and an object
pointer passes it, so a map that stored one there would hand the tracer
an `LLString` that is an object. The kind has to be readable from the
word itself.

Every heap size class is a multiple of 16 bytes and the block payload
begins on a 64-byte line, so every entity slot is 16-byte aligned and the
low four bits of any entity pointer are zero. `MapMixed` spends three of
them:

```text
word < 8            0 = integer key, 1 = hole   (unchanged)
word & 7 == 1       string  pointer is word & !7
word & 7 == 2       object  pointer is word & !7
word & 7 == 3       array   pointer is word & !7
```

A tagged pointer is never below 8, so it cannot be confused with either
sentinel, and the sentinels keep the values the array's entry gives them.
A walker pays one AND and one compare, on a word it has loaded anyway.

**A second word was refused.** The entry is 32 bytes, which is what puts
its per-element cost at parity with `zend_array` 7.3+, and a fifth word
would spend that to save one AND.

**The two spare bytes in the element's second word were refused.** They
sit in the word that carries the value's tag, flags and collision link,
written as one relaxed atomic store of the width the collector loads, and
they are specified to read back as zero so that a Box handed out of an
entry is bit-identical to one a constructor built. Putting the *key's*
kind in the *value's* word also crosses a boundary the entry keeps.

`Map` encodes nothing. Every key it holds is an object, the class says
so, and the word is the pointer.

---

## The content hash of an array key

**Decision**: it lives in the map's own entry, in `hash_or_key`, and the
array entity gains no field, no bit and no byte.

It is computed once, on the insert path, by a content walk that works
through an explicit list in a buffer-arena chunk and refuses like any
allocation. Never the machine stack: nesting depth is the program's
input on a store path, and a frame set per level is a stack overflow that
a refusal is not. A lookup hashes its probe afresh, which is the O(size)
a value key costs in any case, the confirming comparison being O(size)
regardless.

**Nothing invalidates the stored hash, and nothing can.** The entry
retains the key, so any prospective writer names an array whose count is
at least two, and the separation test makes that write copy first: the
map's key is never mutated in place. The freeze is transitive, because a
nested child with any external name has a count of two itself, and one at
count one is reachable only through the frozen parent. The insert-path
window where the count may still be one is closed by a different
argument: hashing runs no user code, so the walk and the retain are one
uninterrupted mutator sequence.

**The table's own moves preserve it.** Growth and compaction copy whole
entries, and the index is rebuilt from the stored hash rather than from
the key's bytes. This is the mechanism a string key's cached hash already
rides.

**A lazy cache in the array entity was refused**, guarded by a "not
computed" bit as a string's hash is at +16. There is no free header bit
in either build configuration, and behind the ledger stood a price the
option was never worth: an invalidation store on every array write, a
path that has nothing to do with maps, paid by the overwhelming majority
of arrays that never become a key.

**Equality stops early.** Two content hashes differ for almost every
pair, so the structural walk runs only after 64 bits already agree,
exactly as a string key's byte comparison does.

---

## A key is a counted child

A map owes a reference to every key that is an entity, on the same terms
as it owes one to every value:

- **Insert** retains the key, and publishes it through the store barrier
  rather than retaining it bare, so that an arena key entering a
  longer-lived map takes the route its category requires.
- **Overwrite** leaves the key alone. The entry keeps the key it was
  found by; only the value changes.
- **Remove** drops the key's reference and the value's, in that order,
  and marks the entry a hole.
- **Sever** hands both out to the caller without releasing them, which is
  the collector's Phase 4 contract for any entity.

A key at count one inside a map is impossible by construction for arrays
and unremarkable for objects: the map's own reference is the count, and
an object key whose only holder is the map dies with it.

---

## Copying, and the COW attribute

**Decision**: copy-on-write is an attribute of a map's class, not a
property of the type.

Without the attribute a map behaves as any object does. `$b = $a` is a
second name, a write through either is seen through both, and nothing is
copied. This is the default.

With the attribute, assignment must yield an independent map, which is
the whole content of the attribute and the only reason a copy exists.
Two doors then apply, and they are the array's two:

**Separation on write copies the container.** A new map entity, a new
chunk, the entries moved across, and every key and every value retained.
Nothing below the entries is duplicated, and both maps go on naming the
same keys and the same values.

**The escape copy is deep, in the category-driven sense.** A map taken
out of the request arena by a longer-lived holder republishes each entry
through the barrier with the destination's category, so an arena
copy-on-write child is copied out, an arena object or reference box takes
the hold-count route, and a heap or immortal child is merely retained.
Keys and values go through that door on one rule; there is no asymmetry
between them. A copied array key is equal by content to the original, so
the hash stored in the entry survives the copy: it names content, not an
address.

**The class owes two bodies for the attribute**, `clone` and
`deep_clone` on the descriptor, the lifecycle slots reserved and never
filled. The deep one drains an explicit list rather than the machine
stack, for the reason the array's does.

---

## Open

- **The rotation amount for an object key's id.** Arithmetic against the
  slot stride, and it wants the measurement that shows the seating rather
  than an argument.
- **`WeakMap`.** A weak key needs the weak table's row to widen from one
  cell to a subscriber list ([weak-references.md](weak-references.md)),
  and nothing is decided here.
- **Whether `Map` keys may be weak by attribute**, which is the same
  question asked of the class rather than of a second class.
- **The construction surface**: what a runtime-provided class looks like
  to the compiler, and whether a map literal exists in the language.
