# The shape of HIR

Status: draft, step S10.1. Sections 1 and 2 are written; the rest of the step —
what HIR drops, names, types, slots, spans, two worked functions and the open
questions — is not yet here.

## 1. What HIR is

HIR is the representation every Limelight frontend produces and every backend
consumes. It is a typed tree, built after names are resolved, and it holds the
logical semantics of Efen whole: what it drops is notation, never meaning.

**A tree, not a graph.** Nesting follows the structure of the language, so `if`,
`switch`, loops, `try`, `guard`, `defer`, `with` and `using` are nodes and no
basic block appears. The control-flow graph belongs to the level below.

**Typed.** Every expression carries its type. Monomorphisation runs on HIR
rather than ahead of it, so a generic body reaches HIR with its type parameters
and its constraints intact. A type inside such a body is symbolic; whether it is
ever substituted depends on which of Efen's two generic strategies the compiler
picks for that instantiation, and that question is held over (step S10.4).

**Post-resolution.** A name in HIR is a key into the symbol database rather than
a string, and a package and a module are parts of that key. Moving a function to
another file therefore does not change its HIR.

**Neutral to representation.** HIR says what happens and never how it is laid
out. The physical placement of objects and structs, the layout of a union, the
dispatch a class uses and the machinery of copy-on-write are all chosen below
it — Efen makes that a rule of the language, not a liberty of the compiler.

**Reached by user code.** Compile-time code reads HIR through the compile-time
API and writes it through the builders there, and an `InlineClosure` is a
fragment of HIR held as a value: it can be a parameter, be called, and be
spliced into another fragment. HIR is a structure the language exposes, not a
private stage of a pipeline.

**Written against Efen.** Efen is the reference language. PHP lowers onto the
same nodes as the poorer case and contributes none of its own: where a PHP
feature has no home, the gap is in Efen and is reported there.

## 2. What HIR is not

**Not a control-flow graph in SSA.** That form belongs to the level below, where
MLIR already provides regions, structured operations and lowering by stages. A
graph here would destroy the structure that the compile-time API reads back:
`getOwnMethods`, `hasGetter` and `getContracts` answer from a tree of
declarations, and basic blocks answer nothing.

**Not a lowered form.** A class in Efen may compile to a struct with a vtable or
to a key-value map with static dispatch, and the choice belongs to the aspect
applied to it. One HIR has to serve both, so it carries no offset, no vtable
index and no allocation.

**Not a union of several languages.** A vocabulary assembled from every language
at once becomes the union of all of them or the intersection of none. The nodes
come from Efen; PHP is checked against the result afterwards, and a second
frontend is checked the same way.

**Not an erased form.** A contract vanishing from the binary is not a contract
vanishing from HIR. Contracts, typestate, refinement types, ownership aspects
and effects are meaning, so they reach HIR and lowering erases them. The erasure
line runs between HIR and lowering, never between the frontend and HIR.

**Not private to the compiler.** Metafunctions produce HIR fragments and the
compile-time API rewrites declarations, so the shape of HIR is part of what the
language promises its users. Changing it changes the language.
