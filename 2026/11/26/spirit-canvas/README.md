# A canvas mode for a spirit's chat: gpt-6.2-sol lays out text, SVG, a VRM body, media, buttons and web views with tools; actions, timelines and spirit-written JavaScript run without the model; screens are saved and reused with new values

チャットの画面に「キャンバス」のモードを足し、spirit（Codex の thread）が道具でキャンバスに好きなものを置けるかを確かめます。
入力欄はそのままです。上の履歴の代わりに、spirit が文字・絵・3D の自分の姿・写真・動画・音声・ボタン・選択肢・入力欄を座標を決めて置き、
アニメーションさせます。ユーザーが押した・選んだ・入れたことは、spirit へのメッセージとして返ります。

![秋を選ぶと描かれた絵（紅葉は 6 枚がそれぞれ別の軌道で舞い、川面の光がゆらめく）](results/s4-choose.jpg)

## Purpose

1. Flutter のアプリで、宣言した要素（JSON）だけからこの種類の画面を描けるか。VRM・動画を含めて、spirit が見るための画像に撮れるか
2. 本番級のモデル（gpt-6.2-sol）が、座標で配置して崩れない画面を自分で組めるか。押された・選ばれたことに画面で応えられるか
3. 1 画面にかかる時間とトークン。どこが重いか

評価は、画面の撮影（`canvas_view` と同じ撮り方）を目で見ることと、ターンごとの時間・道具の回数・トークン（Codex の `thread/tokenUsage/updated`）で行いました。

## Answer

- **作れた。** 見本（モデルなし）で 10 種類の要素がすべて描け、`RepaintBoundary.toImage` の撮影に VRM（flutter_scene）と動画も写った。アニメは止まらずに回る
- **gpt-6.2-sol は、整った画面を自分で組んだ。** 自己紹介では、カードの文・飾りの星・全身の VRM・「手を振り返す」ボタンを配置し、`canvas_view` で見て位置と構図を直した。
  季節の問いでは 4 枚の SVG の絵と選択肢を出し、「秋」を押すと夕暮れの川辺を描き直して、紅葉 6 枚に別々の軌道のアニメを付けた
