# Architecture decisions

A changelog for architecture: what was decided and why, not what
changed in the code. Newest on top. A superseded decision is left in
place and replaced by a new entry, never edited away.

Format per entry (3–6 lines): date + one sentence on **what** was
decided; **why** (the problem or constraint); **rejected** alternatives
in one line; **cost** if any.

---

### 2026-07-24 — The marker's root set includes live arenas' heap references

The concurrent marker's roots are `stacks + globals` **plus every live
arena's references into the general heap** (its *release-at-reset* list),
not stacks + globals alone. Transport depends on the arena's thread: a
same-thread arena (request / ordinary) is scanned directly at the
SNAPSHOT safepoint; an actor arena on another thread **publishes** its
list in the mailbox handshake (variant B), so the marker never reads a
running actor's memory.
- **Why:** a general-heap object reachable *only* from an arena slot is
  on no stack or global, and the marker does not walk arenas, so a
  stacks+globals-only trace would sweep it while live — a use-after-free
  at reset. Prior art (Pony/ORCA, Go, HotSpot, OCaml-multicore/DLG)
  overwhelmingly reads a running mutator's roots by cooperative
  self-publish at a safepoint/handshake, not by concurrent direct reads.
- **Rejected:** the marker reading a running actor's list directly (the
  earlier `actors.md` wording) — only ZGC/Shenandoah approximate
  concurrent root reads and even they gate with a stack-watermark
  barrier; an unsynchronized read also contradicts actor isolation.
- **Deferred, larger:** a capability restriction on what may cross an
  actor boundary into the general heap (immutable or unique only, à la
  Pony `val`/`iso`) — what buys barrier-free collection. Its own entry
  when designed.
- **Cost:** `satb.md` root set and `actors.md` root transport reworded.
- **Not fully worked out.** A direction chosen from prior art, not a
  verified mechanism: the SNAPSHOT "all-threads safepoint" wording still
  sits in tension with the actors' "no stop-the-world" handshake, and the
  handshake payload and same-thread watermark/SATB interaction are
  unproven. `actors.md` and `satb.md` both flag it provisional; re-verify
  at implementation.

### 2026-07-23 — A reserved region must state its extent explicitly

Any reserved or padding region in a layout must state where it starts,
how large it is, and why it is unused; the regions must sum to the
declared total.
- **Why:** the first run of the fact-base checker (`efen-lang/kolvir`)
  found that the value Box was declared 16 bytes while its fields summed
  to 15 — payload 8, type_tag 1, flags 1, reserved 5 — leaving byte 15
  belonging to nobody. `reserved` had to be 6 bytes (+10..15), which
  PHP's `zval` confirms independently: `u1.v.u.extra` (2 B) and `u2`
  (4 B) occupy exactly that span. A loosely worded reserve hid a whole
  missing byte.
- **Rejected:** treating an unexplained "reserved" as harmless slack.
- **Cost:** none of substance; layout tables get slightly more verbose.
- Fixed in [values.md](../model/values.md), "Box Layout". What to put in
  those six bytes is deliberately deferred, see [BACKLOG.md](../BACKLOG.md),
  "Deferred optimizations".
