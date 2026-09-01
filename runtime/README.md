# Runtime

The abstraction layer that bridges PHP-level execution and the underlying platform.

Responsible for lifecycle management (startup, shutdown), platform abstraction, and providing the environment in which PHP programs run. This layer does not implement language semantics directly; it provides the substrate on which the Model and other subsystems operate.

## Documents

- [implementation-language.md](implementation-language.md) — Rust core + thin C++ LLVM layer, the single-LLVM-version rule
- [object-lifecycle.md](object-lifecycle.md) — `new` and ordered teardown: user destructor, resurrection check, weak-reference invalidation, field and resource release, then storage reclamation
- [actors.md](actors.md) — `#[Actor]`: serial execution contexts owning their arenas; mailboxes as the only communication channel; per-actor collection and per-actor GC selection
