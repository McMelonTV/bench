// deno v2 Workers
function parseArgs() {
    const d = new Map<string, string>();
    for (const a of Deno.args) {
        const [k, v] = a.startsWith("--") ? a.slice(2).split("=") : [a, ""];
        if (k) d.set(k, v || "");
    }
    return {
        threads: +(d.get("threads") || 8),
        iterations: +(d.get("iterations") || 2000000),
        keys: +(d.get("keys") || 100000),
        readRatio: +(d.get("read-ratio") || 0.9),
        seed: BigInt(d.get("seed") || "42"),
        model: d.get("model") || "worker",
    };
}

function rand64(seed: bigint) {
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

const workerCode = `
  self.onmessage = (e) => {
    const { id, iterations, keys, readRatio, seed } = e.data;
    function rand64(seed){
      let x = seed;
      return () => {
        x = (x + 0x9E3779B97f4A7C15n) & ((1n<<64n)-1n);
        let z = x;
        z = (z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n & ((1n<<64n)-1n);
        z = (z ^ (z >> 27n)) * 0x94D049BB133111EBn & ((1n<<64n)-1n);
        z = z ^ (z >> 31n);
        return z;
      };
    }
    const rnd = rand64(seed + BigInt(id));
    const reads = Math.floor(readRatio * 1000);
    const m = new Map();
    for (let i=0;i<keys;i++) m.set(i, 0);
    for (let i=0;i<iterations;i++) {
      const k = Number(rnd() % BigInt(keys));
      const r = Number(rnd() % 1000n);
      if (r < reads) {
        m.get(k);
      } else {
        m.set(k, (m.get(k) || 0) + 1);
      }
    }
    self.postMessage({ done: true });
    self.close();
  }
`;

async function main() {
    const opts = parseArgs();
    const per = Math.floor(opts.iterations / opts.threads);
    const start = performance.now();
    const workers: Worker[] = [];
    const promises: Promise<void>[] = [];
    for (let i = 0; i < opts.threads; i++) {
        const w = new Worker(
            URL.createObjectURL(
                new Blob([workerCode], {type: "application/javascript"}),
            ),
            // deno-lint-ignore no-explicit-any
            {type: "module", deno: {namespace: false}} as any,
        );
        workers.push(w);
        promises.push(
            new Promise((res) => {
                w.onmessage = () => res();
            }),
        );
        w.postMessage({
            id: i,
            iterations: per,
            keys: opts.keys,
            readRatio: opts.readRatio,
            seed: opts.seed,
        });
    }
    await Promise.all(promises);
    const dur = Math.round(performance.now() - start);
    // Deno.memoryUsage().rss available
    // deno-lint-ignore no-explicit-any
    (globalThis as any).gc?.();
    // deno-lint-ignore no-explicit-any
    const mem = (Deno as any).memoryUsage?.().rss ?? 0;
    console.log(JSON.stringify({
        runtime: `deno${Deno.version.deno}`,
        model: "worker",
        threads: opts.threads,
        iterations: per * opts.threads,
        keys: opts.keys,
        read_ratio: opts.readRatio,
        seed: Number(opts.seed),
        duration_ms: dur,
        rss_bytes: mem,
    }));
}

main();
