#!/usr/bin/env bash
set -euo pipefail

# ========== USAGE ==========
show_usage() {
  cat << EOF
Usage: $0 [--skip-config] [--help]

Options:
  --skip-config    Skip interactive configuration, use environment variables or defaults
  --help          Show this help message

Environment Variables (used when --skip-config is specified):
  THREADS         Number of threads (default: 8)
  ITERATIONS      Number of iterations (default: 2000000)
  KEYS            Number of keys (default: 100000)
  READ_RATIO      Read ratio 0.0-1.0 (default: 0.9)
  SEED            Random seed (default: 42)
  REPEATS         Repeats per variant (default: 5)
  OUTDIR          Output directory (default: _out)
  TABLE_OUT       Summary table file (default: _summary.md)

Examples:
  $0                                    # Interactive configuration
  $0 --skip-config                     # Use defaults/environment variables
  THREADS=16 REPEATS=10 $0 --skip-config  # Custom environment variables

EOF
}

if [[ "${1:-}" == "--help" ]]; then
  show_usage
  exit 0
fi

# ========== CONFIG ==========
# Common parameters
THREADS="${THREADS:-8}"
ITERATIONS="${ITERATIONS:-2000000}"
KEYS="${KEYS:-100000}"
READ_RATIO="${READ_RATIO:-0.9}"
SEED="${SEED:-42}"
REPEATS="${REPEATS:-5}"          # number of repetitions per variant
OUTDIR="${OUTDIR:-_out}"
TABLE_OUT="${TABLE_OUT:-_summary.md}"

# ========== INTERACTIVE CONFIGURATION ==========
configure_benchmark() {
  echo "==============================================="
  echo "BENCHMARK CONFIGURATION"
  echo "==============================================="
  echo "Configure benchmark parameters (press Enter for defaults):"
  echo

  # Threads
  read -p "Number of threads [$THREADS]: " input_threads
  if [[ -n "$input_threads" && "$input_threads" =~ ^[1-9][0-9]*$ ]]; then
    THREADS="$input_threads"
  fi

  # Iterations
  read -p "Number of iterations [$ITERATIONS]: " input_iterations
  if [[ -n "$input_iterations" && "$input_iterations" =~ ^[1-9][0-9]*$ ]]; then
    ITERATIONS="$input_iterations"
  fi

  # Keys
  read -p "Number of keys [$KEYS]: " input_keys
  if [[ -n "$input_keys" && "$input_keys" =~ ^[1-9][0-9]*$ ]]; then
    KEYS="$input_keys"
  fi

  # Read ratio
  read -p "Read ratio (0.0-1.0) [$READ_RATIO]: " input_read_ratio
  if [[ -n "$input_read_ratio" && "$input_read_ratio" =~ ^0(\.[0-9]+)?$|^1(\.0+)?$ ]]; then
    READ_RATIO="$input_read_ratio"
  fi

  # Seed
  read -p "Random seed [$SEED]: " input_seed
  if [[ -n "$input_seed" && "$input_seed" =~ ^[0-9]+$ ]]; then
    SEED="$input_seed"
  fi

  # Repeats
  read -p "Number of repeats per variant [$REPEATS]: " input_repeats
  if [[ -n "$input_repeats" && "$input_repeats" =~ ^[1-9][0-9]*$ ]]; then
    REPEATS="$input_repeats"
  fi

  # Output directory
  read -p "Output directory [$OUTDIR]: " input_outdir
  if [[ -n "$input_outdir" ]]; then
    OUTDIR="$input_outdir"
    TABLE_OUT="$OUTDIR/_summary.md"
  fi

  echo
  echo "Final configuration:"
  echo "  Threads:     $THREADS"
  echo "  Iterations:  $ITERATIONS"
  echo "  Keys:        $KEYS"
  echo "  Read Ratio:  $READ_RATIO"
  echo "  Seed:        $SEED"
  echo "  Repeats:     $REPEATS"
  echo "  Output Dir:  $OUTDIR"
  echo

  read -p "Proceed with these settings? [Y/n]: " -n 1 -r REPLY
  echo
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "Configuration cancelled. You can:"
    echo "  1. Run the script again to reconfigure"
    echo "  2. Set environment variables and run with --skip-config"
    echo "  3. Edit the script defaults directly"
    exit 0
  fi
}

