# The shape of HIR

Status: draft, step S10.1. Sections 1, 2, 4, 5, 6 and 7 are written. Section 3
waits on a discussion Edmond has held over, and section 9 lists what is open.

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

## 3. What HIR drops

Held over. Only notation is dropped, and the test for a single form is one
question: another way of writing the same abstraction, or a different
abstraction. Applying that test to the candidates — the two parameter syntaxes,
the paren-less statement call, the `|>` pipeline, PHP's `elseif` chain — is a
discussion Edmond has reserved, because the answers are not obvious: `|>` fixes
an evaluation order as well as naming a call, and the PHP forms belong to the
poorer language and settle nothing about Efen.

Two results of that test are already fixed, in opposite directions. `guard` does
not collapse into `if` with a negation, because its binding scopes over the rest
of the function. An argument written with its parameter's name does not collapse
into a position, because binding an argument to a parameter is meaning while the
order of writing is notation.

## 4. Names

A name in HIR is a key into the symbol database, never a string. The full name
of an abstraction is `Package::Module::Abstraction`, so a package and a module
are parts of that key; a namespace is not a node, and a module appears as a
declaration only because it owns a scope.

Resolution therefore happens in the frontend, ahead of HIR, and HIR stops
depending on where the source sits: moving a function to another file leaves its
HIR unchanged. A reference to something outside the function is a key, together
with type arguments when the target is generic.

Nesting and embedding make the key a path rather than a flat name. A struct
declared inside another and a struct that embeds another both resolve through
that path — `entity.x` reaching a field of an embedded `Position` names
`Position::x` through the embedding, not an offset, because an offset is a
matter of layout and layout is chosen below.

**A module's context is a record, not a traversal.** A function compiles on its
own, so everything it needs is reachable through keys without processing its
container. What the container contributes — its imports, the strategies it
enables with `use`, and the static effect bindings of `with { Logger: FileLogger }`
— is one record in the symbol database. Strategy selection depends on that
record rather than on the receiver's type, which is why the same call resolves
to `JSONPersistence` in one module and to `XMLPersistence` in another; the
frontend resolves it and the node carries the resolved target. Every function in
the module depends on that record, so editing it invalidates all of them at
once.

## 5. Types

Every expression carries its type, and types form their own tree that nodes
refer to. Type parameters and their constraints reach HIR, because
monomorphisation runs on HIR rather than ahead of it. Variance is a property of
the parameter's declaration and travels with it: `out T` may appear only in
results, `in T` only in inputs, and the default is invariant.

References are three kinds and they belong to the type: `&T` reads, `&mut T`
reads and writes, `&out T` only writes. (`types/ownership.md` still describes an
older pair, `&T` bidirectional and `&T?` out; the audit of 2026-09-03 replaced
it, and that document has not caught up.)

A contract is a type-level entity, so it reaches HIR and lowering erases it. A
contract standing in a result position does not erase so simply: either the
concrete type is known statically or the value is boxed into a runtime
container, and the name and syntax of that container are undecided in Efen
itself.

**Held over (step S10.4).** Efen has two generic strategies, monomorphisation
and erasure, and the compiler chooses between them unless the programmer demands
one. A type inside a generic body is therefore symbolic, and whether it is ever
substituted depends on a choice made after HIR exists. Until that discussion
happens, nothing here may assume a type in HIR is concrete.

## 6. Slots and ownership

Ownership in Efen is a set of capabilities rather than a single flag: `own` to
destruct, `read`, `write`, `shared` for parallel access, `split` for
sub-ownership, `inspect` to see identity without data, with `mut` standing for
`write` without `shared`. A seventh mode, `managed`, gives the resource to a
container and stops checking transfer, tying the lifetime to the owner.

The capabilities do not attach to a name. The compiler represents a resource as
a **slot** that belongs to a scope and carries the aspects the resource holds
right now, and a name refers to a slot: `let b = a` makes a second reference to
one slot rather than a second slot. Passing that slot by `own` empties it, which
is why a second such pass is a compile error rather than a runtime fault.

HIR therefore distinguishes a name from the slot it denotes, and carries the
aspects on the slot. Both are meaning rather than notation, so both reach HIR
and lowering erases them once it has proved what it needs.

## 7. Spans

Every declaration and every node a diagnostic can name carries the span of the
source it came from. This is a contract rather than a convenience: the
compile-time API exposes `getSourceLocation()` on a class, a method and a
property, so user code compiled today may ask for it.

