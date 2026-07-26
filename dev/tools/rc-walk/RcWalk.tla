---------------------------- MODULE RcWalk ----------------------------
(* Scenario-mode interleaving model of the rc-walk collector.          *)
(* Source of truth: rfc/model/gc/rc-walk-model.md (alphabets, state    *)
(* vector, invariants) and rc-walk.md (the protocol, as amended        *)
(* 2026-07-26: condemned entities never die on the ordinary path,      *)
(* acquittal clears bytes and tears deferred deaths, weak components). *)
(*                                                                     *)
(* The mutator plays a fixed script; the only nondeterminism is WHERE  *)
(* its steps land between collector micro-steps — the collisions that  *)
(* matter, not free-play.  ScriptName = "free" restores the unbounded  *)
(* mutator for offline exhaustion runs.                                *)
EXTENDS Naturals, FiniteSets, Sequences

CONSTANTS ByteOnly,   \* Phase 3 = byte re-read only, no Phase 4
          NonTotal,   \* walker may omit a row while edges into it exist
          NoDefer,    \* freed slots reusable during an epoch
          NoSever,    \* Phase 4 un-guards without severing
          OldDeath,   \* pre-fix rule: condemned entities die normally
          NoAlloc,    \* free mode only: disable MNew
          ScriptName, \* which mutator script runs (see Scripts below)
          InitShape   \* "migration" | "garbage" | "heldchild"

Slots   == 1..3
Fields  == 1..2
Frames  == 1..2
NoRef   == 0
Absent  == 99
NotRead == 99

(* Scripts: action = <<name, args...>>.                                *)
(*   load  fr src f | drop fr | storeval dst f fr | storenull dst f    *)
(*   borrowu fr src f (bind WITHOUT retain — the uncounted borrow)     *)
(*   new fr                                                            *)
TheScript ==
  CASE ScriptName = "selfloop"   -> <<<<"load",2,1,1>>, <<"drop",1>>,
                                     <<"storeval",2,1,2>>, <<"storeval",2,2,2>>>>
    [] ScriptName = "borrow"     -> <<<<"load",2,1,2>>, <<"drop",1>>>>
    [] ScriptName = "migrate"    -> <<<<"load",2,1,2>>, <<"storenull",1,2>>,
                                     <<"drop",1>>>>
    [] ScriptName = "borrowdrop" -> <<<<"load",2,1,2>>, <<"drop",1>>,
                                     <<"drop",2>>>>
    [] ScriptName = "dc3"        -> <<<<"load",2,1,2>>, <<"drop",1>>,
                                     <<"drop",2>>, <<"new",1>>>>
    [] ScriptName = "uncounted"  -> <<<<"borrowu",2,1,2>>, <<"drop",1>>>>
    [] OTHER                     -> <<>>   \* "none", "free"

VARIABLES occ, rcnt, eb, cb, fld,      \* heap
          frame, mpc,                  \* mutator + script counter
          cpc, snap, wtodo, wfld,      \* collector: phase, snapshot, walk
          crc, cedg,                   \* collector-private snapshot arrays
          comp, msg, workS, workE,     \* candidate component, message, work
          bad                          \* drain touched a non-live slot

vars == <<occ, rcnt, eb, cb, fld, frame, mpc, cpc, snap, wtodo, wfld,
          crc, cedg, comp, msg, workS, workE, bad>>

heapVars == <<occ, rcnt, eb, cb, fld>>
colVars  == <<cpc, snap, wtodo, wfld, crc, cedg, comp, msg, workS, workE>>

EpochActive == cpc # "idle"
DieMode == IF EpochActive /\ ~NoDefer THEN "parked" ELSE "free"

(* ------------------------- ground truth --------------------------- *)

ReachStep(R) == R \cup ({fld[s][f] : s \in R, f \in Fields} \ {NoRef})
Reach == LET R0 == {frame[fr] : fr \in Frames} \ {NoRef}
         IN ReachStep(ReachStep(ReachStep(R0)))

TrueRC(s) == Cardinality({fr \in Frames : frame[fr] = s})
           + Cardinality({<<t, f>> \in Slots \X Fields : fld[t][f] = s})

