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

The class descriptor and its behavior pointers are
[classes.md](classes.md). The value representation is
[values.md](values.md). The arena rules a key crosses are
[memory/arenas.md](memory/arenas.md).

Two dependencies are named rather than assumed. A map's entries lie
outside the entity, so the collector reaches them only through the
optional hook family on the class descriptor, raised for a coroutine whose
waker cells lie outside its object and ruled on 2026-08-13
([`../dev/DECISIONS.md`](../dev/DECISIONS.md), "a class with cells outside
itself carries one flag and one group of five").
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
dispatch on, no numeric-string canonicalization, no string-key ownership,
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
"What the outside-cells hook owes a map".

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

**The hook supplements the generic stride; it does not replace it.** A
subclass of a map class declares properties of its own, and those live in
the pointer and box runs where the generic walk finds them. So all three
consumers run the runs first and the hook after, and the class's own head
and table tail are outside every run by the mechanism of point 4 below.
Replacing the stride would make a subclass's own properties invisible to
the tracer, which is a computed root and a ring that never collects.

**The head is read through its window.** The four words a walker needs
are published independently, so a reading taken outside the version
bracket can pair a freshly published chunk with the count that belonged
to the previous one and stride past the end of the entries. A map's hook
therefore reads the head the way the array's arm does: the bracketed
read, a bounded number of attempts, and the map given up for this epoch
when no coherent reading is obtained. Giving it up is the safe direction
and the array already takes it.

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

A subclass of a map class inherits the group, so it is walked,
re-checked, severed and freed without redeclaring anything. That is a
requirement rather than an observation: the descriptor builder seeds the
runs, the properties and the vtable from the parent and does not seed
`dispose`, so a subclass declaring none of its own gets the default one.
For a map subclass that would be the whole table leaked.

---

## The four key kinds

| Kind | Identity in `hash_or_key` | Slot from | Equality |
|---|---|---|---|
| integer | the value | the value, or its salted mix once the ladder has fired | the value |
| string | the full 64-bit hash | the same number, or its salted mix once the ladder has fired, or a keyed hash over the bytes after escalation | the bytes, after the hash agrees |
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

**Decision**: the ladder is kind-dispatched in its triggers as well as
its bodies, it gains a terminal rung, and every secret it draws comes
from a per-process key that no build option folds. Rung one covers all
four kinds. Rung two is a string rung, trigger and body both. Rung three
is refusal, and it is the answer for every kind once nothing rebuildable
remains.

**The two triggers measure two different failures**, and the ladder must
stop conflating them. The chain trigger sees keys whose identities differ
while their buckets coincide; a salt answers it for any kind, the
identities being separable. The equal-identity trigger sees keys whose
identity numbers agree while the keys differ, and only a kind whose
identity is a lossy hash can produce that: the string, whose identity
hashes its bytes, and the array, whose identity hashes its content. An
integer's identity is its value and an object's is its id, so for those
two equal identity means the same key, which is an overwrite and never an
entry in the walk. **The counter therefore counts an entry only when its
tag equals the incoming key's.** Counting any non-integer key, as the
array's table did before the tag test, is what let eight equal-content
arrays fire the string escalation.

**The identities, from birth.** An integer indexes by value, a string by
its cached hash, an object by its rotated id, and an array by a **keyed**
content hash under the per-process key. Inside that walk a string element
is hashed **by its bytes under the same key**, not by its cached hash: a
cached hash is a build constant under `hash-folding`, so a content hash
that consumed it would inherit offline-constructible collisions through
colliding strings however the outer mix were keyed. Hashing the bytes
closes that route and costs nothing asymptotically on a path that already
walks the structure. The content hash is keyed per process and by nothing
else, because the stored number must equal an independently computed
probe and must survive a copy, so no per-table component may enter it.

**Rung one, the chain trigger's first firing, all four kinds.** Draw the
per-table salt and rebuild. Every kind's slot becomes the salted mix of
its identity number, and no key bytes are read. The salt is a keyed hash
of the storage address under the per-process key rather than the plain
hash of it the array draws today, whose own note concedes that addresses
recycle across resets and that under `hash-folding` the seed inside it is
a build constant. With that one change rung one is a complete defense for
the two kinds whose identity is exact: an integer or object flood needs
bucket collisions, bucket choice needs the salt, and the salt needs the
key.

**Rung two, the equal-identity trigger over string entries, or the chain
trigger's second firing.** Escalate and rebuild: a string entry's slot
comes from the keyed hash over its bytes, under the per-process key
together with the table's salt. No other kind's derivation changes, and
the byte-hashing branch is asserted unreachable from any other tag,
because its failure is a read of unrelated memory rather than a wrong
number. An object key's entry holds a pointer to an object, and handed to
the byte hash it is read as a string whose length is the class word. The
string is the one kind that both has a colliding identity and can be
re-derived without allocating, and that conjunction is the whole reason
rung two exists.

**The array has no rung two, and no longer needs one.** Its identity is
keyed from birth, so equal array identities under different content are
not a hash accident to rebuild away from; eight of them are evidence that
the keyed function itself has failed, and re-mixing a broken number with
a salt separates nothing. The equal-identity trigger over array entries
fires rung three directly.

**Rung three, refusal.** It fires when a trigger trips and no rebuild
remains for the offending kind, which is four cases rather than three:
the equal-identity trigger over array entries, the equal-identity trigger
over string entries on a table that is already escalated, the chain
trigger's third firing, and the chain trigger's *first* on a table
escalated through the equal-identity trigger. That last case is the
principle rather than a stricter reading of it: escalation draws the salt
on its way, so such a table has both rebuilds behind it and has never met
a long chain. The insert is
refused with the table unchanged, on the insert's existing refusal
channel but distinguishable from an allocation refusal, and the runtime
raises it as a catchable error rather than as memory pressure. This is
the structural backstop [strings.md](strings.md) has promised since
before this design existed, bounded without depending on a secret, and it
replaces the state the code has today, where a spent ladder returns early
from both rungs and the chain then grows without bound forever. After
rung three no chain an admission can build exceeds the trigger's own
limit: exhausting the ladder caps the damage instead of removing the cap.

**A replay is exempt from the refusal, and from nothing else.** An insert
states which it is: the caller's own admission, or a re-derivation of a
key the table admitted once — the copy's entry replay, and the migration
that re-inserts a vector's positions. A key admitted once cannot be
refused on re-admission, because the refusal would drop an entry that is
already the program's, on an operation the program never performed.
Rungs one and two stay armed on a replay, so a table that still holds a
rebuild takes it. The exemption is paid for in the chain that occasioned
it: a replay past rung three grows one past the trigger's limit, and what
returns it is the copy rule below rather than another rung.

**A copy keeps both rung bits and draws its own salt.** The bits are the
ladder's bound and travel with the key set the copy takes whole; a copy
that started weak would hand an attacker an unescalated table for the
asking. The salt does not travel, because the copy replays every key by
hand: under the source's number the source's chains are reproduced slot
for slot, and with both rungs spent and the replay exempt nothing would
rebuild them away, so the chain would be heritable one copy to the next.

**The copy's storage is sized by its own live count**, through the growth
schedule, and not by the chunk the source holds. Taking the source's slot
count was tried and withdrawn (`dev/DECISIONS.md` in the crate, "a copy
sizes its storage by its own replay"): it was meant to keep apart buckets
that a narrower mask merges, and a mask cannot supply that defense.
Identities that differ are scattered by the copy's own salt whatever the
width; identities that agree collide at every width and are what the
equal-identity trigger answers; and where the salt is known — the oracle
below — a colliding set is forged against any mask as cheaply as against
any other. A copy with no live entry takes no chunk at all, unless it
inherited a drawn rung bit, the draw needing an address to derive from.

**The exemption's bound is the ladder and not the salt's secrecy.** A
salt is drawn from a storage address under the per-process key, and
addresses recycle: a copy freed and a copy made again in its place can
draw the same number, and a timing oracle recovers a salt in any case,
which is what [strings.md](strings.md) concedes in "Neither position is a
defense". So the scattering above is what makes the replay's exemption
cheap in the ordinary case, while what makes it bounded in the adversarial
one is rung three itself: the next admission into that chain is refused.

**What a `Map` has, priced honestly.** Object identities are exact, so
there is nothing rung two could separate, and a flood needs bucket
collisions no attacker can aim without the key. A `Map`'s ladder is
therefore rung one, a flag-only second firing, and rung three — which for
object keys is reachable only by an attacker with address control the
threat model does not grant. One rung plus a terminal refusal is an
honest defense. One rung over a salt that is a public function of one
recyclable address, which is what the crate draws today, was not.

---

## What the crate owes before either class exists

**A per-process key, 32 bytes, drawn from the operating system once per
process in every build**, outside the hash stamp and exempt from
`hash-folding`, because nothing compiled may depend on it. The crate
names this slot already and has not filled it: the keyed byte hash stands
in for it, and the strings design reserves it as the long-hash key.

It is a prerequisite rather than an improvement. `MapMixed`'s array-key
identity cannot be defined without it, and the repriced salt cannot be
drawn without it. Until it exists, under `hash-folding` every rebuild the
ladder performs is aimable and rung three is the only real defense. This
design ships behind the key, not in front of it.

Four smaller obligations follow it, all in the array's table: the
trigger's tag-equality test, the kind dispatch in both slot-hash
functions with the byte branch asserted unreachable from any other tag,
the salt drawn under the key, and rung three as a refusal outcome
distinguishable from an allocation refusal, which retires the early
returns that make a spent ladder a dead one.

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
masks; the key comparison dispatches on the tag instead of testing the
raw word against the hole sentinel; removal and the sever mask before
they hand a pointer out, and stop being typed as a string pointer; the
copy's entry replay, which reconstructs a key from an entry on every
array duplication and every escape copy, gains the two new tags; the
insert's equal-identity counter tests the tag rather than "not an
integer"; and **both** slot-hash functions dispatch as the flood section
requires — the probe side and the rebuild side alike, because a table
whose two sides disagree on one key kind has that kind's entries present,
iterable and unfindable.

An array produces tags 0, 1 and the string tag only, so its lookup keeps
the two-way shape it has: the tag replaces the value test rather than
adding a branch beside it. This does not reintroduce the dispatch that
refused the single-class design; that one was a test of *admission*, on
every write, against a per-instance set.

**The walker is the reader the tag was invented for, and it wants both
words.** The tracer reads the key word raw, and the two things it builds
from it have opposite requirements. The **child** it reports must be
masked, because the collector looks an edge up by the entity's true
address and a tagged integer is a different address: a dropped in-edge
makes the key a computed root, and a ring closing through it is never
collected — the exact failure the hook exists to prevent, reached by
tagging instead of by omitting. The **raw word** it records must not be
masked, because Phase 3 re-reads the cell and compares it against that
value verbatim; masking it would fail every re-check and make every component
touching a map appear externally referenced.

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
touched. A lookup with an array probe can therefore still raise inside a
`foreach` over the same map, and that is the accepted behavior: the
table is untouched when it happens, so the iterator remains valid and the
map is unchanged. The constraint the table states is honoured rather than
relocated.

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

- **Scalars** hash by value. **A string hashes by its bytes under the
  per-process key**, not by the hash cached in its entity: that one is a
  build constant under `hash-folding`, and a content hash consuming it
  would inherit offline-constructible collisions through colliding
  strings. See "What the flood ladder becomes".
- **A nested array** is descended into, in insertion order, hashing each
  key beside its value.
- **An object is hashed by its id, not by its properties.** So two
  distinct objects with equal properties make two distinct keys. This
  departs from PHP's `==` on arrays, which compares nested objects by
  class and property values, and it is deliberate: an object's properties
  change with no barrier and no count to freeze them, so a hash over them
  would be stale the moment after it was taken, with nothing able to
  notice.
- **A reference box anywhere inside a key refuses the key, at any
  count.** A box with a second name is the obvious case: a write through
  that name changes the key's content without touching the array's count.
  A singly-named box is refused too, and collapsing it instead would be
  worse than the case it fixes. Collapsing writes into an array the
  program still names, without separation, on the one path that must
  create no edges — and it manufactures exactly the cycle this walk's
  termination argument assumes away, since a box at count one may hold
  the array that holds it, and collapsing turns that into an array
  containing itself. The COW copy's collapse is not a precedent for it:
  that one writes into the fresh copy and never touches the source.

  The same rule applies to a **probe**, not only to a stored key. A probe
  that hashed through a box would have to be compared through one as
  well, and the confirming walk compares like with like.

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
it linear in that graph rather than in its paths. The association is
consulted **on entry** and filled on entry, so it is a visited set as
well as a sharing optimization; the acyclicity argument makes the two
coincide, and reading it on exit alone would turn any breach of that
argument into a hang rather than a wrong answer.

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
copy-on-write. The override builds a fresh entity rather than starting
from a `memcpy`, which is also how it inherits the other thing the
generic clone does: the copy is a new object that nothing holds weakly,
so it carries no weak-reference flag and no side-table row.

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

## What the outside-cells hook owes a map

Named here because a map is the hook's second customer and it asks for
more than the first:

1. A hook that yields **cells**, from storage the parking machinery can
   take, because a block whose cells the collector recorded may not be
   freed while an epoch is in flight. This is the hook as first raised.
2. A **version**: read through the head's window, with the entity given
   up for the epoch when no coherent reading is obtained, and a
   **re-check** the descriptor answers, because Phase 3 finds an array's
   version by casting the entity and taking a fixed offset, which on an
   object is the class word.
3. A **sever body**, because the generic cell-nulling corrupts a table
   entry two ways, and a **free body**, because rc-trace frees the white
   set itself without calling `dispose` and would otherwise leave the
   chunk behind.
4. A way for a class to declare **body bytes no run describes**, and the
   storage head's no-`&mut` rule restated for an object body.
5. **Inheritance of the group**, which the descriptor builder does not do
   for `dispose` today.

Everything but point 1 is an addition to what the hook was first raised for. The
shape they take is `dev/DECISIONS.md`, 2026-08-13, "a class with cells
outside itself carries one flag and one group of five".

---

## Open

- **The rotation amount for an object key's id.** Arithmetic against the
  slot stride, and it wants the measurement that shows the seating rather
  than an argument.
- **Which pointer a `Map`'s key word holds under a movable object.**
  `Object::object_id` is the raw address today, and arena-reset marks
  evacuation shelved in favour of a movable proxy. Address equality is
  the whole of `Map`'s equality, so the answer decides whether the key
  word holds the object or its proxy. It decides one level down as well:
  an array key's stored content hash embeds the ids of the objects inside
  it, so an id that changes under a movable object makes that key
  unfindable with nothing able to notice.
- **A fourth key tag**, which needs arena entity slots forced to 16-byte
  alignment first. Wanted only if weak keys become a tag rather than a
  class.
- **`WeakMap`**, which needs the weak table's row to widen from one cell
  to a subscriber list ([weak-references.md](weak-references.md)).
- **The construction surface**: what a runtime-provided class looks like
  to the compiler, and whether a map literal exists in the language.
