# Exceptions

## Scope

How `throw` / `try` / `catch` / `finally` are represented and lowered:
the cost model, the table format, the boundary with the Rust runtime,
and what unwinding must do to reference counts and destructors. Object
layout per [classes.md](../model/classes.md); teardown per
[object-lifecycle.md](object-lifecycle.md); memory categories per
[arenas.md](../model/memory/arenas.md).

**The requirement that drives every decision here: a program that
throws nothing pays nothing.** Not "pays little" — pays no instructions
at all on the path where no exception is raised.

---

## The shape of the problem

In a PHP-like language almost every call *can* throw and almost none
do. Any scheme charging per call, or per `try`, is charging the common
case for the rare one. That rules out more designs than it sounds like,
so the alternatives are written out in "Rejected" below rather than
left implicit.

An exception is an ordinary object (`Throwable`), allocated like any
other, so it participates in the normal memory model. Its class is
matched against `catch` clauses by the ordinary `instanceof` rule.

---

## Decision: table-driven unwinding

`try` compiles to **nothing**. No prologue, no registration, no state
variable, no register write. A function containing `try` emits the same
instructions as one without it.

The connection between a call site and its handler is expressed by
**the position of the instruction in memory**. Per function the
compiler emits a side table of ranges:

```
[code range] -> landing pad, action
```

At a throw, the unwinder reads the chain of return addresses that the
calls already pushed for their own `ret`, and for each looks up which
function and which range it falls into. Nothing had to be recorded at
runtime because the information was already there.

### Two phases, and why

**Phase 1 — search.** Walk the frames, ask each whether it has a
matching `catch`. Nothing is modified: no register restored, no memory
written.

**Phase 2 — cleanup.** Walk again, now restoring each frame and
entering its landing pad to run cleanup, until reaching the frame that
phase 1 selected.

The split exists so that an exception with no handler anywhere leaves
the stack **intact** at the point of the throw. Unwinding eagerly would
destroy the evidence before discovering there was nowhere to go, and an
uncaught exception is precisely when the stack is worth the most.

### Consequences to accept

- **Throwing is expensive**: two passes over the frames plus table
  decoding. Exceptions must remain exceptional; they are for request
  errors, not control flow.
- **The optimizer is constrained around calls that can throw.** In LLVM
  such a call is an `invoke`, which is a block terminator, so it splits
  the control-flow graph and pins values needed by the landing pad.
- **Binary size grows.** For C++ the figure usually quoted is ~7% of
  code and data combined — but most of that is landing-pad *code*, not
  tables, and see "Cost" below for why ours is smaller.

---

## Our own table format and O(1) matching

We emit the IR, so we are not obliged to use the C++ exception tables
or the C++ matching procedure. Two places where our own is better:

**Matching a `catch` is O(1).** C++ compares `type_info` pointers and
walks the hierarchy. We already carry a **Cohen display** on every class
([classes.md](../model/classes.md)): ancestors indexed by depth, so
`instanceof` is one load and one compare regardless of depth. A `catch`
action therefore stores a class id and a depth, and matching is:

```
display[depth] == wanted_class_id
```

No RTTI, no string comparison, no hierarchy walk, and the same code
path `instanceof` already uses.

**The action table is smaller**, because that is all an action needs:
a class id, a depth, and which landing pad. Interface `catch` uses the
existing itable id check instead.

Encoding follows the usual discipline, and it is not a place to
innovate: offsets relative to the function start rather than absolute
addresses (shorter, and no load-time relocations), variable-length
integers, frame-unwind information as a delta bytecode rather than a
per-PC table, and a sorted index for logarithmic lookup.

---

## The runtime boundary: never unwind through Rust

The runtime is Rust compiled with `panic = "abort"` and linked as a
static library ([implementation-language.md](implementation-language.md)).
Unwinding through its frames across the C ABI is undefined unless every
such frame is built to allow it, and turning that on would put unwind
tables and landing pads into the allocator's hot paths — the exact
opposite of what this crate is for.

**Therefore: the runtime never unwinds. It reports.**

A runtime operation that fails writes a pending `Throwable` into the
context and returns a sentinel; the *generated code* observes it and
raises. Concretely, on the ABI:

```
LLContext {
    arena:   *mut Arena,
    pending: *mut Throwable,   // null when clear
}
```

The check is one load and one branch, and it is emitted **only after
calls into the runtime that can fail** — not after PHP-to-PHP calls,
which is where the volume is. So the register-check model is used
exactly where it is cheap and the table model everywhere else.

This also gives the memory manager the failure contract it currently
lacks: see "Out of memory" below.

---

## Unwinding, reference counts and destructors

This is where our memory model changes the economics, and it is the
main reason the cost is lower for us than for C++.

