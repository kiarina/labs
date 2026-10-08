# Connecting N orchestrator apps over WebRTC: one brain drives workers on many bodies

Codex・Claude・kiapi のスレッドをツールとして動かす司令塔のアプリを、次の 3 つの役割に分けます。

- **console**: 画面と入力
- **body**: Codex・Claude・kiapi のワーカーを動かす
- **brain**: 司令塔

同じアプリを N 個起動して WebRTC のデータチャネルでつなぎます。brain は 1 つで、残りの N-1 個が body として brain に接続します。
どのアプリの console から送っても brain に届き、どの console にも同じ画面が出ます。brain は body の名前を指定してワーカーを立て、複数の body を同時に使います。

前提となる lab:
- [Codex・Claude・kiapi の司令塔](../../08/flutter-agent-orchestrator-kiapi/README.md)（この lab はその写し。ツール・同時実行・画面の作りはそちら）
- [Codex と Claude のスレッドをツールとして動かす司令塔](../../06/flutter-agent-orchestrator/README.md)

## Purpose

1. 1 つのアプリの中で結合していた console・body・brain を分け、間をデータチャネルにできるか
2. どの console から送っても brain に届き、全部の console が同じ表示（同じ会話・同じワーカー一覧）になるか
3. brain が body の名前でワーカーを立て、複数の body のワーカーを同時に待つ・続きを頼む・止める、を今のツールのまま扱えるか
4. body が途中で消えたとき、brain が気づいてワーカーを失敗として扱えるか

## Answer

- **できた。** 1 台の Mac で 3 つ（brain と body 2 つ）、2 台の Mac（MacBook Pro M1 Max に brain と body 1 つ、Mac Studio M4 Max に body 1 つ）で確かめた。
  どの場合も、全 console の会話と、各ワーカーの文字起こしの操作の数とハッシュが一致した（下の Results）
- **body の console から送った依頼が brain に届いた。** 次の 3 つで確かめた
  - 1 台で 3 つ: body の 1 つ（body-c）から「online の body ごとにワーカーを 1 つずつ同時に立てて」と送った。brain の司令塔（Codex `gpt-5.6-luna`）は
    `list_bodies` で 3 つの body を見つけ、`start_thread` を body ごとに呼んだ（brain の body は Codex、他の 2 つは Claude）。続けて `wait_threads` で待ち、表にまとめた（22 秒）。
    各ワーカーのファイルは、それぞれの body の作業フォルダにできた
  - 別の body（body-b）の console に打ち込んだ続きの依頼: 司令塔は body-c の既存のワーカーに `send_message` で追記を頼んだ。
    同時に、body-b に Codex のワーカーを新しく立てて `ls -la` を返させた
  - 2 台目の Mac の body の console から送った依頼: 2 台の Mac で同時にワーカーが動いた。結果には各 Mac のホスト名と CPU（M4 Max と M1 Max）が返った
- **body が消えると、すぐ気づいた。** `sleep 60` を走らせている body のアプリを終了させると、brain の一覧でその body は offline になり、ワーカーは failed になった。
  司令塔の `wait_threads` もそれを受けて戻り、「約 23 秒後に失敗終了」と報告した
- **brain を作り直しても、body はつながり直した。** brain のアプリを終了すると、body の console は「connecting」になった。
  新しい brain を起動すると、数秒で 2 つとも新しい brain につながった（3 秒ごとにやり直す）
- 接続にかかった時間（body の起動からデータチャネルが開くまで）: 同じ Mac の中で 0.9 秒、別の Mac から 1.6 秒

## Architecture

```text
              ┌──────────── brain のアプリ ─────────────┐
              │ console ← ConsoleMirror ← (loopback)    │
              │                     ↑                   │
              │ Hub（司令塔・ワーカーの台帳）→ ConsolePublisher ─┐
              │   ├ LocalBody（自分の Codex・Claude・kiapi）  │  │
              │   └ RemoteBody ×(N-1) ──────────────────────┐│  │
              │ SignalingServer（WebSocket, :8765）        ││  │
              └────────────────────────────────────────────┼┼──┘
                     データチャネル（1 本に body と console の両方） ││
              ┌──────────── body のアプリ ───────────────┐ ││
              │ BodyHost → LocalBody（Codex・Claude・kiapi） ←┘│
              │ console ← ConsoleMirror ←──────────────────────┘
              └──────────────────────────────────────────┘
```

