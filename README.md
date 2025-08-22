# Bench

A cross-language micro-benchmark that measures

1. throughput (milliseconds) and
2. memory footprint (RSS)

of **concurrent map / hash-table** implementations in ten runtimes:

| Go | Node.js (Worker Threads) | Deno | Bun | Java | .NET (C#) | Python | PHP | Rust | C++ |
|----|--------------------------|------|-----|------|-----------|--------|-----|------|-----|

Bench builds the binaries, runs each variant several times, stores every run as JSON and finally emits a Markdown
table with the median numbers.

***

## 1 . Requirements

* Bash 4, `jq`, `git`
* A *Unix-like* OS (RSS helper reads `/proc/self/statm`; works on Linux & WSL)
* Language tool-chains (only the ones you want to test)

```text
Go 1.18+        node 18+        deno 2.x        bun 1.x
JDK 11+         dotnet 6+       Python 3.8+     PHP 8.0+
Rust 1.70+      g++ 10+ (C++20)
```

Optional

* `cpupower` – fix CPU frequency for stable numbers
* `psutil` (`pip install psutil`) – better Python RSS
* `php-pear` → `pecl` – to compile `parallel` extension  
  (otherwise PHP silently falls back to single-threaded mode)

***

## 2 . Quick start

```bash
# clone and enter
git clone https://github.com/McMelonTV/bench.git
cd bench

# install AUR helpers on Arch (example)
sudo pacman -S --needed jq go nodejs deno rust gcc git

# first run (uses defaults: 8 threads, 2 M ops, 5 repeats)
./bench.sh
```

During the first run the script:

1. Detects which runtimes + source files are present
2. Shows a confirmation screen
3. Builds each runtime (fails are reported & can be skipped)
4. Executes every model `REPEATS` times
5. Writes:
    * `_out/all_runs.jsonl`   – raw per-run data
    * `_out/aggregate.json`  – medians per variant
    * `_summary.md`          – ready-to-paste Markdown table

***

## 3 . Configuration

You can override every parameter via env var or CLI:

```bash
THREADS=32 ITERATIONS=10000000 REPEATS=3 ./bench.sh
```

| Variable   | Default       | Meaning                                 |
|------------|---------------|-----------------------------------------|
| THREADS    | 8             | OS threads / workers                    |
| ITERATIONS | 2 000 000     | total map operations per run            |
| KEYS       | 100 000       | key-space size                          |
| READ_RATIO | 0.9           | fraction of reads (the rest are writes) |
| SEED       | 42            | RNG seed                                |
| REPEATS    | 5             | identical runs per runtime/model        |
| OUTDIR     | `_out`        | build & result folder                   |
| TABLE_OUT  | `_summary.md` | Markdown result table                   |

***

## 4 . Benchmarked models

| Runtime | Models (folder)          | Notes                                   |
|---------|--------------------------|-----------------------------------------|
| Go      | `syncmap`, `sharded`     | stdlib sync.Map vs. N-shard map + mutex |
| Node    | `worker_threads`         | eight workers, sharded Map per worker   |
| Deno    | `worker`                 | worker API; same algo as Node           |
| Bun     | `worker_threads`         | Bun’s worker implementation             |
| Java    | `threadpool`, `forkjoin` | FixedThreadPool vs. ForkJoinPool        |
| C#      | `tasks`, `parallel`      | Task pool vs. `Parallel.For`            |
| Python  | `threads`, `processes`   | GIL-bound threads vs. `multiprocessing` |
| PHP     | `parallel`, `single`     | `pecl parallel` vs. single thread       |
| Rust    | `threads-sharded`        | DashMap-like N-shard mutex map          |
| C++     | `threads-sharded`        | `std::unordered_map` + N mutex shards   |

***

## 5 . Adding a new runtime / model

1. Drop your source in a new folder, keep the CLI flags consistent  
   (`--model name --threads N --iterations N …` and JSON stdout).
2. Add a `build_<lang>()` and `run_<lang>()` function in `bench.sh`.
3. Append the model list at the top (`LANG_MODELS=( ...)`).

The harness will pick it up automatically if the runtime and file exist.

***

## 6 . Known caveats

* RSS on **macOS** / **Windows**: values will be the VM size, not true RSS.
* PHP `parallel` needs a ZTS build; otherwise it silently falls back.
* Deno 2 removed `--allow-hrtime`; the script already omits it.
* Node BigInt warning fixed in `node/bench.js` ≥ 24.6.

***

## 7 . Disclaimer

Most of this software is written by AI, including this README, excluding this disclaimer. The specific model used was
Claude Sonnet 4.0 Thinking through Perplexity.
