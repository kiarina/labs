# Several orchestrators on one network: a signaling server with a roster and body ownership

司令塔（brain）を 1 つのネットワークに複数置きます。

- **body の所属**: 各 body（ワーカーを動かすアプリ）は 1 つ以上の brain に所属し、所属先の brain だけがそこでワーカーを動かします。所属は console の body の設定（⚙）で変えます
- **共有の body**: 複数の brain に所属する body は、一度に 1 つの brain が使います（譲り合い）。使っている brain がいる間、ほかの brain はそこで読むこと（使用中の作業の一覧、`fetch_image`）だけができ、新しい仕事は断られます
- **console**: brain を選び、選んだ brain と話します
- **シグナリング**: 独立したサーバーにし、名簿（どのアプリがいるか、どれが brain・body か）と所属（body → brain）を持たせます。単独のプロセスでも、アプリの中でも動きます
- **起動画面**: アプリを起動すると、シグナリング → 役割（brain・body）→ brain の設定 → 所属 → body の設定の順に選んでから、起動と接続をします
- **orchestrator と worker**: brain が使うエージェントを orchestrator、body が使うエージェントを worker と呼び、別々に設定します。orchestrator は 1 つを選び（モデル・effort・フォルダ）、Mac や Chrome を操作する道具を持ちません。同じアプリが brain と body を兼ねても、プロセスは別です
- **worker type**: body が worker として出すエージェントを、起動画面で決めます。Codex と Claude は 1 つずつ on/off、別のモデルのサーバーにつないだ Codex（custom）はいくつでも。それぞれ足すときに、動くか・ログインしているかを確かめます。司令塔は、選べる種類を tool の定義でなく `list_bodies` の結果で知り、変わったら次のメッセージで知らされます
- **body の一時停止**: console から、接続したまま body を止められます。止めている間、brain はその body で新しいことを始めません（実行中のものは最後まで動きます）
- **brain の設定を console から変える**: Brains の一覧の ⚙ から、その brain の orchestrator の設定（起動画面の Brain と同じ内容）を変えます。↺ で新しい会話にします
- **body の設定を console から変える**: 止めていて何も動いていない body の、エージェント（起動画面の Agents と同じ内容）を console から変えます。確かめはその body のマシンで動き、保存すると body がエージェントを起動し直します

前提となる lab:
- [N 個のアプリを WebRTC でつなぎ、1 つの brain が複数の body を使う形](../flutter-agent-orchestrator-mesh/README.md)（この lab はその写し。司令塔のツール、文字起こしの写し方、画像の運び方はそちら）

## Purpose

1. 複数の brain を同時に動かし、それぞれが自分の所属の body だけを使えるか
2. console で brain を切り替え、選んだ brain に送れるか。どの console にも全部の brain の会話が同じに出るか
3. body の所属を console から変えられるか。ワーカーが動いている間は変えられないようにできるか。1 つの body を複数の brain で共有し、競合を防げるか
4. 1 つのアプリで、起動時に役割（brain・body・シグナリング）を選べるか
5. ワーカーの種類を固定の 3 つ（Codex・Claude・kiapi）から、body ごとに設定で増やせる形にできるか。会話の途中で増えた種類を司令塔が使えるか
6. 動かすエージェントを起動画面で決め、その場で動くか確かめられるか。エージェントが 1 つも無い body を置けるか
7. ワーカーに Mac や Chrome を操作させる道具を worker type ごとに on/off し、要る許可を起動画面の中で通せるか

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
- **起動画面のステップを、widget のテストで本物のシグナリングに対して通した**（`mise run` で流れる。エージェントの確かめと macOS の許可は偽物）
  - 既存につなぐ → 名前がぶつかると注意が出る → Body → 名簿の brain-a・brain-b から選ぶ → Body の設定
  - このアプリで起動する → 使われているポートでステップ 1 に止まる → 空いたポートで進む → Brain と Body → 所属先の既定がこのアプリ
  - どちらも選ばない → ステップ 2 で起動する（console だけ）
  - Brain: エージェントを 1 つ選ぶ（Codex のログインのボタン、custom の足りない項目で止まる、Claude・フォルダ・起こさないを `brain.json` に保存。道具と許可の欄が出ない）
  - Body: Codex のログイン、Claude を off、custom の追加（モデルの一覧から選ぶ、不正な id で止まる）、道具の on/off と要るものの表示、許可の［Grant］と起動し直しのボタン、保存の中身
- **オーナーが本物の画面で、起動画面を最後まで通した。** Agents のステップで Codex・Claude・kiapi を確かめ、Peekaboo の画面収録をこのアプリに許可した
- widget のテストの中の `HttpClient` は、すべて 400 を返す偽物になっている（`HttpOverrides.global = null` で外す）。
  本物の通信の結果は、実時間を待つ（`runAsync`）だけでは画面に届かず、待つことと `pump` を交互に繰り返す