- `lib/mesh/peer.dart`: シグナリングとデータチャネル
  - brain は WebSocket で待ち受ける。body が名乗ると、brain が offer を出し、ICE の候補を交換する
  - データチャネルが開いた後は、WebSocket は相手が消えたことに気づくためだけに残す（ICE が気づくには数十秒かかる）
  - 大きなメッセージは 16,000 文字ごとに分けて送る
  - STUN・TURN は使わない（同じ LAN と VPN（Tailscale）の host 候補でつながる）
- `lib/body/body.dart`: body の 3 つの形
  - `LocalBody`: 自分のバックエンド。前の lab で Hub が持っていたもの
  - `BodyHost`: body のアプリで、brain の依頼（`agent/create`・`start`・`send`・`interrupt`・`close`）を自分のバックエンドで実行し、文字起こしの操作を返す
  - `RemoteBody`・`RemoteAgent`: brain から見た body と、そこのワーカー。ワーカーの状態（queued・running など）は brain が持つ
- `lib/state/thread_view.dart`: 文字起こしへの変更をすべて JSON の操作にして `ops` に残す。操作は Codex の通知、SDK のメッセージ、ユーザーの発言、エラー、
  質問の追加・削除の 6 種類。別のアプリは同じ操作を同じ順に当てて、同じ文字起こしを作り直す
- `lib/console/console.dart`:
  - `ConsolePublisher`（brain）: Hub の状態（設定・body の一覧・スレッドの一覧）と各スレッドの新しい操作を、30 ms ごとにまとめて全 console へ送る
  - `ConsoleMirror`（全アプリ）: 受け取ったものだけで画面を描き、ユーザーの操作（送信・停止・設定など）を brain へ送り返す
  - brain 自身の console も、プロセス内の loopback で同じメッセージ（JSON を通す）を受け取る
- `lib/orchestrator/hub.dart`・`tools.dart`: 司令塔は brain の body の上で動く
  - `start_thread` に `body` を足した（必須。brain の body も名前で指定する）
  - `list_bodies` を足した（名前・online・使えるエージェント・作業フォルダ・動いている数）
  - 同時実行の上限は body ごとに数える（各 body は別のマシン・別のサブスク）
  - `fetch_image(body, path)`: body の画像ファイルを brain へ運ぶ（下の「画像」）
  - **司令塔は手を持たない。** 自分ではコマンドもファイルの読み書きもアプリの操作もせず、brain のマシンでの作業も brain の body のワーカーに頼む
    - Codex の司令塔: `thread/start` の `config` で、そのスレッドだけ機能を切る（`shell_tool`・`unified_exec`・`computer_use`・`browser_use` など。下の表）。
      同じ app-server のワーカーはそのまま使える
    - Claude の司令塔: 組み込みのツールを `tools: ['AskUserQuestion', 'TodoWrite']` に絞る。`strictMcpConfig` で、普段の設定の MCP サーバーを読ませない

### メッセージ

| 向き | `t` | 中身 |
| --- | --- | --- |
| body → brain | `hello` / `info` | 自分の情報（ホスト、使えるエージェント、作業フォルダ、モデル、利用枠） |
| brain → body | `rpc` | `agent/create`・`agent/start`・`agent/send`・`agent/interrupt`・`agent/close` |
| body → brain | `res` / `agent` | rpc の結果 / ワーカーの文字起こしの操作（`ops`）と終わったこと（`finished`） |
| brain → console | `console` | `snapshot`（参加したとき、全部）、`state`（変わったとき）、`ops`（スレッドごとの新しい操作。`from` で位置を示す） |
| console → brain | `action` | `send`・`interrupt`・`new`・`stop`・`settings`・`answer`・`project` |

### 画像

body の画面や絵を、brain の司令塔が見てコメントし、全 console にも出す。

1. 司令塔は、その body のワーカーに画面を撮らせ（`screencapture -x <path>.png`）、パスを返させる
2. 司令塔が `fetch_image(body, path)` を呼ぶ。brain は body へ rpc `file/image` を送る
3. body は `sips` で JPEG（品質 80、長辺 1600 px まで）にして base64 で返す。画像の拡張子のファイルだけ、元は 50 MB・変換後は 4 MB まで
   （リンクに認証が無いので、任意のファイルは読ませない）
