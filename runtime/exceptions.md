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

**Decided: channel B is not needed.** Every candidate for it turned out
to be an ordinary exception — memory exhaustion, `exit()`, and stack
exhaustion, each decided below. What remains is a violated internal
invariant, and that is not a channel: it aborts the process, because
there is nothing safe to continue into.

So the design has **two** channels, U and R, and the paragraph above is
kept only to record why a third was considered and rejected.

### Stack exhaustion is an exception as well

Detected by a guard page, and raised as an ordinary exception, so
`finally` blocks and destructors run as they do for anything else. Java
does exactly this with `StackOverflowError`, and it is catchable there
for the same reason.

The mechanism has one requirement that must be sized deliberately: the
guard region has to leave enough stack to *unwind*, and unwinding runs
user code — `finally` bodies and destructors — which consumes stack of
its own. A destructor that recurses could exhaust the reserve a second
time, so re-entering the reserve while already unwinding on it must be
refused rather than allowed to fault again.

(PHP 8.3 went the other way, checking stack depth explicitly with
`zend.max_allowed_stack_size` rather than trusting guard-page recovery.
Worth knowing about, since it is the fallback if guard-page handling
proves fragile on some target.)

**A note on Zend, because the embedded mode depends on it:** the
description of `zend_bailout` above is how one might build such a thing,
not how Zend actually behaves. Zend jumps to the *innermost* enclosing
`zend_try`, not the request root, and some `zend_catch` sites
deliberately swallow the jump. Anything the embedded mode says about
mapping onto it has to start from that.

**What is different here from every language above: the programmer does
not choose the channel — the compiler does.** In the others the choice
is in the type system, so it is the author's judgement and it is
visible. Here `throw` and `catch` mean one thing in the source and the
compiler selects the lowering. That is the novel part of this design and
also where its risk sits (see "Risks").

### Allocation failure is an ordinary exception

**Deliberate deviation from PHP**, and it is the better behaviour:
exceeding the memory limit in PHP is a fatal error that cannot be
caught, so a request loses everything it was doing. Here it is an
ordinary `Throwable`, caught by the ordinary rules.

That is only possible because the failure path is prepared in advance:

1. The memory manager **permanently reserves a block** for this
   situation. Constructing the exception object needs memory, and by
   definition there is none — so it must have been kept back.
2. On failure it does not give up immediately. First a coarser
   reclamation pass and a GC cycle, using the reserve as working room.
3. Only if that also fails does it raise.

So an exception here means the collector has already run and lost, which
is what makes it a legitimate error rather than a transient condition.

### `exit()` is an exception too

Not a bailout, not a separate shutdown mechanism: an ordinary raise that
unwinds by the ordinary rules.

Its class sits **outside the `Throwable` hierarchy**, so user code
cannot name it and `catch (\Throwable $e)` does not catch it. Only the
request root does. Matching costs nothing extra — it is the same
class test every catch already performs, and this one simply never
matches a user clause.

**`finally` blocks and destructors run on the way out.** This is a
deliberate deviation from PHP, where `exit()` bypasses `finally`
entirely, and it is the better behaviour: a `finally` releasing a lock
or closing a handle should not be skipped because the program chose to
stop. Resources are released by the same mechanism that releases them
for every other exception.

What this buys structurally is that a whole mechanism disappears. PHP
needs `exit()` to longjmp and then runs a separate shutdown phase to get
destructors executed. Here unwinding already does exactly that, so there
is no second path, no reserve to fund it, and no ordering question
between the two.

### `isThrow`: making "must not throw" enforceable

Allocation takes a flag. With `isThrow = true` it raises on failure and
the caller writes straight-line code. With `isThrow = false` it returns
null and the caller checks.

