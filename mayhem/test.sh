#!/usr/bin/env bash
#
# mayhem/test.sh — RUN Pyverilog's own test suite (deps already installed by mayhem/build.sh)
# and emit a CTRF (ctrf.io) summary. exit 0 iff failed==0. PATCH-grade oracle: the suite asserts
# golden AST dumps / dataflow term listings / regenerated Verilog code against expected strings,
# so a no-op patch that neuters the library FAILS here (anti-reward-hacking).
#
# It does NOT compile — build.sh installed pytest + deps into the in-image site dir and compiled
# the pyverilog_run_tests ELF wrapper. We only RUN the suite. The suite is routed through that
# compiled NON-system wrapper so the gate's sabotage check (neuter non-system binaries to exit(0))
# actually perturbs the run (the CPython interpreter under /usr/bin would otherwise be spared).
#
# The suite (tests/{parser_test,dataflow_test,ast_code_generator_test,preprocessor_test}) needs
# Icarus Verilog's `iverilog -E` for preprocessing — installed in the image by mayhem/Dockerfile.
# The parser writes PLY tables + preprocess.output into the CWD, so we run from a writable /tmp dir.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"

SRC="${SRC:-/mayhem}"

# Put the in-image site dir (atheris + pytest + ply + jinja2) and the pyverilog source tree on PYTHONPATH.
PY_PREFIX=/opt/toolchains/python
# shellcheck disable=SC1091
[ -f "$PY_PREFIX/env.sh" ] && source "$PY_PREFIX/env.sh"
export PYTHONPATH="$PY_PREFIX/site:$SRC${PYTHONPATH:+:$PYTHONPATH}"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

RUNNER="$SRC/pyverilog_run_tests"
if [ ! -x "$RUNNER" ]; then
  echo "test.sh: $RUNNER missing/not executable — mayhem/build.sh must build it first" >&2
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

# Run the ENTIRE upstream suite from a writable scratch dir (the parser drops parsetab.py /
# parser.out / preprocess.output into the CWD; the image dir may be mounted read-only).
WORK="$(mktemp -d)"
LOG="$(mktemp)"
( cd "$WORK" && "$RUNNER" -p no:cacheprovider -o addopts= -q "$SRC/tests" ) 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# Parse pytest's summary line, e.g. "27 passed in 12.3s" / "1 failed, 26 passed in ...".
line="$(grep -E '^(=+ )?[0-9].*(passed|failed|error|skipped)' "$LOG" | tail -1)"
get() { echo "$line" | grep -oE "[0-9]+ $1" | grep -oE '^[0-9]+' | head -1; }
passed="$(get passed)";  passed="${passed:-0}"
failed="$(get failed)";  failed="${failed:-0}"
errors="$(get error)";   errors="${errors:-0}"
skipped="$(get skipped)"; skipped="${skipped:-0}"
rm -rf "$LOG" "$WORK"

# pytest errors (collection/setup) count as failures for the oracle.
failed=$(( failed + errors ))

# If pytest itself could not run (rc!=0 and no parseable counts), report a failure.
if [ "$(( passed + failed + skipped ))" -eq 0 ] && [ "$rc" -ne 0 ]; then
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

emit_ctrf "pytest" "$passed" "$failed" "$skipped"
