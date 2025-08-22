// Requires Node >=18
const {Worker, isMainThread, parentPort, workerData} = require('worker_threads');

function parseArgs() {
    const args = require('node:process').argv.slice(2);
    const opts = {threads: 8, iterations: 2000000, keys: 100000, readRatio: 0.9, seed: 42, model: 'worker'};
    for (let i = 0; i < args.length; i++) {
        const [k, v] = args[i].split('=').length === 2 ? args[i].split('=') : [args[i].replace(/^--/, ''), args[i + 1]];
        if (k.startsWith('--')) continue;
        if (v === undefined) continue;
        if (k === 'threads') opts.threads = parseInt(v, 10);
        if (k === 'iterations') opts.iterations = parseInt(v, 10);
        if (k === 'keys') opts.keys = parseInt(v, 10);
        if (k === 'read-ratio') opts.readRatio = parseFloat(v);
        if (k === 'seed') opts.seed = parseInt(v, 10); // Keep as number, convert to BigInt in worker
        if (k === 'model') opts.model = v;
    }
    return opts;
}

function nowMs() {
    return Number(process.hrtime.bigint() / 1000000n);
}

function rand64(seed) {
    let x = BigInt(seed); // Ensure seed is BigInt
    return () => {
        x = (x + 0x9E3779B97f4A7C15n) & ((1n << 64n) - 1n);
        let z = x;
        z = (z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n & ((1n << 64n) - 1n);
        z = (z ^ (z >> 27n)) * 0x94D049BB133111EBn & ((1n << 64n) - 1n);
        z = z ^ (z >> 31n);
        return z;
    };
}

function runWorkerThread({id, iterations, keys, readRatio, seed}) {
    // Ensure all BigInt operations use consistent types
    const rnd = rand64(BigInt(seed) + BigInt(id));
    const reads = Math.floor(readRatio * 1000);
    const map = new Map();

    for (let i = 0; i < keys; i++) map.set(i, 0);

    for (let i = 0; i < iterations; i++) {
        const k = Number(rnd() % BigInt(keys));
        const r = Number(rnd() % 1000n);
        if (r < reads) {
            map.get(k);
        } else {
            map.set(k, (map.get(k) || 0) + 1);
        }
    }
}

async function main() {
    const opts = parseArgs();
    if (isMainThread) {
        const per = Math.floor(opts.iterations / opts.threads);
        const start = nowMs();
        const workers = [];

        for (let i = 0; i < opts.threads; i++) {
            workers.push(new Promise((resolve, reject) => {
                const w = new Worker(__filename, {
                    workerData: {
                        id: i,
                        iterations: per,
                        keys: opts.keys,
                        readRatio: opts.readRatio,
                        seed: opts.seed // Pass as regular number
                    }
                });
                w.on('exit', () => resolve());
                w.on('error', reject);
            }));
        }

        await Promise.all(workers);
        const dur = nowMs() - start;
        global.gc && global.gc();

        setTimeout(() => {
            const res = {
                runtime: `node${process.version}`,
                model: `worker_threads`,
                threads: opts.threads,
                iterations: per * opts.threads,
                keys: opts.keys,
                read_ratio: opts.readRatio,
                seed: opts.seed, // Keep as number
                duration_ms: dur,
                rss_bytes: process.memoryUsage.rss()
            };
            console.log(JSON.stringify(res));
        }, 50);
    } else {
        runWorkerThread(workerData);
    }
}

main().catch(e => {
    console.error(e);
    process.exit(1);
});
