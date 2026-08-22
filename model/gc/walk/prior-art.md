# Prior art, round two: what the counted walk can take

The first round of this search
([`../gc-horizon-v2/prior-art.md`](../gc-horizon-v2/prior-art.md)) asked who
else publishes roothood into a collected object's header. That question died
with the capture-count regime. This round asks three narrower ones, matching
the nodes they feed in [questions.md](questions.md): which barrier forms are
cheaper than the counted pair (F1), what else collects cycles without an
indivisible verification (F2), and how other systems hand reclamation back to
a collector thread (F3).

Descriptions are taken from this repository's survey,
[`../gc-research.md`](../gc-research.md), except where marked **not
surveyed** — those are candidates named for a later read, not summaries of
one.

## The finding that bears on this session

**Partial tracing is the published name of the capture-count regime.** The
survey states the duality plainly: "DRC counts heap edges and traces the
roots; PT counts the roots and traces the heap"
([`../gc-research.md`](../gc-research.md), "Concurrent Deferred Partial
Tracing"). Counting roots and tracing the heap is exactly what
[`../gc-horizon-v2/`](../gc-horizon-v2/README.md) proposed, and partial
tracing is the fourth quadrant of Bacon's taxonomy, long dismissed as too
slow because roots mutate constantly.

The 2026 paper (Kim, Park, Kwon and Kang, KAIST) removes that in two steps.
**Phase consensus** lets the collector and the mutators agree on a phase
change with nobody suspended, which eliminates most reference-count updates
during traversal. **Deferred** partial tracing then replaces atomic root
updates with hazard pointers behind a phase barrier. Reported to match manual
hazard-pointer schemes and to beat BDWGC and CIRC.

What this changes for the refusal of 2026-08-22: nothing about the reason.
The survey names the same blocker the session found independently — "a heap
object dies at trace time rather than at its last release, which is the
`__destruct` timing PHP promises". What it changes is the record: the regime
was not refused for want of a mechanism, and the mechanism it wanted exists.
If the corpus ever says prompt destruction is not observed where it would be
lost, this is the paper to reopen from.

**Phase consensus is separable from partial tracing**, and that is the
transferable part. Node D1 needs a hand-back channel between the mutator and
the collector, and node E1 will need an epoch protocol across several actor
threads. Both are agreements on a phase change without suspension. Read the
paper for the mechanism before designing either.

## F1. Barrier forms cheaper than the counted pair

The measured pair costs 4.1 ns warm and 88 ns at a million-entity working
set (`ll-model` `dev/BENCHMARKS.md`, 2026-08-22). What a barrier must supply
here is narrower than what the count supplies — the count also frees at zero,
answers the uniqueness test and carries the arena's escape hold-count — so
nothing below replaces it. They are read for the store path only, and only if
node A6 says the compiler's proofs leave a large population of stores behind.

- **LXR's field logging** ([`../gc-research.md`](../gc-research.md), and
  [`../gc-horizon.md`](../gc-horizon.md), which already selected LXR as the
  experimental substrate). Logs the field rather than counting the target;
  the design has read it and priced it.
- **SATB, the deletion barrier** ([`../satb.md`](../satb.md), designed and
  deliberately unbuilt since 2026-08-03). One append into a thread-local
  buffer per overwritten reference, no foreign header touched, active only
  while marking. Its banner records what would make it worth building; the
  measured pair is a new input to that question.
- **Coalescing (sliding-view) reference counting**, Levanoni and Petrank —
  **not surveyed**. The published idea is to log an object's slots once on
  first write within an epoch and reconcile at the epoch's end, so repeated
  writes to the same object cost one log entry rather than one pair each.
  That is the shape node A5 asks for, and the repository has no read of it.

## F2. Cycle collection without an indivisible verification

Node D4 has no candidate of its own: the exact test compares each member's
count against its in-component in-degree over current fields, so it cannot be
split, and a large weakly connected component freezes its thread for as long
as it takes. Two published lines attack that.

- **Arborescent GC**, ISMM 2025, Université de Montréal
  ([`../gc-research.md`](../gc-research.md)). Keeps a spanning forest inside
  the program's own reference graph — a parent and a coparent field per
  object — and on every edge removal checks **locally** whether a subtree
  just lost its last path from a root, freeing it at once, cycles included.
  Descends from Even-Shiloach dynamic reachability. This is the one shape
  found that decomposes D4's global question into local ones, which is
  exactly what a bound needs. Against it, from the same survey: roughly two
  words per object, which cancels the compacted 8-byte `RcHeader`;
  multithreading unimplemented; synthetic evaluation. The survey's verdict is
  "watch, do not adopt", and that verdict was written before D4 was a named
  node.
- **Bacon and Rajan's trial deletion**
  ([`../gc-research.md`](../gc-research.md), section 3) is what the current
  design already descends from; its synchronous form is PHP's own collector.
  Nothing new to take, but it is the baseline any D4 answer is measured
  against.
- **Partial tracing**, above, collects cycles as a side effect of tracing
  from counted roots, with no separate verification at all. It carries the
  destruction-timing price for the whole heap, which is why it is not the
  answer here — but a *bounded* application of it to one oversized component
  is a shape nobody has priced.

## F3. Handing reclamation to a collector thread

Node D1 needs the verdict protocol's second direction: the mutator confirms a
component and hands it back.

- **Iso**, PLDI 2025 ([`../gc-research.md`](../gc-research.md), and cited in
  [`../../memory/arena-promotion.md`](../../memory/arena-promotion.md)).
  Request-private collection, whose premise is this project's own, and whose
  DLG corollary is that only the allocating thread can publish an object.
  Read for what it does at the request boundary, which is where a hand-back
  is cheapest.
- **Free-threaded CPython**
  ([`../gc-horizon-v2/prior-art.md`](../gc-horizon-v2/prior-art.md) has the
  read). It ships a header flag for "who counts" and keeps a root registry
  for "who roots"; what it does about reclamation across threads is the part
  that round did not extract.
- **Pony's ORCA** (same document). Matches this project's philosophy and
  avoids the question by collecting only when the actor's stack is empty —
  which is a quiescent point, and therefore an answer to D1 by not needing
  one.

## What to read first

1. Concurrent Deferred Partial Tracing, for phase consensus alone. It feeds
   D1 and E1, and both are blocked on the same shape.
2. Arborescent GC, against node D4. It is the only local answer found to a
   question that has no other candidate.
3. Levanoni and Petrank, against node A5, and only if A6 says a large
   population of stores survives the compiler's proofs.
