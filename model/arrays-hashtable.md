# The array hashtable

## Scope

Storage strategy 3 of [arrays.md](arrays.md) — the ordered hash behind the
`array` class: what a table is made of, how a key becomes a position, what
deletion and iteration cost, how the table defends itself against constructed
collisions, and what it owes the memory manager. `arrays.md` fixes the
architecture above this document (one class, three strategies, transitions, the
COW contract) and calls this design a future one; this is that document.

Out of scope: the typed vector and the mixed vector, except where a transition
into the hash constrains it; the compiler's proof that produces strategy 1.

---

## The shape: an index array over a dense insertion-ordered entry array

**Decision**: one allocation holds an array of `u32` index slots followed by a
dense array of entries in insertion order. The index slots are the hashtable;
the entry array is the order. A lookup reads one index slot and then one entry —
**two dependent memory accesses**, and no design that preserves insertion order
can do better, since the entry read is the answer and the index read is what
locates it.

```
[ u32 index slots ][ Entry × capacity ]

Entry (32 B):
  +0   hash_or_key   u64   full hash of a string key, or the integer key itself
  +8   key           ptr   string key, tagged in its low three bits
                           (maps.md, "The key word gains a tag, for
                           every owner"); 0 = integer key; 1 = hole
  +16  value         ValueBox (16 B), whose reserved bytes carry this
                     entry's collision link: a u32 at entry +28
```

**The collision link lives inside the element's ValueBox**, in the six bytes
[values.md](values.md) reserves at the box's `+10` — the link is the top four of
them, box `+12`. The entry therefore costs 32 bytes rather than the 40 a
separate `next` and `meta` pair cost, and an element of capacity costs 40 with
its two index slots against the 48 it cost before, which is what `zend_array`
has cost since PHP 7.3. Zend threads its
chain through the element's own padding (`zval.u2.next`) under a rule its macros
obey: a value copy never carries `u2`. The rule here has to be stronger, because
the concurrent collector reads the element's second word while a mutator writes
it, so **every** write to that word is one relaxed atomic store of the width the
collector loads. The element field is private, three composing writers publish
the word, and every read hands the box out with the reserved bytes cleared, so a
link cannot travel in a copy into another entry
(`ll-model/dev/DECISIONS.md`, 2026-08-07). The link is loaded with the entry
that was going to be read anyway, so it costs no third dependent access.

**Why the key words come first.** The store barrier writes all sixteen bytes of
a ValueBox, so a value store reaches bytes 16..32 and nothing below them: the
key and the hash are out of its way by position. That is what makes the hole
marker survive an element store.

**Why `key` is the discriminant.** An aligned pointer is a string key; `0` is an
integer key, whose value is in `hash_or_key`; `1` marks a hole left by deletion.
The marker therefore lives outside the ValueBox, where the store barrier cannot
destroy it, which is what makes hole-skipping safe for the arena reset's tracer.

**Index slots** hold entry indices, with `u32::MAX` reserved for "empty". Their
count is twice the entry capacity, so the index runs at load factor 0.5 while the
entry array is full — Zend's ratio, and the one the measurements below were taken
at. The u32 index caps a single array at 2³²−2 elements, a language-visible limit
of the same kind as the 4 GiB string cap in [strings.md](strings.md), checked
through one choke point that raises rather than truncating.

### Why chains, and not a control-byte index

The alternative was a SwissTable-style index over the same entry array: one
control byte per slot carrying a seven-bit hash tag, probed sixteen at a time
with SIMD, plus a parallel `u32` array of entry indices. Its published advantage
is the absent-key lookup, which terminates in the control line without touching
the entry array at all.

**That advantage does not appear once each index runs at its own design load**,
which is the measurement that decides this. A chained index is full at load 0.5
and a control-byte index at 0.875; at 0.5 a chained miss ends on the first slot
read most of the time, while at 0.875 the control-byte probe must walk until it
meets an empty byte, which instrumentation puts at two groups on average and up
to twelve. Measured over a byte-identical entry array, integer keys, medians of
fifteen alternating runs on one core (ns per operation, chained / control byte):