- **会話の途中で body に足した worker type を、司令塔がそのまま使えた。** 司令塔は Codex（`gpt-5.6-luna`、effort low）、custom の送り先は何にでも「OK」と答える偽の Responses API（`probes/fake_responses.py`）
  1. body-c に custom が無い状態で `start_thread(body-c, worker_type: "fake")` を頼んだ。tool は「no worker type "fake" on body-c」と、body-c で選べる `codex`・`claude`・`kiapi` を返した
  2. body-c の `worker-types.json` に `fake` を足して起動し直し、同じ会話で同じ指示を console だけのアプリから送った
  3. 司令塔は `fake` のワーカーを起動し、答え「OK」を受け取った。`list_bodies` の body-c には `fake — fake-model` が出た。偽のサーバーには `model: fake-model` と、普通の関数の形のツールが届いた
  4. 司令塔の会話は作り直していない。tool の定義は会話の最初のまま
  - console だけのアプリにも、同じ会話が同じハッシュで出た

- **エージェントを起動画面で決め、その場で確かめられた。**（モデルのトークンは使わない）
  - Codex: app-server を起動してアカウントを読む。このマシンでは「Logged in (prolite)」。未ログインなら、起動画面からブラウザのログインを始める（`account/login/start`。画面の流れは偽の確認役で確かめた）
  - Claude: 中継プロセスを起動してアカウントを読む。このマシンでは最初「未ログイン」と正しく出た（`claude auth status` も `loggedIn: false`）。
    オーナーが `claude auth login` した後は「Logged in (Claude Max)」
  - custom: `GET {base_url}/models` で、届くか・指定のモデルがあるかを見る。偽のサーバーで「ある」「無い」「届かない」を確かめた
  - 作業フォルダを指定すると、アプリがその中を 1 回読む。無ければここで止まり、macOS のフォルダの許可のダイアログもこの時点で出る
- **エージェントが 1 つも無い body を置けた。** エージェントのプロセスを 1 つも起動せず（子プロセス 0）、司令塔の `list_bodies` には「no worker types」と出た（brain の orchestrator は body の設定と別なので、brain と兼ねる body も 0 個でよい）
- **body の中身が変わったことを、司令塔が次のメッセージで知った。** エージェントの無い body-c を、Codex と Claude を on にして起動し直した。
  console から「tool を呼ばずに、body-c の worker type を答えて」と送ると、
  メッセージの頭に `[bodies changed since you last called list_bodies]` と `- body-c: worker types are now codex (were none)` が付いた。
  司令塔は「codex。知らせにそう書いてあった」と答えた（Claude は未ログインなので入らない）
- **1 つの body を 2 つの brain で共有し、競合を防げた。**（トークンを使わない: 答えを 40 秒遅らせる偽の Responses API の custom worker と、`ORCH_TOOLS`）
  - body-c を brain-a・brain-b の両方の所属にした。brain-a がワーカーを始めると、brain-b の `list_bodies` に `in_use_by: brain-a` と brain-a の作業（題名「hold the body」・running）が出た
  - その間、brain-b の `start_thread` は「in use by brain-a」で断られ、`fetch_image`（読み取り）は通った
  - brain-a のワーカーが終わると body-c が空き、brain-b の `start_thread` が通った。brain-a の console には、共用の「body-c (2)」に「in use by brain-b」、専用の「body-d (1)」、その他に所属なしの「body-e (0)」が出た（スクリーンショット）
  - 本物のモデルの司令塔（brain-b、Codex）も、使用中の body-c で `start_thread` が断られると「別の brain の処理で使用中のため実行できません」と答えた（オーナーの操作）
  - シグナリング（複数の所属、外される brain が断ると変えない）と、brain の振る舞い（断る・待たせる・知らせる）は単体のテストで確かめた（`test/shared_body_test.dart`）
- **orchestrator と worker のプロセスを分けられた。** brain と body を兼ねる brain-a は、orchestrator の Codex と、body の Codex・Claude を別々のプロセスで起動した（子プロセスが 3 つ）。
  body-c の console から brain-a の設定を Claude に変える（`ORCH_CONFIGURE_BRAIN`）と、orchestrator の Codex だけが Claude の中継に入れ替わり、body のプロセスはそのまま残った。
  Brains の一覧に「Claude · default」と ↺・⚙ が出た（スクリーンショット）。ダイアログ（読み込み、brain のマシンでの確かめ、モデルと effort の選択、保存の中身）は widget のテスト（`test/brain_settings_test.dart`）で確かめた
