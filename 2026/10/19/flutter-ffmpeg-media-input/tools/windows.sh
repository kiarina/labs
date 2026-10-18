#!/usr/bin/env bash
set -euo pipefail
: "${WIN_HOST:?set WIN_HOST to the Windows SSH destination}"
cd "$(dirname "$0")/.."
name=labtmp_media_input_20261019
user="$(ssh -o LogLevel=ERROR "$WIN_HOST" 'echo %USERNAME%' | tr -d '\r')"
dir="C:\\Users\\$user\\$name"
mkdir -p work
COPYFILE_DISABLE=1 tar czf work/windows.tgz --exclude='*/build' --exclude='*/.dart_tool' --exclude='*/Pods' --exclude='*/ephemeral' --exclude='*/.symlinks' --exclude='*/.swiftpm' app packages
ssh -o LogLevel=ERROR "$WIN_HOST" "if not exist $dir mkdir $dir"
scp -q -o LogLevel=ERROR work/windows.tgz "$WIN_HOST:$name/windows.tgz"
ssh -o LogLevel=ERROR "$WIN_HOST" "cd $dir && tar xzf windows.tgz"
python3 - "$dir" <<'PY'
import sys
from pathlib import Path
d=sys.argv[1]
s=f'''@echo off
cd /d {d}\\app
call flutter pub get > {d}\\build.log 2>&1
call flutter build windows --release --dart-define=AUTO=file --dart-define=AUTO_EXIT=true >> {d}\\build.log 2>&1
set result=%ERRORLEVEL%
echo done=%result% >> {d}\\build.log
if %result%==0 "{d}\\app\\build\\windows\\x64\\runner\\Release\\media_input_lab.exe"
'''
Path('work/build.cmd').write_bytes(s.replace('\n','\r\n').encode())
PY
scp -q -o LogLevel=ERROR work/build.cmd "$WIN_HOST:$name/build.cmd"
ssh -o LogLevel=ERROR "$WIN_HOST" "schtasks /create /tn MediaInputLab20261019 /tr $dir\\build.cmd /sc once /st 23:59 /it /f >nul && schtasks /run /tn MediaInputLab20261019 >nul"
echo "Dispatched. Inspect $dir\\build.log, then collect the app's report.json."
