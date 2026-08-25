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
 * The heap's size classes, in bytes, copied from `ll-model`
 * `src/memory/heap.rs`. The smallest class at or above a request is the one
 * used; a request past the last goes to the large-entity path.
 */
const SIZE_CLASSES = [
    16, 32, 48, 64, 80, 96, 112, 128,
    160, 192, 224, 256,
    320, 384, 448, 512,
    640, 768, 896, 1024,
    1280, 1536, 1792, 2048,
    2560, 3072, 3584, 4096,
    5120, 6144, 7168, 8192,
];

/** A block of the pooled heap, from the same file. */
const BLOCK_BYTES = 64 * 1024;

/**
 * Header plus class word: what an object carries before its properties.
 *
 * An object is this plus one 16-byte slot per property (`ll-model`
 * `src/object.rs`), quoted here so the size-class arithmetic below is
 * checkable against the layout rather than guessed.
 */
const OBJECT_PREFIX = 16;

/**
 * What an inline string carries before its bytes: the 8-byte header, the
 * 4-byte length, four bytes of padding and the 8-byte hash (`ll-model`
 * `src/string.rs`, `struct LLString`). A string has no class word, so this
 * is not the object prefix.
 */
const STRING_PREFIX = 24;

/**
 * The largest request the small-slot heap serves (`ll-model`
 * `src/memory/heap.rs`, `MAX_SMALL`), and so the point where a string takes
 * the out-of-line layout: a payload allocated through the buffer machinery
 * beside a 32-byte slot (`src/string.rs`, `placement`).
 */
const MAX_SMALL = 8192;

/**
 * The entity slot an out-of-line string keeps: header, length, padding, hash
 * and the pointer to the payload (`ll-model` `src/string.rs`, `placement`).
 * Past [`MAX_SMALL`] this is what lands in a size class, the bytes going to a
 * record of their own.
 */
const OUT_OF_LINE_SLOT = 32;

/** The size class a request of `$bytes` lands in, or null past the last. */
function size_class(int $bytes): ?int
{
    foreach (SIZE_CLASSES as $class) {
        if ($bytes <= $class) {
            return $class;
        }
    }

    return null;
}

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

    /**
     * Arrays holding at least one element, which are the ones whose storage
     * is a second allocation: an empty vector allocates none (`ll-model`
     * `src/array/vector.rs`), and storage is freed through `body_free`
     * rather than with the entity slot.
     */
    public int $nonEmptyArrays = 0;

    /**
     * Distinct strings past [`MAX_SMALL`], which take the out-of-line
     * layout and so park a payload record beside the entity slot.
     */
    public int $outOfLineStrings = 0;
    /**
     * Objects this walk reads no state from: `properties_of` returned an
     * empty array, so the object contributes a row and no edges. An
     * internal class with no declared properties answers that way, and so
     * does every closure — see [`Tally::$closures`].
     */
    public int $unreadable = 0;

    /**
     * Closures met, all of them walked through [`closure_state`]. Limelight
     * keeps a closure as its own entity kind, and the size class recorded for
     * one here is an object's of the same slot count, which is an
     * approximation rather than that kind's layout.
     */
    public int $closures = 0;

    /**
     * String keys of array entries, counted per entry. The walk of
     * `ll-model` counts a hash entry's string key as a counted child
     * beside the value (node B4), and the slot rows above count values
     * only, so this bounds the edges those rows omit.
     */
    public int $stringKeys = 0;

    /** @var array<string, true> distinct string-key contents */
    public array $keyStrings = [];

    /**
     * Objects per slot count, which is what picks an object's size class:
     * a header, a class word and one slot per property.
     *
     * @var array<int, int>
     */
    public array $slotCounts = [];

    /**
     * Size classes each entity kind lands in, as kind => class => count.
     * What node B6 prices: segregating blocks by kind needs a tail block
     * per pair that is in use, where today one class shares one.
     *
     * @var array<string, array<int, int>>
     */
    public array $classesByKind = [];
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
    if ($object instanceof Closure) {
        return closure_state($object);
    }

    try {
        return (array) (new ReflectionObject($object))->getProperties()
            ? get_mangled_object_vars($object)
            : [];
    } catch (Throwable) {
        return [];
    }
}

