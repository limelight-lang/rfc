# RFC terminology

This glossary defines the vocabulary used by the normative RFCs. Its purpose is
to keep implementation terms precise and to prevent a local metaphor from
acquiring several incompatible meanings. Ordinary English uses of a word are
not terms and are outside this glossary.

## Writing rules

1. Prefer the established term from compiler, allocator, garbage-collector, or
   concurrency literature.
2. Name an operation by its observable result. For example, an allocation
   *fails* or *returns null*; an alternative is *rejected*; a queue entry is
   *retained* or *removed*.
3. Use one term for one concept. In particular, do not use legal, architectural,
   or physical metaphors for GC states.
4. Introduce a project-specific term only when the design has no established
   equivalent. Define it at first use and add it here.
5. RFC requirements use **must**, **must not**, **should**, and **may** in their
   usual normative senses. Historical decisions use the past tense instead.

## Terms to use

| Term | Meaning in Limelight | Established equivalent | Verdict |
|---|---|---|---|
| accelerator | Optional collector thread that performs a speculative trace and sends results to the owning mutator | concurrent collector worker | Rename to **collector worker** |
| actor | Serial execution context with isolated mutable state and a mailbox | actor | Keep |
| arena | Region whose allocations normally share a bulk lifetime | region / arena | Keep |
| candidate | Entity enrolled after a non-final decrement because it may belong to a reference cycle | cycle candidate | Keep; use **cycle candidate** at first mention |
| candidate age | Number of collection epochs used by the traversal-pruning policy | age stamp | Keep; replaces *maturation age* |
| class filter | Static analysis that proves instances of a class cannot participate in a reference cycle | acyclic-type filter | Rename to **acyclic-class filter** |
| clean point | Point between mutator operations at which slots and reference counts agree | consistent state / quiescent point | Rename to **consistent point**; do not imply a stop-the-world safepoint |
| collection arena | Bump arena containing one trace's temporary rows, bitmaps, and worklist | tracing scratch arena | Rename to **trace scratch arena** |
| component | Candidate subgraph tested as a unit | candidate component | Keep |
| corpse | Entity whose reference count reached zero while a queue or trace still retains its slot identity | zero-count entity pending reclamation | Rename; name the exact lifecycle state |
| critical door | Allocation that may consume the protected per-thread reserve | reserve allocation path | Rename |
| critical reserve | Memory withheld from ordinary allocations for bounded operations that must remain possible after allocation failure | emergency / failure reserve | Keep; it is defined by the RFC |
| dirty pass / dirty reader | Off-thread traversal that may observe mutually inconsistent counts and edges | concurrent speculative trace | Rename to **speculative trace** / **collector worker** as appropriate |
| door | An allocation path, API entry point, communication channel, or barrier operation, depending on the document | none; the metaphor is ambiguous | Rename according to the actual concept |
| enrolment | Edge-triggered insertion of an entity into the cycle-candidate queue | candidate registration | Rename to **candidate registration** |
| enrolment bit | Header bit that prevents duplicate candidate registration | buffered / candidate bit | Rename to **candidate bit** |
| entity | Runtime allocation with a Limelight entity header and managed lifetime | heap object | Keep as a project-specific umbrella term; define at first use |
| escrow | Last-resort queue segment used when the normal queue and reserve allocation cannot accept a mandatory candidate | overflow buffer | Rename to **overflow buffer** |
| exact judgement / exact test | Owner-thread validation that current external reference count is zero for every member of a candidate component | validation / trial-deletion validation | Rename to **exact validation** |
| floor | Mandatory initial capacity or a conservative lower bound, depending on context | baseline capacity / lower bound | Rename according to the actual concept; retain only the mathematical use |
| guard | Temporary `+1` reference applied before cycle finalization so recursive release cannot start ordinary destruction | temporary strong reference / guard reference | Keep as **guard reference** |
| in-line collection | Collection performed synchronously by the owning mutator | mutator-assisted / synchronous collection | Rename to **synchronous collection** |
| judge / judgement | Decide whether a candidate component is currently unreachable | validate / validation | Rename |
| law | Required owner-only state transition rule | ownership invariant | Rename |
| live | Reachable through an external counted reference, or conservatively treated as such | live | Keep |
| mature candidate | Candidate whose age reaches the traversal-pruning threshold | candidate at the traversal age threshold | Rename; avoid generational-GC *mature* and *promotion* |
| mutator | Thread executing application code and changing the object graph | mutator | Keep |
| ordinary door | Allocation that cannot consume the critical reserve | ordinary allocation path | Rename |
| park a slot | Delay slot reuse while a queue entry or trace can still identify the old occupant | defer slot reuse | Rename |
| parked actor / fiber | Actor or fiber not currently runnable while it waits | blocked / suspended actor or fiber | Rename according to scheduler state |
| promote bound | Candidate age at which traversal treats a non-root target as opaque and live | traversal age threshold | Rename |
| acquit | Exact validation finds an external reference, so the component is not collectable in this run | retain / classify as live | Rename |
| condemn | Exact validation confirms a component is unreachable | confirm as unreachable / select for reclamation | Rename |
| refusal | Rejected design, failed allocation, denied insertion, or capacity result | none; four concepts were conflated | Rename contextually to **rejection**, **allocation failure**, **denial**, or **capacity limit** |
| ring | Strong-reference cycle | reference cycle | Rename except in compact examples after the term has been established |
| shortlist | Components proposed by a speculative trace for owner validation | validation batch | Rename to **validation batch** |
| shadow count | Trace-local working copy of an entity's reference count | trial reference count | Keep; define storage and saturation behavior |
| suspects buffer | Per-thread list that delays reconsideration of candidates rejected by exact validation | deferred-candidate buffer | Rename |
| teardown | Ordered destruction and reclamation of an unreachable component | cycle finalization / reclamation | Keep for the complete ordered procedure; use **reclamation** for memory return alone |
| trace | Trial-deletion traversal over cycle candidates using shadow counts | trial-deletion trace | Keep; qualify at first use |
| trace claim | Ownership of one mutator thread's trace state | trace-token ownership | Rename |
| trace token | Per-mutator synchronization word that serializes traces over that mutator's blocks and queues | per-owner trace lock/token | Keep; the non-blocking acquisition protocol is project-specific |
| verdict | Result of exact validation | validation result | Rename |
| ValueBox | Limelight's 16-byte tagged dynamic value representation | tagged value | Keep as a project-specific type name |
| death / destructor | Previously used for count zero, `__destruct`, field teardown, weak invalidation, and storage return | lifecycle phases | Rename each occurrence to **zero-count teardown**, **user destructor**, **field teardown**, **weak-reference invalidation**, or **storage reclamation** |
| met bit / bitmap | Records whether a trace initialized the shadow row or group | visited bit / bitmap | Rename |
| root queue | Queue of decrement-triggered cycle candidates, not a set of stack or global tracing roots | possible-root buffer / candidate queue | Rename to **candidate queue** |
| scalar | Sometimes used for integers, floats, booleans, nullable pointers, or all PHP scalar types | immediate / non-pointer value | Rename according to representation; PHP strings are scalar types too |
| pure destructor | Destructor classified by which teardown effects may be deferred; some classes still write fields | destructor effect class | Rename the ladder; reserve **pure** for code with no observable side effects |
| zero-abstraction type | Headerless FFI value whose runtime layout matches its foreign representation | layout-transparent FFI type | Rename |
| native | Used for machine code, standard PHP syntax, the machine stack, and FFI code | none; overloaded | Use **machine code**, **standard PHP**, **machine stack**, or **foreign code** |

## Context-sensitive replacements

Several old words cannot be replaced mechanically:

- *refused design* becomes *rejected design*; *allocation refused* becomes
  *allocation failed* or *returned null*; *operation refused* names its actual
  error result.
- *door* becomes *allocation path*, *entry point*, *mailbox*, *channel*, or
  *store-barrier form*, depending on what is being described.
- *floor* remains valid for a mathematical lower bound. For provisioned memory,
  use *baseline capacity*, *initial segment*, or the exact byte count.
- *claim* remains ordinary English when it means an assertion in prose. For
  synchronization, use *acquire the trace token* or *trace-token ownership*.

## Spelling and style

The RFC uses US English: *behavior*, *materialization*, *serialize*, and
*judgment*. Names copied from an external API retain that API's spelling.
Sentences should state the rule first and its history or evidence second.
Decision dates belong in a short rationale paragraph, not in the normative
sentence itself.