4. 司令塔へはツールの結果の画像として渡す（Codex は `contentItems` の `inputImage`、Claude は MCP の結果の `image` ブロック）
5. 同時に、司令塔の文字起こしに `image` の操作として足す。ほかの操作と同じ経路で全 console へ届き、画面はサムネイル（クリックで拡大）を出す

### 名前

- 起動時に `<ホスト名>-<4 桁の 16 進>` を付ける。`ORCH_NAME` で上書きできる
- brain は、online の body と同じ名前を断り、`-2` などを付けて返す。消えた body と同じ名前で参加すると、前の body の項目を置き換える

## Results

### 1 台の Mac に 3 つ（MacBook Pro M1 Max）

body-c の console から送った依頼の後の、3 つの console の `ORCH_DUMP`。各スレッドの `ops` は操作の数、`hash` は操作全体の JSON の FNV-1a:

| console | o1（司令塔） | w1（brain, Codex） | w2（body-b, Claude） | w3（body-c, Claude） |
| --- | --- | --- | --- | --- |
| brain | 307 / `ba778a76` | 157 / `5d99c13f` | 159 / `85b956cc` | 172 / `87fb9a46` |
| body-b | 307 / `ba778a76` | 157 / `5d99c13f` | 159 / `85b956cc` | 172 / `87fb9a46` |
| body-c | 307 / `ba778a76` | 157 / `5d99c13f` | 159 / `85b956cc` | 172 / `87fb9a46` |

- 続きの依頼の後も 3 つとも一致した: o1 467 / `5b5ea98f`、w3 298 / `e3227732`、w4（body-b, Codex）158 / `7d88e0c8`
- 画面: どの console も、中央の会話（ツールの呼び出しと表）と右のワーカー一覧が同じ。左の下に body の一覧（online・ホスト・使えるエージェント・動いている数・利用枠）

### 2 台の Mac

brain・body-b は MacBook Pro M1 Max、studio は Mac Studio M4 Max。studio の console から送った依頼の後:

| console | o1 | w2（body-b, Codex） | w3（studio, Claude） |
| --- | --- | --- | --- |
| brain | 399 / `5c50e465` | 100 / `b0202c58` | 63 / `15c745d3` |
| body-b | 399 / `5c50e465` | 100 / `b0202c58` | 63 / `15c745d3` |
| studio（2 台目の Mac） | 399 / `5c50e465` | 100 / `b0202c58` | 63 / `15c745d3` |

（w1 はその前に試した、body を消したワーカー。failed のまま残る）

### 接続の時間（body の console の記録）

```text
0.0s connecting to ws://<brain>:8765
0.5s   signaling open
0.5s   welcome as studio
0.6s   peer connection created
0.6s   offer
0.6s   answer sent
0.6s   ice RTCIceConnectionStateChecking
1.6s   ice RTCIceConnectionStateConnected
1.6s   data channel arrived (RTCDataChannelOpen)
```

## Findings

- **body の画面のスクリーンショットを、brain の司令塔が見てコメントし、全 console に出せた。**
  - 「Mac Studio の画面のスクリーンショットを撮って、fetch_image で見て、何が映っているか具体的にコメントして」と送った。
    司令塔は studio のワーカーに撮らせ、`fetch_image` で取り込んだ（5120×2880 → 1600×900 の JPEG）
  - 司令塔は、Chrome の岐阜クエストのページ、司令塔の窓、後ろのシステム設定など、画面の中身を具体的に挙げた
  - 3 つの console（brain、body-b、2 台目の Mac の studio）で、画像を含む会話のハッシュが一致した。画面には画像がサムネイルで出た
- 画面の収録の許可が無いと、`screencapture` は `could not create image from display` で失敗する。許可を求められるのは、`open` で起動したアプリ（ここでは `agent_orchestrator`）
  - 許可すると macOS が「終了して再度開く」でアプリを起動し直す。このときは `open --env` で渡した設定が付かない。body の設定を失い、brain として立ち上がった
  - その後に、設定を付けて起動し直した