# Check if user wants to skip interactive configuration
SKIP_CONFIG=false
if [[ "${1:-}" == "--skip-config" ]]; then
  SKIP_CONFIG=true
  shift
fi

# Run configuration unless skipped
if [[ "$SKIP_CONFIG" != "true" ]]; then
  configure_benchmark
fi

# Paths to source artifacts (edit as needed)
GO_SRC="go/bench.go"
NODE_SRC="node/bench.js"
DENO_SRC="deno/bench.ts"
BUN_SRC="bun/bench.js"
JAVA_SRC="java/Bench.java"
CSHARPPROJ_DIR="csharp"          # has Program.cs; we'll create project if missing
PY_SRC="python/bench.py"
PHP_SRC="php/bench.php"
RUST_DIR="rust"                  # has Cargo.toml
RUST_BIN="bench"                 # name of built bin
CPP_SRC="cpp/bench.cpp"

# Models per runtime
GO_MODELS=("syncmap" "sharded")
NODE_MODELS=("worker_threads")   # provided script uses worker_threads
DENO_MODELS=("worker")
BUN_MODELS=("worker_threads")
JAVA_MODELS=("threadpool" "forkjoin")
CS_MODELS=("tasks" "parallel")
PY_MODELS=("threads" "processes")
PHP_MODELS=("parallel" "single")
RUST_MODELS=("threads-sharded")  # implemented as sharded threads
CPP_MODELS=("threads-sharded")

# ========== HELPERS ==========
cmd_exists() { command -v "$1" >/dev/null 2>&1; }
ts() { date +"%Y-%m-%dT%H:%M:%S%z"; }

mkdir -p "$OUTDIR"

# JSON aggregation helpers using jq (required)
if ! cmd_exists jq; then
  echo "Error: jq is required. Please install jq." >&2
  exit 1
fi

emit_info() {
  echo "[$(ts)] $*"
}

emit_error() {
  echo "[$(ts)] ERROR: $*" >&2
}

# Build error handler - asks user whether to continue or exit
handle_build_error() {
  local lang="$1"
  local error_output="$2"

  echo "==============================================="
  emit_error "$lang build failed!"
  echo "==============================================="
  echo "Build output:"
  echo "$error_output"
  echo "==============================================="
  echo
  read -p "Continue with other benchmarks? [y/N]: " -n 1 -r REPLY
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Exiting due to build failure."
    exit 1
  fi
  echo "Continuing without $lang..."
  echo
}

# ========== AVAILABILITY CHECK ==========
check_go() {
  cmd_exists go && [ -f "$GO_SRC" ]
}

check_node() {
  cmd_exists node && [ -f "$NODE_SRC" ]
}

check_deno() {
  cmd_exists deno && [ -f "$DENO_SRC" ]
}

check_bun() {
  cmd_exists bun && [ -f "$BUN_SRC" ]
}

check_java() {
  cmd_exists javac && cmd_exists java && [ -f "$JAVA_SRC" ]
}

check_csharp() {
  cmd_exists dotnet && [ -d "$CSHARPPROJ_DIR" ]
}

check_python() {
  cmd_exists python3 && [ -f "$PY_SRC" ]
}

check_php() {
  cmd_exists php && [ -f "$PHP_SRC" ]
}

check_rust() {
  cmd_exists cargo && [ -d "$RUST_DIR" ]
}

check_cpp() {
  cmd_exists g++ && [ -f "$CPP_SRC" ]
}

# ========== BUILD STEPS ==========

build_go() {
  if ! check_go; then return 1; fi
  emit_info "Building Go"

  local build_output
  if build_output=$(cd "$(dirname "$GO_SRC")" && go build -ldflags="-s -w" -o ../$OUTDIR/go_bench ./$(basename "$GO_SRC") 2>&1); then
    emit_info "Go build successful"
    return 0
  else
    handle_build_error "Go" "$build_output"
    return 1
  fi
}

build_node() {
  if ! check_node; then return 1; fi
  emit_info "Node present (no build required)"
  return 0
}

build_deno() {
  if ! check_deno; then return 1; fi
  emit_info "Deno present (no build required)"
  return 0
}

build_bun() {
  if ! check_bun; then return 1; fi
  emit_info "Bun present (no build required)"
  return 0
}