- **接続したまま body を一時停止できた。** body-c の console から body-c を止める操作が、所属先の brain-a を通って body-c に届いた。
  body-c は自分の状態を `paused` にして brain-a へ知らせ、brain-a と body-c の両方の console に「paused」と出た（`ORCH_PAUSE` と dump、スクリーンショット）。
  止めている間と再開の後の brain の振る舞い（新しい仕事を断る、実行中は続く、順番待ちは残る、知らせ）は単体のテストで確かめた（`test/pause_test.dart`、トークンは使わない）
- **止めた body の設定を、console から変えられた。** body-c の console から、brain-a を通して body-c の設定（Codex だけ・6 つまで → Codex と Claude・5 つまで）を送ると、
  body-c が `worker-types.json` を書き換えてエージェントを起動し直し（古い Codex のプロセスは終わり、Codex と Claude の中継が 1 つずつ）、brain-a の一覧に「Codex, Claude · 5 at once」と出た（`ORCH_CONFIGURE` と dump、スクリーンショット）。
  画面（読み込み、body のマシンでの確かめ、ログインと許可のボタンを出さない、保存の中身、断られたときの表示）は widget のテスト（`test/body_settings_test.dart`）、
  brain の守り（止めていない・ワーカーが動いているか待っているなら断る、古いスレッドを終わらせる）は単体のテストで確かめた

- **Mac や Chrome を操作させる道具を、worker type ごとに on/off できた。** 偽の Responses API に、ワーカーのモデルへ渡る道具を記録させて確かめた（トークンを使わない）
  - Codex の Computer Use の正体は、computer-use のプラグインが足す `cua_repl`（Mac のアプリと Chrome の操作）。`features` の `computer_use`・`browser_use` などを切っても消えず、
    スレッドの `config` で `plugins."computer-use@openai-bundled"`・`"unified-computer-use@openai-bundled"` を切ると消えた
  - custom（別の `CODEX_HOME`）には、設定・プラグイン・ログインを写しても `cua_repl` が出なかった。Computer Use を on にした custom は、ユーザーの `~/.codex` のまま
    モデルの送り先と表だけを替えて起動し、ほかの MCP サーバー・つないだアプリ・マルチエージェントなどはスレッドごとに切る。off なら `exec_command`・`write_stdin`・`request_user_input`・`view_image` だけ、
    on なら `cua_repl` が足され、ユーザーの MCP サーバーは出ない（`app/test/worker_tools_live_test.dart`）
  - kiapi（`qwen3.8-flash-next`）のワーカーで、Computer Use の `cua.getState()` が通った。最初は「node_repl is unavailable for this model」で全部失敗した:
    custom の表で `node_repl_disabled` を立てていたため（Computer Use は node_repl の上で JavaScript を動かす）。on のときは外すようにした。
    続けて kiapi のワーカーに「Computer Use で計算機を開いて表示を読んで」と頼むと、`cua.getApp("com.apple.calculator")` で開いて「144」と答えた
    （日本語の名前 `計算機` では「Invalid app」で、bundle ID で通った）
  - Claude の Chrome（`--chrome`）と Mac の操作（Peekaboo）は、ワーカーのセッションにだけ付ける
- **要る許可を、起動画面の中で確かめて通せる。**
  - このアプリの画面収録・アクセシビリティ: ワーカーはこのアプリの子プロセスなので、シェルで撮る・クリックする（`screencapture`・AppleScript）と、このアプリが聞かれる。
    状態を読み、［Grant］で macOS のダイアログを出す（runner の Swift で `CGRequestScreenCaptureAccess`・`AXIsProcessTrustedWithOptions`）。画面収録は許可の後に起動し直しが要るので、設定を保存して起動し直すボタンを出す
  - Codex の Computer Use: 実体は Codex アプリが入れる別のアプリ（`com.openai.sky.CUAService`）で、macOS の許可はそのアプリが持つ。起動画面では、それが入っているかと、プラグインが on かを見る
  - Peekaboo: ワーカーには `peekaboo mcp serve --no-remote --allow-foreground` で渡し、このアプリの中で動かす。許可はこのアプリのもの（上の画面収録・アクセシビリティ）になり、
    起動画面の［Grant］で通せる。状態は `peekaboo permissions --json --no-remote` をこのアプリから呼んで見る。Claude Code から MCP がつながるか（`connected`）も確かめた
  - **Peekaboo 4.9 の既定は、バックグラウンドのサービス（launchd が起動する `peekaboo daemon`）経由で動き、許可もそちらに要る。** そのサービスはアプリではない素のコマンドなので、
    自分で一度求めるまでシステム設定の画面収録の一覧に出ず、オーナーは許可のトグルを出せなかった（アクセシビリティは通せた）。`--no-remote` でこのアプリの許可に寄せた
  - Claude in Chrome: Chrome と、拡張の接続口（native messaging host）が入っているかを見る。Claude Code の MCP の状態には、最初のターンまで Chrome が出てこない。
    Chrome のプロフィールのフォルダは macOS が守っていて、読むとそれ自体が許可のダイアログになるので、拡張そのものは見ない

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
  - 所属: `body → brain の一覧`（古い形の 1 つの名前も読める）。body でもある brain は、最初の参加で自分を所属させる。ほかの body は所属なしから始まる。body でないアプリは所属を持たない。アプリが抜けても所属は残る
  - 所属はファイルに書いて、起動し直しても残す（アプリの中では状態のフォルダの `signal-owners.json`、単独では `OWNERS_FILE`）
  - 中継: offer・answer・ICE の候補を宛先付きで回す
  - 所属は「body → brain の一覧」。所属の変更（`assign`）は一覧を丸ごと送る。加えるのは誰にも尋ねない。外される brain が online なら `releaseRequest` で尋ね、どれかが断れば変えない（5 秒で答えが無ければ失敗）。
    外される brain が offline なら尋ねない
