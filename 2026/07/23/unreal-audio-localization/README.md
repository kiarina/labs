# Unreal Engine virtual-ear audio localization

Unreal Engine 5.8 の Third Person C++ project に左右 2 本の仮想マイクと
周期的な chirp 音源を置き、音源座標を判定器へ渡さず、左右の受信波形だけから
音源が現在のカメラ正面に対して左か右かを推定した。

## 結論

5 段階で波形生成とAudio Mixer captureを検証した。短時間captureによるResonance Audio
HRTF runは10方位×5回を50/50正解した。続いて常時稼働ring bufferとoverlap windowを実装し、
10個の変化音を10/10検出、誤検出0、頭部Listener固定時の左右9/10で完了した。

実行可能な完全版projectは
[`kiarina/AudioLocalization`](https://github.com/kiarina/AudioLocalization)で公開している。
このlabは、段階ごとの条件、観測結果、失敗、最小コードと次の研究への引き継ぎを保持する。

1. **直接音の幾何合成:** 左右耳までの距離差を PCM へ適用した。推定 lag は
   `-25..25` samples、correlation は `0.9922..0.9986`。
2. **Audio Mixer 実出力:** `ISubmixBufferListener` で PIE world の Main Output Submix を
   48 kHz stereo PCM として取得した。標準 spatializer の左右差は lag ではなく ILD に現れ、
   lag は全件 0、ILD は `-27.21..27.21 dB` だった。
3. **Resonance Audio HRTF:** `BINAURAL_HIGH`で同じ音源を両耳化した。lagは
   `-19..19` samples、ILDは約`-12.78..12.78 dB`となり、ITDと周波数依存の左右差を含む
   HRTF出力を同じ波形判定器へ入力できた。
4. **連続ストリーム:** 5秒ring bufferを30 ms窓・15 ms hopで走査し、RMSの立ち上がりから
   onsetを検出した。0.75秒間隔の10音をすべて対応付け、event recall/precisionはともに1.0、
   頭部Listener固定時のside accuracyは0.9だった。
5. **Interactive環境:** 音源への接触で反復再生をON/OFFし、HRTF後の左右PCM波形を
   HUD左下・右下へ共通振幅スケールで表示できるようにした。

したがって「Unreal がレンダリングした左右波形だけから、カメラ基準の左右を判定する」
ところまでは確認できた。HRTFのAudio Listener、正解計算、2本の耳meshはすべてアバターの
Pawn view locationへ統一した。HRTFのL/Rは物理的な2本のマイクではなく、この頭部中心を基準に
一般化された人間の頭部・耳介を通った両耳信号の近似である。

## 問いと仮説

- 18 cm 間隔の 2 マイクで左右の到達時間差を波形から回収できるか
- TDOA と耳間レベル差（ILD）だけで左右を分類できるか
- 音源座標を判定器へ混入させずに検証できるか
- Unreal MCP によるレベル構成、Automation Test、PIE 実行を再現可能に記録できるか

仮説は、正中面から 15 度以上離れた単一直接音なら、48 kHz の左右波形の
正規化相互相関から耳間時間差を回収でき、accuracy 95% 以上になる、だった。

## 実験条件

| 項目 | 条件 |
| --- | --- |
| Engine | Unreal Engine 5.8.0 (`55116800`) |
| project | Third Person C++ / `AudioLocalization` |
| host | macOS 26.5.2、arm64、Apple M1 Max、Xcode 26.6 |
| sample rate | 48,000 Hz |
| emitted waveform | 20 ms linear chirp、500–4,000 Hz、Hann window |
| virtual ear spacing | 18 cm |
| speed of sound | 343 m/s |
| source radius | 5 m |
| azimuths | `-150, -120, -90, -60, -30, 30, 60, 90, 120, 150` degrees |
| trials | 5 per source、50 total |
| classifier input | left/right PCM arrays only |
| stage 1 input | direct-path fractional delay と `1 / distance` を適用した合成 PCM |
| stage 2 input | Main Output Submix の interleaved PCM を L/R に分離 |
| stage 3 input | Resonance Audio HRTF後のMain Output Submix stereo PCM |
| spatializer | Resonance Audio / `BINAURAL_HIGH` / `Plugin-Spatialized` |
| capture window | 0.10 s 指定、active region は閾値と前後64 framesで抽出 |
| continuous buffer | 5 s ring buffer、30 ms window、15 ms hop |
| onset | RMS 0.001以上、推定noise floorの3倍以上、150 ms refractory |
| continuous events | 0.75 s間隔、10方位を各1回 |
| interactive source | Pawn overlapでON/OFF、0.75 s反復、0.5 s cooldown |
| waveform HUD | 直近200 ms、20 Hz更新、L/R共通full scale 0.05 |
| classifier | correlation が有効で非ゼロ lag なら TDOA、それ以外は ILD |
| ground truth | `(source - ear center) dot camera right` の符号 |
| ambiguous band | 正面・背面から 15 度以内 |

成功条件は全 50 試行の完了、accuracy 95% 以上、判定器への座標入力なし、
Automation Test と PIE の成功とした。

## 実装

追加したコードは次の 2 Actor と信号処理関数からなる。

- `AAudioLocalizationPulseSource`: 20 ms chirp を `USoundWaveProcedural` へ queue して再生
- `AAudioLocalizationExperiment`: カメラ yaw に追従する左右マイク、試行制御、JSON 出力
- `FAudioLocalizationSubmixListener`: 音声スレッドの Main Output Submix callback から
  interleaved PCM を排他制御下で短時間収集、または固定長ring bufferへ連続書込み
- `AnalyzeContinuousStream`: ring bufferをoverlap windowで読み、RMS onset、イベント対応付け、
  L/R波形による左右推定を継続実行
- `AAudioLocalizationHUD`: 直近のHRTF L/R PCMをmin/max envelopeへ縮約してCanvas描画
- `ExtractActiveStereo`: L/R を deinterleave し、無音区間を除いた active waveform を抽出
- `SynthesizeVirtualMicrophones`: 各耳への距離、音速、fractional delay、距離減衰から左右 PCM を生成
- `EstimateSide`: 左右 PCM のみを受け取り、TDOAの lag 符号、または ILD の符号から左右を返す

音源の `UAudioComponent` は attenuation overrideで`SPATIALIZATION_HRTF`を指定する。
Mac platformのSpatialization/Reverb pluginを両方Resonance Audioへ設定し、実行時にも
`FAudioDevice`のactive spatialization plugin名が`Resonance Audio`であることを検証する。
実験開始時に PIE world の `FAudioDevice` から Main Output Submix を取得し、listener を登録する。
callback は audio render thread なのでゲーム状態へ触れず、PCM copyだけを行う。判定とJSON化は
capture終了後に game threadで行う。

`APlayerController::SetAudioListenerOverride`で実際のAudio ListenerをPawn rootへ相対アタッチする。
位置は`GetPawnViewLocation()`、回転はカメラyawで、毎tick更新する。左右耳meshは同じ中心から
Y軸方向へ±9 cmに置く。ground truthも`GetAudioListenerPosition()`が返した実位置・実方向から計算する。
`EndPlay`ではoverrideを解除する。

この自動実行環境では Editor をmacOS上で最前面にしても、PIEの `BeginPlay` 時点で
`FApp::HasFocus()==false`、app volume multiplier `0` が観測された。UE既定の
`Audio.UnfocusedVolumeMultiplier=0.0` では実出力が無音になるため、通常の実験では
`FApp::SetVolumeMultiplier(1.0)` とVR-focusを適用し、`EndPlay`で元の値へ戻す。
Resonance Audioはexternal-send Submixを使い、背景時にSubmix自体がmuteされるため、volume multiplier
だけでなくVR-focusも必要だった。この補正は
`bForceAudioWhenUnfocused` で対照試験用に無効化できる。

カメラ向きと音源座標は正解ラベルの算出にだけ使う。`EstimateSide` の引数には
`FVector` も音源位置もなく、`left/right PCM`, sample rate, max lag,
minimum correlation だけが入る。

この lab には stock Third Person project を複製せず、次だけを保存した。

- [`AudioLocalizationExperiment.h`](project/Source/AudioLocalization/AudioLocalizationExperiment.h)
- [`AudioLocalizationExperiment.cpp`](project/Source/AudioLocalization/AudioLocalizationExperiment.cpp)
- [`AudioLocalizationHUD.h`](project/Source/AudioLocalization/AudioLocalizationHUD.h)
- [`AudioLocalizationHUD.cpp`](project/Source/AudioLocalization/AudioLocalizationHUD.cpp)
- [`AudioLocalizationGameMode.cpp`](project/Source/AudioLocalization/AudioLocalizationGameMode.cpp)
- [`AudioLocalization.Build.cs.patch`](project/AudioLocalization.Build.cs.patch)
- [`AudioLocalization.uproject.patch`](project/AudioLocalization.uproject.patch)
- [`DefaultEngine.ini.patch`](project/DefaultEngine.ini.patch)
- [`mcp-operations.json`](mcp-operations.json)
- [`pie-results.json`](results/pie-results.json)（幾何合成）
- [`rendered-results.json`](results/rendered-results.json)（Audio Mixer 実出力）
- [`rendered-unfocused-failure.json`](results/rendered-unfocused-failure.json)（無音だった失敗試行）
- [`rendered-focus-control-summary.json`](results/rendered-focus-control-summary.json)（フォーカス再試行）
- [`hrtf-results-summary.json`](results/hrtf-results-summary.json)（Resonance HRTF）
- [`continuous-hrtf-results-summary.json`](results/continuous-hrtf-results-summary.json)（連続onset検出）
- [`avatar-listener-motion-summary.json`](results/avatar-listener-motion-summary.json)（頭部Listener移動検証）
- [`interactive-hud-summary.json`](results/interactive-hud-summary.json)（接触ON/OFFとHUD検証）
- [`automation-test.json`](results/automation-test.json)

## 再現手順

1. UE 5.8 で Third Person の C++ project `AudioLocalization` を新規作成する。
2. `PROJECT_ROOT` をその project root、`LAB_ROOT` をこの lab に設定する。
3. 5 個の C++ ファイルを project の `Source/AudioLocalization/` へコピーする。
4. project rootで3個のpatchを適用する。
5. patchによりResonance AudioとMCP toolsetsを有効にし、MacのSpatialization/Reverbを設定する。
6. Editor を起動し、`mcp-operations.json` の順で Actor を配置・保存する。
7. C++ build、Automation Test、PIE を実行する。

```sh
export PROJECT_ROOT=/path/to/AudioLocalization
export LAB_ROOT=/path/to/labs/2026/07/23/unreal-audio-localization
export UE_ROOT=/path/to/UE_5.8

cp "$LAB_ROOT/project/Source/AudioLocalization/AudioLocalizationExperiment."{h,cpp} \
  "$LAB_ROOT/project/Source/AudioLocalization/AudioLocalizationHUD."{h,cpp} \
  "$LAB_ROOT/project/Source/AudioLocalization/AudioLocalizationGameMode.cpp" \
  "$PROJECT_ROOT/Source/AudioLocalization/"
patch -d "$PROJECT_ROOT" -p1 < "$LAB_ROOT/project/AudioLocalization.Build.cs.patch"
patch -d "$PROJECT_ROOT" -p1 < "$LAB_ROOT/project/AudioLocalization.uproject.patch"
patch -d "$PROJECT_ROOT" -p1 < "$LAB_ROOT/project/DefaultEngine.ini.patch"

"$UE_ROOT/Engine/Build/BatchFiles/Mac/Build.sh" \
  AudioLocalizationEditor Mac Development \
  "$PROJECT_ROOT/AudioLocalization.uproject" -WaitMutex -NoHotReloadFromIDE
```

MCP は `initialize`、`notifications/initialized` の後、meta-tool `call_tool` から
各 toolset を呼ぶ。今回の主要操作は以下だった。

- `SceneTools.find_actors` と `ActorTools.get_actor_transform` で PlayerStart を確認
- `SceneTools.add_to_scene_from_class` で管理 Actor 1 個、音源 Actor 10 個を配置
- `SlateInspectorToolset.PressKey("Ctrl+Shift+S")` で World Partition external actors を保存
- `AutomationTestToolset` で discover、list、run、results を実行
- `EditorAppToolset.StartPIE` と `StopPIE` で E2E 実験を実行

project の実行結果は幾何合成版が `Saved/AudioLocalization/results.json`、
旧panning版が`Saved/AudioLocalization/rendered-results.json`、HRTF版が
`Saved/AudioLocalization/hrtf-results.json`、連続版が
`Saved/AudioLocalization/continuous-hrtf-results.json`へ出力される。
補正を無効化した対照試験は `rendered-focused-control-results.json` へ出力される。
lab 内の保存済み結果だけを検査する場合は次を実行する。

```sh
mise run
```

## 観測事実

### Stage 1: direct-path geometry

| 方位 | truth | prediction | lag samples | ILD dB | correlation |
| ---: | --- | --- | ---: | ---: | ---: |
| -150 | Left | Left | 13 | 0.2063 | 0.9922 |
| -120 | Left | Left | 22 | 0.2099 | 0.9983 |
| -90 | Left | Left | 25 | 0.3029 | 0.9986 |
| -60 | Left | Left | 22 | 0.2099 | 0.9983 |
| -30 | Left | Left | 13 | 0.2063 | 0.9922 |
| 30 | Right | Right | -13 | -0.2063 | 0.9922 |
| 60 | Right | Right | -22 | -0.2099 | 0.9983 |
| 90 | Right | Right | -25 | -0.3029 | 0.9986 |
| 120 | Right | Right | -22 | -0.2099 | 0.9983 |
| 150 | Right | Right | -13 | -0.2063 | 0.9922 |

表は各方位 5 回で同一だったため、代表値を 1 行ずつ示した。

- PIE: evaluated 50、correct 50、unknown 0、accuracy 1.0
- 5 m 条件で左右耳までの距離は約 4.91–5.09 m

### Stage 2: rendered Main Output Submix

| 方位 | truth | prediction | lag samples | ILD dB | correlation |
| ---: | --- | --- | ---: | ---: | ---: |
| -150 | Left | Left | 0 | 27.2074 | 1.0000 |
| -120 | Left | Left | 0 | 18.5071 | 1.0000 |
| -90 | Left | Left | 0 | 11.2601 | 1.0000 |
| -60 | Left | Left | 0 | 6.8306 | 1.0000 |
| -30 | Left | Left | 0 | 3.2623 | 1.0000 |
| 30 | Right | Right | 0 | -3.2623 | 1.0000 |
| 60 | Right | Right | 0 | -6.8306 | 1.0000 |
| 90 | Right | Right | 0 | -11.2601 | 1.0000 |
| 120 | Right | Right | 0 | -18.5071 | 1.0000 |
| 150 | Right | Right | 0 | -27.2074 | 1.0000 |

- PIE: evaluated 50、correct 50、unknown 0、accuracy 1.0
- rendered format: 48,000 Hz、2 channels
- active waveform: 992–1,009 frames
- raw capture: 4,096–8,192 frames。PIEが約3 tick/sだったため指定0.10秒より長く変動したが、
  active region抽出後の判定入力は安定した
- standard panning は左右chの振幅を変えたが時間差を加えないため、全trialで lag 0だった
- Automation Test: 1 passed、0 failed、0 warnings、0 errors
- C++ build: succeeded

### Stage 3: Resonance Audio HRTF

| 方位 | truth | prediction | lag samples | mean ILD dB | mean correlation |
| ---: | --- | --- | ---: | ---: | ---: |
| -150 | Left | Left | 1 | 8.6734 | 0.8454 |
| -120 | Left | Left | 1 | 10.1209 | 0.7638 |
| -90 | Left | Left | 19 | 12.7753 | 0.9038 |
| -60 | Left | Left | 8 | 8.9949 | 0.5511 |
| -30 | Left | Left | 4 | 2.8778 | 0.7881 |
| 30 | Right | Right | -4 | -2.8778 | 0.7881 |
| 60 | Right | Right | -8 | -8.9949 | 0.5511 |
| 90 | Right | Right | -19 | -12.7753 | 0.9038 |
| 120 | Right | Right | -1 | -10.1209 | 0.7638 |
| 150 | Right | Right | -1 | -8.6734 | 0.8454 |

- UE logでactive Spatialization/Reverb pluginがともにResonance Audioであることを確認した
- quality modeは`BINAURAL_HIGH`、rendered formatは48,000 Hz stereo
- 最終runはevaluated 50、correct 50、unknown 0、accuracy 1.0
- HRTFではlagとILDが左右で符号反転し、panning版と異なり非ゼロの時間差を観測した
- 直前runは-30度の1試行だけRMS約`6.7e-6`のほぼ無音となり49/50だった。即時再実行は50/50で、
  単発の低振幅外れ値を再現できなかった
- Automation Test: 1 passed、0 failed、0 warnings、0 errors

### Stage 4: continuous HRTF stream and onset detection

| 方位 | truth | prediction | latency ms | lag samples | ILD dB |
| ---: | --- | --- | ---: | ---: | ---: |
| -150 | Left | Left | 30.00 | 8 | 8.78 |
| -120 | Left | Right | 12.00 | -2 | 14.42 |
| -90 | Left | Left | 9.00 | 1 | 12.51 |
| -60 | Left | Left | 6.00 | 28 | 16.33 |
| -30 | Left | Left | 18.00 | 7 | 7.33 |
| 30 | Right | Right | 15.00 | -8 | -8.38 |
| 60 | Right | Right | 5.67 | -28 | -15.86 |
| 90 | Right | Right | 9.00 | -1 | -12.51 |
| 120 | Right | Right | 14.67 | 1 | -11.64 |
| 150 | Right | Right | 11.67 | -10 | -10.05 |

- 48 kHz stereoの常時ストリームでexpected 10、matched 10、missed 0、detections 10、
  false positives 0、Unknown 0を観測した
- event recall 1.0、event precision 1.0、side accuracy 0.9
- 誤判定は-120度の1件。ILDの符号はground truthと一致したが、
  correlationが有効だったため現行判定器がlag符号を優先し、反対側を返した
- 検出遅延は5.67–30.00 ms。最初の音だけstream開始前に発音するため30 ms窓全体を待った
- この段階は複数のActorを順番に発音した結果であり、複数音源の同時混合はまだ試していない
- C++ cold build成功、MCP Automation Testは1 passed、0 failed

### Avatar-mounted Audio Listener motion control

通常時OFFの`bApplyValidationAvatarMotion`をMCPで一時的に有効化し、5音目の後にPawnを
カメラ正面へ100 cm移動した。

- 移動前のListener/耳mesh中心: `(0, 0, 366.01) cm`
- 移動後のListener/耳mesh中心: `(100, 0, 366.01) cm`
- 固定音源の相対方位は、`30→36.90`、`60→70.89`、`90→101.31`、
  `120→128.95`、`150→154.87`度へ変化した
- 移動runもmatched 10/10、false positive 0、event recall/precision 1.0、左右8/10
- したがって、アバター移動が実際のHRTF Listener位置と入力波形の空間条件へ反映されることを確認した
- 検証後、Editor上の自動移動スイッチは保存せずOFFへ戻した。通常はプレイヤー入力による移動を使う

### Interactive source toggles and waveform HUD

`bInteractiveMode=true`では自動10音試行を開始せず、ring bufferとonset解析を無期限に動かす。
各音源には半径100 cm、半高300 cm、音源から下へ200 cmずらしたCapsule Triggerを設けた。
Pawnが接触するたびに、その音源の20 ms chirp反復をON/OFFする。反復間隔は0.75秒、
二重発火防止cooldownは0.5秒である。各球には`BasicShapeMaterial`を明示的に割り当て、
音源ごとのDynamic Material Instanceを生成する。ON時は赤色・1.29倍、OFF時は青色へ戻す。

HUDはMain Output Submixの直近200 ms、48 kHzなら左右各9,600 samplesを20 Hzで取得する。
左下にcyanの`LEFT EAR`、右下にorangeの`RIGHT EAR`を表示し、同じfull scale `0.05`で
min/max envelopeを描く。左右を個別正規化しないため、ILDに相当する振幅差を目視できる。
上段にはL/R RMS、ON音源数、推定左右、lag、ILD、correlationを表示する。

検証用自動接触を一時的に有効にし、音源0へ接触、離脱、再接触した。

- 1回目の接触で`repeating=true`、離脱後も0.75秒反復が継続した
- 再接触で`repeating=false`となり停止した
- 初回実装では球が`DefaultMaterial`を使用しており、`Color`パラメータ設定が描画へ反映されず、
  scale変更だけが見えた。修正後はログ上のmaterialが`MID_BasicShapeMaterial_0`となり、
  OFF `(0.02, 0.18, 1.00)`、ON `(1.00, 0.02, 0.12)`、再OFFの遷移を観測した
- HUDの`DrawHUD`が非ゼロPCMを左右各9,600 samples受け取った
- HUD ready時のL/R RMSはともに`0.002544`、ON音源数は1
- 音源とListenerが同位置の接触直後は左右差0でUnknown、離れた後はlag 10、ILD +10.033 dB、Leftを観測した
- 検証用`bApplyValidationInteractiveContact`の既定値はfalse。通常操作では歩いて接触する

### Focus control: volume補正なし

- EditorをmacOS上で最前面にしたうえで、MCP `StartPIE` を2回、Slateの
  ウィンドウ選択 + `Alt+P` を1回試した
- 最終試行のPIE開始時は `FApp::HasFocus()==false`、volume multiplier `0`
- 48,000 Hz stereo bufferは50回取得したが、active waveformは0/50、Unknownは50/50
- この結果から、自動実行時の無音はユーザーの画面操作だけでは説明できない

## 解釈

- **観測から言えること:** 無反射・単一音源・既知音速の直接音モデルでは、20 ms chirp の
  相互相関で左右を安定して分離できた。また、UE built-in panning が Main Output Submixへ
  出した stereo PCM は、座標を判定器へ渡さず ILD だけで左右を分離できた。
- **方式差:** 幾何合成版は耳間到達時間差を生成したが、built-in panning版は同じ波形を
  左右へ異なるgainで送るため correlationは約1、lagは0だった。今回のStage 2で効いた特徴量はILDである。
- **HRTF:** Stage 3ではResonance Audioが一般化された頭部・耳介特性を反映し、方位ごとに異なる
  correlation、ITD、ILDを生成した。同じ判定器を変更せずHRTF波形へ適用できた。
- **連続処理:** Stage 4により、試行開始後だけ波形を取る方式ではなく、未知時刻の変化音を
  常時ストリームから検出して左右推定へ渡す実験基盤ができた。-120度の結果から、HRTFの
  前後領域では単一窓のlag符号だけをILDより優先する規則が不安定だと分かった。
- **Interactive環境:** Stage 5ではプレイヤーが音源集合を空間内で変更でき、実際に耳へ届いた
  mix全体を左右共通スケールで即時観察できる。接触位置では音源とListenerが近すぎて左右差が
  消えるが、離れるとHRTFのITD/ILDが現れることも観測した。
- **推測:** ノイズ、反射、遮蔽、複数音源を入れても GCC-PHAT、帯域制限、時間窓、
  confidence threshold を導入すれば一定範囲で維持できる可能性がある。
- **まだ言えないこと:** occlusion、reverb、移動中、実環境ノイズ、複数音源で同じ精度になること、
  一般HRTFの結果が個人化HRTFや実録音へ一般化することは未確認である。

## 失敗した試行

- 初回 build は module export macro の大小文字、UE 5.8 の型厳格な `UE_LOG`、
  lambda capture の不足で失敗した。修正後の build は成功した。
- `SceneTools.save_actor` は新規 World Partition external actor の asset がまだ存在せず失敗した。
  Slate MCP の Save All shortcut では 11 個の external actor asset が生成され、保存できた。
- macOS の `Cmd+S` キー送信は保存を確認できなかったため、成功手順には採用していない。
- Editor起動中のbuildは `-0003` hot-reload dylibだけを生成し、再起動時には古いbase dylibが
  読み込まれた。Editor停止中に `-NoHotReloadFromIDE` で通常moduleをlinkして解決した。
- 最初の Submix run は 48 kHz stereo bufferを50回取得したが、全sampleが0で50 Unknownだった。
  UE既定の `Audio.UnfocusedVolumeMultiplier=0.0` とPIE開始時の非フォーカス状態が直接条件だった。
  実験中だけ app volumeを1へ設定すると非ゼロPCMを取得できた。失敗JSONも保存した。
- ユーザー操作によるフォーカス喪失の可能性を切り分けるため補正なしで再試行したが、macOSで
  UnrealEditorが最前面でもUE内部は非フォーカス・volume 0だった。MCP `StartPIE` だけでなく
  Slate入力によるPlayでも同じ結果であり、今回の自動経路では「最前面」とUEのaudio focusが一致しない。
- 最初のHRTF runも全sampleが0だった。Resonance Audioはbackground mute対象のexternal-send Submixを
  使うため、app volumeだけでは不十分だった。実験中に`UseVRFocus`と`HasVRFocus`も有効化して解決した。
- 連続版の初回は、最初のsubmix callbackを待ってから発音する設計にしたため、音がなければcallbackが
  始まらない循環待ちになった。最初の音だけ即時発音する設計に変更した。
- onset判定の初回refractoryを`MIN_int64`から減算し、符号付き整数overflowで全検出を抑止した。
  sentinelを先に判定するよう修正した。
- 解析がring bufferの保持範囲より遅れた場合、同じ読取不能位置を再試行する可能性があった。
  読取失敗時に必ず1 hop以上進め、1 tick最大512窓に制限した。
- 非フォーカスPIEでは音量だけでなくworld timeも停止し、event timerが進まなかった。
  実験中だけ`GEngine->bPauseOnLossOfFocus=false`にして値を退避・復元し、完走を確認した。
- Editor再起動時、CrashReportClientがMCPの8000番portを継承して保持し、新Editorがbindできなかった。
  滞留processを終了してEditorを再起動し、listener PIDがEditor PIDと一致することを確認した。
- `AllToolsets`が有効な通常Editor起動では、既存の`GameFeatureData` Asset Manager警告dialogが
  初期化を止める場合があった。自動E2E再起動では`-unattended`で既知dialogを抑止した。
  これはInteractive audio/HUD実装の失敗ではなく、以前から観測しているtoolset構成上の起動警告である。

## 制約と次の実験

Stage 3はHRTF後のAudio Mixer実出力だが、Main Outputなので他のゲーム音があれば混入する。
また、HRTFは一般化された人間の両耳信号であり、物理的な2本のマイクではない。

常時稼働ring buffer、overlap window、onset検知まで実装できた。次は専用Submixへのworld audio隔離を
検討する。Interactive toggleで複数音源をONにし、背景音を連続再生した状態で突発音を重ねる。
occlusion、reverb、SNR、同時音源数、
カメラ回転速度を段階的な実験条件にし、event recall/precisionとside accuracyを別々に評価する。

次の研究では以下の順序で条件を追加する。各段階で単一音源のbaselineを必ず再測定し、
検出失敗と左右誤判定を別々に記録する。

1. 専用Submixへ評価対象の音源だけをroutingし、UIや環境音との混入を制御する。
2. 連続背景音1個＋既知時刻の突発音1個から始め、SNRを段階的に下げる。
3. chirpを銃声・発話・大声の波形へ置き換え、音種ごとのonset thresholdを比較する。
4. 同時音源数を増やし、event recall/precision、side accuracy、Unknown率を測る。
5. 距離、遮蔽、反射・残響、camera回転を1条件ずつ追加し、交互作用は最後に調べる。

現行projectを開始点にする場合はpublic repositoryをcloneし、このlabの
`continuous-hrtf-results-summary.json`と`interactive-hud-summary.json`をbaselineとして使う。

Audio Synesthesia NRT は editor で解析結果を生成し、runtime 生成音の解析用途には
そのまま適合しないため、この次段階の capture 手段には選ばない。

## 公式資料

- [USoundWaveProcedural API (UE 5.8)](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/USoundWaveProcedural?lang=en-US)
- [ISubmixBufferListener API (UE 5.8)](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/ISubmixBufferListener?lang=en-US)
- [FAudioDevice API (UE 5.8)](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/FAudioDevice?lang=en-US)
- [FApp API (UE 5.8)](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Core/FApp?lang=en-US)
- [Audio Engine Overview (UE 5.8)](https://dev.epicgames.com/documentation/en-us/unreal-engine/audio-engine-overview-in-unreal-engine)
- [Audio Mixer Overview (UE 5.8)](https://dev.epicgames.com/documentation/en-us/unreal-engine/audio-mixer-overview-in-unreal-engine)
- [Submixes Overview (UE 5.8)](https://dev.epicgames.com/documentation/unreal-engine/overview-of-submixes-in-unreal-engine?lang=en-US)
- [Spatialization Overview (UE 5.8)](https://dev.epicgames.com/documentation/unreal-engine/spatialization-overview-in-unreal-engine?lang=en-US)
- [Audio Synesthesia (UE 5.8)](https://dev.epicgames.com/documentation/en-us/unreal-engine/audio-synesthesia-in-unreal-engine)

既存 lab を検索した範囲では Unreal、両耳音源定位、binaural に関する研究はなく、
本 lab と重複する既存実験は見つからなかった。
