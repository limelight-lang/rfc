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

Emitted through the unified store barrier slot
([strategies.md](../gc/strategies.md)), the same hook that carries ARC
operations and any strategy barrier.

The barrier compares the 2-bit category fields of the stored value and
the destination's owner — one XOR + test on flags words that the
retain path has already loaded. Same category (the overwhelmingly
common case): no extra work. On the dangerous direction (arena value
into a longer-lived container) it **only logs the slot into the
arena's remembered set**; nothing is copied at the store. The fate of
escaped objects is decided lazily at arena death, per 32 KB block —
retention in place or evacuation ([arena-reset.md](arena-reset.md)).
The reverse direction (heap value into an arena container) goes to the
release-at-reset list ([arenas.md](arenas.md)).

### Slot category resolution

(Closes what an earlier revision left open.) The destination category
is read from the containing entity's header flags — a slot's lifetime
*is* its owner's lifetime. Slots with no owning entity (globals,
static properties) are long-lived by definition and known at compile
time: the compiler emits those stores with the destination category as
a constant, no runtime lookup at all.

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
