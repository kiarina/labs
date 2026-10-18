#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work/thinker-sandbox
say -v Kyoko -r 190 -o work/delegation-request.aiff '商品コード A17 の在庫を調べ、予約分を引いた利用可能数を日本語で教えてください。'
ffmpeg -v error -y -i work/delegation-request.aiff -ac 1 -ar 24000 -f s16le work/delegation-request.pcm
