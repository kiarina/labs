# gpt-live-1-codex を外部メディアの fork でつなぎ、受信音に加工の口を挟んでエコー除去する

`record` と `camera` で取り続けたマイクとカメラを、外部入力の fork 版 flutter_webrtc と接続ライブラリ
（`flutter_webrtc_external_media` 0.1.0-dev.2）から ChatGPT ログインの gpt-live-1-codex へ送る。
受け取った声は **加工の口（将来の声の変換＝VC の場所。今は VC を入れない）** を通してからアプリ自身が鳴らし、
**実際に鳴らした音（加工後）をエコー除去の参照にする。** macOS と Windows で確かめた（2026-10-20）。

## 結論

- **fork・bridge dev.2 のまま gpt-live-1-codex（CLI 0.163.0、v3 / audio / WebRTC、wham）につながった。**
  Mac の自動 5 回は、1 回が WebRTC の接続に至らず、1 回は中継の不具合でイベントを取れず（音声の往復は動いた）、
  1 回は質問が小さすぎて文字にされなかった。直した後の 2 回と Windows の自動 1 回で、合成音声の 3 つの質問すべてに返事が返った。
  Mac ではオーナーが内蔵スピーカーで 2 分半話し、声に毎回反応し、割り込めて、音は「実用上は問題なさそう」だった。
- **fork には、受信音を鳴らす前に加工する口が無い。** fork を変えずに、受信トラックに sink をつないで
  ミキサーの音量の前の PCM を取り出し（Mac は `RTCAudioTrack addRenderer:`、Windows は `AddSink`）、
  受信トラックの音量を 0 にして native の再生を無音にし、加工後の音をアプリが同じスピーカーに鳴らす形で作れた。
  native の再生は止めずに無音で回し続ける（その引き取りで受信音の復号が進む）。
- **参照は加工後の音でないと効かない。** ピッチを変える代わりの加工で、加工前の音を参照にすると
  エコーはほとんど下がらない（下の表）。**200 ms 遅らせるだけの加工では区別できない**（エコー除去の遅れの推定が吸収する）。
  VC は声の中身を変えるので、ピッチ変更の側と同じく、加工後の参照が要る。
- マイクが聞いているのは加工後の音だった。遅延のモードで、マイクの音は鳴らした音とは Mac 74〜84 ms・Windows 187 ms で、
  加工前の音とはちょうど 200 ms 遅れて一致した。
- 送信を止めた 3 秒の間も `record` とカメラは取り続け（Mac 144000 サンプル・71 コマ、Windows 144480 サンプル・91 コマ）、
  相手が受け取った音は 0 だった。

| 加工 | Mac: 加工後の参照 / 加工前の参照 | Windows: 加工後 / 加工前 |
|---|---|---|
| 機器なし（`mise run`、80 ms・0.5 倍のエコーを合成） | 素通し 59.7 / 59.7 dB、遅延 59.9 / 59.8、ピッチ 58.4 / **0.8** | 同左（機器なし） |
| 偽の peer・遠端だけ（エネルギーの減り） | 素通し 23.2 / 23.2、遅延 23.0 / 22.9、ピッチ 19.1〜22.7 / **0.6〜2.0** | 素通し 11.6 / 11.6、遅延 12.3 / 8.5、ピッチ 10.3〜14.7 / **0.5〜1.8** |
| gpt-live-1-codex・返事を鳴らしている間のエコーの成分（マイク → 送った音） | 素通し -43〜-44 → -88〜-98 dBFS、ピッチ -43〜-46 → -85 / **-47〜-61** | 素通し -24 → -66、ピッチ -27〜-28 → -73〜-85 / **-38〜-41** |
| オーナーとの会話 | 素通し -41〜-45 → -95〜-109、ピッチ -41〜-47 → -86〜-92 / **-42〜-58** | 素通し -17〜-26 → -55〜-111、ピッチ -21 → -75〜-81 / **-24〜-39** |

Windows の偽の peer の減りが小さいのは、DualSense のマイクの雑音が無音でも -22 dBFS あり、エコーが雑音の 4〜7 dB 上にしか出ないから（測れる幅の上限）。

## 確かめたかったこと

1. fork 4477798 と bridge dev.2 9f5e2da のまま、gpt-live-1-codex（ChatGPT ログインの WebRTC）につながるか
2. 受け取った PCM を、加工の口 → アプリが鳴らす → 鳴らした音を参照、の順にできるか（VC は後から入れる）
3. 加工した後でもエコー除去が効くか。参照が加工後につながっていることを、加工を変えて示せるか
4. gpt-live が自分の声のエコーに反応しないか、割り込めるか、送信を止めている間も取得が続くか、止めた後に片付くか