- **データチャネル**: 少なくとも片方が brain の組ごとに 1 本。名前の順で先のアプリが offer を出す
  - 1 本の中で、brain の役のメッセージ（`rpc`・`console`）と、相手の役のメッセージ（`hello`・`info`・`res`・`agent`・`action`）は種類が重ならない。そのため brain どうしも 1 本で足りる
- **brain**: つながった全アプリの console へ会話を流す（前の lab の `ConsolePublisher`）。全アプリの body を名簿として知っている
  - orchestrator は brain だけのプロセスで動く（`app/lib/orchestrator/brain_agent.dart`）。設定は状態のフォルダの `brain.json`（`brain_config.dart`）: エージェント（`codex`・`claude`・`custom`。custom は URL・鍵の変数名・モデル）、モデル、effort、フォルダ（空なら body のプロジェクトのフォルダ）、終わったら起こすか
  - 同じアプリの body の worker とはプロセスを分ける（Codex の app-server・Claude の中継を役割ごとに起動する。ログインは `~/.codex` と Claude Code のものを共有）。
    そのため body の設定を変えても orchestrator の会話は続き、brain の設定を変えても worker は動き続ける。custom の orchestrator は、いつも専用の `CODEX_HOME` で起動する（Computer Use を持たないため）
  - 設定を変える（`brain/configure`）と、orchestrator が動いていないときだけ、保存してエージェントを起動し直し、新しい会話にする
  - ワーカーを動かせるのは、所属の body だけ（`list_bodies`・`start_thread`・`fetch_image`）
  - `releaseRequest` には、その body で自分のワーカーが動いている・待っているなら理由を返して断る
- **共有の body の使用中**（`heldBy`）: 誰が使っているかは body が決める。その brain のワーカーが body で動いているか、作られて始まるのを待っている間、その brain が使用中。全部終わる（閉じる・始まらずに終わる・brain が去る）と空く
  - body が断る: ほかの brain が使っている間の `agent/create`（新しいスレッド）と、動いていないスレッドへの `agent/send`（新しいターン）。読むもの（`file/image`）と、自分のスレッドへの追加の指示・停止は通す
  - brain も先に断る: ほかの brain が使っている body への `start_thread` と、そこのスレッドへの新しいターン（`send_message`）はツールのエラーにする（使える body の一覧を付ける）。自分の順番待ちは待たせ、`list_threads` に `waiting_for` が付く
  - 司令塔には `list_bodies` で `shared_with`（ほかの所属先）と、使用中なら `in_use_by` と `their_work`（その brain の作業の題名・状態）を見せる。使用中になった・空いたは `[bodies changed ...]` で伝わる
  - 同時に動かせる数は変えない（使えるのは 1 つの brain だけなので、そこで動くのはその brain のワーカーだけ）。単位は body だけで、フォルダ単位などには分けない（ワーカーが決めたフォルダの外を触らない保証が無いため）
  - 一時停止と設定の変更は body 全体にかかる。設定の変更は、どの brain のワーカーも無いときだけ