| N | 56 | 448 | 3 584 | 28 672 | 229 376 | 1 835 008 |
|---|---|---|---|---|---|---|
| lookup, absent | 1.21 / 1.89 | 1.10 / 1.91 | 1.13 / 3.37 | 5.95 / 11.21 | 8.93 / 14.43 | 28.6 / 30.4 |
| delete | 1.90 / 5.80 | 1.86 / 4.87 | 2.95 / 4.79 | 6.13 / 13.40 | 14.6 / 23.7 | 42.6 / 56.0 |
| lookup, present | 0.79 / 1.87 | 0.81 / 1.87 | 1.25 / 2.31 | 4.81 / 4.79 | 11.1 / 12.1 | 38.7 / 36.7 |
| build | 5.4 / 12.2 | 4.5 / 10.2 | 5.6 / 9.4 | 9.2 / 11.0 | 17.2 / 16.7 | 56.4 / 43.0 |

Deletion is the chained index's clearest win and holds at every size; the
absent-key column is its win everywhere except the largest size, where the two
are level within the run-to-run spread. The control-byte index wins the build at
the largest size only, where it also draws level on a present-key lookup — its
regime is the one where the entry array has left cache.

**Iteration does not enter this at all**, by construction rather than by
measurement: iteration walks the entry array and reads no index, and the entry
array is the same under both.

**The decision rests on the small and middle sizes, and on an assumption named
here so it can be tested.** The chained margin at N ≤ 3584 is 1.5x to 3x on
build, both lookups and delete, at sizes where the whole table is L1- or
L2-resident — so it is the cost of the path itself, two arrays and a group probe
against one slot read, and not an effect of memory latency. Go reports the same
shape from the other side: a 28-46 % regression on maps of eight elements or
fewer after its move to control bytes. The assumption is **not** that PHP arrays
are small — a small dense integer array is strategy 2 and never reaches this
table — but that the tables which do reach strategy 3 are mostly small and
middling associative ones: rows from a database, configuration, request
parameters. That is plausible and unmeasured, and it is the assumption to attack
first if this default ever looks wrong.

**What this comparison does not establish.** Keys were integers used as their own
hash, so a key comparison was one register compare; a real string key costs a
length test and a `memcmp`, which the control byte filters away at seven bits and
a chain does not. The index memory goes the other way, roughly 9.1 bytes per
entry chained against 5.7 for the control byte — those 3.4 bytes were about 7 %
of the table at the 40-byte entry this comparison was run against, and are about
8 % at the 32 bytes the entry costs now. The chain link is not part of that cost
at all: it sits inside the element's reserved bytes and adds nothing to the
entry. The comparison is equal-N with each index at its own design load; an
equal-memory comparison would let the control byte run near 0.55 instead of
0.875 and would cheapen its miss, but only at the large sizes where the two
already meet within the spread. A mixed workload was run and is **not** quoted
here: at the largest size it forced one table doubling in the control-byte arm
and none in the chained arm, so a single 71 ms growth event sat inside a 116 ms
measurement, and after that doubling the table ran at 0.438 rather than 0.875 —
the row measures neither index at its design point. One core, one x86 machine,
WSL2 with no control over the frequency governor.

**Two non-performance grounds point the same way.** The flood backstop's first
trigger counts entries whose full 64-bit hash equals the new key's; a chain walk
visits exactly those candidates and reads the hash from an entry it has already
loaded, while a control-byte probe walks a run that includes unrelated keys, so
the counter is noisier there. And `BACKLOG.md` names small ARM cores as targets,
where NEON has no single-instruction movemask: chains need no second probe
implementation.

Nothing above changes the entry array, promotion, the tracer, or any observable
semantics, so the index stays replaceable — but it is a decision now, not a
deferral, and what would reverse it is stated in "Open".

---

## Keys

A PHP array key is `int|string`, and a numeric string is canonicalised to an
integer before it reaches the table (`$a["1"]` and `$a[1]` are one key, while
`$a["011"]` stays a string). The canonicalization test therefore sits in front of
every string-key operation and belongs in the cost of one, not in a footnote.

