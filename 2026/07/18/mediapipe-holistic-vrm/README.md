# MediaPipe Holistic real-time VRM retargeting

単眼Webカメラから身体、顔、両手を推定し、VRM 1.0アバターへリアルタイムに
同期できるか検証します。ブラウザ内で完結する
[MediaPipe Holistic Landmarker](https://ai.google.dev/edge/api/mediapipe/js/tasks-vision.holisticlandmarker)
と[@pixiv/three-vrm](https://github.com/pixiv/three-vrm)を使用します。

## Purpose

明らかにしたい問いは次のとおりです。

- Web版Holistic Landmarkerでカメラストリームを実時間より速く処理できるか
- 33姿勢点からVRM 1.0 humanoidのローカル回転を生成できるか
- 左右各21手指点をVRMの指ボーンへ割り当てられるか
- 52 face blendshapeをVRM 1.0 expressionへ変換できるか
- 平滑化を加えても、操作可能な遅延に収まるか

成功条件は、公式VRM 1.0モデルを読み込み、カメラの姿勢結果を1フレーム以上
VRMボーンへ適用し、推論時間を記録できることです。手指と表情については、それぞれの
ランドマークが継続的に取得できる画角で別に観察します。

## Fixed conditions

| Component | Version / revision |
| --- | --- |
| `@mediapipe/tasks-vision` | 0.10.35 |
| Holistic Landmarker model | float16 `latest`、13,683,609 bytes |
| `@pixiv/three-vrm` | 3.5.5 |
| Three.js | 0.185.1 |
| Seed-san VRM | vrm-specification `3942748efbc803b258e288e0f6c993c6bb96cebf` |
| input | 1280x720 requested、user-facing camera |
| inference backend | browser WASM、CPU/XNNPACK |
| smoothing | 0.55 default |

取得物は次のSHA-256で検証します。

```text
holistic_landmarker.task
e2dab61191e2dcd0a15f943d8e3ed1dce13c82dfa597b9dd39f562975a50c3f8

Seed-san.vrm
624d0d554bc205bbdc33e22a68a2c3c20edebb3e573011ead8878a65e5329b23
```

Holistic modelのURLは`latest`を含みますが、2023-12-21更新の同一内容であることを
hashで固定しています。Seed-sanはVirtualCast, Inc.によるモデルで、
[VRM Public License 1.0](https://vrm.dev/en/licenses/1.0/)です。モデルとWASMは
`public/models/`、`public/wasm/`へ取得し、Gitでは管理しません。

## Pipeline

```text
getUserMedia camera
  -> HolisticLandmarker.detectForVideo
  -> pose / face / left hand / right hand / blendshapes
  -> coordinate conversion
  -> world direction to local bone quaternion
  -> time-normalized quaternion slerp
  -> normalized VRM humanoid bones and expressions
  -> Three.js render loop
```

Web版0.10.35にはPythonの`LIVE_STREAM`に相当する非同期APIがなく、`VIDEO`モードの
`detectForVideo`は同期実行です。カメラの新しいframeだけを推論し、VRM描画は別の
`requestAnimationFrame` loopで更新します。推論中はmain threadが停止するため、表示FPSも
推論負荷の影響を受けます。

## Retargeting

MediaPipeのworld landmarkを、表示のmirror設定を含めてThree.js座標へ変換します。
各腕・脚・手指について、VRMの初期姿勢における親から子へのworld方向と、観測した2点間の
方向を一致させるquaternionを求めます。そのworld quaternionを親のworld回転で割り、
normalized humanoid boneのlocal quaternionとして適用します。

`SHOW VIDEO`をオフにすると、推論とlandmark表示を継続したまま、生のカメラ映像だけを
画面から隠せます。配信や記事用のスクリーンショットで人物を写したくない場合に使えます。
`LANDMARKS`ではlandmark描画だけを独立して非表示にできます。

脚は各関節の`visibility`が0.65以上の場合だけ反映します。画角外の脚を
誤推定した姿勢は採用せず、該当ボーンをneutralへ戻します。全身姿勢を0.5秒以上
見失った場合も、全ボーンと表情を急に切り替えず滑らかにneutralへ戻します。

腰、脊椎、胸は左右の腰と肩からbody basisを構成し、回転を55%、25%、20%に分配します。
首と頭は顔の左右端、額、顎から作ったface basisを35%、65%に分配します。これは解剖学的な
IK解ではなく、単眼landmarkをアバターへ低遅延に写すための近似です。

手首は手首、人差し指付け根、小指付け根から手のひらの3軸basisを作り、VRM側の同じ
3点から作ったrest basisとの差を適用します。1本の方向だけでは決められなかった手のひらの
表裏とrollを復元し、局所回転は110度に制限して袖への過度なめり込みを抑えます。

手指はMediaPipeの各chainをVRMの`Proximal`、`Intermediate`、`Distal`へ割り当てます。
親指だけはMediaPipeの`CMC → MCP → IP → TIP`をVRM 1.0の
`ThumbMetacarpal → ThumbProximal → ThumbDistal`へ割り当てます。

静止時のlandmark jitterをボーンへ直接反映しないよう、前回採用した回転から2度未満、
手首と指は3度未満の角度差をノイズとして保持します。このdead zoneを越えた意図的な
動きは通常どおり平滑化して反映します。

顔は次をVRM preset expressionへ写します。

| MediaPipe | VRM 1.0 |
| --- | --- |
| `eyeBlinkLeft/Right` | `blinkLeft/Right` |
| `jawOpen` | `aa` |
| `mouthSmile*`, `mouthStretch*` | `ih`, `ee`, `happy` |
| `mouthPucker` | `ou` |
| `mouthFunnel` | `oh` |
| `eyeWide*`, `jawOpen` | `surprised` |

この対応は音素分類ではなく幾何係数からのheuristicです。VRM側で未定義のpresetは
three-vrmが無視します。

平滑化値を`s`、前回からの秒数を`dt`とし、60 Hzを基準に次の補間率を使います。

```text
alpha = 1 - s ** (dt * 60)
```

frame rateが変動しても、同じ`s`で概ね同じ時間応答になるようにしています。

## Observed results

MacBook Pro (Apple M1 Max、64 GB)、macOS 26.5.2、Codex in-app browserで
ローカルserverへ接続しました。

初期化では次を確認しました。

- 13.7 MB Holistic modelと10.9 MB Seed-sanのhash検証に成功
- Holistic LandmarkerがCPU XNNPACK delegateで初期化
- Seed-sanをVRM 1.0として読み込み、34本を駆動対象として取得
- カメラ開始前のVRM描画は120 fps
- bodyとfaceが同時にactiveになるframeを確認

別の12秒計測では次の値を観測しました。この間、被写体が常に全身を画角内に保つようには
統制していません。

| Metric | Observed |
| --- | ---: |
| input frame size | 1280x720 |
| processed frames | 207 |
| effective throughput | 17.3 fps |
| inference time mean | 49.17 ms |
| inference time median | 59.60 ms |
| inference time p95 | 70.60 ms |
| final one-second inference rate | 23 fps |
| final render rate | 43 fps |
| pose detected | 141 / 207 frames |
| pose applied to VRM | 141 frames |
| right hand detected | 1 / 207 frames |
| left hand detected | 0 / 207 frames |
| face detected | 0 / 207 frames |

姿勢が得られた全141 frameでretarget処理が実行されました。これにより、Webカメラから
Holistic推論、VRM 1.0読み込み、ボーン更新までのend-to-end経路は成立しました。
平均49.17 msはモデル推論呼び出しのwall timeで、camera exposure、display scanoutを含む
glass-to-glass latencyではありません。

手と顔の0件はモデル性能の評価結果ではありません。画角を統制していない短時間のsmoke
testであり、先の短い試行ではface activeを観測しました。手指の全ボーンとface expressionの
変換コードは実装し、合成入力によるtestでボーン回転と`jawOpen -> aa`を確認しましたが、
実カメラでの継続同期品質は未確認です。

MediaPipeから、`NORM_RECT without IMAGE_DIMENSIONS`、feedback tensor無効化、OpenGL error
check無効化のwarningが出ました。処理は継続し、アプリケーション例外は観測しませんでした。

## Interpretation

Apple M1 MaxのCPU/WASMでも、単一人物の姿勢をVRMへ反映しながら約17 fpsで処理できました。
デモや対話的な確認には使用できますが、60 fps motion captureではありません。また同期推論が
main threadを占有するため、モデル時間p95が70.60 msのframeでは描画も停止します。

位置2点だけから決めるbone回転にはtwistの自由度が残ります。現在は肩・腰・顔のbasis以外で
twistを解いておらず、前腕、手首、足首の回内・回外は正確ではありません。hipsのworld移動、
foot lock、床接触IKも実装していないため、足滑りとroot固定が発生します。

結論は「Holisticの姿勢をVRMへリアルタイム反映できる」範囲です。「全身、両手、表情を
安定して同時captureできる」ことは、この観測だけではまだ支持できません。

## Requirements and run

- mise
- Node.js 22.22.0
- 初回の依存・model取得にインターネット接続
- WebGLと`getUserMedia`に対応したbrowser

testとproduction buildを実行します。

```sh
mise -C 2026/07/18/mediapipe-holistic-vrm run
```

対話デモを開始します。

```sh
mise -C 2026/07/18/mediapipe-holistic-vrm run preview
```

表示されたlocalhost URLを開き、`カメラを開始`を選びます。付属のSeed-san以外を試す場合は
VRMファイルを選択するか、右側のviewerへdropします。カメラ映像と推論は外部serverへ送信
されません。

## Tests and remaining work

自動testは座標変換、方向quaternion、frame-rate非依存の平滑化、blendshape lookup、合成した
VRM boneとexpressionの更新を確認します。browser camera、MediaPipe model自体、WebGL出力の
画質は自動testの対象外です。

次に必要な検証は次のとおりです。

- 全身、顔、両手が継続して映る固定動画でlandmark coverageを測る
- static poseで各boneの角度標準偏差を測り、平滑化0、0.55、0.8を比較する
- LEDや画面flashを使ってglass-to-glass latencyを測る
- 肩・肘・手首のplane normalから前腕twistを制約する
- foot velocityから接地を推定し、root移動とfoot lock IKを追加する
- 推論をWeb Workerへ移せるか、個別Pose/Face/Handモデルとの分離実行を比較する
