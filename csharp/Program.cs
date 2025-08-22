using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime;

class Result {
  public string runtime {get;set;} = "";
  public string model {get;set;} = "";
  public int threads {get;set;}
  public int iterations {get;set;}
  public int keys {get;set;}
  public double read_ratio {get;set;}
  public long seed {get;set;}
  public long duration_ms {get;set;}
  public long rss_bytes {get;set;}
}

class RNG {
  ulong x;
  public RNG(ulong seed) { x = seed; }
  public ulong Next() {
    x += 0x9E3779B97f4A7C15;
    ulong z = x;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
    z ^= z >> 31;
    return z;
  }
}

class Program {
  static long RSS() {
    using var p = Process.GetCurrentProcess();
    return p.WorkingSet64;
  }
  static void Main(string[] args) {
    int threads = 8, iterations = 2_000_000, keys = 100_000;
    double readRatio = 0.9;
    ulong seed = 42;
    string model = "tasks";
    for (int i=0;i<args.Length;i++) {
      if (args[i]=="--threads") threads = int.Parse(args[++i]);
      else if (args[i]=="--iterations") iterations = int.Parse(args[++i]);
      else if (args[i]=="--keys") keys = int.Parse(args[++i]);
      else if (args[i]=="--read-ratio") readRatio = double.Parse(args[++i]);
      else if (args[i]=="--seed") seed = ulong.Parse(args[++i]);
      else if (args[i]=="--model") model = args[++i];
    }
    var map = new ConcurrentDictionary<int,long>(Environment.ProcessorCount, keys);
    for (int i=0;i<keys;i++) map[i]=0;
    int per = iterations / threads;
    Action work = () => {
      var rng = new RNG(seed + (ulong)Environment.CurrentManagedThreadId);
      int reads = (int)(readRatio * 1000);
      for (int i=0;i<per;i++) {
        int k = (int)(rng.Next() % (ulong)keys);
        int r = (int)(rng.Next() % 1000);
        if (r < reads) map.TryGetValue(k, out _);
        else map.AddOrUpdate(k, 1, (_, v)=> v+1);
      }
    };
    var sw = Stopwatch.StartNew();
    if (model=="parallel") {
      System.Threading.Tasks.Parallel.For(0, threads, _ => work());
    } else {
      var tasks = new System.Threading.Tasks.Task[threads];
      for (int i=0;i<threads;i++) tasks[i]=System.Threading.Tasks.Task.Run(work);
      System.Threading.Tasks.Task.WaitAll(tasks);
    }
    sw.Stop();
    GC.Collect();
    System.Threading.Thread.Sleep(50);
    var res = new Result {
      runtime = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription,
      model = model,
      threads = threads,
      iterations = per*threads,
      keys = keys,
      read_ratio = readRatio,
      seed = (long)seed,
      duration_ms = sw.ElapsedMilliseconds,
      rss_bytes = RSS()
    };
    Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(res));
  }
}
