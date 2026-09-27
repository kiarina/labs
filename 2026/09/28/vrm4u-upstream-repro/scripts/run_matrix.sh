#!/usr/bin/env bash
# Every run behind the README tables. Each variant starts from the pristine
# pinned VRM4U tree (setup), applies its patches, rebuilds, then runs.
set -u
cd "$(dirname "$0")/.."
: "${UE_ROOT:?Set UE_ROOT to the Unreal Engine 5.8 installation directory}"

variant() {
    echo "### variant $1: ${*:2}"
    mise run setup "${@:2}" >/dev/null || exit 1
    mise run build > .cache/build.log 2>&1 || { tail -20 .cache/build.log; exit 1; }
}
run() { mise run run "$@" > /dev/null 2>&1; }

variant upstream 00-mac-build
run game load upstream-game-load
run pie load upstream-pie-load
run import load upstream-import

variant fix02 00-mac-build 02-runtime-skip-postprocess-abp
run game load fix02-game-load
for f in 0 2000; do for t in 1 2; do run pie load "fix02-pie-load-filler$f-$t" --filler $f; done; done
for t in 1 2; do run pie load "fix02-pie-shot-$t" --shot; done
for m in Seed-san Seed-san-thinned; do run pie spring "fix02-pie-spring-$m" --model "$m.vrm"; done

variant fix01+02 00-mac-build 01-runtime-curve-metadata-no-transaction 02-runtime-skip-postprocess-abp
run game load fix01+02-game-load
run import load fix01+02-import

variant fix02+03 00-mac-build 02-runtime-skip-postprocess-abp 03-runtime-skip-material-update-context
for f in 0 2000; do for t in 1 2; do run pie load "fix02+03-pie-load-filler$f-$t" --filler $f; done; done
for t in 1 2; do run pie load "fix02+03-pie-shot-$t" --shot; done

variant fix02+04 00-mac-build 02-runtime-skip-postprocess-abp 04-vrm1-spring-head-tail-axis
for m in Seed-san Seed-san-thinned; do run pie spring "fix02+04-pie-spring-$m" --model "$m.vrm"; done

python3 scripts/summarize_matrix.py > results/summary.md
cat results/summary.md