(* --------------------- death and zombification -------------------- *)
(* A release cascade: least fixpoint = what refcounting actually      *)
(* frees.  Under the 2026-07-26 rule a condemned entity never dies on *)
(* this path: it drops to rc = 0 but stays live — a "zombie" owned by *)
(* the drain (or by the acquittal that clears its byte).  OldDeath    *)
(* restores the pre-fix semantics for the F5 reachability runs.       *)

MayDie(c, cbF) == OldDeath \/ ~cbF[c]

EdgesIntoF(flF, D, c) ==
  Cardinality({<<s, f>> \in D \X Fields : flF[s][f] = c})

(* Effects of a simultaneous loss of counted refs, over explicit      *)
(* rc/fld/cb snapshots (so store actions can pre-apply the retain and *)
(* the field write).  Zombies fall out automatically: they lose the   *)
(* count but stay out of D, keep fields, stay live.                   *)
LossEffect(loss, rcF, flF, cbF) ==
  LET Grow(D) == D \cup {c \in Slots :
                   /\ occ[c] = "live" /\ MayDie(c, cbF)
                   /\ rcF[c] = loss[c] + EdgesIntoF(flF, D, c)}
      D == Grow(Grow(Grow({})))
      lost(c) == loss[c] + EdgesIntoF(flF, D, c)
  IN [dead |-> D,
      occ  |-> [s \in Slots |-> IF s \in D THEN DieMode ELSE occ[s]],
      rcnt |-> [s \in Slots |-> IF s \in D THEN 0 ELSE rcF[s] - lost(s)],
      fld  |-> [s \in Slots |-> IF s \in D THEN [f \in Fields |-> NoRef]
                                            ELSE flF[s]],
      cb   |-> [s \in Slots |-> IF s \in D \/ lost(s) > 0 THEN FALSE
                                                          ELSE cbF[s]]]

ApplyRec(R) == /\ occ' = R.occ /\ rcnt' = R.rcnt /\ fld' = R.fld /\ cb' = R.cb

OneLoss(t) == [s \in Slots |-> IF s = t THEN 1 ELSE 0]

