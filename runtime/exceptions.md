# Exceptions

## Scope

How `throw` / `try` / `catch` / `finally` are represented and lowered:
the two error channels and how the compiler picks between them, the
cost model, stack-trace materialization, and what unwinding must do to
reference counts and destructors. Object layout per
[classes.md](../model/classes.md) and [lowering.md](../model/lowering.md);
teardown per [object-lifecycle.md](object-lifecycle.md); memory
categories per [arenas.md](../model/memory/arenas.md).

**The requirement that drives every decision: a path that raises
nothing executes no instructions for exception handling.** And,
secondarily but explicitly: **an exception that is caught should cost as
little as possible**, because in a request-serving language caught
exceptions are ordinary control flow at the request level.

---

## Two channels

Every language that takes this seriously ends up with two mechanisms,
not one:

| | Rust | Go | Swift | Zig | C++ P0709 |
|---|---|---|---|---|---|
| recoverable | `Result` | `error` value | `throws` (error register) | error union | `throws` (value) |
| bug / rare | `panic` (unwind) | `panic` | traps | — | classic `throw` |

Limelight has the same two, named here:

**Channel U (unwind).** Table-driven. `try` compiles to nothing; the
handler is found from the return addresses calls already push. Zero
dynamic cost when nothing is raised, expensive when something is.

**Channel R (return).** The error travels back in the return channel.
The caller tests and branches. A couple of instructions per call,
cheap to raise.

**Channel B (bailout).** A `longjmp` to a point established at the
request root. It runs **no** user code on the way out — no destructors,
no `finally` — and it is **not catchable**. This is PHP's own
`zend_bailout`, used there for `memory_limit` exhaustion, `E_ERROR` and
`exit()`.

Channel B is not a weaker version of the other two; it answers a
different question. Unwinding and error returns are for failures user
code may handle. Bailout is for failures where continuing to run user
code is not possible or not meaningful.

setjmp/longjmp is rejected below as an *exception* mechanism because it
would charge every `try`. As a *fatal* mechanism it charges **one setjmp
per request**, which is nothing, and that difference is the whole reason
it belongs here and not there.

**What is different here from every language above: the programmer does
not choose the channel — the compiler does.** In the others the choice
is in the type system, so it is the author's judgement and it is
visible. Here `throw` and `catch` mean one thing in the source and the
compiler selects the lowering. That is the novel part of this design and
also where its risk sits (see "Risks").

### Allocation failure is channel B, not an exception

PHP does not make memory exhaustion catchable: exceeding `memory_limit`
is a fatal error, not a `Throwable`. Copying that is both compatible and
much cheaper — **allocation sites need no check at all.** No error
return, no landing pad, nothing.

Our arena makes the bailout itself nearly free: killing a request does
not require walking frames and releasing references one at a time, since
the request's memory is reclaimed in bulk at reset. Running user
destructors on this path would be wrong anyway — they allocate, and
there is no memory.

The process is killed only by a violated internal invariant (a corrupt
free list, an impossible block kind), where continuing is unsound. A
request that cannot get memory kills the request; the worker serves the
next one.

**Constraint that must be respected:** a `longjmp` may not cross a frame
holding a runtime lock — the block pool's mutex would stay locked
forever and the next thread would deadlock. The points at which bailout
is permitted must be defined as those where no runtime lock is held.
Skipped Rust `Drop`s are survivable (the arena reclaims), a skipped
`MutexGuard` is not.

### Why unwinding is the default and the universal one

Channel U requires no agreement between caller and callee: the caller's
handler is found from addresses, not from a signature. Channel R changes
the calling convention, so **both sides must agree**.

Therefore: **channel U is the fallback for anything the compiler cannot
see** — a class it does not know, an FFI boundary, a dynamically formed
call. No special casing is needed; the universal convention is simply
the one that was already universal.

---

## Execution modes

