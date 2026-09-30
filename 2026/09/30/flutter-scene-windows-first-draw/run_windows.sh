#!/usr/bin/env bash
# Ships app/ to a Windows PC over ssh, builds it in release with flutter_scene's
# pipeline profiling on, runs it as an interactive scheduled task (a GUI app
# cannot show from the ssh session), and prints the result file.
#
#   WIN_HOST=user@windows-pc ./run_windows.sh [REF]
#
# REF is the flutter_scene commit to test (default: the one in app/pubspec.yaml).
# STEPS, SHADOW and IDLE_MS are passed to the app (see app/lib/main.dart);
# RUNS=2 launches the same build twice.
#
# PROXY=1 puts the stand-in d3dcompiler_47.dll (d3dproxy/, built on the Windows
# PC with its build.cmd into PROXY_DIR) next to the app and prints every
# shader compile it saw. With it: CACHE=1 keeps compiled shaders on disk
# across launches, OPT=0|1|2|3|skip replaces the optimization flags, DUMP=1
# saves the HLSL sources.
set -euo pipefail
: "${WIN_HOST:?set WIN_HOST, e.g. user@windows-pc}"
LAB="$(cd "$(dirname "$0")" && pwd)"
REF="${1:-}"
# APP=flutter_only runs the plain Flutter reproduction instead of app/.
APP="${APP:-app}"
EXE="$([[ "$APP" == app ]] && echo first_draw || echo "$APP").exe"
DIR=labtmp_first_draw
WIN_DIR="C:\\Users\\$(echo "$WIN_HOST" | cut -d@ -f1 | sed 's/.*@//')\\$DIR"
ssh_() { ssh -o LogLevel=ERROR "$WIN_HOST" "$@"; }

work="$(mktemp -d)"
cp -R "$LAB/$APP" "$work/app"
rm -rf "$work/app/build" "$work/app/.dart_tool" "$work/app/macos"
if [[ -n "$REF" ]]; then
  sed -i '' -E "s/ref: [0-9a-f]{7,40}/ref: $REF/" "$work/app/pubspec.yaml"
fi
(cd "$work" && COPYFILE_DISABLE=1 tar czf app.tgz app)

ssh_ "if exist $WIN_DIR rmdir /s /q $WIN_DIR" || true
ssh_ "mkdir $WIN_DIR"
scp -q -o LogLevel=ERROR "$work/app.tgz" "${WIN_HOST}:$DIR/app.tgz"
ssh_ "cd $WIN_DIR && tar xzf app.tgz && cd app && flutter pub get >nul 2>&1 && flutter build windows --release --dart-define=FLUTTER_SCENE_PROFILE=true >$WIN_DIR\\build.log 2>&1" \
  || { ssh_ "type $WIN_DIR\\build.log" | tail -20; exit 1; }

REL="$WIN_DIR\\app\\build\\windows\\x64\\runner\\Release"
{
  printf 'set OUT=%s\\result.txt\r\nset STEPS=%s\r\nset SHADOW=%s\r\nset IDLE_MS=%s\r\n' \
    "$WIN_DIR" "${STEPS:-unlit,pbr,skinned,skinned}" "${SHADOW:-1}" "${IDLE_MS:-1000}"
  if [[ -n "${PROXY:-}" ]]; then
    printf 'set D3DPROXY_LOG=%s\\d3d.csv\r\n' "$WIN_DIR"
    if [[ -n "${CACHE:-}" ]]; then printf 'set D3DPROXY_CACHE=%s\\cache\r\n' "$WIN_DIR"; fi
    if [[ -n "${DUMP:-}" ]]; then printf 'set D3DPROXY_DUMP=%s\\dump\r\n' "$WIN_DIR"; fi
    if [[ -n "${OPT:-}" ]]; then printf 'set D3DPROXY_OPT=%s\r\n' "$OPT"; fi
  fi
  printf '"%s\\%s"\r\n' "$REL" "$EXE"
} > "$work/run.cmd"
if [[ -n "${PROXY:-}" ]]; then
  PROXY_DIR="${PROXY_DIR:-C:\\Users\\$(echo "$WIN_HOST" | cut -d@ -f1)\\labtmp_proxy}"
  ssh_ "copy /y $PROXY_DIR\\d3dcompiler_47.dll $REL\\ >nul && copy /y C:\\Windows\\System32\\d3dcompiler_47.dll $REL\\d3dcompiler_47_sys.dll >nul && mkdir $WIN_DIR\\cache $WIN_DIR\\dump"
fi
scp -q -o LogLevel=ERROR "$work/run.cmd" "${WIN_HOST}:$DIR/run.cmd"
ssh_ "schtasks /create /tn FirstDraw /tr $WIN_DIR\\run.cmd /sc once /st 23:59 /it /f >nul"
# RUNS=2 launches the same build again, to see whether anything is cached
# across launches.
for run in $(seq 1 "${RUNS:-1}"); do
  echo "== launch $run"
  ssh_ "del /q $WIN_DIR\\result.txt 2>nul & schtasks /run /tn FirstDraw >nul"
  for _ in $(seq 1 120); do
    ssh_ "findstr /c:\"] done\" $WIN_DIR\\result.txt >nul 2>&1" && break
    sleep 3
  done
  ssh_ "type $WIN_DIR\\result.txt" | grep -v "not ready\|You may wait" || true
  if [[ -n "${PROXY:-}" ]]; then
    ssh_ "if exist $WIN_DIR\\d3d.csv (type $WIN_DIR\\d3d.csv & del /q $WIN_DIR\\d3d.csv)" | python3 -c "
import sys
rows = [l.strip().split(',') for l in sys.stdin if l.count(',') >= 7]
total = sum(float(r[1]) for r in rows)
print(f'   d3d compiles: {len(rows)}, {total/1000:.2f} s in total')
for r in sorted(rows, key=lambda r: -float(r[1]))[:8]:
    print(f'   {float(r[1]):8.0f} ms  at {float(r[0])/1000:6.2f} s  {r[4]:7} {r[3]:>7} bytes  key {r[2]}  {r[7]}')
"
  fi
  ssh_ "taskkill /im $EXE /f >nul 2>&1" || true
  sleep 2
done
ssh_ "taskkill /im $EXE /f >nul 2>&1 & schtasks /delete /tn FirstDraw /f >nul" || true
[[ -n "${KEEP:-}" ]] || ssh_ "rmdir /s /q $WIN_DIR" || true
rm -rf "$work"
