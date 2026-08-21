# GC Horizon, second design — the current one

**This folder holds the current GC horizon design.** It supersedes
[../gc-horizon.md](../gc-horizon.md), which is revision 6 of the first
design and stays in place as the record of what that design decided and
why. Where the two disagree, this folder is the later text; nothing here
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