Limelight is intended to run in several modes, and **exceptions are the
subsystem most affected by which one**, because each host has its own
opinion about who owns the stack.

| Mode | Who owns unwinding | Native channel | Our channels |
|---|---|---|---|
| Embedded in the real PHP runtime | Zend | `EG(exception)` flag + `zend_bailout` | R at the boundary, B maps directly |
| Our own runtime | us | table-driven | U, R, B — the model described here |
| Hybrid | both, alternating | both | conversion at every crossing |
| WASM | the engine | `try_table`/`exnref`, or nothing | U if the engine has EH, else R only |
| JVM | the JVM | `athrow` + per-method tables | the JVM's; R unusual but possible |

The one property that makes this tractable: **the semantic model is
portable even where the implementation is not.** "A range of code is
protected by a handler, matched by type, with cleanup on the way out" is
exactly what the JVM's per-method exception tables and WASM's
`try_table` express natively. So source semantics map onto every mode;
what changes is who runs the unwinder and how the tables are encoded.

The second property, and it is the stronger argument for the hybrid than
frequency ever was: **channel R needs no host support whatsoever.** It
is return values. On any host where we do not own the stack, it is
available. That makes it the portability floor, not merely an
optimization — and it means the two-channel design would be required
even if every exception in every program were rare.

### Per-mode integration notes

**Embedded (Zend).** Zend owns the exception state. Our code must not
unwind through Zend's C frames; at every crossing it publishes into
`EG(exception)` and returns, which is precisely channel R's shape — a
flag check is exactly Zend's own model. `zend_bailout` and channel B are
the same mechanism, so fatal handling composes for free. Whether the
Zend VM is present or only its runtime changes what we call, not this
rule.

**Own runtime.** The full model in this document, and the only mode
where channel U is under our control end to end.

**Hybrid.** The expensive mode: our frames and Zend frames interleave,
so every crossing is a conversion — our in-flight unwind must become
`EG(exception)` on the way in, and a Zend exception must become our
raise on the way out. Conversion points have to be enumerated in the
ABI, not discovered.

**WASM.** No DWARF unwinding exists. Engines with the exception-handling
proposal give a table-shaped mechanism we can target; engines without it
leave channel R as the only option, which is survivable precisely
because R exists for other reasons. Trace materialization cannot read a
native stack here and must use the engine's frames or a shadow stack.

**JVM.** We own nothing about the stack, so exceptions are JVM
exceptions and the JVM's tables do the work. The mapping is natural
because the shapes agree; traces come from the JVM rather than from our
materialization, which means the trace design below applies only to
modes where we unwind.

---

## How the compiler chooses

Limelight compiles with the class hierarchy known
([classes.md](../model/classes.md)). That is what makes the choice
possible at all, and it is a language-level commitment, not an
optimization detail: anything outside that knowledge falls back to
channel U.

The analysis is a fixpoint over the call graph:

1. For each function, the set of exception classes it can raise: what it
   throws directly, plus what propagates out of its callees, minus what
   it catches.
2. For each exception class, a **frequency hint** — see below.
3. A function whose raisable set contains a frequent class uses channel
   R for that class; everything else stays channel U.

**Virtual calls: the convention belongs to the slot, not the method.**
A vtable slot has one calling convention, and an override may raise what
its base does not. With the hierarchy known, the compiler takes the
union over every override of that slot and assigns the slot one
convention. This is why closed-world knowledge is load-bearing rather
than merely convenient.

**Adapters.** Where a channel-R function is called from a context that
wants channel U, the caller checks the returned error and raises it —
a couple of instructions. The other direction is more expensive: calling
a channel-U function from a channel-R one needs a landing pad to catch
and convert. The compiler generates both; the second is the direction to
avoid, and the fixpoint should prefer assignments that minimise it.

### Where the frequency hint comes from — deliberately open

Frequency is a property of execution, not of the program, so the
compiler cannot derive it. The candidates are an attribute on the
exception class, a profile, or structural heuristics, and they can be
combined.

