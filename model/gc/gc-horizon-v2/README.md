# GC Horizon, second design — the capture-count regime

> **Considered and refused, 2026-08-22.** The design of record is
> [`../walk/`](../walk/README.md): the counted heap edge stays the write
> barrier. This folder is kept as the record of the capture-count regime and
> of why it fails — nodes M and N of [questions.md](questions.md). Do not
> build from it.

**This folder holds the capture-count regime, refused on 2026-08-22.** It
was written against [../gc-horizon.md](../gc-horizon.md), revision 6 of the
first design, which stays in place and is again the text in force for the
proof side. Where the two disagree, [../walk/](../walk/README.md) rules
over both; nothing here
is implemented and nothing there has been deleted.

The two differ in one thing: what a borrow pays at a horizon. The first
design pays a reference count — promotion to an owned local by an
ordinary `retain`, with the collector never learning the feature exists.
The second design pays a publication the collector reads, which lets a
class of entities carry no mutator-maintained reference count at all.

## Reading order

- [top-level.md](top-level.md) — the design as agreed so far: the
  problem, the three answers to it, the two prices of protection, the
  three treatments the collector owes an entity, the header states, and
  what changes in `rc-walk`.
- [questions.md](questions.md) — the question graph: what is still open,
  in the order the answers unlock each other, with the session's resolved
  nodes kept in place.
- [prior-art.md](prior-art.md) — the four mechanisms this design
  combines, which three are known and where they ship, the comparison on
  who publishes a root and what the mutator pays, and the one mechanism
  the search did not find.

## Status

Discussion record, written 2026-08-21 from a working session with
Edmond, who is the author of the algorithm. It is neither reviewed nor
adopted: no Critic round has run over it and six questions listed at the end of
[top-level.md](top-level.md) are open. The parts of the first design it
does not touch — the ownership lattice, the horizon list, the placement
rule — hold unchanged and are read from [../gc-horizon.md](../gc-horizon.md).
