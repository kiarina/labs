# Several orchestrators on one network: a signaling server with a roster and body ownership

司令塔（brain）を 1 つのネットワークに複数置きます。

- **body の所属**: 各 body（ワーカーを動かすアプリ）は、どれか 1 つの brain に所属し、所属先の brain だけがそこでワーカーを動かします。所属は console から変えます
- **console**: brain を選び、選んだ brain と話します
- **シグナリング**: 独立したサーバーにし、名簿（どのアプリがいるか、どれが brain・body か）と所属（body → brain）を持たせます。単独のプロセスでも、アプリの中でも動きます
- **起動画面**: アプリを起動すると、シグナリング → 役割（brain・body）→ 所属の順に選んでから、起動と接続をします

前提となる lab:
- [N 個のアプリを WebRTC でつなぎ、1 つの brain が複数の body を使う形](../flutter-agent-orchestrator-mesh/README.md)（この lab はその写し。司令塔のツール、文字起こしの写し方、画像の運び方はそちら）

## Purpose

1. 複数の brain を同時に動かし、それぞれが自分の所属の body だけを使えるか
2. console で brain を切り替え、選んだ brain に送れるか。どの console にも全部の brain の会話が同じに出るか
3. body の所属を console から変えられるか。ワーカーが動いている間は変えられないようにできるか
4. 1 つのアプリで、起動時に役割（brain・body・シグナリング）を選べるか

## Answer

1 台の Mac（MacBook Pro M1 Max）で、signal・brain 2 つ（brain-a・brain-b）・body 2 つ（body-c・body-d）・console 用のアプリを動かして確かめた。
2 台の Mac での確認は、まだしていない（下の Limitations）。

- **brain 2 つが同時に、自分の body だけで動いた。**
  - brain-a には body-c、brain-b には body-d を、console から所属させた
  - 2 つの console から同時に「自分の body それぞれで `hostname && pwd`、最後に相手の body でも試して」と頼んだ
  - brain-a は自分の body（brain-a・body-c）で、brain-b は自分の body（brain-b・body-d）で、ワーカーを動かした
  - 相手の body は、どちらも「別の brain の所属なので使えない」と答えた
- **どの console にも、両方の brain の会話が同じに出た。** brain 2 つ・body 2 つ・console 1 つの計 5 つで、両方の brain の全スレッドの操作の数とハッシュが一致した
- **ワーカーが動いている body は移せなかった。**
  - brain-a が body-c で `sleep 45` を走らせている間に、body-c を brain-b へ移そうとした。
    signal が brain-a に問い合わせ、brain-a が「1 worker(s) of brain-a running or queued on body-c (w3)」と断った
  - 終わった後は移せた。brain-b は、移ってきた body-c でワーカーを動かした
- **新しいアプリは、起動から 1.0 秒で両方の brain とつながった**（signal に入るまで 0.6 秒）
- **役割を起動時に選べる。** 1 台の Mac で、次の 4 つを同時に動かした（環境変数で指定。起動画面と同じ起動処理を通る）
  - brain・body・シグナリング（brain-a）: アプリの中でシグナリングを開始し、ほかの 3 つが入った
  - body（body-c）: 所属先に brain-a を指定し、参加の後に所属が brain-a になった
  - brain だけ（brain-b）: body の一覧に出ず、所属も作られない
  - console だけ（con-x）: エージェントを起動せず、両方の brain の会話を見られる
  - 4 つとも、起動から 0.9〜3.2 秒で両方の brain とつながった
- **シグナリングのポートが使われていると、開始しない。** 起動画面に「in use (Address already in use)」と出して止まる
- **起動画面の 3 つのステップを、widget のテストで本物のシグナリングに対して通した**（`mise run` で流れる）
  - 既存につなぐ → 名前がぶつかると注意が出る → Body → 名簿の brain-a・brain-b から選ぶ
  - このアプリで起動する → 使われているポートでステップ 1 に止まる → 空いたポートで進む → Brain と Body → 所属先の既定がこのアプリ
  - どちらも選ばない → ステップ 2 で起動する（console だけ）
- widget のテストの中の `HttpClient` は、すべて 400 を返す偽物になっている（`HttpOverrides.global = null` で外す）。
  本物の通信の結果は、実時間を待つ（`runAsync`）だけでは画面に届かず、待つことと `pump` を交互に繰り返す

