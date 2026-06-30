# GC Heap Design Decisions

## Heap Structure: Immix-style blocks (no global object list)

**Decision**: Limelight does not maintain a global linked list of objects. The heap structure itself serves as the object enumeration mechanism.

The heap is divided into fixed-size **blocks** (32KB, aligned to their size). Each block is subdivided into **lines** (256 bytes). The GC enumerates all live objects by linearly scanning blocks — no separate list required.

**Why:**
- A global intrusive linked list is shared mutable state — requires synchronization on every allocation and free.
- Linear block traversal is cache-friendly: scanning a block = sequential memory reads. A linked list of heap objects scattered across memory causes pointer-chasing cache misses.
- Block boundaries are computable from any pointer (mask off the low 15 bits) — the GC always knows which block an object belongs to without a lookup.

This is the approach used by MMTK, Immix, and LXR. Global object lists (as in Boehm GC, early PHP) are considered obsolete for this reason.

---

## GC / Mutator Coordination: Lock-Free CAS Handoff

**Decision**: GC and mutator coordinate ownership of objects via a single atomic CAS on the object's state field. Neither side waits for the other.

### Protocol

Each object has an atomic state field with at least three values: `LIVE`, `SCANNING`, `DEAD`.

```
Mutator (deleting):              GC (scanning):
CAS(obj.state, LIVE → DEAD)      CAS(obj.state, LIVE → SCANNING)

Success → mutator owns the        Success → GC owns the object,
object, proceeds with free.       proceeds with scan.

Failure → GC got there first,     Failure → mutator got there first,
mutator steps back.                GC skips the object.
```

One CAS determines the winner. No locks, no barriers, no waiting.

### Why this works with Immix

Because the GC enumerates objects by scanning blocks linearly, it encounters objects in a predictable, localized order. Contention between the GC and the mutator is low: the GC visits each object once per collection cycle, and the mutator deletes objects on its own schedule. The probability of simultaneous CAS on the same object is proportional to GC frequency × mutator delete rate, which is small in practice.

### Cost

- Uncontended CAS: ~10–40 cycles
- Contended CAS (rare): ~100–300 cycles + cache line bounce

This is faster than any stop-the-world approach. Compared to write-barrier + SATB, the cost depends on contention frequency — for typical PHP workloads where GC cycles are infrequent relative to mutator activity, contention is low and CAS is cheap.

### What happens when GC wins but object becomes unreachable during scan

The GC completes its scan of the object, then checks reachability. If the object is unreachable (refcount dropped to zero or no tracing paths reach it), the GC enqueues it for deferred reclamation. The mutator does not need to be involved — it already stepped back from the CAS.
