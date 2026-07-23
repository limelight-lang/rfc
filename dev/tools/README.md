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
