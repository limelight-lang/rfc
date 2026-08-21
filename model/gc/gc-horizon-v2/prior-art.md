# Prior art, and what fits the philosophy

The second design combines four mechanisms. Three of them are known, one
was not found by the search recorded below. The purpose of this document
is to say which of the four is Limelight's own, and what each known one
supplies that this design can take.

The philosophy the fit is judged against, stated by Edmond 2026-08-21:
flexibility; the least possible work on the mutator and correspondingly
more on the collector; no stop-the-world where it can be avoided —
Limelight's remaining analogue of one being the mutator-side drain that
frees a confirmed component ([../drain-window.md](../drain-window.md)).

## The four mechanisms

1. **Defer the count for locals.** Deutsch and Bobrow, 1976. Known,
   shipped, and the base of everything below.
2. **Split the heap into a counted and a collector-counted population.**
   Ulterior Reference Counting, 2003, and its line through RC Immix to
   LXR.
3. **Elide the count for a reference the compiler proves is covered.**
   Nim's cursor inference, Perceus, Swift.
4. **Publish the root into the object's own header, and let the
   collector's ageing stamp be the clearing operation.** Not found.

Every deferred system in the table below answers "which entities do the
locals hold" by reading the stack or a side registry the mutator
maintains. This design answers it by reading the heap, which the
collector walks anyway.

## The table

Axes: who publishes that an entity is held from outside the heap, where
the publication is written, who ends it, what the mutator pays for it,
and whether the scheme stops the world.

| System | Who publishes | Where | Who ends it | Mutator pays | Stop-the-world |
|---|---|---|---|---|---|
| Deferred RC (Deutsch–Bobrow 1976) | nobody — the stack is read instead | — | — | nothing on local traffic | the stack enumeration |
| Ulterior RC (2003) | mutator, per mutated object | two bits in the object header | collector, at each collection | a coalescing write barrier, first mutation per object per epoch | nursery collection; stacks still enumerated |
| RC Immix (2013), LXR (2022) | as above | object header | collector, per epoch | field-logging barrier, 1.6% mutator overhead measured for LXR | brief; concurrent decrements and SATB tracing |
| Free-threaded CPython (3.14) | mutator, per C-stack reference | `tstate->c_stack_refs`, a side registry | the frame's own exit | nothing on deferred objects' `INCREF`/`DECREF` | the tracing GC |
| Partial tracing (PLDI 2026) | mutator, by counting roots | a root count per handle | the handle's own release | a count operation per root acquisition | none |
| Iso (PLDI 2025) | mutator, on publication | a per-object `public` bit | never — publication is one-way | a write barrier on public-to-private stores; 2% measured | private collections stop only their own thread |
| Pony ORCA | nobody — the actor collects only when its own stack is empty | — | — | nothing: no read or write barrier | none |
| ZGC, JDK 16 | mutator, per stack frame | the frame, via a watermark | the collector, on scanning the frame | a check at every method return | none for the root scan |
| `rc-walk` today | mutator, by counting | the entity's own count word | the matching `release` | a `retain`/`release` pair per local reference | none; the drain frees |
| This design | mutator, at a horizon | the entity's own epoch byte | the collector, by ageing the stamp | one byte store per horizon crossed | none; the drain frees |

## What each known system supplies

