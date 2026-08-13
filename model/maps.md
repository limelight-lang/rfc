# Maps

## Scope

`Map` and `MapMixed`: two classes the runtime provides, each an ordered
hash whose keys are wider than an array's. This document fixes what they
are to the runtime, what a key may be, how each key kind is hashed and
compared, who owns a key, what copying one means, and what the table
underneath them has to change to serve a second customer.

The table is the ordered hash of
[arrays-hashtable.md](arrays-hashtable.md): one allocation of `u32` index
slots over a dense array of 32-byte entries in insertion order. Its shape
does not change. One field's encoding does, and the section "The key word
gains a tag, for every owner" says exactly which readers move with it.

The class descriptor and its behaviour pointers are
[classes.md](classes.md). The value representation is
[values.md](values.md). The arena rules a key crosses are
[memory/arenas.md](memory/arenas.md).

Two dependencies are named rather than assumed. A map's entries lie
outside the entity, so the collector reaches them only through the
optional hook family on the class descriptor, which is `ll-model`'s stage
S18, raised for a coroutine whose waker cells lie outside its object.
This design may be read before that hook exists; it cannot be built
before it, and it widens what the hook owes — see "The cells that lie
outside the entity". The second is `Object::object_id`, in the Open
section, because address equality is the whole of `Map`'s equality and
the address is not yet stable under every reset.

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

What that buys is the object machinery: teardown through the descriptor's
`dispose`, admission to the rc-trace candidate buffer, which already
takes `Object`, and promotion and the store barrier as they stand. The
table costs nothing to reuse in its shape: it allocates no entity, calls
no store barrier and names no entity kind.

A kind code of its own would have bought the opposite. Every kind switch
in the runtime gains an arm, and each arm is a place where an omission
leaks rather than fails. The code space is nearly spent: `7` is reserved
and `4`–`6` are the family the model wants consolidated.

**Iteration order is insertion order**, because the table's is. A map
inherits it rather than promising it separately.

**A map's body is opaque to the slot machinery.** A class declares its
body as runs of scalars, pointers, boxes and bools; a map's body is a
storage head and a table tail, which is none of those. The descriptor
therefore needs a way to say "these bytes are mine and no run describes
them", and the storage head's own rule travels with it: no `&mut` may
span the head, because a concurrent walker reads those words. Both are
requirements this design places on the descriptor, listed again under
"What S18 owes a map".

---

## The cells that lie outside the entity

A map's counted children are its entries: every key that is an entity,
and every value. They live in the table's chunk, outside the object,
where `ptr_runs` and `box_runs` cannot describe them. Three consumers
reach an object's cells today, and each needs something different from a
class whose cells are elsewhere.

**Reading, for the tracer.** The `walk` hook yields cells rather than
children, because the collector records a cell's address and its raw word
and re-reads both in Phase 3. Keys and values pass through it alike: a
key that is an entity is a counted child with no lesser standing than a
value, and a walk that yields values only leaks a ring closing through a
key with no pass able to find it.

**Reading with a version, for Phase 3.** A map's chunk moves under growth
and compaction exactly as an array's does, so a walk of a map must answer
the version it read at, and the re-check must be able to ask the same
question again later. The array's answer is `trace_cells` returning the
storage version and the epoch keeping one per walked row; the object arm
answers nothing today, and nothing is read by Phase 3 as a guarantee that
there is no storage to re-check. For a map that guarantee is false. So
the class answers the version when it is walked, and answers "is this
still the version you gave me" when Phase 3 asks — through the
descriptor, not by casting the entity to an array and taking a fixed
offset, which for a map object lands in whatever the class laid out
there.

**Writing, for the sever.** This is the one the generic path cannot do at
all. Phase 4 severs an object by writing a null into each cell, and a
table entry cannot be emptied that way: the barrier's whole-Box store
would zero the reserved bytes that carry the entry's chain link, making
it a self-referencing chain, and a null in the key word reads as
`KEY_INT`, which leaves a live integer-keyed entry rather than a hole and
`live` stale. The array has its own sever arm for exactly these two
reasons. A map needs the same, so a class whose cells lie outside itself
owes a sever body of its own, and the generic cell-nulling stays correct
only for cells inside the entity.

