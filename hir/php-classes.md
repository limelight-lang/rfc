# The PHP class model against Efen's

Status: draft, step S10.8. Each row states either a verdict, with its date and
where the decision is recorded, or what the verdict is waiting on. Rows are
closed one at a time; closing one does not touch the others.

What is not in dispute is most of it: both are reference types with single
inheritance, multiple interfaces, static members and a constructor. The rows
below are the differences.

| Difference | State |
|---|---|
| **Memory model** | **Decided 2026-09-03.** A PHP object is an Efen ARC object, so a PHP class takes the reference-counted aspect Efen already describes. Recorded in `limelight-lang/amber`, `dev/DECISIONS.md` |
| **Destruction** | **Decided 2026-09-03**, and it follows from the row above. `__destruct` means the count reached zero, which is what the reference-counted aspect already does. No separate mechanism |
| **Dispatch default** | **Decided in part, 2026-09-03.** A PHP method is virtual unless something makes it otherwise; `private`, `final`, and any method of a `final` class are static by construction, and devirtualisation from the symbol database narrows the rest. Open: which further methods need not be virtual — Edmond is thinking about it |
| **Late static binding** | **Open.** `static::` resolves against the runtime class of the receiver rather than the lexical one, and returns dynamism where the signature does not advertise it. No counterpart is written down for Efen. Waiting on: a mechanism, or a ruling that PHP's own runtime carries it |
| **Magic methods** | **Open.** `__get`, `__set` and `__call` intercept names that were never declared; a computed property is declared in advance and cannot. The dictionary-shaped aspect is the likely mechanism, which would make interception a property of the aspect rather than of the class. Waiting on: that aspect being specified |
| **Dynamic properties** | **Open**, and it follows the row above: assigning a field that was never declared exists only under a dictionary-shaped aspect. Waiting on: the same specification |
| **`protected`** | **Open, and blocked on a contradiction in Efen itself.** `functions.md` names `public`, `internal`, `private`, `api`; `compile-time/index.md` names `Public`, `Private`, `Protected`, `Internal`. PHP needs `protected`. Waiting on: one canonical list, which the documentation audit of 2026-09-03 did not cover |
| **Traits against strategies** | **Open.** Both add behaviour from outside, but a trait attaches in the class body with its own conflict rules (`insteadof`, `as`) while a strategy attaches per module through `use`. Different attachment point, different conflict resolution. Waiting on: whether a trait lowers onto a strategy at all, or onto plain members copied at compile time |
