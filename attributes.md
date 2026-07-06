# Attributes Are the Language Surface

**Key principle.** Limelight adds **zero new keywords and zero new
syntax** to PHP. Every Limelight capability enters the language through
native PHP 8 attributes. A Limelight program is, syntactically, a valid
PHP program.

---

## One vocabulary, two directions

Attributes flow both ways between the programmer and the compiler:

**1. Declaration (human → compiler).** The programmer opts into
semantics:

```php
#[Actor(gc: 'none')]
class RequestHandler { ... }        // an actor — no new `actor` keyword

class Node {
    #[Backedge] public ?Node $parent;   // cycle-shape hint for the GC
}
```

**2. Materialization (compiler → human).** The expensive analysis mode
— whole-program, cross-autoload, possibly profile-assisted — writes
its findings **back into the source code as the same attributes**. The
fast incremental compile then *reads* them as declarations and only
verifies them locally.

Prior art for the round trip: the Checker Framework's whole-program
inference inserts inferred Java annotations back into source
(ROUNDTRIP mode); Facebook's Hack migration inferred types and wrote
them into code as soft annotations hardened after runtime validation;
MonkeyType applies runtime-observed types to Python source.

### Trust rules

- **Explicit beats inferred.** A hand-written attribute is a
  constraint the analysis must respect, never overwrite.
- **Inferred is verified, not believed.** Every materialized attribute
  is a checked assumption: each build re-verifies it cheaply against
  the local facts; stale attributes are reported, re-inferred, never
  silently trusted. (Checker Framework's model.)
- **Inferred is visible.** Materialized attributes live in the code:
  reviewable in diffs, versioned in git, correctable by hand — unlike
  sidecar caches (GHC `.hi`, PGO profiles).
- Inferred attributes carry a marker (parameter or dedicated namespace
  — exact form TBD) so humans and tools can tell the two apart.

---

## Why this principle is load-bearing

1. **The entire PHP toolchain keeps working.** Parsers, IDEs,
   formatters, Psalm/PHPStan, composer tooling — none of them break on
   a Limelight codebase, because there is nothing new to parse.
2. **Graceful degradation is possible.** Plain PHP ignores
   un-reflected attributes; a Limelight program remains *runnable* by
   Zend where the semantics permit (an `#[Actor]` class degrades to a
   synchronous object; `#[Backedge]` is inert). Degradation contracts
   per attribute are part of each attribute's RFC.
3. **Attributes are the persistent cache of whole-program analysis.**
   This closes the open problem in
   [static-lifetimes.md](model/memory/static-lifetimes.md): analysis
   cannot see across unseen autoload boundaries — but materialized
   attributes in already-analyzed code travel with that code. Fast
   builds stay fast; deep analysis runs when it runs.
4. **The ecosystem already votes for this.** PHP's de-facto extension
   surface has been docblock annotations for a decade
   (`@template` generics in Psalm/PHPStan). Limelight promotes the
   pattern from comments to native attributes, from advisory to
   compiler-enforced and codegen-driving.

## Attribute registry (current)

| Attribute | Direction | Domain | RFC |
|---|---|---|---|
| `#[Actor]`, `#[Actor(gc:, threshold:)]` | declared | actor contexts, per-actor GC | [runtime/actors.md](runtime/actors.md) |
| `#[Backedge]` | declared **and** inferred | cycle shapes (Level B) | [model/memory/static-lifetimes.md](model/memory/static-lifetimes.md) |
| ownership conventions (borrows / takes / escapes per parameter) | inferred | move analysis across signatures | [model/memory/static-lifetimes.md](model/memory/static-lifetimes.md) |
| acyclicity (`ACYCLIC` class bit) | inferred | cycle-candidate filtering (Level A) | [model/memory/static-lifetimes.md](model/memory/static-lifetimes.md) |
| generics (`#[Template]`-family, vocabulary aligned with Psalm/PHPStan) | declared | parametric types without new syntax | future RFC (backlog) |

All Limelight attributes live in a reserved namespace (exact name TBD)
so they can never collide with userland attributes.

## Open questions

- Namespace and the inferred-marker mechanism.
- Materialization ergonomics: how the analysis edits code it does not
  own (vendor/) — likely sidecar overrides for read-only trees, source
  edits for the project tree.
- Generics-via-attributes needs its own RFC: variance, reification vs
  erasure, interaction with the value model.