**The chunk is not freed while an epoch is in flight.** It goes through
`deferred_free`, which exists for this.

The hooks are inherited the way `dispose` is, so a subclass of a map
class is walked, re-checked and severed without redeclaring anything.

---

## The four key kinds

| Kind | Identity in `hash_or_key` | Slot from | Equality |
|---|---|---|---|
| integer | the value | the value, or the salted mix once the ladder has fired | the value |
| string | the full 64-bit hash | the same number, or a keyed hash over the bytes after escalation | the bytes, after the hash agrees |
| object | the id, rotated | the same number, or its salted mix once the ladder has fired | the address |
| array | the content hash | the same number, or its salted mix once the ladder has fired | the content, after the hash agrees |

`hash_or_key` holds the key's identity number in every row, and the slot
number is derived from it. Which derivation applies is a dispatch on the
key's tag, and only the string row may ever reach a hash over bytes. This
is a change to the table and it is stated as one under "What the flood
ladder becomes".

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
neighbouring buckets. A rotation is one instruction and a bijection, so
it loses nothing. The amount is chosen against the slot stride and is
arithmetic rather than a decision.

---

## What the flood ladder becomes

**Decision**: the ladder is kind-dispatched, and it is not inherited
unchanged. Rung one covers all four kinds. Rung two is a string-key rung
and must never be reached with any other kind.

The table's ladder counts, per insert, the entries whose full identity
number equals the new key's, and separately the length of the chain
walked. Rung one draws a per-table salt and rebuilds; rung two escalates
to a keyed hash over the key's bytes and rebuilds. As it stands the salt
enters only the integer path, and the escalated rebuild hashes the bytes
of every non-integer key it meets.

Both halves are wrong for a map, and the second is a wild read rather
than a wrong number. An object key's entry holds a pointer to an object;
handed to the byte hash it is read as a string, whose length field is the
object's class word. The first insert that escalates a `MapMixed` holding
one object key crashes the process, and so does every later growth,
because growth rebuilds the index too.

**Rung one, generalised.** The salt enters the slot derivation for every
kind: the slot is the salted mix of whatever `hash_or_key` holds. For an
integer that is the value, as today. For an object it is the rotated id.
For an array it is the stored content hash, which needs no re-walk — the
identity number is already there. For a string it is the full hash. One
rung, one mechanism, no key bytes read.

**Rung two, narrowed.** Escalating to a keyed hash over the key's bytes
is meaningful only where the identity *is* bytes, which is the string key
alone. An address has no bytes, and an array's content hash is already a
hash over its contents, so re-hashing it with the salt is rung one. For a
`Map`, the ladder therefore has one rung, and that is its whole flood
answer: a per-table secret over the rotated address makes bucket choice
unpredictable to a program that can only influence where objects are
allocated.

**What this obliges the table to do**: `entry_slot_hash` dispatches on
the key's tag, and its byte-hashing branch is reachable only from the
string tag. The assertion that it is unreachable otherwise belongs in the
code, because the failure is a read of unrelated memory rather than a
wrong answer.

---

## The key word gains a tag, for every owner

**Decision**: the `key` word carries the key's kind in its low three
bits, in an array as well as in a map. There is one encoding of that
field in the crate, not one per owner.

The array's entry distinguishes three states in that word today: `0` is
an integer key, `1` is a hole, and anything above is a string pointer.
Adding a fourth and a fifth state for a map alone would give the field
three encodings — untagged string, untagged object, tagged — sharing one
struct, one accessor and one set of callers, with nothing in an entry
saying which is in force. Every reader of the raw word would then be
correct for one owner and wrong for another: the key accessor hands the
pointer back unmasked, the key comparison would fail its pointer test and
fall into a byte compare at a misaligned address, removal would decrement
a tagged pointer, and the sever would push one into the displaced list.

```text
word < 8            0 = integer key, 1 = hole   (unchanged)
word & 7 == 1       string  pointer is word & !7
word & 7 == 2       object  pointer is word & !7
word & 7 == 3       array   pointer is word & !7
```

