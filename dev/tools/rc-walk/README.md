# rc-walk model checker

TLA+ model of the rc-walk collector
([../../../model/gc/rc-walk.md](../../../model/gc/rc-walk.md)), checked
with TLC. Results and readings live in
[rc-walk-proof.md](../../../model/gc/rc-walk-proof.md); the kill traces
it must reproduce are
[rc-walk-danger-cases.md](../../../model/gc/rc-walk-danger-cases.md).

Toolchain: Java (tested on 19.0.1) + `tla2tools.jar` (TLC2 2.19,
2024-08-08, from the official tlaplus GitHub releases; vendored here).

> **Protocol drift (2026-07-27):** both specs model the pre-amendment
> protocol; the eager-death amendment (rc-walk.md) retired the condemned
> byte, the F5 death deferral and message-based acquittals. See the
> banner note in rc-walk-model.md; re-derivation is deferred to the
> checker-extensions work after design freeze.

## Files

- `RcWalk.tla` — the model: three actors, the 2026-07-26 protocol
  amendments (condemned entities never die on the ordinary path,
  acquittal clears bytes and tears deferred deaths, weak components,
  store releases last), broken-variant switches, scenario scripts.
- `SC_*.cfg` — the scenario battery, one run each: a fixed mutator
  script, interleaved every possible way with the collector.
- `DrainWindow.tla` + `DW_*.cfg` — the drain-exclusivity window
  ([drain-window.md](../../../model/gc/drain-window.md)): a separate
  tiny spec (sound run: 23 states), one sound config and three kills,
  one per link of the proof.
- `run_all.ps1` — legacy free-mode batch runner (expensive; the
  scenario battery replaced it for routine use).

## Running

```
java -cp tla2tools.jar tlc2.TLC -config SC_selfloop_byte.cfg -workers 8 RcWalk.tla
```

Scenario runs finish in seconds. `ScriptName = "free"` in a config
restores the unbounded mutator — exhaustion then needs hours and
gigabytes, use deliberately.

Every `SC_*` config encodes an expectation (see the battery table in
rc-walk-proof.md): kill configs must end in a violated invariant with a
trace, sound configs must exhaust with no error. A sound config that
suddenly reports a violation, or a kill config that goes green, means
either the spec or the design regressed — investigate before trusting
anything else.
