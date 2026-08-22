<?php

declare(strict_types=1);

/**
 * Walk a booted application's object graph and report what a Limelight heap
 * of it would hold: how many entities of each kind, and how many counted
 * edges per entity.
 *
 * Node A6 of model/gc/walk/questions.md splits into a store-side share, which
 * needs a compiler, and a heap-side share, which does not. This answers the
 * second: node B1 wants the share of entities that cannot sit on a cycle, and
 * node B4 wants the ratio of counted edges to entities, an edge costing the
 * walk about what an entity does.
 *
 * Usage:
 *
 *     php heap-composition.php <bootstrap.php> [label]
 *
 * The bootstrap file is included and must return one value or an array of
 * values to start from — the application container is the usual root. It runs
 * with the bootstrap file's own directory as the working directory, which is
 * what a framework's relative paths expect; set `HEAP_CHDIR` to point
 * elsewhere and the bootstrap can live outside the application it boots.
 *
 * What the figures are and are not
 * --------------------------------
 * Zend's object model is not Limelight's, and three of the differences change
 * a number rather than a word:
 *
 *  - **Objects are exact.** `spl_object_id` gives identity, so the object
 *    count and every object-to-object edge is counted once.
 *  - **Strings and arrays have no identity in PHP.** Two slots holding equal
 *    strings may be one entity or two, and the engine shares them by refcount
 *    where it can. Distinct string contents are reported as the proxy for
 *    string entities, which under-counts where a program holds equal strings
 *    separately. Arrays are counted per slot, which over-counts a shared one.
 *  - **A closure is an object here.** Limelight's entity kinds keep them
 *    apart; this scan reports the class so the share can be split later.
 *
 * The exact half — objects, their slots, and the edges between them — is the
 * half the headline figures are drawn from.
 */

/** Values that hold no reference and end a walk. */
const SCALAR_TYPES = ['integer', 'double', 'boolean', 'NULL'];

/**
 * One scan's tally.
 *
 * Slot counts are per occupied slot, so an object with three properties
 * holding the same array contributes three array slots.
 */
final class Tally
{
    /** @var array<int, true> every object seen, keyed by spl_object_id */
    public array $objects = [];
    /** @var array<string, int> objects per class name */
    public array $classes = [];
    /** @var array<string, true> distinct string contents, the proxy for string entities */
    public array $strings = [];

    public int $objectSlots = 0;
    public int $arraySlots = 0;
    public int $stringSlots = 0;
    public int $scalarSlots = 0;
    public int $otherSlots = 0;

    /** Slots examined inside an array rather than inside an object. */
    public int $arrayElements = 0;
    /** Arrays reached, counted per slot: no identity is available. */
    public int $arraysWalked = 0;
    /** Objects whose properties could not be read. */
    public int $unreadable = 0;
}

/**
 * Read every property of `$object`, private and inherited included.
 *
 * Returns an empty array for an object whose state reflection refuses —
 * an internal class with no declared properties answers that way and holds
 * nothing this scan can reach.
 *
 * @return array<string, mixed>
 */
function properties_of(object $object): array
{
    try {
        return (array) (new ReflectionObject($object))->getProperties()
            ? get_mangled_object_vars($object)
            : [];
    } catch (Throwable) {
        return [];
    }
}

/**
 * Walk everything reachable from `$roots`, filling `$tally`.
 *
 * The walk is iterative and dedupes objects by identity, so a cycle
 * terminates. Arrays carry no identity, so an array reached twice is walked
 * twice — the tally names that as `arraysWalked`.
 *
 * @param list<mixed> $roots
 */
