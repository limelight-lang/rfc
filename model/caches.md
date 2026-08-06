# Caches

## Scope

Every place in this runtime that holds a computed answer against a later
question: what is cached, what keys it, what may invalidate it, and what happens
when it fills. The individual mechanisms are specified where they live —
[classes.md](classes.md) for inline caches and interned names,
[lowering.md](lowering.md) for the IR, [arrays-hashtable.md](arrays-hashtable.md)
for the array table, [memory/heap-slot-allocation.md](memory/heap-slot-allocation.md)
for the block caches. This document exists for the question those cannot answer
separately: which of them need a replacement policy, and what the ones that do
not need instead.

---

## No cache in this runtime uses a replacement policy

**Decision**: no LRU, LFU, ARC, CLOCK or any other eviction policy appears
anywhere in Limelight. Where a cache is bounded, it overwrites in place, refuses,
or degrades to a slower path that always exists.

This is not an omission and it is not novel. Nine production runtimes were read
at source level — Zend, V8, HotSpot, HHVM, CPython 3.12 and its current `main`,
PyPy, LuaJIT, JavaScriptCore, CoreCLR — and not one uses a classical replacement
policy for a dispatch, property, method or type cache. Zend's three-word property
slot, HotSpot's single `CompiledICData`, HHVM's one-entry `MethodCache`,
CPython's per-instruction cache, PyPy's and CPython's direct-mapped tables, V8's
and JavaScriptCore's stub caches all resolve a collision by clobbering. The
arithmetic is why: these entries are two or three words and cost tens of
nanoseconds to rebuild, while any policy costs metadata work on **every access
including hits**.

**The one exception in the industry is a checklist, and Limelight fails it.**
HotSpot's code cache has a real adaptive recency policy — `nmethod::is_cold`
against GC epochs, with the aging threshold scaled to pressure and switched off
entirely when there is none. It qualified because four things were true at once:
entries are kilobytes and cost milliseconds of compilation to recreate; the
recency signal is free, stamped by an entry barrier that already exists;
reclamation is batched into a pause that already exists; and the policy costs
nothing when it is not needed. Limelight has none of the middle two.
[gc/strategies.md](gc/strategies.md) and `dev/DECISIONS.md` record that `rc-walk`
pauses the mutator not at all, so there is no pause to batch into; AOT calls are
direct, so there is no entry barrier to take a recency stamp from; and nothing in
this runtime ever scans another thread's stack, so nothing can prove a body is
not executing. **So the conclusion is not "only a future compiled-code region
would qualify" — it is that nothing qualifies, including compiled code.** A
compiled-code region grows monotonically, bounded by recompilation count.

**What replaces a policy**, at each site that would otherwise want one:

- **Overwrite in place**, where the cache is one entry and there is no choice to
  make. This is every inline cache.
- **Invalidation by construction**, where a cached artifact cannot become wrong:
  see the next section.
- **Refusal with a named degradation path**, where a capacity limit is real.
  See "Capacity" below.

---

## Invalidation: three ways to need none

Every cache in this runtime avoids an invalidation protocol, and it is worth
naming which of three mechanisms each one uses, because the mechanisms fail
differently.

**By key stability.** An inline cache keys on a class-descriptor address.
Descriptors are immortal ([classes.md](classes.md), "Class Descriptor"), classes
are immutable after link, and the GC is non-moving, so the key cannot become
stale and — the sharper property — an address cannot be recycled onto a
*different* class, which would turn a stale entry into a silent false hit rather
than a crash. This is the mechanism that made the long-lived-arena wording in an
earlier draft load-bearing rather than cosmetic.

**By self-verification.** A cached artifact that re-checks its own preconditions
needs no invalidation, only a guard. V8's megamorphic stub cache uses this: its
handlers verify the prototype chain, so a stale entry is useless rather than
wrong. Limelight's future use for it is CHA-style devirtualization of `static::`
sites, deferred to a JIT phase in [classes.md](classes.md): the site keeps a
guard it re-verifies, rather than a registry that must find it.

