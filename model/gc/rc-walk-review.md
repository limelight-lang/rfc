# rc-walk — design review

> **Status: review.** Written against [rc-walk.md](rc-walk.md) as it stood on
> 2026-07-25, before the resolution pass. Findings are numbered for reference;
> the agenda at the end is what needs a decision.

## Verdict

The central identity holds and the shape is coherent: derived roots make a
barrier-free walk possible, and skipping is genuinely conservative. What does
not hold is **Phase 3**. As specified it leaves an uncovered window in which a
live entity can be condemned, and **Phase 4** cannot free a pure cycle at all.
Both are fixable without giving up the design constraint; neither is a
detail.

Everything else below is either a consequence of those two or a cost the
document does not yet charge itself.

## How to read a finding

Each carries a **direction** and an **evidence** mark.

- Direction — *correctness* (a live entity is freed, or a dead one is freed
  twice), *recall* (garbage survives), *cost* (the mutator or the collector
  pays more than the document claims). Only correctness blocks the build
  order.
- Evidence — *code* (read in `ll-model`), *doc* (contradiction between RFCs),
  *argued* (a timeline, not yet mechanically checked).

## Findings

### 1. The condemnation erases the evidence it is checked against
*correctness, argued*

The condemned byte can only record touches that land **after** the collector
writes 1. A `retain` or `release` in the window between the walk's read and
the condemnation writes 0 over a byte that is already 0, leaving no trace,
and the collector's write of 1 then makes the window look quiet.

    walk reads rc[X] = 1
    mutator:  $x = $a->o        retain X   rc 1 → 2, byte 0 → 0
    mutator:  unset($a)         release A  rc[A] drops
    walk reads A, records edge A → X
    diff:     rc[X] recorded 1, in[X] = 1  →  not a root
    condemn:  byte X := 1
    check:    byte X reads 1    →  confirmed, and $x is live

The document's own justification — "a lost update always produces the
conservative answer" — analyses only the mutator clobbering the collector.
The other direction, the collector's write landing after a mutator's clear,
is the anti-conservative one, and it is the normal case here rather than a
rare race.

The published mechanism that covers this window is a **second read**: Paz,
Petrank, Bacon, Kolodner and Rajan validate by comparing two sliding views,
not by a single flag. The window algebra the document needs to state is:

    dirty watch reset  ≤  first walk read
    condemn write      ≤  dirty query
    byte check         last

Violate any of the three and something is uncovered.

### 2. Phase 4 cannot free a pure cycle
*correctness, code*

The discipline as written — guard every member, run destructors, "un-guard
through `ll_release` and let the ordinary teardown path decide" — never
reaches zero for `A ↔ B`: guard gives 2 and 2, un-guard returns 1 and 1, and
both members are read as resurrected.

