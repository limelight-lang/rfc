# Architecture decisions

A changelog for architecture: what was decided and why, not what
changed in the code. Newest on top. A superseded decision is left in
place and replaced by a new entry, never edited away.

Format per entry (3–6 lines): date + one sentence on **what** was
decided; **why** (the problem or constraint); **rejected** alternatives
in one line; **cost** if any.

---

### 2026-07-24 — Proxy is the runtime's one indirection; movement is opt-in through it

Box (kind 4), WeakRef (kind 5), and Ghost/lazy (kind 6) are unified as
instances of one **Proxy** pattern — a surrogate that intercepts all
access to a target for one dereference — and a fourth effect, a movable
handle, joins them. Object movement exists **only** behind a movable
proxy (or an extract-to-access container); the general heap stays strictly
non-moving.
- **Why:** fragmentation is handled without a global moving collector.
  Confining relocation to an opt-in proxy pool keeps the common path on
  direct pointers (no read barrier, no global pinning) and localizes the
  compactor; identity rides the stable proxy, so `spl_object_id` stays
  address-derived. The shape is the GoF taxonomy (virtual proxy = Ghost,
  smart reference = WeakRef, handle = movable), and PHP 8.4 already names
  its lazy strategies Ghost and Proxy. No mainstream language unifies
  weak + lazy + movable under one primitive, so this consolidates known
  effects rather than inventing.
- **Rejected:** a global moving/compacting collector — read barriers plus
  pinning for FFI-escaped addresses plus header identity-hash, all to move
  objects the FFI load often pins anyway (see the non-moving research).
  The committed fragmentation answer is the movable proxy, not arena-reset
  sparse-block evacuation, which stays deferred.
- **Cost:** one pointer-chase per access on proxied objects; a scoped
  compactor for the movable-proxy pool if/when built.
- **Deferred:** consolidating kinds 4–6 (one family) to reclaim
  entity-kind bits — noted, not designed.
- **Written:** [classes.md](../model/classes.md), "The Proxy family".

### 2026-07-24 — Captured heap objects carry `gc_state = OWNED`, skipped by the collector

A general-heap object (category `00`) captured by an arena/actor stays
physically in the heap but is marked with a fourth `gc_state` value,
`OWNED`. Both CAS handoffs start from `LIVE`
([heap-design.md](../model/gc/heap-design.md)), so an `OWNED` object
fails both and is skipped by collector and mutator alike; its lifetime is
the owning arena's responsibility until it escapes to shared and is
re-armed to `LIVE`.
- **Why:** a transferable object is allocated in the general heap for a
  zero-copy handoff ([actors.md](../runtime/actors.md)) but is owned by
  one actor at a time. The collector must not touch a captured object;
  saying so with `gc_state` costs zero new bits (2-bit field, only 3
  values used) and needs no new collector branch — a non-`LIVE` state
  already fails the handoff CAS. It also makes the "needs no atomic
  counts" claim exact: the single owner is the sole writer of `refcount`.
- **Rejected:** a dedicated flag bit (the flags word is full, bits 0–31
  all assigned); a fifth `mem_category` (2 bits, all four values used);
  reusing entity-kind `7` (conflates identity with collectability).
- **Cost:** `heap-design.md` state field is now four-valued; `classes.md`
  flags table and `actors.md` updated.
- **Not fully worked out.** The escape event that flips `OWNED → LIVE`
  (an object becoming reachable by ≥2 actors) rides the existing
  escape/category machinery; its exact trigger and the in-transit
  A→queue→B ownership window are not yet pinned. Provisional.

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