**By boundary.** A cache that dies wholesale at a boundary that arrives on its
own needs no policy for the same reason a request-scoped allocator needs no
`free`. In Limelight that boundary is the arena reset, and it is stronger than
Zend's: a request-scoped cache is arena-allocated, so the reset frees it without
walking it ([memory/arena-reset.md](memory/arena-reset.md), "Freed memory is just
memory").

**What Limelight deliberately does not import.** Zend memsets its whole
`map_ptr` table at every request start; HHVM makes the same reset cheap with a
one-byte generation per entry, incremented per request and memset only on
wraparound. Neither pattern has a site here: request-scoped memory is freed by
the reset rather than reset in place, and per-thread structures deliberately
outlive a request. Worse, the generation byte is *unsound* at the one place it
would be reached for — an actor, which [classes.md](classes.md) records is not
bound to a thread and may migrate between messages, so a region stamped
generation 7 by one thread reads as valid on another whose counter also stands at
7. A version stamp on classes has no consumer either: PHP cannot mutate a class,
so CPython's version-tag machinery answers a question this language does not ask.

---

## The sites

**Inline caches** ([classes.md](classes.md), [lowering.md](lowering.md)) — one
entry per dynamic call, property access or interface conversion site, keyed on
the receiver's class pointer. A site is one word pointing at an immutable
`(class, target)` pair baked at link time; the halves are never written after
link, so a concurrent update cannot tear them apart. Process lifetime, no
eviction, no invalidation — under one invariant that is stated rather than
assumed: compiled code is immortal. A miss costs a hashtable probe in
`cls->methods` keyed by an interned name, where the hash is precomputed and the
name comparison is a pointer compare — a modest miss, and that is itself the
argument for keeping the machinery around a hit small.

**The itable search** ([classes.md](classes.md)) — a sorted array keyed by
interface id, resolved by the same per-site cache. Not a cache itself; the itable
is baked at link time and nothing rebuilds it while the program runs.

**Interned names** ([classes.md](classes.md)) — content to entity, in the
immortal region, so that name equality is a pointer compare. **Eviction here
would be a correctness bug, not a tuning knob**: evicting an entry and
re-interning the same content later yields two addresses for one name and breaks
every name comparison in the runtime. The admission question is answered
instead — a runtime-built name is matched by hash and confirmed by `memcmp`, and
never enters the table, so attacker-shaped input cannot grow it.

**The string hash** ([strings.md](strings.md)) — a one-slot memo inside the
entity it describes, computed on first use, cleared by the one event that
invalidates it. No policy is possible or needed. The array table makes its write
a shared one, so it becomes a relaxed atomic
([arrays-hashtable.md](arrays-hashtable.md)).

**The block pool's per-thread cache** ([memory/heap-slot-allocation.md](memory/heap-slot-allocation.md))
— eight free blocks, refilled in batches of four, flushed by half on overflow,
returned to the global chain when the thread dies. Blocks are fungible, so
"which to evict" has no wrong answer: this is a *sizing* decision, not a
replacement one. The same is true of the heap's one retained empty block per size
class.

**The rc-walk component history** ([gc/rc-walk.md](gc/rc-walk.md)) — the only
designed memo here with a stated invalidation event *and* a stated false-hit
cost: a spurious match costs one early forced drain and nothing else. It is the
model the rest of this document holds its caches to.

**Not caches, listed because they are mistaken for them.** The Cohen display,
vtables, itables, `static_vtbl`, `prop_layout`, `traced_runs` and template shapes
are link-time or compile-time artifacts with no runtime fill path — nothing can
be evicted from a table that was never filled at runtime. The weak table is
authoritative state whose entries are removed at death rather than evicted. The
retained-block index is a precomputed index whose lifetime is exactly the
retention it describes.

**The one genuinely megamorphic site** is the exception-unwinding personality
routine, which sees a different class on every call and therefore has no site to
attach a cache to ([runtime/exceptions.md](../runtime/exceptions.md)). It is
answered with a `Throwable` flag bit and the sorted itable's binary search, not
with a shared table — a shared table would buy back only the search it replaces
while re-introducing the multi-writer problem that per-site words avoid.

---

## Capacity: every limit names a degradation path

**Rule**: a bounded structure states what happens when it fills, and that
something is never an abort and never a silent wrong answer.

The industry precedent is uniform. OPcache returns the un-interned string and
logs a warning when its interned-string buffer overflows. PyPy falls back to a
plain dict past eighty attributes. CPython's current type cache stops accepting
new names past 65536 rather than evicting. HHVM stops translating and interprets.
What makes "no eviction policy" survivable everywhere is that nothing throws.

Limelight has fewer such paths than those runtimes, and one of them is a
cautionary tale rather than a precedent: `immortal_alloc` used to assert on a
request above one block payload, which under `panic = "abort"` terminates the
worker. That has been changed to an OS-direct run (`ll-model/dev/DECISIONS.md`,
2026-08-06), and the general lesson is written here because the assert's
justification — "anything larger is a caller bug" — is only true while no caller
forwards input, and that is a property of today's call graph rather than of the
allocator.

The degradation paths that do exist: an allocation refusal reports null and
reaches a frame that can raise, rather than aborting; an oversized immortal
entity takes an OS-direct run; an inline cache that keeps missing keeps taking
the slow path forever, which is correct and merely slow. **There is no
interpreter to fall back to**, which is why HHVM's answer is unavailable here and
why every other path has to be exact.

---

## Open

- **A give-up state for a thrashing inline cache.** A genuinely polymorphic site
  pays the miss cost on every call *and* two stores that bounce a cache line
  between cores. A saturating counter in the spare low bits of the site's pair
  pointer would stop the writes; whether that is worth a mask on the hit path is
  a measurement nobody can take until real workloads exist.
- **Whether a repeatedly dispatched runtime-built name earns a site cache**
  keyed on (class, name). Deferred to profiling, since the name path is already
  the slow path.
- **The compiled-code region under tiering**, if tiering ever arrives: it cannot
  meet the eviction checklist above, so it grows monotonically, and the inline
  cache's target half needs the entry-cell or vtable-slot shape named in
  [lowering.md](lowering.md).