A tagged pointer is never below 8, so it cannot collide with either
sentinel, and the sentinels keep the values the array's entry gives them.

**What moves with it**, and this is the whole cost: the key accessor
masks, the key comparison dispatches on the tag instead of testing the
raw word against the hole sentinel, removal and the sever mask before
they hand a pointer out, and the slot hash dispatches as the section
above requires. An array produces tags 0, 1 and the string tag only, so
its lookup keeps the two-way shape it has — the tag replaces the
value test rather than adding a branch beside it. This does not
reintroduce the dispatch that refused the single-class design: that one
was a test of *admission*, on every write, against a per-instance set.

**A fifth word was refused.** The entry is 32 bytes, which is what puts
its per-element cost at parity with `zend_array` 7.3+, and a fifth word
would spend that to save one AND.

**The two spare bytes in the element's second word were refused.** They
sit in the word that carries the value's tag, flags and collision link,
written as one relaxed atomic store of the width the collector loads, and
they are specified to read back as zero so that a Box handed out of an
entry is bit-identical to one a constructor built. Putting the key's kind
in the value's word also crosses a boundary the entry keeps.

**Three bits is the budget, and there is no fourth.** Heap size classes
are multiples of 16 bytes and a large entity is allocated 16-aligned, so
a heap entity pointer has four zero low bits. A request-arena entity does
not: the arena rounds to 8 and a class's object size is aligned to 8, so
an arena object at an odd multiple of 8 has bit 3 set. Three bits is what
8-alignment gives and three bits is what the scheme spends. A fourth tag
requires forcing arena entity slots to 16 first; see Open.

---

## The content hash of an array key

**Decision**: the hash of an array key lives in the map's own entry, in
`hash_or_key`, and the array entity gains no field, no bit and no byte.

It is computed once, on the insert path, and a lookup computes the same
number for its probe **before the table is entered**. That ordering is
not incidental: the table's read path may not allocate and may not raise,
because a lookup runs under a live iterator on a shared table, and the
content walk allocates. So hashing a probe is the map method's work, the
table receives a number, and a refusal to hash raises before the table is
touched.

**The walk is over an explicit list in a buffer-arena chunk**, never the
machine stack, because nesting depth is the program's input on a store
path and a frame set per level is a stack overflow where a refusal is an
error a caller can see. It also carries a source-to-hash association
beside the list, one entry per distinct array met, for the same reason
the deep copy carries one: a structure whose children name each other
twice per level costs 2^depth walks without it and one walk per distinct
array with it.

### What the walk hashes, kind by kind

This is the definition of content equality for `MapMixed`, not an
implementation note.

- **Scalars** hash by value, **strings** by their cached hash.
- **A nested array** is descended into, in insertion order, hashing each
  key beside its value.
- **An object is hashed by its id, not by its properties.** So two
  distinct objects with equal properties make two distinct keys. This
  departs from PHP's `==` on arrays, which compares nested objects by
  class and property values, and it is deliberate: an object's properties
  change with no barrier and no count to freeze them, so a hash over them
  would be stale the moment after it was taken, with nothing able to
  notice.
- **A reference box is not allowed inside a key.** On insert, a box whose
  count is one is collapsed to the value it holds, exactly where the COW
  copy already collapses one. A box with a second name refuses the
  insert, because a write through that name changes the key's content
  without touching the array's count.

### Why nothing invalidates it

The entry retains the key, so any prospective writer of the array names
one whose count is at least two, and the separation test makes that write
copy first: the map's key is never mutated in place. The freeze is
transitive over what the walk descends into, because a nested array with
any external name has a count of two itself, and one at count one is
reachable only through the frozen parent. It does not need to extend to
objects, since they are hashed by identity, and it cannot be broken
through a reference box, since a key holds none.

The insert-path window where the count may still be one is closed by a
different argument: hashing runs no user code, so the walk and the retain
are one uninterrupted mutator sequence.