**This is intentionally left undecided, and nothing above depends on
it.** The mechanism needs only *a* per-class frequency input; changing
where that input comes from does not change the channels, the fixpoint,
the slot-convention rule, or the adapters. Settling it early would be
guessing, and it is cheap to settle late.

### The cost of channel R that is easy to miss

Channel R does not escape the work that unwinding does — it moves it
into ordinary code:

- **Cleanup still has to happen.** A function returning an error must
  release the heap references its locals hold and run `finally` before
  returning. That is the same code a landing pad contains, emitted on
  the error-return path instead.
- **The stack trace must be materialized eagerly.** With channel R each
  frame simply returns, so by the time the caller sees the error, the
  frame that raised it is already gone. The lazy scheme below does not
  apply; a channel-R raise pays its trace up front.

So channel R is cheaper to *raise* and more expensive per *call*, which
is exactly the trade the frequency hint is deciding.

---

## Channel U: how the tables work

`try` compiles to no instructions. The connection between a call site
and its handler is the **position of the instruction in memory**: per
function the compiler emits ranges

```
[code range] -> landing pad, action
```

and the unwinder walks the return addresses. Two phases:

**Phase 1 — search.** Walk frames, ask each whether it has a matching
handler. Nothing is modified.

**Phase 2 — cleanup.** Walk again, restoring each frame and entering its
landing pad, up to the frame phase 1 selected.

Phase 1 exists so that an exception with **no** handler leaves the
native stack intact for a debugger or core dump. (It is not needed to
preserve the *PHP-level* trace — that is materialized separately, see
below.)

Phase 1 also produces the information the trace design needs: the exact
set of frames about to die.

### What "zero cost" does and does not mean

Honestly stated:

- **No dynamic instructions** are executed for `try` on a path that does
  not raise. This part is true and is the whole point.
- **Codegen is still affected.** A call that can raise is an `invoke` in
  LLVM, which is a block terminator: it splits the control-flow graph
  and pins values the landing pad needs, which costs register allocation
  freedom and can add spills.
- **A function with no `try` at all still gets landing pads** if it
  holds heap references in locals, because unwinding past it must
  release them. This is the same cost C++ pays for destructors, and it
  is the dominant part of the code-size figure — not the tables.

So the accurate claim is "no dynamic cost on the non-raising path", and
`try` itself really is free. "Costs nothing at all" is not true and
should not be repeated.

---

## Matching a `catch`

**Class catch is O(1)**, using the Cohen display each class carries
([lowering.md](../model/lowering.md)): ancestors indexed by depth, so
matching is one indexed load and one compare, independent of hierarchy
depth. The action stores the target class **pointer** and its depth —
not an id: [classes.md](../model/classes.md) settled on full pointers
and no compressed ids.

Because it is a pointer, the action table needs a load-time relocation
or an indirection through a per-module table. That cost is real and is
the price of not having ids; it is paid once per module at load, not per
throw.

**Interface catch is not O(1), and that includes `Throwable`.** This is
the common case — `catch (\Throwable $e)` — so it deserves an explicit
answer rather than being glossed:

- interfaces are matched through the itable list, a search rather than
  an indexed load ([lowering.md](../model/lowering.md));
- the inline caches that make ordinary interface dispatch fast do not
  exist inside a shared personality routine, which sees a different
  class on every call.

Options, to be decided before implementation: reserve a bit in the class
flags for "implements Throwable" (making the catch-all a single test),
give the well-known root interfaces fixed slots, or sort the itable and
binary-search. The first is cheap and covers the case that actually
dominates.

**Classes not yet linked.** A `catch` of a class that has not been
loaded must fail to match *without* triggering loading. Action entries
therefore need lazy binding: unresolved entries compare unequal until
the class is linked, rather than forcing resolution from inside the
unwinder.

---

