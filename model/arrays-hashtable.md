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

Entry (40 B):
  +0   hash_or_key   u64   full hash of a string key, or the integer key itself
  +8   key           ptr   string key; 0 = integer key; 1 = hole
  +16  next          u32   index of the next entry in this bucket's chain
  +20  meta          u32   per-entry state (see "Element states")
  +24  value         ValueBox (16 B)
```

**Why the ValueBox is last.** The store barrier writes all sixteen bytes of a
ValueBox ([values.md](values.md), the `+10` row: bytes 10..15 are "alignment
padding, not usable as per-slot state"). Placing the ValueBox at +24 puts every
write it performs inside bytes 24..40, so a value store cannot reach `key`,
`next` or `hash_or_key`. Zend threads its collision chain through the element's
own padding (`zval.u2.next`); this crate cannot, and the four bytes at +16 are
what replace that trick. They cost footprint, not a third dependent access — the
link is loaded with the entry that was going to be read anyway.

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

### The index layer is replaceable, and deliberately so

The entry array is identical under a second index shape: `u64` slots fusing a
seven-bit hash fingerprint with the `u32` entry index, probed by open addressing.
That shape answers a lookup for an absent key without touching the entry array at
all, and it remains two dependent accesses because the fingerprint and the index
share one word. Chains are the default and the fused slot is the alternative;
neither changes the entry array, promotion, the tracer, or any observable
semantics, so the choice can be revisited on measurement rather than settled
here. What decides it is the ratio of absent-key lookups (`isset`, `??`,
`array_key_exists`) to present-key lookups in real PHP, which nobody has
measured.

**No measurement in this repository currently supports a choice between them,
and the ones that were attempted are withdrawn.** Both index shapes were
benchmarked over a byte-identical entry array on 2026-08-05, and an independent
review of the harness found four defects that between them void the comparison:
every table size was a power of two, so the open-addressed index was allocated
twice the slots it needed and ran at load 0.500 rather than the 0.875 it exists
for — the stated comparison was never executed; the mixed workload sized its
tables for a theoretical peak and ran at loads between 0.016 and 0.508; the
tombstone rebuild that was supposed to distinguish two of the runs could not
fire at the sizes tested; and the deletion rule was not the one it was modelled
on, so it truncated the probe sequence of unrelated keys and lost live entries
at a rate of roughly one per seven hundred operations at realistic load. Earlier
runs had already been invalidated twice — once for timing a `memset` of an
oversized index, once for probing keys in insertion order, which walks the entry
array sequentially and erases the very cost the control byte exists to avoid.

What survives is qualitative and is why chains are the default here: an
order-preserving table needs the dense entry array regardless, so the index is
the only variable; PHP arrays are mostly small, and at small sizes the whole
table is cache-resident, which is precisely where a control byte buys nothing
and its extra work shows; deletion is frequent in PHP, and unlinking a chain
leaves nothing behind, while an open-addressed slot cannot be freed without
truncating the probe sequence of keys that passed over it and therefore leaves a
tombstone to be cleaned later. Iteration is unaffected either way, since it is a
property of the entry array.

The measurement that would settle it is specified in "Open" below.

---

## Keys

A PHP array key is `int|string`, and a numeric string is canonicalised to an
integer before it reaches the table (`$a["1"]` and `$a[1]` are one key, while
`$a["011"]` stays a string). The canonicalisation test therefore sits in front of
every string-key operation and belongs in the cost of one, not in a footnote.

**A string key's position** comes from the hash cached in the string header at
+16 ([strings.md](strings.md)), computed on first use, with zero meaning "not
computed". The table stores that hash in the entry, so a probe compares 64 bits
before it compares any bytes, and a full comparison runs only on equal hashes.

**An integer key's position** comes from an avalanche mix of the key, salted per
table — not from the key's low bits. Zend indexes an integer key by its value, so
the keys `0, 1024, 2048, …` collide in one bucket at every table size up to 1024,
which is a flood requiring no knowledge of any seed and no hash function at all.
The mix costs a multiply and a shift, and it is paid only by hash-resident
integer keys: a dense integer array is strategy 2 and never reaches this table.

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

`meta` and `key` together carry four states, and every walker branches on them:

- **live, plain value** — the common case.
- **hole** — `key == 1`. Left by deletion, skipped by iteration and by the
  tracer, reclaimed by compaction.
- **element holding a reference** — the ValueBox carries a pointer to a
  ReferenceBox (kind 3, `RcHeader | Value`), tagged in the box's own flags.
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
the value; the COW separator retains the box and does not recurse, which is
PHP's observable by-reference infection; and `escape_copy` treats it as
identity-bearing — hold-count, never copy.

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
first, and then read a byte from the ArrayBox's own fields, which are on a line
they have already loaded. Two bits for the strategy, one for the hash mode
below, and the per-table salt live there together.

---

## Defence against constructed collisions

The hash stage recorded the debt and named its owner: neither arm of the seed
defends against collision flooding, and bounding the worst case is the table's
job (`ll-model/dev/DECISIONS.md`, 2026-08-04). Rapidhash is in the family for
which seed-independent universal multicollisions have been published, so the
defence cannot rest on the hash being unpredictable.

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
storage under a live iterator or an element reference, and has no synchronisation
on a table two threads read. Insert-only firing is sufficient because the trigger
prevents the pathological state from existing, so lookups are bounded as a
consequence rather than by a check of their own.

**What it does**: trigger 1 escalates the table, once, to a keyed hash over the
key's bytes — the long-key function slot [strings.md](strings.md) already
reserves, with a per-process key that is never folded — and sets the table's
one-way mode bit, after which its string-key operations hash bytes instead of
reading the cached hash at +16. The cached hash is not touched: it is shared
across every table holding that string. Trigger 2 redraws the per-table salt and
rebuilds the index; a second firing escalates as well.

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
category, so an arena COW child is copied recursively, an arena object or
ReferenceBox child takes the existing hold-count route, and a heap or immortal
child is merely retained. Depth is bounded by the arena-resident COW subtree. A
refused publish needs no rollback log, because the copy is private until the slot
accepts it: releasing the prefix already built and freeing the private storage
restores every external count. This is the arm `object.rs`'s `escape_copy`
reserves with `unreachable!("no COW copy for this entity kind yet")`.

---

## Open

- **The index layer**, pending the ratio of absent-key to present-key lookups on
  real PHP code. The entry array is designed so that either shape fits.
- **The compaction threshold**, currently Zend's ~3 % by borrowing rather than by
  measurement.
- **The two flood constants**, and whether escalation raises an operations-visible
  signal.
- **The recursion-depth guard** on the escape copy, since nesting depth is
  attacker-shaped input on a store path.
- **The index measurement, done properly.** What the withdrawn attempt has to
  fix before its numbers mean anything: size each table at its own design load
  (0.5 chained, 0.875 open-addressed) rather than at a shared power of two; let
  growth, compaction and index rebuild run inside the timed region, since the
  design puts the cost there; make an insert a lookup-then-insert, which is what
  a PHP write is; probe in a shuffled order; assert the achieved hit count
  inside every timed loop, which is the check that would have caught all four
  defects; interleave the two implementations within one run and pin the clock,
  because the between-run spread on this box reached 50 % and exceeded every
  difference being read; and measure string keys as well as integers, since a
  string key comparison is a length test and a `memcmp` rather than one
  register compare. Until then the default stands on the structural argument
  above, not on numbers.
- **ARM.** Everything attempted so far ran on one x86 core. The SIMD group probe
  has no single-instruction equivalent on NEON, and the memory-level parallelism
  that hides a dependent access is scarcer on the small cores `BACKLOG.md` names
  as targets, so both halves of the comparison move there.
