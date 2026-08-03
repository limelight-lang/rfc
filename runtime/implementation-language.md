# Implementation Language

## Decision: Rust core + thin C++ layer around LLVM

The runtime has an unusual requirement: its hot paths (retain/release,
bump allocation, Optional unwrap, COW checks) must **inline into compiled
PHP code**. Therefore the runtime is built twice at build time: to machine
code, and to **LLVM bitcode** that is merged with PHP-derived IR at
AOT/JIT link time (`llvm::Linker::linkModules`), letting the optimizer
inline across the boundary. Both candidate languages can emit bitcode
(`clang -emit-llvm`, `rustc --emit=llvm-bc`); the decision is driven by
everything else.

### Comparison

| Factor | Rust | C++ |
|---|---|---|
| Memory safety of a large long-lived codebase | Yes (unsafe islands are localized) | No |
| LLVM API (IR emission, JIT engine) | Bindings (inkwell/llvm-sys), lag behind LLVM | First-class, native |
| In-memory compilation of interop snippets ([ir-integration-research.md](../interop/ir-integration-research.md)) | Impossible (`librustc_driver` is closed) | Clang supports it, already in the interop plan |
| LLVM version choice | Dictated by rustc (e.g. Rust 1.85 = LLVM 19) | Free |
| Bitcode for cross-inlining into PHP code | Yes | Yes |

A sixth factor stood here until 2026-08-03: MMTK as a GC backend, native
to Rust because `VMBinding` is a Rust trait and reachable from C++ only
through a C wrapper. MMTK is not being built
([heap-design.md](../model/gc/heap-design.md)), so the factor is gone.
The decision stands on the rest, and the runtime core it produced is
already Rust.

### Split

- **Rust** — the runtime core (~90% of the code): memory manager, arenas,
  the collectors, runtime data structures,
  strings/arrays, stdlib infrastructure. Long-lived, eventually
  multi-threaded code where Rust's safety pays for itself. Precedents:
  MMTK itself, Ruby's YJIT.
- **C++ (thin layer)** — only what holds LLVM in its hands: IR emission,
  the JIT engine, in-memory Clang for interop code generation (Clang is a
  C++ library; it cannot be embedded from Rust). Communicates with the
  Rust core over a C ABI.

Rejected alternatives: pure C++ (loses safety across the whole codebase to
make one module more convenient); pure Rust (fights LLVM
bindings in the most complex part of the project and gives up in-memory
Clang).

### The single-LLVM-version rule

All bitcode participants must share one LLVM version
([ir-integration-research.md](../interop/ir-integration-research.md),
hard blockers). Since rustc pins its own LLVM, **rustc's LLVM version
dictates the project's LLVM version**: the C++ layer, the JIT, and Clang
are all built against it. This is a build-system rule, enforced in CI.
