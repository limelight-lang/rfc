# Runtime

The abstraction layer that bridges PHP-level execution and the underlying platform.

Responsible for lifecycle management (startup, shutdown), platform abstraction, and providing the environment in which PHP programs run. This layer does not implement language semantics directly — it provides the substrate on which the Model and other subsystems operate.

## Documents

- [implementation-language.md](implementation-language.md) — Rust core + thin C++ LLVM layer, the single-LLVM-version rule
- [object-lifecycle.md](object-lifecycle.md) — `new`, three-phase teardown (pre-destructor / drop / memory release)
