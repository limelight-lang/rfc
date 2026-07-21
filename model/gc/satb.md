# SATB: Concurrent Marking for the `rc-satb` Strategy

## Scope

The design of the `rc-satb` build strategy
([strategies.md](strategies.md)): cycle collection that runs
**concurrently** with the mutator, trading a store barrier during
marking epochs for near-zero pauses. This document owns the tri-color
correctness argument, the deletion barrier, the epoch protocol, and the
integration with the CAS handoff and deferred-free machinery from
[heap-design.md](heap-design.md).

Status: designed ahead of need. The default strategy `rc-trace` ships
first; `rc-satb` is the build for latency-sensitive long-running
processes.

---

## The problem: marking a graph that mutates under you

A concurrent marker colors objects: **black** (scanned), **gray**
(found, children pending), **white** (not yet seen). The fatal race is
a tri-color invariant violation:

1. The mutator stores the only reference to white object `X` into an
   already-black object.
2. The mutator erases the original (gray-reachable) reference to `X`.

No gray path to `X` remains. The marker terminates with `X` white and
frees a live object. Note that per-object state flags or CAS cannot
catch this: `X` is never touched by the GC or deleted by the mutator;
it simply becomes invisible.

## The solution: Snapshot At The Beginning

The collector promises to collect only what was **already garbage when
the epoch started** (the logical snapshot). Everything reachable in the
snapshot stays live this epoch, even if the mutator drops it mid-epoch;
it becomes *floating garbage*, collected next epoch.

The snapshot is protected by a **deletion barrier**: the second step of
the race above (erasing a snapshot reference) is the only step that can
hide `X`, so that is the step that gets instrumented.

## The deletion barrier

The strategy hook installed into the unified store barrier slot
([strategies.md](strategies.md)):

```
ll_ref_store(ctx, owner, slot, old_entity, new_value):
    retain(new_value)                    # ARC layer, before anything else
    category_barrier(owner, new_value)   # always: arenas (escape / release log)
    if marking_active and old_entity is heap ref:
        satb_queue.push(old_entity)      # "this was in the snapshot: trace it"
    *slot = new_value                    # published as a whole Value...
    release(old_entity)                  # ...before the displaced value dies
```

- The barrier is the **only** writer of the slot, and it writes the
  whole `Value` before releasing the displaced one: teardown runs user
  code, and user code that collects must not see an edge the refcount
  has already given up.
- The queue push is performed **by the mutator thread itself** into a
  **thread-local** SATB queue: no cross-thread writes, no locks. The
  marker drains full queue segments. This respects the rule that only
  the owning thread mutates its state; the GC thread only reads handed-
  off segments.
- Outside a marking epoch the hook costs one flag load + predicted
  branch (~1–3 cycles), sitting next to RC work that is already there.
  With build-time strategy selection, non-`rc-satb` builds contain no
  trace of it.
- The queue stores the *old value* only. Pushing "to be freed" would be
  the opposite of the intent: the queue keeps snapshot references
  **alive** for this epoch.

## Epoch protocol

```
1. TRIGGER      threshold on cycle-candidate bytes (calibrate; cf. Zend 10K roots)
2. SNAPSHOT     brief all-threads safepoint:
                  - scan stacks + globals → initial gray set
                  - set marking_active
                (bounded by root count, not heap size; this is the only pause)
3. MARK         background marker traces from gray set;
                mutator runs, deletion barrier feeds the queue;
                marker drains SATB queues as additional gray sources
4. TERMINATE    marker exhausts gray set; final safepoint:
                  - drain remaining queue segments, finish marking
                  - clear marking_active
5. SWEEP        unmarked refcounted blocks in the general heap are cycle
                garbage → three-phase teardown, deferred-free honored
```

Floating garbage (died during MARK) stays until the next epoch: the
standard SATB cost, bounded by epoch length.

## Integration with heap-design.md machinery

Both coordination mechanisms defined in
[heap-design.md](heap-design.md) exist **for this strategy**; under
`rc-trace` the mutator is parked and the races never occur:

- **CAS handoff (`LIVE / SCANNING / DEAD`)** resolves the
  delete-vs-scan race: a refcount hitting zero mid-epoch (mutator
  freeing) versus the marker scanning that object. One CAS decides the
  winner. It does *not* protect the tri-color invariant, and is not
  meant to; that is the deletion barrier's job. The two are
  complementary, not alternatives.
- **Deferred-free bit**: while `marking_active`, frees queue instead of
  releasing memory, keeping the marker's view of block contents stable;
  the queue flushes at epoch end.

## Interaction with arenas

- Arena objects are invisible to the marker (contract:
  [strategies.md](strategies.md)); the category barrier already logs
  arena escapes independently of the epoch.
- **Sticky blocks** from arena-reset Mode B
  ([arena-reset.md](../memory/arena-reset.md)) are exactly the objects
  with no refcount history; the tracing component of this strategy
  manages them, as anticipated there.
- A future LXR-style build (deferred RC, saturated 2-bit counts; see
  [gc-research.md](gc-research.md)) would reuse this same SATB
  machinery; that remains research, not a committed strategy.

## What this strategy does not do

- No moving, no compaction: the non-moving constraint holds; no read
  barriers of any kind.
- No insertion (incremental-update) barrier: SATB was chosen because
  the deletion barrier permits termination without rescanning mutated
  blacks.
- Strings and other leaf entities are never cycle candidates; the
  marker traces only container/object graphs (same focus elephc's
  collector chose).

## Open questions

- **Epoch trigger calibration** — candidate-bytes threshold vs
  allocation volume; measure on real workloads.
- **SATB queue overflow policy** — segment size, marker backpressure,
  degenerate case of a mutator flooding deletions faster than the
  marker drains.
- **Marker parallelism** — one background marker thread first;
  work-stealing parallel marking only if profiles demand it.