(* Acquittal / drop duties: clear the members' bytes, then tear down  *)
(* zombie members (rc = 0, still live) — their deaths were deferred.  *)
TearRec(K) ==
  LET cb1 == [s \in Slots |-> IF s \in K THEN FALSE ELSE cb[s]]
      Z == {m \in K : occ[m] = "live" /\ rcnt[m] = 0}
      loss == [c \in Slots |->
                 IF c \in Z THEN 0 ELSE EdgesIntoF(fld, Z, c)]
      Grow(D) == D \cup {c \in Slots \ Z :
                   /\ occ[c] = "live" /\ MayDie(c, cb1)
                   /\ rcnt[c] = loss[c] + EdgesIntoF(fld, D \cup Z, c)}
      D == Grow(Grow(Grow({})))
      gone == Z \cup D
      lost(c) == loss[c] + EdgesIntoF(fld, D, c)
  IN [occ  |-> [s \in Slots |-> IF s \in gone THEN DieMode ELSE occ[s]],
      rcnt |-> [s \in Slots |-> IF s \in gone THEN 0 ELSE rcnt[s] - lost(s)],
      fld  |-> [s \in Slots |-> IF s \in gone THEN [f \in Fields |-> NoRef]
                                               ELSE fld[s]],
      cb   |-> [s \in Slots |-> IF s \in gone \/ lost(s) > 0 THEN FALSE
                                                             ELSE cb1[s]]]

(* --------------------- mutator operations ------------------------- *)
(* Op* carry only guards and heap/frame effects; script vs free mode  *)
(* is decided in Next.  Checkpoint-borne work (MAck, MDrain) is       *)
(* reactive and always available — it is not a script step.           *)

FrameHolds(s) == \E fr \in Frames : frame[fr] = s

OpNew(fr) ==
  /\ cpc \notin {"await_ack", "wait_drain"}   \* checkpoint-first
  /\ frame[fr] = NoRef
  /\ \E s \in Slots :
       /\ occ[s] \in {"virgin", "free"}
       /\ occ'  = [occ EXCEPT ![s] = "live"]
       /\ rcnt' = [rcnt EXCEPT ![s] = 1]
       /\ eb'   = [eb EXCEPT ![s] = "zero"]
       /\ cb'   = [cb EXCEPT ![s] = FALSE]
       /\ fld'  = [fld EXCEPT ![s] = [f \in Fields |-> NoRef]]
       /\ frame' = [frame EXCEPT ![fr] = s]

OpLoad(fr, src, f) ==
  /\ FrameHolds(src) /\ frame[fr] = NoRef /\ fld[src][f] # NoRef
  /\ LET t == fld[src][f] IN
       /\ frame' = [frame EXCEPT ![fr] = t]
       /\ rcnt' = [rcnt EXCEPT ![t] = @ + 1]
       /\ cb'   = [cb EXCEPT ![t] = FALSE]
  /\ UNCHANGED <<occ, eb, fld>>

OpBorrowU(fr, src, f) ==
  /\ FrameHolds(src) /\ frame[fr] = NoRef /\ fld[src][f] # NoRef
  /\ frame' = [frame EXCEPT ![fr] = fld[src][f]]
  /\ UNCHANGED heapVars

(* store(dst.f, y): retain new, WRITE THE FIELD, then release old —   *)
(* the release is last (F7 fix), computed on the updated field state. *)
OpStoreVal(dst, f, fr) ==
  /\ FrameHolds(dst) /\ frame[fr] # NoRef
  /\ LET new == frame[fr]
         old == fld[dst][f]
     IN IF old = new
        THEN /\ cb' = [cb EXCEPT ![new] = FALSE]
             /\ UNCHANGED <<occ, rcnt, eb, fld>>
        ELSE LET rc1 == [rcnt EXCEPT ![new] = @ + 1]
                 cb1 == [cb EXCEPT ![new] = FALSE]
                 fl1 == [fld EXCEPT ![dst][f] = new]
                 loss == IF old = NoRef THEN [s \in Slots |-> 0]
                                        ELSE OneLoss(old)
             IN /\ ApplyRec(LossEffect(loss, rc1, fl1, cb1))
                /\ UNCHANGED eb
  /\ UNCHANGED frame

OpStoreNull(dst, f) ==
  /\ FrameHolds(dst) /\ fld[dst][f] # NoRef
  /\ LET old == fld[dst][f]
         fl1 == [fld EXCEPT ![dst][f] = NoRef]
     IN /\ ApplyRec(LossEffect(OneLoss(old), rcnt, fl1, cb))
        /\ UNCHANGED eb
  /\ UNCHANGED frame

OpDrop(fr) ==
  /\ frame[fr] # NoRef
  /\ ApplyRec(LossEffect(OneLoss(frame[fr]), rcnt, fld, cb))
  /\ frame' = [frame EXCEPT ![fr] = NoRef]
  /\ UNCHANGED eb

MutFree ==
  /\ ScriptName = "free"
  /\ \/ \E fr \in Frames : (~NoAlloc /\ OpNew(fr)) \/ OpDrop(fr)
     \/ \E fr \in Frames, s \in Slots, f \in Fields : OpLoad(fr, s, f)
     \/ \E s \in Slots, f \in Fields, fr \in Frames : OpStoreVal(s, f, fr)
     \/ \E s \in Slots, f \in Fields : OpStoreNull(s, f)
  /\ UNCHANGED mpc /\ UNCHANGED colVars /\ UNCHANGED bad

MutScript ==
  /\ ScriptName # "free" /\ mpc <= Len(TheScript)
  /\ LET a == TheScript[mpc] IN
       CASE a[1] = "load"      -> OpLoad(a[2], a[3], a[4])
         [] a[1] = "drop"      -> OpDrop(a[2])
         [] a[1] = "storeval"  -> OpStoreVal(a[2], a[3], a[4])
         [] a[1] = "storenull" -> OpStoreNull(a[2], a[3])
         [] a[1] = "borrowu"   -> OpBorrowU(a[2], a[3], a[4])
         [] a[1] = "new"       -> OpNew(a[2])
  /\ mpc' = mpc + 1
  /\ UNCHANGED colVars /\ UNCHANGED bad

(* ------------------------ collector: walk ------------------------- *)

CTrigger ==
  /\ cpc = "idle"
  /\ snap' = {s \in Slots : occ[s] # "virgin"}
  /\ wtodo' = {s \in Slots : occ[s] # "virgin"}
  /\ wfld' = {}
  /\ crc'  = [s \in Slots |-> Absent]
  /\ cedg' = [s \in Slots |-> [f \in Fields |-> NotRead]]
  /\ cpc' = "walk" /\ comp' = {} /\ msg' = {} /\ workS' = {} /\ workE' = {}
  /\ UNCHANGED heapVars /\ UNCHANGED <<frame, mpc>> /\ UNCHANGED bad

CWalkClassify(s) ==
  /\ cpc = "walk" /\ s \in wtodo
  /\ \/ (* free / dying / zombie: occupancy test *)
        /\ rcnt[s] = 0
        /\ wtodo' = wtodo \ {s}
        /\ UNCHANGED <<eb, crc, wfld>>
     \/ (* new: stamp and skip (allocate-black) *)
        /\ rcnt[s] > 0 /\ eb[s] \in {"zero", "cur"}
        /\ eb' = [eb EXCEPT ![s] = "cur"]
        /\ wtodo' = wtodo \ {s}
        /\ UNCHANGED <<crc, wfld>>
     \/ (* mature: record the row, queue the field reads *)
        /\ rcnt[s] > 0 /\ eb[s] = "old"
        /\ crc' = [crc EXCEPT ![s] = rcnt[s]]
        /\ wfld' = wfld \cup {<<s, f>> : f \in Fields}
        /\ wtodo' = wtodo \ {s}
        /\ UNCHANGED eb
     \/ (* NonTotal breakage: mature row silently omitted             *)
        /\ NonTotal
        /\ rcnt[s] > 0 /\ eb[s] = "old"
        /\ wtodo' = wtodo \ {s}
        /\ UNCHANGED <<eb, crc, wfld>>
  /\ UNCHANGED <<occ, rcnt, cb, fld, frame, mpc>>
  /\ UNCHANGED <<cpc, snap, cedg, comp, msg, workS, workE, bad>>

CWalkField(s, f) ==
  /\ cpc = "walk" /\ <<s, f>> \in wfld
  /\ LET v == fld[s][f]
         valid == v # NoRef /\ v \in snap /\ rcnt[v] > 0
     IN cedg' = [cedg EXCEPT ![s][f] = IF valid THEN v ELSE NoRef]
  /\ wfld' = wfld \ {<<s, f>>}
  /\ UNCHANGED heapVars /\ UNCHANGED <<frame, mpc>>
  /\ UNCHANGED <<cpc, snap, wtodo, crc, comp, msg, workS, workE, bad>>

(* --------------------- collector: diff & mark --------------------- *)

RecordedEdges == {p \in Slots \X Fields : cedg[p[1]][p[2]] \in Slots}
Inn(c) == Cardinality({p \in RecordedEdges : cedg[p[1]][p[2]] = c})
Rows == {s \in Slots : crc[s] # Absent}
Vval(s) == IF crc[s] = Absent THEN 0 ELSE crc[s]
Universe == Rows \cup {cedg[p[1]][p[2]] : p \in RecordedEdges}
Roots == {s \in Universe : Vval(s) > Inn(s)}
MarkStep(M) == M \cup {cedg[p[1]][p[2]] :
                         p \in {q \in RecordedEdges : q[1] \in M}}
Marked == MarkStep(MarkStep(MarkStep(Roots)))
Unmarked == Universe \ Marked
Linked(a, b) == \E p \in RecordedEdges :
                  \/ p[1] = a /\ cedg[p[1]][p[2]] = b
                  \/ p[1] = b /\ cedg[p[1]][p[2]] = a
CompGrow(S) == S \cup {c \in Unmarked : \E a \in S : Linked(a, c)}
CompOf(s) == CompGrow(CompGrow(CompGrow({s})))   \* weak connectivity

CDiff ==
  /\ cpc = "walk" /\ wtodo = {} /\ wfld = {}
  /\ IF Unmarked = {}
     THEN /\ cpc' = "flush" /\ UNCHANGED <<comp, workS>>
     ELSE \E s \in Unmarked :
            /\ comp' = CompOf(s)
            /\ workS' = CompOf(s)
            /\ cpc' = "condemn"
  /\ UNCHANGED heapVars /\ UNCHANGED <<frame, mpc>>
  /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, msg, workE, bad>>

(* ------------------ collector: condemn & re-check ----------------- *)

CCondemn(s) ==
  /\ cpc = "condemn" /\ s \in workS
  /\ cb' = [cb EXCEPT ![s] = TRUE]
  /\ workS' = workS \ {s}
  /\ cpc' = IF workS = {s} THEN "await_ack" ELSE "condemn"
  /\ UNCHANGED <<occ, rcnt, eb, fld, frame, mpc>>
  /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, comp, msg, workE, bad>>

MAck ==
  /\ cpc = "await_ack"
  /\ cpc' = IF ByteOnly THEN "recheck_byte" ELSE "recheck_cnt"
  /\ workS' = comp
  /\ workE' = IF ByteOnly THEN {}
              ELSE {p \in RecordedEdges : cedg[p[1]][p[2]] \in comp}
  /\ UNCHANGED heapVars /\ UNCHANGED <<frame, mpc>>
  /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, comp, msg, bad>>

(* Acquittal: clear bytes, tear deferred deaths, drop the component.  *)
Acquit == /\ ApplyRec(TearRec(comp)) /\ UNCHANGED eb
          /\ cpc' = "flush" /\ comp' = {} /\ workS' = {} /\ workE' = {}
          /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, msg>>

CRecheckCnt(s) ==
  /\ cpc = "recheck_cnt" /\ s \in workS
  /\ IF crc[s] # Absent /\ rcnt[s] # crc[s]
     THEN Acquit
     ELSE /\ UNCHANGED heapVars
          /\ IF workS # {s}
             THEN /\ workS' = workS \ {s} /\ cpc' = "recheck_cnt"
                  /\ UNCHANGED workE
             ELSE IF workE # {}
             THEN /\ workS' = {} /\ cpc' = "recheck_edge"
                  /\ UNCHANGED workE
             ELSE /\ workS' = comp /\ cpc' = "recheck_byte"
                  /\ UNCHANGED workE
          /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, comp, msg>>
  /\ UNCHANGED <<frame, mpc>> /\ UNCHANGED bad

CRecheckEdge(p) ==
  /\ cpc = "recheck_edge" /\ p \in workE
  /\ IF fld[p[1]][p[2]] # cedg[p[1]][p[2]]
     THEN Acquit
     ELSE /\ UNCHANGED heapVars
          /\ workE' = workE \ {p}
          /\ IF workE = {p}
             THEN cpc' = "recheck_byte" /\ workS' = comp
             ELSE cpc' = "recheck_edge" /\ UNCHANGED workS
          /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, comp, msg>>
  /\ UNCHANGED <<frame, mpc>> /\ UNCHANGED bad

CRecheckByte(s) ==
  /\ cpc = "recheck_byte" /\ s \in workS
  /\ IF cb[s] = FALSE
     THEN Acquit
     ELSE /\ UNCHANGED heapVars
          /\ IF workS # {s}
             THEN /\ workS' = workS \ {s} /\ cpc' = "recheck_byte"
                  /\ UNCHANGED msg
             ELSE IF ByteOnly
             THEN /\ workS' = comp /\ cpc' = "free_direct"
                  /\ UNCHANGED msg
             ELSE /\ workS' = {} /\ cpc' = "wait_drain" /\ msg' = comp
          /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, comp, workE>>
  /\ UNCHANGED <<frame, mpc>> /\ UNCHANGED bad

(* byte_only draft: the collector frees on its own verdict            *)
CFreeDirect(s) ==
  /\ cpc = "free_direct" /\ s \in workS
  /\ occ'  = [occ EXCEPT ![s] = "free"]
  /\ rcnt' = [rcnt EXCEPT ![s] = 0]
  /\ fld'  = [fld EXCEPT ![s] = [f \in Fields |-> NoRef]]
  /\ workS' = workS \ {s}
  /\ cpc' = IF workS = {s} THEN "flush" ELSE "free_direct"
  /\ UNCHANGED <<eb, cb, frame, mpc>>
  /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, comp, msg, workE, bad>>

(* --------------------- mutator: the Phase-4 drain ----------------- *)
(* Atomic on the mutator's thread.  Exact test guard-aware by         *)
(* construction (the guard is not modelled as a count change since    *)
(* the drain is one action).  A non-live member marks corruption      *)
(* (reachable only under OldDeath / NoDefer).  A zombie member        *)
(* (live, rc = 0) balances 0 = 0 and is torn down here, exactly once. *)

IndegK(K, m) == Cardinality({<<s, f>> \in K \X Fields : fld[s][f] = m})

MDrain ==
  /\ cpc = "wait_drain" /\ msg # {}
  /\ LET K == msg
         pass == \A m \in K : rcnt[m] = IndegK(K, m)
     IN IF ~pass
        THEN (* drop the message whole: bytes cleared, zombies torn *)
             /\ ApplyRec(TearRec(K)) /\ UNCHANGED eb /\ UNCHANGED bad
        ELSE IF \E m \in K : occ[m] # "live"
        THEN /\ bad' = TRUE /\ UNCHANGED heapVars
        ELSE IF NoSever
        THEN /\ UNCHANGED heapVars /\ UNCHANGED bad
        ELSE (* sever member fields, free members, cascade outside    *)
             LET fl1 == [s \in Slots |-> IF s \in K
                                         THEN [f \in Fields |-> NoRef]
                                         ELSE fld[s]]
                 cb1 == [s \in Slots |-> IF s \in K THEN FALSE ELSE cb[s]]
                 loss == [c \in Slots |->
                            IF c \in K THEN 0
                            ELSE Cardinality({<<s, f>> \in K \X Fields :
                                                fld[s][f] = c})]
                 Grow(D) == D \cup {c \in Slots \ K :
                              /\ occ[c] = "live" /\ MayDie(c, cb1)
                              /\ rcnt[c] = loss[c] + EdgesIntoF(fl1, D, c)}
                 D == Grow(Grow(Grow({})))
                 gone == K \cup D
                 lost(c) == loss[c] + EdgesIntoF(fl1, D, c)
             IN /\ occ'  = [s \in Slots |-> IF s \in gone THEN DieMode
                                                          ELSE occ[s]]
                /\ rcnt' = [s \in Slots |-> IF s \in gone THEN 0
                                            ELSE rcnt[s] - lost(s)]
                /\ fld'  = [s \in Slots |-> IF s \in gone
                                            THEN [f \in Fields |-> NoRef]
                                            ELSE fl1[s]]
                /\ cb'   = [s \in Slots |->
                              IF s \in gone \/ lost(s) > 0 THEN FALSE
                                                           ELSE cb1[s]]
                /\ UNCHANGED eb /\ UNCHANGED bad
  /\ msg' = {} /\ comp' = {} /\ cpc' = "flush"
  /\ UNCHANGED <<frame, mpc>>
  /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, workS, workE>>