function walk(array $roots, Tally $tally, int $maxDepth): void
{
    /** @var list<array{mixed, int}> */
    $stack = [];
    foreach ($roots as $root) {
        $stack[] = [$root, 0];
    }

    while ($stack !== []) {
        [$value, $depth] = array_pop($stack);
        if ($depth > $maxDepth) {
            continue;
        }

        if (is_object($value)) {
            $id = spl_object_id($value);
            if (isset($tally->objects[$id])) {
                continue;
            }

            $tally->objects[$id] = true;
            $class = $value::class;
            $tally->classes[$class] = ($tally->classes[$class] ?? 0) + 1;

            foreach (properties_of($value) as $slot) {
                classify($slot, $tally);
                if (is_object($slot) || is_array($slot)) {
                    $stack[] = [$slot, $depth + 1];
                }
            }

            continue;
        }

        if (is_array($value)) {
            $tally->arraysWalked++;
            foreach ($value as $element) {
                $tally->arrayElements++;
                classify($element, $tally);
                if (is_object($element) || is_array($element)) {
                    $stack[] = [$element, $depth + 1];
                }
            }
        }
    }
}

/** Count one occupied slot by what it holds. */
function classify(mixed $slot, Tally $tally): void
{
    $type = gettype($slot);
    if ($type === 'object') {
        $tally->objectSlots++;
    } elseif ($type === 'array') {
        $tally->arraySlots++;
    } elseif ($type === 'string') {
        $tally->stringSlots++;
        $tally->strings[$slot] = true;
    } elseif (in_array($type, SCALAR_TYPES, true)) {
        $tally->scalarSlots++;
    } else {
        $tally->otherSlots++;
    }
}

$bootstrap = $argv[1] ?? null;
if ($bootstrap === null || !is_file($bootstrap)) {
    fwrite(STDERR, "usage: php heap-composition.php <bootstrap.php> [label]\n");
    exit(1);
}

$label = $argv[2] ?? basename(dirname(realpath($bootstrap)));
$maxDepth = (int) (getenv('HEAP_MAX_DEPTH') ?: 64);

chdir(getenv('HEAP_CHDIR') ?: dirname(realpath($bootstrap)));
$roots = require realpath($bootstrap);
$roots = is_array($roots) ? $roots : [$roots];

$tally = new Tally();
walk($roots, $tally, $maxDepth);

$objects = count($tally->objects);
$strings = count($tally->strings);
$countedSlots = $tally->objectSlots + $tally->arraySlots + $tally->stringSlots;
$ringCapableSlots = $tally->objectSlots + $tally->arraySlots;

$share = static fn (int $part, int $whole): string
    => $whole === 0 ? 'n/a' : sprintf('%.1f %%', 100.0 * $part / $whole);

printf("heap_composition label=%s max_depth=%d\n", $label, $maxDepth);
printf("  objects (exact)         %d in %d classes\n", $objects, count($tally->classes));
printf("  distinct strings (proxy) %d\n", $strings);
printf("  arrays walked (per slot) %d, elements %d\n", $tally->arraysWalked, $tally->arrayElements);
printf(
    "  counted slots            %d — object %d, array %d, string %d\n",
    $countedSlots,
    $tally->objectSlots,
    $tally->arraySlots,
    $tally->stringSlots
);
printf("  scalar slots             %d, other %d\n", $tally->scalarSlots, $tally->otherSlots);
printf(
    "  leaf share of slots      %s (a string cannot sit on a ring)\n",
    $share($tally->stringSlots, $countedSlots)
);
printf(
    "  ring-capable slots       %s\n",
    $share($ringCapableSlots, $countedSlots)
);
printf(
    "  counted edges per object %.2f (every counted slot over the exact object count)\n",
    $objects === 0 ? 0.0 : $countedSlots / $objects
);
printf(
    "  object-to-object edges   %d, %.2f per object\n",
    $tally->objectSlots,
    $objects === 0 ? 0.0 : $tally->objectSlots / $objects
);

$top = $tally->classes;
arsort($top);
printf("  top classes             ");
foreach (array_slice($top, 0, 5, true) as $class => $n) {
    printf("%s=%d ", $class, $n);
}
printf("\n");