/**
 * The state a closure holds: its `use` captures and its bound `$this`.
 *
 * A closure has no property table, so `get_mangled_object_vars` returns
 * nothing for one and reflection over properties reads none of this. Half the
 * objects of a booted framework container are closures, and their captures
 * routinely hold arrays and strings reachable through nothing else, so
 * without this the scan reports them as leaves and loses whatever they hold.
 *
 * The scope class is a class rather than a value, so it is not a counted slot
 * and is not returned.
 *
 * @return array<string, mixed>
 */
function closure_state(Closure $closure): array
{
    try {
        $reflection = new ReflectionFunction($closure);
    } catch (Throwable) {
        return [];
    }

    $state = $reflection->getClosureUsedVariables();
    $bound = $reflection->getClosureThis();
    if ($bound !== null) {
        $state['this'] = $bound;
    }

    return $state;
}

/**
 * Give every string key its size class, once per distinct content.
 *
 * `classify` records a class for the strings it meets in slots, and a key is
 * not a slot it is called on, so without this pass the string half of
 * `classesByKind` covers value strings alone — while the key strings count
 * as entities everywhere else. Run after the walk and before anything reads
 * the histogram.
 */
function fold_key_strings(Tally $tally): void
{
    foreach ($tally->keyStrings as $key => $_) {
        if (isset($tally->strings[$key])) {
            continue;
        }

        note_string_layout($tally, STRING_PREFIX + strlen((string) $key));
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

            if ($value instanceof Closure) {
                $tally->closures++;
            }

            $declared = properties_of($value);
            $count = count($declared);
            if ($declared === []) {
                $tally->unreadable++;
            }

            $tally->slotCounts[$count] = ($tally->slotCounts[$count] ?? 0) + 1;
            record_class($tally, 'object', OBJECT_PREFIX + 16 * $count);
            foreach ($declared as $slot) {
                classify($slot, $tally);
                if (is_object($slot) || is_array($slot)) {
                    $stack[] = [$slot, $depth + 1];
                }
            }

            continue;
        }

        if (is_array($value)) {
            $tally->arraysWalked++;
            if ($value !== []) {
                $tally->nonEmptyArrays++;
            }

            foreach ($value as $key => $element) {
                $tally->arrayElements++;
                if (is_string($key)) {
                    $tally->stringKeys++;
                    $tally->keyStrings[$key] = true;
                }

                classify($element, $tally);
                if (is_object($element) || is_array($element)) {
                    $stack[] = [$element, $depth + 1];
                }
            }
        }
    }
}

/** Record which size class one entity of `$kind` lands in. */
function record_class(Tally $tally, string $kind, int $bytes): void
{
    $class = size_class($bytes);
    if ($class === null) {
        return;
    }

    $tally->classesByKind[$kind][$class] = ($tally->classesByKind[$kind][$class] ?? 0) + 1;
}

/**
 * Record the entity slot a string of `$bytes` takes, and count the payload it
 * parks if there is one.
 *
 * A string past [`MAX_SMALL`] keeps a fixed slot and moves its bytes to a
 * record beside it, so it is the slot and not the whole string that picks the
 * size class — a draft recorded neither, `record_class` returning early on a
 * request past the last class.
 */
