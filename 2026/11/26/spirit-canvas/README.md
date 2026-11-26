# A canvas mode for a spirit's chat: gpt-6.2-sol lays out text, SVG drawings, a VRM body, photos, video, audio and buttons with tools, and the user's presses come back as messages

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

## 結論が成り立つ範囲と、まだ見ていないこと

- macOS だけ。iOS・Android・Windows では動かしていない。スマートフォンの縦の画面では 1280x800 の固定は小さすぎる
- Claude（Opus）では流していない。各シナリオ 1 回で、ばらつきは見ていない
- 選択肢・ボタンは画面で実際にクリックした（s2、s4）。入力欄の `submit`、`tap`、動画・音声の `ended` は、モデルにつないだ状態では確かめていない（見本で描けることだけ）
- 動画・音声は、手元の素材（labs の `tests/assets`）か https の URL だけ。spirit が新しく画像・音声を作る道具は無い
- 撮影は 960x600（`pixelRatio` 0.75）で spirit に渡している。小さい文字が読めるかは見ていない

## 次の一手（この lab の結果から）

速さと、往復なしの手触りを足す方向です。

1. **押したときの結果を、置くときに一緒に宣言する。** 「このボタンを押したら、この要素をこう変える」をアプリだけで即座に行い、spirit には通知として後から伝える。s5 の切り替えのような UI が往復なしで動く
2. **時間の並び（タイムライン）。** 「3 秒後にこれを出す」「動画が終わったら次へ」
3. **spirit が書く小さなスクリプト（状態・タイマー・計算）をアプリの中で動かす。** 時計・カウントダウン・遊びが往復なしで動く。スクリプトから spirit へ通知でき、spirit からはスクリプトの状態を部分的に書き換えられる。安全に動かす仕組みの選び方が要
4. **通知の区別。** アクション・スクリプトからの通知は「すぐ起こす」「次に話すときにまとめて渡す」を分け、毎秒の処理が spirit を起こし続けないようにする
5. **端末の実際の大きさに合わせる。** 使える大きさ（縦横・安全領域）を `canvas_view` と `<ui>` で渡し、回転やリサイズは `resize` のイベントで知らせる。割合や寄せの指定で、組み直さずに追従させる
6. **spirit がモードを切り替える道具。** チャットのまま頼まれた絵を、そのまま見せられるように。ユーザーが自分でチャットに戻した直後に戻さないよう、提案を出して押されたら切り替える形などを選ぶ
7. 大きな SVG を書く遅さ（出力 8,000〜11,000 トークン）は残る。画像の生成の道具を足して比べる

## Run

```sh
# 共有の素材、Seed-san（VRM、VirtualCast, Inc.、VRM Public License 1.0）、.vrma を取る
mise -C 2026/11/26/spirit-canvas run assets
# ビルド（clean から）と起動。codex にログインしている必要がある
mise -C 2026/11/26/spirit-canvas run build
CONTROL_PORT=8813 mise -C 2026/11/26/spirit-canvas run run
# 別の端末から: 送る・押す・状態
python3 2026/11/26/spirit-canvas/drive.py s1-intro send "キャンバスで自己紹介して"
python3 2026/11/26/spirit-canvas/drive.py s2 event press <button id>
```

環境変数: `MODEL`（既定 `gpt-6.2-sol`）、`EFFORT`、`CONTROL_PORT`（既定 0 = 切る）、`START_MODE`（`canvas` / `chat`）、
`VRM_PATH`・`VRMA_PATH`（既定は `work/assets`）、`ABBREVIATE_VIEW`（既定 `1`。`0` で SVG を全文返す、s1〜s7 の条件）。
画面の右上の「見本」は、モデルを使わずに `demo_scene.dart` を置きます。

`mise -C 2026/11/26/spirit-canvas run`（既定）は解析とキャンバスのモデルのテストだけを行います。

## Dependencies

`app/pubspec.lock` が解決した版。flutter_vrm は commit `6cdf97d`、flutter_scene はその lab と同じ upstream の commit `0e263be`（`dependency_overrides`）。
flutter_svg 2.5、video_player 2.14、audioplayers 6.8。