This is not a convenience. Everywhere throwing would be unsafe — inside
the runtime, while a lock is held, during arena reset where no PHP frame
exists to receive the exception — the call passes `false`, and raising
becomes **impossible rather than merely discouraged**. A rule enforced
by a parameter beats a rule enforced by discipline, which is how the
"no lock held across a raise" constraint stops being something to
remember.

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
| Embedded in the real PHP runtime | Zend | `EG(exception)` flag + `zend_bailout` | R at the boundary; B does **not** map directly — see above |
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
flag check is exactly Zend's own model. Whether the Zend VM is present
or only its runtime changes what we call, not this rule.

**Unsolved here, and it is the harder half:** Zend raises bailouts of
its own — any allocation of its crossing `memory_limit`, a user
`exit()` — while *our* frames sit between the raise and the enclosing
`zend_try`. That jump crosses our frames whether we like it or not, and
the only defence is a `zend_try` at every Zend→ours crossing, which
costs a setjmp per crossing. Also unaddressed: `EG(exception)` wants a
real `zend_object`, while our exceptions are arena-allocated with our
own headers, so the boundary needs a data conversion nobody has
designed.

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

### The channels are not exclusive: it is an ABI property of the function

This is below the language, not part of it. PHP has nothing to say here;
it is what the function's ABI declares.

A function's error behaviour has three independent parts:

- **which exception classes travel by return.** Declaring some does not
  forbid the others from unwinding: a function may return `E` and still
  throw everything else. Both channels can be live at once, and the
  common shape is exactly that — the frequent class by return, the rest
  by unwinding.
- **whether it can raise at all.**
- **`nothrow`** — a hard guarantee that it cannot, under any channel.

Declaring the return set may also be **forced** rather than inferred: a
function can be obliged to report a class by return even where the
compiler would not have chosen it.

`nothrow` is the most valuable of the three, and not for documentation.
A call to a `nothrow` function is an ordinary `call`, not an `invoke`,
so it does not terminate the basic block, does not split the
control-flow graph, and does not pin values for a landing pad. That is
the one cost of channel U listed above as unavoidable — and this is what
avoids it. It should be inferred wherever provable, not only where
written.

**Every entry point into the Rust runtime is `nothrow` by
construction.** That is not a separate rule but the same principle seen
from the caller's side: Rust never raises, it returns a status. So calls
into the runtime are plain `call`s, and the allocator's hot paths carry
no landing pads and no `invoke`-induced pressure on register allocation.
The boundary principle and the codegen property are the same fact.

**One function, one convention.** No dual entry points, no thunks, no
per-call-site variants — a function is compiled one way and that is what
it is. The compiler decides which, subject to any declaration forcing
its hand.

From that follows the rule that settles the dynamic-dispatch objection
without any machinery: **a function may use channel R only if every call
to it is statically resolved.** One erased call site — an inline cache,
a first-class callable, `__call` — and the function is channel U, since
an inline cache holds one code pointer and calls it one way
([lowering.md](../model/lowering.md)). The compiler sees every call
site, so this is a property it can check rather than a convention to
maintain.

The motivating case survives intact: a function that raises often — a
dispatcher failing 20-40% of the time — called directly by code that
handles the failure immediately. Unwinding twice per five calls is
exactly what channel U is bad at. That call is direct, so the function
qualifies.

**Adapters.** Where a channel-R function is called from a context that
wants channel U, the caller checks the returned error and raises it —
a couple of instructions. The other direction is more expensive: calling
a channel-U function from a channel-R one needs a landing pad to catch
and convert. The compiler generates both; the second is the direction to
avoid.


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

The runtime core is Rust, built `panic = "abort"` in the release profile
(`Cargo.toml`) and linked statically
([implementation-language.md](implementation-language.md) covers the
split, not the panic strategy). Unwinding through its frames is not
permitted.

**The governing principle: an exception is born in a Limelight frame.
The Rust core never raises — it returns a status.**

So allocation failure does not unwind out of the allocator. Rust reports
it; the Limelight-side entry point raises, and from there everything
follows the ordinary rules, because that frame is an ordinary
participant in unwinding with ordinary tables. This is how C++
`operator new` produces `bad_alloc`, and it costs the caller a
predictable, never-taken branch rather than a flag check.

