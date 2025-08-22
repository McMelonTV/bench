import java.util.*;
import java.util.concurrent.*;
import java.lang.management.*;

class Result {
    public String runtime, model;
    public int threads, iterations, keys;
    public double read_ratio;
    public long seed, duration_ms, rss_bytes;

    public String toJson() {
        return String.format(
                "{\"runtime\":\"%s\",\"model\":\"%s\",\"threads\":%d,\"iterations\":%d," +
                        "\"keys\":%d,\"read_ratio\":%.3f,\"seed\":%d,\"duration_ms\":%d,\"rss_bytes\":%d}",
                escapeJson(runtime), escapeJson(model), threads, iterations,
                keys, read_ratio, seed, duration_ms, rss_bytes
        );
    }

    private String escapeJson(String str) {
        if (str == null) return "null";
        return str.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}

public class Bench {
    static long rss() {
        // Use Runtime totalMemory as a proxy; for true RSS, read /proc/self/statm on Linux via File IO
        return Runtime.getRuntime().totalMemory();
    }

    public static void main(String[] args) throws Exception {
        int threads = 8, iterations = 2_000_000, keys = 100_000;
        double readRatio = 0.9;
        long seed = 42;
        String model = "threadpool";

        for (int i = 0; i < args.length; i++) {
            if (args[i].equals("--threads")) threads = Integer.parseInt(args[++i]);
            else if (args[i].equals("--iterations")) iterations = Integer.parseInt(args[++i]);
            else if (args[i].equals("--keys")) keys = Integer.parseInt(args[++i]);
            else if (args[i].equals("--read-ratio")) readRatio = Double.parseDouble(args[++i]);
            else if (args[i].equals("--seed")) seed = Long.parseLong(args[++i]);
            else if (args[i].equals("--model")) model = args[++i];
        }

        // Declare as final for lambda access
        final int finalKeys = keys;
        final long finalSeed = seed;
        final double finalReadRatio = readRatio;
        final int per = iterations / threads;

        final ConcurrentHashMap<Integer, Long> map = new ConcurrentHashMap<>(keys);
        for (int i = 0; i < keys; i++) map.put(i, 0L);

        Runnable work = () -> {
        };

        if (model.equals("threadpool")) {
            work = () -> {
                RNG rng = new RNG(finalSeed + Thread.currentThread().getId());
                int reads = (int) (finalReadRatio * 1000);
                for (int i = 0; i < per; i++) {
                    int k = (int) Math.floorMod(rng.next(), finalKeys);
                    int r = (int) Math.floorMod(rng.next(), 1000);
                    if (r < reads) {
                        map.get(k);
                    } else {
                        map.compute(k, (kk, vv) -> vv == null ? 1L : vv + 1);
                    }
                }
            };
        } else if (model.equals("forkjoin")) {
            work = () -> {
                RNG rng = new RNG(finalSeed + Thread.currentThread().getId());
                int reads = (int) (finalReadRatio * 1000);
                for (int i = 0; i < per; i++) {
                    int k = (int) Math.floorMod(rng.next(), finalKeys);
                    int r = (int) Math.floorMod(rng.next(), 1000);
                    if (r < reads) map.get(k);
                    else map.compute(k, (kk, vv) -> vv == null ? 1L : vv + 1);
                }
            };
        } else {
            System.err.println("unknown model");
            System.exit(1);
        }

        long start = System.nanoTime();
        if (model.equals("forkjoin")) {
            ForkJoinPool fj = new ForkJoinPool(threads);
            List<ForkJoinTask<?>> tasks = new ArrayList<>();
            for (int i = 0; i < threads; i++) {
                tasks.add(fj.submit(work));
            }
            for (ForkJoinTask<?> t : tasks) t.join();
            fj.shutdown();
        } else {
            ExecutorService es = Executors.newFixedThreadPool(threads);
            List<Future<?>> fs = new ArrayList<>();
            for (int i = 0; i < threads; i++) fs.add(es.submit(work));
            for (Future<?> f : fs) f.get();
            es.shutdown();
        }
        long dur = (System.nanoTime() - start) / 1_000_000;

        System.gc();
        Thread.sleep(50);

        Result res = new Result();
        res.runtime = System.getProperty("java.runtime.version");
        res.model = model;
        res.threads = threads;
        res.iterations = per * threads;
        res.keys = keys;
        res.read_ratio = readRatio;
        res.seed = seed;
        res.duration_ms = dur;
        res.rss_bytes = rss();

        System.out.println(res.toJson());
    }

    static class RNG {
        private long x;

        RNG(long seed) {
            x = seed;
        }

        long next() {
            x += 0x9E3779B97f4A7C15L;
            long z = x;
            z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9L;
            z = (z ^ (z >>> 27)) * 0x94D049BB133111EBL;
            z = z ^ (z >>> 31);
            return z;
        }
    }
}
