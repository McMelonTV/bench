package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"math/rand/v2"
	"os"
	"runtime"
	"runtime/debug"
	"sync"
	"time"
)

type Result struct {
	Runtime    string  `json:"runtime"`
	Model      string  `json:"model"`
	Threads    int     `json:"threads"`
	Iterations int     `json:"iterations"`
	Keys       int     `json:"keys"`
	ReadRatio  float64 `json:"read_ratio"`
	Seed       uint64  `json:"seed"`
	DurationMS int64   `json:"duration_ms"`
	RSSBytes   uint64  `json:"rss_bytes"`
}

func rss() uint64 {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	return m.Sys // close to RSS; for external RSS, parse /proc/self/statm on Linux
}

func main() {
	threads := flag.Int("threads", 8, "")
	iters := flag.Int("iterations", 2_000_000, "")
	keys := flag.Int("keys", 100_000, "")
	readRatio := flag.Float64("read-ratio", 0.9, "")
	seed := flag.Uint64("seed", 42, "")
	model := flag.String("model", "syncmap", "syncmap|sharded")
	shardsN := flag.Int("shards", 64, "for sharded model")
	flag.Parse()

	debug.SetGCPercent(100)
	runtime.GOMAXPROCS(runtime.NumCPU())

	switch *model {
	case "syncmap":
		runSyncMap(*threads, *iters, *keys, *readRatio, *seed)
	case "sharded":
		runSharded(*threads, *iters, *keys, *readRatio, *seed, *shardsN)
	default:
		fmt.Fprintln(os.Stderr, "unknown model")
		os.Exit(1)
	}
}

func runSyncMap(threads, iterations, keys int, readRatio float64, seed uint64) {
	var m sync.Map
	// prefill
	for i := 0; i < keys; i++ {
		m.Store(i, int64(0))
	}
	runWork("go"+runtime.Version(), "threads-sync.Map", threads, iterations, keys, readRatio, seed, func(ctx context.Context, tid int, n int) {
		r := rand.New(rand.NewPCG(seed+uint64(tid), seed*1315423911+uint64(tid)))
		reads := int(readRatio * 1000.0)
		for i := 0; i < n; i++ {
			k := int(r.IntN(keys))
			if int(r.IntN(1000)) < reads {
				if v, ok := m.Load(k); ok {
					_ = v.(int64)
				}
			} else {
				for {
					v, _ := m.Load(k)
					old := int64(0)
					if v != nil {
						old = v.(int64)
					}
					if m.CompareAndSwap(k, old, old+1) {
						break
					}
					// if key absent, Store will fail CAS; ensure presence
					if v == nil {
						// initialize
						m.LoadOrStore(k, int64(0))
					}
				}
			}
		}
	}, &m)
}

type shard struct {
	mu sync.Mutex
	m  map[int]int64
}

func runSharded(threads, iterations, keys int, readRatio float64, seed uint64, shardsN int) {
	shards := make([]*shard, shardsN)
	for i := range shards {
		shards[i] = &shard{m: make(map[int]int64, keys/shardsN+1)}
	}
	// prefill
	for i := 0; i < keys; i++ {
		s := shards[i%shardsN]
		s.mu.Lock()
		s.m[i] = 0
		s.mu.Unlock()
	}
	runWork("go"+runtime.Version(), "threads-sharded", threads, iterations, keys, readRatio, seed, func(ctx context.Context, tid int, n int) {
		r := rand.New(rand.NewPCG(seed+uint64(tid), seed*1315423911+uint64(tid)))
		reads := int(readRatio * 1000.0)
		for i := 0; i < n; i++ {
			k := int(r.IntN(keys))
			s := shards[k%shardsN]
			if int(r.IntN(1000)) < reads {
				s.mu.Lock()
				_ = s.m[k]
				s.mu.Unlock()
			} else {
				s.mu.Lock()
				s.m[k]++
				s.mu.Unlock()
			}
		}
	}, shards)
}

func runWork(rt, model string, threads, iterations, keys int, readRatio float64, seed uint64, worker func(context.Context, int, int), obj any) {
	per := iterations / threads
	ctx := context.Background()
	start := time.Now()
	var wg sync.WaitGroup
	wg.Add(threads)
	for t := 0; t < threads; t++ {
		tid := t
		go func() {
			defer wg.Done()
			worker(ctx, tid, per)
		}()
	}
	wg.Wait()
	dur := time.Since(start).Milliseconds()
	_ = obj // keep from optimizing away

	// force GC to stabilize mem reading
	runtime.GC()
	time.Sleep(50 * time.Millisecond)
	res := Result{
		Runtime:    rt,
		Model:      model,
		Threads:    threads,
		Iterations: per * threads,
		Keys:       keys,
		ReadRatio:  readRatio,
		Seed:       seed,
		DurationMS: dur,
		RSSBytes:   rss(),
	}
	b, _ := json.Marshal(res)
	fmt.Println(string(b))
}
