---------------------------- MODULE DrainWindow ----------------------------
(* The drain-exclusivity window of the rc-walk verdict protocol           *)
(* (model/gc/drain-window.md): the mutator's drain of a posted component  *)
(* and the collector never hold access to the same entities at the same  *)
(* time. Deliberately tiny — access-interest windows only, no refcounts,  *)
(* no fields, two components — so exhaustion stays under ~100 states.     *)
(*                                                                        *)
(* The collector runs a linear script over components 1 and 2: begin      *)
(* read ("rb"), end read ("re"), post the verdict ("post"), then the      *)
(* close gate ("wait", passable only at outstanding = 0), then the next   *)
(* epoch's walk ("wb"/"we"), which reads EVERY entity (the ALL sentinel). *)
(* The mutator pops posted components and drains them, decrementing the   *)
(* outstanding counter when the drain FINISHES.                           *)
(*                                                                        *)
(* Broken selects a variant; each removes one link of the proof and must  *)
(* violate NoOverlap (a kill config), while "none" must exhaust clean:    *)
(*   "post_before_read" - the collector posts before its last read of    *)
(*                        the component (kills link 1: post follows the   *)
(*                        last read, ordered by the queue mutex).         *)
(*   "touch_after_post" - the collector re-reads a component it already  *)
(*                        posted (kills link 2: no return after post).    *)
(*   "early_sub"        - the drain acks at pop instead of at finish     *)
(*                        (kills link 3: the Release decrement follows    *)
(*                        the drain's last access, so the close gate's    *)
(*                        Acquire read orders the next walk after it).    *)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANT Broken

\* `reading` sentinel: the next epoch's walk touches every entity.
ALL == 3

VARIABLES
    pc,          \* collector script position
    reading,     \* component the collector holds read access to (0 none)
    posted,      \* verdicts posted and not yet popped (the queue)
    outstanding, \* verdicts posted and not yet acked
    draining     \* component the mutator is draining (0 none)

vars == <<pc, reading, posted, outstanding, draining>>

Op(o, comp) == [op |-> o, c |-> comp]

Sound ==
    <<Op("rb", 1), Op("re", 1), Op("post", 1),
      Op("rb", 2), Op("re", 2), Op("post", 2),
      Op("wait", 0), Op("wb", 0), Op("we", 0)>>

PostBeforeRead ==
    <<Op("post", 1), Op("rb", 1), Op("re", 1),
      Op("post", 2), Op("rb", 2), Op("re", 2),
      Op("wait", 0), Op("wb", 0), Op("we", 0)>>

TouchAfterPost ==
    <<Op("rb", 1), Op("re", 1), Op("post", 1),
      Op("rb", 2), Op("re", 2), Op("post", 2),
      Op("rb", 1), Op("re", 1),
      Op("wait", 0), Op("wb", 0), Op("we", 0)>>

\* "early_sub" breaks the mutator, not the collector's script.
Script == CASE Broken = "post_before_read" -> PostBeforeRead
            [] Broken = "touch_after_post" -> TouchAfterPost
            [] OTHER                       -> Sound

Init ==
    /\ pc = 1
    /\ reading = 0
    /\ posted = {}
    /\ outstanding = 0
    /\ draining = 0

CollectorStep ==
    /\ pc <= Len(Script)
    /\ LET a == Script[pc] IN
       CASE a.op = "rb" ->
                /\ reading' = a.c
                /\ pc' = pc + 1
                /\ UNCHANGED <<posted, outstanding, draining>>
         [] a.op = "re" ->
                /\ reading' = 0
                /\ pc' = pc + 1
                /\ UNCHANGED <<posted, outstanding, draining>>
         [] a.op = "post" ->
                /\ posted' = posted \cup {a.c}
                /\ outstanding' = outstanding + 1
                /\ pc' = pc + 1
                /\ UNCHANGED <<reading, draining>>
         [] a.op = "wait" ->
                /\ outstanding = 0     \* the close gate
                /\ pc' = pc + 1
                /\ UNCHANGED <<reading, posted, outstanding, draining>>
         [] a.op = "wb" ->
                /\ reading' = ALL
                /\ pc' = pc + 1
                /\ UNCHANGED <<posted, outstanding, draining>>
         [] a.op = "we" ->
                /\ reading' = 0
                /\ pc' = pc + 1
                /\ UNCHANGED <<posted, outstanding, draining>>

\* Pop a posted verdict: the drain's access window opens. The counter
\* moves here only in the broken "early_sub" variant.
Pop ==
    /\ draining = 0
    /\ \E c \in posted:
           /\ draining' = c
           /\ posted' = posted \ {c}
    /\ outstanding' = IF Broken = "early_sub"
                          THEN outstanding - 1
                          ELSE outstanding
    /\ UNCHANGED <<pc, reading>>

\* The drain finished: window closes, then the ack (fetch_sub Release).
Finish ==
    /\ draining /= 0
    /\ draining' = 0
    /\ outstanding' = IF Broken = "early_sub"
                          THEN outstanding
                          ELSE outstanding - 1
    /\ UNCHANGED <<pc, reading, posted>>

\* Terminal stutter so a finished run is not a deadlock.
Done ==
    /\ pc > Len(Script)
    /\ draining = 0
    /\ posted = {}
    /\ UNCHANGED vars

Next == CollectorStep \/ Pop \/ Finish \/ Done

Spec == Init /\ [][Next]_vars

\* The claim: no entity is ever accessed by both sides at once. The
\* next-epoch walk (ALL) counts as touching every entity.
NoOverlap ==
    \/ draining = 0
    \/ /\ reading /= draining
       /\ reading /= ALL

=============================================================================
