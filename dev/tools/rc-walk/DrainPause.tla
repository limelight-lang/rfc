----------------------------- MODULE DrainPause -----------------------------
(* What a synchronous collection may condemn while a drain is paused      *)
(* (model/gc/walk/questions.md, node D3). Sage permitted the mutator to   *)
(* leave a batch half freed at three boundaries — between messages, after *)
(* the prologue before the sever, and inside the sever between one cell's *)
(* empty-and-record pair and the next — and the same node records what    *)
(* nobody had checked: the synchronous collection runs on this very       *)
(* thread, is not gated on a paused drain (`ll-model` `src/walk.rs`,      *)
(* `collect_cycles`), and meets the drain's guards outstanding. The claim *)
(* under test is that nothing the paused drain owns can be condemned      *)
(* there, and that nothing it still owes a count for can be freed.        *)
(*                                                                        *)
(* The population is small on DrainWindow.tla's pattern, but not as small *)
(* as the claim allows: the confirmed component m1 <-> m2; `x`, a child   *)
(* of m2 that a program root also holds; `y`, a child of m1 that the      *)
(* second garbage cycle d1 <-> d2 also holds. The d-cycle is what keeps a *)
(* clean run from being vacuous — the collection condemns and frees it at *)
(* every pause the run reaches, so a clean run says the pause is safe     *)
(* rather than that this model collects nothing. Nothing forces the       *)
(* collection to run at all, so the behaviour that reaps nothing is in    *)
(* the run too; what the count of states says is that both are checked.   *)
(* The d-cycle is outside                                                 *)
(* the message because it died after the verdict was posted; the verdict  *)
(* itself stands whatever holds `y`, the exact test reading the members'  *)
(* counts against their in-component in-degrees and nothing else.         *)
(*                                                                        *)
(* Broken selects a variant. "none" and "refused_boundaries" must exhaust *)
(* clean; the two below must violate, and each removes one thing the      *)
(* claim rests on:                                                        *)
(*   "guard_dropped" - the drain holds no guard across the pause, which   *)
(*                     is the shape a pause with no residue invites. The  *)
(*                     component then carries no reference the collector  *)
(*                     cannot see, and the collection takes it.           *)
(*   "double_drop"   - the sever drops an external child's count as it    *)
(*                     empties the cell and keeps the displaced entry     *)
(*                     too. The child is left with a garbage holder's     *)
(*                     count alone, so the collection reaps it while the  *)
(*                     drain still owes a drop on it. Not an invented     *)
(*                     hazard: `ref_store` is the composition of the      *)
(*                     publish and the drop (`src/memory/barrier.rs`),    *)
(*                     and a split sever written over it drops there.     *)
(* "refused_boundaries" opens the two seams the second verdict refuses —  *)
(* between the last cell and `unguard`, and anywhere inside the release   *)
(* of the external children. Neither hazard objects to them:              *)
(* the refusal rests on `unguard` running once, not on what a collection  *)
(* started there would find.                                              *)
(*                                                                        *)
(* Four abstractions, each stated because each bounds the result:         *)
(*                                                                        *)
(*  - The prologue is one step. Its user code is `run_pre_destructor`,    *)
(*    which runs after the guard is placed and whose effect on a member's *)
(*    own count is caught by `exact_test(members, 1)`, an acquittal that  *)
(*    never reaches the sever (`src/walk.rs`, `drain_confirmed`). Its     *)
(*    effect on non-members is not modelled, and a destructor that calls  *)
(*    the collection itself is a boundary this model does not have.       *)
(*  - `SeverCell` releases an in-component child as it empties the cell,  *)
(*    where `sever_component` empties every member's cells first and      *)
(*    releases afterwards. D3 permits the earlier release; the modelled   *)
(*    state carries the lower count of the two, so a clean run covers     *)
(*    both.                                                               *)
(*  - The mutator runs no program code at the pause. Every non-member     *)
(*    entity may be retained and released there, and the model omits it.  *)
(*  - `SyncCollect` frees its condemned set in one step. The collection   *)
(*    it stands for guards, nulls weak cells, runs `__destruct` on every  *)
(*    confirmed member, re-verifies and may acquit                        *)
(*    (`collect_cycles_inner`), so it runs user code of its own at the    *)
(*    pause and can leave live entities whose destructor is spent. The    *)
(*    model says nothing about either.                                    *)
(*                                                                        *)
(* Two things the runs say about themselves. The corpse rule is inert     *)
(* here: removing it leaves all four configurations at the same outcome   *)
(* and the same state counts, so it is in the model to match the code     *)
(* rather than to carry a result. And a kill reports the first invariant  *)
(* violated, so `NoDanglingCell` and `NoNegativeCount` are checked at     *)
(* every state and shown to fire by nothing.                             *)
EXTENDS Naturals, FiniteSets

CONSTANT Broken

\* The confirmed component: a two-entity cycle.
Members == {"m1", "m2"}

Entities == {"m1", "m2", "x", "y", "d1", "d2"}

\* The members' counted cells. Emptying one is the empty-and-record pair
\* that Sage's second verdict makes the pause granularity.
MemberCells == {<<"m1", "m2">>, <<"m1", "y">>, <<"m2", "m1">>, <<"m2", "x">>}

\* The second garbage cycle, and its own edge into `y`.
OtherCells == {<<"d1", "d2">>, <<"d2", "d1">>, <<"d1", "y">>}

Cells == MemberCells \cup OtherCells

\* What the guard adds to a member's count and what `unguard` takes back.
GuardDelta == IF Broken = "guard_dropped" THEN 0 ELSE 1

VARIABLES
    rc,        \* refcount per entity
    indeg,     \* in-degree over the walked population
    pc,        \* the drain's position
    emptied,   \* cells emptied, by the drain's sever or the collection's
    dropped,   \* member cells whose parked count the release has dropped
    freed,     \* entities freed, by either side
    syncFreed  \* entities the synchronous collection freed

vars == <<rc, indeg, pc, emptied, dropped, freed, syncFreed>>

\* Counts as the collector confirmed them. Every member's count is
\* internal to the component, so the exact test passes; `x` carries one
\* count no in-degree explains, which is the program root.
Init ==
    /\ rc = [m1 |-> 1, m2 |-> 1, y |-> 2, x |-> 2, d1 |-> 1, d2 |-> 1]
    /\ indeg = [e \in Entities |-> Cardinality({c \in Cells : c[2] = e})]
    /\ pc = "prologue"
    /\ emptied = {}
    /\ dropped = {}
    /\ freed = {}
    /\ syncFreed = {}

LiveCells == {c \in Cells \ emptied : c[1] \notin freed}

\* An entity whose count exceeds its in-degree holds a reference no
\* walked cell explains — a guard, a program root, or a count parked in
\* the displaced vector. That is Phase 2's root predicate (`src/walk.rs`,
\* `garbage_components`; ../../../model/gc/rc-walk.md).
Roots == {e \in Entities \ freed : rc[e] > indeg[e]}

Step(S) == S \cup {c[2] : c \in {cc \in LiveCells : cc[1] \in S}}

RECURSIVE Closure(_)
Closure(S) == LET T == Step(S) IN IF T = S THEN S ELSE Closure(T)

\* Phase 2 groups the unmarked set into weakly connected components
\* (`src/walk.rs`, `garbage_components`), so the grouping is the
\* undirected closure over live cells inside that set.
Undirected(S) ==
    S \cup {c[1] : c \in {cc \in LiveCells : cc[2] \in S}}
      \cup {c[2] : c \in {cc \in LiveCells : cc[1] \in S}}

RECURSIVE Group(_, _)
Group(S, U) == LET T == Undirected(S) \cap U IN IF T = S THEN S ELSE Group(T, U)

\* What the collection would free: the unmarked groups, less the ones the
\* corpse rule refuses. Phase 4 runs `exact_test(members, 0)` per
\* component and that test drops the whole component when any member sits
\* at count zero (`src/walk.rs`, `exact_test`), so the refusal is per
\* group rather than over the unmarked set at large.
Condemned ==
    LET unmarked == (Entities \ freed) \ Closure(Roots)
        groups == {Group({e}, unmarked) : e \in unmarked}
    IN UNION {g \in groups : ~\E e \in g : rc[e] = 0}

\* The prologue, through to the guard.
Prologue ==
    /\ pc = "prologue"
    /\ rc' = [e \in Entities |-> IF e \in Members THEN rc[e] + GuardDelta ELSE rc[e]]
    /\ pc' = "post_prologue"
    /\ UNCHANGED <<indeg, emptied, dropped, freed, syncFreed>>

EnterSever ==
    /\ pc = "post_prologue"
    /\ pc' = "severing"
    /\ UNCHANGED <<rc, indeg, emptied, dropped, freed, syncFreed>>

\* One cell's empty-and-record pair. An in-component child's count drops
\* here and stops at its guard; an external child's count is parked in
\* the displaced vector and drops only after `unguard`.
SeverCell ==
    /\ pc = "severing"
    /\ \E c \in MemberCells \ emptied :
        LET child == c[2]
            drops == child \in Members \/ Broken = "double_drop"
        IN /\ emptied' = emptied \cup {c}
           /\ indeg' = [e \in Entities |-> IF e = child THEN indeg[e] - 1 ELSE indeg[e]]
           /\ rc' = [e \in Entities |->
                        IF e = child /\ drops THEN rc[e] - 1 ELSE rc[e]]
    /\ UNCHANGED <<pc, dropped, freed, syncFreed>>

\* `unguard` runs once, after the last cell of the last member, and a
\* member whose count reaches zero dies with it.
Unguard ==
    /\ pc = "severing"
    /\ MemberCells \subseteq emptied
    /\ rc' = [e \in Entities |-> IF e \in Members THEN rc[e] - GuardDelta ELSE rc[e]]
    /\ freed' = freed \cup {m \in Members : rc[m] - GuardDelta = 0}
    /\ pc' = "release"
    /\ UNCHANGED <<indeg, emptied, dropped, syncFreed>>

\* How many counts the drain still owes an entity: one per emptied member
\* cell that named it and has not been dropped, the displaced vector
\* being a vector and not a set.
Parked == {c \in (emptied \cap MemberCells) \ dropped : c[2] \notin Members}

Owed(e) == Cardinality({c \in Parked : c[2] = e})

\* The displaced vector drains one entry at a time — step 8, which the
\* second verdict admits no boundary inside. Modelled entry by entry so
\* the refused seam has states of its own; a child left at zero dies.
ReleaseOne ==
    /\ pc = "release"
    /\ \E c \in Parked :
        /\ dropped' = dropped \cup {c}
        /\ rc' = [e \in Entities |-> IF e = c[2] THEN rc[e] - 1 ELSE rc[e]]
        /\ freed' = IF rc[c[2]] - 1 = 0 THEN freed \cup {c[2]} ELSE freed
    /\ UNCHANGED <<pc, indeg, emptied, syncFreed>>

ReleaseDone ==
    /\ pc = "release"
    /\ Parked = {}
    /\ pc' = "done"
    /\ UNCHANGED <<rc, indeg, emptied, dropped, freed, syncFreed>>

\* Where the drain may stop, per the two verdicts: after the prologue,
\* and between two cells of the sever. The seam between the last cell and
\* `unguard` is not one of them.
AtPermittedBoundary ==
    \/ pc = "post_prologue"
    \/ /\ pc = "severing"
       /\ ~(MemberCells \subseteq emptied)

\* The seams the second verdict refuses: after the last cell before
\* `unguard`, and anywhere inside the release of the external children —
\* including a displaced vector drained halfway.
AtRefusedBoundary ==
    \/ /\ pc = "severing"
       /\ MemberCells \subseteq emptied
    \/ pc = "release"

MayCollect ==
    \/ AtPermittedBoundary
    \/ /\ Broken = "refused_boundaries"
       /\ AtRefusedBoundary

\* The synchronous collection at a boundary. It runs to completion on
\* this thread while the drain waits, so it is one step: it frees what no
\* root reaches, empties the cells of what it freed, and drops the count
\* every such cell held on a survivor. A collection that condemns nothing
\* is a no-op and is left disabled.
SyncCollect ==
    /\ MayCollect
    /\ Condemned /= {}
    /\ LET dead == Condemned
           cut == {c \in Cells \ emptied : c[1] \in dead}
           lost(e) == Cardinality({c \in cut : c[2] = e /\ e \notin dead})
       IN /\ freed' = freed \cup dead
          /\ syncFreed' = syncFreed \cup dead
          /\ emptied' = emptied \cup cut
          /\ rc' = [e \in Entities |-> rc[e] - lost(e)]
          /\ indeg' = [e \in Entities |-> indeg[e] - lost(e)]
    /\ UNCHANGED <<pc, dropped>>

Done ==
    /\ pc = "done"
    /\ UNCHANGED vars

Next == Prologue \/ EnterSever \/ SeverCell \/ Unguard
            \/ ReleaseOne \/ ReleaseDone \/ SyncCollect \/ Done

Spec == Init /\ [][Next]_vars

\* The three hazards a collection under a paused drain would produce, and
\* a count driven below zero, which is a drop nobody owed.
NoOwnedFreed == syncFreed \cap Members = {}

NoOwedDrop == \A e \in syncFreed : Owed(e) = 0

NoDanglingCell == \A c \in LiveCells : c[2] \notin freed

NoNegativeCount == \A e \in Entities : rc[e] >= 0

=============================================================================