- 撮影が失敗したとき、ワーカー（Codex）は `sudo screencapture` も試した（パスワードが無いので失敗）。ワーカーは承認なしの全権限で動くので、こうした試みも止まらない

- **最初の作りでは、新しく起動した body の最初の接続が必ず 20 秒でタイムアウトした**（やり直すとすぐつながった）。原因はシグナリングの読み方だった
  - 1 通目（welcome）を broadcast stream の `first` で読み、次の listener は `createPeerConnection` の後に付けていた
  - その間に届いた offer は、聞いている人がいないので捨てられていた。2 回目はプロセスが温まっていて速く、offer が届く前に聞けていた
  - 1 本の `StreamIterator` で最初から最後まで読むように直した
  - あわせて、brain の ICE の候補は offer より先に届く（`setLocalDescription` の間に出る）ので、相手の説明を設定するまで候補を取っておくようにした
- **文字起こしは「状態」ではなく「操作」で写すと簡単だった。** ThreadView への変更をすべて JSON の操作にした。brain は操作をそのまま流し、console は同じ順に当てる。
  Codex と Claude の表示の作りに手を入れずに、どの console でも同じ画面が出た。新しく参加した console には、全部の操作を最初から送る
- body の上のワーカーの状態（queued・running・idle・failed）は brain が持つ。終わったかどうかは、body が送る `finished` と、写した文字起こし（最後のターンの状態）で決まる。
  body の向こうの状態を別に写す必要はなかった
- body が消えたことに気づくのは、シグナリングの WebSocket が閉じるのが先だった（アプリが終わるとすぐ閉じる）。データチャネルと ICE だけに頼ると、気づくまで数十秒かかる
- 2 台目の Mac（Mac Studio）では、最初に起動したときにローカルネットワークの許可を求められ、オーナーが許可した。1 台目の Mac では、この lab の間に求められたかを確かめていない
- **司令塔は、自分のマシンを操作するツールを持ったままだった。** オーナーが console から試した結果は次のとおり（2026-10-09）
  - 「Mac Studio の Chrome で gifuquest.blazeworks.jp を開いて」と頼むと、司令塔（Codex）は `start_thread` を呼ばなかった。
    代わりに、普段の Codex の設定から渡っている Computer Use（MCP の `cua_repl`）を自分で呼んだ
  - そのため、開いたのは brain のマシン（MacBook Pro）の Chrome だった。それでも司令塔は「Mac Studio の Chrome で開きました」と答えた
  - 「Mac Studio の body で、Codex に Chrome で開かせて」と body とエージェントを名指しすると、司令塔は `start_thread(body: studio)` を呼んだ。
    Mac Studio のワーカーが、そのマシンの Computer Use でタブを開いた
  - 司令塔の読み取り専用のサンドボックスは、MCP のツールを止めない。指示の「仕事はワーカーに任せる」だけでは足りない
  - **直した。** 司令塔から手を外し、`start_thread` の `body` を必須にした（上の Architecture）。直した後に次の 3 つを確かめた
    - 名指しなしの「Mac Studio の Chrome で gifuquest.blazeworks.jp を開いて」: 司令塔は `list_bodies` の後に `start_thread(body: "studio")` を呼び、
      Mac Studio のワーカーがタブを開いた
    - 司令塔に「ワーカーを使わず自分で書き込んで」と頼むと、指示に従って試さずに断った
    - 「brain の body の Codex のワーカーに Computer Use で開かせて」: brain の body のワーカーは、今までどおり `cua_repl` で Chrome を操作できた
    - 司令塔を Claude（`sonnet`）にして、名指しなしの同じ依頼を送った。こちらも `start_thread(body: "studio")` で Mac Studio のワーカーに頼んだ