**Termination follows from the same two rules.** The walk descends only
into arrays, which are copy-on-write, and a cycle cannot close inside a
pure copy-on-write subgraph — every entity a real ring passes through is
non-copy-on-write, and the two ways an array reaches one, a reference box
and an object, are respectively refused and not descended into. So the
walk is over a finite directed acyclic graph, and the association makes
it linear in that graph rather than in its paths.

**The table's own moves preserve the stored number**, because growth and
compaction copy whole entries and the index is rebuilt from the stored
identity rather than from the key's bytes. This is the mechanism a string
key's cached hash already rides.

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

- **Insert** publishes the key through the store barrier rather than
  retaining it bare, so that an arena key entering a longer-lived map
  takes the route its category requires.
- **Overwrite** leaves the key alone. The entry keeps the key it was
  found by; only the value changes.
- **Remove** drops the key's reference and the value's, in that order,
  and marks the entry a hole.
- **Sever** hands both out to the caller without releasing them, through
  the class's own sever body rather than the generic cell-nulling, for
  the reasons under "The cells that lie outside the entity".

---

## Copying, and the COW attribute

**Decision**: copy-on-write is an attribute of a map's class, not a
property of the type. It decides what *assignment* does, and nothing
else.

Without the attribute a map is assigned as any object is: `$b = $a` is a
second name, a write through either is seen through both, and nothing is
copied. This is the default.

With the attribute, assignment must yield an independent map, which is
the whole content of the attribute and the only reason a separation
exists.

**`clone` is not the attribute's business, and a map class always carries
one.** The generic clone is a `memcpy` of the object's body followed by a
retain stride over the pointer runs. For a map that duplicates the
storage head and the table tail, giving two live maps over one chunk, two
writers into one entry array, and two disposes freeing it. So every map
class overrides `clone` with the body below, whether or not it is
copy-on-write.

**The copy copies the container.** A new map entity, a new chunk, the
entries moved across, and each key and each value **published into the
new entries through the store barrier with the destination's category**,
not retained bare. Where the destination's category equals the source's
that publication is a plain retain and costs nothing extra. Where it
differs it is the difference between a correct copy and dangling keys: a
heap holder separating an arena-resident map would otherwise take a bare
reference on an arena object, which the retain path declines to count at
all, and the next arena reset would free a key the heap map still names.

**The escape copy is the same body with a longer-lived destination.** It
republishes each entry through the barrier with the destination's
category, so an arena copy-on-write child is copied out, an arena object
or reference box takes the hold-count route, and a heap or immortal child
is merely retained. Keys and values go through it on one rule. A copied
array key is equal by content to the original, so the hash stored in the
entry survives the copy: it names content, not an address.

**Depth is the list's, not the stack's**, in the deep case, for the
reason the array's copy states.

---

## What S18 owes a map

Named here because a map is the hook's second customer and it asks for
more than the first:

1. A hook that yields **cells**, whose chunk is freed through
   `deferred_free` while an epoch is in flight. This is S18 as raised.
2. A **version** answered by the walk and re-askable in Phase 3, through
   the descriptor rather than by casting the entity to an array.
3. A **sever body** on the descriptor, because the generic cell-nulling
   corrupts a table entry two ways.
4. A way for a class to declare **body bytes no run describes**, and the
   storage head's no-`&mut` rule restated for an object body.

Points 2, 3 and 4 are additions to what S18.1 currently scopes.

---

## Open

- **The rotation amount for an object key's id.** Arithmetic against the
  slot stride, and it wants the measurement that shows the seating rather
  than an argument.
- **Which pointer a `Map`'s key word holds under a movable object.**
  `Object::object_id` is the raw address today, and arena-reset marks
  evacuation shelved in favour of a movable proxy. Address equality is
  the whole of `Map`'s equality, so the answer decides whether the key
  word holds the object or its proxy.
- **A fourth key tag**, which needs arena entity slots forced to 16-byte
  alignment first. Wanted only if weak keys become a tag rather than a
  class.
- **`WeakMap`**, which needs the weak table's row to widen from one cell
  to a subscriber list ([weak-references.md](weak-references.md)).
- **The construction surface**: what a runtime-provided class looks like
  to the compiler, and whether a map literal exists in the language.