- **worker type**（`app/lib/agents/worker_types.dart`）: そのアプリで動かすエージェント。id で呼ぶ
  - `codex`・`claude` は 1 つずつで on/off（同じ種類を複数並べると、司令塔が違いを説明から読み分けることになるため）。custom はいくつでも
  - 起動画面の「Body」で決め、状態のフォルダの `worker-types.json`（`ORCH_WORKER_TYPES` で場所を変えられる）に書く。ファイルが無ければ Codex と Claude（`KIAPI_BASE_URL` があれば kiapi も）
  - 種類ごとに既定の作業フォルダと既定のモデルを持てる。作業フォルダは `start_thread` の `cwd` > worker type の作業フォルダ > body のプロジェクトのフォルダの順
  - body のプロジェクトのフォルダも起動画面で決める（空なら `ORCH_CWD`、それも無ければホーム）。同じアプリの brain は、自分のフォルダが空ならここで働く
  - worker type として司令塔に見せる。0 個でもよい（body のツール `fetch_image` だけが使える）
  - 1 つずつ起動し、どれかが失敗しても（未ログイン、サーバーに届かない）ほかは使える。失敗したものは理由付きで「使えない」と知らせる
  - Mac や Chrome を操作させる道具は、既定で off。Codex と custom は Computer Use、Claude は Chrome と Mac の操作（Peekaboo）。on のものは `list_bodies` の `can_also_use` で司令塔に見せる
  - custom は Codex の app-server を種類ごとに 1 つ起動し、モデルの送り先をその種類の Responses API のサーバーにする（自前の `CODEX_HOME` とモデル表）。
    Computer Use を on にした custom だけは、ユーザーの `~/.codex` で起動する（上の Answer）
  - body は brain に、種類ごとに id・種類（codex・claude・custom）・表示名・説明・同時に動かせる数・モデル・使えない理由を知らせる。API キーは環境変数の名前（`env_key`）だけを設定に持ち、値は body のマシンから出ない
  - 司令塔の `start_thread` の `worker_type` は文字列で、tool の定義に選択肢（enum）を持たない。選択肢は会話の途中で変わり、body ごとにも違うため。司令塔は `list_bodies` の `worker_types` で知り、無い種類を指定したらその body の一覧をエラーに付けて返す
  - 同時に動かせる数は、body ごとの上限（起動画面の「Workers at once on this body」、既定 4）と、種類ごとの上限（`max_concurrent`）の両方で決まる。
    どちらも body の設定で、brain は body から知らされた値を使う（マシンとサブスクは body ごとのため）
  - brain は、司令塔が最後に `list_bodies` で見た内容（body ごとの worker type）を覚え、次に司令塔へ送るメッセージ（ユーザーの発言、`[worker update]`）の頭に違いを添える。
    body の起動し直し、加わる・抜ける、所属が移る、のどれでも同じに扱う（console の操作のイベントでなく、今の内容と見せた内容の差で見る）
- **body**（body を選んだアプリ）: つながった brain ごとに `BodyHost` を置く。rpc は、今の所属先の brain からのものだけを受ける
  （所属が変わる前に始めたエージェントの `close`・`interrupt` は受ける）
- **一時停止**: 止めている状態は body が持ち（メモリだけ。起動し直すと止めていない状態に戻る）、`info` の `paused` で brain へ知らせる。
  console の body の一覧のボタンから、所属先の brain を通して body へ送る（rpc `body/pause`）。所属先の brain が変わっても、止めたまま
  - brain が先に断る: 止めている body への `start_thread`・`fetch_image`、終わったスレッドへの新しいターン（`send_message`）はツールのエラーにする
  - body も断る（最後の守り）: `agent/start`、実行中でないエージェントへの `agent/send`、`file/image`
  - 断らないもの: 実行中のターン（その追加の指示も）。止める前から順番待ちのものは待ったまま残り、再開すると始まる（`list_threads` に `waiting_for`）
  - 司令塔には `list_bodies` の `paused: true` と、次のメッセージの頭の `[bodies changed ...]`（「paused by the user」「resumed」）で伝える
  - 司令塔そのものはワーカーではないので止まらない
- **設定の変更**（`app/lib/ui/body_settings.dart`）: console の body の一覧の設定のボタンから。止めていて、所属先の brain のワーカーがそこで動いても待ってもいないときだけ押せる
  - 編集の画面は起動画面の Body と同じ部品（`app/lib/ui/agents_editor.dart`）。確かめ（ログインの状態・モデルの一覧・道具の要るもの・macOS の許可）は body のマシンで動かす（`body/check`）。
    ログインと許可を出す操作は、そのマシンの起動画面でする（console には出さない）
  - console → brain は `request`／`reply`（答えの要る依頼）、brain → body は rpc `body/config`・`body/check`・`body/configure`。brain は `body/` で始まるものだけを通す
  - brain も body も断る: 止めていない、エージェントが動いている（brain はさらに自分のワーカーが待っているとき）
  - 保存すると body は古いエージェントを止めて起動し直す。そこにあったスレッドは終わり、`send_message` はエラー、`list_threads` に `ended` が付く。同じアプリの brain の orchestrator は別のプロセスなので続く
  - 止めたままなので、終わったら再開する。worker type の変化は、司令塔に `[bodies changed ...]` で伝わる