Passes over HIR need the same thing for their own reasons. Monomorphisation
fails when a constraint is not satisfied, an aspect refuses a class that lacks a
required member, and a metafunction reports an error from inside a fragment it
generated. None of them has anywhere to point without a span, and the fragment
case is the hard one: a span has to survive being spliced from one `InlineClosure`
into another.

## 8. Two functions written out

The notation below is for reading. It is not a syntax anyone types and not a
serialisation format; the normative form of HIR is the data structure in
`amber`, and this rendering exists so a person can check the shape by eye.
`s1`, `s2` name slots (section 6), and the bracketed words after a slot are the
ownership aspects it holds at that point.

### Efen

```efen
fn readFile(path: String?) {
    guard let path = path else { return }
    let file = File.open(path)
    defer { file.close() }
    process(file)
}
```

```
fn App::Files::readFile
  param  path : String?                  -> s1  [read]
  result void
  body block
    guard
      bind    path = unwrap ref s1       -> s2  [read]   scope: rest of block
      else    block
                return
    bind file = call                     -> s3  [own read write]
           target   Std::Io::File::open
           arg      path = ref s2
    defer
      block
        call
          target   Std::Io::File::close
          receiver ref s3
    call
      target App::Files::process
      arg    file = ref s3
```

Three things to read off it. `guard` and `defer` are nodes and neither is
rewritten into anything else: the binding made by `guard` states the scope it
governs, and `defer` states nothing about where it will run, because deciding
that is lowering's work. Every target is a key, so the tree says which `close`
it means without knowing where that source file is. And the slot, not the name,
carries the aspects: `path` is read-only, the handle `file` is owned.

### PHP

```php
function greet(string $name): string {
    if ($name === '') {
        return 'Hello, guest';
    }
    return 'Hello, ' . $name;
}
```

```
fn App::Greeting::greet
  param  name : String                   -> s1  [read]
  result String
  body block
    if
      condition call
                  target Php::Op::identical
                  arg    left  = ref s1
                  arg    right = literal ""
      then block
             return literal "Hello, guest"
    return call
             target Php::Op::concat
             arg    left  = literal "Hello, "
             arg    right = ref s1
```

The pair makes the rule of section 1 concrete. PHP contributes no node: `===`
and `.` are calls, and what makes them PHP is the target they name, not the
shape of the tree. PHP's peculiarities arrive in HIR as **symbols**, resolved
against a library that implements them, and a peculiarity with no symbol to
resolve to is a gap in Efen rather than a missing node here.

## 9. What is open

Each line names the question and where it is settled. A question with no owner
is a question nobody answers, so none is left without one.

**Held over by Edmond, not to be reopened unasked.**

- Which surface forms are only notation, and therefore which of the candidates
  in section 3 collapse.
- What a type means inside a generic body, and which of Efen's two generic
  strategies applies to an instantiation. Step S10.4 cannot close before this.

**Owned by step S10.6, the operation set.**

- Whether HIR records that a member came from an aspect. An aspect adds methods,
  properties, contracts and interfaces, so the class HIR describes is the
  expanded one; whether the origin of a member is meaning or bookkeeping is
  exactly the question "the whole logical semantics" raises.
- Whether the receiver arrives as a context. `memory/classes-internal.md` writes
  a method as `fn init(x, y) -> Self in Self`, the same `in` that carries an
  effect, but no normative document says so.

**Owned by `amber`, and recorded in its `dev/DECISIONS.md`.**

- Whether HIR is persisted between runs or rebuilt for each compilation.
- Whether a language may contribute passes of its own.
- Where the line falls between a pass over HIR and a pass over MLIR.

**Holes in Efen itself, to be closed there and not worked around here.**

- A contract standing in a result position needs a runtime container, and its
  name and syntax are undecided.
- `CodeBlock.parse(code: String)` in the compile-time API is raw code injection,
  which `compile-time/metafunctions.md` forbids outright. One of the two has to
  give way.
- `enum Visibility` offers `Public, Private, Protected, Internal` while
  `functions.md` names `public, internal, private, api`. The symbol record needs
  one list, and `private` there is file-scoped.
- `types/ownership.md` still describes `&T` as bidirectional and `&T?` as out,
  which the audit of 2026-09-03 replaced.
