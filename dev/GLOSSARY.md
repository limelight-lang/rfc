# RFC terminology

> **Status: draft for `dev/PLAN.md` S9.1.** The canonical table is normative
> for new text; the deprecated and context-sensitive sections are migration
> input. S9.1 closes only after the active RFC set has been checked against it.

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

## Canonical terms

Only this table defines terms that new normative text may use without a local
definition.

| Term | Meaning in Limelight |
|---|---|
| actor | Serial execution context with isolated mutable state and a mailbox |
| arena | Region whose allocations normally share a bulk lifetime |
| cycle candidate | Header-bearing entity registered after a non-final decrement because it may belong to a reference cycle |
| candidate age | Saturating age assigned to a retained candidate component at exact-validation commit: the minimum current member age plus one, scoped by a separate epoch stamp |
| acyclic-class filter | Static proof that instances of a class cannot participate in a reference cycle |
| consistent point | Point between mutator operations at which slots and reference counts agree; not a stop-the-world safepoint |
| trace scratch arena | Per-trace bump arena containing temporary rows, initialization bitmaps, and worklist segments |
| candidate component | Candidate subgraph tested as one unit |
| collector worker | Optional thread that performs speculative tracing and sends a validation batch to the owning mutator |
| critical reserve | Per-mutator memory withheld from ordinary allocation for bounded operations that must remain possible after allocation failure |
| candidate registration | Edge-triggered insertion of an entity into the candidate pipeline after a non-final decrement |
| candidate bit | Header bit that prevents duplicate candidate registration while the candidate pipeline retains the entity's identity |
| entity | Managed allocation beginning with a Limelight entity header |
| overflow buffer | Bounded, lifetime-funded storage that retains mandatory candidate registrations when no queue segment can be acquired |
| exact validation | Owner-thread check that current member reference counts are fully explained by component-internal edges and guard references |
| guard reference | Temporary `+1` strong reference that prevents recursive zero-count teardown during cycle finalization |
| synchronous collection | Collection performed by the owning mutator |
| live | Reachable through an external counted reference, or conservatively treated as such |
| mutator | Thread executing application code and changing the object graph |
| traversal age threshold | Candidate age at which a non-root trace target is treated as opaque and live for the current epoch |
| deferred slot reuse | Delay between teardown and allocator reuse while a queue entry or trace can still identify the old occupant |
| validation batch | Components proposed by a speculative trace for owner-thread exact validation |
| shadow count | Trace-local working copy of an entity's reference count, with explicitly defined saturation behavior |
| deferred-candidate buffer | Per-mutator buffer that delays reconsideration of candidates retained by exact validation |
| cycle finalization | Ordered guard, weak-reference invalidation, user destructor invocation, revalidation, severing, and reclamation of a validated unreachable component |
| trace | Trial-deletion traversal over cycle candidates using shadow counts; qualify it at first use |
| trace token | Per-mutator synchronization word that serializes traces over that mutator's blocks and candidate state |
| validation result | Result of exact validation, distinct from a speculative trace proposal |
| ValueBox | Limelight's 16-byte tagged dynamic value representation |
| zero-count transition | Reference-count change that reaches zero and triggers teardown |
| user destructor | PHP `__destruct` method |
| field/resource teardown | Runtime release of an entity's owned fields and internal resources |
| weak-reference invalidation | Nulling weak references before storage can be reclaimed |
| storage reclamation | Return of storage to its allocator or operating system |
| row-initialization bitmap | Bitmap recording which groups of shadow rows have been initialized in the current trace |
| candidate queue | Queue of decrement-triggered cycle candidates; not a set of stack or global tracing roots |
| headerless FFI value | Unmanaged foreign-layout value with no Limelight entity header; its exact ABI layout is specified separately |
| collision-defense state | Hash-table state selecting ordinary indexing, salted rebuild, keyed-hash escalation, or terminal admission denial |
| admission denial | Non-memory failure to admit a new hash-table key after collision defenses are exhausted |

## Deprecated terms

These terms are recorded so existing text can be migrated. Their presence in
this table does not approve them for new normative prose.

| Deprecated term | Replacement |
|---|---|
| accelerator | collector worker |
| class filter | acyclic-class filter |
| clean point | consistent point |
| collection arena | trace scratch arena |
| corpse | zero-count entity pending reclamation, or the exact lifecycle state |
| critical door | reserve allocation path |
| dirty pass / dirty reader | speculative trace / collector worker, according to subject |
| enrolment / enrolment bit | candidate registration / candidate bit |
| escrow | overflow buffer |
| exact judgement / exact test | exact validation |
| in-line collection | synchronous collection |
| judge / judgement | validate / validation |
| law | ownership invariant |
| mature candidate | candidate at the traversal age threshold |
| ordinary door | ordinary allocation path |
| park a slot | defer slot reuse |
| parked actor / fiber | blocked or suspended actor/fiber, according to scheduler state |
| promote bound | traversal age threshold |
| acquit | retain after exact validation / classify as externally referenced |
| condemn | validate as unreachable / select for reclamation |
| ring, when it means a graph | reference cycle |
| shortlist | validation batch |
| suspects buffer | deferred-candidate buffer |
| trace claim | trace-token ownership |
| verdict | validation result |
| death / destructor, when unqualified | zero-count transition, user destructor, field/resource teardown, weak-reference invalidation, or storage reclamation |
| met bit / bitmap | row-initialization bitmap |
| root queue | candidate queue |
| pure destructor | named destructor effect class; reserve *pure* for no observable side effects |
| zero-abstraction type/entity | headerless FFI value; specify C layout or ABI compatibility separately |

## Context-sensitive words

- *door* becomes *allocation path*, *entry point*, *mailbox*, *channel*, or
  *store-barrier form*, according to the operation.
- *refusal* becomes *rejected design*, *allocation failure*, *admission
  denial*, *unsupported placement*, or *capacity limit*.
- *floor* remains valid for a mathematical lower bound. Provisioned memory is
  *baseline capacity*, an *initial segment*, a *queue base block*, or an exact
  byte count.
- *owner* must be qualified in cross-module contracts: *containing entity*,
  *owning mutator*, *block owner*, *lifetime anchor*, or *unique-ownership
  proof*.
- *dispose* and *drop* may remain ABI or source identifiers. Prose names the
  operation they perform: usually *user destructor invocation*, *field/resource
  teardown*, or *storage reclamation*.
- *teardown* must be qualified where more than one lifecycle protocol is in
  scope: *ordinary object teardown*, *field/resource teardown*, *thread-exit
  teardown*, or *cycle finalization*. It never means storage reclamation alone.
- *scalar* names a PHP scalar type only where that type set is intended.
  Representation text uses *immediate value*, *non-pointer value*, or the exact
  primitive type.
- *native* becomes *machine code*, *standard PHP*, *machine stack*, or
  *foreign code*, according to context.
- *flood ladder*, *rung*, and *trigger* become *collision-defense state*, the
  exact threshold (*chain-length threshold* or *equal-hash threshold*), the
  selected rebuild, or *admission denial*.
- *claim* remains ordinary English for an assertion. Synchronization uses
  *acquire the trace token* or *trace-token ownership*.

## Spelling and style

The RFC uses US English: *behavior*, *materialization*, *serialize*, and
*judgment*. Names copied from an external API retain that API's spelling.
Sentences should state the rule first and its history or evidence second.
Decision dates belong in a short rationale paragraph, not in the normative
sentence itself.
