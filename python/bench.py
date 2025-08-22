import argparse
import json
import multiprocessing as mp
import sys
import threading
import time


def rss_bytes():
    try:
        import psutil
        return psutil.Process().memory_info().rss
    except:
        import resource
        return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024


def splitmix64(seed):
    x = seed & ((1 << 64) - 1)
    while True:
        x = (x + 0x9E3779B97F4A7C15) & ((1 << 64) - 1)
        z = x
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9 & ((1 << 64) - 1)
        z = (z ^ (z >> 27)) * 0x94D049BB133111EB & ((1 << 64) - 1)
        z = z ^ (z >> 31)
        yield z


def worker_thread(shards, locks, keys, per, read_ratio, seed, tid):
    rnd = splitmix64(seed + tid)
    reads = int(read_ratio * 1000)
    for _ in range(per):
        k = int(next(rnd) % keys)
        r = int(next(rnd) % 1000)
        s = k % len(shards)
        if r < reads:
            with locks[s]:
                _ = shards[s].get(k, 0)
        else:
            with locks[s]:
                shards[s][k] = shards[s].get(k, 0) + 1


def worker_process(args):
    (keys, per, read_ratio, seed, pid, shardsN) = args
    shards = [dict() for _ in range(shardsN)]
    # prefill
    for i in range(keys):
        shards[i % shardsN][i] = 0
    rnd = splitmix64(seed + pid)
    reads = int(read_ratio * 1000)
    for _ in range(per):
        k = int(next(rnd) % keys)
        r = int(next(rnd) % 1000)
        s = k % shardsN
        if r < reads:
            _ = shards[s].get(k, 0)
        else:
            shards[s][k] = shards[s].get(k, 0) + 1
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--iterations", type=int, default=2_000_000)
    ap.add_argument("--keys", type=int, default=100_000)
    ap.add_argument("--read-ratio", type=float, default=0.9)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--model", type=str, default="threads")
    ap.add_argument("--shards", type=int, default=64)
    args = ap.parse_args()

    per = args.iterations // args.threads
    t0 = time.time()

    if args.model == "threads":
        shards = [dict() for _ in range(args.shards)]
        locks = [threading.Lock() for _ in range(args.shards)]
        for i in range(args.keys):
            shards[i % args.shards][i] = 0
        ts = []
        for i in range(args.threads):
            t = threading.Thread(target=worker_thread,
                                 args=(shards, locks, args.keys, per, args.read_ratio, args.seed, i))
            t.start();
            ts.append(t)
        for t in ts: t.join()
    elif args.model == "processes":
        with mp.Pool(processes=args.threads) as pool:
            pool.map(worker_process,
                     [(args.keys, per, args.read_ratio, args.seed, i, args.shards) for i in range(args.threads)])
    else:
        print("unknown model", file=sys.stderr);
        sys.exit(1)

    dur = int((time.time() - t0) * 1000)
    res = {
        "runtime": f"python{sys.version.split()[0]}",
        "model": args.model,
        "threads": args.threads,
        "iterations": per * args.threads,
        "keys": args.keys,
        "read_ratio": args.read_ratio,
        "seed": args.seed,
        "duration_ms": dur,
        "rss_bytes": rss_bytes()
    }
    print(json.dumps(res))


if __name__ == "__main__":
    main()
