#!/usr/bin/env bash
#
# mayhem/test.sh -- RUN ArkScript's own boost-ext/ut unit-test suite (built by mayhem/build.sh
# at mayhem-build/test/unittests) PLUS four direct known-answer probes through the same build's
# dynamically-linked `arkscript` CLI. Two layers because a suite driven by its own runner binary
# is enough on its own here (the runner IS the dynamically-linked `unittests` executable, unlike
# a ctest/meson wrapper that launches a separate process the shim can neuter before it reads a
# fixture -- see SPEC 6.3/§4) -- but the KAT probes give a second, independent, minimal-surface
# proof that is trivial to eyeball and pins down exact VM output, not just "some suite passed".
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

TEST_BUILD="$SRC/mayhem-build/test"
RUNNER="$TEST_BUILD/unittests"
ORACLE_CLI="$TEST_BUILD/arkscript"

if [ ! -x "$RUNNER" ]; then
  echo "test.sh: test runner $RUNNER missing -- build.sh must build the 'unittests' target" >&2
  emit_ctrf "arkscript-unittests+kat" 0 1 0
  exit 1
fi
if [ ! -x "$ORACLE_CLI" ]; then
  echo "test.sh: oracle CLI $ORACLE_CLI missing -- build.sh must build the 'arkscript' target" >&2
  emit_ctrf "arkscript-unittests+kat" 0 1 0
  exit 1
fi

passed=0; failed=0; skipped=0

# ── Layer 1: upstream's ENTIRE unit suite (tests/unittests, all Suites/*.cpp: parser, compiler,
#    optimizer, type-checker, VM/lang, stdlib examples, rosetta, formatter, bytecode reader,
#    debugger, name resolution, embedding, REPL, ...). It asserts BEHAVIOUR (golden values/diffs),
#    so neutering the program to a no-op makes it FAIL. boost-ext/ut prints a per-suite summary;
#    run from $SRC since some resources resolve relative to the source root. Capture stdout+stderr
#    and strip ANSI colour codes so the counts parse -- we read the SUITE'S OWN reported numbers,
#    never the process exit code (§4: a neutered/exit(0) binary would still exit 0). ─────────────
run_log="$(cd "$SRC" && "$RUNNER" 2>&1)"; rc=$?
clean="$(printf '%s\n' "$run_log" | sed -E 's/\x1b\[[0-9;]*m//g')"
printf '%s\n' "$run_log"

# Per-suite pass line: "Suite 'X': all tests passed (<A> asserts in <M> tests)"
while IFS= read -r m; do passed=$(( passed + m )); done < <(
  printf '%s\n' "$clean" | sed -nE "s/^Suite '[^']+': all tests passed \([0-9]+ asserts in ([0-9]+) tests\).*/\1/p")
# Per-suite fail block: a "tests:   <T> | <F> failed" line following a "Suite X" header.
while IFS= read -r line; do
  t="$(printf '%s' "$line" | sed -nE 's/^tests:[[:space:]]+([0-9]+) \| [0-9]+ failed.*/\1/p')"
  f="$(printf '%s' "$line" | sed -nE 's/^tests:[[:space:]]+[0-9]+ \| ([0-9]+) failed.*/\1/p')"
  if [ -n "$t" ] && [ -n "$f" ]; then
    failed=$(( failed + f )); passed=$(( passed + t - f ))
  fi
done < <(printf '%s\n' "$clean" | grep -E '^tests:[[:space:]]+[0-9]+ \|')
k="$(printf '%s\n' "$clean" | sed -nE 's/^([0-9]+) tests skipped.*/\1/p' | head -1)"
[ -n "$k" ] && skipped="$k"

# Never let a nonzero runner exit (or an unparseable log) become a silent pass.
if [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi
if [ "$passed" -eq 0 ] && [ "$failed" -eq 0 ]; then
  echo "test.sh: could not parse unittests summary" >&2; failed=1
fi

# ── Layer 2: direct known-answer probes through the dynamically-linked oracle CLI (`arkscript
#    -e <expr>`), each asserting an EXACT stdout line via grep -qxF (whole-line, fixed-string --
#    not a substring/pattern match). This is what actually catches the LD_PRELOAD sabotage shim:
#    the shim's constructor _exit(0)s any non-system dynamically-linked executable it's preloaded
#    into BEFORE `arkscript` ever reaches `(print ...)`, so its stdout goes empty and every one of
#    these greps fails -- verified in step (2) below. ──────────────────────────────────────────
kat() {
  local name="$1" expr="$2" expected="$3"
  local out
  out="$("$ORACLE_CLI" -e "$expr" 2>/dev/null)"
  if printf '%s\n' "$out" | grep -qxF "$expected"; then
    echo "KAT_${name}=${expected} (ok)"
    passed=$(( passed + 1 ))
  else
    echo "KAT_${name}: expected exact line '${expected}', got: ${out}" >&2
    failed=$(( failed + 1 ))
  fi
}

kat ARITH        "(print (+ 40 2))"                                                          "42"
kat LIST_LITERAL  "(print (list 1 2 3))"                                                       "[1 2 3]"
kat FACT10        "(let fact (fun (n) (if (<= n 1) 1 (* n (fact (- n 1)))))) (print (fact 10))" "3628800"
kat FORMAT        "(print (format \"{}-{}\" 1 2))"                                             "1-2"

emit_ctrf "arkscript-unittests+kat" "$passed" "$failed" "$skipped"
