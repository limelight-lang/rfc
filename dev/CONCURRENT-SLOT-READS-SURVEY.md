# How shipped runtimes read a tagged value slot from a collector thread

> **Survey date:** 2026-09-14
> **Question:** how does a concurrent collector read a value slot whose tag
> and payload are two machine words, while the owning mutator may be
> overwriting it, without ever combining a new payload with an old tag?
> **Purpose:** the precedent record behind `ALGORITHM-AUDIT.md` A1's
> resolution (`DECISIONS.md`, "A1 closes on a discriminating word"). It
> reports what is built; it recommends nothing.

No shipped runtime lets an off-thread collector read a two-word tag+payload
slot racily. Each one either makes the slot one word, makes the word the
collector reads self-describing so the tag is never the collector's, caps the
atomic unit at what the hardware stores in one instruction, guards a change
of interpretation with a colour-CAS or a double read, or has no concurrent
reader at all. **V** marks a claim verified against the cited source, **I**
an inference.

## Go — the one shipped two-word answer

An interface value is two words, `{itab/type *, data unsafe.Pointer}`, and
the concurrent mark workers read it under a hybrid Yuasa–Dijkstra barrier
(V: `runtime/mbarrier.go`, https://go.dev/src/runtime/mbarrier.go). Issue
#8405 (2014) states the problem in these terms: "garbage collection treats
interfaces as multiword objects: the type word tells whether the data word is
a pointer … It must not be possible for the collector to observe a
half-updated interface value" (V: https://github.com/golang/go/issues/8405).
Sixteen-byte atomics were rejected there — "128-bit SSE loads and stores are
not guaranteed to be atomic … I don't think we want to use atomics here",
`lock cmpxchg16b` at about 20 cycles and 5,000 when the value crosses a cache
line — and the representation was changed instead: since Go 1.4 the data
word always holds a pointer or nil, so the collector reads one word and the
type word is not the GC's (V: https://go.dev/doc/go1.4, "interface values
always hold a pointer"). The pointer bitmap marks only the second word; the
first is deliberately not a GC pointer because itabs live in persistent
allocation (V: `cmd/compile/internal/typebits/typebits.go`). The price was an
allocation for every scalar stored in an interface, because the pointer took
the data word and the scalar had nowhere else to go. The Go memory model
still calls a racing interface store "arbitrary memory corruption" — for the
mutator, not the collector (V: https://go.dev/ref/mem).

Limelight's resolution is the same shape with the discriminator in a word of
its own: the collector reads +8 alone, a pointer or a tag word, and the scalar
keeps +0 unboxed.

## One-word encodings

**V8.** One tagged word, Smi or pointer by the low bit (32 bits under pointer
compression); concurrent marking since 2018 with relaxed atomic field writes
and an atomic colour transition in the barrier. Where the tag lives apart from
the field — the hidden class saying whether a field is tagged or an unboxed
double — a layout change is guarded by a colour CAS: the mutator CASes the
object white→grey→black and pushes it to a bailout list before changing the
layout; the worker snapshots the pointer fields under the old class and
trusts the snapshot only if its own grey→black CAS succeeds (V:
https://v8.dev/blog/concurrent-marking, "Object layout changes").

**JavaScriptCore.** `JSValue` is one NaN-encoded 64-bit word (V:
`runtime/JSCJSValue.h`); Riptide marks concurrently with a retreating
barrier that records the object, never the stored value (V:
https://webkit.org/blog/7122/). Slot reads rely on 8-byte-aligned stores
being single-copy atomic, and the runtime forbids libc `memcpy`/`memset`
on scanned memory for that reason — "we may see a torn JSValue in the
concurrent collector" — copying with 8-byte `movq` tails (V:
`heap/GCMemoryOperations.h`). Where interpretation and storage part — the
Structure deciding the butterfly's layout — a seqlock-shaped double read:
read Structure, read butterfly, read Structure again, `didRace()` on
mismatch, crediting Afek et al., "Atomic Snapshots of Shared Memory" (V:
`runtime/JSObject.cpp`, `visitButterflyImpl`).

**SpiderMonkey.** `JS::Value` is 64 bits on every architecture; in the
PUNBOX64 mode of 64-bit targets the tag sits in the top bits above a 47-bit
address, and NUNBOX32 keeps the tag in the high word on 32-bit targets (V:
`js/public/Value.h`). Marking is incremental on the
main thread with parallel marking inside a slice; concurrent marking "is
currently being investigated" (V: https://firefox-source-docs.mozilla.org/js/gc.html).
Whether the one-word choice was made for concurrency: I — the 2010 "fatvals"
change was argued on unboxed doubles.

**HotSpot.** An oop is one word (compressed or not); every concurrent
collector reads one-word oops and finds them through the klass's oop map,
never a per-slot tag. The two-word case is Valhalla, and its answer is a cap:
flattened values must be read and written atomically, the hardware limit is
"64 bits (aligned) and sometimes within 128 bits" (V: J. Rose,
https://cr.openjdk.org/~jrose/values/flattened-values.html); the prototype
VM sets `MAX_ATOMIC_OP_SIZE = sizeof(uint64_t)` and flattens a null-marker
byte plus payload only when the rounded size is ≤ 8 bytes, keeping the field
a reference otherwise (V: `src/hotspot/share/classfile/fieldLayoutBuilder.*`
and `oops/layoutKind.hpp` on the `lworld` branch of
https://github.com/openjdk/valhalla). Tearing beyond that is an opt-in
(`@LooselyConsistentValue`) about what Java code observes; the GC still sees
each embedded oop as an ordinary oop.

**.NET CoreCLR.** One-word references, found through the method table's
GCDesc; "managed references are always aligned to their size … and accesses
are atomic", only pointer-sized primitives being atomic (V:
`docs/design/specs/Memory-model.md`, `docs/design/coreclr/botr/garbage-collection.md`
in https://github.com/dotnet/runtime). A two-word case such as a struct with
a reference is scanned by the reference's own descriptor entry, never
conditioned on a sibling flag (I).

## No concurrent reader

**PHP Zend.** `zval` is 16 bytes, `zend_value` at +0, `u1.type_info` at +8
(V: `Zend/zend_types.h`). `zend_gc_collect_cycles` is trial deletion after
the Bacon–Rajan paper the header comment of `Zend/zend_gc.c` cites (V: that
comment, for the colour scheme and the flow); that it runs synchronously on
the executing thread, and that under ZTS no thread scans another's zvals
because each has its own executor globals, are inferences from the source
having no collector thread (I).

**Lua 5.4 / LuaJIT.** `TValue` is 16 bytes with the tag byte at +8 in Lua
5.4 and an 8-byte NaN-tagged union in LuaJIT (V: `lobject.h`, `lj_obj.h`);
neither has a collector thread.

**Ruby.** `VALUE` is one word with low-bit tags (V:
`include/ruby/internal/value.h`); per-Ractor local GC runs on the owner
thread, and a global GC or compaction stops the other Ractors at
`rb_gc_vm_barrier()` (V: `gc/default/default.c`).

**Erlang/BEAM.** Per-process heaps, one-word tagged terms, each process
collected by its scheduler (V: https://www.erlang.org/doc/apps/erts/garbagecollection.html).

**Nim ORC.** Trial deletion after Bacon–Rajan and Lins, `roots {.threadvar.}`,
the collector on the mutator thread; "the reference counting operations do
not use atomic instructions" (V: `lib/system/orc.nim`,
https://nim-lang.org/docs/mm.html).

**Swift.** Reference counting only, no tracing collector (I).

**Rust crates.** `gc-arena` sequences mutation and collection through the
`Mutation` token (V: https://docs.rs/gc-arena). `shredder` has a background
collector thread that takes a per-object exclusive `Lockout` before scanning
and marks an object it cannot lock live for the cycle — a lock with a
conservative fallback, not a racy read (V: `src/collector/collect_impl.rs`,
`src/concurrency/lockout.rs` in https://github.com/Others/shredder).

**Bacon–Rajan's concurrent Recycler.** Bacon and Rajan, "Concurrent Cycle
Collection in Reference Counted Systems", ECOOP 2001: a collector thread reads
fields while mutators run, with buffered increments and decrements processed
at epoch boundaries; every reference slot is one aligned word. Both URLs found
for the paper — IBM Research's and the Purdue mirror Nim's `orc.nim` cites —
answered 404 on 2026-09-14, so the protocol is stated from the paper as cited
by Zend and Nim (I), and the slot width from Jalapeño's object model (I).

## Hardware

Intel documents that AVX-capable processors carry out the 16-byte memory
operations of aligned `MOVAPS`/`MOVAPD`/`MOVDQA` and their VEX.128 and
EVEX.128 forms atomically (V: SDM Vol. 3A §9.1.1 as quoted in GCC PR104688
and `portable-atomic` issue #10; PR104688's opening comment dates the SDM
change to December 2021, its "Change 13"). Before that, only `cmpxchg16b`
was architecturally atomic, though aligned 16-byte SSE was empirically atomic
on Ivy Bridge, Skylake, Piledriver and Zen 2 and never across a line split
(V: https://rigtorp.se/isatomic/). AMD extended the guarantee to naturally
aligned double-quadword loads and stores on AVX parts in November 2022 (V:
PR104688 comment 10, 2022-11-14). Arm's FEAT_LSE2 (Armv8.4) makes aligned `ldp`/`stp`
16-byte single-copy atomic (V: LLVM D109827). GCC ≥ 12's libatomic and Rust's
`portable-atomic` use these with runtime detection; no collector examined
here relies on them, and Go's 2014 record is the one design-level statement
of why.

## Comparison

| Runtime | Slot width | Concurrent reader | Mechanism |
|---|---|---|---|
| PHP Zend | 16 B, tag at +8 | no | collector on the owning thread |
| Go | 16 B, type + data | yes | data word always a pointer; GC ignores the type word |
| V8 | 1 word | yes | relaxed atomic loads; layout change = colour CAS + snapshot |
| SpiderMonkey | 8 B punboxed | no (incremental, parallel in slice) | one-word encoding |
| JavaScriptCore | 8 B NaN-encoded | yes | one-word atomic load; Structure by double read + `didRace` |
| HotSpot | 4/8 B oop | yes | one-word oop; Valhalla flattens tag+payload only if ≤ 8 B |
| .NET CoreCLR | 1 word | yes (background GC) | one-word refs found by GCDesc |
| Lua 5.4 / LuaJIT | 16 B / 8 B | no | single-threaded state |
| Ruby | 1 word | no | local GC on owner; global GC behind a barrier |
| Erlang | 1 word | no | per-process heap |
| Nim ORC | 1 word | no | collector on the mutator thread |
| Swift | 1 word | no | refcount only |
| gc-arena | — | no | token-sequenced |
| shredder | — | yes (thread) | per-object lock, conservative fallback |
| Bacon–Rajan Recycler | 1 word | yes | one-word slots, epoch handshakes |

For a two-word slot, three things are proven at scale and none of them is a
racy read of both words. Go's is the only general-purpose two-word tag+payload
slot under a truly concurrent marker: the word the collector reads is
self-describing and the tag is never consulted by the GC. Valhalla's is the
opposite bound: a tag-byte+payload unit is stored atomically only while it fits
one 8-byte instruction, and above that the runtime refuses to flatten rather
than tolerate a tear. V8's colour-CAS-plus-snapshot and JSC's double read are
proven, but for a tag that is object-level, changes rarely and lives at a
different address from the field, and both end in "discard and revisit"
rather than in a read guaranteed consistent.