**Deutsch–Bobrow** states the trade this design inherits: leaving locals
out of the count removes most of the counting traffic, and the price is
that reclamation waits until the roots are found some other way.
Their other way is enumeration — "deferred RC must thus postpone all
reclamation until it periodically enumerates the stacks and registers"
([URC](https://www.steveblackburn.org/pubs/papers/urc-oopsla-2003.pdf),
§1). The zero-count table is the machinery that makes the wait safe, and
`rc-walk` has no equivalent because it never left the count.

**Ulterior RC** supplies the partition and the transition. Its logged
state lives in the object header, two bits checked without
synchronisation on the write barrier's fast path, and the collector
clears the state at each collection — a mutator-set, collector-cleared
per-object bit, which is mechanically what this design's mark is. The
purpose differs: URC's bit records that an object was mutated, so the
collector knows to re-enumerate its fields, while the mark here records
that an entity is held from a frame. URC's *integrate event* is the
operation this design needs for the deferred-to-counted direction, and
it names the same requirement — the transition happens during
collection, with a stable view of the edges, not on an ordinary store.

**RC Immix and LXR** supply the engineering: sticky counts of three
bits with overflow measured at 0.65% of objects, implicitly-dead new
objects, coalesced logging, concurrent decrement processing, and the
occasional backup trace that collects cycles and repairs stuck counts.
LXR's unified field-logging barrier is measured at 1.6% mutator
overhead, which is the number to beat with a scheme that has no such
barrier at all.

**LXR's premise does not carry to a non-moving collector.** Its stated
design premise is "that regular, brief stop-the-world collections will
yield sufficient responsiveness and far greater efficiency than
concurrent evacuation", and the target of that sentence is evacuation:
"concurrent evacuation requires expensive barriers to prevent mutator
and collector races, which is intrinsically more expensive than
stop-the-world evacuation. LXR does not require a read barrier." A
collector that never moves an object needs no read barrier for that
reason either, and Limelight fixed non-moving as a cross-strategy
decision ([../heap-design.md](../heap-design.md)), so `rc-walk` is
outside the choice LXR poses.

Two of its measurements do carry. On `lusearch` in a heap 1.3 times the
minimum, LXR's own pauses are longer than G1's at every percentile —
0.9 ms against 0.4 ms at the median — and its query latency is better at
every percentile, 3.0 ms against 12.0 ms at the 99th. Pause length was
not what set the latency; the mutator's per-operation cost and the
collector's ability to keep up with a 9.5 GB/s allocation rate were.
The second measurement bounds the first: given ten times the minimum
heap, Shenandoah reaches 170K queries per second against LXR's 119K, so
the premise is a claim about tight heaps and not about collectors in
general. Both numbers are from 2022, with Shenandoah and ZGC
non-generational at the time — the paper says their generational
variants were then under development.

**Free-threaded CPython** is the shipped instance of the header flag.
`PyUnstable_Object_EnableDeferredRefcount` sets `_PyGC_BITS_DEFERRED`
in the object's `_ob_gc_bits` and writes `_Py_REF_DEFERRED` into
`_ob_ref_shared`, after which the count no longer decides the object's
fate: it "will only be deallocated by the tracing garbage collector, and
not when the interpreter no longer has any references to it"
([Stinner](https://vstinner.github.io/free-threading-deferred-reference-counting.html)).
The interpreter applies it to modules, top-level functions and classes,
and the evaluation stack borrows through a tagged pointer bit rather
than counting. What CPython does not do is remove the root enumeration:
C-level stack references are pushed onto `tstate->c_stack_refs`, and the
collector traverses that registry. The registry is the Form C proposal
of the first design ([../gc-horizon.md](../gc-horizon.md)), reached by a
production runtime, and it is what the header mark replaces here.

**Iso** is the closest match to the workload. It is a request-private
collector for Java: each request collects its own objects, and the paper's
premise is the one Limelight is built on — object lifetimes are tied to
request lifetimes, most objects stay private to the request that allocated
them, and global operations are what limits responsiveness at scale. Its
motivating figure puts PHP WordPress heap composition beside Java's, both
showing total heap occupancy falling to zero between requests.

The mechanism is the Doligez-Leroy-Gonthier invariant: objects in a local
heap can only be referenced from outside by the stack of the thread that
owns the heap, which lets each local heap be collected "independently,
without synchronization among threads". Iso maintains it dynamically with a
per-object `public` bit and a write barrier that fires when a store's source
is public and its destination private, publishing the transitive closure of
the stored object. An object publishes at most once, so the amortised barrier
cost is constant, and the measured price of the whole visibility-tracking
scheme is 2% on Tomcat and Spring. Iso itself beats OpenJDK's G1 by 32% and
22% in execution time in a modest heap. The heap is 32 KB blocks owned by the
allocating thread, with private, public and mixed blocks and one further
invariant — a block holds private objects of at most one thread. Its central
contribution, opportunistic copying, pins public objects during a private
collection and private objects during a global one; Limelight is non-moving,
so that half does not apply.

What does apply is a corollary Iso states and Limelight's own cross-regime
question needs: **the publishing thread can only ever be the thread that
allocated the object**, since no other thread knows about a private object.
If a deferred entity is actor-private, then the edge from a counted source
into deferred space is always installed by its owner, and integration needs
no synchronisation with anyone. That is open question 4 above, answered for
the actor-private case and open for the rest. The 2% is also the closest
measured price for a publication check, which is the shape of the arena's
existing escape promotion (`model/src/promote.rs`, `IS_ESCAPEE`).

**Pony ORCA** is the closest match to the philosophy and the furthest
from the mechanism. It is fully concurrent with no stop-the-world step
and no read or write barrier; reference counts change only when messages
are sent and received; and it never scans a stack because "an actor
garbage collects its objects between the execution of its behaviours,
that is, when its stack of execution is empty"
([ORCA](https://www.ponylang.io/media/papers/OGC.pdf), §5.2.4). It also
declines to treat locally-referenced objects as roots — such objects are
"simply marked as reachable and need not be traced any further", which
is what the mark buys here without the empty-stack precondition. The
precondition is the difference: ORCA collects at a point where the
question this design answers does not arise, and Limelight's collector
runs while frames are live.

**ZGC** shows what the alternative costs. Its stack watermark barrier
made root scanning concurrent by putting "an inexpensive check that is
folded into the already existing safe-point check at method return"
([JDK 16 notes](https://malloc.se/blog/zgc-jdk16)) on every method
return. That is mutator work proportional to control flow, which is the
side of the ledger Limelight is trying to keep empty.

**Nim's cursor inference** is the first design's anchored borrow,
shipped. A cursor "is not involved in the reference counting, it is a
raw pointer without runtime checks", and the compiler infers one when
neither side of an assignment is mutated afterwards
([Nim destructors](https://nim-lang.org/docs/destructors.html)). The
proof obligation is narrower than the anchor chain and the language is
statically typed, so the inference is cheaper than the one this design
needs, but the shape is the same: a local that pays nothing because
something else already owns the value.

## Fit against the philosophy

**Takes the philosophy and the mechanism:** URC's partition and its
integrate event; LXR's sticky counts and backup trace for the cycles
publication cannot answer.

**Takes the philosophy, not the mechanism:** ORCA. No barriers and no
stop-the-world, bought by collecting only at a quiescent point. Worth
re-reading when the actor boundary is specified, because Limelight also
has message boundaries
([../../../runtime/actors.md](../../../runtime/actors.md)), and a
collection that runs there needs no mark at all.

**Rejected by the philosophy:** ZGC's return barrier and LXR's field
logging both charge the mutator per operation. Deutsch–Bobrow's stack
enumeration and CPython's root registry both need a structure the
mutator maintains outside the heap.

## The quadrant this design sits in

Bacon, Cheng and Rajan's unified theory places tracing and reference
counting as dual computations over the same graph, which leaves a fourth
quadrant: **count the roots and trace the heap**, the exact dual of
deferred reference counting, which counts heap edges and traces the roots.
That quadrant is where the second design sits, and it is where the capture
count belongs by definition — a count of code-side captures is a root
count.

The recent instance is Kim, Park, Kwon and Kang's concurrent deferred
partial tracing (PLDI 2026,
[doi](https://dl.acm.org/doi/10.1145/3808310)), a collector library for
C++ and Rust. Counting roots buys them precise root identification with
no stack maps and no conservative scanning, and tracing the heap from the
objects whose root count is non-zero collects cycles without a separate
cycle collector — the two properties this design is after, reached from
the same direction. Their cost is that a root count is maintained by
smart-pointer handles, so every root acquisition pays; their contributions
are the two mechanisms that make it concurrent, phase consensus and a
hazard-pointer replacement for atomic root updates.

The delta is where the root count comes from. Theirs is maintained at
every handle, ours only at a horizon — and it degrades further to a mark
that costs one store and expires by itself, which is the mechanism the
next section says was not found. This entry was already in this
repository's own survey before the search
([../gc-research.md](../gc-research.md), "Concurrent Deferred Partial
Tracing"), and the search below missed it; the survey should be read
before the web next time.

## What the search did not find, and how far it looked

No system was found that publishes roothood into the collected object's
own header and relies on the collector's own stamping to end the
publication. The claim is narrow after the section above: the quadrant is
occupied and named, and what was not found is the cheap expiring form of
the root publication. This is a negative result of a bounded search and
not a claim of novelty. Two
things would settle it: a reading of the deferred-RC literature that
predates the web-indexed part, and the framework Edmond has in mind,
which he reported as an existing implementation and which the search did
not identify. The nearest shipped thing found is free-threaded CPython's
deferred flag, which is the same header bit answering "who counts" but
not "who roots".

## Sources

- [Ulterior Reference Counting, OOPSLA 2003](https://www.steveblackburn.org/pubs/papers/urc-oopsla-2003.pdf)
- [Ownership and Reference Counting based Garbage Collection in the Actor World (Pony ORCA)](https://www.ponylang.io/media/papers/OGC.pdf)
- [Low-Latency, High-Throughput Garbage Collection (LXR), PLDI 2022](https://arxiv.org/abs/2210.17175)
- [Free threading internals: deferred reference counting, Victor Stinner](https://vstinner.github.io/free-threading-deferred-reference-counting.html)
- [ZGC in JDK 16: concurrent thread-stack processing](https://malloc.se/blog/zgc-jdk16)
- [Iso: Request-Private Garbage Collection, PLDI 2025](https://www.steveblackburn.org/pubs/papers/iso-pldi-2025.pdf)
- [Revisiting Partial Tracing for Safe, Efficient, and Concurrent Garbage Collection in Unmanaged Languages, PLDI 2026](https://dl.acm.org/doi/10.1145/3808310)
- [Work Packets: A New Abstraction for GC Software Engineering, Optimization, and Innovation, OOPSLA 2025](https://www.steveblackburn.org/pubs/papers/packet-oopsla-2025.pdf)
- [MMTk status page](https://www.mmtk.io/status)
- [Nim: destructors and move semantics](https://nim-lang.org/docs/destructors.html)
