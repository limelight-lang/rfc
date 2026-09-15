# Chained single-producer single-consumer queues: what deployed code does

A survey of 2026-09-15, made for the ruling "the candidate queue is read behind
its writer, and the collector's verdicts come back by a second ring"
(`DECISIONS.md`). Every line below was read from the named source that day;
the excerpts and URLs are in the session's research report, and the table is
what the ruling rests on. The reference form the crate adopts is moodycamel's
`ReaderWriterQueue` (a copy stands in `~/true-async-server/deps/concurrentqueue/`).

| Queue | Form | Who allocates / frees | Consumer detects a segment's end | Producer per push | Consumer per pop | Second consumer |
|---|---|---|---|---|---|---|
| Vyukov unbounded SPSC (1024cores; ports: old Rust std `spsc_queue.rs`, Concurrency Kit `ck_fifo_spsc`) | chain, one value per node | producer allocates; nothing freed — the producer recycles nodes behind a stale copy of the consumer's cursor | null `next` | one release store of the link; x86-64 plain stores and a compiler fence, ARM64 `stlr` / `dmb ishst` | one acquire load and one release store of the cursor | no |
| FastFlow `uSWSR_Ptr_Buffer` | chain of bounded rings, slot `NULL` = empty | producer mallocs or pops a cache; consumer resets and pushes drained rings into a reversed SPSC ring `bufcache`, frees on its overflow | slot empty, `buf_r != buf_w`, slot empty again, then pop the next ring from a third SPSC list | `WMB` before the slot store (x86 none, ARM `dmb st`) | none on the fast path | no |
| folly `USPSCQueue` | chain of 256-entry segments, tickets | producer allocates one segment ahead; consumer deletes once the producer's `tail` left it | ticket arithmetic, then wait for `tail` to leave, acquire load of `next` | one release store per entry flag, own ticket; per segment a CAS on `next` and a release store of `tail` | one acquire load per flag; per segment an acquire load of `tail` | no |
| moodycamel `ReaderWriterQueue` | circular list of blocks, doubling | producer mallocs; nothing freed; a block is reused when `tailBlock->next != frontBlock` | `front == tail` and `frontBlock != tailBlock`, double-checked | relaxed store behind a release fence (x86 compiler-only; ARM64 `dmb ish`) | acquire fence and relaxed load; release fence and store | no |
| crossbeam-channel list (MPMC) | chain of 31-slot blocks | producer allocates one slot early; the reader of the last slot frees, DESTROY/READ bits | offset arithmetic; spin on `next` | a CAS and a `fetch_or` | a fence, a CAS, an acquire load, a `fetch_or` | yes |
| tokio mpsc list (MPSC) | chain of 32-slot blocks | producer allocates; consumer re-links a drained block at the chain's end by CAS, else frees | `load_next` null; a RELEASED bit | a `fetch_add` and a `fetch_or` | one acquire load; up to three CAS per block returned | no |
| rtrb, ringbuf, Linux circular buffer, kfifo | bounded ring | — | index compare | one release store (kfifo `smp_wmb`) | one release store, an acquire load when the cached copy is stale | no |

**What the table settles for the ruling.** Every chained design allocates on
the producer's thread and every one runs the consumer elsewhere; they differ
only in how a consumed segment comes back — never handed back (Vyukov,
moodycamel: the producer reaches it again), a reversed SPSC channel
(FastFlow), freed by the consumer once the producer has provably left it
(folly, crossbeam), or re-linked at the chain's end by the consumer (tokio).
The crate takes moodycamel's circle, whose return protocol is the one test
`tailBlock->next != frontBlock`, over pool blocks the owner draws and never
frees to the other side. One difference from the reference is deliberate: the
reference orders by `atomic_thread_fence` around relaxed accesses, which on
ARM64 costs a `dmb ish` per push; the crate orders by release stores and
acquire loads on the index words (rtrb's spelling), which is `stlr`/`ldar`
there and the same plain `mov` on x86-64.
