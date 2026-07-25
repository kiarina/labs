# Unreal mixed-audio auditory attention

Unreal Engine 5.8の連続環境音中で、突発音の検知、左右推定、後段処理用clip抽出を
HRTF後のstereo PCMだけから行い、判断過程をHUDへ表示するBlank C++ projectです。

Third Person templateのmesh、animation、mapは使わず、C++で生成したblock pawnを操作します。
三人称cameraとは独立して、Resonance Audioのlistener位置をpawnの頭部へ固定し、listenerのyawを
camera操作へ追従させます。このため移動と旋回で音源の相対方位を変えられます。

## 問いと評価

- 帯域別energy riseと全帯域RMS riseは、環境音中の40 ms burstを低遅延で検知できるか
- 変化した時間周波数binのmasked GCC-PHATとILD投票で左右を判定できるか
- 検出時刻と推定方向から作ったsoft maskで、候補clipを再合成できるか

検知recall、false alarm、latency、検知成功時のside accuracyとUnknown率、抽出前後の
SI-SDRを別々に評価します。暫定成功条件はSNR 0 dB以上でrecall 90%以上、5分間の
false alarm 1件以下、median latency 60 ms以下、side accuracy 90%以上です。

## 実装

- Resonance Audio `BINAURAL_HIGH`、48 kHz Main Output Submix stereo capture
- Audio callbackは事前確保した5秒ring bufferへのcopyだけを行う
- 専用workerが1024-point Hann STFTを480-sample hopで実行
- 8帯域energy riseと全帯域RMS riseの大きい方をonset scoreにする
- 200–1500 Hzのmasked GCC-PHATと1.5–8 kHzのILDを左右投票へ使う
- event前250 ms、後750 msを固定し、同じsoft maskを左右へ適用してiSTFTする
- raw/extracted stereo PCM16 WAVとrun JSONを`Saved/MixedAudioAttention/`へ保存する
- Engine内蔵Cubeだけでblock pawnを生成し、頭部位置をbinaural listenerにする
- 各音源は半径1 mの接触triggerを持ち、pawnが入るたびに0.5秒のcooldown付きでon/offを切り替える

環境音源は内周3 mの大きな水色球に`ENV`、突発音源は外周5 mの小さな橙色球に
`BURST`と表示します。onでは種類別の色で少し拡大し、offでは暗い灰色になります。
通常の可視化demoは環境音2個がon、突発音4個がoffで開始します。環境音は接触で連続再生を
pause/resumeし、突発音はonの球だけが2秒ごとの巡回scheduleで発音します。full modeは自動試験を
維持するため、6音源すべてをonで開始します。HUDの`SOURCES n/6`は現在の有効数です。

HUD上段は状態、頭部位置、score、threshold、prediction、confidence、lag、ILD、latencyを
2行のstatus barへ表示します。デフォルトは画面下部だけを使うcompact dockで、左右それぞれの
直近2秒の波形、4秒のspectrogram、最新eventを表示し、実験空間を広く残します。`H`で詳細表示と
compact表示を切り替えられます。波形は左右共通のpeak scaleを使用し、panel外へ描画しません。

## 実験条件

C++から内周の左右2個のseed固定連続noiseと、外周の方位`-120 / -60 / +60 / +120°`のtargetを生成します。
targetは40 ms chirpとseed固定noise burst、要求SNRは`+12 / +6 / 0 / -6 dB`です。
full modeは60秒較正、300秒negative、2音種×4方位×4 SNR×5回の160 eventを実行します。
音種推理、前後・上下定位、遮蔽、残響は扱いません。距離減衰は前実験と同様に無効であり、
移動時も距離による音量差ではなく、頭部listenerに対するHRTF方向変化を観察します。

## 実行

```sh
UE_ROOT=/path/to/UE_5.8 mise run verify
UE_ROOT=/path/to/UE_5.8 mise run build
UE_ROOT=/path/to/UE_5.8 mise run test
UE_ROOT=/path/to/UE_5.8 mise run editor  # 5 s calibrationの可視化demo
UE_ROOT=/path/to/UE_5.8 mise run full    # full experiment
```

PIE中は`W/S`で前後、`A/D`で左右へ移動し、mouseでcameraと頭部listenerの向きを操作します。
環境音球または突発音球へ接触すると、その音源のon/offが切り替わります。
HUD上段の`HEAD (X,Y,Z) YAW`で、解析時のlistener位置と向きを確認できます。試行中に移動した
場合、正解のLeft/Rightは発音時点の頭部位置とlistener右方向から計算されます。
入力はbinary InputAction assetやMapping Contextへ依存せず、PlayerControllerの実キー状態とmouse deltaを
C++ pawnが直接読み取ります。
PIE開始時はgame viewportへkeyboard/mouse focusを自動的に渡します。操作をEditorへ戻す場合は
`Shift+F1`を使用します。

Editorは`http://127.0.0.1:8100/mcp`でUnreal MCPを公開します。PIE開始時にUnreal内部が
非フォーカスになる環境では、Resonance Audioのexternal-sendがmuteされるため、実験中だけ
volume、VR focus、pause-on-focus-lossを補正し、EndPlayで元の値へ戻します。

## 観測結果

2026-07-25にUnreal MCPからPIEを起動した、block pawn追加前の固定listener demo runの観測です。

| 項目 | 観測値 |
|---|---:|
| matched detections | 35 / 35 |
| correct side | 34 / 35 (97.14%) |
| latency | 20–60 ms、median 20 ms |
| unmatched detections | 0 |
| analyzer queue overrun | 0 |

左右stream波形、scrolling spectrogram、選択bin、検出線、最新eventのraw/extracted波形が
同時に更新されることをMCP screenshotで確認しました。raw/extracted WAVとrun JSONも生成されました。

これは短い固定listener demoの観測で、移動可能listener追加後の再評価でも、5分negativeによる
false alarm評価でもありません。full modeは実装済みですが、
60秒較正＋300秒negativeを含むrunは未実施です。またpost-HRTF targetだけのsolo referenceをまだ
取得していないため、SI-SDRは未測定です。soft-mask WAVの生成を抽出品質の成功とは解釈しません。

集計値は[`results/summary.json`](results/summary.json)に保存しています。

## 失敗と修正

- Resonance Audioはvolume補正だけでは非フォーカスPIEで無音だった。VR focusも有効化して解決した。
- procedural背景音をtimer補充した初版は約2秒で無音化した。既知の実験時間分を起動時にqueueした。
- 通常の`TArray<float>`と非aligned設定ではUE 5.8 FFT factoryがnullを返し、scoreが常に0だった。
  `Audio::FAlignedFloatBuffer`と128-bit aligned設定へ変更した。
- 3帯域rise平均は狭いburstを希釈したため、最大帯域riseとRMS riseの高速経路へ変更した。

## 再現環境と制約

- Unreal Engine 5.8、ResonanceAudio、ModelContextProtocol、AllToolsets
- macOS 26.5.2、Apple M4 Max、Xcode 26.6
- procedural信号だけを使用し、imported assetやbinary mapは含めない
- block pawnはEngine内蔵Cubeを参照し、既存levelのチェッカー床を使うため、Third Personコンテンツへ依存しない
- HRTFは一般化された両耳信号で、実耳録音や個人化HRTFへの一般化は未確認
- Main Outputにはこのprojectの実験音だけを流す前提
