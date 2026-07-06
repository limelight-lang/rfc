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

## What a region is not

A region is the **memory half of an actor**. Actor = region + mailbox
+ serial execution. Unbundling costs the concurrency guarantees:

- **No isolation.** References cross the region boundary freely; the
  ordinary category barrier logs escapes into the remembered set
  ([arenas.md](arenas.md)), and promotion at reset handles survivors.
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
- **Attribute name**: `#[Region]` vs `#[Arena]`; kept `#[Region]` for
  the Verona association.
