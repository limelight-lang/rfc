<?php

/**
 * The state `heap-composition.php` scans: a booted Laravel application that
 * has handled one request.
 *
 * "Booted" alone does not name a state a figure can be re-taken from — the
 * same tree gives 44 objects with no bootstrappers run and 327 with the
 * kernel's — so this file is the recipe, checked in beside the instrument and
 * cited by every figure taken through it (node A6 of
 * ../../model/gc/walk/questions.md).
 *
 * What it produces: every service provider registered and booted, and one GET
 * of the health route `/up` routed, dispatched and terminated. The health
 * route is the request of record because `bootstrap/app.php` declares it, so
 * it needs no database, no session and no authenticated user.
 *
 * Usage, with the application outside this repository:
 *
 *   HEAP_APP=/path/to/app HEAP_CHDIR=/path/to/app \
 *       php heap-composition.php heap-bootstrap-laravel.php <label>
 *
 * HEAP_APP names the application root; without it the current directory is
 * used, which is what HEAP_CHDIR has already set.
 */

$root = getenv('HEAP_APP') ?: getcwd();

require $root . '/vendor/autoload.php';

/** @var \Illuminate\Foundation\Application $app */
$app = require $root . '/bootstrap/app.php';

$kernel = $app->make(\Illuminate\Contracts\Http\Kernel::class);

$request = \Illuminate\Http\Request::create('/up', 'GET');
$response = $kernel->handle($request);
$kernel->terminate($request, $response);

return $app;