If a case is ever found where an exception must genuinely originate
inside Rust, it is analysed on its own. The principle is not weakened to
accommodate it in advance.

### Destructors never propagate

`__destruct` is called by **generated code**, not from inside the Rust
teardown. And it is compiled so that it cannot let an exception escape:
any exception raised inside is caught at the destructor's own boundary
and handed back as a value.

The reason is not tidiness. **After the destructor, runtime code must
run — always.** Phases 2 and 3 release the object's children and return
its memory ([object-lifecycle.md](object-lifecycle.md)); skipping them
leaks the whole subgraph. A destructor that could unwind past that code
would skip it, so it must not be able to.

Two consequences worth stating plainly:

- **No check is needed after a reference release or a store barrier.**
  An earlier draft required one, which would have put a test on the most
  frequent operations in the program, on the non-raising path — the Zend
  model this document rejects elsewhere. Since a destructor cannot
  propagate, there is nothing to check for.
- **Every teardown completes.** No leaked children, no half-updated
  candidate buffer, no block left un-freed.

What is then *done* with a returned error depends on where the death
happened — raised in the frame that dropped the last reference, chained
onto an exception already in flight, or reported when there is no frame
at all (arena reset, the collector). That policy still needs work; the
part settled here is that the destructor boundary always returns.

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
that list. It raises an ordinary exception from a Limelight frame, so
there is nothing for a caller to check beyond the returned pointer.

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

### Capture is eager, symbolization is lazy

**Capture happens at construction, always, and copies the whole chain of
return addresses.** Not at throw, not partially, not conditionally.

That is forced by semantics rather than chosen: PHP builds the trace
when the `Throwable` is constructed, and `return new Exception()` proves
why nothing lazier works. The constructing frame dies by an *ordinary
return* — no unwinding, no store, no barrier of any kind — yet it
belongs in the trace. There is no event to hang laziness on, because
nothing happens.

The cost is bounded and small: copying one machine word per frame. It is
not resolution.

**Symbolization stays lazy.** A captured frame is a number. Turning it
into function, file and line happens only when the program asks for
`getTrace()` / `getTraceAsString()`, so an exception that is caught and
swallowed never pays for it — which is where the real cost lives.

This needs a PC→(function, file, line) side table in release builds,
registered at compile time for JIT code. A genuine size cost, and it
belongs in the budget.

### Deferred optimization: materialize only the doomed segment

Unwinding does not destroy the stack, only the **segment** between the
raise point and the handler; everything below survives. Phase 1
identifies that segment exactly, before phase 2 destroys anything, so
the order falls out on its own:

```
phase 1: find the handler   ->   the doomed segment is now known
materialize:                     copy only that segment
phase 2: destroy it
```

Work proportional to the distance to the handler rather than to stack
depth — and with no handler at all, phase 2 never runs and nothing needs
copying.

**This cannot be the general mechanism**, for the reason above: it is
tied to the throw, while capture is tied to construction. It is
applicable only where the compiler can see construction, throw and catch
together and prove the exception does not outlive them. Kept as an
optimization for that case, not as the design.

An earlier draft proposed hanging the lazy remainder on the escape
barrier. That does not work: the barrier fires on
`RequestArena → longer-lived` stores only
([arenas.md](../model/memory/arenas.md)), so it never sees an exception
stored arena-to-arena, chained as `previous`, or simply returned.

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

**Deferred until generators are designed, with one constraint already
clear.** Whether the trace walk has a problem at all depends on how they
are implemented, and the two options differ completely:

- **Flat state machine** (LLVM's `llvm.coro.*` intrinsics, as used by
  C++20 coroutines and Swift async): no separate stack exists. Live
  state across a suspension goes into a heap frame object; resuming is
  an ordinary call and suspending an ordinary return. While the
  generator runs, the logical PHP chain is contiguous on the native
  stack and there is nothing to hop across. A suspended generator has no
  frames at all, only a data structure.
- **A real separate stack**: the segmented walk below becomes real.