build_java() {
  if ! check_java; then return 1; fi
  emit_info "Building Java"
  mkdir -p "$OUTDIR/java"

  local build_output
  if build_output=$(cd "$(dirname "$JAVA_SRC")" && javac -d ../$OUTDIR/java ./$(basename "$JAVA_SRC") 2>&1); then
    emit_info "Java build successful"
    return 0
  else
    handle_build_error "Java" "$build_output"
    return 1
  fi
}

build_csharp() {
  if ! check_csharp; then return 1; fi
  emit_info "Building C#"

  # Create project if missing
  if [ ! -f "$CSHARPPROJ_DIR/Bench.csproj" ]; then
    emit_info "Creating C# project"
    rm -rf "$CSHARPPROJ_DIR/bin" "$CSHARPPROJ_DIR/obj" || true
    local create_output
    if ! create_output=$(cd "$CSHARPPROJ_DIR" && dotnet new console -n Bench -o . 2>&1); then
      handle_build_error "C# (project creation)" "$create_output"
      return 1
    fi
  fi

  local build_output
  if build_output=$(cd "$CSHARPPROJ_DIR" && dotnet build -c Release 2>&1); then
    emit_info "C# build successful"
    return 0
  else
    handle_build_error "C#" "$build_output"
    return 1
  fi
}

build_python() {
  if ! check_python; then return 1; fi
  emit_info "Python present (no build required)"

  # Check for optional psutil
  if python3 -c "import psutil" 2>/dev/null; then
    emit_info "Python psutil available for better memory measurement"
  else
    emit_info "Python psutil not available (optional), using resource module"
  fi
  return 0
}

build_php() {
  if ! check_php; then return 1; fi
  emit_info "PHP present (no build required)"

  # Check for parallel extension
  if php -m | grep -q "parallel" 2>/dev/null; then
    emit_info "PHP parallel extension available"
  else
    emit_info "PHP parallel extension not available (optional), will use single-threaded mode"
  fi
  return 0
}

build_rust() {
  if ! check_rust; then return 1; fi
  emit_info "Building Rust (this may take a while for first build)"

  local build_output
  if build_output=$(cd "$RUST_DIR" && cargo build --release 2>&1); then
    emit_info "Rust build successful"
    return 0
  else
    handle_build_error "Rust" "$build_output"
    return 1
  fi
}

build_cpp() {
  if ! check_cpp; then return 1; fi
  emit_info "Building C++"

  local build_output
  if build_output=$(g++ -O3 -std=c++20 -lpthread -o "$OUTDIR/cpp_bench" "$CPP_SRC" 2>&1); then
    emit_info "C++ build successful"
    return 0
  else
    handle_build_error "C++" "$build_output"
    return 1
  fi
}

# ========== RUN STEPS ==========

run_go() {
  local model="$1"
  echo "./$OUTDIR/go_bench --threads $THREADS --iterations $ITERATIONS --keys $KEYS --read-ratio $READ_RATIO --seed $SEED --model $model"
}

run_node() {
  local model="$1"
  echo "node --expose-gc $NODE_SRC --model=$model --threads=$THREADS --iterations=$ITERATIONS --keys=$KEYS --read-ratio=$READ_RATIO --seed=$SEED"
}

run_deno() {
  local model="$1"
  echo "deno run --allow-env --allow-read --v8-flags=--expose-gc $DENO_SRC --model=$model --threads=$THREADS --iterations=$ITERATIONS --keys=$KEYS --read-ratio=$READ_RATIO --seed=$SEED"
}

run_bun() {
  local model="$1"
  echo "bun $BUN_SRC --model=$model --threads=$THREADS --iterations=$ITERATIONS --keys=$KEYS --read-ratio=$READ_RATIO --seed=$SEED"
}

run_java() {
  local model="$1"
  local cp="$OUTDIR/java"
  echo "java -Xms1g -Xmx1g -XX:+AlwaysPreTouch -cp $cp Bench --model $model --threads $THREADS --iterations $ITERATIONS --keys $KEYS --read-ratio $READ_RATIO --seed $SEED"
}

run_csharp() {
  local model="$1"
  echo "dotnet run --project $CSHARPPROJ_DIR -c Release -- --model $model --threads $THREADS --iterations $ITERATIONS --keys $KEYS --read-ratio $READ_RATIO --seed $SEED"
}

