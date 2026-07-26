---------------------------- MODULE RcWalk ----------------------------
(* Scenario-mode interleaving model of the rc-walk collector.          *)
(* Source of truth: rfc/model/gc/rc-walk-model.md (alphabets, state    *)
(* vector, invariants) and rc-walk.md (the protocol, as amended        *)
(* 2026-07-26: condemned entities never die on the ordinary path,      *)
(* acquittal clears bytes and tears deferred deaths, weak components,  *)
(* guard-aware re-verify, non-reentrant drain).                        *)
(*                                                                     *)
(* The mutator plays a fixed script; the only nondeterminism is WHERE  *)
(* its steps land between collector micro-steps.  The Phase 4 drain is *)
(* phased (test -> guard -> destructors -> verify -> sever/free) so    *)
(* destructor scenarios — resurrection, allocation, re-entrancy — are  *)
(* expressible.  Slot s1 is the one entity with a destructor body,     *)
(* selected by DtorName; DESTRUCTOR_RAN is the dran set.               *)
EXTENDS Naturals, FiniteSets, Sequences

CONSTANTS ByteOnly,       \* Phase 3 = byte re-read only, no Phase 4
          NonTotal,       \* walker may omit a row while edges into it exist
          NoDefer,        \* freed slots reusable during an epoch
          NoSever,        \* Phase 4 un-guards without severing
          OldDeath,       \* pre-fix rule: condemned entities die normally
          ReentrantDrain, \* pre-fix rule: a checkpoint inside the drain
                          \* picks the in-progress message up again
          NoAlloc,        \* free mode only: disable MNew
          DtorName,       \* s1's destructor body: "none"|"resurrect"|"alloc"
          ScriptName,     \* which mutator script runs (see Scripts below)
          InitShape       \* "migration"|"garbage"|"heldchild"|"garland"
                          \* |"pair"|"pair2"

Slots   == 1..4   \* s4: the "second home" / external-holder entity
Fields  == 1..2
Frames  == 1..3
NoRef   == 0
Absent  == 99
NotRead == 99

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
    [] ScriptName = "allocstore" -> <<<<"new",2>>, <<"storeval",3,1,1>>>>
    [] ScriptName = "migratekill" -> <<<<"load",2,1,2>>, <<"storenull",1,2>>,
                                     <<"drop",1>>, <<"drop",2>>>>
    [] ScriptName = "secondhome" -> <<<<"load",2,4,1>>, <<"load",3,1,2>>,
                                     <<"storeval",4,2,3>>, <<"drop",3>>,
                                     <<"storenull",1,2>>, <<"drop",2>>,
                                     <<"storenull",4,1>>>>
    [] OTHER                     -> <<>>   \* "none", "free"

VARIABLES occ, rcnt, eb, cb, fld,      \* heap
          frame, mpc,                  \* mutator + script counter
          gcnt, dran,                  \* Phase 4 guards, DESTRUCTOR_RAN
          cpc, snap, wtodo, wfld,      \* collector: phase, snapshot, walk
          crc, cedg,                   \* collector-private snapshot arrays
          comp, msg, workS, workE,     \* candidate component, message, work
          bad                          \* drain touched a non-live slot

vars == <<occ, rcnt, eb, cb, fld, frame, mpc, gcnt, dran, cpc, snap,
          wtodo, wfld, crc, cedg, comp, msg, workS, workE, bad>>

heapVars == <<occ, rcnt, eb, cb, fld>>
colVars  == <<cpc, snap, wtodo, wfld, crc, cedg, comp, msg, workS, workE>>
dtorVars == <<gcnt, dran>>

EpochActive == cpc # "idle"
DrainPhases == {"drain_dtor", "drain_verify"}
DieMode == IF EpochActive /\ ~NoDefer THEN "parked" ELSE "free"

(* ------------------------- ground truth --------------------------- *)

