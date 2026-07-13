#!/usr/bin/env bash
#
# mayhem/build.sh — build the Pyverilog Atheris fuzz harness + its standalone reproducer,
# and prepare the project's own test suite. Runs inside the commit image (mayhem/Dockerfile)
# as `mayhem` in /mayhem. Python adaptation of the C/C++ template.
#
# What it does (must be idempotent + air-gapped on re-run — SPEC §6.2 item 9 / §6.5):
#   1. Populate / reuse an in-image wheelhouse under /opt/toolchains/python (HOME-independent),
#      then install atheris + pytest + pyverilog's runtime deps (jinja2, ply) OFFLINE from that
#      wheelhouse into a fixed site dir on PYTHONPATH. The first (CI, online) build fills the
#      wheelhouse; the air-gapped PATCH re-run resolves entirely from it. pyverilog itself is
#      exercised as its editable source tree (repo root on PYTHONPATH).
#   2. Pre-generate the PLY LALR parser tables into a fixed directory (the commit image is
#      mounted read-only during coverage collection, so the parser must never write at run time).
#   3. Compile launcher.c -> the ELF Mayhem target `pyverilog_fuzzer` (Atheris is a Python
#      script; Mayhem needs an ELF cmd, and the gate needs DWARF < 4 — hence a compiled wrapper).
#   4. Build the same launcher as the standalone (run-once) reproducer `pyverilog_fuzzer-standalone`.
#   5. Compile the pytest ELF runner wrapper `pyverilog_run_tests` (so the sabotage oracle bites).
#
# The base image exports the build contract (CC, SANITIZER_FLAGS, DEBUG_FLAGS, ...). We only need
# DEBUG_FLAGS here (the launcher is a thin C exec wrapper — sanitizing it would just instrument the
# wrapper, not the fuzzed Python; Atheris instruments the pyverilog library itself at import time).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export DEBUG_FLAGS CC MAYHEM_JOBS

SRC="${SRC:-/mayhem}"
cd "$SRC"

# ── Python toolchain caches at a FIXED, $HOME-independent prefix (SPEC §6.2 item 8) ──
PY_PREFIX=/opt/toolchains/python
WHEELHOUSE="$PY_PREFIX/wheelhouse"
SITE="$PY_PREFIX/site"
PLY_TABLES="$PY_PREFIX/plytables"
mkdir -p "$WHEELHOUSE" "$SITE" "$PLY_TABLES"

PY="$(command -v python3)"

# 1) Wheelhouse: download every runtime/test dependency ONCE (online). On the air-gapped re-run the
#    directory is already populated, so pip never reaches the network. atheris ships a prebuilt
#    manylinux wheel for this CPython. jinja2 + ply are pyverilog's install_requires; pytest runs
#    pyverilog's own suite.
PKGS=(atheris pytest jinja2 ply)
need_download=0
"$PY" -c "import os,glob,sys; sys.exit(0 if glob.glob(os.path.join('$WHEELHOUSE','atheris-*.whl')) else 1)" || need_download=1
if [ "$need_download" -eq 1 ]; then
  echo ">> populating wheelhouse (online) at $WHEELHOUSE"
  "$PY" -m pip download --dest "$WHEELHOUSE" "${PKGS[@]}"
else
  echo ">> wheelhouse already populated — reusing $WHEELHOUSE (air-gapped re-run path)"
fi

# 2) Install the deps into the fixed site dir, OFFLINE from the wheelhouse. --no-index +
#    --find-links guarantees no PyPI access (works on the air-gapped re-run). Idempotent: once the
#    site dir holds atheris+pytest+ply we SKIP the reinstall. pyverilog itself stays the editable
#    source tree (repo root on PYTHONPATH) so a PATCH agent's edits under pyverilog/ take effect
#    with no reinstall.
if "$PY" -c "import os,glob,sys; sys.exit(0 if (glob.glob(os.path.join('$SITE','atheris*')) and glob.glob(os.path.join('$SITE','pytest*')) and glob.glob(os.path.join('$SITE','ply*'))) else 1)"; then
  echo ">> deps already installed in $SITE — skipping (idempotent re-run)"
else
  echo ">> installing deps (offline) into $SITE"
  "$PY" -m pip install --no-index --find-links="$WHEELHOUSE" --target "$SITE" "${PKGS[@]}"
fi

# pyverilog is a top-level package at the repo root, so the repo root itself goes on PYTHONPATH.
PYRUN="$SITE:$SRC:$SRC/mayhem"

# Record the site dir + interpreter for test.sh / the launcher to consume.
cat > "$PY_PREFIX/env.sh" <<EOF
export PYTHONPATH="$PYRUN\${PYTHONPATH:+:\$PYTHONPATH}"
export PYTHON_BIN="$PY"
EOF

# Sanity: the harness imports must resolve offline now.
PYTHONPATH="$PYRUN" "$PY" -c 'import atheris, pyverilog, ply, jinja2, pytest; print("imports OK: pyverilog", pyverilog.__version__)'

# 3) Pre-generate the PLY LALR tables (parsetab.py) into the fixed, writable-at-build-time dir so
#    the parser only READS them at run time (read-only image during coverage collection).
PYTHONPATH="$PYRUN" PLY_TABLES_DIR="$PLY_TABLES" "$PY" -c "
from pyverilog.vparser.parser import VerilogParser
VerilogParser(outputdir='$PLY_TABLES', debug=False)
print('PLY tables generated in $PLY_TABLES')
"

# 4) Compile the ELF launcher target + the standalone reproducer (DWARF < 4 via $DEBUG_FLAGS).
#    The launcher execs $PY on the harness; PYTHONPATH is baked into the env the binary inherits
#    at run time (the Dockerfile sets ENV PYTHONPATH), so the Python side finds atheris + pyverilog.
HARNESS="$SRC/mayhem/fuzz_log.py"
echo ">> compiling pyverilog_fuzzer (+ standalone) with DEBUG_FLAGS=$DEBUG_FLAGS"
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/pyverilog_fuzzer"
# The standalone reproducer is the same launcher: libFuzzer runs a single input file once when the
# harness is given a file path (no fuzzing loop), which is exactly the run-once reproducer contract.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/pyverilog_fuzzer-standalone"

# 5) The pytest oracle runs through a compiled NON-system ELF wrapper so the gate's anti-reward-hack
#    sabotage check (which neuters non-system binaries to exit(0)) actually bites the suite.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" "$SRC/mayhem/run_tests.c" -o "$SRC/pyverilog_run_tests"

echo ">> build.sh complete"
ls -la "$SRC/pyverilog_fuzzer" "$SRC/pyverilog_fuzzer-standalone" "$SRC/pyverilog_run_tests"
