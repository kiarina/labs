# Unreal Engine lab の開発ガイド

Unreal Engine を使う lab を、小さく独立し、再現可能な project として管理するための
共通手順です。新しい Unreal Engine lab を作るとき、または既存 lab の project、C++、
Config、Content、build・検証手順を変更するときに参照してください。

この文書は `TokyoCanvas` で実際に得た Unreal Engine 5.8、Unreal MCP、PIE、C++ build の
知見を、labs の用途に合わせて一般化したものです。project 固有の設定やコマンド名は、
各 lab の README と task を正典にしてください。

## 基本方針

- Unreal project は lab 内に置き、外部ディレクトリの project に依存させない
- project は原則として Blank C++ から始め、検証対象でない gameplay template や
  Starter Content を含めない
- Level、音源、Listener、実験装置は、可能な範囲で C++ から決定的に構成する
- Editor の実体や asset、PIE world を確認・操作するときは Unreal MCP を使う
- C++、`.ini`、task、検証scriptなどのテキストファイルは、通常のファイル編集で管理する
- 自動検証とMCPによる観測を優先するが、MCPで再現できない聴感、見た目、連続入力は
  必要に応じて人が実機確認する
- 観測結果、失敗、MCPの制約、手動確認した範囲をREADMEに区別して記録する

## 最小 project の構成

推奨構成は次のとおりです。project directory名はlab内で一意にしてください。

```text
YYYY/MM/DD/{slug}/
├── README.md
├── metadata.json
├── .gitignore
├── .mise/tasks/
├── UnrealProject/
│   ├── {Project}.uproject
│   ├── Config/
│   ├── Source/
│   └── Content/
│       └── Maps/
│           └── Experiment.umap
├── results/
└── verify.py
```

Gitで管理するもの:

- `.uproject`
- `Config/`
- `Source/`
- 起動に必要な最小限のmap、Submix、Blueprintなどのproject固有asset
- build・起動・検証を行うtask
- pathや機密情報を除去した検証結果

Gitで管理しないもの:

- `Binaries/`
- `DerivedDataCache/`
- `Intermediate/`
- `Saved/`
- IDEが生成するproject、workspace、user settings
- template由来で検証に不要なmesh、texture、animation
- download・import・cookで再生成できるasset

Engine内蔵のprimitiveやmaterialを参照できる場合は、同じassetをprojectへコピーしません。
大きな音声、画像、動画は`tests/assets/`から利用します。Unrealへのimportや変換が必要なら、
生成先をlabの無視対象へ置き、その準備手順と入力revisionをREADMEへ記録します。

既存のUnreal Engine labは、この構成への適合だけを目的として作り直す必要はありません。

## 新しい lab と project を作る

Unreal Engine 5.8のインストールにはBlank C++ templateがありますが、新規projectを作成する
公開CLIはありません。`GenerateProjectFiles.sh`は既存projectのIDE filesを生成するcommandで、
project自体は作成しません。

このrepositoryでは、次のtaskでBlank C++相当のlabと完全な最小projectを生成します。

```sh
mise run //:unreal:create -- \
  YYYY/MM/DD/{slug} \
  ProjectName \
  --title "Human-readable project title"
```

`ProjectName`はC++ module名にも使うため、英字で始まる英数字だけにします。出力先が既に存在する
場合は上書きせず失敗します。生成後にREADMEの目的、問い、評価方法を定義してから実装を始めます。

scaffoldの構造だけを確認するには、生成されたlabで次を実行します。

```sh
mise -C YYYY/MM/DD/{slug} run verify
```

Editor targetのbuildとEditor起動にはEngineの場所を渡します。

```sh
UE_ROOT=/path/to/UE_5.8 mise -C YYYY/MM/DD/{slug} run build
UE_ROOT=/path/to/UE_5.8 mise -C YYYY/MM/DD/{slug} run editor
```

## Unreal MCP の設定

Editorの状態確認、asset操作、Blueprint操作、PIE、スクリーンショット、world内の数値検証には
Unreal MCPを使います。標準endpointは次です。

```text
http://127.0.0.1:8100/mcp
```

`.uproject`では、使用するEngine versionで提供されているMCP serverとtoolset pluginを
有効にします。Unreal Engine 5.8で確認した最小例は次です。

```json
{
  "Plugins": [
    {
      "Name": "ModelContextProtocol",
      "Enabled": true
    },
    {
      "Name": "AllToolsets",
      "Enabled": true
    }
  ]
}
```