(* -------------------------- epoch close --------------------------- *)

CFlush ==
  /\ cpc = "flush"
  /\ occ' = [s \in Slots |-> IF occ[s] = "parked" THEN "free" ELSE occ[s]]
  /\ eb'  = [s \in Slots |-> IF eb[s] = "cur" THEN "old" ELSE eb[s]]
  /\ cpc' = "idle"
  /\ snap' = {} /\ wtodo' = {} /\ wfld' = {}
  /\ crc'  = [s \in Slots |-> Absent]
  /\ cedg' = [s \in Slots |-> [f \in Fields |-> NotRead]]
  /\ comp' = {} /\ msg' = {} /\ workS' = {} /\ workE' = {}
  /\ UNCHANGED <<rcnt, cb, fld, frame, mpc>> /\ UNCHANGED bad

(* ----------------------------- spec ------------------------------- *)

Next ==
  \/ MutFree \/ MutScript
  \/ CTrigger \/ CDiff \/ CFlush \/ MAck \/ MDrain
  \/ \E s \in Slots : CWalkClassify(s) \/ CCondemn(s)
                      \/ CRecheckCnt(s) \/ CRecheckByte(s) \/ CFreeDirect(s)
  \/ \E s \in Slots, f \in Fields : CWalkField(s, f)
  \/ \E p \in Slots \X Fields : CRecheckEdge(p)

