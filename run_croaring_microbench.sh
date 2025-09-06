#!/usr/bin/env bash
set -euo pipefail

# Build and run CRoaring microbenchmarks using zig cc/c++.
#
# Usage:
#   ./run_croaring_microbench.sh [DATA_DIR] [google-benchmark args]
#
# Notes:
# - Uses $CROARING_DIR if set; otherwise clones into /tmp/CRoaring.
# - Builds with CMake in <CROARING_DIR>/build-zig using zig cc/c++.
# - Builds only the 'bench' target and runs it.
# - By default, filters out benchmarks whose names contain 'cpp' or 'Cpp'.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CROARING_REMOTE="https://github.com/RoaringBitmap/CRoaring.git"

# Determine CRoaring directory:
if [[ -n "${CROARING_DIR:-}" ]]; then
  CROARING_DIR="$CROARING_DIR"
else
  CROARING_DIR="/tmp/CRoaring"
fi
BUILD_DIR="$CROARING_DIR/build-zig"
BUILD_TYPE="Release"

mkdir -p "$(dirname "$CROARING_DIR")"

if [[ -d "$CROARING_DIR/.git" ]]; then
  echo "[INFO] Updating CRoaring at $CROARING_DIR"
  git -C "$CROARING_DIR" fetch --tags --prune
  git -C "$CROARING_DIR" pull --ff-only || true
else
  echo "[INFO] Cloning CRoaring into $CROARING_DIR"
  git clone --depth=1 "$CROARING_REMOTE" "$CROARING_DIR"
fi

# Prefer Ninja if available
GENERATOR_SWITCHES=""
if command -v ninja >/dev/null 2>&1; then
  GENERATOR_SWITCHES="-G Ninja"
fi

# Ensure zig is available
if ! command -v zig >/dev/null 2>&1; then
  echo "[ERROR] zig not found in PATH. Install zig and retry." >&2
  exit 1
fi

# Function to detect if CPU supports AVX512
detect_avx512_support() {
  case "$(uname -s)" in
    Linux)
      # Check /proc/cpuinfo for AVX512 flags
      if grep -q "avx512" /proc/cpuinfo 2>/dev/null; then
        return 0  # AVX512 supported
      fi
      ;;
    Darwin)
      # On macOS, check sysctl for CPU features
      if sysctl -n machdep.cpu.leaf7_features 2>/dev/null | grep -q "AVX512"; then
        return 0  # AVX512 supported
      fi
      # Also check brand string for known AVX512 CPUs
      if sysctl -n machdep.cpu.brand_string 2>/dev/null | grep -qE "(Intel.*Core.*i[579]|Xeon|M[123])"; then
        # Most modern Intel CPUs support AVX512, but let's be conservative
        # and assume support unless we know otherwise
        return 0
      fi
      ;;
    *)
      # For other platforms, assume no AVX512 support by default
      ;;
  esac
  return 1  # AVX512 not supported or uncertain
}

# Detect AVX512 support
DISABLE_AVX512_FLAG=""
if ! detect_avx512_support; then
  echo "[INFO] AVX512 not detected or not supported, disabling AVX512 in CRoaring"
  DISABLE_AVX512_FLAG="-DROARING_DISABLE_AVX512=ON"
else
  echo "[INFO] AVX512 support detected, enabling AVX512 optimizations"
fi

# Configure with CMake using zig as the C/C++ compiler
mkdir -p "$BUILD_DIR"
echo "[INFO] Configuring CMake in $BUILD_DIR (BUILD_TYPE=$BUILD_TYPE)"
CC="zig cc" CXX="zig c++" \
  cmake -S "$CROARING_DIR" -B "$BUILD_DIR" \
  $GENERATOR_SWITCHES \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DENABLE_ROARING_MICROBENCHMARKS=ON \
  ${DISABLE_AVX512_FLAG}

# Build microbenchmarks (C-only by default: build 'bench' target)
echo "[INFO] Building microbenchmarks (bench only)"
cmake --build "$BUILD_DIR" --config "$BUILD_TYPE" --target bench --parallel