評価: 加工は素通し・200 ms 遅延・ピッチ 1.12 倍（約 2 半音上げ。窓 40 ms の 2 タップ）。エコー除去を 2 系統並べ、
加工後の音（鳴らした音）と、加工前の音（同じ時刻に揃えたもの）をそれぞれの参照にして比べる。
偽の peer は Python の aiortc で、遠端の声（共有素材 `conversation_2speaker_14s_16k.mp3`、ピーク 18000）を送り、こちらの送った音を記録する。
本物は、合成音声（macOS の `say` Kyoko）の質問を 1 回の接続で 3 つ入れる（q1 素通し・加工後の参照、q2 ピッチ・加工後、q3 ピッチ・加工前）。

## 作り

```text
record（48 kHz mono）──┬──────────────── 解析など（取り続ける）
                        └─ AEC3（参照＝鳴らした音）─ 送信の口 ─ bridge dev.2 ─ fork ─ WebRTC ─ gpt-live-1-codex
                           AEC3（参照＝加工前の音、比較用）
gpt-live の声 ─ 受信トラック ─ sink（音量の前）─ 加工の口 ─ 再生の待ち行列 ─ アプリのスピーカー ─┐
              └ native の再生（音量 0。復号を進めるために回し続ける）                          │
                                                            鳴らした音 ─ AEC3 の参照 ←─────────┘
camera ─ 160px・8fps ─ 送信の口（偽の peer だけ。gpt-live には音だけ送る）
```

- `native/playout_slot.*`: 加工の口。480 サンプル（10 ms）ずつの同期処理で、遅れを `slot_latency_samples` で返す。
  VC はこの約束の後ろに置く（非同期の変換でも、遅れを返して待ち行列で吸収する）。
- `native/playout_pipeline.*`: 受信（任意の rate・ch を 48 kHz mono に）→ 加工 → 再生の待ち行列（40 ms 溜めてから鳴らす、上限 1 秒）
  → 鳴らした音を参照に。エコー除去 2 系統と、マイクと再生の時刻の対応表（`clock_map`）、記録（各 5 分まで）を持つ。機器は持たない。
- `playout_audio/`: lab の plugin。macOS は `AVAudioEngine`（出力だけ）、Windows は共有モードの WASAPI（イベント駆動、`AUTOCONVERTPCM` で 48 kHz を端末の 96 kHz へ）。
  受信トラックは flutter_webrtc の内部（Mac `remoteTrackForId:`、Windows は `peerconnections_` の receivers）から探す。
- `app/`: `record`・`camera` を取り続け、送信の口・加工・送る参照を切り替える。`LAB_PEER`（偽の peer）、`LAB_LIVE`（本物）、`LAB_HUMAN=1`（人の会話）。
- `tools/live_server.py`: 本物の制御。`codex app-server` に `thread/realtime/start`（v3・audio・webrtc、call base は wham）を出し、
  アプリの SDP offer を渡して answer を返す。サイドバンドの WebSocket を中継してイベントの種類と文字起こしをアプリへ送る。
  Thinker は無く、委譲には決まった短い文を返す。`OPENAI_API_KEY` は外す。

## 動かし方

```sh
mise run                     # 機器なしの試験（results/digital-probe.json と同じ値になる）
mise run build-macos         # 素材の準備・AEC3 の用意・macOS の debug ビルドと署名し直し
python3 -m venv build/venv && build/venv/bin/pip install -r requirements-peer.txt -r requirements-analysis.txt -r requirements-live.txt
build/venv/bin/python tools/peer.py --speech app/assets/far_speech.pcm --output build/peer --port 18799 --far-gain 2
mise run launch-macos LAB_PEER=http://127.0.0.1:18799 LAB_SESSION=mac-fake-7 LAB_OUT_DIR=$PWD/build/trials
build/venv/bin/python tools/analyze.py build/trials/gpt_live_playout_mac-fake-7 out.json --peer build/peer/mac-fake-7-received.pcm
```

本物は `npm install --prefix work/cli @openai/codex@0.163.0` の後、`tools/live_server.py [待ち受けのアドレス]` を起動し、
`work/live-control.json` の URL を `LAB_LIVE` に渡す（ChatGPT ログイン済みの `~/.codex` を使う）。解析は `tools/analyze_live.py`、人の会話は `tools/analyze_human.py`。