run_python() {
  local model="$1"
  echo "python3 $PY_SRC --model $model --threads $THREADS --iterations $ITERATIONS --keys $KEYS --read-ratio $READ_RATIO --seed $SEED"
}

run_php() {
  local model="$1"
  echo "php -d detect_unicode=0 $PHP_SRC --model $model --threads $THREADS --iterations $ITERATIONS --keys $KEYS --read-ratio $READ_RATIO --seed $SEED"
}

run_rust() {
  local model="$1"
  echo "$RUST_DIR/target/release/$RUST_BIN --model $model --threads $THREADS --iterations $ITERATIONS --keys $KEYS --read-ratio $READ_RATIO --seed $SEED"
}

run_cpp() {
  local model="$1"
  echo "./$OUTDIR/cpp_bench --threads $THREADS --iterations $ITERATIONS --keys $KEYS --read-ratio $READ_RATIO --seed $SEED"
}

# ========== AVAILABILITY CHECK AND CONFIRMATION ==========

# Check what's available
AVAILABLE=()
UNAVAILABLE=()

# Check each language/runtime
if check_go; then
  AVAILABLE+=("go")
else
  UNAVAILABLE+=("go")
fi

if check_node; then
  AVAILABLE+=("node")
else
  UNAVAILABLE+=("node")
fi

if check_deno; then
  AVAILABLE+=("deno")
else
  UNAVAILABLE+=("deno")
fi

if check_bun; then
  AVAILABLE+=("bun")
else
  UNAVAILABLE+=("bun")
fi

if check_java; then
  AVAILABLE+=("java")
else
  UNAVAILABLE+=("java")
fi

if check_csharp; then
  AVAILABLE+=("csharp")
else
  UNAVAILABLE+=("csharp")
fi

if check_python; then
  AVAILABLE+=("python")
else
  UNAVAILABLE+=("python")
fi

if check_php; then
  AVAILABLE+=("php")
else
  UNAVAILABLE+=("php")
fi

if check_rust; then
  AVAILABLE+=("rust")
else
  UNAVAILABLE+=("rust")
fi

if check_cpp; then
  AVAILABLE+=("cpp")
else
  UNAVAILABLE+=("cpp")
fi