## The runtime boundary, and destructors

The runtime is Rust built with `panic = "abort"` in the release profile
and linked statically
([implementation-language.md](implementation-language.md)). Unwinding
through its frames is not permitted.

**This is not solved by "the runtime returns a status", because the
runtime calls PHP code.** `__destruct` is invoked from Rust frames
([object-lifecycle.md](object-lifecycle.md)), and in PHP a destructor
may throw during entirely ordinary execution, when the last reference
dies at a scope end. If that throw unwound, it would unwind through
Rust.

**Resolution: every runtime→PHP callback uses channel R.** Destructors,
collector callbacks, and anything else the runtime calls back into
return an error rather than raising. The signatures are ours, PHP does
not constrain them, and a destructor occupies one vtable slot, so the
convention is uniform by construction.

The runtime then decides what to do with a returned error according to
context, and the contexts differ sharply:

| Where | Policy |
|---|---|
| Destructor during normal refcount death | hand the error to the raising PHP frame, which raises it normally |
| Destructor during phase-2 cleanup | chain onto the in-flight exception as `previous`, continue unwinding |
| Destructor during **arena reset** | no live stack exists ([arena-reset.md](../model/memory/arena-reset.md)); report to the request's error sink and continue the fixpoint |
| Destructor from the cycle collector | same as arena reset |

The third row is the one that has no other answer: reset runs after the
request body has finished, so there is no frame to raise into. Zend
faces the identical situation at shutdown and reports rather than
propagates; this does the same, deliberately.

### The pending channel

For runtime entry points that can fail without calling PHP code, the
context carries the error:

```
LLContext {
    arena:    *mut Arena,
    pending:  *mut Object,    // Throwable, null when clear   [proposed]
    unwinding: bool,          // an exception is already in flight
}
```

`pending` does not exist in the implementation today (the context holds
only `arena`); this is the proposed extension.

`unwinding` is not decoration: without it a second failure during
cleanup cannot even be detected, and the rule "a destructor that throws
while unwinding chains onto the original" cannot be implemented.

**Which entry points can fail must be enumerated in the ABI**, because
the compiler emits the check only after those. Allocation is **not** on
that list — it is channel B and needs no check at all.

What remains is narrower than it first appears, and deliberately so:
the boundary where foreign code calls into ours, and runtime-initiated
destruction (arena reset, the cycle collector).

Destruction on the *ordinary* refcount-death path is the contested case.
Putting it on this list would mean a check after every reference release
and every store barrier — the most frequent operations in the program,
on the non-raising path, which is the Zend model this document rejects
elsewhere. See the open defect below; it is not settled here.

### Foreign code in the middle

`ours → foreign → ours → throw` must not unwind: the foreign frames have
no tables of ours, and the runtime is built `panic = "abort"`.

The rule is therefore absolute: **wherever foreign code calls into ours,
the exception is captured at that boundary.** It becomes a plain return
to the foreign caller, and is re-raised once control is back in our
frames. Every such callback carries a capture wrapper — a real, local,
visible cost.

This applies to runtime→PHP callbacks and to user FFI callbacks alike.

---

## Stack traces

PHP captures the trace when the `Throwable` is **constructed**, not when
it is thrown, and that is observable: `(new Exception)->getTrace()`
returns a full trace for an exception never thrown. Two modes, matching
PHP's `zend.exception_ignore_args`: with arguments and without.

### Materialization: only the frames that are about to die

Unwinding does not destroy the stack — it destroys the **segment**
between the raise point and the handler. Everything below the handler
survives. So only that segment need be copied into the exception, and
phase 1 identifies it exactly, before phase 2 destroys anything.

The order falls out on its own:

```
phase 1: find the handler   ->   the doomed segment is now known
materialize:                     copy only that segment
phase 2: destroy it
```

The work is proportional to **the distance to the handler**, not to
stack depth. A nearby `try/catch` materializes a handful of frames. If
there is **no** handler, phase 2 never runs, the whole stack survives,
and nothing needs materializing at all.

