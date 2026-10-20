# gpt-live-1-codex の返事を MeanVC2 で流しながら声変換し、鳴らした音でエコー除去する

[前の lab](../flutter-fork-gpt-live-codex-playout/README.md) で作った「受信音 → 加工の口 → アプリが鳴らす → 鳴らした音を AEC の参照」の
加工の口に、[MeanVC2](https://github.com/ASLP-lab/MeanVC2)（zero-shot の声変換）を実際に入れ、macOS と Windows で確かめた（2026-10-20）。
オーナーが「gpt-live-1-codex の受信音の加工に MeanVC2 を使う」と決めたことを受けた検証。

## 結論

- **流しながらの MeanVC2 は CPU 1 スレッドで実時間に間に合う。** 上流の `runtime/run_rt.py` の 160 ms ずつの変換（`120ms` のモデル）で、
  単体の 1 回の処理は Mac（Apple M1 Max）が中央値 29 ms・95% 48 ms（2 ステップ）／37 ms・64 ms（3 ステップ）、
  G-GEAR（Core i9-12900K）が 64 ms・109 ms（2 ステップ）／81 ms・143 ms（3 ステップ）。間に合わない回は 0。
  アプリと同時に動かすと 5〜10% 遅くなり、Windows の 3 ステップは 160 ms まで 16 ms しか余らないので、既定は Mac 3 ステップ・Windows 2 ステップにした。
- **組み込みは Python の常駐プロセス（ループバックの TCP）にした。** 流しながらの変換がそのまま間に合い、ONNX への書き出しは誰も試していないため、一番早く確かめられる形を選んだ。
  加工の口に外へ出すモード（slot 3）を足し、アプリが受信音（48 kHz）を送り、サーバーが 16 kHz → MeanVC2 → 48 kHz で返す。
- **増える遅れは約 +470〜630 ms**（受け取ってから鳴らすまで、素通し 27〜30 ms、VC 500〜660 ms。内訳は変換待ち 380〜480 ms と再生待ち約 180 ms）。
  オーナーは「遅れは気にならない」「割り込める」と評価した。
- **エコー除去の参照は VC の後の鳴らした音でないと効かない。** 偽の peer で、VC の後の参照なら 14〜22 dB、VC の前の参照では 1.4〜2.5 dB しか下がらない（Mac・Windows）。
  実 gpt-live-1-codex（Windows）でも、返事を鳴らす間のエコーの成分は VC の後の参照で約 66 dB 下がった。オーナーの会話でエコーは無かった。
- **最初に聞こえた歪みは、変換後の音が大きすぎて振り切れていたこと**（元の声より約 5 dB 大きく、上限で 43 サンプル）。サーバーで大きさを受信音にそろえ、柔らかく抑えて直した。
- **残る不自然さの大きな原因は、元の声と参照の声の高さの差**だった。gpt-live の既定の声は 121 Hz、オーナーの本番相当の参照は 416 Hz で、MeanVC2 の出力は 233〜257 Hz で頭打ちになった
  （元の声を変換前に 10 半音上げても変わらない）。gpt-live の声を高い `himari`（276 Hz）にすると出力は 284 Hz で元の抑揚が残り、オーナーは「かなりよくなったかも」と評価した。
- 同じ中身なら、アプリが実際に鳴らした音と、後から同じ方法で変換した音は、オーナーに同じに聞こえた。アプリの鳴らし方は質を落としていない。
  質はオーナーの評価で「流し方 2 ステップ < 3 ステップ < ファイル丸ごと」。帯域を補う・6 ステップ・`40ms` のモデルは 3 ステップを超えなかった。

## 作り

```text
受信トラック ─ sink ─ 加工の口（slot 3: 外へ）─ pullExternal ─ TCP ─ VC サーバー（16k↓・MeanVC2 160 ms・大きさ合わせ・16k↑）
                                                                        │
アプリのスピーカー ← 再生の待ち行列 ← pushExternal ←──────────────────────┘
        └─ 鳴らした音 ─ AEC3 の参照（比較用に、同じ量の VC の前の音を並べた参照の AEC3 も回す）
```

- `vc/stream_vc.py`: 上流 `runtime/run_rt.py` の `VCRunner.process_chunk` をそのまま使う。変えたのは 2 点。
  話者の埋め込みをファイルの変換の lab と同じ encoder（`preprocess/models/ecapa_tdnn.py` + `wavlm_large.pt`）で作る
  （上流の runtime の読み込みは公開されていない `wavlm_large_cfg.pt` を要る）。ODE のステップ数を引数にした（上流は 2 で固定）。
- `vc/server.py`: 枠（1 バイトの種類 + 4 バイトの長さ）で、`P` 受信音／変換音、`T` 変換先の声の差し替え（音声ファイルか共有の素材の話者）、`Q` 統計、`R` リセット。
  大きさは、受信音が声のとき（-45 dBFS より上）だけ、約 1.6 秒の平均で合わせ、0.7 から上は柔らかく抑えて 0.9 で止める。
- `native/playout_pipeline.*`: slot 3 で受信音を外へ出す待ち行列と、戻った音を再生へ入れる口（`pipeline_external_pull`・`pipeline_external_push`）。
  比較用の参照は、戻った量と同じだけ VC の前の音を並べる。
- `app/lib/vc_client.dart`: 20 ms ごとに取り出して送り、戻りを push する。画面で変換先の声（共有の素材の話者 1・2、またはファイル）を選べる。
- `tools/live_server.py`: 前の lab と同じ制御に、gpt-live の声を選ぶ `--voice=<名前>` を足した（`thread/realtime/start` の `voice`。一覧は `thread/realtime/listVoices`）。

## 確かめ方と結果

| 段 | 結果 | 記録 |
|---|---|---|
| 流しながらの処理時間（単体） | 上の結論の数値。最初の出力まで約 350 ms（Mac）・約 380 ms（G-GEAR） | [Mac](results/vc-bench-mac.json)・[Mac 3 ステップ](results/vc-bench-mac-steps3.json)・[Win](results/vc-bench-win.json)・[Win 3 ステップ](results/vc-bench-win-steps3.json) |
| 偽の peer（Mac、2 ステップ） | VC の後の参照 14.4〜21.5 dB / VC の前 1.4〜2.4 dB。近端だけ -0.4 dB（相関 0.98）、同時に話す -2.9 dB（0.88） | [mac-vc-fake-1](results/mac-vc-fake-1.json) |
| 偽の peer（Windows、2 ステップ） | VC の後 20.0〜22.0 dB / VC の前 1.6〜2.5 dB。DualSense の雑音（-23 dBFS）で近端は測れず | [win-vc-fake-1](results/win-vc-fake-1.json) |
| 実 gpt-live-1-codex（Windows、自動） | 3 問とも正しく文字にされ各 1 往復。エコーの成分 -81〜-83 dBFS（マイク -15） | [win-vc-live-1](results/win-vc-live-1.json) |
| オーナーの会話（Mac、本番相当の参照、3 ステップ） | 歪みは改善、割り込める、遅れは気にならない、エコーなし。自然さが課題 | [mac-vc-human-3](results/mac-vc-human-3.json) |
| オーナーの会話（Mac、gpt-live の声 `himari`） | 「かなりよくなったかも」。出力の高さ 284 Hz | [mac-vc-himari-2](results/mac-vc-himari-2.json) |
| 遅れ | 上の結論 | [latency](results/latency.json) |
| 質の切り分け | 歪みの原因、聞き比べの順位、高さ | [quality](results/quality.json) |

本番相当の参照の声と、聞き比べに作った音声はオーナーの手元の素材を含むので、Git に入れない（`build/`）。参照の声の名前も記録しない。

## 失敗と気づいたこと

- **既定の入力が Bluetooth（Pixel Buds Pro）のとき、内蔵マイクを名指しして `record` を始めると、エラーなしで 0 サンプルのまま**だった（オーナーが話しても反応しない）。
  入力を内蔵にしてから起動し直すと取れた。イヤホンをつなぎ直すと macOS が既定の入力を Bluetooth に戻す。既定の入出力が両方 Bluetooth のときは `record` の開始が -10868 で失敗した（前の lab と同じ）。
  大きさの合わせ方を直した後の偽の peer の回（`mac-vc-fake-2`）はこれでマイクが 0 だったので、大きさの合わせの確認にだけ使った（倍率 0.44〜0.60 で、下限 0.25 に張り付かない）。
- 大きさの合わせを最初は常に動かしていたので、返事の合間の変換の雑音で倍率が下限 0.25 に張り付き、次の返事の頭が小さくなりうる状態だった。受信音が声のときだけ動かすように直した。
- 変換後の音は入力より約 1% 短く、再生の待ち行列がときどき空になる（366 秒で 5 回、声の途中の無音は 1 回）。主な不自然さの原因ではなかった（A/B で同じに聞こえた）。
- 再生の待ち行列には、VC の戻りが 160 ms ずつ届くので約 180 ms がたまる。遅れを詰めるならここを小さくできる。

## 成り立つ範囲と残り

- オーナー 1 人の聴取、Mac の内蔵スピーカー・Pixel Buds Pro、Windows の EDIFIER。Windows ではオーナーが VC を聞いていない（開始した回は素通しのまま）。
- MeanVC2 は 16 kHz で出すので 8 kHz より上が無い。帯域を補う試しは効かなかった。
- 参照の声が高すぎると（416 Hz）MeanVC2 が届かない。製品では、gpt-live の声を参照に近い高さのもの（`himari` など）にするか、届く高さの参照を使う。
  `himari` 以外の声、Windows での `himari`、長時間・再接続は試していない。
- 製品に入れるなら、受信 PCM の正式な口（fork か bridge）、VC のプロセスの寿命と失敗時の素通しへの切り替え、配布（torch とモデル 3 GB）を決める必要がある。

## 動かし方

```sh
mise run                       # 機器なしの試験（前の lab と同じ）
(cd vc && uv sync && uv run python bench.py --threads 1 --steps 3)   # 流しながらの処理時間
(cd vc && uv run python server.py --port 18810 --steps 3 --target asset:speaker2)
mise run build-macos
mise run launch-macos LAB_PEER=http://127.0.0.1:18799 LAB_SESSION=mac-vc-fake LAB_OUT_DIR=$PWD/build/trials
```

`vc/` は初回に MeanVC2 のコードとモデル（約 3 GB）を `vc/vendor/` に取る（`meanvc2_runtime.py` の `ensure_assets`、ハッシュで確かめる）。
本物は前の lab と同じく `npm install --prefix work/cli @openai/codex@0.163.0` の後、`tools/live_server.py <アドレス> --voice=himari`。
Windows は `tools/windows/build.cmd` と `tools/windows/launch.ps1 -Vc`（VC のサーバーを起動してからアプリを対話タスクで起動し、終わったら止める）。
聞き比べは `vc/ab.py`（`--extras` で帯域・6 ステップ・`40ms`）と `vc/live_vs_offline.py`。

前提: [受信音の加工の口](../flutter-fork-gpt-live-codex-playout/README.md)、[MeanVC2 のファイルの変換](../meanvc2-japanese-os-tts/README.md)、
[初代 MeanVC の流しながらの変換](../../../07/19/meanvc-streaming-apple-silicon/README.md)。MeanVC2 のコードとモデルは Apache-2.0（[THIRD_PARTY.md](THIRD_PARTY.md)）。有料の API は呼んでいない。
