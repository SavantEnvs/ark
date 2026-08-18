#!/usr/bin/env bash
#
# mayhem/build.sh -- build ArkScript's in-process libFuzzer harness (compiles AND executes the
# fuzzer bytes as ArkScript source, matching upstream's OWN AFL fuzz setup at
# tests/fuzzing/docker/2-fuzz.sh, which runs `arkscript @@ -L lib` -- compile+run, not compile
# only) plus a standalone reproducer, AND upstream's own boost-ext/ut unit-test suite + a
# dynamically-linked `arkscript` CLI used by mayhem/test.sh for direct KAT probes.
#
# Two independent, non-conflicting build trees (SPEC 6.2/PORTING "dual build is usually free"):
#   mayhem-build/fuzz  -- ArkReactor compiled STATIC with $SANITIZER_FLAGS + $DEBUG_FLAGS +
#                         -fsanitize=fuzzer-no-link (UNCONDITIONALLY, so the LIBRARY carries
#                         SanitizerCoverage even under an explicit empty --build-arg
#                         SANITIZER_FLAGS=) and -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION (this
#                         is an ArkScript-recognised macro, NOT auto-defined by clang -- verified
#                         empirically -- that upstream itself uses to compile OUT `sys:exec`
#                         (Builtins/System.cpp) and a bytecode self-hash integrity check
#                         (State.cpp) specifically for fuzzing builds; see the harness header for
#                         why that sandboxes the target).
#   mayhem-build/test  -- ArkReactor's NORMAL (project default: dynamic .so) build, with
#                         ARK_TESTS=On ARK_BUILD_EXE=On ARK_BUILD_MODULES=On ARK_MOD_ALL=On,
#                         matching upstream CI's own test configuration (the suite imports the
#                         `hash` native module and the `testmodule` test fixture module). This
#                         also builds a normal, dynamically-linked `arkscript` CLI for free --
#                         mayhem/test.sh uses it for KAT probes (a static binary would be immune
#                         to verify-repo's LD_PRELOAD sabotage shim).
#
# SUBMODULES / AIR-GAP (SPEC 6.5): the repo vendors its stdlib (lib/std, lib/modules) and
# thirdparties/* as git submodules with NO FetchContent/network fetch inside CMake itself. A
# plain `git clone` of the mayhem branch (what the CI checkout and a re-run both start from)
# carries only the gitlinks, so `git submodule update --init --recursive` populates them here.
# The first (online) `docker build` does this once and bakes the checked-out submodule content
# into the image layer; the OFFLINE re-run (`docker run --network none ... build.sh`) finds every
# submodule already at its recorded commit, so `git submodule update` is a verified no-op that
# touches no network (this is also upstream's own CI checkout shape: submodules:recursive).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) -- it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# Always ensure the LIBRARY gets SanitizerCoverage instrumentation, regardless of the base image's
# default or an empty override (see header comment) -- otherwise Mayhem would see 0 edges from the
# parser/compiler/VM despite the harness TU itself being instrumented via $LIB_FUZZING_ENGINE.
case "$SANITIZER_FLAGS" in
  *fuzzer-no-link*) ;;  # already present
  *) SANITIZER_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link" ;;
esac
# DWARF <= 3 (SPEC 6.2 item 10): clang-19's plain -g emits DWARF-5; be explicit.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS

: "${SRC:=/mayhem}"
cd "$SRC"

# ── 0) Vendored submodules (stdlib + thirdparties). See header -- a verified no-op on re-run. ──
git config --global --add safe.directory "$SRC" 2>/dev/null || true
git submodule update --init --recursive

BUILD_ROOT="$SRC/mayhem-build"
mkdir -p "$BUILD_ROOT"

# ── 1) Sanitized ArkReactor: STATIC (self-contained -- the fuzz binary never needs to locate a
#       .so at runtime), $SANITIZER_FLAGS + $DEBUG_FLAGS + fuzzer-no-link (SanCov) +
#       FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION. ARK_BUILD_MODULES=Off: no native .arkm modules
#       are built into this tree, so `import` from fuzzed code can only ever pull in pure
#       ArkScript source, never native code (see the harness's SANDBOXING note).
#       ARK_ENABLE_SYSTEM=Off is belt-and-suspenders on top of the FUZZING_BUILD_MODE macro that
#       already compiles sys:exec's implementation out. ────────────────────────────────────────
FUZZ_BUILD="$BUILD_ROOT/fuzz"
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION"
cmake -S "$SRC" -B "$FUZZ_BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DARK_BUILD_EXE=Off -DARK_TESTS=Off -DARK_STATIC=On \
  -DARK_BUILD_MODULES=Off -DARK_BENCHMARKS=Off -DARK_SANITIZERS=Off -DARK_ENABLE_SYSTEM=Off \
  -DCMAKE_C_FLAGS="$FUZZ_CFLAGS" \
  -DCMAKE_CXX_FLAGS="$FUZZ_CFLAGS"
