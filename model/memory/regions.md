# Memory Regions: `#[Region]`

## Motivation

Sometimes an object needs its own memory policy without being an
actor. The driving case: a very long-lived object (a cache, an index,
a loaded model) whose internals should live compactly together, be
collected by their own strategy on their own schedule, and die in O(1)
when the owner dies. Today the design offers this machinery only
bundled with actors; this document unbundles it.

Prior art: Microsoft Verona regions (per-region memory management
strategy), Apache/Nginx memory pools, allocator-parameter idioms in
Zig/Odin.

## Definition

A class declared `#[Region]` owns arenas, exactly like an actor owns
arenas ([../../runtime/actors.md](../../runtime/actors.md)):

```php
#[Region(gc: 'rc-trace', threshold: '1mb')]
class RouteIndex {
    private array $trie = [];        // lives in this region's arena
    ...
}

#[Region(gc: 'none')]                // never collected; dies as a whole
class RequestScratch { ... }
```

- **Allocation context**: while execution is inside the region's
  methods, allocations land in the region's arena. Same mechanism as
  the actor allocation context: the "current arena" pointer is mounted
  on entry and restored on exit.
- **Death = arena reset**: when the region object dies (by refcount or
  by its owner's drop), its arenas reset through the standard
  discipline ([arena-reset.md](arena-reset.md),
  [object-lifecycle.md](../../runtime/object-lifecycle.md)): tracked
  pre-destructors, promotion of escaped survivors, blocks back to the
  pool.
- **Per-region GC binding**: the region binds a collector from the
  build's compiled-in strategy set, with its own thresholds, exactly
  as `#[Actor(gc: ...)]` does
  ([../gc/strategies.md](../gc/strategies.md)). A `gc: 'none'` region
  is legal and useful: no cycle collection ever, the reset pays for
  everything.

## Class-shared regions

`#[Region(shared: true)]` binds **one region to the class itself**;
every instance of the class, and everything those instances allocate,
lives in that single region:

```php
#[Region(shared: true, gc: 'none')]
class TrieNode {                     // all nodes of all tries live
    public array $children = [];     // compactly in one arena
}
```

- **Placement**: instances themselves are allocated in the class
  region (unlike the per-instance form, where the instance lives
  outside and only its contents live inside). This is the slab/pool
  idiom: many small objects of one type co-located for cache density.
- **Lifecycle**: the region keeps a live-instance count. When it drops
  to zero, the region resets (tracked pre-destructors run, blocks
  return to the pool). An explicit `pack()`/`reset()` API for shedding
  content earlier is the same open question as for per-instance
  regions.
- **Cost to know**: one long-lived straggler instance keeps the whole
  region's survivor blocks alive. Block-level retention from
  [arena-reset.md](arena-reset.md) bounds the damage to the
  blocks that actually carry survivors, but a shared region is still a
  commitment: choose it for populations that live and die together.

## The region as an allocator class: custom allocation, freeing, traversal

A `#[Region]` is an **allocator class**: an object that owns memory and
governs the objects it creates. By default it inherits the arena
discipline wholesale — bump allocation, release-at-reset, escape counting
([arenas.md](arenas.md)) — and binds a *named* collector from the build's
strategy set (above). The generalization is that a region may also supply
its **own** allocation, freeing, and GC traversal, instead of only
selecting from the menu.

- **Allocation / freeing.** A region may replace bump-and-reset with its
  own policy: a free list, a size-class pool (a shared region already is
  the per-class pool [heap-slot-allocation.md](heap-slot-allocation.md)
  reserves), or a slotmap that hands out keys instead of pointers so its
  backing store can be compacted. That last is the only form of object
  movement the runtime has, safe for the same reason as a movable proxy
  ([../classes.md](../classes.md), "The Proxy family"): access goes
  through the region's key/handle, so relocation invalidates no raw
  pointer.
- **Traversal.** To collect its contents — and to let the global
  collector learn which general-heap objects a region keeps alive — the
  collector needs the *outgoing references* of the region's objects. The
  compiler generates a default traversal from each object's layout; a
  region may override it (skip fields it manages by hand, walk a custom
  structure, report a summarized root set). This per-region traversal is
  the genuinely new capability: Verona/Zig/Ada give custom allocation and
  bulk release, but not a user-supplied GC walk.

**The traversal safety contract is over-approximation.** A custom
traversal must report a **superset** of the live outgoing references, and
only references the objects actually hold — never a fabricated address.
Over-reporting keeps a dead object alive one extra cycle (harmless);
under-reporting frees a still-referenced object, a use-after-free, and is
forbidden. This is the discipline the arena's release-at-reset list and
SATB marking already rely on (../gc/satb.md): erring
toward *more* live is always safe, erring toward *less* never is. The
runtime does **not** verify a hand-written traversal — honoring the
contract is the author's responsibility, and a traversal that
under-reports is undefined behavior (a use-after-free). That unsafety is
accepted deliberately for now, to be revisited separately (Open
questions); the compiler-generated default traversal is always safe by
construction, so only a hand-written override carries the risk.

**A region's contents are `gc_state = OWNED`.** The global collector
skips them ([../gc/heap-design.md](../gc/heap-design.md)); the region's
own collector, driven by its own traversal and free rules, is solely
responsible for them, and its outgoing references into the general heap
enter the global marker as roots (../gc/satb.md),
published the way an actor publishes its arena roots
([../../runtime/actors.md](../../runtime/actors.md)). The compiler wires
this: allocation inside the region's methods routes to the region's
allocator, collection calls the region's traversal, and reset calls its
free rules.

## What a region is not

A region is the **memory half of an actor**. Actor = region + mailbox
+ serial execution. Unbundling costs the concurrency guarantees:

- **No isolation.** References cross the region boundary freely; the
  ordinary category barrier counts the escape in the escapee's own
  header ([arenas.md](arenas.md)), and promotion at reset handles
  survivors.
  There is no queue and no packing discipline.
- **No serial-execution guarantee.** A region does not make refcounts
  non-atomic by itself; counting follows the build's threading mode.
  If a region instance is confined to one actor, it inherits that
  actor's serial world for free.
- **No collection-at-message-boundary.** The region's collector runs
  by its own trigger (threshold), pausing per the bound strategy's
  rules.

## Ownership of the region object itself

The `#[Region]` instance is an ordinary managed object living wherever
its allocation site put it (typically the long-lived arena or the
general heap). Only its *contents* live in the region's arenas. The
compiler treats the instance as the arenas' owner: tier analysis
([static-lifetimes.md](static-lifetimes.md)) can schedule the whole
region's death statically when the owner's lifetime is proven.

## Interactions

- [arenas.md](arenas.md): the arena-owner set generalizes again:
  request, actor, and now region. The request arena remains the
  degenerate case (an anonymous region that dies after one message).
- [../gc/strategies.md](../gc/strategies.md): strategy selection is
  two-level (build set + per-owner binding); regions bind exactly like
  actors.
- [../../runtime/actors.md](../../runtime/actors.md): an actor's
  memory story can now be specified as "a region plus the queue
  discipline".

## Open questions

- **Explicit lifecycle API**: manual `reset()` / `pack()` on a region
  (ties into the explicit pack operation in the backlog) for
  long-lived regions that shed generations of content without dying.
- **Nested regions**: a region created while another region's context
  is mounted; likely just a stack of contexts, but promotion targets
  need a rule.
- **Attribute name**: `#[Region]` vs `#[Arena]` vs `#[Allocator]`; kept
  `#[Region]` for the Verona association, but the concept is an
  *allocator class* and the spelling may move to `#[Allocator]`.
- **Custom-traversal verification**: the compiler-generated default
  traversal over-approximates by construction; a hand-written override
  needs a check (or a restricted form) that it cannot under-report live
  references. Open.