PHP's own rule points at the first for generators: `yield` is only legal
in the generator's own body, never from a function it calls, so there is
never a deep suspended segment to preserve. `Fiber::suspend()` has no
such restriction — it suspends from arbitrary depth — so fibers are the
ones that need a real stack, and the ones this problem is actually
about.

Still to think through: when the generator body has called into
something and the whole thing must be cut back to the generator's
suspension point, since after `yield` its state is no longer what the
inner frames assumed.

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

**There is no such thing as an uncaught exception.** The request root
always has a handler — it is what turns a failure into a response and
what the host loop expects. So phase 1 always finds one and phase 2
always runs to it, which is what keeps heap references held by locals
from leaking: they are in no release-at-reset list, so only cleanup
frees them.

"Nothing is caught anywhere" therefore does not arise in normal
operation. It can only mean the root handler itself is missing or
broken, which is a runtime bug and aborts.

(An earlier revision said both that phase 2 never runs without a handler
and that it must run to the root. The first was written thinking of a
C++-style program with no outer `try`; here there always is one.)

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

## To think about: gates for late-loaded code

The rule that a function may use channel R only if every call to it is
statically resolved assumes the compiler sees every call site. Autoloading
breaks that assumption directly ([classes.md](../model/classes.md)), and
the answer is not to freeze conventions globally.

**Late-bound code is reached through a gate**: a small piece of runtime
code that decides how the target may actually be called and adapts. The
overhead is real but small, and it is confined to the dynamic case
rather than taxing everything to accommodate it.

That inverts the usual framing. The question stops being "how do we keep
a convention stable across separate compilations" and becomes "what does
the gate need to know, and what does it cost" — a local problem with a
local answer.

Unresolved: what the gate inspects, whether it is per-call-site or
per-target, whether it can be cached the way an inline cache is, and
what it does when the target's convention cannot be satisfied at all.

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

**1. ~~Trace capture cannot be lazy the way described.~~ Resolved.**
Capture is now eager at construction and copies the whole return-address
chain; only symbolization is deferred. The doomed-segment scheme
survives as an optimization where the compiler can see construction,
throw and catch together. See "Capture is eager, symbolization is
lazy".

**2. ~~Channel R and dynamically dispatched calls.~~ Resolved**, and
without adding machinery: one function has one convention, and a
function may use channel R only if **every** call to it is statically
resolved. One erased call site and it is channel U. The compiler sees
every call site, so this is something it checks rather than something
anyone maintains — no dual entry points, no thunks, no per-site
variants.

What remains open is quantitative rather than structural: how much of a
real program is reachable only by direct calls, which decides how far
channel R actually reaches.

**3. ~~The pending check on the ordinary destruction path.~~ Resolved.**
Destructors are called by generated code and compiled so they cannot
propagate, because runtime teardown code must run after them
unconditionally. Nothing to check for, so the check is gone. See
"Destructors never propagate".

**4. A channel-R error in flight is invisible to the runtime.** It
travels in a return slot, so neither `pending` nor `unwinding` is set,
and the per-context policy table above cannot distinguish "a destructor
failed during normal death" from "a destructor failed while an error was
already propagating". Either compiled code owns chaining on every
error-return cleanup path, or propagation must set a context flag — with
the per-hop cost that implies.

**5. Closed world versus autoloading — direction settled, details
open.** Conventions are not frozen globally. Late-bound code is reached
through a **gate**: small runtime code that works out how the target may
be called and adapts, paying a small overhead confined to the dynamic
case. See "To think about: gates for late-loaded code" for what remains
unanswered.

**6. The channel-R ABI is unspecified.** Where the error physically
travels when every function already returns a 16-byte `Value`; what a
function does when its raisable set contains one frequent and one rare
class; how the caller tests the class cheaply, given that the interface
case is not O(1).

**7. ~~Contradiction on uncaught exceptions.~~ Resolved.** The request
root always has a handler, so phase 1 always finds one and phase 2
always runs to it. "Uncaught" cannot arise except as a runtime bug.

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
