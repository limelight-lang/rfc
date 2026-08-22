# The walk, second version: the protocol

**Draft, 2026-08-22.** The first version is
[`../rc-walk.md`](../rc-walk.md); it is the record of what came before and
not a text this one has to agree with.

## What changes

One thing. In the first version the collector produced suspects and the
mutator confirmed and freed them, because confirmation had to run where
nothing races it and freeing rode along in the same visit. Here the collector
confirms and frees on its own thread. The mutator's whole part is two stores
per acquiring section, and it never handles a verdict.

## The reference count, unchanged

A heap edge carries a count. Publishing a reference retains, overwriting one
releases, a release reaching zero tears the entity down on the spot. That is
the barrier, it is what makes an ordinary death immediate, and nothing below
touches it. The walk exists for what the count cannot see: a ring whose
members hold each other.

## Phase-critical sections

The mutator marks the interval in which it takes a new reference out of the
heap. Two stores into its own memory, no lock, no foreign line:

```
enter:   me.epoch = global_epoch      // one relaxed store, release fence
  tmp = load(slot)                    // the acquisition
  retain(tmp)
exit:    me.epoch = INACTIVE          // one store
```

Outside a section the mutator dereferences, computes, calls and writes fields
as it pleases. What it may not do outside a section is take a reference it
did not already hold.

**What the section is for.** It gives the collector one thing it cannot get
otherwise: a moment at which no thread is part-way through acquiring. Nothing
else about the mutator's execution is constrained, and no thread is ever
stopped or signalled.

## The collection cycle

### 1. Walk

The collector enumerates the walked population and records, per entity, its
count and its out-edges into private arrays. It reads a heap the mutator is
changing, so what it produces is a set of **candidate components**, not a
verdict.

### 2. Wait for a quiescent point

The collector advances the global epoch and then reads every thread's epoch
cell. While any thread's cell holds the previous epoch, that thread may be
part-way through an acquisition; the collector does other work and looks
again. It never waits on a thread and never asks one to stop.

### 3. Confirm

At a quiescent point the collector re-reads the count of every member of a
candidate component and recomputes the in-component in-degree from the
members' current fields. When every member's count equals its in-degree,
every reference to every member comes from inside the component, and the
component is garbage.

**Why the verdict then holds.** The confirmation reads two things at
different instants — each member's count, and each member's fields — and the
verdict is sound only if the result is what a single instant would have
given. Three steps establish that, and together they are the whole safety
argument.

*The counts are not understated.* One operation raises a count: acquiring a
reference. At a quiescent point no thread is inside an acquisition, so no
raise is in flight and none has been lost between the collector's read and
the moment it reads the next member.

*The fields cannot move under the recomputation.* Writing a field of a member
requires holding that member. A held member's count exceeds its in-component
in-degree, so the equality fails on it. The two outcomes are therefore the
only ones: either the check fails, or no mutator can reach a member and the
component is motionless for the whole recomputation. The recomputation needs
no protection of its own, and it is Edmond's own argument of 2026-08-22 —
a component nothing outside holds is one the mutator cannot touch — applied
to the confirmation rather than to the walk.

*Nothing can come to hold a member afterwards.* A mutator obtains a reference
only by reading it out of something it already reaches. The equality says no
path from outside reaches a member, so no read can produce one, and no other
operation creates a reference out of nothing. Unreachability is stable.

The dangerous case of the first version — the mutator acquiring a new
reference to a member between the walk's read and the free — is closed by the
first step, and closed on the collector's side rather than by handing the
component to the mutator.

**What the argument rests on, stated so it can be attacked.** That an
acquisition is the only operation that raises a count; that every acquisition
lies inside a marked section; that reaching a member is necessary to write
one of its fields; and that a quiescent point is observable without stopping
a thread. Each is a claim about the lowering, not about the collector, and
each fails if the compiler emits one acquisition outside a section.

### 4. Reclaim

Where every destructor in the component's death cascade is proven pure, the
collector does the whole of it: runs the destructors, nulls the weak cells,
severs the members, and returns the memory, cross-thread through
`remote_free`. Nothing crosses to the mutator.

Where the cascade contains an impure destructor, the component goes to the
mutator, which runs the destructor at a checkpoint and reclaims from there.
The reason is not verification, which is already done: an impure destructor
is user code, and user code needs the mutator's execution context.

## What the mutator pays

Two stores into its own memory per acquiring section. No verdict queue, no
confirmation pass, no drain, and no per-store barrier beyond the count it
already keeps.

## Open

The nodes of [questions.md](questions.md), and these, which this draft
creates:

- **The section's granularity.** One section per acquisition is the safe
  form and the most stores; one section per basic block, or per call, is
  fewer stores and a longer interval in which no quiescent point exists. The
  compiler chooses, and what it should choose is a measurement.
- **A thread that never leaves a section** — a long loop that keeps
  acquiring — leaves the collector without a quiescent point. Bounding that
  is the same problem the first version's checkpoint coverage had, and it is
  not solved here.
- **Which population the walk enumerates**, and what it may skip: nodes B1
  to B4.
- **The purity proof**, without which section 4's first arm is empty for
  every class that has a destructor at all:
  [compiler-proofs.md](compiler-proofs.md), section 5.