**A string key's position** comes from the hash cached in the string header at
+16 ([strings.md](strings.md)), computed on first use, with zero meaning "not
computed". The table stores that hash in the entry, so a probe compares 64 bits
before it compares any bytes, and a full comparison runs only on equal hashes.

**An integer key's position** comes from the key's value while the table is
unsalted, and from an avalanche mix of the key, salted per table, once the flood
ladder has drawn the table's salt. A fresh table is unsalted — the ladder's
zeroth rung — so a table pays the mix only after a long chain fired the rung
(amended 2026-08-07; the first draft applied the mix from birth). The trigger
reads shape, not intent: honest keys striding by a power of two build the same
chain a flood does and buy the same salt, which is the price of needing no
classifier.

Indexing by value admits Zend's flood: the keys `0, 1024, 2048, …` collide in one
bucket at every table size up to 1024, with no knowledge of any seed and no hash
function at all. The zeroth rung admits it deliberately, because the flood builds
exactly one long chain, and a long chain is the first rung's own trigger — the
rung that draws the salt and rebuilds. The salt is thus paid exactly where keys
turned out to come from outside, and nothing has to predict where that is. A
compiler-supplied "external data" flag was rejected as the selector: the
classification has to be right on every array, it fails silently in the unsafe
direction, and keys arrive through `json_decode`, a database row, `array_keys` of
another array and any function argument. The flag stays available later as an
optimization, when a compiler exists that can prove rather than assume.

The mix costs a multiply and a shift, paid only by salted, hash-resident integer
keys: a dense integer array is strategy 2 and never reaches this table.

**The lazily cached string hash is a shared write.** `string.rs` justifies its
plain non-atomic store by observing that only single-thread-owned strings are
left unhashed — `init_at` hashes Immortal and LongLived strings eagerly. A
GcHeap COW string used as a key on two threads falsifies that: two lookups race
plain stores of the same value. The value is idempotent, so the race is benign in
practice and undefined in the memory model, and Miri is this crate's tool for
exactly that. The field becomes a relaxed atomic — free on x86-64 and ARM64 —
and this lands with the table, since the table's lookup path is what creates the
second writer.

---

## Element states

`key` and the element's own tag together carry four states, and every walker
branches on them:

- **live, plain value** — the common case.
- **hole** — `key == 1`. Left by deletion, skipped by iteration and by the
  tracer, reclaimed by compaction.
- **element holding a reference** — the ValueBox carries a pointer to a
  ReferenceBox (`RcHeader | Value`), tagged in the box's own flags.
- **element of a table under a foreign owner** — see "Thread hand-over".

**A reference into an element is a ReferenceBox, never a slot pointer.**
`values.md` offers two forms of a PHP `&`: the ReferenceBox, and the typed slot
reference that retains an owner and points at a slot. The second is for slots
that never move — `&$obj->typedProp` — and an array element moves whenever the
storage is reallocated by growth. So `&$a['k']` boxes the element's current value
into a fresh ReferenceBox and stores the tagged pointer back into the element:
growth then moves sixteen bytes containing a pointer, and the box stays put.
Consequences, each of which is a branch somewhere: an element store writes
*through* the box; taking the reference on a shared table separates first,
because it is a write; a by-value iterator dereferences the box when producing
the value; the COW separator shares the box **while a second name holds it**
and unwraps it otherwise, which is where PHP's by-reference infection begins
and ends; and `escape_copy` treats it as identity-bearing — hold-count, never
copy.

**The separator's condition, and the one event that asks it.** A copy of the
table unwraps an element whose box has a single holder — the source's own
entry — and takes the value behind it; with two or more it shares the box, and
a write through either container is read through the other. Duplication is the
only event that collapses a reference. Neither `unset` of the binding, nor a
write through the box, nor a write to a neighbouring element changes the
element's state, which is measured behavior rather than a choice: php 8.3.6
reports the element `reference refcount(1)` after each, and collapses it in
`zend_array_dup_element`. `escape_copy` is not a duplication and does not
collapse: the program stores a value across a lifetime boundary there, so the
box travels with the element.

**In the request arena the holder count is an upper bound**, so the separator
errs toward sharing — a container there is reclaimed by the reset rather than
by its own death, and every hold it took on a box stands until the request
ends. The direction is the safe one and the reasoning is in
[values.md](values.md), "ReferenceBox".