- **画面のボタンを実際に押すと spirit に届き、画面で応えた。** 「手を振り返す」を押すと、VRM を `cheer` のポーズと `happy` の表情にし、星を脈打たせた（10 秒、道具 2 回）
- **遅い。** 新しい画面を作るターンは 50 秒〜4 分。特に SVG の絵を描くターンは、出力が 8,000〜11,000 トークンになり、最初の道具の呼び出しまで 12〜21 秒かかった
- **`canvas_view` が自分の書いた SVG を毎回全文返していたのが、入力を膨らませていた。** 長い SVG を長さだけにすると、同じ「秋の絵」のターンの入力が 435,461 → 178,919 トークン、時間が 240 → 168 秒になった（絵は別物なので条件は揃っていない。下の表）
- チャットのモードでは道具を使わずに普通に返した（6 秒）。チャットのまま「絵で見たい」と頼むと、キャンバスに描いて「切り替えると見える」と案内した
- **Part 2: spirit を通さずに動かす仕組み（要素の `on`、状態と `{{name}}`、タイムライン、spirit が書く JavaScript、通知の区別）を足すと、押したときの反応が 4〜9 ms になった。**
  Sol は 4 つのシナリオをすべて自分で書いたスクリプトで作り、タイマーの終わりにはスクリプトから spirit を起こした（[Part 2](#part-2-spirit-を通さずにアプリだけで動かす)）
- **Part 3: 画面を丸ごと JSON 1 つに保存し、値を差し替えて呼び出せるようにした。** 数学の脱出ゲームをゼロから作ると 276 秒、別の会話で英語版を頼むと、作り置きを呼び出して 39 秒（出力 11,577 → 1,415 トークン）。
  効果音と、クロスフェードする BGM も足した（[Part 3](#part-3-作り置きの画面と音)）
- **Part 4: WebView の要素で、`asset://` の差し込み、ページの JS のイベントを spirit へ、spirit が外からページの状態を読む、の 3 つができた。** Sol が web で作ったもぐらたたきは、10 秒で spirit を起こして応援させ、終わりに結果を話させた。
  spirit に見せる撮影には WebView が写らない（[Part 4](#part-4-web-要素webview)）

| | |
| --- | --- |
| ![見本](results/demo.jpg) | ![自己紹介](results/s1-intro.jpg) |
| 見本（モデルなし）。左は VRM（`wave`、`happy`）、右上は写真と動画、太陽は回転、顔は 2 コマのパラパラ、丸は跳ねる | 自己紹介。spirit が組んだもの（VRM は `framing: full`） |
| ![季節の問い](results/s3-ask.jpg) | ![街の一日](results/s5-media.jpg) |
| 「好きな季節を選択肢で聞いて」。4 枚の絵は SVG で spirit が描いた | 手元の写真・動画・音声で「街の一日」。朝・午後・夜の切り替えと再生はボタン |

## How it works

```text
app/lib/
  main.dart               画面（チャット / キャンバスの切り替え、入力欄、字幕）、道具の実行、イベントを spirit へ
  spirit.dart             codex app-server の thread 1 本（dynamicTools、code mode を切ったモデル表）
  spirit_tools.dart       道具の定義（JSON Schema）と spirit への指示
  canvas/canvas_model.dart  要素・アニメ（キーフレーム）・イベント
  canvas/canvas_view.dart   1280x800 の舞台を窓に合わせて縮める。要素ごとの描画、撮影
  canvas/vrm_element.dart   VRM（flutter_vrm）。ポーズ・表情・.vrma・構図・口パク
  control_server.dart     検証用のローカルの HTTP（送る・モード・イベント・撮影・状態）
  demo_scene.dart         モデルを使わない見本
drive.py / wait_turn.py   検証の操作と記録
```

### 道具

| 道具 | すること |
| --- | --- |
| `canvas_view(image?)` | 今のキャンバスを画像と要素の一覧で見る。ユーザーがどちらのモードかも返す |
| `canvas_put(elements[])` | 要素を置く（同じ id は置き換え）。1 回で画面全体を置ける |
| `canvas_update(id, props, transition_ms?, easing?)` | 一部の属性を変える。`transition_ms` で位置・大きさ・透明度などをなめらかに動かす |
| `canvas_animate(id, keyframes[], duration_ms, repeat, alternate, easing)` | キーフレームのアニメ。アプリが再生し、spirit はフレームごとに呼ばない |
| `canvas_remove(ids)` / `canvas_clear(background?)` | 消す |
| `canvas_media()` | 見せてよい写真・動画・音声・VRM・VRMA の名前 |

要素の種類は `text`・`shape`・`image`・`svg`（`frames` でパラパラ）・`video`・`audio`・`vrm`・`button`・`choices`・`input`。
すべて `id`・`x`・`y`・`w`・`h` を持ち、`z`・`opacity`・`scale`・`rotation`・`tappable` が共通です。属性の一覧は `spirit_tools.dart` の `_elementSchema`。

ユーザーの操作は `press`（ボタン）・`choose`（選択肢）・`submit`（入力欄）・`tap`（`tappable` の要素）・`ended`（動画・音声の終わり）で、
250 ms 以内のものをまとめて 1 通にし、`<canvas_event event="press" id="..."/>` の形で送ります。spirit の turn が動いていれば `turn/steer` で差し込みます。
ユーザーのメッセージにも毎回 `<ui mode="canvas"/>` を付けて、今どちらを見ているかを渡します。spirit の普通の返事は、キャンバスの下に字幕として出ます。

キャンバスの大きさは 1280x800 の固定で、窓に合わせて縮めます（spirit がいつも同じ座標で置けるように）。チャットのモードの間もキャンバスは描かれ続けます（spirit が見られるように）。

### Codex の設定

[司令塔の lab](../../../10/06/flutter-agent-orchestrator/README.md) と同じく、道具は `thread/start` の `dynamicTools`（`experimentalApi`）。
[API のように使う lab](../../../10/07/agent-runtimes-as-llm-api/README.md) で見つけた code mode を、`~/.codex/models_cache.json` を写して `tool_mode` などを null にしたモデル表（`model_catalog_json`）で切ります。
code mode のままだと道具の結果が 1 つの文字列になり、`canvas_view` の画像が画像として届きません。シェル・Computer Use・ブラウザなどの機能は thread ごとに切っています。

## Results

条件: MacBook Pro（M1 Max、macOS）、Flutter 3.47.2（Dart 3.13.2）、Codex CLI 0.172.0、`gpt-6.2-sol`（推論 effort は既定の low）、
ChatGPT のサブスクで実行。各シナリオ 1 回ずつ（ばらつきは見ていない）。

1 本の thread で続けて流した（s1〜s7）。トークンは累計の差分。「道具」の括弧内は `canvas_view` の回数。

| シナリオ | 時間 (s) | 最初の道具まで (s) | 道具 | 入力 | うちキャッシュ | 出力 |
| --- | ---: | ---: | --- | ---: | ---: | ---: |
| s1 自己紹介して | 56 | 4 | 10 (5) | 139,692 | 108,672 | 1,635 |
| s2 「手を振り返す」を押す（画面で実際にクリック） | 10 | 3 | 2 (0) | 51,124 | 50,432 | 177 |
| s3 好きな季節を選択肢で聞いて、答えたら絵を | 57 | 6 | 5 (2) | 121,399 | 113,536 | 2,325 |
| s4 「秋」を選ぶ（画面で実際にクリック） | 240 | 21 | 12 (2) | 435,461 | 395,264 | 10,773 |
| s5 写真・動画・音声で「街の一日」 | 116 | 3 | 10 (3) | 589,465 | 578,432 | 4,150 |
| s6 チャットのモードで朝ごはんの相談 | 6 | — | 0 | 59,007 | 58,624 | 166 |
| s7 チャットのまま「それ、絵で見てみたいな」 | 121 | 20 | 3 (1) | 253,026 | 242,176 | 5,339 |

`canvas_view` が長い SVG（300 文字を超える `markup`・`frames`）を長さだけ返すようにして、新しい thread で s3・s4 を流し直した:

| シナリオ | 時間 (s) | 最初の道具まで (s) | 道具 | 入力 | うちキャッシュ | 出力 |
| --- | ---: | ---: | --- | ---: | ---: | ---: |
| v2-s3 好きな季節を…（同じ文） | 49 | 4 | 3 (2) | 41,978 | 29,056 | 2,043 |
| v2-s4 「秋」を押す | 168 | 12 | 8 (1) | 178,919 | 167,168 | 7,845 |

- v2-s4 の差分には、間に挟まった空のイベントの 1 ターン（下の「失敗した試行」、入力 12,605）を含む
- v2 では spirit が選択肢ではなく 4 つのボタンで季節を聞いた。描いた絵も別物（[v2-s3](results/v2-s3-ask.jpg)、[v2-s4](results/v2-s4-choose.jpg)）で、比べは「同じ依頼で入力がどれだけ減ったか」の目安にとどまる
- 各ターンの記録（道具の引数・結果の先頭、要素の一覧）は `results/*.json`。長い文字列は 2,000 文字を超えると切ってある

### 観測したこと

- spirit は `canvas_view` で自分の画面を見て直した（s1 で 5 回）。直したのは位置・大きさ・VRM の構図で、文字のはみ出しはどのシナリオでも起きなかった
- s4 で spirit は、最初に 1 枚の SVG で背景を描き、葉を別の要素にして `canvas_animate` を 6 回、川面の光に 1 回呼んだ。そのあと見て、木の葉の層を別の SVG で足した
- 字幕として出る spirit の最初の一言（「キャンバスで、手を振ってごあいさつするね。」）は道具の前に出るので、待っている間の手がかりになった
- s5 の「朝・午後・夜」の切り替えボタンは、押すたびに spirit への往復になる作り（spirit が押されたら `canvas_update` で動画を替える前提）。押したときの反応は s2 から見て 10 秒前後になるはず（押していない）
- s7 で spirit はチャットのモードのまま描き、`canvas_view` の `mode: chat` を見て「切り替えると見える」と書いた。モードを切り替える道具は無い

### 失敗した試行・都合の悪い結果

- **VRM が背中を向けた。** 最初の版の `framing: full` は、カメラを +Z に置いていた。flutter_vrm の `VrmPortrait.bust` が返す向きを使うように直した。直す前の s1 で、spirit は撮影を 5 回見たが背中であることには触れず、そのまま「はじめまして」と返した
- **検証のスクリプトの誤り:** v2 で選択肢を探すスクリプトが、ボタンで聞かれたため空の `choose` イベントを送った。spirit は「季節がまだ選ばれていないみたい」と返した（5 秒）。そのあと「秋」のボタンを押し直した
- **2 回目以降のビルドが Xcode で失敗した。** `Cycle in dependencies between targets 'Runner' and 'Flutter Assemble'`。`build/macos` だけを消しても直らず、`flutter clean` からなら通った。
  そこで設定を `--dart-define` から環境変数に変え、`mise run build`（clean から）と `mise run run`（ビルド済みのアプリを環境変数付きで起動）に分けた
- `codex app-server` の既定のモデルは `gpt-6.2-astra` だった。この lab では `MODEL` の既定を `gpt-6.2-sol` にしている

## Part 2: spirit を通さずにアプリだけで動かす

Part 1 では、押すたびに spirit を往復した（ボタン 1 回で約 10 秒）。spirit が考えるのは組み立てるときだけにし、動かすのはアプリに任せる仕組みを足した。

### 足したもの

| | すること |
| --- | --- |
| 要素の `on` | 押した・選んだ・入れた・タップ・終わったときに、アプリがその場で動作の列を行う（`update`・`animate`・`put`・`remove`・`set`・`add`・`timeline`・`notify`）。`choose` は値ごとに分けられ、`$value` で値を差し込める |
| 要素の `notify` | ユーザーの操作をどう spirit に伝えるか。`now`（起こす）・`later`（次に話すときにまとめて渡す）・`none`。既定は、キャンバスの上で誰も扱わなければ `now`、`on` かスクリプトが扱えば `later` |
| 状態と `{{name}}` | 共有の値。文字・ボタンの文字の `{{name}}` に差し込まれ、値が変わるとすぐ表示も変わる。spirit は `canvas_state` で一部だけ書き換えられる |
| `canvas_timeline` | 時刻ごとの動作の列。繰り返し・1 周の長さを指定できる |
| `canvas_script` | spirit が書く JavaScript を、アプリの中で動かす。`sg.every`・`sg.after`・`sg.on`（操作・状態）・`sg.set`・`sg.update`・`sg.put`・`sg.animate`・`sg.notify(text, {wake})` |
| 通知 | 後回しの通知（`<canvas_notice>`、`handled` の付いた `<canvas_event>`）は、次に spirit へ送るメッセージの先頭にまとめて付く。起こす通知は 5 秒に 1 回までに間引き、間のものはまとめて送る |

スクリプトは、`flutter_js` 0.8.7 の 1 つの JavaScript の文脈（macOS では JavaScriptCore）で、fetch・XHR を入れずに動かす。
タイマーは JavaScript 側に持ち、アプリが 50 ms ごとに `__sg.tick` を呼ぶ。スクリプトからアプリへは `sendMessage` で、値を同期で返す。
ハンドラの中の例外は spirit への通知になり、3 回落ちたスクリプトは止める。読み込みの時点の構文エラーは道具の結果で返る。

**安全の範囲（lab の時点）:** ネットワーク・ファイル・DOM は無い。ただし、無限ループは止められない（UI と同じスレッドで同期に動くため、アプリが固まる）。製品にするなら、別の isolate かプロセスと実行時間の上限が要る。

### モデルなしの確認

`/tool` で道具を直に呼んで確かめた（`results/behaviors-demo.jpg`）: 毎秒進む時計（スクリプトが `sg.set`、文字は `{{time}}`）、`on` で数える回数と星のアニメ、0.7 秒ごとのスライドのタイムライン、
3 の倍数でスクリプトが後回しの通知を残す、構文エラーが道具の結果で返る、毎回落ちるスクリプトが 3 回で止まり通知は 2 件だけ残る。単体テスト（`test/behaviors_test.dart`）で `on`・`choose` の振り分け・テンプレート・タイムライン・通知の間引きを見ている。

### gpt-6.2-sol に流した結果

新しい thread で、b1〜b4 を続けて流した。

| シナリオ | 時間 (s) | 最初の道具まで (s) | 道具 | 入力 | うちキャッシュ | 出力 |
| --- | ---: | ---: | --- | ---: | ---: | ---: |
| b1 地理クイズを 3 問、答えたらその場で正誤と点数 | 69 | 14 | clear, put, script, view | 60,822 | 32,384 | 2,868 |
| b1 を解いた後「終わったよ！どうだった？」 | 31 | 5 | view, put, view | 68,858 | 61,184 | 1,160 |
| b2 1 分のタイマーと時刻、スタートボタン、終わったら声をかけて | 50 | 11 | media, clear, put, script, view | 127,650 | 122,624 | 2,066 |
| b2 のタイマーが終わってスクリプトが spirit を起こした | 2 | — | — | 23,444 | 23,040 | 21 |
| b3「タイマーは 3 分、時刻はオレンジに。ほかはそのまま」 | 24 | 20 | script, view | 73,016 | 62,208 | 982 |
| b4 自己紹介を 3 枚のスライドで 4 秒ごと、最後に「もう一度」 | 79 | 11 | view, clear, put, view, script, view | 198,340 | 184,704 | 3,365 |

| | |
| --- | --- |
| ![クイズ](results/b1-quiz-done.jpg) | ![タイマー](results/b2-timer.jpg) |
| b1 を 3 問解いた後。答え合わせ・点数・進み具合・次へはすべてスクリプト | b2 の集中タイム |

spirit が書いたスクリプトは `results/scripts/`（46〜61 行）。

- **押したときの反応が、spirit の往復なしになった。** クイズの選択・次へを 5 回押し、押してから画面の値が変わるまで 4〜9 ms（制御のポートから押して状態を読むまで。描画の時間は含まない）。その間 spirit は一度も起きなかった
- **時間で spirit を起こせた。** タイマーのスタートを画面で実際にクリックし、ちょうど 1 分後にスクリプトが `sg.notify(..., {wake: true})` で起こした。spirit は道具を使わず 2.5 秒で「1分経ったよ。集中タイム終了、おつかれさま！」と返した
- **Sol は 4 つとも JavaScript のスクリプトで作った。** `on`・`canvas_timeline`・`canvas_state` は一度も使わなかった。スライドショー（b4）もタイムラインではなくスクリプトだった
- **spirit は答えのボタンに自分で `notify: "none"` を付けた。** 押されたことを自分に知らせない選択で、「どうだった？」と聞かれると `canvas_view` で画面を読み、「3問中2問正解、第2問の正解は琵琶湖」と答えた（31 秒）
- **「ほかはそのまま」の部分の変更（b3）は、スクリプトの丸ごとの書き直しになった。** タイマーの長さと時刻の色をスクリプトの中に持っていたため。画面は作り直さず 24 秒で済んだが、長さを状態に出していれば `canvas_state` の 1 回で済んだはず（解釈）
- 「終わったら教えて」（b1）は、spirit を起こすのではなく、画面に「全3問終了！ 3問中2問正解」を出す形にした
- スライドは約 4 秒ごとに切り替わり、最後のスライドでだけ出る「もう一度」で最初に戻った。表示中に押しても何も起きない作り

## Part 3: 作り置きの画面と音

使ってみたオーナーから、spirit の字幕が出続けて邪魔だったことと、作っておいた画面をすぐ流したい、音や BGM を鳴らし・変えたい、という声があった。

### 足したもの

| | すること |
| --- | --- |
| 字幕 | 流れてくる間と、読み終える程度の時間（4 秒 + 1 秒に 8 文字）だけ出して消える。キャンバスに触ると消える |
| `canvas_save` | 画面を丸ごと 1 つの JSON に保存する（要素・背景・状態・タイムライン・スクリプトの元のコード・BGM）。`params` に、呼び出すときに差し替える状態の名前と説明を書く |
| `canvas_load` | 保存した画面を、`values` で params を差し替えて一度に出す |
| `canvas_scenes` | 作り置き（lab の `scenes/`、Git に入る）と spirit が保存したもの（`work/scenes/`）の一覧。名前・説明・params だけ |
| `canvas_audio`、動作の `sound`・`bgm`、`sg.sound`・`sg.bgm` | 効果音を 1 回鳴らす。BGM は 1 本で、曲を替えるとクロスフェード、同じ曲なら音量だけ動かす、`stop` でフェードアウト |
| 音の素材 | `make_sounds.py` が標準ライブラリだけで合成する（効果音 7 個、8 小節の BGM 3 曲）。ライセンスの要る素材は使わず、生成物は Git に入れない |

指示には「作る前に `canvas_scenes` を見て、合うものがあれば値を差し替えて呼び出す」「使い回せそうな画面は、変わりうる値を状態に出してから保存する」を足した。

### 結果

| シナリオ | 時間 (s) | 最初の道具まで (s) | 道具 | 入力 | うちキャッシュ | 出力 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| c1 中1数学の宇宙基地からの脱出ゲーム、5 問、BGM と効果音つき、別の教科でも使えるよう保存して | 276 | 5 | 17 | 454,601 | 416,000 | 11,577 |
| c2 （アプリを起動し直した新しい thread で）「宇宙基地からの脱出ゲーム、今度は中学1年の英語でやりたい」 | 39 | 4 | 4 | 67,594 | 38,784 | 1,415 |

| | |
| --- | --- |
| ![呼び出した英語版](results/c2-reuse.jpg) | ![不正解でヒント](results/c3-wrong.jpg) |
| c2 で呼び出した英語版の開始画面（数学版と同じ作り） | 1 問目を間違えたところ |
| ![正解でロック解除](results/c3-right.jpg) | |
| 正解すると 1 つ目のロックが外れる | |

- **作り置きを呼び出すと、7 分の 1 の時間になった。** c2 は `canvas_scenes` → `canvas_load`（英語の 5 問を `values` で渡す）だけで、出力は 1,415 トークン。ゼロから作った c1 は 276 秒・出力 11,577 トークン
- **Sol は使い回すつもりの画面を、状態から描く作りにした。** 題名・教科・問題（問い・選択肢・答え・ヒント・解説）を状態に置き、6,278 文字のスクリプトがそこから描く。`params` は `gameTitle`・`subject`・`questions`。保存したあと、理科の 2 問で試しに呼び出して確かめ、数学に戻した
- c2 では、一度呼び出して `canvas_view` で見たあと、問題の文を短く直してもう一度呼び出した
- 呼び出し（`canvas_load`）は 15〜36 ms。保存したファイルは 22,238 バイト（要素 35、スクリプト 1）。[`scenes/space-station-escape.json`](scenes/space-station-escape.json) に作り置きとして入れた
- 効果音・BGM は、モデルなしで鳴らし・替え・止めて、エラーが出ないことと BGM の状態（曲・音量）を見た。耳で聞いての確かめは、この記録の時点ではしていない

### 失敗した試行

- **呼び出した英語版で、押しても画面が変わらなかった。** Sol のスクリプトは、自分の `sg.set` の後に `sg.on("state")` の描画が走る前提で書かれていた。こちらの実装は、spirit（`canvas_state`）と動作（`set`）からの変更でしか状態のハンドラを呼んでいなかった。
  道具の説明もそこをはっきり書いていなかった。スクリプトの `sg.set` の後も、ハンドラが返ってから状態のハンドラを呼ぶように直した（1 回の流れで 3 回まで）。直した後、同じ `values` で呼び出し、不正解→ヒント、正解→ロック 1/5 まで画面と音が動いた。
  c1 の中で Sol が試した呼び出しは、spirit 側から `canvas_state` で状態を動かして確かめていたので、この不具合に当たらなかった

## Part 4: web 要素（WebView）

オーナーの問い: WebView の中の画像や素材を `asset://` で指定して差し込めるか、中の JS のイベントを外で受けて spirit に届けられるか、途中の状態を spirit が外から取れるか。Windows・Mac・Android・iOS に対応しているか。

### 作り

| | どうしたか |
| --- | --- |
| WebView | `webview_flutter` 4.14（公式。macOS・iOS は WKWebView、Android は Android WebView）。要素の型 `web` に `html`（または https の `url`） |
| `asset://` | アプリの中に、ループバックだけの小さな HTTP サーバーを立てる。ページはそこから配り、HTML の `asset://<名前>` を `http://127.0.0.1:<port>/asset/<名前>` に書き換える。ページが後から足す要素（`src`・`href`・`poster`・`style`・`<style>`・`fetch`・`new Audio`）は、先頭に差し込む小さな JS が書き換える。WebView の独自スキームの仕組みに頼らないので、WebView の種類を選ばない |
| JS → 外 | ページの `sg.emit(name, data, {wake})` が JavaScript channel（`SGHost`）でアプリに届き、`event="web"` のイベントとして spirit へ。`wake` で、すぐ起こすか次にまとめて渡すかをページが決める。`on`・スクリプトの `sg.on("web")` でも受けられる |
| 外から状態 | ページの `sg.setState(obj)` をアプリが持ち、`canvas_view` の `web` に入れる（JS を走らせずに読める）。加えて `canvas_web_eval(id, js)` でページの中の JS を走らせて値を受け取る。`canvas_view` はページの本文（`innerText` の先頭 800 文字）も返す |

### モデルなしの確認

1 つのページ（[`results/web-test-page.json`](results/web-test-page.json) を `/tool?name=canvas_put` に渡した）で:

- **`asset://` の差し込み:** `<img src="asset://…">` は 1254 px で読めた。CSS の `url(asset://…)` は `url("http://127.0.0.1:…/asset/…")` になった。押すたびに JS が `img.src = 'asset://…'` で足した画像も 1536 px で読めた
- **JS → 外:** ページのボタンを 2 回押すと、`sg.emit('pressed', {count}, {wake: false})` が 2 件、次に spirit へ渡す通知として積まれた
- **外から状態:** `canvas_web_eval` で `window.secret()` が「inner 2」を返した。`canvas_view` の `web` に `{"state": {"count": 2}, "text": "…押した回数: 2…"}` が入った
- **ページの中の音:** 最初は `new Audio('asset://…').play()` が `NotSupportedError` で失敗した。WebKit が利用者の操作なしの再生を止める設定を外しても同じだった。原因は配信の側で、WebKit は音声・動画を部分取得（HTTP の Range）で読む。サーバーが 206 で返すようにすると鳴った（`played ok`）

### gpt-6.2-sol に流した結果

w1「web ブロックで、20秒のもぐらたたきゲームを作って。手元の効果音とBGMを使って。途中で様子を見て応援してくれて、終わったら結果について話しかけてね」

| | 時間 (s) | 道具 | 入力 | うちキャッシュ | 出力 |
| --- | ---: | --- | ---: | ---: | ---: |
| 作る（新しい thread） | 308 | 22（うち `canvas_web_eval` 11） | 550,072 | 486,272 | 13,462 |
| 10 秒の時点でページが起こした | 4 | 0 | 29,960 | 29,568 | 117 |
| 終わってページが起こした | 2 | 0 | 30,208 | 29,056 | 45 |

![もぐらたたきの終わり。spirit の字幕は結果への声かけ](results/w1-finished.jpg)

- Sol は 20,130 文字の HTML を 1 つの `web` 要素に書き、`asset://sounds/…` で BGM と効果音を鳴らした。10 秒と 20 秒に `sg.emit(…, {wake: true})` を置き、`sg.setState` で得点などを外に出した
- **Sol は `canvas_web_eval` でページの中に試験用の仕組みを差し込み、10 秒の応援と 20 秒の終わりまで自分で通しの試験をした。** そのうえで、ゲームの秒数を状態に出して `mole-garden` として保存した（[`scenes/mole-garden.json`](scenes/mole-garden.json)）
- 遊んだとき: スタートと、もぐらを叩く操作は、こちらが `canvas_web_eval` でページのボタンを押した（窓が後ろにあるとき、コンピューター操作のクリックが WebView の中に届かなかった）。10 秒の時点で spirit が起きて 4 秒後に「折り返しで16匹、ここまで全部命中！ あと10秒、その調子！」、終わりで 2 秒後に「20秒で32匹！ 出てきた33匹のうち、逃したのはたった1匹。…最後までいいペースだったね！」と言った（32 匹は JS で叩いた数）

### 分かった制約

- **spirit に見せる撮影（`RepaintBoundary`）に WebView は写らない。** プラットフォームのビューなので。代わりに `canvas_view` は本文と `sg.setState` の状態を返す。Sol は `getBoundingClientRect` などを `canvas_web_eval` で読んで配置を確かめていた
- macOS の WebView は透明な背景に対応していない（`setBackgroundColor` が `UnimplementedError: opaque`）。ページが自分の背景を塗る
- **WebView は、キャンバスのほかの要素より常に上に出る。** 縮める枠の外に置いているため（下の不具合の直し）。`opacity`・`scale`・`rotation` も WebView には効かない（位置と大きさのアニメは効く）

### 失敗した試行: WebView の中のボタンが押せなかった

オーナーが試すと、Sol が作ったもぐらたたきの「もう一回」をクリックしても反応しなかった。
最初の版は、WebView もほかの要素と同じく 1280x800 の舞台に置き、舞台ごと `FittedBox` で窓に合わせて縮めていた。
見た目は縮んで描かれるが、WebView のネイティブのビューは縮める前の大きさのままで、クリックは縮める前の位置として届いていた。
窓の (400, 400) のクリックがページの (398, 323) に届いた（見た目どおりなら、およそ (663, 538)）。アクセシビリティの座標も見た目とずれていた。
Sol の自己試験や `canvas_web_eval` での操作は JS からボタンを押していたので、この不具合に当たらなかった。

直し方: WebView だけを舞台の外に出し、窓の上の実際の位置と大きさ（舞台の座標 × 縮みの割合）で置く。ページは同じ割合の CSS `zoom` で縮め、ページの中の CSS の画素は舞台の座標のままにする（ページの URL の `zoom` と `sg.setZoom`）。
直した後、右下 4 分の 1 に置いたページのボタンを見た目の位置でクリックすると、ボタンの上に届いて押された。もぐらたたきのスタートも、画面のクリックで始まった。アクセシビリティの座標も見た目と合った。

### 対応する OS

| OS | WebView | この lab での状態 |
| --- | --- | --- |
| macOS | `webview_flutter`（WKWebView） | 確かめた |
| iOS | 同じ（WKWebView） | 未確認。同じ実装で動く見込み |
| Android | 同じ（Android WebView） | 未確認。自動再生の扱いは別の設定が要る可能性 |
| Windows | `webview_flutter` は非対応。API 互換の `webview_all`（2026-11 の版、WebView2）か、2024 年で止まっている `webview_windows` | 未確認 |

使っているのは、ページの読み込み・JavaScript channel・JS を走らせて結果を受け取る、の 3 つだけ。`asset://` は WebView の独自スキームではなくループバックのサーバーで解くので、Windows でも WebView の差し替えで済む見込み（解釈。動かしていない）。

## 結論が成り立つ範囲と、まだ見ていないこと

- macOS だけ。iOS・Android・Windows では動かしていない。スマートフォンの縦の画面では 1280x800 の固定は小さすぎる
- Claude（Opus）では流していない。各シナリオ 1 回で、ばらつきは見ていない
- 選択肢・ボタンは画面で実際にクリックした（s2、s4）。入力欄の `submit`、`tap`、動画・音声の `ended` は、モデルにつないだ状態では確かめていない（見本で描けることだけ）
- 動画・音声は、手元の素材（labs の `tests/assets`）か https の URL だけ。spirit が新しく画像・音声を作る道具は無い
- 撮影は 960x600（`pixelRatio` 0.75）で spirit に渡している。小さい文字が読めるかは見ていない
- Part 2 は Sol だけ、各 1 回。`on`・タイムライン・状態を spirit が使う場面は観測できていない（道具としてはモデルなしで動く）。指示文を変えた比べもしていない
- スクリプトの安全は lab の範囲（無限ループで固まる）。複数のスクリプトが同じ要素を書き換えるときの順序も決めていない
- Part 3 は c1・c2 の各 1 回。保存するのは、保存した時点の画面と状態そのもの（遊んだ途中の値も入る）。作り置きの版の管理、spirit ごと・家族ごとの置き場所は決めていない

## 次の一手（この lab の結果から）

Part 1 で挙げた「押したときの結果を宣言する」「時間の並び」「spirit が書くスクリプト」「通知の区別」は Part 2、「作り置きの保存・呼び出し・差し替え」と音は Part 3、WebView は Part 4 で作った。残り:

1. **web 要素を他の OS で動かす。** iOS・Android は同じ実装、Windows は `webview_all`（WebView2）への差し替えから。WebView の画面を spirit に見せる撮影（各 WebView のスナップショット）も
2. **端末の実際の大きさに合わせる。** 使える大きさ（縦横・安全領域）を `canvas_view` と `<ui>` で渡し、回転やリサイズは `resize` のイベントで知らせる。割合や寄せの指定で、組み直さずに追従させる
3. **spirit がモードを切り替える道具。** チャットのまま頼まれた絵を、そのまま見せられるように。ユーザーが自分でチャットに戻した直後に戻さないよう、提案を出して押されたら切り替える形などを選ぶ
4. **スクリプトを製品の形で動かす。** 別の isolate かプロセス、実行時間の上限、スクリプトどうしの順序
5. **作り置きの置き場所と共有。** spirit ごと・家族ごと、版、アセット（画像・音）を含めた受け渡し。製品ではアセットノードの `asset://` で参照する形が合いそう（未検討）
6. **音の素材。** 合成の素材は仮。作り置きの BGM・効果音を揃えるか、音楽の生成を道具にする。spirit の声（TTS）と重なったときに BGM を下げる
7. **`notify: "none"` の扱い。** spirit が自分で聞かないことにした操作も、画面を読めば分かった。ただ、聞かれるまで知らない。会話の記憶に残すかどうかを決める
8. 大きな SVG を書く遅さ（出力 8,000〜11,000 トークン）は、作り置きで避けられる場面が多い。ゼロから描く場面のために、画像の生成の道具を足して比べる

## Run

```sh
# 共有の素材、Seed-san（VRM、VirtualCast, Inc.、VRM Public License 1.0）、.vrma を取り、音を合成する
mise -C 2026/11/26/spirit-canvas run assets
# ビルド（clean から）と起動。codex にログインしている必要がある
mise -C 2026/11/26/spirit-canvas run build
CONTROL_PORT=8813 mise -C 2026/11/26/spirit-canvas run run
# 別の端末から: 送る・押す・状態
python3 2026/11/26/spirit-canvas/drive.py s1-intro send "キャンバスで自己紹介して"
python3 2026/11/26/spirit-canvas/drive.py s2 event press <button id>
# 道具を直に呼ぶ（モデルなし）
curl -s -XPOST "localhost:8813/tool?name=canvas_state" --data-binary '{"set":{"n":1}}'
```

環境変数: `MODEL`（既定 `gpt-6.2-sol`）、`EFFORT`、`CONTROL_PORT`（既定 0 = 切る）、`START_MODE`（`canvas` / `chat`）、
`VRM_PATH`・`VRMA_PATH`（既定は `work/assets`）、`ABBREVIATE_VIEW`（既定 `1`。`0` で SVG を全文返す、s1〜s7 の条件）。
画面の右上の「見本」は、モデルを使わずに `demo_scene.dart` を置きます。
作り置きは `scenes/`、spirit が保存した画面は `work/scenes/` に入ります。

`mise -C 2026/11/26/spirit-canvas run`（既定）は解析とキャンバスのモデルのテストだけを行います。

## Dependencies

`app/pubspec.lock` が解決した版。flutter_vrm は commit `6cdf97d`、flutter_scene はその lab と同じ upstream の commit `0e263be`（`dependency_overrides`）。
flutter_svg 2.5、video_player 2.14、audioplayers 6.8、flutter_js 0.8.7（Part 2）、webview_flutter 4.14.1・webview_flutter_wkwebview 3.27.2（Part 4）。