## Architecture

```text
                    signal（Dart のプロセス、:8765）
                    名簿・所属・WebRTC の中継
          ┌──────────┬──────────┼──────────┬──────────┐
       brain-a    brain-b    body-c     body-d    con-x      ← 全アプリが WebSocket でつなぐ
          ║ ╲      ║ ╲  ╲      │          │         │
          ║  ╲═════╬══╲══╲═════╪══════════╪═════════╡      ← brain が絡む組ごとにデータチャネル 1 本
          ╚════════╝   ╲  ╲════╪══════════╡
```

- **signal**（`signal/lib/signal_server.dart`。依存なしの Dart）
  - 単独では `mise run signal`（`signal/bin/signal.dart`）。アプリの中では、起動画面で「Signaling」を選ぶと同じものが動く
  - 名簿: 名前・brain か・body か・online・ホスト。名前がぶつかったら `-2` などを付けて返す。普通の HTTP の GET には名簿と所属を JSON で返す
  - 所属: `body → brain`。body でもある brain は、最初の参加で自分を所属させる。ほかの body は所属なしから始まる。body でないアプリは所属を持たない。アプリが抜けても所属は残る
  - 所属はファイルに書いて、起動し直しても残す（アプリの中では状態のフォルダの `signal-owners.json`、単独では `OWNERS_FILE`）
  - 中継: offer・answer・ICE の候補を宛先付きで回す
  - 所属の変更（`assign`）: 今の所属先が online なら、その brain に `releaseRequest` で尋ね、断られたら変えない（5 秒で答えが無ければ失敗）。
    所属先が offline・所属なしなら、すぐ変える
- **データチャネル**: 少なくとも片方が brain の組ごとに 1 本。名前の順で先のアプリが offer を出す
  - 1 本の中で、brain の役のメッセージ（`rpc`・`console`）と、相手の役のメッセージ（`hello`・`info`・`res`・`agent`・`action`）は種類が重ならない。そのため brain どうしも 1 本で足りる
- **brain**: つながった全アプリの console へ会話を流す（前の lab の `ConsolePublisher`）。全アプリの body を名簿として知っている
  - ワーカーを動かせるのは、所属の body だけ（`list_bodies`・`start_thread`・`fetch_image`）
  - `releaseRequest` には、その body で自分のワーカーが動いている・待っているなら理由を返して断る
- **body**（body を選んだアプリ）: つながった brain ごとに `BodyHost` を置く。rpc は、今の所属先の brain からのものだけを受ける
  （所属が変わる前に始めたエージェントの `close`・`interrupt` は受ける）
- **console**（全アプリ）: つながった brain ごとに写し（`BrainView`）を持つ。選んだ brain の写しを中央と右に出し、送信・停止・設定はその brain へ送る
  - 左には次を出す
    - brain の選択
    - 全アプリの一覧。名前・所属先・使えるエージェント。所属先を押すと、brain を選ぶメニューが出る（ワーカーが動いている間は押せない）
  - 所属の変更は signal へ送る

### 起動画面

`ORCH_ROLE`・`ORCH_SIGNAL_URL`・`ORCH_NAME` のどれも無いときに出る。3 つのステップに分け、前のステップで分かることを次のステップで使う。
前回の選択を状態のフォルダの `launch.json` に覚え、次の初期値にする。

| ステップ | 選ぶもの | 「次へ」で起きること |
| --- | --- | --- |
| 1. Signaling | このアプリで起動する（ポート）か、既存につなぐ（URL。既定 `ws://localhost:8765`）か | 起動する、または問い合わせる。ポートが使われている・読めないなら、ここで止まる。読めたら名簿を持って次へ |
| 2. Roles | 名前（body_id。空なら「ホスト名-乱数 4 桁」）、Brain・Body（両方も可） | 名前が online のアプリとぶつかると、`-2` が付くと注意を出す。Body を選ばなければ、ここで起動する（どちらも選ばなければ console だけ） |
| 3. Belongs to | 所属する brain。候補は、自分が brain ならこのアプリ（既定）と、名簿にいる online の brain | 起動する。参加の後に所属を変える |

