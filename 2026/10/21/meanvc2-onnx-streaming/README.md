# MeanVC2 を ONNX にして、流しながらの変換を Flutter の 4 プラットフォームで動かす

[MeanVC2](https://github.com/ASLP-lab/MeanVC2)（zero-shot の声変換、Apache-2.0）の流しながらの変換（上流 `runtime/run_rt.py`、`120ms` のモデル）を
ONNX に書き出し、上流の PyTorch と同じ値になるか、Flutter のアプリの中の ONNX Runtime で 160 ms ずつ実時間に間に合うかを、
Mac・Windows・Android（Pixel 6）・iOS（iPad Air 4）で確かめた（2026-10-21）。

前の lab [gpt-live-1-codex の受信音への組み込み](../../20/flutter-gpt-live-codex-meanvc2-playout/README.md) は、MeanVC2 を Python の常駐プロセス（PyTorch）で流した。
アプリ（body）の中で、別プロセスと Python なしに動かせるか、将来の末端になるモバイルで間に合うかが、この lab の問い。

## 結論

- **5 つの部品すべてを ONNX に書き出せた。** 上流の流しながらの変換を部品の呼び出しごとに分け、流す状態（ASR の注意と畳み込みのキャッシュ、DiT の層ごとの KV キャッシュ）を入出力にした。
  書き出せなかった部品は無い。そのままでは書き出せなかった箇所（下の「書き出し」）は、同じ計算を書き直して通した。
- **fp32 の ONNX は上流の PyTorch と聞いて区別できないはずの差に収まる。** 同じ入力・同じ乱数で、波形の SNR 38〜67 dB、スペクトルの差（LSD）0.01〜0.06 dB。
  上流そのものを別の乱数で動かした差（LSD 約 13 dB）より 2 桁以上小さい。70 秒の入力で、DiT の位置が 4000 で巻き戻る上流の処理も通り、差は広がらなかった。
  **アプリ（Dart・flutter_onnxruntime）の中でも同じ**で、4 プラットフォームとも Python の ONNX Runtime と 60.6 dB、上流の PyTorch と 63.3〜63.4 dB・LSD 0.02 dB。
- **int8（重みの動的量子化）は速いが、上流との差が fp32 よりはっきり大きい**（LSD 5.5〜5.9 dB。別の乱数の 13 dB よりは小さい）。DiT・Vocos・ASR のどれを int8 にしても差が出る。
  **オーナーが聞き比べて「int8 でも違いはほとんどわからなかった」**（2026-10-21、下の Web UI）。数字の差は聞いて分かる差になっていない。
- **実時間に間に合う。** 160 ms ずつの処理の中央値（3 ステップ、アプリの中、いちばん速いスレッド数）:

  | 端末 | fp32 | int8 | 間に合わない回 |
  |---|---:|---:|---|
  | Mac（Apple M1 Max） | 19 ms（2 スレッド） | 14 ms | 0 |
  | Windows（Core i9-12900K） | 25 ms（2 スレッド） | 15 ms | 0 |
  | iPad Air 4（A14、iPhone 12 と同じチップ） | 29 ms（1 スレッド） | 18 ms | 0 |
  | Pixel 6（Tensor G1） | 69 ms（2 スレッド） | 54 ms | 0（2 スレッドのとき） |

  上流の PyTorch（Mac、Python、1 スレッド）は 38 ms、同じ Mac の Python の ONNX Runtime は 21 ms（fp32）・11 ms（int8）。ONNX は PyTorch の約 1.8 倍速い。
- **Pixel 6 は 5 分続けても追いついたが、余裕は少ない。** fp32・2 スレッド・3 ステップを 160 ms ごとに 300 秒流し、変換した音は 299.9 秒ぶん出た（遅れて始まった回 0）。
  1 回の処理の平均は 100〜110 ms（実時間の約 0.65 倍）で、10 秒ごとに 0〜7 回が 160 ms を超えた。熱の状態は 3 分ほどで「軽度」（`THERMAL_STATUS_LIGHT`）、電池の温度 32.6 → 35.9 °C。
  Pixel 6 は 1 スレッド・4 スレッドだと 3 ステップで間に合わない回が多い（34〜48 回 / 147 回）。**スレッド数は端末ごとに決める必要がある。**
- **既定は int8 にする**（下の「既定と製品への申し送り」）。聞いて差がほとんど分からず、通話中のモデルが 56 MB（fp32 は 167 MB）、
  Pixel 6 の 5 分では平均 92 ms・最大 188 ms・160 ms を超えた回 2.4%（fp32 は 103 ms・220 ms・6.4%）で、熱の状態も上がらなかった。
- **メモリ**: モデルは fp32 で 184 MB（ファイル）、int8 で 74 MB。アプリの RSS は、起動直後（モデルなし）が iPad 56・Windows 117・Mac 122・Pixel 177 MB、
  fp32 を読んで変換している間が iPad 約 305・Windows 350〜370・Mac 約 455・Pixel 450〜500 MB、int8 が iPad 約 220・Windows 約 270・Mac 370〜450・Pixel 380〜410 MB
  （同じプロセスで前の設定のセッションを閉じた後の値なので、解放しきれなかった分を含みうる）。
  上流の PyTorch の Python は WavLM を含めて 3.2 GB、ONNX の Python は 0.44 GB。
- 話し始めまでの遅れ（入力を溜める時間 + 処理）は、どの端末も 330〜400 ms（上流と同じ。最初の出力は入力 320 ms ぶんを溜めてから出る）。

## 書き出し

`py/export_onnx.py`。torch 2.5.1 の TorchScript 経由の書き出し（opset 17）。

| グラフ | 入力 → 出力 | 大きさ（fp32 / int8） |
|---|---|---:|
| `fbank` | 400 サンプルの枠 [N, 400] → log-mel [N, 80]（kaldi の fbank と同じ設定） | 0.9 MB |
| `asr` | Fast-U2++ 160 ms: 19 枠と offset・注意 [6,4,8,128]・畳み込み [6,1,256,8] のキャッシュ → BN [1,4,256] と新しいキャッシュ | 75.8 / 28.7 MB |
| `gtm` | 話者の埋め込み [1,256] → 音色の記憶 k・v [1,32,256]（参照ごとに 1 回） | 17.4 MB |
| `dit` | DiT 1 回の評価: x [1,16,80]・t・r・BN・話者・記憶・offset と 4 層の KV キャッシュ（長さ 0〜36）→ u と新しいキャッシュ | 53.6 / 13.8 MB |
| `vocos` | mel [1,80,T] → 波形 [1,160(T-1)] | 36.5 / 13.0 MB |

ASR の重みの元のファイルは 235 MB（5,700 万）だが、流しながらの変換が使うのは埋め込みと 12 層のうち 6 層だけで（BN は 6 層目から取る）、デコーダと CTC は使わない。書き出すと 1,760 万になる。
通話中に要るのは `fbank`・`asr`・`dit`・`vocos` の 167 MB（int8 で 56 MB）。`gtm` は参照を登録したときだけ使うので、brain のマシンで k・v（64 KB）まで作って配ってもよい。

キャッシュ・ASR の窓・BN の補間・ODE のステップ・Vocos のつなぎ（クロスフェード）は、上流のまま、呼び出す側（`py/onnx_stream.py`、Dart は `app/lib/meanvc2.dart`）に置いた。

そのままでは書き出せなかった箇所と、どう通したか:

- **Fast-U2++ と Vocos は TorchScript のファイルで配られている。** ASR はそのまま `torch.onnx.export` に渡せた。Vocos は、TorchScript の部品を trace の中から呼ぶと
  「active trace に属さない」で止まり、backbone だけを書き出すと Optional の引数で内部エラー（`input_values:80 vs param_count_list:79`）。同じ重みを読む eager の ConvNeXt を書いて通した
- **Vocos の ISTFT**（`irfft` と `fold`）は ONNX に対応が無いので、逆 DFT の行列積と、単位行列を重みにした転置畳み込み（重ね合わせ）に書き直した
- **fbank** の `rfft` も同じく DFT の行列積に書き直した（kaldi の窓・プリエンファシス・mel の重みはそのまま）
- **DiT** は、上流が offset を Python の int で渡し（trace で固定される）、KV キャッシュの長さを `if` で切っている（同じく固定される）。offset をテンソルの入力にし、
  `[-max:]` の切り出し（短ければそのまま）に置き換えた。`F.rms_norm` は opset 17 に無いので式で書いた。最初の chunk は長さ 0 のキャッシュで呼ぶ（ORT は Python・アプリとも受け付けた）

### 話者の encoder（参照の声の登録）

`py/export_speaker.py`。WavLM-Large + ECAPA-TDNN（上流の `preprocess/models/ecapa_tdnn.py`、`wavlm_large_finetune.pth`）を、波形 [1, T] → 埋め込み [1, 256] の 1 つのグラフにした。
s3prl の包み（波形の list・`pad_sequence`・Python の長さ）は trace が追えないので、1 本の波形について同じ隠れ状態（24 層それぞれの入力と最後の出力）と重み付けを書き直した。
波形の正規化の `F.layer_norm(wav, wav.shape)` も、長さが変わると書き出せないので式で書いた。

| | 大きさ | 上流とのコサイン（3〜20 s の参照） | 7.6 s の参照の時間（Mac、Python、4 スレッド） |
|---|---:|---|---:|
| fp32 | 1.30 GB | 1.0000 | 1.0 s |
| int8 | 387 MB | 0.9993〜0.9997 | 0.52 s |

int8 の埋め込みで変換した音は、fp32 の埋め込みのときと LSD 5.7 dB 違う（`results/speaker-int8-effect.json`。ほかの int8 と同じ大きさ。聞いてはいない）。
**この重みは microsoft/UniSpeech の CC BY-SA 3.0**（MeanVC2 の Apache-2.0 ではない）。配るときはライセンスを分ける。
書き出しの道具と Dart の package は、このあと `kiarina/meanvc2_onnx`（公開の準備中）が持つ。この lab とは同期しない。

## 一致

部品ごと（`results/export-check.json`、同じ入力を上流の部品と ONNX に入れる）の最大の差は、fbank 6e-5（値の幅 26）、ASR 1.2e-5、DiT 3.8e-6、Vocos 3.3e-5。
流しながら通したとき（`results/parity.json`、上流の PyTorch と ONNX Runtime 1.31・Python、1 スレッド、同じ乱数）:

| 入力 | steps | fp32: BN / mel / 波形 SNR（dB） | fp32 LSD | int8: mel / 波形 SNR | int8 LSD | 別の乱数の上流: 波形 SNR / LSD |
|---|---:|---|---:|---|---:|---|
| 共有の素材の話者 1（6.6 s） | 2 | 80.7 / 82.4 / 42.1 | 0.06 | 25.3 / 2.9 | 5.64 | -2.8 / 13.1 |
| 同 | 3 | 80.7 / 82.9 / 59.1 | 0.03 | 26.3 / 2.6 | 5.51 | -2.9 / 13.4 |
| Kyoko の 1 文（7.9 s） | 2 | 94.4 / 100.2 / 66.9 | 0.01 | 25.5 / 1.6 | 5.65 | -3.1 / 12.8 |
| 同 | 3 | 94.4 / 98.8 / 64.3 | 0.02 | 25.0 / 2.0 | 5.72 | -3.1 / 13.1 |
| Kyoko の 16 文（70 s） | 2 | 92.8 / 91.4 / 55.9 | 0.02 | 22.9 / 1.4 | 5.88 | -3.1 / 13.4 |
| 同 | 3 | 92.8 / 89.1 / 38.2 | 0.03 | 24.5 / 2.3 | 5.63 | -3.0 / 13.6 |

- 参照の声は共有の素材の話者 2（7.6 s）。話者の埋め込みは上流と同じ WavLM-Large + ECAPA で作り（`fixtures/target_spk.json`）、ONNX 側には値だけを渡した
- LSD は 512 点の STFT の振幅の dB の差の二乗平均（声のある枠だけ）。位相に影響されないので、聞いたときの差の目安として足した。波形の SNR は位相の小さなずれで大きく下がる
- **int8 を部品ごとに分けると**（Kyoko・3 ステップ、`results/parity-int8-split.json`）、LSD は ASR だけ int8 で 3.1、DiT だけで 5.4、Vocos だけで 3.6、ASR と DiT で 5.5 dB。
  量子化はチャンネルごと（`per_channel`）にした。テンソルごとにした最初の試しは部品の差が倍ほど大きかった
- **Vocos の int8 は、ISTFT の DFT の行列まで量子化すると壊れる**（部品の比較でコサイン 0.14〜0.49）。DFT の行列と Vocos の出口（振幅と位相）は量子化から外した

アプリの中の一致（`results/device-parity.json`。Kyoko・3 ステップ、Python で作った乱数を渡す）:

| 端末 | fp32: Python の ORT と / 上流の PyTorch と（SNR dB・LSD dB） | int8: Python の ORT と / 上流と |
|---|---|---|
| Mac・Pixel 6・iPad Air 4 | 60.6・0.02 / 63.4・0.02 | 3.1・5.08 / 1.4・5.69 |
| Windows | 60.6・0.02 / 63.3・0.02 | 3.7・5.05 / 2.5・5.51 |

int8 はアプリの ORT（1.28）と Python の ORT（1.31）で互いに LSD 5 dB 離れた。量子化した計算の丸めが版と CPU で違い、その差が fp32 のときのようには小さくならない。
**int8 は「Python で確かめた値」をそのまま端末の保証にできない**（端末ごとに聞いて確かめる必要がある）。

## 速さ

160 ms ずつ、待たずに続けて入れる（3 回の平均ではなく全回の分布）。間に合わない回は 160 ms を超えた回。147 回（7.9 s × 3 回）。上流は 3 回に 1 回、1 回の入力で DiT を 2 回呼ぶので、95% はほぼ 2 倍になる。

アプリ（Flutter 3.47.2・flutter_onnxruntime 1.9.0（ONNX Runtime 1.28）・profile ビルド）、3 ステップ、中央値 / 95%（ms）:

| 端末 | fp32 1 スレッド | fp32 2 | fp32 4 | int8 1 | int8 2 | int8 4 |
|---|---|---|---|---|---|---|
| Mac M1 Max | 25 / 46 | 19 / 36 | 25 / 40 | 15 / 27 | 14 / 24 | 20 / 32 |
| Windows i9-12900K | 30 / 54 | 25 / 44 | 25 / 46 | 17 / 31 | 15 / 27 | 19 / 33 |
| iPad Air 4 | 29 / 52 | 29 / 51 | 49 / 78 | 18 / 32 | 19 / 33 | 34 / 63 |
| Pixel 6 | 107 / 197（34 回） | 69 / 128 | 107 / 183（48 回） | 112 / 208（42 回） | 54 / 97 | 105 / 186（33 回） |

2 ステップはどれも 3 ステップの 0.7〜0.85 倍。Windows の 8 スレッドは fp32 で 49 / 96 ms と遅くなった（`results/device/windows-bench.json`）。
内訳（Pixel 6・fp32・2 スレッド・3 ステップ、1 回あたり）: fbank 2.5、ASR 13.1、DiT 51.7、Vocos 15.5、Dart の処理 1.0 ms。fbank の 2.5 ms はほぼ platform channel の往復。

Python（ONNX Runtime 1.31、`results/bench-mac.jsonl`・`results/bench-win.jsonl`）、3 ステップ、中央値 / 95%（ms）:

| | 上流 PyTorch 1 スレッド | ONNX fp32 1 | fp32 2 | int8 1 | int8 2 |
|---|---|---|---|---|---|
| Mac M1 Max | 38.2 / 65.6 | 20.8 / 37.5 | 15.1 / 26.6 | 11.4 / 19.8 | 9.5 / 16.4 |
| Windows i9-12900K | （前の lab: 81 / 143） | 42.6 / 78.7 | 29.7 / 54.4 | 14.0 / 27.0 | 12.1 / 20.7 |

Mac の測定中、ほかの作業でロードアベレージが 5〜9 あった。Mac の数値は静かなときより遅めの可能性がある。

### 5 分続ける（Pixel 6）

fp32 は `results/device/android-soak-fp32-t2-s3.json`、int8 は `results/device/android-soak-int8-t2-s3.json`（どちらも 2 スレッド・3 ステップ）。160 ms ごとに 1 回（待ち合わせはアプリの時計）、Kyoko の文を繰り返す。端末は充電中（電池の残量 77% のまま。**電池の減り方は測れていない**）。

| 経過 | 中央値 / 95% / 最大（ms） | 160 ms を超えた回 / 62 | 熱の状態 | 電池の温度 |
|---|---|---|---|---|
| 10 s | 89 / 168 / 195 | 6 | なし | 32.6 °C |
| 150 s | 91 / 171 / 218 | 5 | なし | 35.0 °C |
| 188 s | 86 / 172 / 180 | 6 | 軽度 | 35.0 °C |
| 298 s | 91 / 174 / 214 | 5 | 軽度 | 35.9 °C |

int8（同じ条件）は、経過を通して中央値 75〜83 ms・95% 135〜164 ms・最大 188 ms、160 ms を超えた回は 1,860 回のうち 45 回（fp32 は 119 回）、
1 回の平均 90〜95 ms（fp32 は 100〜110 ms）、熱の状態は最後まで「なし」、電池の温度 33.1 → 34.9 °C、RSS 約 365 MB（fp32 は約 475 MB）。どちらも変換した音は 299.9 秒ぶん出た。

続けて入れたとき（69 ms）より、160 ms ごとに休ませたときのほうが遅い（約 90 ms）。休む間に CPU の周波数が下がる・小さいコアに移るためと推測（確かめていない）。
平均が 160 ms を下回るので遅れは溜まらないが、1 回が最大 220 ms かかるので、再生の待ち行列に 1 回ぶん（約 60 ms）の余裕が要る。

## 聞き比べの Web UI

```sh
(cd py && uv run python listen.py)   # http://127.0.0.1:8777/
```

- 用意した行: 3 つの入力 × 2/3 ステップで、元の声、上流の PyTorch、ONNX fp32、ONNX int8、別の乱数の上流（差の目安）。Kyoko・3 ステップには 4 端末のアプリの出力も並ぶ
- 「名前を隠して聞く」で PyTorch・fp32・int8 を A・B・C に入れ替える
- 「自分の声で試す」: 元の声（と任意で参照の声）をファイルか録音で渡すと、3 つを同じ乱数で流しながら変換し、変換の時間と PyTorch との差を出す
- 各行は PyTorch の出力の最大値で音量をそろえる（**MeanVC2 の出力は 1.0 を超えることがあり、16 bit にそのまま書くと振り切れる**。最初はこれで差を見誤った）

**オーナーの聴取（2026-10-21）: 「聞いてみたけど int8 でも違いはほとんどわからなかった」。** 聞いた行・回数・機器は記録していない（1 人の聞き手）。

## 既定と製品への申し送り

- **既定は int8**（ASR・DiT・Vocos を int8、fbank・GTM は fp32）。理由: 聞いて差がほとんど分からなかった、通話中のモデルが 56 MB で配りやすい、余裕の小さい端末ほど効く
  （Pixel 6 の 5 分で 160 ms を超えた回が 6.4% → 2.4%、熱も上がらない）。fp32 は、一致を確かめる基準と、int8 で問題が出たときの切り替え先として残す
- **int8 は ONNX Runtime の版で結果が動く**（アプリの 1.28 と Python の 1.31 で LSD 5 dB）。製品は ORT の版を固定し、上げるときは同じ入力で聞き直す。
  端末の一致の試験は「Python と同じ値」ではなく、fp32 の一致（SNR 60 dB 前後）と、int8 は LSD が 6 dB 前後に収まることで見る
- **スレッド数は端末で測って決める。** 端末の種類から決め打ちしない（Pixel 6 は 1 と 4 で遅く 2 で速い、iPad は 1 と 2 が同じで 4 で遅い、Windows は 8 で遅い）。
  最初に変換を使うとき（参照の登録や設定の画面など、通話の外）に、1・2・4 スレッドで数秒ずつ流して 160 ms ごとの処理の平均がいちばん小さいものを選び、端末に覚える。
  迷ったら 2（この lab の 4 端末ではどれも 2 が最速か最速に近い）。ほかの ONNX（聞き取り・画像）と同時に動くので、合計が CPU のコア数を超えないようにする
- **素通しに切り替える目安**（160 ms ごとに流したときの、1 回の処理時間で判断する）:
  - 通話を始める前: 上の測定の平均が 120 ms（160 ms の 75%）を超える端末は、最初から素通し。Pixel 6 は int8 で約 92 ms なので変換する
  - 通話中: 直近 10 秒の平均が 140 ms を超えたとき、または再生の待ち行列が空になった（音が途切れた）ときに、次の無音（発話の切れ目）で素通しへ切り替え、その通話の間は戻さない
    （声の途中で変換と素通しを行き来させない）。1 回が 160 ms を超えるのは平均が下回っていれば問題ないので、それだけでは切り替えない
  - 再生の待ち行列には 1 回ぶん（約 60〜100 ms）の余裕を置く（Pixel 6 は 1 回が最大 190〜220 ms）
  - この目安は単体で動かしたときの数字から決めた。WebRTC・AEC3・聞き取りと同時に動かした実測で見直す

## 成り立つ範囲と残り

- **iPhone は測っていない。** 手元の iOS の実機は iPad Air 4（A14、iPhone 12 と同じチップ）だけ。新しい iPhone はこれより速いはず（未確認）
- **iPad の 5 分の連続は測れていない。** 実行中に別のアプリが前に出てアプリが止まった（同じ iPad をほかの作業も使っていた）。続けて入れる測定は済み
- 電池の減り方は、どの端末も充電中で測れていない。Mac・Windows は続けて流していない
- アプリが同時にほかの処理（WebRTC、AEC3、聞き取りの ONNX、カメラの解析）をしている状態では測っていない。Pixel 6 は単体でも余裕が少ないので、同時に動かすと間に合わない可能性が高い
- int8 の聴取は 1 人で、条件を記録していない。fp16 は試していない。モバイルの GPU・NPU（CoreML・NNAPI の実行プロバイダ）は試していない
- 声の質そのもの（参照の声の高さで届かない問題など）は前の lab のまま。この lab は「上流と同じ変換が、どこで動くか」だけを見た
- 参照の埋め込み（WavLM-Large + ECAPA、2.4 GB）の ONNX 化は範囲外。埋め込みは 256 個の数で、brain のマシンで作って配る想定

## 動かし方

macOS（Apple Silicon）、Python 3.11、[uv](https://docs.astral.sh/uv/)、Flutter 3.47.2、ffmpeg。

```sh
mise run //:test-assets:download
cd py
uv sync
uv run python export_onnx.py --int8      # 初回に MeanVC2 のコードとモデル（約 3 GB）を vendor/ に取り、ハッシュを確かめる。build/onnx/ と results/export-check.json
uv run python parity.py                  # results/parity.json、build/listen/
uv run python bench.py --variant fp32 --threads 1 --steps 3 --output ../results/bench-mac.jsonl
uv run python make_fixture.py            # build/serve/（アプリが取るモデルとフィクスチャ、sha256 の manifest）
uv run python serve.py &                 # :8823。アプリへの配信と、アプリのレポートの受け取り
cd ..
MODE=parity,bench mise run macos
BASE_URL=http://<この Mac のアドレス>:8823 MODE=parity,bench mise run android
BASE_URL=http://<この Mac のアドレス>:8823 MODE=soak EXTRA_DEFINES="--dart-define=VARIANTS=fp32 --dart-define=ORT_THREADS=2 --dart-define=STEPS=3" mise run android
IOS_DEVICE=<UDID> MODE=parity,bench mise run ios          # モデルをアプリに入れる（OFFLINE）。レポートは devicectl で取る
WIN_HOST=<user@windows-pc> BASE_URL=http://<この Mac のアドレス>:8823 mise run windows
(cd py && uv run python device_parity.py)                # results/device-parity.json
```

- iOS はアプリに同梱する形（`OFFLINE`）にした。LAN のサーバーに初めてつなぐとローカルネットワークの許可のダイアログが出て、人が押さないと進まないため（VPN のアドレスに変えて入れ直しても、ダイアログが出たまま要求は届かなかった。新しい起動で出たのか前の起動の残りかは分けていない）
- Windows の MSVC は日本語のロケールで ORT のヘッダーの警告（C4819）がエラーになるので、`app/windows/CMakeLists.txt` で `/utf-8` を付けた（前の lab と同じ）
- アプリの設定は `--dart-define`: `MODE`（`parity`・`bench`・`soak` をカンマで）、`VARIANTS`、`STEPS`、`ORT_THREADS`、`TRIALS`、`SOAK_SECONDS`、`BASE_URL`、`OFFLINE`、`TAG`

## 環境

- MeanVC2 のコード `13acf84c1bf135ea5edad9c245b345289b06b33e`、モデル（Hugging Face）`39cdd19522fe896c227da691314d9a0e3b995486`。ハッシュは `py/meanvc2_runtime.py`、書き出したモデルの sha256 は `fixtures/manifest.json`
- torch 2.5.1（上流の `requirements.txt` と同じ。前の lab の理由のまま）、onnx 1.23.2、onnxruntime 1.31.0（Python）、Python 3.11
- Mac: MacBook Pro Apple M1 Max 64 GB、macOS 27.0.1。Windows: Core i9-12900K・64 GB、Windows 11（Build 26220）、MSVC。Android: Pixel 6（Android 17）。iOS: iPad Air 4（iPadOS 27.0.1）
- 乱数: ODE のノイズは numpy の `default_rng(20261021)` から 1 回 [1,16,80] ずつ。アプリの速さの測定は Dart の乱数（Box-Muller）

`py/meanvc2_runtime.py` と `py/stream_vc.py` は前の lab から写した（`stream_vc.py` には、比較のために ODE のノイズを外から渡す口を足した）。MeanVC2 のコードとモデルは Apache-2.0。有料の API は呼んでいない。

## 決まりの出どころ

| 決まり | 決めた人 | 理由 |
|---|---|---|
| 既定は int8（fbank・GTM は fp32）、fp32 は基準と切り替え先に残す | エージェント（2026-10-21） | オーナーが聞いて差がほとんど分からなかった。56 MB で速く、Pixel 6 で余裕が増える |
| ORT の版を固定し、上げたら聞き直す | エージェント | int8 は ORT の版で結果が動く |
| スレッド数は端末で測って決め、迷ったら 2 | エージェント | 速いスレッド数が端末で違った |
| 素通しの目安（始める前 120 ms、通話中 140 ms か途切れ、切り替えは無音で） | エージェント | Pixel 6 の実測から。単体の数字なので同時に動かした実測で見直す |