- **console**（全アプリ）: つながった brain ごとに写し（`BrainView`）を持つ。選んだ brain の写しを中央と右に出し、送信・停止・設定はその brain へ送る
  - 左には次を出す
    - Brains: 選ぶと、その brain と話す。行に orchestrator が何で動いているか（エージェント・モデル・effort）。↺ で新しい会話（ワーカーは続く）、⚙ でその brain の設定（`app/lib/ui/brain_settings.dart`。編集は起動画面の Brain と同じ部品 `brain_editor.dart`、確かめは brain のマシンで `brain/check`）
    - body の一覧を「Bodies of <選んでいる brain>」と「Other bodies」（ほかの brain のもの・所属なし）に分ける。名前の後ろに所属する brain の数（1 なら専用、2 以上なら共用）、使えるエージェント・同時に動かせる数。
      ほかの brain が使っているときだけ「in use by brain-b」。重ねると所属先・プロジェクトのフォルダ・サブスクの使用量
    - 所属先は body の設定のダイアログ（⚙）の「Belongs to」で変える。ダイアログは止めていて、どの brain のワーカーもいないときだけ開けるので、所属先の変更も同じ条件になる。
      所属なしの body は止める操作を中継できる brain がいない（ワーカーも動いていない）ので、いつでも開け、中身は「Belongs to」だけ。エージェントは変わったときだけ保存して起動し直す
    - 知らせ（所属の変更など）は失敗したときだけ出す
  - 所属の変更は signal へ送る

### 起動画面

`ORCH_ROLE`・`ORCH_SIGNAL_URL`・`ORCH_NAME` のどれも無いときに出る。ステップに分け、前のステップで分かることを次のステップで使う。
前回の選択を状態のフォルダの `launch.json` に覚え、次の初期値にする。

| ステップ | 選ぶもの | 「次へ」で起きること |
| --- | --- | --- |
| 1. Signaling | このアプリで起動する（ポート）か、既存につなぐ（URL。既定 `ws://localhost:8765`）か | 起動する、または問い合わせる。ポートが使われている・読めないなら、ここで止まる。読めたら名簿を持って次へ |
| 2. Roles | 名前（body_id。空なら「ホスト名-乱数 4 桁」）、Brain・Body（両方も可） | 名前が online のアプリとぶつかると、`-2` が付くと注意を出す。Body を選ばなければ、ここで起動する（どちらも選ばなければ console だけ） |
| 3. Brain（Brain のとき） | orchestrator のエージェント（Codex・Claude・custom から 1 つ。custom は URL・API キーの変数名・モデル）、モデル（確かめると一覧から選べる）、effort（そのモデルが受け付けるもの）、フォルダ、ワーカーが終わったら起こすか。道具と macOS の許可は無い | 入ったとき・選び直したとき・「Check」で確かめる。Codex が未ログインならログインのボタンが出る。Start で `brain.json` に書く |
| 4. Belongs to（Body のとき） | 所属する brain（複数選べる。複数なら共有）。候補は、自分が brain ならこのアプリ（既定）と、名簿にいる online の brain | 次へ。参加の後に所属を変える |
| 5. Body（Body のとき） | このマシンのプロジェクトのフォルダと、body なら同時に動かせるワーカーの数（1〜16）。Codex・Claude の on/off・作業フォルダ・既定のモデル（確かめると一覧から選べる）・同時に動かせる数、Mac や Chrome を操作させる道具の on/off（on にすると、要るものとその状態が出る）、このアプリの macOS の許可、custom の追加（id・URL・API キーの変数名・モデル・作業フォルダ・説明・同時に動かせる数）。custom のモデルは、URL を入れて「Load models」でサーバーの一覧を読み、そこから選ぶ（一覧の無いサーバーは手で入れる。選んだモデルのコンテキスト長も一緒に覚える）。同時に動かせる数はスライダー（0〜8、0 は「上限なし」） | 入ったとき・on にしたとき・「Check」で確かめる。Codex が未ログインならログインのボタンが出る。Start で `worker-types.json` に書いて起動する。0 個でもよい |

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
- 写した lab の中継プロセス（Node）の `node_modules` を入れ忘れると、Claude だけでなく Codex も使えないと表示された。
  起動の失敗が 1 つでもあると、本体の準備ができていない扱いにしていたため。今はエージェントごとに起動し、失敗したものだけを理由付きで「使えない」にする