# Locate executables (handle generator differences)
BENCH_BIN="$BUILD_DIR/microbenchmarks/bench"
[[ -x "$BUILD_DIR/bench" ]] && BENCH_BIN="$BUILD_DIR/bench"

if [[ ! -x "$BENCH_BIN" ]]; then
  echo "[ERROR] bench executable not found (looked in $BUILD_DIR)" >&2
  exit 1
fi

# Run CRoaring bench and Zig bench, then compare
echo "[INFO] Running CRoaring bench (realdata)"

# Parse args: optional first positional DATA_DIR if it is a directory
DATA_ARG=""
if [[ $# -gt 0 && -d "$1" && "$1" != -* ]]; then
  DATA_ARG="$1"
  shift
  echo "[INFO] Using DATA_DIR=$DATA_ARG"
fi

# Add default filter unless user provided one
HAS_FILTER=0
for a in "$@"; do
  if [[ "$a" == --benchmark_filter* ]]; then
    HAS_FILTER=1
    break
  fi
done
DEFAULT_FILTER=""
if [[ $HAS_FILTER -eq 0 ]]; then
  # POSIX ERE: include only non-C++ microbenchmarks by explicit allowlist
  DEFAULT_FILTER='--benchmark_filter=^(SuccessiveIntersection(64|Cardinality(64)?)?|SuccessiveUnion(Cardinality(64)?|64)?|SuccessiveDifferenceCardinality(64)?|TotalUnion(Heap)?|RandomAccess(64)?|ToArray(64)?|IterateAll(64)?|ComputeCardinality(64)?|RankMany(Slow)?)$'
fi

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t croaring)"
trap 'rm -rf "$TMP_DIR"' EXIT

CROAR_OUT="$TMP_DIR/croaring.txt"
ZIG_OUT="$TMP_DIR/zig.txt"

"$BENCH_BIN" ${DATA_ARG:++"$DATA_ARG"} ${DEFAULT_FILTER:+"$DEFAULT_FILTER"} "$@" | tee "$CROAR_OUT"

echo "[INFO] Running Zig bench"
# Build Zig flags based on AVX512 detection
ZIG_AVX512_FLAG=""
if [[ -n "$DISABLE_AVX512_FLAG" ]]; then
  ZIG_AVX512_FLAG=" -DROARING_DISABLE_AVX512=true"
fi
FLAGS="$ZIG_AVX512_FLAG -Doptimize=ReleaseFast"

# Prefer same dataset directory for Zig if provided
if [[ -n "$DATA_ARG" ]]; then
  zig build $FLAGS bench -- "$DATA_ARG" 2>&1 | tee "$ZIG_OUT"
else
  # Use the same default dataset as CRoaring's bench
  zig build $FLAGS bench -- "$CROARING_DIR/benchmarks/realdata/census1881" 2>&1 | tee "$ZIG_OUT"
fi

echo "[INFO] Comparing results (ns per iteration)"
# Parse both outputs via awk and join by benchmark name in-memory
awk '
  FNR==1 { fi++ }
  $3=="ns" {
    name=$1; t=$2+0
    if (fi==1) c[name]=t; else if (fi==2) z[name]=t
  }
  END {
    for (n in c) if (n in z) printf "%s %d %d\n", n, c[n], z[n]
  }
' "$CROAR_OUT" "$ZIG_OUT" | sort >"$TMP_DIR/joined.txt"

echo "$(printf '%-36s %12s   %12s   %8s' 'Benchmark' 'CRoaring(ns)' 'Zig(ns)' 'Zig/CR')"
echo "$(printf '%-36s %12s   %12s   %8s' '---------' '-----------' '-------' '-----')"
awk '{name=$1; c=$2; z=$3; ratio=(c>0? z/c: 0); printf("%-36s %12d   %12d   %7.2fx\n", name, c, z, ratio)}' "$TMP_DIR/joined.txt"

echo "[INFO] Done."