ReachStep(R) == R \cup ({fld[s][f] : s \in R, f \in Fields} \ {NoRef})
Reach == LET R0 == {frame[fr] : fr \in Frames} \ {NoRef}
         IN ReachStep(ReachStep(ReachStep(ReachStep(R0))))

TrueRC(s) == Cardinality({fr \in Frames : frame[fr] = s})
           + Cardinality({<<t, f>> \in Slots \X Fields : fld[t][f] = s})

(* --------------------- death and zombification -------------------- *)

MayDie(c, cbF) == OldDeath \/ ~cbF[c]

EdgesIntoF(flF, D, c) ==
  Cardinality({<<s, f>> \in D \X Fields : flF[s][f] = c})

LossEffect(loss, rcF, flF, cbF) ==
  LET Grow(D) == D \cup {c \in Slots :
                   /\ occ[c] = "live" /\ MayDie(c, cbF)
                   /\ rcF[c] = loss[c] + EdgesIntoF(flF, D, c)}
      D == Grow(Grow(Grow(Grow({}))))
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

(* Acquittal / drop duties over an explicit count snapshot: clear the  *)
(* members' bytes, then tear down zombie members (rc = 0, live).       *)
TearRec(K, rcF) ==
  LET cb1 == [s \in Slots |-> IF s \in K THEN FALSE ELSE cb[s]]
      Z == {m \in K : occ[m] = "live" /\ rcF[m] = 0}
      loss == [c \in Slots |->
                 IF c \in Z THEN 0 ELSE EdgesIntoF(fld, Z, c)]
      Grow(D) == D \cup {c \in Slots \ Z :
                   /\ occ[c] = "live" /\ MayDie(c, cb1)
                   /\ rcF[c] = loss[c] + EdgesIntoF(fld, D \cup Z, c)}
      D == Grow(Grow(Grow(Grow({}))))
      gone == Z \cup D
      lost(c) == loss[c] + EdgesIntoF(fld, D, c)
  IN [occ  |-> [s \in Slots |-> IF s \in gone THEN DieMode ELSE occ[s]],
      rcnt |-> [s \in Slots |-> IF s \in gone THEN 0 ELSE rcF[s] - lost(s)],
      fld  |-> [s \in Slots |-> IF s \in gone THEN [f \in Fields |-> NoRef]
                                               ELSE fld[s]],
      cb   |-> [s \in Slots |-> IF s \in gone \/ lost(s) > 0 THEN FALSE
                                                             ELSE cb1[s]]]

(* --------------------- mutator operations ------------------------- *)

FrameHolds(s) == \E fr \in Frames : frame[fr] = s

OpNew(fr) ==
  /\ cpc \notin {"await_ack", "wait_drain", "wait_acquit"} \* checkpoint-first
  /\ frame[fr] = NoRef
  /\ \E s \in Slots :
       /\ occ[s] \in {"virgin", "free"}
       /\ occ'  = [occ EXCEPT ![s] = "live"]
       /\ rcnt' = [rcnt EXCEPT ![s] = 1]
       /\ eb'   = [eb EXCEPT ![s] = "zero"]
       /\ cb'   = [cb EXCEPT ![s] = FALSE]
       /\ fld'  = [fld EXCEPT ![s] = [f \in Fields |-> NoRef]]
       /\ frame' = [frame EXCEPT ![fr] = s]
       /\ dran' = dran \ {s}
  /\ UNCHANGED gcnt

OpLoad(fr, src, f) ==
  /\ FrameHolds(src) /\ frame[fr] = NoRef /\ fld[src][f] # NoRef
  /\ LET t == fld[src][f] IN
       /\ frame' = [frame EXCEPT ![fr] = t]
       /\ rcnt' = [rcnt EXCEPT ![t] = @ + 1]
       /\ cb'   = [cb EXCEPT ![t] = FALSE]
  /\ UNCHANGED <<occ, eb, fld>> /\ UNCHANGED dtorVars

OpBorrowU(fr, src, f) ==
  /\ FrameHolds(src) /\ frame[fr] = NoRef /\ fld[src][f] # NoRef
  /\ frame' = [frame EXCEPT ![fr] = fld[src][f]]
  /\ UNCHANGED heapVars /\ UNCHANGED dtorVars

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
  /\ UNCHANGED frame /\ UNCHANGED dtorVars

OpStoreNull(dst, f) ==
  /\ FrameHolds(dst) /\ fld[dst][f] # NoRef
  /\ LET old == fld[dst][f]
         fl1 == [fld EXCEPT ![dst][f] = NoRef]
     IN /\ ApplyRec(LossEffect(OneLoss(old), rcnt, fl1, cb))
        /\ UNCHANGED eb
  /\ UNCHANGED frame /\ UNCHANGED dtorVars

OpDrop(fr) ==
  /\ frame[fr] # NoRef
  /\ ApplyRec(LossEffect(OneLoss(frame[fr]), rcnt, fld, cb))
  /\ frame' = [frame EXCEPT ![fr] = NoRef]
  /\ UNCHANGED eb /\ UNCHANGED dtorVars

MutFree ==
  /\ ScriptName = "free" /\ cpc \notin DrainPhases
  /\ \/ \E fr \in Frames : (~NoAlloc /\ OpNew(fr)) \/ OpDrop(fr)
     \/ \E fr \in Frames, s \in Slots, f \in Fields : OpLoad(fr, s, f)
     \/ \E s \in Slots, f \in Fields, fr \in Frames : OpStoreVal(s, f, fr)
     \/ \E s \in Slots, f \in Fields : OpStoreNull(s, f)
  /\ UNCHANGED mpc /\ UNCHANGED colVars /\ UNCHANGED bad

MutScript ==
  /\ ScriptName # "free" /\ cpc \notin DrainPhases
  /\ mpc <= Len(TheScript)
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
  /\ UNCHANGED heapVars /\ UNCHANGED <<frame, mpc>>
  /\ UNCHANGED dtorVars /\ UNCHANGED bad

CWalkClassify(s) ==
  /\ cpc = "walk" /\ s \in wtodo
  /\ \/ /\ rcnt[s] = 0
        /\ wtodo' = wtodo \ {s}
        /\ UNCHANGED <<eb, crc, wfld>>
     \/ /\ rcnt[s] > 0 /\ eb[s] \in {"zero", "cur"}
        /\ eb' = [eb EXCEPT ![s] = "cur"]
        /\ wtodo' = wtodo \ {s}
        /\ UNCHANGED <<crc, wfld>>
     \/ /\ rcnt[s] > 0 /\ eb[s] = "old"
        /\ crc' = [crc EXCEPT ![s] = rcnt[s]]
        /\ wfld' = wfld \cup {<<s, f>> : f \in Fields}
        /\ wtodo' = wtodo \ {s}
        /\ UNCHANGED eb
     \/ /\ NonTotal
        /\ rcnt[s] > 0 /\ eb[s] = "old"
        /\ wtodo' = wtodo \ {s}
        /\ UNCHANGED <<eb, crc, wfld>>
  /\ UNCHANGED <<occ, rcnt, cb, fld, frame, mpc>> /\ UNCHANGED dtorVars
  /\ UNCHANGED <<cpc, snap, cedg, comp, msg, workS, workE, bad>>

CWalkField(s, f) ==
  /\ cpc = "walk" /\ <<s, f>> \in wfld
  /\ LET v == fld[s][f]
         (* occupancy AND maturity: the epoch-byte clause (2026-07-26) *)
         (* keeps the allocate-black skip total — an edge into a new  *)
         (* or reused slot is not recorded                            *)
         valid == v # NoRef /\ v \in snap /\ rcnt[v] > 0 /\ eb[v] = "old"
     IN cedg' = [cedg EXCEPT ![s][f] = IF valid THEN v ELSE NoRef]
  /\ wfld' = wfld \ {<<s, f>>}
  /\ UNCHANGED heapVars /\ UNCHANGED <<frame, mpc>> /\ UNCHANGED dtorVars
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
Marked == MarkStep(MarkStep(MarkStep(MarkStep(Roots))))
Unmarked == Universe \ Marked
Linked(a, b) == \E p \in RecordedEdges :
                  \/ p[1] = a /\ cedg[p[1]][p[2]] = b
                  \/ p[1] = b /\ cedg[p[1]][p[2]] = a
CompGrow(S) == S \cup {c \in Unmarked : \E a \in S : Linked(a, c)}
CompOf(s) == CompGrow(CompGrow(CompGrow(CompGrow({s}))))   \* weak connectivity

CDiff ==
  /\ cpc = "walk" /\ wtodo = {} /\ wfld = {}
  /\ IF Unmarked = {}
     THEN /\ cpc' = "flush" /\ UNCHANGED <<comp, workS>>
     ELSE \E s \in Unmarked :
            /\ comp' = CompOf(s)
            /\ workS' = CompOf(s)
            /\ cpc' = "condemn"
  /\ UNCHANGED heapVars /\ UNCHANGED <<frame, mpc>> /\ UNCHANGED dtorVars
  /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, msg, workE, bad>>

(* ------------------ collector: condemn & re-check ----------------- *)

CCondemn(s) ==
  /\ cpc = "condemn" /\ s \in workS
  /\ cb' = [cb EXCEPT ![s] = TRUE]
  /\ workS' = workS \ {s}
  /\ cpc' = IF workS = {s} THEN "await_ack" ELSE "condemn"
  /\ UNCHANGED <<occ, rcnt, eb, fld, frame, mpc>> /\ UNCHANGED dtorVars
  /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, comp, msg, workE, bad>>

MAck ==
  /\ cpc = "await_ack"
  /\ cpc' = IF ByteOnly THEN "recheck_byte" ELSE "recheck_cnt"
  /\ workS' = comp
  /\ workE' = IF ByteOnly THEN {}
              ELSE {p \in RecordedEdges : cedg[p[1]][p[2]] \in comp}
  /\ UNCHANGED heapVars /\ UNCHANGED <<frame, mpc>> /\ UNCHANGED dtorVars
  /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, comp, msg, bad>>

(* Acquittal is a message (2026-07-26, second audit): the collector   *)
(* touches nothing — the owning thread's next checkpoint clears the   *)
(* bytes and tears deferred deaths on its own thread (MAcquitDrain).  *)
Acquit == /\ UNCHANGED heapVars
          /\ cpc' = "wait_acquit" /\ msg' = comp
          /\ workS' = {} /\ workE' = {}
          /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, comp>>

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
  /\ UNCHANGED <<frame, mpc>> /\ UNCHANGED dtorVars /\ UNCHANGED bad

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
  /\ UNCHANGED <<frame, mpc>> /\ UNCHANGED dtorVars /\ UNCHANGED bad

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
  /\ UNCHANGED <<frame, mpc>> /\ UNCHANGED dtorVars /\ UNCHANGED bad

CFreeDirect(s) ==
  /\ cpc = "free_direct" /\ s \in workS
  /\ occ'  = [occ EXCEPT ![s] = "free"]
  /\ rcnt' = [rcnt EXCEPT ![s] = 0]
  /\ fld'  = [fld EXCEPT ![s] = [f \in Fields |-> NoRef]]
  /\ workS' = workS \ {s}
  /\ cpc' = IF workS = {s} THEN "flush" ELSE "free_direct"
  /\ UNCHANGED <<eb, cb, frame, mpc>> /\ UNCHANGED dtorVars
  /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, comp, msg, workE, bad>>

(* The mutator drains an acquittal message: clear the members' bytes, *)
(* tear members whose deaths were deferred — race-free on its thread. *)
MAcquitDrain ==
  /\ cpc = "wait_acquit" /\ msg # {}
  /\ ApplyRec(TearRec(msg, rcnt)) /\ UNCHANGED eb
  /\ msg' = {} /\ comp' = {} /\ cpc' = "flush"
  /\ UNCHANGED <<frame, mpc>> /\ UNCHANGED dtorVars
  /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, workS, workE, bad>>

(* --------------------- mutator: the Phase-4 drain ----------------- *)
(* Phased: exact test -> guard -> destructor steps -> guard-aware     *)
(* verify -> sever/free (or acquit).  While a drain phase is active   *)
(* the mutator's own script is blocked: the thread is inside the      *)
(* drain.  s1 is the one entity with a destructor body (DtorName).    *)

IndegK(K, m) == Cardinality({<<s, f>> \in K \X Fields : fld[s][f] = m})

MDrainStart ==
  /\ cpc = "wait_drain" /\ msg # {}
  /\ LET K == msg
         pass == \A m \in K : rcnt[m] = IndegK(K, m)
     IN IF ~pass
        THEN (* drop whole: bytes cleared, deferred deaths torn *)
             /\ ApplyRec(TearRec(K, rcnt)) /\ UNCHANGED eb
             /\ msg' = {} /\ comp' = {} /\ cpc' = "flush"
             /\ UNCHANGED dtorVars /\ UNCHANGED bad
        ELSE IF \E m \in K : occ[m] # "live"
        THEN /\ bad' = TRUE /\ UNCHANGED heapVars
             /\ msg' = {} /\ comp' = {} /\ cpc' = "flush"
             /\ UNCHANGED dtorVars
        ELSE (* guard every member: a real +1 on the count *)
             /\ rcnt' = [s \in Slots |-> IF s \in K THEN rcnt[s] + 1
                                                    ELSE rcnt[s]]
             /\ gcnt' = [s \in Slots |-> IF s \in K THEN 1 ELSE gcnt[s]]
             /\ cpc' = "drain_dtor"
             /\ UNCHANGED <<occ, eb, cb, fld>>
             /\ UNCHANGED <<msg, comp>> /\ UNCHANGED dran /\ UNCHANGED bad
  /\ UNCHANGED <<frame, mpc>>
  /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, workS, workE>>

(* One destructor step per member; only s1 has a body.  A resurrect   *)
(* stores the member into a free frame slot (a counted reference); an *)
(* alloc carves a slot into fr2.  Everything else is a no-op.         *)
MDtorRun(m) ==
  /\ cpc = "drain_dtor" /\ m \in msg /\ m \notin dran
  /\ dran' = dran \cup {m}
  /\ IF m = 1 /\ DtorName = "resurrect" /\ frame[2] = NoRef
     THEN /\ frame' = [frame EXCEPT ![2] = m]
          /\ rcnt' = [rcnt EXCEPT ![m] = @ + 1]
          /\ cb'   = [cb EXCEPT ![m] = FALSE]
          /\ UNCHANGED <<occ, eb, fld>>
     ELSE IF m = 1 /\ DtorName = "alloc" /\ frame[2] = NoRef
     THEN \E s \in Slots :
            /\ occ[s] \in {"virgin", "free"}
            /\ occ'  = [occ EXCEPT ![s] = "live"]
            /\ rcnt' = [rcnt EXCEPT ![s] = 1]
            /\ eb'   = [eb EXCEPT ![s] = "zero"]
            /\ cb'   = [cb EXCEPT ![s] = FALSE]
            /\ fld'  = [fld EXCEPT ![s] = [f \in Fields |-> NoRef]]
            /\ frame' = [frame EXCEPT ![2] = s]
     ELSE UNCHANGED heapVars /\ UNCHANGED frame
  /\ UNCHANGED mpc /\ UNCHANGED gcnt
  /\ UNCHANGED colVars /\ UNCHANGED bad

(* The pre-fix hazard (F8): the allocation above is a checkpoint      *)
(* inside the drain; a re-entrant allocator picks the in-progress     *)
(* message up again and re-runs the test.  The guards make every      *)
(* member mismatch, so the nested entry drops the message the outer   *)
(* drain is still working on — and the outer guards leak forever.     *)
MReenterDrain ==
  /\ ReentrantDrain /\ cpc = "drain_dtor" /\ msg # {}
  /\ DtorName = "alloc" /\ frame[2] # NoRef   \* the nested checkpoint
  /\ ApplyRec(TearRec(msg, rcnt)) /\ UNCHANGED eb
  /\ msg' = {} /\ comp' = {} /\ cpc' = "flush"
  /\ UNCHANGED <<frame, mpc>> /\ UNCHANGED dtorVars
  /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, workS, workE, bad>>

MDrainVerify ==
  /\ cpc = "drain_dtor" /\ msg # {} /\ msg \subseteq dran
  /\ LET K == msg
         pass == \A m \in K : rcnt[m] - gcnt[m] = IndegK(K, m)
         unguarded == [s \in Slots |-> rcnt[s] - gcnt[s]]
     IN IF ~pass \/ NoSever
        THEN (* acquit (or the no_sever bug): un-guard; on acquit the *)
             (* bytes clear and deferred deaths tear                  *)
             /\ IF NoSever /\ pass
                THEN /\ rcnt' = unguarded /\ UNCHANGED <<occ, fld, cb>>
                ELSE ApplyRec(TearRec(K, unguarded))
             /\ UNCHANGED eb
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
                 D == Grow(Grow(Grow(Grow({}))))
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
                /\ UNCHANGED eb
  /\ gcnt' = [s \in Slots |-> IF s \in msg THEN 0 ELSE gcnt[s]]
  /\ msg' = {} /\ comp' = {} /\ cpc' = "flush"
  /\ UNCHANGED <<frame, mpc>> /\ UNCHANGED dran
  /\ UNCHANGED <<snap, wtodo, wfld, crc, cedg, workS, workE, bad>>

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
  /\ UNCHANGED <<rcnt, cb, fld, frame, mpc>> /\ UNCHANGED dtorVars
  /\ UNCHANGED bad

(* ----------------------------- spec ------------------------------- *)

Next ==
  \/ MutFree \/ MutScript
  \/ CTrigger \/ CDiff \/ CFlush \/ MAck
  \/ MDrainStart \/ MDrainVerify \/ MReenterDrain \/ MAcquitDrain
  \/ \E s \in Slots : CWalkClassify(s) \/ CCondemn(s) \/ MDtorRun(s)
                      \/ CRecheckCnt(s) \/ CRecheckByte(s) \/ CFreeDirect(s)
  \/ \E s \in Slots, f \in Fields : CWalkField(s, f)
  \/ \E p \in Slots \X Fields : CRecheckEdge(p)

InitCol ==
  /\ cpc = "idle" /\ snap = {} /\ wtodo = {} /\ wfld = {}
  /\ crc = [s \in Slots |-> Absent]
  /\ cedg = [s \in Slots |-> [f \in Fields |-> NotRead]]
  /\ comp = {} /\ msg = {} /\ workS = {} /\ workE = {}
  /\ bad = FALSE /\ mpc = 1
  /\ gcnt = [s \in Slots |-> 0] /\ dran = {}

CycleChildFld ==
  [s \in Slots |->
     IF s = 1 THEN [f \in Fields |-> IF f = 1 THEN 2 ELSE 3]
     ELSE IF s = 2 THEN [f \in Fields |-> IF f = 1 THEN 1 ELSE NoRef]
     ELSE [f \in Fields |-> NoRef]]

InitMigration ==
  /\ occ = [s \in Slots |-> IF s = 4 THEN "virgin" ELSE "live"]
  /\ fld = CycleChildFld
  /\ frame = [fr \in Frames |-> IF fr = 1 THEN 1 ELSE NoRef]
  /\ rcnt = [s \in Slots |-> IF s = 4 THEN 0 ELSE IF s = 1 THEN 2 ELSE 1]
  /\ eb = [s \in Slots |-> IF s = 4 THEN "zero" ELSE "old"]
  /\ cb = [s \in Slots |-> FALSE]

InitGarbage ==
  /\ occ = [s \in Slots |-> IF s = 4 THEN "virgin" ELSE "live"]
  /\ fld = CycleChildFld
  /\ frame = [fr \in Frames |-> NoRef]
  /\ rcnt = [s \in Slots |-> IF s = 4 THEN 0 ELSE 1]
  /\ eb = [s \in Slots |-> IF s = 4 THEN "zero" ELSE "old"]
  /\ cb = [s \in Slots |-> FALSE]

InitHeldChild ==
  /\ occ = [s \in Slots |-> IF s = 4 THEN "virgin" ELSE "live"]
  /\ fld = [s \in Slots |->
              IF s = 1 THEN [f \in Fields |-> IF f = 1 THEN 2 ELSE NoRef]
              ELSE IF s = 2 THEN [f \in Fields |-> IF f = 1 THEN 1 ELSE 3]
              ELSE [f \in Fields |-> NoRef]]
  /\ frame = [fr \in Frames |-> IF fr = 1 THEN 3 ELSE NoRef]
  /\ rcnt = [s \in Slots |-> IF s = 4 THEN 0 ELSE IF s = 3 THEN 2 ELSE 1]
  /\ eb = [s \in Slots |-> IF s = 4 THEN "zero" ELSE "old"]
  /\ cb = [s \in Slots |-> FALSE]

InitGarland ==
  /\ occ = [s \in Slots |-> IF s = 4 THEN "virgin" ELSE "live"]
  /\ fld = [s \in Slots |->
              IF s = 1 THEN [f \in Fields |-> IF f = 1 THEN 2 ELSE NoRef]
              ELSE IF s = 2 THEN [f \in Fields |-> IF f = 1 THEN 1 ELSE 3]
              ELSE IF s = 3 THEN [f \in Fields |-> IF f = 1 THEN 3 ELSE NoRef]
              ELSE [f \in Fields |-> NoRef]]
  /\ frame = [fr \in Frames |-> NoRef]
  /\ rcnt = [s \in Slots |-> IF s = 4 THEN 0 ELSE IF s = 3 THEN 2 ELSE 1]
  /\ eb = [s \in Slots |-> IF s = 4 THEN "zero" ELSE "old"]
  /\ cb = [s \in Slots |-> FALSE]

InitPair ==
  /\ occ = [s \in Slots |-> IF s \in {3, 4} THEN "virgin" ELSE "live"]
  /\ fld = [s \in Slots |->
              IF s = 1 THEN [f \in Fields |-> IF f = 1 THEN 2 ELSE NoRef]
              ELSE IF s = 2 THEN [f \in Fields |-> IF f = 1 THEN 1 ELSE NoRef]
              ELSE [f \in Fields |-> NoRef]]
  /\ frame = [fr \in Frames |-> IF fr = 1 THEN 1 ELSE NoRef]
  /\ rcnt = [s \in Slots |-> IF s = 1 THEN 2 ELSE IF s = 2 THEN 1 ELSE 0]
  /\ eb = [s \in Slots |-> IF s \in {3, 4} THEN "zero" ELSE "old"]
  /\ cb = [s \in Slots |-> FALSE]

(* pair2: garbage cycle s1<->s2, s3 virgin, frame empty — the shape   *)
(* for destructor scenarios: the cycle drains, s1's destructor acts   *)
InitPair2 ==
  /\ occ = [s \in Slots |-> IF s \in {3, 4} THEN "virgin" ELSE "live"]
  /\ fld = [s \in Slots |->
              IF s = 1 THEN [f \in Fields |-> IF f = 1 THEN 2 ELSE NoRef]
              ELSE IF s = 2 THEN [f \in Fields |-> IF f = 1 THEN 1 ELSE NoRef]
              ELSE [f \in Fields |-> NoRef]]
  /\ frame = [fr \in Frames |-> NoRef]
  /\ rcnt = [s \in Slots |-> IF s \in {3, 4} THEN 0 ELSE 1]
  /\ eb = [s \in Slots |-> IF s \in {3, 4} THEN "zero" ELSE "old"]
  /\ cb = [s \in Slots |-> FALSE]

(* secondhome: live ring s1<->s2 held by s4 (s4.f1 = s1), child      *)
(* s1.f2 = s3, fr1 holds s4 — the 4-entity near-false-post shape the  *)
(* second audit named; F = 3 gives the borrow chain room              *)
InitSecondHome ==
  /\ occ = [s \in Slots |-> "live"]
  /\ fld = [s \in Slots |->
              IF s = 1 THEN [f \in Fields |-> IF f = 1 THEN 2 ELSE 3]
              ELSE IF s = 2 THEN [f \in Fields |-> IF f = 1 THEN 1 ELSE NoRef]
              ELSE IF s = 4 THEN [f \in Fields |-> IF f = 1 THEN 1 ELSE NoRef]
              ELSE [f \in Fields |-> NoRef]]
  /\ frame = [fr \in Frames |-> IF fr = 1 THEN 4 ELSE NoRef]
  /\ rcnt = [s \in Slots |-> IF s = 1 THEN 2 ELSE 1]
  /\ eb = [s \in Slots |-> "old"] /\ cb = [s \in Slots |-> FALSE]

Init == /\ CASE InitShape = "migration" -> InitMigration
             [] InitShape = "garbage"   -> InitGarbage
             [] InitShape = "garland"   -> InitGarland
             [] InitShape = "pair"      -> InitPair
             [] InitShape = "pair2"     -> InitPair2
             [] InitShape = "secondhome" -> InitSecondHome
             [] OTHER                   -> InitHeldChild
        /\ InitCol

Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Next)

(* -------------------------- properties ---------------------------- *)

TypeOK ==
  /\ occ \in [Slots -> {"virgin", "live", "free", "parked"}]
  /\ rcnt \in [Slots -> 0..12]
  /\ eb \in [Slots -> {"zero", "cur", "old"}]
  /\ cb \in [Slots -> BOOLEAN]
  /\ fld \in [Slots -> [Fields -> Slots \cup {NoRef}]]
  /\ frame \in [Frames -> Slots \cup {NoRef}]
  /\ gcnt \in [Slots -> 0..2] /\ dran \subseteq Slots

SafeHeap == \A s \in Reach : occ[s] = "live"

NotBad == bad = FALSE

(* I1 with the Phase 4 guard as its own term, per the model. *)
I1Honest == \A s \in Slots :
              occ[s] = "live" => rcnt[s] = TrueRC(s) + gcnt[s]

I2NoDangling == \A s \in Slots, f \in Fields :
                  fld[s][f] # NoRef => occ[fld[s][f]] = "live"

(* The filter never posts a live entity.  Scoped to the queue-waiting *)
(* phase: during drain_dtor a destructor may legally resurrect a      *)
(* member (that is what the re-verify exists for), so reachability of *)
(* an in-drain member is not a filter failure.                        *)
PostClean == cpc = "wait_drain" => msg \cap Reach = {}

(* I4, the checkable half: a virgin slot has never been stamped.      *)
I4Virgin == \A s \in Slots : occ[s] = "virgin" => eb[s] = "zero"

(* Destructors run at most once per incarnation: a drained member is  *)
(* in dran before anything of it is freed — checked structurally by   *)
(* MDtorRun's guard; no separate invariant needed.                    *)

EventuallyCollected == <>(\A s \in Slots : occ[s] \in {"free", "virgin"}
                                           \/ s \in Reach)
=======================================================================
