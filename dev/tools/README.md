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
question. The nodes that asked it — A6, with B1 wanting the share of entities
that cannot sit on a cycle and B4 the edge-to-entity ratio — were the walk's,
and went with its question graph on 2026-08-26; `rc-cycle` asks the same three
of the same instrument.

```
HEAP_CHDIR=/path/to/app php heap-composition.php bootstrap.php label
```

The bootstrap file returns one value or a list of values to walk from — an
application container is the usual root — and `HEAP_CHDIR` lets it live
outside the application it boots, so nothing is written into the scanned
project. `HEAP_MAX_DEPTH` bounds the walk, 64 by default.

**The bootstrap is `heap-bootstrap-laravel.php`, beside this file.** It boots
the application and handles one GET of the health route `/up`, and every
figure taken through it cites it. Pass it by absolute path: `HEAP_CHDIR`
changes directory before the bootstrap is resolved.

**A figure whose bootstrap is not written down can be read and not re-taken**,
which is why that file exists. "Booted" names no state a number comes back
from — the same tree gives 44 objects with no bootstrappers run and 327 with
the kernel's, against A6's recorded 507 — and the re-run of 2026-08-24 wrote
down no bootstrap either: four plausible ones give 373 to 378 objects where it
recorded 387, on a tree untouched since 2026-07-02. The corpus is
`~/laravel-spawn-example`, outside this repository, a Laravel `^13.0`
application with an async adapter and four extra provider trees rather than a
skeleton.

**Read the file's own header before quoting a figure.** Object identity is
exact; strings and arrays carry no identity in PHP, so the string count is a
proxy that under-counts and the array count is per slot and over-counts.
Which way each error runs is what decides whether a figure is a floor or a
ceiling.

**Two populations the walk of `ll-model` counts and this scan does not**,
found by review 2026-08-25 and printed as their own rows since. A hash entry's
string key is a counted child beside the value, and the scan classifies
values: the `string keys` row is the edges the slot rows omit and the key
contents seen nowhere else are the string entities they omit. And an object
whose state reflection cannot read — every closure, and any internal class
with no declared properties — contributes a row and no edges, which the
`state not read` row counts; that one is a floor with no bound, since what
those objects hold is unreachable rather than absent.