Windows は `tools/windows/build.cmd`（短いパスの専用の `PUB_CACHE`）でビルドし、`tools/windows/launch.ps1 -Session <名前> -Env "LAB_PEER=...;LAB_SPEAKER_MATCH=EDIFIER;LAB_MIC_MATCH=DualSense"` で
デスクトップのセッションに起動する（ssh は session 0 なので対話タスクにする）。`AEC_RECORD_RAW=1` で `record_windows` の RAW の入力を使う。
偽の peer と制御サーバーは Mac で動かし、Windows からは VPN のアドレスで届かせた（本物の音声は Windows と OpenAI の間を直接流れる）。

## 環境

- macOS: Apple Silicon のノート（MacBook Pro M1 Max）、内蔵マイク・内蔵スピーカー（音量 50%）、FaceTime HD カメラ、macOS 27.0
- Windows: Core i9-12900K のデスクトップ、Windows 11（10.0.26220）、DualSense のマイク、EDIFIER M60（端末 96 kHz・2ch）、
  Pixel Fold の Windows 仮想カメラ
- 依存は [results/pins.json](results/pins.json)（Mac と Windows の `pubspec.lock` は同一）

## 結果

### 偽の peer（[Mac](results/mac-fake-7.json)、[Windows](results/win-fake-1.json)）

- 受信と再生は実時間どおり（Mac 再生 3146752 / 受信 3147360 サンプル、Windows 3137442 / 3137280）。途切れ・あふれ 0。
- Mac の native の再生（fork の出力だけの装置）の参照は全区間 0（無音）。Windows は native の出力を直接は測っていない。
  遅延のモードで、マイクが加工前の音と短い遅れで一致しないことから、native の再生が聞こえていないと判断した。
- 近端の声（既知の音声を取得に足した）: Mac は近端だけ -0.5 dB（相関 1.0）、同時に話す区間で加工後の参照 -2.9 dB（相関 0.90）。
  Windows は近端の声がマイクの雑音より小さく（近端だけの区間が無音より 1.8 dB 下）、測れていない。同時に話す区間は -7.5 dB（相関 0.2）で、近端を落としている可能性がある。
- 相手が受け取った音: 送信中は Mac -46〜-52 dBFS（遠端だけ）、Windows -27.5〜-30.5 dBFS。送信を止めた区間は 0 サンプル。

### gpt-live-1-codex（自動。[Mac 4](results/mac-live-4.json)、[Mac 5](results/mac-live-5.json)、[Windows 1](results/win-live-1.json)）

- 1 回の接続で 3 つの質問。Mac 4・5 と Windows 1 は全部に返事が返った。Windows 1 は 3 問とも正しく文字にされ、各 1 往復だった。
- 返事を鳴らしている間のエコーの成分（鳴らした音への最小二乗の射影）は上の表。加工後の参照なら 39〜58 dB 下がり、
  ピッチ＋加工前の参照（比較）では 4〜17 dB しか下がらない。音響の遅れは回ごとに探した（Mac 95・97 ms、Windows 192 ms）。
- **Mac の部屋は静かではなかった**（別の作業の合成音声などが鳴っていた）。質問が崩れて文字にされ（「日本の四季」→「二本の式」）、
  入れていない文も認識された。その文は結果に載せず、文字数だけ残した。このため、Mac の自動の回では
  「gpt-live が自分の声のエコーに反応したか」を判定していない。Windows 1 は加工前の参照（q3）でも余計な発話は 0 だった（1 回だけの観測）。

### オーナーとの会話（Mac。[結果](results/mac-human-1.json)）

- 内蔵スピーカーで 154 秒、ユーザーの発話 9 回に返事 9 回。途中で素通し → ピッチ → 加工前の参照に切り替えた。
- オーナーの評価: 声には常に反応した、割り込めた、音は実用上は問題なさそう。
- 加工前の参照に切り替えた後、返事が 0.13 秒で終わった場面が 1 回ある。オーナーの声が重なったのか、エコーなのかは記録から区別できない。
- 文字起こしは保存していない。

### Windows のオーナーとの会話（[2 回目](results/win-human-2.json)、[3 回目](results/win-human-3.json)）

- 1 回目は開始されないまま閉じた（つないでいない）。2 回目は EDIFIER のスピーカーで 154 秒・返事 9 回、3 回目は 59 秒・返事 6 回。
  受信と再生は実時間どおりで途切れ 0（2 回目 再生 7189602 / 受信 7188960 サンプル）。