function note_string_layout(Tally $tally, int $bytes): void
{
    if ($bytes > MAX_SMALL) {
        $tally->outOfLineStrings++;
        record_class($tally, 'string', OUT_OF_LINE_SLOT);

        return;
    }

    record_class($tally, 'string', $bytes);
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
        if (!isset($tally->strings[$slot])) {
            $tally->strings[$slot] = true;
            note_string_layout($tally, STRING_PREFIX + strlen($slot));
        }
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
fold_key_strings($tally);

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
// A dying entity parks its own slot; a non-empty array parks its storage and
// an out-of-line string parks its payload as headerless records beside it.
// Only a record with a header can carry an epoch byte, so the entity share of
// all parked records bounds what the young-free exemption can remove (node C2
// of model/gc/walk/questions.md).
$entities = $objects + $strings + $tally->arraysWalked;
$companions = $tally->nonEmptyArrays + $tally->outOfLineStrings;
printf(
    "  headerless companions    %d — non-empty arrays %d, out-of-line strings %d, %.2f per entity\n",
    $companions,
    $tally->nonEmptyArrays,
    $tally->outOfLineStrings,
    $entities === 0 ? 0.0 : $companions / $entities
);
printf(
    "  entity share of records  %s — what bounds the exemption\n",
    $share($entities, $entities + $companions)
);
printf(
    "  counted edges per object %.2f (every counted slot over the exact object count)\n",
    $objects === 0 ? 0.0 : $countedSlots / $objects
);
printf(
    "  object-valued slots      %d, %.2f per object (an array cell counts here too)\n",
    $tally->objectSlots,
    $objects === 0 ? 0.0 : $tally->objectSlots / $objects
);
// The rows above count values only. A hash entry's string key is a counted
// child of the array in `ll-model`'s walk (node B4), so the key count is the
// edges those rows omit, and the key strings absent from `strings` are the
// string entities they omit.
$newKeyStrings = count(array_diff_key($tally->keyStrings, $tally->strings));
printf(
    "  string keys              %d, %d distinct, %d of them counted nowhere above\n",
    $tally->stringKeys,
    count($tally->keyStrings),
    $newKeyStrings
);
// A row with no edges is a floor, not a leaf: what the object holds may be
// unreadable rather than absent. A closure's state is read through
// `closure_state`, so it is counted here as walked rather than as missing.
printf(
    "  state not read           %d objects; closures walked %d\n",
    $tally->unreadable,
    $tally->closures
);

// The size class an object lands in follows from its slot count, so the
// spread of slot counts bounds how many classes a kind-segregated heap
// would need a tail block for (node B6).
$slots = $tally->slotCounts;
ksort($slots);
$distinct = count($slots);
$widest = $distinct === 0 ? 0 : max(array_keys($slots));
printf(
    "  object slot counts       %d distinct, widest %d, spread %s\n",
    $distinct,
    $widest,
    implode(
        ' ',
        array_map(
            static fn (int $n, int $count): string => "{$n}:{$count}",
            array_keys($slots),
            array_values($slots)
        )
    )
);

// Node B6: segregating entity blocks by kind needs one partly-filled tail
// block per pair of size class and kind that is in use, where today the
// kinds sharing a class share its tail. The extra is therefore the pairs
// beyond the first in each class.
$pairs = 0;
$classesInUse = [];
foreach ($tally->classesByKind as $kind => $classes) {
    foreach (array_keys($classes) as $class) {
        $pairs++;
        $classesInUse[$class] = true;
    }
}

$extraTails = $pairs - count($classesInUse);
printf(
    "  size classes in use      %d over %d kind pairs — %d extra tail blocks, %.1f MiB\n",
    count($classesInUse),
    $pairs,
    $extraTails,
    $extraTails * BLOCK_BYTES / 1048576
);
foreach ($tally->classesByKind as $kind => $classes) {
    ksort($classes);
    printf("    %-7s %s\n", $kind, implode(' ', array_keys($classes)));
}

$top = $tally->classes;
arsort($top);
printf("  top classes             ");
foreach (array_slice($top, 0, 5, true) as $class => $n) {
    printf("%s=%d ", $class, $n);
}
printf("\n");
