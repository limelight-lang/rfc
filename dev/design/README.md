# design/ — schemas for complex parts

One document per topic, named after it. Diagrams are **PlantUML**
sources (`.puml`) kept next to the document; no binary images in the
repo — render on demand from the text source. Around each diagram, a
short note: what it shows, which invariants hold, what is deliberately
absent. English only — except the interactive maps (`*.map.yaml`), which
are in Russian by Edmond's ruling of 2026-08-25: a map is read on its
served page, not in the repository, and he reads it in Russian.

Occupants: `rc-cycle.map.yaml`, `rc-cycle`'s question graph
([`../../model/gc/cycle/questions.md`](../../model/gc/cycle/questions.md)) as an
interactive map; `trace-token-handshake.md`, the trace token as a
request-and-consent word between a collector thread and a mutator, ruled
2026-09-17 and waiting on Edmond before it amends "Concurrency". Still expected: the fact-base schema (entities,
relations, attributes, invariants) once the formalism is chosen.