Strategy 1 (the typed vector) admits no reference at all, since an unboxed slot
has no room for the tag and the storage reallocates. Taking `&` into a proven
`array<int>` therefore transitions it out of strategy 1 before the reference
exists.

---

## Order, deletion and compaction

**Insertion appends** to the entry array and links the new entry at the head of
its bucket's chain. Insertion order is the entry array's own order, and nothing
reorders it, so iteration is a stride over `0..used` skipping holes.

**Deletion unlinks** the entry from its chain and marks it a hole. `used` does
not move, so holes accumulate and iteration walks them.

**Compaction** slides live entries down over the holes and rebuilds every chain.
It runs at growth time and only when holes exceed a threshold of the live count —
Zend's rule, ~3 %, is a starting point and not a measured one. Compaction moves
elements, so it must repair every live iterator position; PHP's `foreach` by
value iterates a COW snapshot and is unaffected, while `foreach` by reference and
the internal pointer are not, which is why the table carries a count of live
iterators and repairs them rather than assuming there are none.

**`nNextFreeElement` never goes backwards.** Appending to `[0,1,2]` after
`unset($a[1])` yields key 3. Re-inserting a deleted key appends it at the end.
Both are observable and both are properties of the table, not of the caller.

---

## Growth, and the migration from the mixed vector

Growth allocates a new storage of twice the entry capacity, copies the entry
array wholesale, and rebuilds the index — the entry array's contents are
position-independent, since every link is an index rather than a pointer.

**2 → 3** (mixed vector to hash) happens on the first string key or the first
hole in the integer key space, as `arrays.md` fixes. The migration walks the
vector in order, appending each element as an entry with its integer key, so
insertion order survives the transition by construction.

