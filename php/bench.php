<?php
// php -dextension=parallel.so bench.php --model=parallel
function parse_args($argv)
{
    $opts = ["threads" => 8, "iterations" => 2000000, "keys" => 100000, "read_ratio" => 0.9, "seed" => 42, "model" => "parallel", "shards" => 64];
    for ($i = 1; $i < count($argv); $i += 2) {
        $k = ltrim($argv[$i], "-");
        $v = $argv[$i + 1] ?? null;
        if ($v === null) break;
        if ($k === "threads") $opts["threads"] = (int)$v;
        else if ($k === "iterations") $opts["iterations"] = (int)$v;
        else if ($k === "keys") $opts["keys"] = (int)$v;
        else if ($k === "read-ratio") $opts["read_ratio"] = (float)$v;
        else if ($k === "seed") $opts["seed"] = (int)$v;
        else if ($k === "model") $opts["model"] = $v;
    }
    return $opts;
}

function rss_bytes()
{
    if (function_exists("memory_get_usage")) return memory_get_usage(true);
    return 0;
}

function splitmix64_next($state)
{
    $x = ($state + 0x9E3779B97F4A7C15) & ((1 << 63) - 1);
    $z = $x;
    $z = ($z ^ ($z >> 30)) * 0xBF58476D1CE4E5B9;
    $z = ($z ^ ($z >> 27)) * 0x94D049BB133111EB;
    $z = $z ^ ($z >> 31);
    return [$z & ((1 << 63) - 1), $z & ((1 << 63) - 1)];
}

$opts = parse_args($argv);
$threads = $opts["threads"];
$per = intdiv($opts["iterations"], $threads);
$start = hrtime(true);

if ($opts["model"] === "parallel" && extension_loaded("parallel")) {
    $routines = [];
    for ($i = 0; $i < $threads; $i++) {
        $id = $i;
        $keys = $opts["keys"];
        $reads = intval($opts["read_ratio"] * 1000);
        $seed = $opts["seed"];
        $iters = $per;
        $routines[] = new parallel\Runtime();
        $routines[$i]->run(function ($id, $iters, $keys, $reads, $seed) {
            $m = [];
            for ($k = 0; $k < $keys; $k++) $m[$k] = 0;
            $state = $seed + $id;
            for ($i = 0; $i < $iters; $i++) {
                // cheap LCG fallback in PHP
                $state = ($state * 1103515245 + 12345) & 0x7fffffff;
                $k = $state % $keys;
                $state = ($state * 1103515245 + 12345) & 0x7fffffff;
                $r = $state % 1000;
                if ($r < $reads) {
                    $_ = $m[$k];
                } else {
                    $m[$k] = ($m[$k] ?? 0) + 1;
                }
            }
            return true;
        }, [$id, $per, $keys, $reads, $seed]);
    }
    foreach ($routines as $rt) {
        $rt->close();
    }
} else {
    // single-thread baseline
    $m = [];
    for ($k = 0; $k < $opts["keys"]; $k++) $m[$k] = 0;
    $state = $opts["seed"];
    $reads = intval($opts["read_ratio"] * 1000);
    for ($i = 0; $i < $opts["iterations"]; $i++) {
        $state = ($state * 1103515245 + 12345) & 0x7fffffff;
        $k = $state % $opts["keys"];
        $state = ($state * 1103515245 + 12345) & 0x7fffffff;
        $r = $state % 1000;
        if ($r < $reads) $_ = $m[$k]; else $m[$k] = ($m[$k] ?? 0) + 1;
    }
}
$dur = intdiv(hrtime(true) - $start, 1_000_000);
echo json_encode([
    "runtime" => "php" . PHP_VERSION,
    "model" => $opts["model"],
    "threads" => $threads,
    "iterations" => $per * $threads,
    "keys" => $opts["keys"],
    "read_ratio" => $opts["read_ratio"],
    "seed" => $opts["seed"],
    "duration_ms" => $dur,
    "rss_bytes" => rss_bytes()
]), PHP_EOL;