- オーナーの評価: 2 回目は「問題なく動いてた」。ただし **「参照: 加工前」にしてから素通しに戻した後、あなたの声が文字起こしされなくなった**。
  記録では 104.2 秒を最後に gpt-live からイベントが 1 つも来ず、最後のユーザーの発話が終わらないまま 154.8 秒で終了した。
  その間もアプリは送り続けていた（bridge は送信中・故障なし・落とした分 0、送った音は加工前・加工後の出力ともマイクとほぼ同じ大きさの声）。
  3 回目は同じ順で参照と加工を切り替えたが止まらなかった（オーナーも確認）。原因は分かっていない。gpt-live 側の止まり方の可能性が高いと見るが、1 回の再現失敗では言い切れない。
- 返事の間のエコーの成分: マイク -17〜-29 dBFS に対し、加工後の参照で -55〜-111 dBFS、ピッチ＋加工前の参照で -24〜-39 dBFS（2 回目の素通しの 1 回は -33 dBFS で、
  オーナーの声と重なった区間と見られる）。
- DualSense の入力は、オーナーの声が大きいときに上限（32767）まで振り切れていた。

## 失敗と直したこと

- **再生が割れた（最初の Mac の 3 回）。** pipeline が、エコー除去の処理（100 ms ずつ 2 系統）の間ロックを持ち、
  スピーカーの render と受信の sink（どちらも音声のリアルタイムのスレッド）がそれを待っていた。受信も再生も実時間の 0.71 倍に落ち、
  オーナーが割れを聞いた。エコーは 1〜4 dB しか下がらなかった（[記録](results/mac-fake-2-lock-contention.json)）。
  音声のスレッドは短いコピーのロックだけにし、エコー除去は取得の側でだけ回すように直した。直した後、割れはオーナーの耳でも消えた。
- macOS の sandbox の中に書いた結果を外から読めなかったので、この lab の debug 版だけ sandbox を外した。
  ターミナルから直接起動するとカメラの許可が親のプロセスの分になったので、開発用の証明書で署名し直して `open` で起動した。
- 本物の 1 回目は、中継の `emit()` の引数名とイベントの欄名 `kind` がぶつかって、イベントを 1 つも受け取れなかった（音声の往復は動いていた）。
  2 回目は WebRTC が 10 秒以内に connected にならずに終わった（原因は追っていない）。
- 質問を半分の大きさ（-31 dBFS）にした回は、質問が文字にされなかった。元の大きさに戻すと文字にされた。
- 次の質問へ進む判定が早すぎて、前の返事を鳴らしている途中に質問を入れた回があった。返事が開いている間は待つように直した。
- Windows: 共有の pub cache だと依存の一覧が欠けた。lab の中に置いた `PUB_CACHE` はパスが長すぎて fork の checkout が失敗した。
  短いパス（`%USERPROFILE%\work\gpc`）で通った。

## 成り立つ範囲と残り

- 各 OS 1 組の機器、短い試行。長時間・機器の抜き差し・Bluetooth・別のマイク・別の部屋は試していない。
- 新しい peer での再接続はしていない（1 回の接続で終わる）。
- Windows の同時に話す区間で近端が落ちる件（-7.5 dB）と、Windows の 2 回目で gpt-live が音を処理しなくなった件（再現しなかった）が残る。
- 「自分の声のエコーへの反応」は、静かな部屋で、加工前の参照（比較）を使った回でまだ判定できていない。
- 加工の口は同期の 10 ms ブロック。実際の VC（例: MeanVC2）は非同期で遅れが大きいので、遅れを返して待ち行列で吸収する形にする必要がある。
  その遅れの分、返事が遅れて聞こえる。
- 受信トラックを探すのに flutter_webrtc の内部（Windows は `peerconnections_` へのアクセス）を使っている。製品では fork か bridge に正式な口を作るほうがよい。

前提の lab: [外部メディアの fork とエコー除去](../flutter-fork-external-media-aec/README.md)、
[Mac の同時に話す区間の欠け](../flutter-macos-doubletalk-dropout/README.md)、
[Codex app-server の音声](../../19/codex-app-server-audio/README.md)（ChatGPT ログインの WebRTC の成功条件、DEMO.md）、
[外部入力](../../19/flutter-webrtc-external-capture/README.md)。第三者のソースは [THIRD_PARTY.md](THIRD_PARTY.md)。有料の API は呼んでいない（ChatGPT のサブスクの枠を使う）。