**1 → 2** (typed vector to mixed) is a hole `arrays.md` leaves open and this
design forces shut. `arrays.md` says strategy 1 never transitions, because the
compiler proved monomorphism; but separation copies "the storage in its current
representation", so a proven `array<int>` handed to `function f($x) { $x[0] =
"s"; }` gives the callee a private typed vector it then stores a pointer into.
The generic element write therefore dispatches on the strategy tag and
transitions 1 → 2 on an incompatible store — by then the table is exclusively
owned, so it may allocate and may raise. Raw unboxed stores inside the region
the compiler proved stay branch-free.

**The strategy tag** lives in the ArrayBox body, not in the entity header. The
flags word has no free bit ([strings.md](strings.md), and the crate's layout
test), and it needs none: teardown and both walkers dispatch on entity kind
first, and then read the tag from the ArrayBox's own fields, which are on a line
they have already loaded.

Inside the body it sits with the storage pointer and the two counts, in the
words a concurrent walker reads, and **not** in the byte holding the ladder's
rung state and the append cursor's exhaustion. The walker loads the tag
atomically, because the tag is what says which layout the counts describe and a
migration replaces the representation under it; the rung state is written
plainly by the mutator and no walker reads it. One byte cannot be both, so the
two bits once reserved for the strategy beside the rung state are free again,
and the per-table salt stays where the rung state is. *(Amended 2026-08-12:
this paragraph put the strategy tag in that byte, which the walker's atomic
reading forbids.)*

---

## Defense against constructed collisions

The hash stage recorded the debt and named its owner: neither arm of the seed
defends against collision flooding, and bounding the worst case is the table's
job (`ll-model/dev/DECISIONS.md`, 2026-08-04). Rapidhash is in the family for
which seed-independent universal multicollisions have been published, so the
defense cannot rest on the hash being unpredictable.

**What is counted**, during the insert's own chain walk, against the table's
current state, with nothing accumulated between operations:

1. **Entries met whose full 64-bit hash equals the new key's.** An honest table
   never holds eight of them at any reachable size — eight-way agreement by
   chance needs on the order of 2⁵⁶ keys — so the threshold is a size-independent
   constant, and it is reachable only through constructed multicollisions.
2. **Chain length.** A generous constant, since the honest maximum is 4–8 at
   4 M keys and grows like log n / log log n. This catches families whose hashes
   differ but whose indices coincide, including an integer flood.

Counting per operation rather than keeping a running maximum is what survives
deletion: a stored maximum never decreases, so a table emptied by `unset` would
keep firing forever, or would need an O(n) recomputation on every delete.

**When it fires**: on insertion only. The insert path already holds exclusive
ownership after separation, may allocate, and may raise. A lookup may do none of
those: `isset()` must not acquire an out-of-memory raise, must not reallocate
storage under a live iterator or an element reference, and has no synchronization
on a table two threads read. Insert-only firing is sufficient because the trigger
prevents the pathological state from existing, so lookups are bounded as a
consequence rather than by a check of their own.

**What it does**: trigger 1 escalates the table, once, to a keyed hash over the
key's bytes — the long-key function slot [strings.md](strings.md) already
reserves, with a per-process key that is never folded — and sets the table's
one-way mode bit, after which its string-key operations hash bytes instead of
reading the cached hash at +16. The cached hash is not touched: it is shared
across every table holding that string. Trigger 2 draws the per-table salt — a
fresh table has none — and rebuilds the index; a second firing escalates as
well. Whichever trigger fires first on an unsalted table draws the salt on the
way, so rung state moves one way and a copy inherits both bits. The escalated
hash's key is the long-key slot's per-process never-folded key named above;
until that slot is filled the runtime stands in with a hash keyed by the
table's salt, which is the second reason the draw precedes escalation — a salt
left at zero would key the stand-in with a number every attacker knows. Either
way it is a draw, not the redraw the Perl defect is about: the salt of a table
holding entries is never moved again. A copy draws its own, over an empty table
before its first insert, where no entry is indexed under the number it replaces —
the bits it inherits are what keep the ladder bounded, and the number is what an
attacker's set was built against ([maps.md](maps.md), "Rung three, refusal").

**What the attacker can drive**: one salt rebuild and one escalation per table,
each O(n), plus a bounded constant of work per insert before firing. Redrawing a
salt in response to equal-hash keys is what made Perl's REHASH exploitable
(CVE-2013-1667), and this design never does it — equal hashes escalate instead.

**What this retires**: nothing in `hash-folding`. Folding replaces a load of the
cached hash with an immediate; the index derivation's salt mix is paid alike by a
folded and an unfolded hash. An escalated table ignores folded constants for its
own index, which is dead weight in an attacked table rather than a break.

**What it rules out**: treeification. Java 8 bounds a bin at O(log n) by
converting it to a red-black tree, and the nodes have nowhere to live here — they
do not fit beside a 16-byte ValueBox, and they cannot be indices into the entry
array without reordering it, which insertion order forbids. Side-allocated nodes
would make the pathological path an allocation the attacker triggers, which is
the objection that rules out a grow-on-long-probe response as well.

**The residual**, stated as an assumption rather than hidden: after escalation,
constructing a new colliding set requires breaking a keyed PRF. That is the same
posture as CPython, Ruby and Rust.

---

## What the table owes the memory manager

**Complete enumeration.** The arena reset's escaped-subgraph trace marks visited
entities in flag bits; table storage is not an entity and has no header, so the
tracer enumerates elements from the storage itself. That enumeration must be
complete rather than conservative — an array survivor's element references are
erased rather than ignored, and `traceable_in_full` asserts it
(`ll-model/dev/DECISIONS.md`, 2026-08-04). The dense prefix `0..used` with holes
marked in `key` satisfies this by construction, and the marker is outside the
ValueBox precisely so that a value store cannot destroy it.

**Promotion carries the storage.** An arena survivor's out-of-line storage is
copied into the heap with the entity header fixed in place, exactly as a string
payload is ([strings.md](strings.md)). This is why every link inside the storage
is an index and never a pointer: a copied storage would otherwise need every
internal pointer fixed up. An OS-direct storage transfers ownership without a
copy; an in-block one is copied; and a refused copy retains the payload's block,
because the reset has no caller left to report a refusal to.

**Storage blocks carry no flags**, and need none: every consumer derives the
category from the owning ArrayBox or from the block kind, and promotion moves the
storage out before its block is returned.

**Thread hand-over.** Storage lives in the per-thread buffer arena, under the
per-block owner, remote-free and adoption protocol that arena gained on
2026-08-04. Growth on a thread that does not own the block allocates from its own
arena and posts the old chunk home. Moving an arena-category array between actors
is an actor-design question and is deferred, named rather than assumed away.

**The COW copy has two depths and they must not be confused.** Separation on
write is shallow — children are retained and shared, as `arrays.md` says. The
store barrier's escape copy is deep, as [values.md](values.md) and
[arenas.md](memory/arenas.md) say, and it is deep in a category-driven sense: the
copy publishes each element through the barrier again with the destination's
category, so an arena COW child is copied in turn, an arena object or
ReferenceBox child takes the existing hold-count route, and a heap or immortal
child is merely retained. The work is linear in the arena-resident COW subgraph
reachable from the source: one copy per distinct entity, held once per entry
naming it. Nesting is worked through a list in a buffer-arena chunk rather than
the machine stack, so depth, attacker-shaped input on a store path, costs a
refusable allocation and never a stack frame. A
refused publish needs no rollback log, because the copy is private until the slot
accepts it: releasing the prefix already built, freeing the private storage and
giving the private entity itself back restores every external count. All three,
and the third is the one an implementation drops — the entity nothing has named
yet is still an entity, and leaving it behind leaks a slot per refusal.
*(Amended 2026-08-12: the sentence stopped at the storage, and the crate leaked
exactly what it left out. Amended 2026-08-13: the replaced sentence bounded a
recursion depth over a subtree. The copy drains an explicit list, so no
recursion is left to bound, and it holds one copy per distinct source entity
instead of unfolding the graph into its paths, which cost 2^depth on a source
whose children name each other twice per level. The open item asking for a
recursion-depth guard closes with it.)*

The escape copy has an arm per COW kind — a string's and an array's — and the
kinds with no COW copy reach a default that cannot return: null is how the
call says "out of memory", and an unimplemented kind is not that, so there is
nothing safe to return and nothing safe to continue into.
*(Amended 2026-08-12: this used to read as though the whole deep copy were the
arm reserved by `unreachable!`, which is the default beside the two arms rather
than either of them.)*

---

## Open

- **The index layer is decided, and the string-key run is its check rather than
  its prerequisite.** The cancellation threshold, named in advance so the result
  cannot be read to taste: if the control-byte index wins both lookups by 1.5x
  or more at N between 56 and 28 672 on string keys of realistic length, without
  its deletion margin worsening, the default changes. This is not expected — a
  chain compares the full 64-bit hash before any `memcmp`, so the seven-bit tag
  saves only the entry load for candidates that do not match, and at load 0.5
  there are few of those.
- **The compaction threshold**, currently Zend's ~3 % by borrowing rather than by
  measurement.
- **The two flood constants**, and whether escalation raises an operations-visible
  signal.
- **String keys, which are the one corner the index comparison leaves open.** A
  seven-bit tag filters a wrong key before any byte comparison; a chain compares
  the full hash and then the bytes. With integer keys that difference is one
  register compare and the measurement above is biased toward chains by exactly
  that amount. Same harness, string keys of realistic length distribution.
- **A mixed workload that measures what it claims.** The attempt made on
  2026-08-05 is not quotable: table sizes that put one index at its design load
  left the other with a full growth cycle of headroom, so at the largest size one
  arm paid a doubling inside the timed region and the other paid none, and after
  that doubling neither arm was at its design load. Either give both arms
  proportional headroom, or hold the live count fixed so no growth occurs, and
  print the achieved load and growth count for the mixed phase rather than for
  the build phase only.
- **Instrumentation that cannot drift from the code it measures.** The probe-length
  figures first reported for the control-byte index came from a copy of the probe
  loop that still used the old stride, and it silently failed to find about one
  present key in a hundred. A counter compiled into the real lookup under a build
  flag is the shape that cannot diverge.
- **ARM.** Everything attempted so far ran on one x86 core. The SIMD group probe
  has no single-instruction equivalent on NEON, and the memory-level parallelism
  that hides a dependent access is scarcer on the small cores `BACKLOG.md` names
  as targets, so both halves of the comparison move there.
