# rc-cycle — the design of record from 2026-08-25

Edmond chose the direction and the name. The protocol text is
[`../rc-cycle.md`](../rc-cycle.md); the open questions are
[`questions.md`](questions.md) and the work is built on them, node by node,
as stage S5 was.

**What it replaces, and in what sense.** `rc-walk` is the strategy the crate
runs and `../rc-walk.md` is the text in force for it. What
changes on 2026-08-25 is which design the work serves: new questions are
asked of `rc-cycle`, and `walk/` is closed — its graph stands as the record
of a stage that finished, not as a queue. Nothing is deleted and no code
moves until `rc-cycle` exists to move it to.

**The premise is not verified.** The algorithm is Bacon–Rajan's cycle
collection over Levanoni and Petrank's sliding views, and the first node
asks what that costs the mutator per store — which is the constraint
`rc-walk` was built on. A design written before that answer would be a guess
with a banner.
