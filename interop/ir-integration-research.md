# IR-Level Integration with C++ and Rust

## Summary

This document captures research on obtaining LLVM IR from C++ and Rust modules and composing it with Limelight's own IR at build or JIT time.

---

## Extracting IR

### From C++ (Clang)

```sh
clang++ -S -emit-llvm foo.cpp -o foo.ll    # textual IR
clang++ -emit-llvm -c foo.cpp -o foo.bc    # bitcode
```

### From Rust

```sh
rustc --emit=llvm-ir lib.rs    # textual IR
rustc --emit=llvm-bc lib.rs    # bitcode
```

---

## Composing Modules

Multiple IR modules can be merged using `llvm-link`:

```sh
llvm-link rust.bc cpp.bc my.bc -o combined.bc
```

After merging, run `opt` for optimization and `llc` to produce object code.

---

## Hard Blockers

| Problem | Impact |
|---|---|
| **LLVM version must match** | Clang and rustc must be built against the same LLVM version. Example: Rust 1.85 = LLVM 19, so Clang 19 is required. Mismatched versions cause `llvm-link` to fail. |
| **Target triple must be identical** | Even minor triple string differences break ThinLTO. All toolchain invocations must be standardized. |
| **C++ templates and Rust generics** | IR only contains instantiations actually used within the compiled translation unit. A template `Foo<T>` not used in the same `.cpp` has no IR body. This is a fundamental constraint of ahead-of-time monomorphization. |
| **arm64 macOS personality limit** | The compact unwind table on arm64 macOS supports at most 3 personality functions. Mixing C++ EH + Rust EH + ObjC hits this limit. Linux (Itanium EH) is unaffected. |

---

## The Template / Generics Problem

If Limelight needs to call `Foo<MyPhpObject>` from C++ or `process::<MyPhpValue>()` from Rust, those instantiations do not exist in any precompiled IR. The only solution is to **generate source code for the specific concrete type and recompile**.

### In-memory compilation (C++)

Clang supports compilation from an `llvm::MemoryBuffer` — no filesystem required:

1. Generate a C++ snippet at runtime: `template class Foo<MyPhpObject>;`
2. Feed it to `CompilerInstance` via `MemoryBuffer`
3. Receive an `llvm::Module*` in memory
4. Merge it into Limelight's module with `llvm::Linker::linkModules()` — also in memory

This is the cleanest path for JIT use cases where PHP types are only known at runtime.

### Rust generics

`librustc_driver` is unstable and not designed for external use. In-process compilation is not viable. The practical approach is to invoke `rustc` as a subprocess, emitting bitcode to a temp file, then loading it back as an `llvm::Module`.

### Design implication

Limelight must be prepared to generate C++ or Rust source snippets on demand for each new PHP type that needs to cross the language boundary, compile them (in-memory for C++, via subprocess for Rust), and merge the resulting `llvm::Module` into its own IR. This is the only viable path when generic or templated library code is involved.

---

## ThinLTO

ThinLTO is a scalable link-time optimization variant that enables cross-module and cross-language inlining without merging all IR into one giant module upfront.

### How it works

1. Each module is compiled to bitcode plus a **summary index** (function signatures, call graph edges).
2. The linker reads summaries and imports only the functions actually called across module boundaries.
3. Each module is optimized in parallel with access to its imported functions only.

### Enabling it

```sh
# Clang
clang++ -flto=thin -c foo.cpp -o foo.o

# Rust
RUSTFLAGS="-C linker-plugin-lto" cargo build

# Link with LLD (required)
clang++ -flto=thin -fuse-ld=lld foo.o bar.o -o out
```

ThinLTO is used by **Mozilla Firefox in production** since 2019 to achieve cross-language inlining between its C++ and Rust codebases.

---

## Practical Strategies for Limelight

| Scenario | Recommended approach |
|---|---|
| Non-generic C++/Rust library code | Extract IR with `-emit-llvm` / `--emit=llvm-bc`, merge with `llvm-link`. Pin LLVM versions. Expose `extern "C"` entry points. |
| C++ templates / Rust generics with PHP types | Generate a source snippet for the concrete type, compile in-memory (Clang) or via subprocess (rustc), merge the resulting module into Limelight's IR. |
| Calling into precompiled system libraries | Use a C ABI boundary. This is what bindgen, cxx, and autocxx do. Recover cross-module inlining via ThinLTO at the final link step. |
| JIT: PHP compiled at runtime, calling into C++/Rust | Pre-compile C++/Rust to bitcode at Limelight build time. At JIT time, merge pre-compiled bitcode with PHP-derived IR using `llvm::Linker::linkModules()`. LLVM version must match the JIT's LLVM. |

---

## C++ ABI Details in IR

- Vtables appear as `@_ZTV<ClassName>` globals. They are only emitted in the TU that defines the first non-inline virtual method.
- RTTI appears as `@_ZTI<ClassName>` (type info) and `@_ZTS<ClassName>` (type string). Only present in the owning TU.
- Name mangling: Clang uses Itanium C++ ABI. Rust uses its own scheme. Both are opaque to the linker as long as symbols resolve.
- Calling a C++ virtual method from external IR requires loading the vtable slot explicitly — it is not a simple direct call.

---

## Exception Handling Across Modules

- C++ uses `__gxx_personality_v0`; Rust uses `rust_eh_personality`. After `llvm-link`, a combined module may legally contain both.
- On **Linux** (Itanium EH / `.eh_frame`): multiple personality functions per binary are supported. No issue.
- On **arm64 macOS**: compact unwind tables have a limit of 3 personalities. Mixing C++, Rust, and ObjC EH exceeds this (rust-lang/rust #102754, open).
- Do not mix libstdc++ and libc++abi in the same binary. Pick one C++ runtime.

---

## References

- [Closing the gap: cross-language LTO between Rust and C/C++ — LLVM Blog](https://blog.llvm.org/2019/09/closing-gap-cross-language-lto-between.html)
- [Linker-plugin-based LTO — The rustc book](https://doc.rust-lang.org/rustc/linker-plugin-lto.html)
- [llvm-link — LLVM documentation](https://llvm.org/docs/CommandGuide/llvm-link.html)
- [Exception Handling in LLVM](https://llvm.org/docs/ExceptionHandling.html)
- [CXX — safe interop between Rust and C++](https://cxx.rs/)
- [Mozilla ThinLTO tracking — Bugzilla #1486042](https://bugzilla.mozilla.org/show_bug.cgi?id=1486042)
- [arm64 personality limit — rust-lang/rust #102754](https://github.com/rust-lang/rust/issues/102754)
