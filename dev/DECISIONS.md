# Architecture decisions

A changelog for architecture: what was decided and why, not what
changed in the code. Newest on top. A superseded decision is left in
place and replaced by a new entry, never edited away.

Format per entry (3–6 lines): date + one sentence on **what** was
decided; **why** (the problem or constraint); **rejected** alternatives
in one line; **cost** if any.

---

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