- 「Back」で前のステップへ戻れる。ステップ 1 でアプリの中のシグナリングを始めた後に戻ってポートを変えると、起動し直す
- 所属の変更は、前の所属先でワーカーが動いていれば断られ、所属は前のまま（理由は body の一覧の上に出る）
- 画面の流れは widget のテスト（`app/test/launch_page_test.dart`）で、本物のシグナリングに対して確かめる

### メッセージ（WebSocket、signal との間）

| 向き | `t` | 中身 |
| --- | --- | --- |
| app → signal | `hello` | 名前・brain か・body か・ホスト |
| signal → app | `welcome` / `roster` | 決まった名前 / 名簿と所属（変わるたびに全員へ） |
| app ↔ signal | `signal` | WebRTC の offer・answer・ICE（宛先付き） |
| app → signal | `assign` | body をどの brain へ（null は所属なし） |
| signal → brain | `releaseRequest` | その body を手放してよいか |
| brain → signal | `releaseReply` | よい / 理由付きで断る |
| signal → app | `assignResult` | 結果 |

データチャネルのメッセージは前の lab と同じ。

## Findings

- **broadcast の stream で受けると、聞き始める前に届いたものが捨てられる。** 前の lab と同じ落とし穴を別の場所で踏んだ
  - 新しいアプリが signal に入ると、brain はすぐ offer を出す。アプリの接続の管理は、signal に入った後に聞き始める
  - その間に届いた offer が捨てられ、brain が 20 秒後にやり直すまでつながらなかった（20.8 秒・23.5 秒）
  - 1 人だけが聞く stream（single-subscription）にして、聞き始めるまで溜めるようにした。0.9〜1.0 秒になった
- **ICE の候補は、offer・answer より先に送らない。**
  - offer する側の候補は `setLocalDescription` の間に出て、offer より先に相手へ着く。受ける側には、まだその相手の peer connection が無い
  - 自分の offer・answer を送るまで、自分の候補を溜めるようにした
  - 受ける側は、相手ごとの信号を 1 件ずつ順に処理する。offer の処理が終わるまで、後ろの候補を待たせる
- **`ORCH_SELECT` で brain を指定した console が、先につながった別の brain に送った。** 起動直後の送信は、指定の brain が選ばれるまで待つようにした
- 写した lab の中継プロセス（Node）の `node_modules` を入れ忘れると、Claude だけでなく Codex も使えないと表示された
  - 起動の失敗が 1 つでもあると、本体の準備ができていない扱いになり、Codex と Claude を一覧に出さない作り
  - ログを見ないと気づきにくい
- 所属は signal が持つので、brain や body を起動し直しても所属は残った。signal はファイルにも書くので、signal を起動し直しても残った
- 起動画面のエラーは、画面の部品の初期化（`initState`）の中だけで読むと、後から出たエラーが表示されない。エラーを key にして作り直した
- body でもある brain の所属先の既定を「所属なし」にすると、起動のたびに自分の body を手放してしまう。既定を「このアプリ」にした

### ワーカーに自動で入るプロンプト

偽の API（Anthropic の Messages、OpenAI の Responses）に向けて、送られる中身を記録した（`mise run probe-prompts`。トークンを使わない）。
作業フォルダには目印を書いた `AGENTS.md` と `CLAUDE.md` を置いた。

| | system（基本の指示） | `CLAUDE.md` | `AGENTS.md` |
| --- | --- | --- | --- |
| Claude、この lab のワーカーの設定（`systemPrompt` なし、`settingSources` に project） | 136 文字（SDK の 1 文だけ） | 入る | 入らない |
| Claude、`systemPrompt: {type: 'preset', preset: 'claude_code'}` | 約 27,500 文字（Claude Code の本来のプロンプト） | 入る | 入らない |
| Claude、`systemPrompt` に文字列、`settingSources: []` | 156 文字（SDK の 1 文 + 渡した文） | 入らない | 入らない |
| Codex、既定 | モデル表の基本の指示 | 入らない | 入る |
| Codex、`-c project_doc_max_bytes=0` | 同上 | 入らない | 入らない |

- **この lab の Claude のワーカーには、Claude Code の本来のプロンプトが入っていない。** 中継プロセスは、司令塔にだけ preset（と `append`）を渡し、ワーカーには `systemPrompt` を渡していない。
  ワーカーの system は「You are a Claude agent, built on Anthropic's Claude Agent SDK.」の 1 文だけで、ツールは Claude Code と同じものを持つ