**Arena objects need no cleanup at all.** Objects in the request arena
(or an actor's arena, [actors.md](actors.md)) are not individually
counted and are reclaimed in bulk at reset
([arena-reset.md](../model/memory/arena-reset.md)). An unwind that
passes over them does nothing. In C++ every local object with a
destructor forces cleanup code; for us, most locals force none.

**Heap references in locals must be released.** A local holding a
`GcHeap` reference owns a count, and unwinding past it must drop that
count or the object leaks. This is what our landing pads are mostly
made of.

**`__destruct` runs during unwinding** for objects whose last reference
dies this way, through the same three-phase teardown as any other death
([object-lifecycle.md](object-lifecycle.md)) — including the guard that
keeps a transient `$this` from re-entering teardown.

**An exception escaping a destructor** that is itself running during
unwinding is an error, not a nested unwind: the runtime is already
mid-unwind and has no meaningful place to put a second exception. It
terminates the request, and the original exception is the one reported.

### `finally`

A `finally` block is a landing pad that runs and then **resumes**
unwinding rather than stopping it — exactly the same shape as a frame
that has cleanup but no `catch`. It needs no separate mechanism.

Its normal-path copy (when the block is left without an exception) is
ordinary code and costs what it costs; only the unwind copy is cold.

---

## Out of memory, and other runtime failures

Today the memory manager is inconsistent: the huge-allocation path
returns null while pooled paths assert and abort. Aborting is wrong
for a server — one request that cannot get memory must not take the
process with it.

With the pending-exception channel above, the contract becomes uniform:

| Failure | Response |
|---|---|
| Allocation cannot be satisfied | pending `OutOfMemoryError`, request unwinds |
| Size/alignment outside the documented ABI range | pending `Error` — a compiler or FFI bug, but recoverable |
| Internal invariant violated (corrupt free list, bad block kind) | abort; there is nothing safe to continue into |

The distinction is the point: **resource exhaustion and caller mistakes
are recoverable; a broken invariant is not.** Only the third row may
kill the process, and it is the only one where continuing would be
unsound.

Allocation on the unwind path is the awkward case — constructing
`OutOfMemoryError` must not itself require an allocation that fails.
It is preallocated once per context at startup, like the immortal
class metadata it points at.

---

## Windows and ELF

Two different table formats, both supported by LLVM but not the same
lowering: ELF targets use the Itanium-style scheme with `.eh_frame`,
while Windows x64 uses `RUNTIME_FUNCTION`/`UNWIND_INFO` with funclets,
where cleanup and catch bodies are separate functions with a special
prologue.

This is a real fork in the code generator and belongs in the design
rather than being met later as a surprise. The language-level semantics
above are identical on both; what differs is how landing pads are
emitted and how the personality routine is invoked.

---

## Rejected alternatives

**A register holding the current error (Swift, and P0709 for C++).**
The caller zeroes a callee-saved register, the callee writes the error
into it, and after each call the caller tests and branches. Cheap,
predictable, no unwinder, no tables — and rejected here for one reason:
in this language nearly every call can throw, so it charges a branch
after nearly every call in the program. That is the one cost tables
remove entirely. It is however exactly right at the runtime boundary,
where it *is* used.

**A register holding the current handler address, saved at `try`.**
Two or three instructions per `try` and none per call, which is
genuinely cheaper on the happy path than the Swift model, and the
per-frame slot can be shared by several `try` blocks in one function.

It fails on frames that have no `try`. Function `B`, called from inside
`A`'s `try`, may hold heap references and objects with `__destruct`;
its frame must be unwound properly, but it registered nothing, so a
direct jump to `A`'s handler skips it. Fixing that means making every
frame *with cleanup* register itself — which in this language is nearly
every frame, so the cost moves from the rare `try` to the common call
and ends up worse than Swift.

This design is not hypothetical: it is 32-bit Windows SEH, with its
frame chain rooted at `fs:[0]` and a per-frame state number updated at
region boundaries. x64 Windows abandoned it for table-driven unwinding
for precisely the reason above.

**setjmp/longjmp.** Every `try` registers a frame on a global list, so
it pays on entry and exit even when nothing is thrown. The historical
predecessor to all of the above and the thing "zero-cost" was named in
opposition to.

**Checking a flag after every operation (Zend).** PHP's own engine sets
`EG(exception)` and the VM tests it. Reasonable for an interpreter,
where the dispatch loop dominates anyway; a poor trade for compiled
code, where the test *is* the cost.

---

## Deferred optimization: direct jump when nothing needs cleanup

When the compiler can prove that no frame between the `throw` and its
handler requires cleanup, unwinding can be lowered to a direct jump
using a saved handler address and stack pointer, skipping the two-phase
walk entirely.

Ordinarily this applies rarely. Here it should apply often, because
arena objects need no cleanup and locals holding only arena references
leave nothing to release — so whole call chains can be cleanup-free.

Deliberately *after* the general mechanism, and gated on a measurement:
it costs a few instructions at `try` in exchange for a much cheaper
throw, which is only worth it if throws are frequent enough to matter.

---

## What is measured

"Almost zero" is a claim, and this crate does not accept unmeasured
claims ([WORKFLOW](https://github.com/limelight-lang/model)). The
checks:

1. **Instruction-level.** The generated code for a function with `try`
   must be identical to the same function without it, aside from table
   contents. Compare the emitted IR; any difference is a defect.
2. **Throughput.** A call-heavy benchmark with and without enclosing
   `try` blocks must be indistinguishable.
3. **Size.** Record the table and landing-pad cost separately — they
   have different causes and different fixes, and lumping them is how
   the "7%" number becomes uninformative.
4. **Throw cost.** Measured and published rather than assumed, since it
   is the price paid for everything above.
