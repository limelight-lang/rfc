# The erasure line

Status: draft, step S10.2. The rows below cover the documents read so far; the
list at the end names what has not been read, so the gap is visible rather than
guessed at.

Two rows come from documents that carry the banner "проект спецификации":
typestate and code regions have no grammar and no compiler check yet, so their
rows describe an intent rather than a mechanism. `types/typestate.md` also says
transitions on an exception are out of scope for the first version, while the
audit of 2026-09-03 already proposes a syntax for them (`throws IOError >>
Closed`); the two have not been reconciled.

The line runs **between HIR and lowering**, not between the frontend and HIR.
HIR keeps the logical semantics of Efen whole, so an abstraction that disappears
from the binary does not disappear from HIR. Each row therefore says two things:
how HIR holds the abstraction, and what lowering does with it.

## Rows

| Abstraction | In HIR | Below HIR |
|---|---|---|
| Contract | A type-level entity: a constraint on a type parameter, a `conforms` on a class or an interface, and a function signature, which `functions.md` calls a contract too | Erased. A contract in a result position does not erase alone: either the concrete type is static or the value is boxed, and that container is undecided in Efen |
| Interface | A declaration, and a dispatch target: a call whose receiver has an interface as its static type names an interface method | A vtable and an indirect call |
| Class | A declaration with four separate lists — base class, interfaces, contracts, strategies — plus members and attributes, and no layout at all | The aspect applied to it chooses: a struct with a vtable, or a key-value map with static dispatch |
| Struct | A value type; assignment is one node with value semantics; embedding is a feature of the declaration | Layout, padding and alignment, and the copy-on-write machinery the language guarantees |
| Strategy, static | Already resolved: the node carries the target the module's record selected | A direct call |
| Strategy, dynamic | A value of its own — a method table with no receiver — and a `using` node binding it over a scope | A vtable and an indirect call |
| Aspect | The expanded result: the class HIR describes already has the members the aspect added. Whether the origin of a member is recorded is **open (S10.6)** | Nothing of its own; it ran during compilation |
| Attribute, decorator | Attributes ride on the declaration untouched | Read by lowering (`@packed`, `@bigEndian`) or already spent during generation (`@equatable`) |
| Metafunction, `InlineClosure` | `meta fn` is a declaration kind; a closure is a fragment of HIR held as a value, with hygiene, and a splice is a node | Inlined at the call site; nothing of the metafunction survives |
| Generics | Type parameters, constraints, variance, instantiation sites, and an explicit demand for a strategy when the programmer made one | Monomorphisation for one strategy and a uniform representation for the other. **Held over (S10.4)** |
| Context | A declaration; `with`, `override` and `without` bind over a scope; a read through `%` is a node | How a context reaches a function is undecided |
| Effect | The requirement `in X` on a signature, inferred along the call graph, with `isolated` cutting the edge | Erased when the effect is a contract; a vtable when it is an interface. `context-and-effects.md` marks this its own open question |
| Ownership, slots | A slot per resource, carrying the aspects it holds at that point; a name refers to a slot rather than owning one | Erased once the checks pass. `own` decides where a destructor call lands |
| Projection | Two things: a declaration (a binary-compatible view type) and an operation (viewing a value through it) | Nothing. Binary compatibility is the point: a projection costs no code |
| Metadata | On declarations, as written | Erased unless `markForRuntime` marked the key to travel |
| Visibility | On the symbol record, four levels, `private` file-scoped | Erased; it constrains linkage while it lasts |
| Typestate | States are declarations inside a class, a struct or an interface and may carry their own fields; a signature carries `Before >> After` beside its contexts and its `throws`; refinement uses the existing `is` and `switch` and adds no node | Erased once the check passes. The per-state fields still reach lowering, because what a state holds is what has to be laid out |
| Code region | A `region` node carrying its properties — `preserve` is the only one so far — and the guarantees it makes over named slots | Erased. It emits no code; it constrains what lowering is allowed to see |
| Package, module, namespace | Parts of a symbol key. A module also owns a record: its imports, the strategies it enables, its static effect bindings | Linkage and deployment |

## Not read yet

No row is written for these, because writing one would mean guessing. Each names
the document that decides it, all under `efen/docs/efen`:

- refinement types — `types/refinement-types.md`
- enums and unions — `types/enum.md`
- optional and `null` — `types/optional.md`
- type aliases — `type-aliases.md`
- tuples, dictionaries, collections, strings, constants — `types/`
- generators — `generators.md`
- disposable — `disposable.md`
- dialects — `dialects.md`
- superpolymorphism — `superpolymorphism.md`