### Capture is cheap; symbolization is lazy

Materializing a frame records its **return address** — a number. It does
not resolve function, file or line. That resolution happens only if the
program actually asks for `getTrace()` / `getTraceAsString()`, and an
exception that is caught and swallowed never pays it.

This requires a PC→(function, file, line) side table present in release
builds, and for JIT-compiled code, registered at compile time. That is a
real size cost and belongs in the budget.

### Validity of the surviving segment

The frames below the handler can be walked lazily — but only while they
are alive. If the exception is stored somewhere longer-lived and
inspected later, they are gone.

**The escape barrier already detects exactly this event.** Storing an
exception into a longer-lived container is an escape, which the barrier
must notice anyway for arena reasons
([arenas.md](../model/memory/arenas.md)); materializing the remainder of
the trace there costs no new check on any hot path.

### Arguments must not hold references

In the with-arguments mode, holding live references to arguments would
make every argument of every captured frame an escapee, promoting a
large part of the request out of the arena at reset — losing precisely
what the arena is for.

It is also unnecessary for format compatibility. `getTraceAsString()`
renders objects as `Object(ClassName)`, arrays as `Array`, strings
truncated, scalars by value. So a compatible trace stores: scalars by
value, truncated string copies, and for objects **the class name only** —
and class metadata is immortal, so referencing it holds nothing alive.

Live values are needed only by the array form of `getTrace()`. That is
therefore a separate, heavier mode, and its cost in promotion must be
documented rather than discovered.

### Inlining and generators

**Inlined calls** have no physical frame but must appear in a PHP trace,
so the PC→frame mapping has to expand one address into several logical
frames.

**Generators and fibers break the "walk down the stack" assumption**
([actors.md](actors.md) already depends on fibers). A generator has its
own stack segment, so the logical PHP caller chain crosses a context
switch and is not contiguous. Worse, a suspended generator's frames are
alive but their lifetime is **independent** of the catching frame: the
generator may be destroyed first, which unwinds its segment separately
so its `finally` blocks run. So "still alive" cannot be decided from the
catcher's frame alone.

This is unresolved and is the main open item in this document.

---

## Semantics

Where this deviates from PHP it must say so; silent deviation in a
PHP-compatible language is a defect.

**Chained exceptions.** A second exception raised during unwinding — in
a destructor or a `finally` — chains onto the in-flight one as
`previous` and unwinding continues, as PHP does. This requires the
`unwinding` flag above.

**`finally`** is a landing pad that runs and resumes unwinding rather
than stopping it, which needs no separate mechanism. A `finally` that
raises, or that returns, replaces the in-flight exception per PHP rules;
its normal-path copy is ordinary code.

**Uncaught exceptions.** Phase 2 still runs to the root, or heap
references held by locals leak permanently — they are in no
release-at-reset list. The user handler runs at the root, above the
frame that owns the C-ABI boundary to the host loop.

**Actors.** A synchronous actor call that fails delivers the `Throwable`
as its reply, which means the exception and its materialized trace are
subject to the payload copy discipline ([actors.md](actors.md)). An
uncaught exception with no awaiting caller is a supervision question,
still open there.

---

## Platform reality

The custom parts of this design are the **action table contents** and
the **personality routine**, not the container format. LLVM emits the
LSDA and CFI from `invoke`/`landingpad`; replacing those encodings means
patching LLVM, which is not proposed. What is proposed is standard
tables carrying our own typeinfo payloads, interpreted by our own
personality.

**Windows is a different IR shape, not a different encoding.** Funclet
EH uses `catchswitch`/`catchpad`/`cleanuppad`, and LLVM's funclet
lowering keys off recognized personalities — an unrecognized custom
personality is treated as landingpad-style, which windows-msvc does not
support. This constrains how much personality customization is available
there and must be settled before committing to a custom personality.

