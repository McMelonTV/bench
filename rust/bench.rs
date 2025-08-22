extern crate serde;
use serde::Serialize;
use std::{
    sync::{Arc, Mutex},
    time::Instant,
};

#[derive(Serialize)]
struct ResultOut {
    runtime: String,
    model: String,
    threads: usize,
    iterations: usize,
    keys: usize,
    read_ratio: f64,
    seed: u64,
    duration_ms: u128,
    rss_bytes: u64,
}

fn rss_bytes() -> u64 {
    #[cfg(target_os = "linux")]
    {
        let s = std::fs::read_to_string("/proc/self/statm").unwrap_or_default();
        let parts: Vec<&str> = s.split_whitespace().collect();
        if parts.len() >= 2 {
            let pages: u64 = parts[1].parse().unwrap_or(0);
            return pages * 4096;
        }
    }
    0
}

fn splitmix64(mut x: u64) -> impl FnMut() -> u64 {
    move || {
        x = x.wrapping_add(0x9E3779B97f4A7C15);
        let mut z = x;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }
}

fn run_sharded(
    threads: usize,
    iterations: usize,
    keys: usize,
    read_ratio: f64,
    seed: u64,
    shards_n: usize,
) {
    let mut shards = Vec::with_capacity(shards_n);
    for _ in 0..shards_n {
        shards.push(Arc::new(Mutex::new(vec![0i64; 0])));
    }
    // store as Vec of hashmaps but for speed, use Vec with capacity keys/shard and sparse fill via map-like approach
    let mut maps: Vec<Arc<Mutex<std::collections::HashMap<usize, i64>>>> =
        Vec::with_capacity(shards_n);
    for _ in 0..shards_n {
        maps.push(Arc::new(Mutex::new(
            std::collections::HashMap::with_capacity(keys / shards_n + 1),
        )));
    }
    for i in 0..keys {
        let s = &maps[i % shards_n];
        let mut g = s.lock().unwrap();
        g.insert(i, 0);
    }
    let per = iterations / threads;
    let start = Instant::now();
    let mut handles = Vec::new();
    for t in 0..threads {
        let maps = maps.clone();
        let reads = (read_ratio * 1000.0) as u64;
        let mut rnd = splitmix64(seed + t as u64);
        handles.push(std::thread::spawn(move || {
            for _ in 0..per {
                let k = (rnd() % keys as u64) as usize;
                let r = rnd() % 1000;
                let sidx = k % maps.len();
                let m = &maps[sidx];
                if r < reads {
                    let g = m.lock().unwrap();
                    let _ = g.get(&k);
                } else {
                    let mut g = m.lock().unwrap();
                    let e = g.entry(k).or_insert(0);
                    *e += 1;
                }
            }
        }));
    }
    for h in handles {
        h.join().unwrap();
    }
    let dur = start.elapsed().as_millis();
    let out = ResultOut {
        runtime: format!("rustc{}", rustc_version_runtime()),
        model: "threads-sharded".to_string(),
        threads,
        iterations: per * threads,
        keys,
        read_ratio,
        seed,
        duration_ms: dur,
        rss_bytes: rss_bytes(),
    };
    println!("{}", serde_json::to_string(&out).unwrap());
}

fn rustc_version_runtime() -> String {
    // Best effort: read env var set by cargo; else unknown
    option_env!("RUSTC_VERSION")
        .unwrap_or("unknown")
        .to_string()
}

fn main() {
    let mut threads = 8usize;
    let mut iterations = 2_000_000usize;
    let mut keys = 100_000usize;
    let mut read_ratio = 0.9f64;
    let mut seed = 42u64;
    let mut _model = "threads".to_string();
    let mut shards = 64usize;
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--threads" => {
                i += 1;
                threads = args[i].parse().unwrap();
            }
            "--iterations" => {
                i += 1;
                iterations = args[i].parse().unwrap();
            }
            "--keys" => {
                i += 1;
                keys = args[i].parse().unwrap();
            }
            "--read-ratio" => {
                i += 1;
                read_ratio = args[i].parse().unwrap();
            }
            "--seed" => {
                i += 1;
                seed = args[i].parse().unwrap();
            }
            "--model" => {
                i += 1;
                _model = args[i].clone();
            }
            "--shards" => {
                i += 1;
                shards = args[i].parse().unwrap();
            }
            _ => {}
        }
        i += 1;
    }
    // For fairness use sharded Mutex<HashMap>; you can switch to DashMap by feature
    run_sharded(threads, iterations, keys, read_ratio, seed, shards);
}
