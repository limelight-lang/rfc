# Cross-Arena Object Promotion

## Core Principle

The fundamental division is binary: **does this object outlive the current request?**

- **No** → request arena
- **Yes** → everything else (long-lived arena, immortal, GC heap)

All further subdivisions (long-lived vs immortal vs GC heap) are
implementation details. The memory category lives as a 2-bit field in
the entity's header flags ([arenas.md](arenas.md),
`ll-model/src/refcount.rs`); the barrier compares exactly these bits.

---

## Problem

An object allocated in the request arena may need to outlive the request — for example, when assigned to a long-lived slot (global variable, persistent cache, class-level property). The request arena will be reset at end of request, so the object must be promoted before that happens.

---

## Solution: Static Analysis + Barrier Fallback

Two complementary mechanisms cover 100% of cases.

### 1. Static Analysis (compile-time)

The compiler determines the target category at allocation time and allocates directly there. No runtime check, no barrier logging, no copy.

Cases the compiler can resolve statically:
- Object created and dies within one function → request arena, guaranteed
- Object assigned to a global variable → long-lived arena, guaranteed
- Object assigned to a class-level persistent slot → long-lived arena, guaranteed

Cases that fall through to the dynamic barrier:
- Object passed to an external function (may be stored anywhere)
- Object stored in a dynamically-typed container
- Any case where the compiler cannot prove the destination lifetime

### 2. Category Barrier Fallback (runtime)

Composed into the store barrier's micro-operations
([strategies.md](../gc/strategies.md)), alongside the ARC operations and
any strategy barrier.

The barrier compares the stored value's 2-bit category field against the
destination's, where the destination category is **`owner_cat`, a
parameter the compiler supplies** (not a load from the owner's flags,
which do not exist for every destination). Same category (the
overwhelmingly common case): no extra work. On the dangerous direction
(arena value into a longer-lived container) it **only counts the
escape** — a hold-count in the escapee's own header, plus one append to
the arena's escapee list on the 0 → 1 transition
([arenas.md](arenas.md)). The holder's slot is never recorded, precisely
so that a holder dying before reset cannot dangle it. Nothing is copied
at the store. The fate of escaped objects is decided lazily at arena
death, per 64 KB block — retention in place or evacuation
([arena-reset.md](arena-reset.md)). The reverse direction (heap value
into an arena container) goes to the release-at-reset list
([arenas.md](arenas.md)).

### Slot category resolution

(Closes what an earlier revision left open.) `owner_cat` is always a
compiler-supplied parameter — a slot's lifetime *is* its owner's, and
the compiler knows it at the store site. A slot in a heap or arena
object takes its owner's category; a slot with no owning entity (a
global, a thread-local static block, which has no `RcHeader` at all) is
long-lived by construction. Either way the destination category reaches
the barrier as a value, never a runtime load from a header that may not
be there.

---

## Rejected Alternatives

- **Arena tag in pointer high bits** (bits 63–62, ZGC-style colored
  pointers — the original design of this document). Killed by block
  retention: [arena-reset.md](arena-reset.md) recategorizes surviving
  objects *in place* by rewriting their header bits, which is possible
  precisely because the category lives in one place. A pointer tag
  would have to be rewritten in every existing pointer to the object —
  exactly the reference-fixup problem the whole design avoids. The
  header comparison is also effectively free, since retain loads the
  flags word anyway.
- **Eager copy + forwarding pointer at the barrier** (also the
  original design). Superseded by deferred promotion: copying at the
  store pays for escapes that may never survive to arena death,
  requires identity fixes at every barrier hit, and forwarding
  pointers would have to be left in live arena memory. Deferral
  batches all of it into one moment where the remembered set is a
  complete list of incoming references.

---

## Relationship to ARC

Before promotion an arena object has no refcount history (arena
semantics: not counted). What happens after is owned by
[arena-reset.md](arena-reset.md): objects in retained blocks become
sticky and are managed by the tracing component; evacuated objects
move into the GC heap and live under the active strategy.