`rc-trace` does not have this problem for a reason rc-walk does not share.
In `ll-model/src/gc.rs` the internal edges are already decremented during
`mark_gray` and **deliberately not restored**, so the white set is freed
directly ("Free the white set. Internal-edge releases already happened
count-wise in mark_gray"). rc-walk has no trial deletion, so its members
retain a count equal to their in-degree inside the component. The reference
to "the discipline the existing `run_cyclic_destructors` already implements"
is therefore wrong as stated.

The repair is a fork in the design, not an edit:

- **Release the intra-component edges first, then un-guard.** Counts become
  true, the ordinary path frees what reaches zero, and a wrongly confirmed
  live member survives at a non-zero count. Phase 3 failures degrade to a
  premature `__destruct`, which is a semantic bug and not a
  use-after-free.
- **Free the component outright** on the collector's verdict. Then every
  Phase 3 false positive is a use-after-free.

The first makes refcounting the memory-safety backstop and Phase 3 only a
destructor-timing mechanism. That difference deserves to be stated
explicitly wherever it is chosen.

### 3. Phase 1 dispatches on category, but the header switch is on kind
*correctness, doc + code*

The walk skips "if the category is not `GcHeap`" and then reads
`traced_runs` through the class. Entity kinds 1–3 — string, array, reference
box — carry **no class pointer at `+8`** ([classes.md](../classes.md),
"Entity kind and non-object teardown"), and `for_each_counted_child` in
`ll-model/src/object.rs` yields children as bare `*mut RcHeader` of any kind.
A `GcHeap` array child therefore reaches the class-pointer read.

The recall half is the larger problem. If arrays and `&` reference boxes are
skipped, every cycle that passes through one is invisible, and
`$this->items[] = $child; $child->parent = $this;` is the commonest cyclic
shape in PHP. Skipping is sound; it is not affordable.

### 4. Racing child reads are dereferenced, not validated
*correctness, doc*

Deciding whether a child is `GcHeap` means reading the child's header through
a pointer loaded from a slot the mutator may be writing. Two hazards:
a 16-byte `Box` slot read as a torn pair, and a slot in a freshly bumped
allocation read before its fields are published.

[satb.md](satb.md) solves exactly the first for its marker with a `WRITING`
bit and release/acquire ordering. rc-walk has no counterpart and does not
say why it needs none. Minimum: validate every child pointer against the
region registry — inside an entity block, correctly aligned for that block's
size class — before touching its header, and state that as a Phase 1
invariant.

### 5. Nothing prevents a component being condemned twice
*correctness, argued*

A confirmed component sits in a message queue until the mutator polls.
Confirmed garbage is by construction untouched, so the next epoch walks it,
finds it unchanged, and confirms it again. The mutator then drains two
messages for the same component: the second guards and destructs through
memory the first already freed, and after the deferred-release queue flushes,
possibly through a reused slot.

Needed, and unstated: the collector does not re-judge a component with an
undrained message, and the drain re-checks the FREE stamp and the condemned
byte per member **before** its own guard retain clears it. That same re-check
also closes the window in which `WeakReference::get` resurrects a member
between confirmation and drain.

### 6. The memory model is not "plain stores on both sides"
*correctness, doc*

`RcHeader` declares `refcount` and `flags` as `_Atomic uint32_t`
([lowering.md](../lowering.md)), while rc-walk promises plain stores. The
gap matters beyond pedantry: a non-atomic single-writer header may legally be
cached in a register across a retain/release sequence, so "the mutator writes
0 on every retain and release" is a source-level statement with no
instruction behind it during that window. The final byte check is likewise
unfenced against a clear still sitting in a store buffer.

Relaxed atomic stores keep the document's real claim — no atomic
read-modify-write anywhere — and cost nothing on x86. The check needs an
ordering edge, which is what a handshake provides for free.

### 7. The FREE stamp does not cover the window it was introduced for
*recall and correctness, argued*

The stamp is written in teardown phase 3, but phase 2 runs `__destruct`,
which is arbitrary PHP of arbitrary duration. A slot visited in that window
contributes a dying entity's out-edges, which inflates `IN` for live targets
— the exact failure the stamp exists to prevent. Reading `rc == 0` first and
skipping is cheap and closes most of it; an out-of-line allocated bitmap
closes it without writing to the object at all.

### 8. `id` stability is assumed, never stated
*correctness, argued*

`id = (block index << k) | slot index` with blocks enumerated "in address
order" is stable only if the block index is a registry slot, not an
enumeration ordinal. New entity blocks appear mid-epoch, and promoted arena
survivors may add more. If ids shift under the collector, `edges[]`
cross-wires and `IN` lands on the wrong entity.

### 9. Dirty-page tracking is neither free nor sufficient
*cost, doc*

Two claims need retiring. It does not cost the mutator nothing: Linux
soft-dirty write-protects PTEs on reset, so every first write to a page after
each epoch takes a fault, and the reset runs through `/proc/self/clear_refs`
for the whole process; Windows requires the region reserved with
`MEM_WRITE_WATCH` at `VirtualAlloc` time, which the block pool must be
plumbed for up front, and a read that does not reset leaves a gap.

And it does not converge. A true garbage cycle is by definition untouched by
the mutator, so the only writes that can veto it come from **other objects
sharing its 4 KB page**. That co-location is stable, so "re-run the epoch"
does not fix it — a garbage cycle next to a hot object is never confirmed.

The productive use of write-watch is the opposite one, and it is the original
one: Boehm, Demers and Shenker use dirty pages to **narrow** the work, not to
validate a verdict.

### 10. The snapshot's memory is not charged
*cost, argued*

Phase 2 materialises `rc[]` and `edges[]` for the whole entity population in
collector-private memory, and the deferred-release queue grows for the
duration of the epoch. Both scale with heap size and epoch length, and
neither appears in the cost table. Trial deletion avoids the first by working
only on candidates; the document should either accept the constant or say why
the snapshot is worth it.

### 11. Two RFCs disagree about roots
*doc*

[strategies.md](strategies.md) §2 states that at a poll safepoint "the
thread's roots are enumerable". rc-walk is built on the premise that they are
not, which is what forces derived roots. Both cannot stand. Fil-C is the
worked example of the price of the first: accurate stacks without stack maps
cost a heap-allocated frame per function and a spill of every live pointer
before each pollcheck.

## The one structural fact

Findings 1, 4, 7 and 8 are the same fact wearing different clothes: **every
anti-conservative failure mode funnels into Phase 3 as its only repair**,
while the build order, the open questions and the cost table all treat
Phase 3's mechanisms as optional refinements. The direction analysis the
document asserts globally — "the error direction is always conservative" —
is true of the *walk* and false of the *pipeline*.

Naming that fact is most of the fix. A walk that is conservative modulo a
sound Phase 3 needs Phase 3 present from the first concurrent milestone, in
whatever form.

## Where this sits in the literature

- **The identity is not new.** `RC - IN > 0` is CPython's `gc_refs`
  computation, and the same subtraction is what Bacon and Rajan perform
  locally by trial deletion. Nothing to defend there.
- **The acyclic flag is theirs too.** Bacon and Rajan compute it for the
  Recycler and report the candidate population falling by roughly an order of
  magnitude.
- **Validation without mutator cooperation is the unusual part.** The
  nearest published relatives are Boehm–Demers–Shenker's mostly-parallel
  collector, which uses dirty pages but finishes with a stop-the-world
  re-scan, and Paz et al.'s on-the-fly cycle collection, which validates by
  comparing two sliding views but keeps a write barrier. No exact prior art
  surfaced for barrier-free derived roots plus flag-based validation.
- **Fil-C is the counter-example worth keeping in view.** FUGC is a
  concurrent on-the-fly Dijkstra collector with a store barrier, accurate
  roots via heap-allocated frames, and soft handshakes instead of
  stop-the-world; it ships whole distributions. Its transferable parts are
  mechanical rather than strategic: the handshake as an ordering primitive,
  the re-handshake-to-fixpoint loop, out-of-line mark bitvectors, and naming
  the allocate-black invariant. Its performance is not an argument for
  anything here — the published numbers are for Fil-C as a whole against
  clang, the collector is not isolated, and no comparison against JVM
  collectors exists.

## What has to be proved

Two theorems carry the design; everything else is recall or cost.

**S (safety).** If a component is confirmed at time *T*, then at *T* no
member is reachable from outside the walked heap.

The proof obligation is a case analysis over mutator actions in the window
between the first walk read and the check, showing each leaves evidence the
check observes. Finding 1 is precisely a case where it does not, so the
theorem is currently false and the repair is what makes it provable.

**L (stability).** Unreachability is stable: no mutator action makes an
unreachable entity reachable again.

This is what licenses the gap between confirmation and the drain in Phase 4.
It needs explicit clauses for the ways a reference can be materialised
without a store through a live reference: `WeakReference::get`, an FFI handle
holding a raw pointer, and a `__destruct` that runs while its own component
is condemned.

Everything the walk skips — regions, acyclic classes, kinds it does not
traverse, huge objects — is covered by a third, much easier statement: the
skip lemma, that omitting an entity from the walk only removes in-edges and
so only adds roots. It already appears in the document as a corollary and
needs the sharpening that omission must be **total**: a recorded edge into an
entity with no recorded row reads as a negative derived root.

## How to test it

Three layers, cheapest first.

1. **A model, not the code.** Four entities, two threads, an abstract heap:
   the interleavings that matter are all reachable at that size. TLA+ or
   PlusCal for the protocol, or `loom` if the harness should exercise real
   Rust. The invariant is one line: no confirmed component contains a member
   reachable from outside. This is where finding 1 shows up as a
   counterexample trace rather than as an argument.
2. **The synchronous walk as an oracle.** Build-order step 2 gives a
   whole-heap leak detector with no concurrency. Generate random object
   graphs — cycles of varying length, cycles hanging off live roots, chains
   of dependants, arrays and reference boxes on the cycle path — and compare
   its white set against a mark from an explicitly maintained root set. Any
   disagreement is a bug in the identity or in the skip rules, with no race
   to blame.
3. **Adversarial interleavings.** Turn each finding above into a test that
   *forces* its timeline: a mutator thread with an injected delay at the
   exact point, a collector single-stepped between walk, condemn and check.
   The reference-migration case of finding 1 is the first one to write, and
   it should fail against the current design.

Two properties are worth asserting continuously rather than per test: no
confirmed member ever has its byte cleared between confirmation and drain,
and every component freed by the collector has all its members' destructors
run exactly once.

## After the resolution pass

[rc-walk.md](rc-walk.md) was rewritten against these findings on the same
day. What changed, and what it costs, in the order it matters:

**The safety boundary moved, and that is the whole of it.** Phase 4 now
opens with an *exact test*, run on the mutator's own thread where nothing
races it: a component is garbage iff every member's refcount equals its
in-degree recomputed from the members' current fields. Counted references
account exactly, so the equality says no reference to any member comes from
outside — the central identity applied locally, and decided rather than
guessed. Phase 3 is demoted to a filter that keeps false candidates off the
queue. Findings 1, 2, 5, 7 and 8 all dissolve there: a false verdict now
costs one verification pass, not a destructor and not a free.

**Other resolutions.** Arrays and reference boxes are walked; strings,
`WeakRef` and `Box` are total-skips, with FFI-wrapper cycles moved to the
uncollectable list (3). The walker dispatches on kind before touching `+8`
and validates every child pointer against the snapshot, so a torn read
costs a phantom edge rather than a crash (4). Header accesses become
relaxed atomics and the handshake supplies the ordering edge (6). Registry
indices become stable handles and allocate-black is named (10). OS
dirty-page tracking is rejected outright, with both reasons on the record
(9). The strategies.md conflict is noted in place (11).

**What it cost.** The design constraint was amended from "the mutator does
no work for the collector" to "no *per-operation* work": the mutator now
answers a handshake per epoch and runs a verification pass per confirmed
component. The amendment is honest and the new costs are bounded by garbage
found rather than by store traffic, but the premise is not the one the
document started from.

**One rejection carries no trace in the document**: side-table allocation
bitvectors, dropped in favour of the in-header FREE stamp on the grounds
that the header is read anyway and a bitvector adds a second cache line per
slot. It is a defensible call and the counter-argument — that writing the
stamp dirties an object page the walk would otherwise never touch — no
longer bites now that dirty-page tracking is gone.

## Decision agenda

Ordered for a one-question-at-a-time pass. Each blocks the ones under it.

1. **Does Phase 3 survive at all?** If Phase 4's exact test owns safety,
   the first concurrent milestone can be walk → mark → post → exact test,
   with no condemned byte, no handshake and no header masking on
   `retain`/`release`. That deletes the design's only per-operation cost and
   makes it barrier-free in the strict sense again. What Phase 3 buys is
   fewer false posts; whether that is worth a header byte and a handshake is
   a measurement nobody has taken.
2. **Weak references against the exact test.** A `WeakReference` is
   uncounted by design, so a member can satisfy the test while a weak
   handle to it is alive, and `get()` inside an outside destructor can
   resurrect it mid-sever. Weak refs are deferred, which means the exact
   test's guarantee is conditional until they are designed.
3. **Uncounted borrows.** Same shape, already listed as unsolved: an elided
   retain is invisible to a test built on counts. The obligation on the ARC
   optimiser — an elided borrow is legal only when covered by a counted
   reference in a frame — is the load-bearing assumption of the whole
   design and is written down in no compiler document.
4. Slot metadata: in-header FREE stamp, or the rejected out-of-line bitmap.
5. Finding 11: which of the two root stories survives, and which RFC
   changes.