- Claude の `CLAUDE.md` は、system ではなく最初のユーザーの発言の `<system-reminder>` として入る。`AGENTS.md` は読まない（`CLAUDE.md` から `@AGENTS.md` で取り込めば読む）
- Codex の `AGENTS.md` は、`# AGENTS.md instructions for <cwd>` の見出しと `<INSTRUCTIONS>` に包まれて会話の先頭に入る。
  `project_doc_fallback_filenames` で足した名前（`CLAUDE.md` など）は、`AGENTS.md` が無いときだけ読まれる

## Limitations

- **2 台の Mac では確かめていない。** 2 台目の Mac（Mac Studio）が VPN から外れていて、届かなかった
- **画面のクリックでの操作は、エージェントは確かめていない**（brain の切り替え、所属先のメニュー）
  - 使っている関数は、起動時の `ORCH_SELECT`・`ORCH_ASSIGN`・`ORCH_ROLE`・`ORCH_OWNER` と同じ。そちらで確かめた
  - 画面の表示（brain の選択、所属先の一覧、起動画面とそのエラー）はスクリーンショットで確かめた
  - 起動画面の操作は widget のテストで確かめた（上の Answer）
- **認証が無い。** signal は誰でも参加でき、誰でも所属を変えられる。信頼できるネットワークの中だけで動かす
- Claude のワーカーは、Claude Code の本来のプロンプトなしで動いている（上の Findings）。直すなら中継プロセスでワーカーにも preset を渡す
- シグナリングを動かしているアプリを閉じると、全員がシグナリングを失う（所属はファイルに残る）。別のアプリがシグナリングを引き継ぐ仕組みは無い
- brain が落ちると、その brain の所属の body は所属先が offline のまま残る。console から別の brain へ移せる（offline の brain には尋ねない）
- 全アプリが全 brain とつながるので、データチャネルの数は「アプリ数 × brain 数」程度に増える。数台でしか試していない

## How to run

前提: 各マシンで `codex login` と `claude auth login`（サブスク）を済ませておく、mise。

```bash
mise run                    # sidecar の型検査、flutter analyze、起動画面のテスト
mise run run                # 起動画面から始める
```

起動画面を出さずに起動するときは、環境変数で役割を指定する。

```bash
ORCH_ROLE=brain,body,signal ORCH_NAME=brain-a mise run run             # シグナリングもこのアプリで
ORCH_ROLE=body ORCH_NAME=body-c ORCH_SIGNAL_URL=ws://<シグナリングのホスト>:8765 ORCH_OWNER=brain-a mise run run
mise run signal             # シグナリングを単独で（:8765）。PORT か引数でポートを変える
```

- `ORCH_ROLE`: `brain`・`body`・`signal`・`console` のコンマ区切り。`brain` だけなら body も兼ねる。`console` だけなら brain も body もしない
- `ORCH_SIGNAL_PORT`: アプリの中のシグナリングのポート（既定 8765）
- `ORCH_OWNER`: 参加の後に、この body の所属先にする brain（`-` は所属なし）
- 同じマシンで複数起動するときは、`ORCH_STATE_DIR` を分ける
- `ORCH_SELECT=<brain>`: console が最初に出す brain
- `ORCH_ASSIGN=body-c=brain-a,body-d=`: 起動後に所属を変える（空は所属なし。console の一覧と同じ操作）
- `ORCH_PROMPT`: 選んだ brain へ、起動後に 1 回送る
- `ORCH_DUMP=path.json`: 名簿・所属・brain ごとの会話（操作の数とハッシュ）・接続の記録を書き出す
- `mise run probe-prompts`: Codex と Claude のワーカーに自動で入るプロンプトを、偽の API で確かめる（`probes/`）

## Environment

- macOS 27.0.1、MacBook Pro M1 Max
- Flutter 3.47.2・Dart 3.13.2、flutter_webrtc 1.6.2+hotfix.4、Node 22.22
- codex-cli 0.159.3、`@anthropic-ai/claude-agent-sdk` 0.3.289
- 司令塔 `gpt-5.6-luna`（effort low）、Codex のワーカー `gpt-5.6-luna`
- 実行日: 2026-10-09
