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
set -euo pipefail
: "${WIN_HOST:?set WIN_HOST, e.g. user@windows-pc}"
LAB="$(cd "$(dirname "$0")" && pwd)"
REF="${1:-}"
DIR=labtmp_first_draw
WIN_DIR="C:\\Users\\$(echo "$WIN_HOST" | cut -d@ -f1 | sed 's/.*@//')\\$DIR"
ssh_() { ssh -o LogLevel=ERROR "$WIN_HOST" "$@"; }

work="$(mktemp -d)"
cp -R "$LAB/app" "$work/app"
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

printf 'set OUT=%s\\result.txt\r\nset STEPS=%s\r\nset SHADOW=%s\r\nset IDLE_MS=%s\r\n"%s\\app\\build\\windows\\x64\\runner\\Release\\first_draw.exe"\r\n' \
  "$WIN_DIR" "${STEPS:-unlit,pbr,skinned,skinned}" "${SHADOW:-1}" "${IDLE_MS:-1000}" "$WIN_DIR" > "$work/run.cmd"
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
  ssh_ "taskkill /im first_draw.exe /f >nul 2>&1" || true
  sleep 2
done
ssh_ "taskkill /im first_draw.exe /f >nul 2>&1 & schtasks /delete /tn FirstDraw /f >nul" || true
ssh_ "rmdir /s /q $WIN_DIR" || true
rm -rf "$work"