InitCol ==
  /\ cpc = "idle" /\ snap = {} /\ wtodo = {} /\ wfld = {}
  /\ crc = [s \in Slots |-> Absent]
  /\ cedg = [s \in Slots |-> [f \in Fields |-> NotRead]]
  /\ comp = {} /\ msg = {} /\ workS = {} /\ workE = {}
  /\ bad = FALSE /\ mpc = 1

CycleChildFld ==
  [s \in Slots |->
     IF s = 1 THEN [f \in Fields |-> IF f = 1 THEN 2 ELSE 3]
     ELSE IF s = 2 THEN [f \in Fields |-> IF f = 1 THEN 1 ELSE NoRef]
     ELSE [f \in Fields |-> NoRef]]

(* migration: live cycle s1<->s2 (f1), child s1.f2 = s3, fr1 holds s1 *)
InitMigration ==
  /\ occ = [s \in Slots |-> "live"] /\ fld = CycleChildFld
  /\ frame = [fr \in Frames |-> IF fr = 1 THEN 1 ELSE NoRef]
  /\ rcnt = [s \in Slots |-> IF s = 1 THEN 2 ELSE 1]
  /\ eb = [s \in Slots |-> "old"] /\ cb = [s \in Slots |-> FALSE]

(* garbage: same shape, frame empty — everything is dead already      *)
InitGarbage ==
  /\ occ = [s \in Slots |-> "live"] /\ fld = CycleChildFld
  /\ frame = [fr \in Frames |-> NoRef]
  /\ rcnt = [s \in Slots |-> 1]
  /\ eb = [s \in Slots |-> "old"] /\ cb = [s \in Slots |-> FALSE]