cmake --build "$FUZZ_BUILD" -j"$MAYHEM_JOBS" --target ArkReactor

ARK_INC=(-I"$SRC/include" -I"$SRC/thirdparties/fmt/include" -I"$SRC/thirdparties/picosha2")
ARK_LIBS=("$FUZZ_BUILD/libArkReactor.a" "$FUZZ_BUILD/libnewlib.a")

# ── 2) The harness: compile+link TWICE (fuzz target + standalone reproducer), matching every
#       other C/C++ integration in this fleet. The standalone driver is C: compiling it with the
#       C++ compiler would mangle its `LLVMFuzzerTestOneInput` reference and the link would fail
#       to find our harness's `extern "C"` definition. ─────────────────────────────────────────
HARNESS="$SRC/mayhem/harnesses/fuzz_arkscript.cpp"

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++20 "${ARK_INC[@]}" "$HARNESS" \
    $LIB_FUZZING_ENGINE "${ARK_LIBS[@]}" \
    -o /mayhem/arkscript

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD_ROOT/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++20 "${ARK_INC[@]}" "$HARNESS" \
    "$BUILD_ROOT/standalone_main.o" "${ARK_LIBS[@]}" \
    -o /mayhem/arkscript-standalone

echo "built /mayhem/arkscript (+ standalone)"

# The harness resolves `import`s against "/mayhem/fuzz-lib" (see its SANDBOXING note) -- a
# DEDICATED copy of just lib/std, deliberately NOT $SRC/lib itself. $SRC IS /mayhem (the commit
# image COPYs the checkout there), and step 3 below builds the `hash` NATIVE module into
# $SRC/lib/hash.arkm as a POST_BUILD copy (lib/modules/src/hash/CMakeLists.txt) -- if the harness
# pointed at $SRC/lib directly, that native module would become importable from fuzzed code by
# the time this script finishes, contradicting the "no native modules reachable" sandboxing this
# build is supposed to guarantee. A private copy, made before that happens, keeps the promise
# true regardless of step ordering.
rm -rf /mayhem/fuzz-lib
mkdir -p /mayhem/fuzz-lib
cp -r "$SRC/lib/std" /mayhem/fuzz-lib/std

# ── 3) Upstream's OWN unit-test suite (mayhem/test.sh only RUNS these -- never compiles), PLUS a
#       normal, dynamically-linked `arkscript` CLI (ARK_STATIC left at its Off default) for direct
#       KAT probes. This is a SEPARATE, clean tree -- no sanitizer, no DWARF override, project
#       NORMAL flags -- so it stays an honest, unhalted functional oracle. Configuration matches
#       upstream CI (setup-compilers): the suite imports the `hash` native module and the
#       `testmodule` test-fixture module, both built via ARK_BUILD_MODULES/ARK_MOD_ALL. ──────────
TEST_BUILD="$BUILD_ROOT/test"
cmake -S "$SRC" -B "$TEST_BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DARK_TESTS=On -DARK_BUILD_EXE=On \
  -DARK_BUILD_MODULES=On -DARK_MOD_ALL=On -DARK_BENCHMARKS=Off -DARK_SANITIZERS=Off
cmake --build "$TEST_BUILD" -j"$MAYHEM_JOBS" --target unittests arkscript testmodule hash

if ! file "$TEST_BUILD/arkscript" | grep -q 'dynamically linked'; then
  echo "FATAL: $TEST_BUILD/arkscript is not dynamically linked -- the sabotage check could not" >&2
  echo "       neuter it, which would make mayhem/test.sh a reward-hackable oracle." >&2
  file "$TEST_BUILD/arkscript" >&2
  exit 1
fi

echo "build.sh: done"
ls -la /mayhem/arkscript /mayhem/arkscript-standalone "$TEST_BUILD/unittests" "$TEST_BUILD/arkscript"