# Count total benchmark runs
TOTAL_RUNS=0
for rt in "${AVAILABLE[@]}"; do
  case "$rt" in
    go) TOTAL_RUNS=$((TOTAL_RUNS + ${#GO_MODELS[@]})) ;;
    node) TOTAL_RUNS=$((TOTAL_RUNS + ${#NODE_MODELS[@]})) ;;
    deno) TOTAL_RUNS=$((TOTAL_RUNS + ${#DENO_MODELS[@]})) ;;
    bun) TOTAL_RUNS=$((TOTAL_RUNS + ${#BUN_MODELS[@]})) ;;
    java) TOTAL_RUNS=$((TOTAL_RUNS + ${#JAVA_MODELS[@]})) ;;
    csharp) TOTAL_RUNS=$((TOTAL_RUNS + ${#CS_MODELS[@]})) ;;
    python) TOTAL_RUNS=$((TOTAL_RUNS + ${#PY_MODELS[@]})) ;;
    php) TOTAL_RUNS=$((TOTAL_RUNS + ${#PHP_MODELS[@]})) ;;
    rust) TOTAL_RUNS=$((TOTAL_RUNS + ${#RUST_MODELS[@]})) ;;
    cpp) TOTAL_RUNS=$((TOTAL_RUNS + ${#CPP_MODELS[@]})) ;;
  esac
done

# Display summary and ask for confirmation
echo "==============================================="
echo "CONCURRENT HASHMAP BENCHMARK CONFIGURATION"
echo "==============================================="
echo
echo "Benchmark Parameters:"
echo "  Threads:     $THREADS"
echo "  Iterations:  $ITERATIONS"
echo "  Keys:        $KEYS"
echo "  Read Ratio:  $READ_RATIO"
echo "  Seed:        $SEED"
echo "  Repeats:     $REPEATS"
echo "  Output Dir:  $OUTDIR"
echo
echo "Available Languages/Runtimes (${#AVAILABLE[@]}):"
if [ ${#AVAILABLE[@]} -gt 0 ]; then
  for rt in "${AVAILABLE[@]}"; do
    case "$rt" in
      go) echo "  ✓ Go (models: ${GO_MODELS[*]})" ;;
      node) echo "  ✓ Node.js (models: ${NODE_MODELS[*]})" ;;
      deno) echo "  ✓ Deno (models: ${DENO_MODELS[*]})" ;;
      bun) echo "  ✓ Bun (models: ${BUN_MODELS[*]})" ;;
      java) echo "  ✓ Java (models: ${JAVA_MODELS[*]})" ;;
      csharp) echo "  ✓ C# (models: ${CS_MODELS[*]})" ;;
      python) echo "  ✓ Python (models: ${PY_MODELS[*]})" ;;
      php) echo "  ✓ PHP (models: ${PHP_MODELS[*]})" ;;
      rust) echo "  ✓ Rust (models: ${RUST_MODELS[*]})" ;;
      cpp) echo "  ✓ C++ (models: ${CPP_MODELS[*]})" ;;
    esac
  done
else
  echo "  (none)"
fi

echo
echo "Unavailable Languages/Runtimes (${#UNAVAILABLE[@]}):"
if [ ${#UNAVAILABLE[@]} -gt 0 ]; then
  for rt in "${UNAVAILABLE[@]}"; do
    reason=""
    case "$rt" in
      go)
        if ! cmd_exists go; then reason="(go not installed)";
        elif [ ! -f "$GO_SRC" ]; then reason="(source file missing: $GO_SRC)"; fi ;;
      node)
        if ! cmd_exists node; then reason="(node not installed)";
        elif [ ! -f "$NODE_SRC" ]; then reason="(source file missing: $NODE_SRC)"; fi ;;
      deno)
        if ! cmd_exists deno; then reason="(deno not installed)";
        elif [ ! -f "$DENO_SRC" ]; then reason="(source file missing: $DENO_SRC)"; fi ;;
      bun)
        if ! cmd_exists bun; then reason="(bun not installed)";
        elif [ ! -f "$BUN_SRC" ]; then reason="(source file missing: $BUN_SRC)"; fi ;;
      java)
        if ! cmd_exists javac || ! cmd_exists java; then reason="(JDK not installed)";
        elif [ ! -f "$JAVA_SRC" ]; then reason="(source file missing: $JAVA_SRC)"; fi ;;
      csharp)
        if ! cmd_exists dotnet; then reason="(.NET not installed)";
        elif [ ! -d "$CSHARPPROJ_DIR" ]; then reason="(project dir missing: $CSHARPPROJ_DIR)"; fi ;;
      python)
        if ! cmd_exists python3; then reason="(python3 not installed)";
        elif [ ! -f "$PY_SRC" ]; then reason="(source file missing: $PY_SRC)"; fi ;;
      php)
        if ! cmd_exists php; then reason="(php not installed)";
        elif [ ! -f "$PHP_SRC" ]; then reason="(source file missing: $PHP_SRC)"; fi ;;
      rust)
        if ! cmd_exists cargo; then reason="(cargo not installed)";
        elif [ ! -d "$RUST_DIR" ]; then reason="(rust dir missing: $RUST_DIR)"; fi ;;
      cpp)
        if ! cmd_exists g++; then reason="(g++ not installed)";
        elif [ ! -f "$CPP_SRC" ]; then reason="(source file missing: $CPP_SRC)"; fi ;;
    esac
    echo "  ✗ $rt $reason"
  done
else
  echo "  (none)"
fi

echo
echo "Total benchmark runs planned: $TOTAL_RUNS variants × $REPEATS repeats = $((TOTAL_RUNS * REPEATS)) runs"

if [ ${#AVAILABLE[@]} -eq 0 ]; then
  echo
  echo "ERROR: No languages available to benchmark!"
  echo "Please install required runtimes and ensure source files exist."
  exit 1
fi

echo
echo "This may take a considerable amount of time to complete."
echo "Build failures will prompt for confirmation to continue."
read -p "Continue with benchmark? [Y/n]: " -n 1 -r REPLY
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
  echo "Benchmark cancelled."
  exit 0
fi

echo
echo "Starting build phase..."
echo "==============================================="

# ========== ORCHESTRATION ==========

# Function to find the best available time command
find_time_command() {
  # Check for GNU time in common locations
  if command -v /usr/bin/time >/dev/null 2>&1; then
    echo "/usr/bin/time"
  elif command -v /bin/time >/dev/null 2>&1; then
    echo "/bin/time"
  elif command -v gtime >/dev/null 2>&1; then
    # On macOS with Homebrew, GNU time is installed as 'gtime'
    echo "gtime"
  else
    # No GNU time found
    echo ""
  fi
}

# Function to check if we have proper memory measurement capabilities
check_memory_measurement() {
  local time_cmd="$1"

  if [[ -z "$time_cmd" ]]; then
    emit_error "GNU time not found. Memory measurement will be limited."
    emit_error "To install GNU time:"
    emit_error "  Ubuntu/Debian: sudo apt install time"
    emit_error "  RHEL/Fedora:   sudo dnf install time"
    emit_error "  Arch Linux:    sudo pacman -S time"
    emit_error "  macOS:         brew install gnu-time"
    echo
    read -p "Continue with limited measurement capabilities? [y/N]: " -n 1 -r REPLY
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Benchmark cancelled. Please install GNU time for accurate memory measurement."
      exit 1
    fi
    return 1
  fi
  return 0
}

# Do the time command check once globally
TIME_CMD=$(find_time_command)
HAS_MEMORY_MEASUREMENT=true

if [[ -z "$TIME_CMD" ]]; then
  emit_error "GNU time not found. Memory measurement will be limited."
  emit_error "To install GNU time:"
  emit_error "  Ubuntu/Debian: sudo apt install time"
  emit_error "  RHEL/Fedora:   sudo dnf install time"
  emit_error "  Arch Linux:    sudo pacman -S time"
  emit_error "  macOS:         brew install gnu-time"
  echo
  read -p "Continue with limited measurement capabilities? [y/N]: " -n 1 -r REPLY
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Benchmark cancelled. Please install GNU time for accurate memory measurement."
    exit 1
  fi
  HAS_MEMORY_MEASUREMENT=false
fi

# Build all available toolchains with error handling
BUILD_AVAILABLE=()

if [[ " ${AVAILABLE[*]} " =~ " go " ]] && build_go; then BUILD_AVAILABLE+=("go"); fi
if [[ " ${AVAILABLE[*]} " =~ " node " ]] && build_node; then BUILD_AVAILABLE+=("node"); fi
if [[ " ${AVAILABLE[*]} " =~ " deno " ]] && build_deno; then BUILD_AVAILABLE+=("deno"); fi
if [[ " ${AVAILABLE[*]} " =~ " bun " ]] && build_bun; then BUILD_AVAILABLE+=("bun"); fi
if [[ " ${AVAILABLE[*]} " =~ " java " ]] && build_java; then BUILD_AVAILABLE+=("java"); fi
if [[ " ${AVAILABLE[*]} " =~ " csharp " ]] && build_csharp; then BUILD_AVAILABLE+=("csharp"); fi
if [[ " ${AVAILABLE[*]} " =~ " python " ]] && build_python; then BUILD_AVAILABLE+=("python"); fi
if [[ " ${AVAILABLE[*]} " =~ " php " ]] && build_php; then BUILD_AVAILABLE+=("php"); fi
if [[ " ${AVAILABLE[*]} " =~ " rust " ]] && build_rust; then BUILD_AVAILABLE+=("rust"); fi
if [[ " ${AVAILABLE[*]} " =~ " cpp " ]] && build_cpp; then BUILD_AVAILABLE+=("cpp"); fi

echo "==============================================="
emit_info "Build phase complete"
emit_info "Successfully built: ${BUILD_AVAILABLE[*]}"

if [ ${#BUILD_AVAILABLE[@]} -eq 0 ]; then
  echo "ERROR: No languages built successfully!"
  exit 1
fi

echo "Starting benchmark runs..."
echo "==============================================="

# Progress bar helper function
show_progress() {
  local current="$1"
  local total="$2"
  local prefix="$3"
  local bar_width=30

  local filled=$((current * bar_width / total))
  local empty=$((bar_width - filled))

  # Build progress bar
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done

  # Calculate percentage
  local percent=$((current * 100 / total))

  # Print progress (overwrites previous line with \r)
  printf "\r[$(ts)] %s [%s] %d/%d (%d%%)" "$prefix" "$bar" "$current" "$total" "$percent"
}

# Run each variant REPEATS times and collect outputs
ALL_JSON="$OUTDIR/all_runs.jsonl"
: > "$ALL_JSON"

run_and_collect() {
  local runtime="$1"; shift
  local model="$1"; shift
  local runner="$1"; shift

  local prefix="Running $runtime/$model"

  for r in $(seq 1 "$REPEATS"); do
    # Show progress bar
    show_progress "$r" "$REPEATS" "$prefix"

    # Get the command to run
    local cmd="$($runner "$model")"

    # Create temporary files for time output and program output
    local time_output=$(mktemp)
    local prog_output=$(mktemp)

    local start_time=$(date +%s.%N)
    local success=false
    local max_rss_bytes=0
    local duration_ms=0
    local use_program_memory=false

    # Run with appropriate time measurement (use global variables)
    if [[ "$HAS_MEMORY_MEASUREMENT" == "true" ]]; then
      # Use GNU time for detailed measurement
      if timeout 300s "$TIME_CMD" -v -o "$time_output" $cmd > "$prog_output" 2>&1; then
        local end_time=$(date +%s.%N)
        duration_ms=$(awk "BEGIN {printf \"%.0f\", ($end_time - $start_time) * 1000}")

        # Extract memory usage from time output (Maximum resident set size in KB)
        local max_rss_kb=$(grep "Maximum resident set size" "$time_output" | awk '{print $NF}' 2>/dev/null || echo "0")
        max_rss_bytes=$((max_rss_kb * 1024))
        success=true
      fi
    else
      # Fall back to basic timing and use program's own memory reporting
      if timeout 300s $cmd > "$prog_output" 2>&1; then
        local end_time=$(date +%s.%N)
        duration_ms=$(awk "BEGIN {printf \"%.0f\", ($end_time - $start_time) * 1000}")

        # Try to extract memory from program output if it's JSON
        local prog_out=$(cat "$prog_output")
        if echo "$prog_out" | jq . >/dev/null 2>&1; then
          local program_rss=$(echo "$prog_out" | jq -r '.rss_bytes // empty' 2>/dev/null)
          if [[ -n "$program_rss" && "$program_rss" != "null" ]]; then
            max_rss_bytes="$program_rss"
            use_program_memory=true
          else
            max_rss_bytes=0
          fi
        else
          max_rss_bytes=0
        fi
        success=true
      fi
    fi

    if [[ "$success" == "true" ]]; then
      # Get the program output
      local prog_out=$(cat "$prog_output")

      # Create our own JSON with measured values
      local combined_json
      if echo "$prog_out" | jq . >/dev/null 2>&1; then
        # Program output is valid JSON - merge with our measurements
        if [[ "$use_program_memory" == "true" ]]; then
          # Keep the program's memory measurement, only override duration
          combined_json=$(echo "$prog_out" | jq -c ". + {
            duration_ms: $duration_ms,
            runtime_alias: \"$runtime\",
            model_alias: \"$model\",
            repeat: $r,
            measured_externally: true,
            measurement_method: \"${TIME_CMD:-program-reported}\",
            memory_source: \"program\"
          }")
        else
          # Use our external measurements for both time and memory
          combined_json=$(echo "$prog_out" | jq -c ". + {
            duration_ms: $duration_ms,
            rss_bytes: $max_rss_bytes,
            runtime_alias: \"$runtime\",
            model_alias: \"$model\",
            repeat: $r,
            measured_externally: true,
            measurement_method: \"${TIME_CMD:-fallback}\",
            memory_source: \"external\"
          }")
        fi
      else
        # Program output is not JSON - create our own JSON
        combined_json=$(jq -n -c "{
          duration_ms: $duration_ms,
          rss_bytes: $max_rss_bytes,
          runtime_alias: \"$runtime\",
          model_alias: \"$model\",
          repeat: $r,
          measured_externally: true,
          measurement_method: \"${TIME_CMD:-fallback}\",
          memory_source: \"external\",
          threads: $THREADS,
          iterations: $ITERATIONS,
          keys: $KEYS,
          read_ratio: $READ_RATIO,
          seed: $SEED
        }")
      fi

      echo "$combined_json" >> "$ALL_JSON"
    else
      # Clear progress line and show error
      printf "\r%-80s\r" " "
      emit_error "Run failed for $runtime/$model (repeat $r)"
      if [ -f "$prog_output" ]; then
        emit_error "Program output: $(head -3 "$prog_output")"
      fi
    fi

    # Cleanup temp files
    rm -f "$time_output" "$prog_output"
  done

  # Complete the progress line and move to next line
  show_progress "$REPEATS" "$REPEATS" "$prefix"
  echo " ✓"
}

for rt in "${BUILD_AVAILABLE[@]}"; do
  case "$rt" in
    go)
      for m in "${GO_MODELS[@]}"; do run_and_collect "go" "$m" run_go; done
      ;;
    node)
      for m in "${NODE_MODELS[@]}"; do run_and_collect "node" "$m" run_node; done
      ;;
    deno)
      for m in "${DENO_MODELS[@]}"; do run_and_collect "deno" "$m" run_deno; done
      ;;
    bun)
      for m in "${BUN_MODELS[@]}"; do run_and_collect "bun" "$m" run_bun; done
      ;;
    java)
      for m in "${JAVA_MODELS[@]}"; do run_and_collect "java" "$m" run_java; done
      ;;
    csharp)
      for m in "${CS_MODELS[@]}"; do run_and_collect "csharp" "$m" run_csharp; done
      ;;
    python)
      for m in "${PY_MODELS[@]}"; do run_and_collect "python" "$m" run_python; done
      ;;
    php)
      for m in "${PHP_MODELS[@]}"; do run_and_collect "php" "$m" run_php; done
      ;;
    rust)
      for m in "${RUST_MODELS[@]}"; do run_and_collect "rust" "$m" run_rust; done
      ;;
    cpp)
      for m in "${CPP_MODELS[@]}"; do run_and_collect "cpp" "$m" run_cpp; done
      ;;
  esac
