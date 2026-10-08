# Codex as a coding agent on a local model: codex app-server against kiapi's Responses API

Codex（`codex app-server`）のモデルの送り先を、自宅の推論サーバー kiapi の Responses API（`POST /v1/responses`）に向け、
ローカルのモデル（Qwen3.8-Flash-Next）で小さなコーディングの仕事をこなせるかを確かめます。

前提となる lab:
- [Codex が自前の Responses API の送り先に送るもの](../codex-responses-provider/README.md)（送り方と、受け付けられる返事の形。kiapi の実装はこれに合わせた）
- [Codex と Claude のスレッドをツールとして動かす司令塔](../../06/flutter-agent-orchestrator/README.md)（ここに kiapi のワーカーとして並べるのが目的）

## Purpose

1. kiapi の Responses API で、Codex がツールの往復から最後の回答まで進めるか
2. Qwen3.8-Flash-Next で、ファイルを読んで直し、テストで確かめる、という小さな仕事を最後までこなせるか
3. かかる時間とトークン、Prefix Caching の効き

## Answer

- **3 回中 3 回、テストを通して終わった**（34.1・34.5・41.8 秒）。毎回、ファイルの一覧 → `calc.py` とテストを読む → テストを走らせる → 3 つのバグを
  直す（ファイルをシェルで丸ごと書き直す）→ テストで確かめる → 1 行で報告、の順に進めた。テストのファイルは一度も変えなかった
- 1 回あたりの入力は 33〜56K トークンで、そのうち 77〜86% が kiapi の Prefix Caching から出た。出力は 0.7〜0.9K トークン
- 最初の依頼（Codex の指示と履歴で約 7.6K トークン）の応答まで約 10 秒。モデルを載せる前の最初の 1 回（予備の試行）は 37 秒かかった

## Method

- 課題: `fixture/calc.py`（バグが 3 つ: 平均から 1 を引く、空のリストで `ValueError` にならない、下限を下回ると上限を返す）と、標準の `unittest` のテスト 4 件
- 依頼: 「テストが落ちている。`test_calc.py` を変えずに `calc.py` を直し、`python3 -m unittest` が通るのを確かめて 1 行で報告して」
- 1 回ごとに課題を新しい一時ディレクトリに写し、自前の設定の `codex app-server` を起動して 1 ターンだけ送る。終わったら、こちらでテストを走らせて判定する
  （通ったか、テストのファイルが元のままか）
- Codex の設定（前の lab と同じ考え方）
  - 空の `CODEX_HOME`
  - `-c model_providers.kiapi={base_url="http://127.0.0.1:8500/v1", wire_api="responses"}`、`model_provider="kiapi"`、`model="qwen3.8-flash-next"`
  - モデル表: OpenAI の `gpt-5.6-luna` の項目を写し、slug を kiapi のモデル名にして、`tool_mode`・`multi_agent_version`・`apply_patch_tool_type` を null、
    `use_responses_lite` を false、コンテキストを 200K にしたもの
  - code mode・multi agent・apps・plugins・画像生成・computer use・ブラウザなどを切り、`skills.include_instructions=false`
  - `approvalPolicy: never`、`sandbox: workspace-write`
- Codex の指示（`instructions`）は Codex 既定のもの（GPT 向けの約 17.7K 文字）のまま

## Results

`results/qwen3.8-flash-next.json`（各回の手順・コマンドとその出力の末尾・トークン・直した後の `calc.py`。一時ディレクトリのパスは `<task>` に置き換えた）

| 回 | 結果 | 秒 | 手順（m: 発言、c: コマンド） | 入力トークン | うちキャッシュ | 出力トークン |
| --- | --- | ---: | --- | ---: | ---: | ---: |
| 0 | 通った | 34.1 | m c c c m c m | 32,779 | 25,288 | 667 |
| 1 | 通った | 34.5 | m c c m c c c m | 39,731 | 32,302 | 717 |
| 2 | 通った | 41.8 | m c c c c c c m | 56,135 | 48,017 | 896 |

- 直し方は 3 回とも同じ中身（`if not values: raise ValueError(...)`、`- 1` を外す、下限で `low` を返す。例外の文言だけ違う）
- 編集はシェルで行った（0・1 回目は `cat > calc.py <<'EOF'`、2 回目は `printf '%s\n' ... > calc.py`。2 回目はその前に `cat -A` で改行の形も確かめた）。Codex のファイル編集のツール（`apply_patch`）は、このモデル表では渡らない（前の lab）
- 予備の試行（同じ設定、記録は上書き）も 68.7 秒で通った。うち最初の応答まで 37 秒

## Findings

- kiapi の Responses API は、Chat Completions の上に変換を挟んだだけの作り（会話をサーバーに持たない）で、Codex のツールの往復に足りた
- Prefix Caching が効くのは、Codex が毎回同じ指示と履歴を先頭から送り直すため。依頼を重ねるほど、新しく読むのは末尾の分だけになる
- Qwen3.8-Flash-Next は、GPT 向けに書かれた Codex の指示のままでも、この大きさの仕事は迷わずにこなした

## Limitations

- 課題は 1 ファイル・テスト 4 件の小さなもの。複数ファイルにまたがる変更、長い会話、履歴の圧縮（コンテキストが埋まったとき）は試していない
- 試行は 3 回だけ。kiapi は依頼を 1 件ずつ処理するので、並べて走らせたときの待ちは測っていない
- kiapi の Responses API は reasoning を扱わない（`reasoning` は無視し、Qwen の thinking は切ったまま）
- サーバー機（Mac Studio M4 Max 128GB）の上で、kiapi に `127.0.0.1` でつないだ。tailnet 越しの時間は含まない

## How to run

前提: kiapi（`/v1/responses` を持つ版）が動いていて、`qwen3.8-flash-next` が使えること。`uv`、mise。`~/.codex/models_cache.json`（Codex を一度使うとできる）。

```bash
mise run                                   # 文法の確認だけ
KIAPI_BASE_URL=http://127.0.0.1:8500 mise run trial   # 3 回（TRIALS で変えられる）
```

## Environment

- macOS 27.0.1、Mac Studio M4 Max 128GB
- `openai-codex` 0.161.0（同梱の codex）、Python 3.12
- kiapi の `/v1/responses` を足した版（2026-10-08）、`qwen3.8-flash-next`（mlx-community/Qwen3.8-Flash-Next-4bit）
- 実行日: 2026-10-08
