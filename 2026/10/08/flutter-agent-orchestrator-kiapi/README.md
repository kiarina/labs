# Adding a local-model worker (Codex on kiapi) to the Codex and Claude orchestrator

Codex と Claude のスレッドをツールとして動かす司令塔のアプリに、3 つ目のワーカーとして「kiapi」を足します。
kiapi のワーカーは、モデルの送り先を自宅の推論サーバー kiapi（ローカルのモデル）にした `codex app-server` です。
OpenAI の Codex・Claude のワーカーと同じツール（`start_thread` など）で、司令塔から並べて使えるかを確かめます。

前提となる lab:
- [Codex と Claude のスレッドをツールとして動かす司令塔](../../06/flutter-agent-orchestrator/README.md)（この lab はその写しに kiapi を足したもの。画面・ツール・同時実行の作りはそちら）
- [Codex が自前の Responses API の送り先に送るもの](../codex-responses-provider/README.md)（1 つの app-server でも相乗りできるが、モデル表の都合でプロセスを分ける理由）
- [Codex を kiapi につないでコーディングの仕事をさせる](../codex-on-kiapi/README.md)（kiapi のワーカーの設定の出どころ）

## Purpose

1. 司令塔のツールで `provider: "kiapi"` のワーカーを立て、Codex・Claude のワーカーと同時に動かせるか
2. kiapi のワーカーだけ同時に 1 つまでにして、2 つ目を順番待ちにできるか（kiapi は依頼を 1 件ずつ処理する）
3. 司令塔が kiapi のワーカーに続きを頼む（`send_message`）など、今の workflow がそのまま使えるか

## Answer

- **使えた。** Codex の司令塔（`gpt-5.6-luna`）に「(1) kiapi で `calc.py` を直す、(2) Claude で `textutil.py` を直す、(3) kiapi で `NOTES.md` に `calc.py` の説明を書く、
  終わったら全体のテスト」と頼むと、3 つのワーカーを立て、`wait_threads` で待ち、最後は kiapi のワーカー（w1）に `send_message` で全体のテストを頼んで、
  「6 件すべて成功」と報告した（2 分 23 秒）。手元でもテストは通り、変わったのは担当の 3 ファイルだけだった
- **kiapi は 1 つずつ動いた。** 右の一覧は w1（kiapi）と w2（Claude）が同時に走り、w3（kiapi）は w1 が終わってから始まった。司令塔も
  「NOTES.md 作成は kiapi の実行枠待ち」と書いた
- 時間: w1（kiapi、`calc.py`）58 秒、w2（Claude、`textutil.py`）12 秒、w3（kiapi、`NOTES.md`）45 秒

## 変えたところ（前の lab から）

- `Provider` に `kiapi` を足した。kiapi のワーカーは `CodexBackend` と `CodexAgent` をそのまま使い、backend に provider の印を持たせただけ
- `kiapiAppServer()`（`lib/rpc/rpc_client.dart`）: 2 つ目の `codex app-server` を、次の設定で起動する
  - 専用の `CODEX_HOME`（アプリの設定のディレクトリの `kiapi-codex-home`。`~/.codex` の MCP サーバー・スキル・ログインを持ち込まない）
  - `-c model_providers.kiapi={…, base_url="$KIAPI_BASE_URL/v1", wire_api="responses"}`・`model_provider="kiapi"`・`model="$KIAPI_MODEL"`
  - モデル表（`model_catalog_json`）: `~/.codex/models_cache.json` の `gpt-5.6-luna` の項目を写し、slug を kiapi のモデル名にして、ツールを普通の function で送る形にしたもの
  - code mode・multi agent・apps・plugins・画像生成・computer use・ブラウザなどを切る
- 同時実行: 全体の上限（既定 4）に加えて、kiapi だけの上限 `kiapiMaxConcurrent`（既定 1）。`drainQueue` が待ちのワーカーを一度に何人も始めても上限を越えないよう、
  始めると決めた時点で `running` にする
- 司令塔のツールの `provider` に `kiapi` を足し、説明と司令塔への指示に「ローカルのモデル。無料で外に出ないが遅く弱い。1 つずつ動く」と書いた
- kiapi の app-server が起動できなくても、Codex と Claude は使える（設定の画面に理由を出す）

## Findings

- kiapi のワーカーは、Codex のワーカーと同じ JSON-RPC・同じ通知で動くので、会話の表示・止める・続きを頼む、は何も足さずに使えた
- 専用の `CODEX_HOME` は空でも起動する（ログインなし）。中に `config.toml`・ログ・goals や memories の SQLite が作られる（機能を切っていてもファイルはできる）
- 司令塔は kiapi のワーカーの説明（遅く弱い・1 つずつ）を読み、それでも頼まれたとおり kiapi に振った。どの仕事をどこへ振るかを司令塔に任せたときの選び方は試していない

- 作業フォルダに `.codex/config.toml` があると（ホームフォルダでは普段の Codex の設定）、kiapi のワーカーにもそこの MCP サーバーのツールが渡る。
  最初は kiapi が `namespace` のツールを受け付けず、ワーカーが「unsupported tool type: 'namespace'」で失敗した。kiapi 側で受け付けるようにした
  （kiapi `2a1de66`。追記、2026-10-08）

## Limitations

- 1 回だけ、小さな課題で試した。kiapi のワーカーに長い仕事・大きな変更をさせたときの質、履歴の圧縮は試していない
- 司令塔を kiapi にする（kiapi に司令塔のツールを持たせる）ことは試していない。画面の切り替えも Codex・Claude のまま
- kiapi のモデルは 1 つ（`qwen3.8-flash-next`）。モデルの一覧は kiapi から読まず、`KIAPI_MODEL` で決めている
- kiapi の chat のモデルは約 74 GiB 常駐する。kiapi のワーカーが走っている間に kiapi の画像などを使うと、モデルの載せ直しで待つ

## How to run

前提: `codex login` と `claude auth login`（サブスク）、mise、kiapi（`/v1/responses` を持つ版）が動いていること。

```bash
mise run            # sidecar の型検査と flutter analyze
KIAPI_BASE_URL=http://127.0.0.1:8500 ORCH_CWD=path/to/project ORCH_PROMPT="..." mise run run
```

`KIAPI_MODEL` で kiapi のモデルを変えられる（既定 `qwen3.8-flash-next`）。設定は
`~/Library/Application Support/com.kiarina.labs.agentOrchestratorKiapi/settings.json`（`kiapiMaxConcurrent` を含む）。

## Environment

- macOS 27.0.1、Mac Studio M4 Max 128GB（kiapi も同じマシン）
- Flutter 3.47.2、codex-cli 0.160.1、Node 22
- 司令塔 `gpt-5.6-luna`（effort low）、Claude のワーカーは既定のモデル、kiapi `qwen3.8-flash-next`
- 実行日: 2026-10-08
