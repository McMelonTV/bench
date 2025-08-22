import {isMainThread, parentPort, Worker, workerData} from "worker_threads";

function parseArgs() {
    const args = process.argv.slice(2);
    const opts = {threads: 8, iterations: 2000000, keys: 100000, readRatio: 0.9, seed: 42n, model: 'worker'};
    for (let i = 0; i < args.length; i++) {
        const [k, v] = args[i].startsWith("--") ? args[i].slice(2).split("=") : [args[i], args[i + 1]];
        if (!v) continue;
        if (k === "threads") opts.threads = +v;
        if (k === "iterations") opts.iterations = +v;
        if (k === "keys") opts.keys = +v;
        if (k === "read-ratio") opts.readRatio = +v;
        if (k === "seed") opts.seed = BigInt(v);
        if (k === "model") opts.model = v;
    }
    return opts;
}

function rand64(seed) {
    let x = seed;
    return () => {
        x = (x + 0x9E3779B97f4A7C15n) & ((1n << 64n) - 1n);
        let z = x;
        z = (z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n & ((1n << 64n) - 1n);
        z = (z ^ (z >> 27n)) * 0x94D049BB133111EBn & ((1n << 64n) - 1n);
        z = z ^ (z >> 31n);
        return z;
    };
}

async function main() {
    const opts = parseArgs();
    const per = Math.floor(opts.iterations / opts.threads);
    const start = Date.now();
    const promises = [];

    for (let i = 0; i < opts.threads; i++) {
        promises.push(new Promise((resolve, reject) => {
            const w = new Worker(new URL(import.meta.url), {
                workerData: {
                    id: i,
                    iterations: per,
                    keys: opts.keys,
                    readRatio: opts.readRatio,
                    seed: opts.seed
                }
            });

            // Set up timeout to prevent hanging
            const timeout = setTimeout(() => {
                w.terminate();
                reject(new Error(`Worker ${i} timed out`));
            }, 30000); // 30 second timeout

            // Use message passing for reliable completion signaling
            w.on('message', (msg) => {
                if (msg === 'done') {
                    clearTimeout(timeout);
                    w.terminate();
                    resolve();
                }
            });

            w.on('error', (err) => {
                clearTimeout(timeout);
                reject(err);
            });

            w.on('exit', (code) => {
                clearTimeout(timeout);
                if (code !== 0) {
                    reject(new Error(`Worker exited with code ${code}`));
                } else {
                    resolve(); // Backup resolution if message wasn't sent
                }
            });
        }));
    }

    await Promise.all(promises);
    const dur = Date.now() - start;
    global.gc && global.gc();
    const rss = process.memoryUsage.rss();

    console.log(JSON.stringify({
        runtime: `bun${process.versions.bun}`,
        model: "worker_threads",
        threads: opts.threads,
        iterations: per * opts.threads,
        keys: opts.keys,
        read_ratio: opts.readRatio,
        seed: Number(opts.seed),
        duration_ms: dur,
        rss_bytes: rss
    }));
}

if (isMainThread) {
    main().catch(e => {
        console.error(e);
        process.exit(1);
    });
} else {
    const {id, iterations, keys, readRatio, seed} = workerData;
    const rnd = rand64(seed + BigInt(id));
    const reads = Math.floor(readRatio * 1000);
    const m = new Map();

    // Initialize map
    for (let i = 0; i < keys; i++) {
        m.set(i, 0);
    }

    // Run benchmark
    for (let i = 0; i < iterations; i++) {
        const k = Number(rnd() % BigInt(keys));
        const r = Number(rnd() % 1000n);
        if (r < reads) {
            m.get(k);
        } else {
            m.set(k, (m.get(k) || 0) + 1);
        }
    }

    // Signal completion before exiting
    parentPort?.postMessage('done');

    // Small delay to ensure message is sent
    setTimeout(() => {
        process.exit(0);
    }, 10);
}