plugin名や分割方法はEngine versionで変わる可能性があるため、実際に使用した一覧を
READMEへ記録します。必要なtoolsetだけを有効にできる場合は、過剰なpluginを追加しません。

projectの`Config/DefaultEditorPerProjectUserSettings.ini`には、次の設定を使用できます。

```ini
[/Script/ModelContextProtocolEngine.ModelContextProtocolSettings]
ServerUrlPath=/mcp
ServerPortNumber=8100
bAutoStartServer=True
bEnableToolSearch=True
```

MCP clientがrepository local設定に対応する場合は、次のようにendpointを登録します。

```json
{
  "mcpServers": {
    "unreal": {
      "type": "http",
      "url": "http://127.0.0.1:8100/mcp"
    }
  }
}
```

Editor起動後は、単にportがLISTENしているだけで準備完了と判断しません。MCPから軽量な
状態取得を行い、応答することを確認します。起動時のmodal dialogでgame threadが止まると、
portは開いていてもMCPが応答しない場合があります。

## MCP を使う場面

次の作業は、可能な限りUnreal MCPで行います。

- assetの存在、class、property、参照関係の確認
- assetの作成、複製、設定変更、compile、明示的な保存
- Blueprint / AnimBlueprint graphの確認と、対応toolが扱える範囲の編集
- Editor commandの実行
- PIEの開始、終了、状態取得
- Slate経由のclick、単発key入力、スクリーンショット
- PIE world内のActor取得、transformやpropertyの数値確認
- Automation Testの起動と結果確認

一方、次はMCPだけで完了扱いにしません。

- 押しっぱなしや連続的なmouse・keyboard入力
- gamepad stickなどのanalog入力
- 音が実際にどう聞こえるかという聴感評価
- frame timingや操作の手触り
- MCP toolが対応しないMigrateや一部のsubgraph編集

音声labでは、MCPによるPIE操作とPCM・JSONによる定量評価を行ったうえで、聴感確認が必要な
項目を別に明記します。スクリーンショットだけで音声機能を検証済みとはしません。

## MCP asset 編集の安全策

MCPのreflection経由でassetを直接変更すると、GUIなら実行される検証や再構築処理を通らず、
保存、thumbnail描画、PIE終了時にEditorがクラッシュする場合があります。

assetを変更するときは、次の順序を守ります。

1. Git statusと対象assetの保存状態を確認する
2. MCPで現在のpropertyと参照を読み、変更前の状態を記録する
3. 最小の1 asset、1 propertyだけを変更する
4. 必要なcompileを実行する
5. 対象assetを明示的に保存する
6. Editorの生存、assetの再読込、期待propertyを確認する
7. canaryが成功してから残りへ展開する
8. PIEまたはAutomation Testで実行時の結果を確認する

Blueprintは配線後にcompileし、compile成功後に保存します。大量のassetを一括変更してから
初めて保存する方法は避けます。

BlendSpaceでは、sample数、sample位置、axisなどをreflectionで直接変更すると内部gridが
再構築されず、保存やthumbnail生成でクラッシュする事例がありました。既存構造を保った
animation参照の差し替え以外は、対応する専用toolまたはGUIを使います。

PIE worldのActorをMCPから変更すると、EditorのUndo transactionがPIE objectへの参照を保持し、
StopPIE時にクラッシュする場合があります。検証用の状態はできるだけC++やtest harnessから
生成します。PIE objectを直接変更した場合は、ログ、JSON、スクリーンショットなど必要な結果を
先に回収してからPIEを停止します。

## C++ build と Editor の再起動

C++の変更をPIEへ確実に反映するには、Unreal Editorを完全終了してからEditor targetをbuildします。
Editorを起動したままbuildすると、番号付きのhot reload binaryが生成され、次回起動時に古いbase
binaryが読み込まれる場合があります。

推奨サイクル:

1. MCPでPIEを停止する
2. 意図したasset変更だけを明示的に保存する
3. PIE由来の不要なdirty mapは保存しない
4. 対象projectを開いているEditor processを特定して終了する
5. port 8100を保持するprocessが残っていないことを確認する
6. project固有のhot reload binaryだけを片付ける
7. Editor targetをbuildする
8. Editorを再起動する
9. MCPの状態取得が成功するまで待つ
10. Automation TestとPIE検証を行う

同じmachineで別projectのEditorが動いている可能性があるため、全Unreal Editor processを無条件に
一括終了しません。project path、PID、portのownerをread-only commandで特定してから、対象process
だけを終了します。強制終了は、通常終了できず、未保存変更を破棄してよいことを確認した場合に限ります。

