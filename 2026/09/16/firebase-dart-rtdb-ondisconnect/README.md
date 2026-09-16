# firebase_dart で RTDB の onDisconnect による presence は成り立つか

Flutter 公式の Firebase プラグイン（FlutterFire）は Linux デスクトップに対応していません。
そこで、純 Dart 実装の [`firebase_dart`](https://pub.dev/packages/firebase_dart) を使えば、
Realtime Database（RTDB）の `onDisconnect` を使った presence（オンライン状態の管理）を
macOS と Linux で同じ形に作れるかを確かめます（2026-09-16）。

判断材料を集めるための検証です。Firebase Emulator だけを相手にしており、本番の
Firebase には接続していません。

## 目的と問い

- `onDisconnect` の予約は、正常終了・プロセス強制終了・回線断のそれぞれで、サーバー側の
  presence を offline に戻すか
- 回線が戻ったとき、`.info/connected` を起点に予約をかけ直す実装で自動的に online へ戻るか。
  切断を繰り返しても状態が壊れないか
- 無応答の回線（通信は止まっているが TCP は切れていない half-open）を、クライアントと
  サーバーは検知できるか
- 認証セッションはディスクへ保存され、再起動後にネットワーク越しのログインなしで
  復元されるか。ID token を更新した後も RTDB へ書き込めるか
- 以上が macOS と Linux で同じように動くか

## 前提として確認したこと（コードと pub.dev）

- `firebase_dart` 1.6.2 が対応するのは Authentication、Realtime Database、Cloud Storage。
  **Cloud Firestore には対応していない**（パッケージの説明文と README）
- Google ログインのような popup / redirect 系の認証（`signInWithPopup` /
  `signInWithRedirect` / `signInWithAuthProvider`）は README で未対応とされている
- `onDisconnect` の予約はクライアント側で 1 回だけ実行済みとして扱われ、再接続時に
  自動では再送されない。公式 SDK と同じく、`.info/connected` が true になるたびに
  アプリがかけ直す必要がある（`repo.dart` の `_runOnDisconnectEvents`）
- 45 秒ごとに keepalive フレームを送るが、応答を待つ ping はなく、
  `WebSocket` の `pingInterval` も設定していない（`connection.dart`、`websocket_io.dart`）
- Emulator へ接続する API（`useDatabaseEmulator` / `useAuthEmulator` 相当）はない

## 構成

| ファイル | 役割 |
|---|---|
| `bin/client.dart` | presence クライアント。サインイン（または保存済みセッションの復元）、`.info/connected` ごとに `onDisconnect().set(offline)` → `set(online)` の順で登録、stdin のコマンドで正常終了・token 更新・死活監視などを行う |
| `bin/scenarios.dart` | クライアントを子プロセスとして起動し、TCP プロキシで回線断を再現しながら、REST（emulator の owner 権限）で `/presence/{uid}` を 100 ms 間隔で観測する |
| `database.rules.json` | `/presence/$uid` を本人だけが読み書きできるルール |
| `Dockerfile` | Linux 用に AOT コンパイルしたバイナリを `scratch` イメージに入れる |

正常終了では、spirits-garden の presence で踏んだ落とし穴に合わせて、offline の書き込みを
先に、`onDisconnect` の取り消しを最後に行い、その後 `goOffline()` します。

### Emulator を使うための工夫（本番との差分）

1. **Auth の通信先**: `firebase_dart` には Emulator 用の設定がないため、`FirebaseDart.setup`
   に渡す `http.Client` で `identitytoolkit.googleapis.com` / `securetoken.googleapis.com` への
   通信を Auth Emulator へ向け直した
2. **ID token の署名**: Auth Emulator は未署名（`alg: none`）の ID token を返す。
   `firebase_dart` は Google の JWKS で署名を検証するため、そのままでは
   `Unable to verify token` で失敗する。上の `http.Client` で、Emulator の token を
   使い捨ての RS256 鍵で署名し直し、その公開鍵を JWKS として返した。claims は変えていない。
   RTDB Emulator は署名を検証しないので、差し替えたのは署名の検証だけ
3. **接続先ホストの書き換え**: RTDB は接続時の handshake で接続先ホスト（`h`）を返し、
   クライアントは以後そこへ直接再接続する。Emulator は接続元に関係なく自分の設定値
   `127.0.0.1:9000` を返すため、そのままではプロキシを迂回してしまう。プロキシで
   handshake の `h` を同じ長さの `127.0.0.1:9001` へ書き換えた（全接続で書き換えを確認）
4. **名前空間**: `singleProjectMode` の Database Emulator はルールを `demo-lab-default-rtdb` に
   読み込む。最初は `ns=demo-lab` へ接続していて、ルールが効かずに他人の uid へ書き込めて
   いた。名前空間を合わせてから、他人の uid への書き込みが拒否されることを確認した

## シナリオ

| ID | 内容 | 見るもの |
|---|---|---|
| S1 | 初回サインイン → online → 他人の uid へ書き込み → 正常終了 | ルールの拒否、正常終了から offline 反映までの時間 |
| S2 | 再起動 → token 更新 → 書き込み → `SIGKILL` | セッション復元、ログイン API の呼び出し回数、強制終了から offline までの時間 |
| S3 | プロキシで接続を切断し、3 秒間は新規接続も拒否 → 受け入れ再開 | サーバー / クライアントが切断に気づくまでの時間、受け入れ再開から online 復帰までの時間 |
| S4a | 既存接続の転送だけを 90 秒止める（half-open） | 90 秒以内に誰かが気づくか |
| S4b | S4a と同じ状況で、アプリ側に死活監視を入れる | 検知時間、新しい接続での再登録、古い接続を後から閉じたときに online が上書きされるか |
| S5 | 接続切断を 10 回繰り返す | 毎回 offline / online になるか、登録エラー、最終状態 |
| S6 | 回線が切れた状態で正常終了を試みる | 正常終了が完了するか |

S4b の死活監視は、5 秒ごとに `/presence/{uid}/beat` へ `ServerValue.timestamp` を書き込み、
5 秒以内に完了しなければ `goOffline()` → `goOnline()` で再接続させるものです。
S4b ではサーバー側の古い接続を開いたままにし、クライアントが新しい接続で再登録した後に閉じます。

## 実行方法

```sh
# macOS（または Linux の実機）: emulator を起動して全シナリオを実行する
mise -C 2026/09/16/firebase-dart-rtdb-ondisconnect run

# Linux コンテナ: 先に別の端末で emulator を起動しておく
firebase emulators:start --only auth,database --project demo-lab
mise -C 2026/09/16/firebase-dart-rtdb-ondisconnect run linux
```

`BLACKHOLE_SECONDS`（既定 90）と `FLAPS`（既定 10）で S4a の時間と S5 の回数を変えられます。
全体の所要時間は約 4 分です。

## 実行環境

- MacBook Pro（Apple M1 Max、64 GB）、macOS 26.6.2
- Linux: Docker Desktop 29.8.0 の linux/arm64 コンテナ（kernel 7.0.12-linuxkit）。
  Emulator は macOS 側で動かし、`host.docker.internal` 経由で接続した
- Dart 3.11.0（macOS は `dart compile exe`、Linux は `dart:3.11.0` イメージでコンパイル）
- firebase_dart 1.6.2、http 1.6.0、jose 0.3.5+2、openid_client 0.4.10+2、
  web_socket_channel 3.0.3
- firebase-tools 13.2.1、Database Emulator 4.11.2、OpenJDK 11.0.32.1

## 結果

生データは [`results/darwin-arm64.json`](results/darwin-arm64.json) と
[`results/linux-arm64-docker.json`](results/linux-arm64-docker.json) です。
時間は各シナリオ 1 回の実測値で、観測の間隔は 100 ms（S4a は 250 ms）です。

| 項目 | macOS | Linux |
|---|---|---|
| S1 他人の uid への書き込みを拒否 | ✅ | ✅ |
| S1 正常終了の所要時間 / offline 反映 | 11 ms / 14 ms | 11 ms / 15 ms |
| S2 保存済みセッションの復元（ログイン API 呼び出し 0 回） | ✅ | ✅ |
| S2 token 更新後の書き込み | ✅ | ✅ |
| S2 `SIGKILL` から offline まで | 6 ms | 8 ms |
| S3 切断からサーバーが offline にするまで / クライアントが気づくまで | 2 ms / 2 ms | 2 ms / 2 ms |
| S3 受け入れ再開から online 復帰まで | 1,376 ms | 186 ms |
| S4a 90 秒間の half-open をサーバーが検知 | ❌ 検知せず（online のまま） | ❌ 同左 |
| S4a 90 秒間の half-open をクライアントが検知 | ❌ 検知せず | ❌ 同左 |
| S4b 死活監視による検知 / 再登録 | 9,002 ms / 9,020 ms | 9,002 ms / 9,064 ms |
| S4b 古い接続を閉じた後に online が上書きされたか | されなかった（最終状態 online） | 同左 |
| S5 10 回の切断で offline / online を観測 | 10 / 10 | 10 / 10 |
| S5 登録エラー / 最終状態 | 0 / online | 0 / online |
| S6 回線断の状態での正常終了 | 15 秒待っても完了せず | 同左 |

S3 の復帰時間は、`firebase_dart` の再接続バックオフのどの時点で受け入れを再開したかで変わります。
S5 で切断から再接続までにかかった時間は、回を重ねるごとに伸びました（ログの時刻から読んだ値で、
JSON には記録していません）。

| 回 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|---|---|
| macOS（秒） | 1.21 | 1.53 | 1.76 | 2.06 | 2.72 | 4.78 | 3.31 | 4.46 | 9.54 | 11.56 |
| Linux（秒） | 0.78 | 1.63 | 1.35 | 1.62 | 2.58 | 3.54 | 5.67 | 5.65 | 8.39 | 7.32 |

実装（`retry_helper.dart`、`persistent_connection.dart`）では、30 秒未満で切れた接続は
失敗として扱われ、再接続の待ち時間が 1 秒から 1.3 倍ずつ伸びます（上限 30 秒、
待ち時間の 50〜100% の範囲でランダム）。S5 は切断の間隔が 30 秒より短いため、この伸びが
そのまま表れたと考えられます。

開発中の試行では、次の結果も出ています（修正後の本番値ではありません）。

- 手順 3 の書き換え前は、再接続がプロキシを迂回し、S4a / S5 が意味をなさなかった
- 手順 4 の修正前は、ルールが効かず他人の uid への書き込みが成功した
- S4b で古い接続もプロキシが閉じてしまう実装では、サーバー側に古い接続が残らず、
  上書きの有無を確かめられていなかった。最終結果は古い接続を 1 本残した状態で取った

## 解釈

- **`onDisconnect` 自体は安定して動いた。** 正常終了、強制終了、TCP の切断のいずれでも
  数 ms で offline になり、`.info/connected` 起点でかけ直す実装で 10 回の切断すべてから
  自動で online に戻った。macOS と Linux で挙動の差はなかった
- **認証の保存と復元も Linux で使える。** `storagePath` に保存したセッションで、再起動後に
  ログイン API を呼ばずに復元でき、token 更新後も RTDB のルールを通過した
- **half-open の回線は、アプリ側で監視しないと検知できない。** クライアントは keepalive を
  送るだけで応答を確かめないため、転送だけが止まった回線では 90 秒たっても
  `.info/connected` は true のままだった。書き込みにタイムアウトを付けて再接続させる
  監視を入れると、「監視間隔 + タイムアウト」程度（今回は約 9 秒）で新しい接続に移れた。
  実際のネットワークでは、送信データに ACK が返らなければ OS の TCP 再送タイムアウトで
  いずれ切れると考えられるが、その時間（Linux の既定では十数分になりうる）は今回測っていない
- **正常終了の処理にはタイムアウトが必要。** `set()` はサーバーの応答まで完了しないため、
  回線断の状態では正常終了が終わらない。この場合でもサーバー側は `onDisconnect` で
  offline になっていたので、一定時間で諦めて終了してよい
- **古い接続による上書きは、Emulator では起きなかった。** 新しい接続で再登録した後に
  古い接続を閉じても、online は上書きされなかった。原因は確かめていないが、再接続時に
  前回のセッション ID（`ls`）を送る仕組みで、サーバーが古いセッションを処理している
  可能性がある。本番のサーバーも同じ挙動かは未確認のため、本番では接続ごとに
  別のキーへ書く（`connections/{id}` のような形）ほうが安全

## 結論が成り立つ範囲と未確認事項

- **Emulator だけで確認した。** 本番 RTDB での half-open の検知、古い接続の扱い、
  handshake でのホスト切り替えは、Emulator と違う可能性がある
- **署名の検証を差し替えている。** 本番の Google 署名付き token を `firebase_dart` が
  検証できるかは確かめていない（通常の利用経路なので問題ない見込みだが、未実測）
- **Linux はコンテナの CLI で確認した。** Flutter の Linux デスクトップアプリ上
  （`firebase_dart_flutter`）では動かしていない
- **Linux でのログイン手段は未検証。** Google ログインは `firebase_dart` の README で未対応と
  されており、ブラウザ経由の OAuth などを別に作る必要がある。今回はメールアドレスと
  パスワードでログインした
- **ID token の自然な期限切れ（1 時間）は待っていない。** 更新は強制更新で確かめた
- **Cloud Firestore は使えない。** Firestore のリアルタイム購読が必要な設計では、
  別の手段が要る
- 各シナリオは 1 回ずつの実行で、時間のばらつきは評価していない
