#!/usr/bin/env bash
# native-check.sh — one-command container gate for native/ (NATIVE_PORT 4-2: T0 + render smoke).
#
# 가설: ✅ "import → 헤드리스 T0 → Xvfb Mobile 스모크 샷" 3단이 모두 exit 0이면 골격(엔진 4.7.2,
#       ext .so 로드, 렌더 경로)이 살아 있다. 실패한 단계 이름이 곧 고칠 곳이다.
#
# Usage: tools/native-check.sh [--no-build-ext] [--no-shot] [-- <run_tests.gd args, e.g. --suite=all>]
# Steps:
#   1. ext   tools/godot/build_ext.sh (incremental; skipped with --no-build-ext or without cmake/c++)
#   2. import  godot --headless --path native --import  (registers .gdextension, builds class cache)
#   3. T0    godot --headless --path native -s res://tests/run_tests.gd -- <args>   (exit = fails)
#   4. shot  xvfb-run ... --rendering-method mobile -s res://tests/shot.gd -- --shot=<out>/smoke_mobile.png
# Env: GODOT (default godot47, falls back to godot with a warning), NATIVE_PROJ (default native/), NATIVE_CHECK_OUT
#      (default native/build/native-check; gitignored and hidden from the Godot importer).
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROJ=${NATIVE_PROJ:-$ROOT/native}
OUT=${NATIVE_CHECK_OUT:-$PROJ/build/native-check}
BUILD_EXT=1 SHOT=1
TEST_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build-ext) BUILD_EXT=0 ;;
    --no-shot) SHOT=0 ;;
    --) shift; TEST_ARGS=("$@"); break ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (test args go after --)" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "${GODOT:-}" ]; then
  if command -v godot47 >/dev/null; then GODOT=godot47
  elif command -v godot >/dev/null; then
    GODOT=godot
    echo "[native-check] WARN: godot47 not found, using $(godot --version 2>/dev/null | tail -1)." \
         "The ext (compatibility_minimum 4.7) will not load; install with tools/godot/install_godot_nix.sh" >&2
  else echo "[native-check] FAIL: no godot47/godot on PATH" >&2; exit 2
  fi
fi

mkdir -p "$OUT" "$PROJ/build"
touch "$PROJ/build/.gdignore"
declare -a RESULTS=()
FAILED=0
step() { # step <name> <rc>
  RESULTS+=("$1=$([ "$2" = 0 ] && echo ok || echo "FAIL($2)")")
  [ "$2" = 0 ] || FAILED=1
}

echo "[native-check] engine: $("$GODOT" --headless --version 2>/dev/null | tail -1) ($GODOT)"

# 1. ext -------------------------------------------------------------------------------------------
if [ "$BUILD_EXT" = 1 ]; then
  if command -v cmake >/dev/null && command -v c++ >/dev/null; then
    GODOT="$GODOT" bash "$ROOT/tools/godot/build_ext.sh" > "$OUT/build_ext.log" 2>&1
    rc=$?; tail -n 4 "$OUT/build_ext.log"; step ext $rc
  else
    echo "[native-check] INFO: cmake/c++ missing, skipping ext build (test_ext will SKIP)"; RESULTS+=("ext=skipped")
  fi
fi

# 2. import ----------------------------------------------------------------------------------------
# Seed .godot/extension_list.cfg with every tracked *.gdextension before the first scan. Without it a
# fresh checkout discovers the ext mid-scan, EditorHelp regenerates docs on a worker thread, and
# `--import` quits under it: SIGSEGV in EditorLog::add_message from EditorHelp::_load_doc_thread
# (Godot 4.7.2 race, reproduced 3/3 on a clean .godot; 0/3 once seeded).
seed_extension_list() {
  local list="$PROJ/.godot/extension_list.cfg" manifest res
  mkdir -p "$PROJ/.godot"; touch "$list"
  while IFS= read -r manifest; do
    res="res://${manifest#"$PROJ"/}"
    grep -qxF "$res" "$list" || echo "$res" >> "$list"
  done < <(find "$PROJ" -name '*.gdextension' -not -path '*/.godot/*' -not -path '*/godot-cpp/*' \
             -not -path '*/build/*' | sort)
}
seed_extension_list
run_import() { "$GODOT" --headless --path "$PROJ" --import > "$OUT/import.log" 2>&1; }
run_import
rc=$?
if [ "$rc" -ge 128 ]; then
  echo "[native-check] WARN: importer died with signal $((rc - 128)); retrying once (see $OUT/import.log.crash)"
  cp "$OUT/import.log" "$OUT/import.log.crash"
  run_import; rc=$?
fi
# A broken script or manifest shows up as ERROR lines even when the importer exits 0. A missing
# Linux ext library is expected when it was not built (test_ext SKIPs), so those lines are tolerated.
ext_lib="$PROJ/ext/bin/libtraffic.linux.template_debug.x86_64.so"
ignore='^$'
[ -f "$ext_lib" ] || ignore='dynamic library|GDExtension dynamic library not found|Error loading extension'
errors=$(grep -E '^(ERROR|SCRIPT ERROR)' "$OUT/import.log" | grep -Ev "$ignore" || true)
if [ -n "$errors" ]; then
  echo "$errors" | head -n 20
  [ "$rc" = 0 ] && rc=1
fi
[ -f "$ext_lib" ] || echo "[native-check] INFO: $ext_lib absent; ext load errors ignored, test_ext will SKIP"
step import $rc

# 3. T0 headless tests -----------------------------------------------------------------------------
"$GODOT" --headless --path "$PROJ" -s res://tests/run_tests.gd -- "${TEST_ARGS[@]}" 2>&1 | tee "$OUT/t0.log" \
  | grep -E '^(PASS|FAIL|SKIP|INFO|DONE|SUMMARY|SCRIPT ERROR|ERROR)'
rc=${PIPESTATUS[0]}
grep -q '^SUMMARY ' "$OUT/t0.log" || { echo "[native-check] runner printed no SUMMARY (crash?)"; [ "$rc" = 0 ] && rc=1; }
step t0 $rc

# 4. Xvfb Mobile smoke shot ------------------------------------------------------------------------
if [ "$SHOT" = 1 ]; then
  if command -v xvfb-run >/dev/null; then
    rm -f "$OUT/smoke_mobile.png"
    xvfb-run -a -s "-screen 0 1280x1024x24" "$GODOT" --path "$PROJ" --rendering-method mobile \
      --audio-driver Dummy -s res://tests/shot.gd -- --shot="$OUT/smoke_mobile.png" > "$OUT/shot.log" 2>&1
    rc=$?
    grep -E '^(RESULT|FAIL|INFO)' "$OUT/shot.log"
    [ -s "$OUT/smoke_mobile.png" ] || { [ "$rc" = 0 ] && rc=1; }
    step shot $rc
  else
    echo "[native-check] INFO: xvfb-run missing, skipping render smoke"; RESULTS+=("shot=skipped")
  fi
fi

echo "[native-check] ${RESULTS[*]}  (logs: $OUT)"
[ "$FAILED" = 0 ] && echo "[native-check] GREEN" || echo "[native-check] RED"
exit "$FAILED"