**JIT-compiled code must register unwind information at runtime**
(`RtlAddFunctionTable`, `__register_frame`). For a language that is both
AOT and JIT this is a real subsystem, not a detail.

**Size.** The `.eh_frame`/CFI portion is typically the dominant EH
contribution, and it is the part this design **cannot** shrink: every
frame must stay walkable for phase 1. The savings claimed here are in
landing-pad code and action tables only.

---

## Risks

**The channel is invisible in the source.** In every prior art the
programmer picks, so the cost is legible. Here a frequency hint silently
changes calling conventions across the program. A stale attribute
produces a slow build with no diagnostic. Mitigation: make the chosen
channel inspectable in build output, and treat the attribute as a hint
that a profile overrides.

**Whole-program compilation.** If a function's convention depends on
global analysis, it cannot be compiled in isolation — the decision moves
to link time. GraalVM native-image and .NET NativeAOT accept this
consciously; the cost is incremental build complexity.

**Two lowerings, one semantics.** `catch` must behave identically
regardless of channel, including trace contents and `finally` ordering.
Every semantic rule above has to hold in both, and the test suite must
run the important cases under both lowerings.

---

## To think about: a call into PHP may never return

The runtime calls PHP code in several places — `__destruct`, collector
callbacks, anything user-supplied. Every one of those call sites is
written as if control comes back. **It may not.**

PHP code can `exit()`, hit a fatal, or be killed by a limit. Whatever
mechanism carries that out, it does not return to the Rust frame that
made the call. So the frame's assumptions never get to unwind: a lock it
holds stays held, a half-built structure stays half-built, a block taken
from the pool but not yet owned stays in limbo, an entry appended to a
log without its counterpart stays inconsistent.

This is the mirror image of the foreign-code rule above. There, foreign
frames are the ones an exception must not cross. Here, **our own runtime
frames are the foreign ones** — from PHP's point of view they are native
code it is escaping through.

The candidate invariant, to be confirmed or replaced after thought:

> No runtime frame may call into PHP while holding a lock, owning a
> half-constructed object, or having cleanup that must run afterwards.
> Everything must be consistent *before* the call, because there may be
> no "after".

If that holds, it is checkable — a call into PHP is a barrier, like a
safepoint — and it constrains where destructors and callbacks can be
invoked from far more than the exception design alone suggests.

**Not resolved. Recorded so it is not rediscovered late.**

---

## Open defects

Found by adversarial review of the previous revision and **not yet
resolved**. They are listed because a design document that hides its
holes is worse than one that has them: each of these invalidates part of
what is written above, and the reader needs to know which part.

**1. Trace capture cannot be lazy the way the section above describes.**
The escape barrier fires only on `RequestArena → longer-lived` stores,
so it does not see the events that actually end a frame's life: an
exception stored arena→arena, an exception chained as `previous`, or
simply `return new Exception()` — where the constructing frame dies by
an ordinary return, having never been part of any doomed segment. Since
PHP captures at *construction*, that frame belongs in the trace. The
likely fix is that capture of the return-address chain is always eager
(it is a copy of machine words, cheap) and only symbolization is
deferred, with the doomed-segment scheme surviving as an optimization
where the compiler can see construction, throw and catch together.

**2. Channel R and dynamically dispatched calls.** Knowing every class
is not the same as knowing the callee. `classes.md` records that the
untyped-receiver path — inline cache into the method table — is the
common case, and an inline cache holds one code pointer called with one
baked convention. So channel R appears usable only at statically
resolved sites, with every function additionally needing a
channel-U entry point for erased calls to target. That would narrow
channel R considerably, and the cost model above does not account for
it.