- 所属は signal が持つので、brain や body を起動し直しても所属は残った。signal はファイルにも書くので、signal を起動し直しても残った
- 起動画面のエラーは、画面の部品の初期化（`initState`）の中だけで読むと、後から出たエラーが表示されない。エラーを key にして作り直した
- body でもある brain の所属先の既定を「所属なし」にすると、起動のたびに自分の body を手放してしまう。既定を「このアプリ」にした
- **console だけのアプリから送った発言を、brain が捨てていた。** brain は console の操作を、相手の body の窓口（body として名乗ったときに作る）で受けていた。
  console だけのアプリは body として名乗らないので、窓口が無かった。つながった全アプリから操作を受けるようにした
- custom の worker type は、モデルのサーバーに届かなくても「使える」と出る。app-server はサーバーに問い合わせずに起動するため。手元に kiapi が無い状態でも、kiapi は使える種類として一覧に出た。
  そのため起動画面で `/models` を確かめるようにした（起動した後に届かなくなったものは、まだ「使える」と出る）
- **Agent SDK のアカウント情報には「ログインしているか」が無い。** 未ログインだと `{"tokenSource": "none", "apiProvider": "firstParty"}` が返る。`tokenSource` が `none` 以外か、メール・契約の種類があればログイン済みと見なした
- 起動画面の Codex・Claude の確かめは、`flutter test` からも本物で流せる。widget のテストと違い、`HttpOverrides` を外せば普通の Dart のテストとしてプロセスを起動できる

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

- **console から body の設定を変える画面は、本物の画面のクリックでは開いていない。** 変える経路は `ORCH_CONFIGURE` で、画面は widget のテストで確かめた
- **console の brain の設定のダイアログは、本物の画面のクリックでは開いていない。** 変える経路は `ORCH_CONFIGURE_BRAIN` で、画面は widget のテストで確かめた
- **2 台の Mac では確かめていない。** 2 台目の Mac（Mac Studio）が VPN から外れていて、届かなかった
- **console の brain の切り替えと所属先のメニューは、画面のクリックでは確かめていない**
  - 使っている関数は、起動時の `ORCH_SELECT`・`ORCH_ASSIGN`・`ORCH_PAUSE` と同じ。そちらで確かめた。表示はスクリーンショットで確かめた
  - 起動画面は、widget のテストとオーナーの操作で確かめた（上の Answer）
- **認証が無い。** signal は誰でも参加でき、誰でも所属を変えられる。信頼できるネットワークの中だけで動かす
- Claude のワーカーは、Claude Code の本来のプロンプトなしで動いている（上の Findings）。直すなら中継プロセスでワーカーにも preset を渡す
- シグナリングを動かしているアプリを閉じると、全員がシグナリングを失う（所属はファイルに残る）。別のアプリがシグナリングを引き継ぐ仕組みは無い
- brain が落ちると、その brain の所属の body は所属先が offline のまま残る。console から別の brain へ移せる（offline の brain には尋ねない）
- 全アプリが全 brain とつながるので、データチャネルの数は「アプリ数 × brain 数」程度に増える。数台でしか試していない
- custom の worker type は、Responses API のサーバーだけ。Chat Completions だけのサーバーでは試していない。鍵の要る外部の API（`env_key`）も試していない
- Codex のブラウザのログイン（起動画面から）は、本物では通していない（このマシンはログイン済み）
- Codex の Computer Use は、使うアプリごとに「Allow Computer Use to use …」を実行中に聞いてくる（`mcpServer/elicitation/request`）。アプリの数だけあるので、起動画面では先に通せない。
  ワーカーは Full Access なので、セッションの間は許可すると答える（`{action: accept, content: {}, _meta: {persist: session}}`。前は知らない求めをすべて断っていた）。
  計算機の確認では聞かれなかった（前の lab で「いつも許可」にしていたため）ので、この答えはまだ本物では通っていない
