<?php
/**
 * linkcheck — verify every internal cross-reference in the RFC resolves.
 *
 * The RFC is a web of documents that link to each other constantly. A link
 * that points at a moved or misspelled path still renders as a link, so it
 * rots silently: nothing fails, the reader just lands nowhere. This checks
 * both halves of a reference — the file and the #anchor — against reality.
 *
 * Usage:
 *   php dev/tools/linkcheck.php [root]
 *
 *   root  directory to scan, default: the repository root (this file's
 *         grandparent). Pass a path to check a subtree.
 *
 * Exit status:
 *   0  every internal link resolves
 *   1  at least one link is broken (suitable for a pre-push check)
 *
 * What it checks:
 *   - relative links between markdown files, including ../ hops;
 *   - #anchors, matched against the target document's own headings using
 *     GitHub's slug rules, including the -1/-2 suffixes GitHub adds to
 *     repeated headings;
 *   - links inside fenced code blocks are ignored, since those are samples.
 *
 * What it does not check: external http(s) links. They need the network and
 * they fail for reasons that are not ours.
 */

declare(strict_types=1);

$root = $argv[1] ?? dirname(__DIR__, 2);
$root = rtrim(str_replace('\\', '/', $root), '/');

if (!is_dir($root)) {
    fwrite(STDERR, "not a directory: $root\n");
    exit(2);
}

/** Blank out fenced code blocks, keeping line count stable. */
function stripFences(string $text): string
{
    $out = [];
    $inFence = false;
    foreach (explode("\n", $text) as $line) {
        if (str_starts_with(ltrim($line), '```')) {
            $inFence = !$inFence;
            $out[] = '';
            continue;
        }
        $out[] = $inFence ? '' : $line;
    }
    return implode("\n", $out);
}

/** GitHub's heading-to-anchor slug. */
function slug(string $text): string
{
    $t = mb_strtolower(trim($text));
    $t = preg_replace('/`([^`]*)`/u', '$1', $t);            // inline code
    $t = preg_replace('/\[([^\]]*)\]\([^)]*\)/u', '$1', $t); // links -> text
    $t = preg_replace('/[*_~]/u', '', $t);
    $t = preg_replace('/[^\p{L}\p{N}\- ]/u', '', $t);
    return str_replace(' ', '-', $t);
}

/** Resolve a relative path without touching the filesystem. */
function normalize(string $path): string
{
    $path = str_replace('\\', '/', $path);
    $parts = [];
    foreach (explode('/', $path) as $part) {
        if ($part === '' || $part === '.') {
            continue;
        }
        if ($part === '..') {
            array_pop($parts);
            continue;
        }
        $parts[] = $part;
    }
    $prefix = str_starts_with($path, '/') ? '/' : '';
    return $prefix . implode('/', $parts);
}

// ---------------------------------------------------------------- collect
$files = [];
$it = new RecursiveIteratorIterator(
    new RecursiveCallbackFilterIterator(
        new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS),
        static fn($current) => $current->getFilename() !== '.git'
    )
);
foreach ($it as $file) {
    if ($file->isFile() && strtolower($file->getExtension()) === 'md') {
        $path = normalize(str_replace('\\', '/', $file->getPathname()));
        $files[$path] = (string) file_get_contents($file->getPathname());
    }
}

// Anchors each document offers.
$anchors = [];
foreach ($files as $path => $text) {
    $seen = [];
    $set = [];
    preg_match_all('/^(#{1,6})\s+(.*?)\s*$/m', stripFences($text), $m);
    foreach ($m[2] as $heading) {
        $s = slug($heading);
        $n = $seen[$s] ?? 0;
        $set[$n === 0 ? $s : "$s-$n"] = true;
        $seen[$s] = $n + 1;
    }
    $anchors[$path] = $set;
}

// ------------------------------------------------------------------ check
$brokenFiles = [];
$brokenAnchors = [];
$checked = 0;

foreach ($files as $path => $text) {
    preg_match_all('/\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/', stripFences($text), $m,
        PREG_SET_ORDER);
    foreach ($m as $link) {
        $target = $link[2];
        if (preg_match('#^(https?:|mailto:)#i', $target)) {
            continue;
        }
        $checked++;
        [$file, $frag] = array_pad(explode('#', $target, 2), 2, null);

        $resolved = $file === ''
            ? $path
            : normalize(dirname($path) . '/' . $file);

        $where = ltrim(substr($path, strlen($root)), '/');

        if (!file_exists($resolved)) {
            $brokenFiles["$where -> $target"] = true;
            continue;
        }
        if ($frag !== null && $frag !== '' && isset($anchors[$resolved])
            && !isset($anchors[$resolved][mb_strtolower($frag)])) {
            $brokenAnchors["$where -> $target"] = true;
        }
    }
}

// ----------------------------------------------------------------- report
printf("markdown files:          %d\n", count($files));
printf("internal links checked:  %d\n", $checked);

printf("\nBROKEN FILE TARGETS: %d\n", count($brokenFiles));
foreach (array_keys($brokenFiles) as $line) {
    echo "  $line\n";
}

printf("\nBROKEN ANCHORS: %d\n", count($brokenAnchors));
foreach (array_keys($brokenAnchors) as $line) {
    echo "  $line\n";
}

exit(count($brokenFiles) + count($brokenAnchors) > 0 ? 1 : 0);