(* heldchild: garbage cycle s1<->s2, s2.f2 = s3, fr1 holds s3         *)
InitHeldChild ==
  /\ occ = [s \in Slots |-> "live"]
  /\ fld = [s \in Slots |->
              IF s = 1 THEN [f \in Fields |-> IF f = 1 THEN 2 ELSE NoRef]
              ELSE IF s = 2 THEN [f \in Fields |-> IF f = 1 THEN 1 ELSE 3]
              ELSE [f \in Fields |-> NoRef]]
  /\ frame = [fr \in Frames |-> IF fr = 1 THEN 3 ELSE NoRef]
  /\ rcnt = [s \in Slots |-> IF s = 3 THEN 2 ELSE 1]
  /\ eb = [s \in Slots |-> "old"] /\ cb = [s \in Slots |-> FALSE]

Init == /\ CASE InitShape = "migration" -> InitMigration
             [] InitShape = "garbage"   -> InitGarbage
             [] OTHER                   -> InitHeldChild
        /\ InitCol

Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Next)

(* -------------------------- properties ---------------------------- *)

TypeOK ==
  /\ occ \in [Slots -> {"virgin", "live", "free", "parked"}]
  /\ rcnt \in [Slots -> 0..9]
  /\ eb \in [Slots -> {"zero", "cur", "old"}]
  /\ cb \in [Slots -> BOOLEAN]
  /\ fld \in [Slots -> [Fields -> Slots \cup {NoRef}]]
  /\ frame \in [Frames -> Slots \cup {NoRef}]

(* T4, continuous: whatever the frame can reach is live.              *)
SafeHeap == \A s \in Reach : occ[s] = "live"

(* The drain never runs against a freed or recycled slot.             *)
NotBad == bad = FALSE

(* I1 (sound configurations): counts are honest.  A zombie is honest: *)
(* rc = 0 and nothing points at it.                                   *)
I1Honest == \A s \in Slots : occ[s] = "live" => rcnt[s] = TrueRC(s)

(* I2: no live field points at a non-live slot.                       *)
I2NoDangling == \A s \in Slots, f \in Fields :
                  fld[s][f] # NoRef => occ[fld[s][f]] = "live"

(* No live entity is ever posted (F6: does the filter ever let a      *)
(* false post through?).  Expected to FAIL under NonTotal.            *)
PostClean == msg \cap Reach = {}

(* Liveness (script "none", garbage shape): garbage is collected.     *)
EventuallyCollected == <>(\A s \in Slots : occ[s] \in {"free", "virgin"}
                                           \/ s \in Reach)
=======================================================================