- **Codex の機能は、`thread/start` の `config: {features: {...}}` でスレッドごとに切れる。** モデル表は起動時にしか渡せないが、機能の切り替えはスレッドごとに効いた。
  偽の Responses API につなぎ、Codex が送るツールを比べた（`gpt-5.6-luna`。OpenAI のモデルはコードモードなので、ツールは JS の `exec` の中から呼ぶ形で並ぶ）

  | スレッド | 渡るツール |
  | --- | --- |
  | 設定なし | `exec`（JS）・`wait`・`request_user_input`、MCP の `cua_repl`（Computer Use）。`exec` の中に `exec_command`・`write_stdin`・`apply_patch`・goal 3 つ・`request_plugin_install`・`view_image`・MCP のリソース 3 つ |
  | `shell_tool` だけ切る | `exec_command`・`write_stdin` が消える |
  | 司令塔の設定（シェル・Computer Use・ブラウザ・apps・plugins・goals などを切る） | `cua_repl` も消え、`exec` の中は `apply_patch`・`view_image`・MCP のリソース 3 つだけ |

  - 残る `apply_patch` は、読み取り専用のサンドボックスが「patch rejected: writing is blocked by read-only sandbox」で断り、ファイルはできなかった（偽のサーバーに呼ばせて確かめた）
- Computer Use の `createBrowserTab(..., {visible: true})` は、どちらのマシンでも「Capability is not available: visibility」で失敗した。`visible` を外すと開いた
- バックグラウンドからのキー入力（computer use の `app_type`）は Flutter のテキスト欄に入らなかった（アクセシビリティの値は書けたが、画面の入力に反映されない）。
  画面からの入力は、窓を前に出して打ち込んで確かめた。同じ bundle ID のアプリを 3 つ起動すると、computer use からは 1 つの窓しか選べなかった

## Limitations

- **シグナリングに認証が無い。** brain は `0.0.0.0:8765` で待ち受け、届いた相手は誰でも body として参加できる。参加した body のアプリは brain の console と同じ操作ができ、
  brain は body の上のワーカーに承認なしの全権限を渡す。信頼できるネットワーク（自分の LAN・VPN）の外では動かさない
- brain が落ちたときの引き継ぎは無い。body はつながり直すが、前の brain の会話とワーカーの台帳は消える。body の上で動いていたワーカーは、brain が消えたときに中断する
- 小さな課題で、それぞれ 1 回ずつ確かめた。長い仕事、大きな文字起こし（数 MB の snapshot）、データチャネルの送信バッファがあふれたときは試していない
- 確かめたのは macOS だけ。Windows の body は、Codex と中継プロセス（Node）を Windows で動かす作業が別に要る
- 2 台の間で、どの候補の組（LAN か VPN か）でつながったかは確かめていない
- 司令塔の質問（Claude の AskUserQuestion）への答えを body の console から送る経路は作ったが、試していない
- 作業フォルダの選択（左のフォルダ）は brain の console でだけ選べる（パスが brain のマシンのものなので）
- kiapi はこの検証では使っていない（各 body に kiapi の app-server が立つが、ワーカーは Codex と Claude だけで確かめた）

## How to run

前提: 各マシンで `codex login` と `claude auth login`（サブスク）を済ませておく、mise。

```bash
mise run                                                       # sidecar の型検査と flutter analyze
ORCH_NAME=brain ORCH_CWD=path/to/project mise run run          # brain（ORCH_BRAIN_URL が無ければ brain）
ORCH_BRAIN_URL=ws://<brain のホスト>:8765 ORCH_CWD=path/to/project mise run run   # body
```

- 同じマシンで複数起動するときは、`ORCH_STATE_DIR` を分ける（設定と kiapi 用の `CODEX_HOME` が入る）
- `ORCH_PROMPT` を渡すと、起動して brain につながった後に、その console から 1 回送る（画面の入力と同じ経路）
- `ORCH_DUMP=path.json` を渡すと、その console が表示しているもの（スレッド、操作の数とハッシュ、最後の回答、接続の記録）を書き出す
- `ORCH_PORT` で brain の待ち受けのポートを変えられる（既定 8765）

## Environment

- macOS 27.0.1。MacBook Pro M1 Max（brain と body 2 つ）、Mac Studio M4 Max（body 1 つ）。2 台は同じ LAN と VPN の中
- Flutter 3.47.2、flutter_webrtc 1.6.2+hotfix.4、Node 22.22
- codex-cli 0.159.3（MacBook Pro）・0.160.1（Mac Studio）、`@anthropic-ai/claude-agent-sdk` 0.3.289
- 司令塔 `gpt-5.6-luna`（effort low）、Codex のワーカー `gpt-5.6-luna`、Claude のワーカー `haiku`
- 実行日: 2026-10-09