done

emit_info "Runs complete. Aggregating medians..."

# ========== AGGREGATION ==========
# Compute median duration_ms and rss_bytes per runtime/model pair

AGG_JSON="$OUTDIR/aggregate.json"
jq -s '
  group_by(.runtime_alias + "|" + .model_alias) |
  map({
    runtime: (.[0].runtime // .[0].runtime_alias),
    runtime_alias: .[0].runtime_alias,
    model: (.[0].model // .[0].model_alias),
    iterations: (.[0].iterations),
    threads: (.[0].threads),
    keys: (.[0].keys),
    read_ratio: (.[0].read_ratio),
    seed: (.[0].seed),
    duration_ms_median:
      ( [.[].duration_ms] | sort | .[ (length-1)/2 ] ),
    rss_bytes_median:
      ( [.[].rss_bytes] | sort | .[ (length-1)/2 ] ),
    repeats: (length)
  })
' "$ALL_JSON" > "$AGG_JSON"

emit_info "Aggregated to $AGG_JSON"

# Emit a Markdown table
cat > "$TABLE_OUT" <<MD
# Concurrent Map Benchmark Summary (median over repeats)

**Benchmark Configuration:**
- Threads: $THREADS
- Iterations: $ITERATIONS
- Keys: $KEYS
- Read Ratio: $READ_RATIO
- Seed: $SEED
- Repeats per variant: $REPEATS

| runtime | model | duration_ms (median) | rss_bytes (median) | rss_mb (median) |
|---|---|---:|---:|---:|
MD

jq -r '
  .[] |
  [
    (.runtime_alias // "n/a"),
    (.model // "n/a"),
    (.duration_ms_median // 0),
    (.rss_bytes_median // 0)
  ] | @tsv
' "$AGG_JSON" | while IFS=$'\t' read -r runtime model dur rss_bytes; do
  # Format bytes with thousands separators
  rss_bytes_formatted=$(printf "%'d" "$rss_bytes" 2>/dev/null || printf "%d" "$rss_bytes")

  # Calculate and format MB with 3 decimal places using awk for better float handling
  rss_mb_formatted=$(echo "$rss_bytes" | awk '{printf "%.3f", $1/1048576}')

  printf "| %s | %s | %s | %s | %s |\n" "$runtime" "$model" "$dur" "$rss_bytes_formatted" "$rss_mb_formatted" >> "$TABLE_OUT"
done

emit_info "Summary written to $TABLE_OUT"
echo
echo "Done. Files:"
echo "  - All runs: $ALL_JSON"
echo "  - Aggregate JSON: $AGG_JSON"
echo "  - Markdown summary: $TABLE_OUT"
