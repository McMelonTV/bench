#include <bits/stdc++.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <unistd.h>

struct Result {
  std::string runtime, model;
  int threads, iterations, keys;
  double read_ratio;
  uint64_t seed;
  long long duration_ms;
  unsigned long long rss_bytes;
};

uint64_t splitmix64(uint64_t &x){
  x += 0x9E3779B97f4A7C15ULL;
  uint64_t z = x;
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
  z = z ^ (z >> 31);
  return z;
}

unsigned long long rss_bytes() {
  long rss=0L;
  FILE* fp = fopen("/proc/self/statm","r");
  if (!fp) return 0;
  if (fscanf(fp,"%*s%ld",&rss)!=1) { fclose(fp); return 0; }
  fclose(fp);
  return (unsigned long long)rss * sysconf(_SC_PAGESIZE);
}

int main(int argc, char** argv) {
  int threads=8, iterations=2'000'000, keys=100'000, shards=64;
  double read_ratio=0.9;
  uint64_t seed=42;
  for (int i=1;i<argc;i++) {
    std::string a=argv[i];
    if (a=="--threads") threads=std::stoi(argv[++i]);
    else if (a=="--iterations") iterations=std::stoi(argv[++i]);
    else if (a=="--keys") keys=std::stoi(argv[++i]);
    else if (a=="--read-ratio") read_ratio=std::stod(argv[++i]);
    else if (a=="--seed") seed=std::stoull(argv[++i]);
    else if (a=="--shards") shards=std::stoi(argv[++i]);
  }
  std::vector<std::unordered_map<int,long long>> maps(shards);
  std::vector<std::mutex> locks(shards);
  for (int i=0;i<keys;i++) maps[i%shards][i]=0;
  int per = iterations / threads;

  auto start = std::chrono::steady_clock::now();
  std::vector<std::thread> ts;
  ts.reserve(threads);
  for (int t=0;t<threads;t++) {
    ts.emplace_back([&, t](){
      uint64_t x = seed + t;
      int reads = int(read_ratio*1000);
      for (int i=0;i<per;i++) {
        int k = int(splitmix64(x) % uint64_t(keys));
        int r = int(splitmix64(x) % 1000ULL);
        int s = k % shards;
        if (r < reads) {
          std::lock_guard<std::mutex> g(locks[s]);
          auto it = maps[s].find(k);
          if (it!=maps[s].end()) (void)it->second;
        } else {
          std::lock_guard<std::mutex> g(locks[s]);
          maps[s][k] += 1;
        }
      }
    });
  }
  for (auto &th: ts) th.join();
  auto dur = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-start).count();
  printf("{\"runtime\":\"gcc\",\"model\":\"threads-sharded\",\"threads\":%d,\"iterations\":%d,\"keys\":%d,\"read_ratio\":%.3f,\"seed\":%llu,\"duration_ms\":%lld,\"rss_bytes\":%llu}\n",
    threads, per*threads, keys, read_ratio, (unsigned long long)seed, (long long)dur, rss_bytes());
  return 0;
}
