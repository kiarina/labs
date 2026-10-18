#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work
mise run //:test-assets:download
npm install --prefix work/cli --no-audit --no-fund @openai/codex@0.163.0
npm install --prefix work/cli-old --no-audit --no-fund @openai/codex@0.159.3
work/cli-old/node_modules/.bin/codex app-server generate-json-schema --experimental --out work/schema
work/cli/node_modules/.bin/npm install --prefix work/cli-old --no-audit --no-fund @openai/codex@0.159.3
work/cli-old/node_modules/.bin/codex app-server generate-json-schema --experimental --out work/schema-latest
input=../../../../tests/assets/mp4/ltx2_dialogue_512x512_24fps_7s_355kb.mp4
printf '20e1c86950574d95ad72ed2d324407aa7e48d6013a5d556cdd9517fb71e412ff  %s\n' "$input" | shasum -a 256 -c -
ffmpeg -v error -y -i "$input" -vn -ac 1 -ar 24000 -f s16le work/fixture.pcm
printf 'a5503c8158b14ed47625665a66161265e0062fba3d359ff399b648f5346c06de  work/fixture.pcm\n' | shasum -a 256 -c -
if [ ! -d work/codex ]; then
 git clone --depth 1 --branch rust-v0.163.0 --filter=blob:none --sparse https://github.com/openai/codex.git work/codex
fi
git -C work/codex sparse-checkout set codex-rs/core/src codex-rs/app-server/src codex-rs/codex-api/src codex-rs/protocol/src codex-rs/features/src
python3 tools/export_schema.py