- Debug のビルドを作り直すと署名が変わり、macOS の許可が外れることがある。作り直したら起動画面で確かめ直す
- 一度だけ、ワーカーの知らせ（`[worker update]`）が司令塔の動いている途中に入った後、ターンが終わっても画面が動いている表示（停止ボタン）のまま残った。
  同じ流れを 3 回やり直して再現しなかった。原因は分かっていない（ターンの状態を `ORCH_DUMP` の `turnStates` に出すようにした）

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
- `ORCH_OWNER`: 参加の後に、この body の所属先にする brain（コンマ区切りで複数。`-` は所属なし）
- 同じマシンで複数起動するときは、`ORCH_STATE_DIR` を分ける
- `ORCH_SELECT=<brain>`: console が最初に出す brain
- `ORCH_ORCHESTRATOR=codex|claude`: brain の orchestrator のエージェント（`brain.json` より優先）
- `ORCH_ASSIGN=body-c=brain-a,body-d=brain-a+brain-b,body-e=`: 起動後に所属を変える（`+` で複数、空は所属なし。console の一覧と同じ操作）
- `ORCH_TOOLS=steps.json`: brain がモデルを使わずに自分のツールを呼ぶ（`[{tool, args, delay_ms}]`。args の body が所属になるまで待つ）。結果は `steps.json.out.jsonl` に追記（トークンを使わない確かめ用）
- `ORCH_PAUSE=body-c`: 起動後に、その body を所属先の brain を通して止める（console の一時停止のボタンと同じ操作）
- `ORCH_CONFIGURE=body-c=path.json`（`ORCH_PAUSE` と一緒に）: 止まったのを見てから、その body の設定を `worker-types.json` の形のファイルの中身にする。結果は console の知らせ（dump の `notice`）に出る
- `ORCH_CONFIGURE_BRAIN=brain-a=path.json`: その brain の準備ができたら、設定を `brain.json` の形のファイルの中身にする（console の brain の ⚙ と同じ操作）。結果は console の知らせに出る
- `ORCH_PROMPT`: 選んだ brain へ、起動後に 1 回送る
- `ORCH_DUMP=path.json`: 名簿・所属・brain ごとの会話（操作の数とハッシュ、ターンの状態）・接続の記録を書き出す
- `ORCH_WORKER_TYPES=path.json`: エージェントの設定（既定は状態のフォルダの `worker-types.json`。起動画面で書くもの）
- `ORCH_FORWARD_ENV="OPENROUTER_API_KEY ..."`: アプリへ渡す環境変数の名前（custom の `env_key` の値。アプリは空の環境で起動するため）
- `mise run probe-prompts`: Codex と Claude のワーカーに自動で入るプロンプトを、偽の API で確かめる（`probes/`）
- 起動画面の確かめを、このマシンの本物の Codex・Claude で流す（モデルのトークンは使わない）:
  `cd app && LIVE_CHECK=1 CLAUDE_FLUTTER_SIDECAR=$PWD/../sidecar NODE_BIN=$(command -v node) flutter test test/agent_check_live_test.dart`
- custom のワーカーに渡る道具を、Computer Use の on/off で比べる（偽の Responses API、トークンを使わない）:
  `cd app && LIVE_CHECK=1 flutter test test/worker_tools_live_test.dart`

エージェントの設定（`worker-types.json`。起動画面で書く）:

```json
{
  "project_dir": "~/src",
  "max_workers": 4,
  "codex": {"enabled": true, "cwd": "~/src", "model": "gpt-5.6-luna", "max_concurrent": 2, "computer_use": true},
  "claude": {"enabled": true, "chrome": true, "mac": false},
  "custom": [
    {
      "id": "kiapi",
      "label": "kiapi",
      "base_url": "http://127.0.0.1:8500/v1",
      "model": "qwen3.8-flash-next",
      "max_concurrent": 1,
      "context_window": 200000,
      "description": "Codex driven by a local model: free and private, but slower and weaker. Use it for small, well-specified tasks."
    },
    {
      "id": "openrouter-qwen",
      "base_url": "https://openrouter.ai/api/v1",
      "model": "qwen/qwen3-coder",
      "env_key": "OPENROUTER_API_KEY",
      "description": "An example of a provider that needs a key (not tried in this lab)."
    }
  ]
}
```

- `project_dir`: このマシンのプロジェクトのフォルダ（`~/` 可）。`max_workers`: この body で同時に動かせるワーカーの数（既定 4）
- `codex`・`claude`: `enabled`、`cwd`（既定の作業フォルダ。`~/` 可）、`model`（既定のモデル）、`max_concurrent`。道具は Codex が `computer_use`、Claude が `chrome`・`mac`（Peekaboo）。custom も `computer_use` を持てる
- custom の `id` は英小文字・数字・`_`・`-`（`codex`・`claude` は使えない）。`base_url` と `model` は必須
- `description` は司令塔が種類を選ぶときに読む。何に向いているかを書く
- `max_concurrent`: この種類を同じ body で同時に動かせる数（省くと body の上限だけ）

## Environment

- macOS 27.0.1、MacBook Pro M1 Max
- Flutter 3.47.2・Dart 3.13.2、flutter_webrtc 1.6.2+hotfix.4、Node 22.22
- codex-cli 0.159.3、`@anthropic-ai/claude-agent-sdk` 0.3.289
- 司令塔 `gpt-5.6-luna`（effort low）、Codex のワーカー `gpt-5.6-luna`
- 実行日: 2026-10-09（起動画面と worker type は 2026-10-10、エージェントのステップと道具の on/off は 2026-10-11）
- Peekaboo 4.9.0