macOSのbuild commandはlabのtaskへ隠蔽し、Engineの場所を環境変数で上書き可能にします。

```sh
"${UE_BUILD}" "${PROJECT_NAME}Editor" Mac Development \
  -Project="${PROJECT_FILE}"
```

repository内のREADMEやtaskへmachine固有の絶対pathを書きません。`UE_ROOT`、`UE_BUILD`、
`UE_EDITOR`、`PROJECT_FILE`など、用途が明確な変数を使います。

変更が反映されたことは、build成功だけで判断しません。PIEログ、追加したAutomation Test、
新しいpropertyや挙動など、変更後binaryでなければ成立しない観測を1つ以上確認します。

## AutoSave と dirty asset

PIE開始・終了だけでmapがdirtyになるprojectがあります。内容に意味がないのに保存すると、`.umap`へ
毎回binary差分が発生します。PIE由来と確認できたdirty assetは保存せず破棄します。

反復的なMCP build cycleで起動時のAutoSave復元modalが問題になる場合は、project単位で次を設定できます。

```ini
[/Script/UnrealEd.EditorLoadingSavingSettings]
bAutoSaveEnable=False
```

AutoSaveを無効にすると未保存作業の自動復旧も失われます。採用する場合は、MCP編集を小さく区切って
明示的に保存し、READMEへ理由を記録します。既にEditorを起動したmachineでは、per-user設定が
project defaultを上書きしていないか確認します。

## port 8100 とクラッシュ復旧

MCPが応答しないときは、次を順に確認します。

1. Editor processが生存しているか
2. port 8100をどのprocessがLISTENしているか
3. 起動時modal dialogが開いていないか
4. Editor logにMCP serverのbind失敗がないか
5. 直前のasset保存やthumbnail生成でクラッシュしていないか

Editorクラッシュ後、CrashReportClientなどの子processがlistenerを保持し続ける場合があります。
port ownerを確認して該当processだけを終了し、portが空いたことを確認してからEditorを再起動します。
bindに失敗したまま起動したEditorは自動で再bindしない場合があるため、そのEditorも終了してから
起動し直します。

クラッシュ後は、次を保存します。

- Editor logの末尾とcall stack
- 直前に呼んだMCP toolと引数
- 保存済み・未保存だったasset
- 再現条件
- 復旧に必要だった操作

log pathはplatformとprojectで異なるため、各labのREADMEへ実測した場所を記録します。

## 検証の段階

Unreal Engine labは、可能な範囲で次の順序で検証します。

1. **pure C++ / signal processing test**: WorldやEditorを必要としない計算
2. **Automation Test**: UObject、設定、asset、決定的な実験条件
3. **PIE数値検証**: Actor、Listener、Audio Mixer、rendered PCM、時間変化
4. **MCP観測**: PIE操作、world状態、ログ、スクリーンショット
5. **実機確認**: 聴感、操作感、analog入力、長時間挙動

成功条件は段階ごとに分けます。たとえば音声研究では、event detection、左右判定、clip抽出、聴感を
一つの合否へまとめません。

labのdefault taskは、できるだけ次を自動実行します。

- `tests/assets/`を使う場合のdownload
- project構成と必要pluginの確認
- Editor targetのbuild
- 対象Automation Test
- 保存済みresultの検証
- path・機密情報・重い生成物の混入確認

Editorや実機を必要とする任意検証は別taskに分け、READMEに前提と終了条件を記録します。

## README に記録する事項

- Unreal Engine versionとrevision
- OS、chip、Xcodeまたはcompiler version
- 有効にしたpluginと、必須・任意の区別
- project生成方法と、Blank templateから加えたもの
- MCP endpoint、使用した主要tool、MCPで確認できなかった範囲
- 入力assetのrevision、license、準備手順
- build、Editor起動、Automation Test、PIEの再現手順
- 実験条件、seed、試行回数
- 観測事実と解釈
- crash、失敗した試行、復旧方法
- 人が確認した項目と、未確認事項

## 完了前の確認

- clean checkout相当の状態からprojectをbuildできる
- lab外のUnreal projectやmachine固有pathへ依存していない
- MCP serverが起動し、Editor状態を取得できる
- 対象Automation TestとPIE検証が完了している
- intended assetだけが変更され、PIE由来の不要な`.umap`差分がない
- `Binaries/`、`DerivedDataCache/`、`Intermediate/`、`Saved/`が追跡対象でない
- 大きなtemplate assetや生成物が追跡対象へ入っていない
- resultとREADMEから第三者が条件、結果、制約を追える
