# Arrays

## Scope

The array entity: the three storage implementations behind the single
`array` class, transition rules, and the external contract. Plugs into the
Box/unboxed and COW contracts from [values.md](values.md).

The detailed hashtable design (bucket layout, collision strategy,
iteration order preservation) is a future document; this one fixes the
architecture.

---

## `ArrayInterface`, One Class, Three Storage Implementations

**Decision**: `array` implements `ArrayInterface` (the language-facing
type), but unlike the string split
([strings.md](strings.md#mutability-modes-stringinterface-two-classes)),
the three storage strategies below stay **internal to one class**, not
separate classes: transitions between them (see below) never change the
object's `class` pointer, so there is no `!invariant.load` conflict here
— the storage-strategy tag is an internal bit, invisible to `instanceof`.

To the language, `array` is a single final class (same
construction as `string`, see [strings.md](strings.md): no per-instance
class pointer, devirtualized methods). Internally it has three storage
strategies, chosen per array:

| # | Storage | Element | When |
|---|---------|---------|------|
| 1 | **Typed vector** | Unboxed (raw i64 / f64 / ptr) | The compiler has **proven** all elements share one type |
| 2 | **Mixed vector** | Box (16 B) | Dense integer keys `0..n-1`, heterogeneous values |
| 3 | **Ordered hash** | Box (16 B) | String keys, sparse indices: full PHP array semantics |

This is the elements-kinds strategy of V8 / storage strategies of PyPy,
with Zend's packed-array optimization as the direct analog of #2.

### Why #1 pays off

A proven `array<int>` stores 8 bytes per element instead of 16, iterates
over a contiguous machine array, and its arithmetic reads need no tag
dispatch: effectively a C array with PHP syntax.

---

## Transition Rules

- **1 never transitions.** It exists only where the compiler proved
  monomorphism; the proof is static, so the representation is final.
- **2 → 3** happens at runtime when the array stops being a dense list:
  insertion of a string key, or creation of a hole/sparse index. Same
  trigger as Zend packed→hash.
- **3 never goes back** (within one array's lifetime; a rebuilt array may
  start packed again).

Transitions replace the storage under the same entity: the array's
identity, refcount, and COW state are unaffected.

---

## External Contract

- An array is a refcounted heap entity beginning with `RcHeader`.
- **COW by default**: the flag-based protocol from
  [values.md](values.md): refcount always maintained, write with
  `refcount > 1` separates. Separation copies the storage in its current
  representation.
- Elements are Values: Box slots in #2/#3, raw unboxed values in #1.
- Nested arrays are pointers to child array entities; separation is
  shallow (children are shared until written, standard COW recursion).
- Arrays created in the language are always managed RC/COW entities.
  At the FFI boundary a foreign buffer may be viewed as an array
  without copying; see
  [zero-abstraction.md](memory/zero-abstraction.md).
