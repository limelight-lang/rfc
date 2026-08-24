# dev/tools — repository utilities

Small helpers for maintaining the RFC itself. They are tooling, never part
of any product; nothing here is on a build path.

## `linkcheck.php`

Verifies that every internal cross-reference in the RFC resolves — both the
file a link points at and the `#anchor` inside it.

```sh
php dev/tools/linkcheck.php          # scan the whole repository
php dev/tools/linkcheck.php model    # scan one subtree
```

Output is a count of files and links checked, then any broken targets and
broken anchors with the file each was found in. Exit status is `0` when
everything resolves and `1` when anything is broken, so it can gate a
commit or run in CI.

**When to run it.** Any time a document is renamed, moved, split, or has a
heading reworded, and before pushing a change that touches links. A heading
edit is the easy one to forget: the link still renders, it just stops
landing anywhere.

**What it covers.** Relative links between markdown files including `../`
hops; `#anchors` matched against the target's headings by GitHub's slug
rules, including the `-1`/`-2` suffixes GitHub appends to repeated
headings; links inside fenced code blocks are ignored, since those are
samples rather than references.

**What it does not cover.** External `http(s)` links — they need the
network and break for reasons outside this repository.

**Why a script and not an off-the-shelf checker.** The ready-made tools
(`lychee`, `markdown-link-check`) each pull in a Rust or Node toolchain,
and their anchor handling does not match GitHub's slug rules exactly, which
is precisely the half that rots quietly here. This is ~150 lines with no
dependency beyond the PHP already required to work on this project.

## `heap-composition.php`

Walks a booted application's object graph and reports what a Limelight heap
of it would hold: entities by kind, counted slots by what they hold, and the
counted edges per entity. It answers the heap-side half of the corpus
question — node A6 of
[../../model/gc/walk/questions.md](../../model/gc/walk/questions.md), with
node B1 wanting the share of entities that cannot sit on a cycle and node B4
the edge-to-entity ratio.

```
HEAP_CHDIR=/path/to/app php heap-composition.php bootstrap.php label
```

The bootstrap file returns one value or a list of values to walk from — an
application container is the usual root — and `HEAP_CHDIR` lets it live
outside the application it boots, so nothing is written into the scanned
project. `HEAP_MAX_DEPTH` bounds the walk, 64 by default.

**Record the bootstrap beside the figures.** "Booted" is not a state a
number can be re-taken from: the same Laravel tree gives 44 objects with no
bootstrappers run, 327 with the kernel's, and 387 after one handled request.
A6's booted column of 2026-08-22 reads 507 and no bootstrap was written down
with it, so it can be read and not reproduced (2026-08-24). The corpus those
figures came from is `~/laravel-spawn-example`, outside this repository.

**Read the file's own header before quoting a figure.** Objects and the
edges between them are exact; strings and arrays carry no identity in PHP,
so the string count is a proxy that under-counts and the array count is per
slot and over-counts. Which way each error runs is what decides whether a
figure is a floor or a ceiling.
