# Postmortem — painful mistakes

Serious mistakes only: ones that cost real time, broke something that
worked, sent work down a false path, or recurred.

Format per entry: **what happened** (the symptom as seen); **root
cause** (not "a typo" but why it was possible and why it slipped
through); **what changed** so it cannot recur (a test, an invariant, a
rule, a check).

---

### 2026-07-23 — The Node example gave a 16-byte Box only 8 bytes

**What happened.** In the worked example of a lowered PHP class
([lowering.md](../model/lowering.md)), `Value meta` sat at `+32` and
`int64_t id` at `+40`. A `Value` is the 16-byte Box — lowering.md says so
itself, and [values.md](../model/values.md) defines it — so `meta` spans
`+32..+47` and the two fields claimed the same eight bytes. Every field
after `meta` was 8 too low and `object_size` read 56 instead of 64. Code
written from this example would have overwritten half of `$meta` on every
write to `$id`.

**Root cause.** The size of a field's type was never written beside its
offset; it lived in a different document. Each document was internally
consistent — lowering.md's offsets form a tidy ascending sequence, and
"the Box is 16 bytes" is correct — so neither looked wrong on its own.
The contradiction existed only in the pair, and documents get read one at
a time. Reviewing a layout against the *definitions it depends on* is
exactly the check a human reviewer skips.

**What changed.** The fact base (`efen-lang/kolvir`) now derives a field's
size from its type's own definition, so an offset stated in one document
is checked against a size stated in another; the collision is reported as
the specific bytes involved. The pre-fix layout is kept there as a
regression case (`pilot/asp/node_before_fix.lp`). lowering.md now states
the Box span inline at the point of use, so the dependency is visible
where the offsets are written.
