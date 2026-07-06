# Cross-Arena Object Promotion

## Core Principle

The fundamental division is binary: **does this object outlive the current request?**

- **No** → request arena
- **Yes** → everything else (long-lived arena, immortal, GC heap)

All further subdivisions (long-lived vs immortal vs GC heap) are implementation details. The write barrier checks exactly this one bit. Arena tag in the pointer encodes this as the highest bit.

---

## Problem

An object allocated in the request arena may need to outlive the request — for example, when assigned to a long-lived slot (global variable, persistent cache, class-level property). The request arena will be reset at end of request, so the object must be promoted to the long-lived arena before that happens.

---

## Solution: Static Analysis + Write Barrier Fallback

Two complementary mechanisms cover 100% of cases.

### 1. Static Analysis (compile-time)

The compiler determines the target arena at allocation time and allocates directly there. No runtime check, no write barrier, no copy.

Cases the compiler can resolve statically:
- Object created and dies within one function → request arena, guaranteed
- Object assigned to a global variable → long-lived arena, guaranteed
- Object assigned to a class-level persistent slot → long-lived arena, guaranteed

Cases that fall through to the write barrier:
- Object passed to an external function (may be stored anywhere)
- Object stored in a dynamically-typed container
- Any case where the compiler cannot prove the destination lifetime

### 2. Write Barrier Fallback (runtime)

This check is emitted through the unified store barrier slot
([strategies.md](../gc/strategies.md)), the same hook that carries ARC
operations and any strategy barrier.

Every pointer store checks whether a cross-arena assignment is happening. If a request-arena object is being stored into a long-lived slot — the object is copied to the long-lived arena and the slot is updated to the new address.

#### Arena tag in pointer (fast check)

Arena metadata is stored in the high bits of the pointer. In 64-bit address space the upper bits are unused:

```
bits 63–62: arena tag
  00 = request arena
  01 = long-lived arena
  10 = immortal
  11 = GC heap (Immix)
```

Cross-arena check = one bitmask operation, ~1 cycle. Write barrier only copies when tags differ — which is the rare case.

This is the same technique ZGC uses with colored pointers, applied here for arena discrimination rather than relocation.

#### Write barrier protocol

```
store $value → $slot:
  if arena_tag($value) == REQUEST
  and arena_tag($slot) == LONG_LIVED:
    $value = copy($value, long_lived_arena)
    update forwarding pointer at old location
  store $value → $slot
```

---

## Open Question: Lifetime Tracking

> **TODO**: The write barrier requires knowing at runtime whether a destination slot is long-lived or request-scoped. This means every slot (object field, variable, container entry) must carry or imply its arena. The mechanism for tracking slot lifetimes needs to be designed — options include slot-level tags, type-level annotations, or inference from the owning object's arena.

---

## Relationship to ARC

Objects promoted from request arena to long-lived arena enter the ARC lifecycle at the moment of promotion. Before promotion they have no refcount (request arena semantics). After promotion they are reference counted normally.