**3. The pending check on the ordinary destruction path.** As written,
"check after anything that can run a destructor" puts a test after every
reference release and every store barrier — the hottest operations
there are, on the non-raising path. Candidate resolution: split
`ll_object_die` so that the `__destruct` call for ordinary refcount
death is issued by *generated* code, in a PHP frame that can unwind
normally, leaving channel R for genuinely runtime-initiated destruction
(reset, collector). The runtime is already half-shaped for this —
`ll_release` returns whether the entity died and the caller runs
teardown.

**4. A channel-R error in flight is invisible to the runtime.** It
travels in a return slot, so neither `pending` nor `unwinding` is set,
and the per-context policy table above cannot distinguish "a destructor
failed during normal death" from "a destructor failed while an error was
already propagating". Either compiled code owns chaining on every
error-return cleanup path, or propagation must set a context flag — with
the per-hop cost that implies.

**5. Closed world versus autoloading.** The slot-convention rule needs
every override known, while `classes.md` documents autoloading as an
open world. A class loaded later that overrides a slot cannot change a
convention already compiled into every call site; it must be coerced to
the frozen one. That rule is not written anywhere, and there is no
link-time convention fingerprint to detect a mismatch between separately
built components.

**6. The channel-R ABI is unspecified.** Where the error physically
travels when every function already returns a 16-byte `Value`; what a
function does when its raisable set contains one frequent and one rare
class; how the caller tests the class cheaply, given that the interface
case is not O(1).

**7. Contradiction on uncaught exceptions.** One section says phase 2
never runs when there is no handler, another says it must run to the
root or heap references in locals leak. Both cannot be true, and which
one holds also decides whether the "stack stays intact for a debugger"
rationale survives.

**8. Cyclic garbage destructors are cited as settled and are not.** The
implementation does not run `__destruct` for cyclically-dead objects at
all; that is its own open problem, larger than the error channel, and
this document should not lean on it.

---

## Rejected

**Choosing the channel by an attribute alone, at the call site.** An
attribute on the exception class cannot decide a calling convention: at
a virtual call site the callee is not known, and two overrides of one
slot may disagree. It works only as a *hint* feeding whole-program
analysis, which is what is proposed above.

**A register holding the current handler, saved at `try`.** Two or three
instructions per `try` and none per call — genuinely cheaper on the
happy path than the Swift model, and one frame slot can serve several
`try` blocks. It fails on frames with **no** `try`: they may hold heap
references and objects with `__destruct`, so a direct jump to the
handler skips cleanup they need. Fixing it means every frame with
cleanup registers itself, which is nearly every frame, moving the cost
from the rare `try` to the common call. This is 32-bit Windows SEH,
whose frame chain hung off `fs:[0]` with a per-frame state number; x64
abandoned it for table-driven unwinding for exactly this reason.

**setjmp/longjmp.** Registers a frame on entry and unregisters on exit,
paying when nothing is thrown.

**A flag checked after every operation (Zend).** Right for an
interpreter, where dispatch dominates; for compiled code the check *is*
the cost.

---

## Deferred: direct jump when nothing needs cleanup

When the compiler can prove no frame between raise and handler needs
cleanup, the raise lowers to a jump, skipping both phases. Rarely
applicable in C++; often applicable here, because arena objects need no
cleanup and whole call chains can hold nothing but arena references.

Gated on measurement: it costs a few instructions at `try` in exchange
for a cheaper raise.

---

## What is measured

1. **Codegen.** A function with `try` versus without: the difference
   must be confined to table contents and to the CFG effects of `invoke`
   on calls that can raise. Any dynamic instruction attributable to
   `try` itself is a defect.
2. **Throughput.** A call-heavy benchmark with and without enclosing
   `try` blocks must be indistinguishable.
3. **Raise cost, both channels**, published rather than assumed — it is
   the number the whole channel-selection design turns on.
4. **Size**, with tables, landing pads and CFI counted **separately**;
   they have different causes and different fixes, and one lumped
   percentage is uninformative.
5. **Trace cost**: materialization separated from symbolization, and
   with-arguments separated from without.
