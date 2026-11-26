# Flutter のアプリに WebView を埋め込む

Flutter のアプリの画面の一部に WebView を置き、ページへ素材を渡す・ページとやり取りする・操作を速く感じさせるときの手順と落とし穴。
2026-11-26 の [spirit-canvas](../2026/11/26/spirit-canvas/README.md)（macOS、`webview_flutter` 4.14.1、WKWebView）で実際に確かめた内容で、
iOS（Simulator）と Android（Pixel 6）は下の「iOS と Android で違うところ」で確かめた。Windows は下の「Windows」で確かめた。別の OS や WebView で反証が出たら、この文書を直す。

## 置き方: 縮める枠の中に入れない

**WebView を `FittedBox`・`Transform` で縮めた中に置くと、見た目は縮むが、クリックは縮める前の位置で届く。**
WebView はプラットフォームのビューで、ネイティブのビューは縮める前の大きさのまま置かれる。
1280x800 の舞台を窓に合わせて縮めた中に置いたとき、窓の (400, 400) のクリックがページの (398, 323) に届いた（見た目どおりなら、およそ (663, 538)）。
アクセシビリティの座標も見た目とずれる。JS からボタンを押す試験では気づけない。

- WebView だけを縮める枠の外に出し、窓の上の実際の位置と大きさ（舞台の座標 × 縮みの割合）で `Positioned` に置く
- ページの中の座標を舞台に合わせたいなら、同じ割合の CSS `zoom` を `document.documentElement` にかける
- その結果、WebView は舞台の Flutter の要素より手前に出る。上に重ねたいもの（字幕・VRM の体など）は、下の「WebView の上に重ねる」のとおり WebView より後ろに別の層として置く。`Opacity`・回転・拡大は WebView には効かせられない
- macOS の WebView は透明な背景に対応していない（`setBackgroundColor` が `UnimplementedError: opaque`）。ページが自分の背景を塗る
- `RepaintBoundary.toImage` の撮影に WebView は写らない。各 WebView に自分を撮らせて重ねる（下の「撮影」）。撮れない OS では、ページの本文や状態を JS で取って渡す
- 窓をしまうと Flutter はフレームを描かない。`WidgetsBinding.instance.endOfFrame` を待つ処理は返らなくなるので、時間の上限を付ける。しまったまま足した WebView は、窓を戻すまで作られない
- 決まった大きさの画面を縮めて見せるとき、ページの CSS の `@media` は縮めた WebView の実際の幅で効く（`zoom` ではページから見える幅は変わらない）

## 素材の渡し方: ループバックの HTTP サーバー

ページから手元のファイル（画像・音・動画）を使わせるには、アプリの中にループバック（`127.0.0.1`、ポートは OS 任せ）だけの HTTP サーバーを立て、ページもそこから配る。
独自の URL スキーム（`asset://` など）を使いたいときは、配る前の HTML と、ページが後から足す要素（`src`・`href`・`poster`・`style`、`fetch`、`new Audio`）の両方でサーバーの URL に書き換える。
後者は、ページの先頭に入れる小さな JS の `MutationObserver` と関数の包み直しで行う。WebView の独自スキームの仕組みに頼らないので、WebView の種類を選ばない。

**音声と動画は、HTTP の Range に答えないと再生できない。** WebKit は部分取得で読むので、`206 Partial Content` を返さないと
`Audio.play()` が `NotSupportedError: The operation is not supported.` で失敗する。`Accept-Ranges: bytes` と `Content-Range` を返す。
WebKit の「利用者の操作なしの再生を止める」設定（`WebKitWebViewControllerCreationParams.mediaTypesRequiringUserAction`）を空にしても、この失敗は直らない。
ページが操作なしで鳴らすなら、その設定も空にしておく。

## 撮影

`webview_flutter_wkwebview` は撮る口を持たないが、ページの裏の WKWebView を取り出す公開の口がある。
Dart の `WebKitWebViewController.webViewIdentifier` を、アプリの Swift で `FWFWebViewFlutterWKWebViewExternalAPI.webView(forIdentifier:withPluginRegistry:)` に渡し、
`WKWebView.takeSnapshot(with:)`（`afterScreenUpdates = true`）で PNG にして MethodChannel で返す。Flutter の撮影の上の同じ場所に描けば 1 枚になる。
**窓が他の窓の後ろにあっても、しまってあっても撮れた**（ページの中の変更も反映された。0.6 秒）。OS の窓の撮影では、後ろの窓の WebView は黒く写る。
Android は `AndroidWebViewController.webViewIdentifier` を、アプリの Kotlin（`MainActivity.configureFlutterEngine`）で `WebViewFlutterAndroidExternalApi.getWebView(flutterEngine, id)` に渡し、
`webView.draw(Canvas(bitmap))` で PNG にする。**ただし Android の `draw` は最後に描いた絵を写す。** アプリが裏にある間のページの変化は写らず、前面に戻すと写った（Pixel 6）。

## ページとのやり取り

`webview_flutter` の 3 つの口だけで足りる。どの WebView にもある口なので、別の WebView へ差し替えやすい。

| 向き | 口 |
| --- | --- |
| ページ → アプリ | JavaScript channel（`addJavaScriptChannel`）。ページは `チャンネル名.postMessage(JSON 文字列)` |
| アプリ → ページ | `runJavaScriptReturningResult`。WKWebView は文字列を返す。値は `JSON.stringify` で包んで返させ、例外も JSON にする |
| 状態 | ページが状態をチャンネルで送ってアプリが持つと、JS を走らせずに読める |

## 操作を速く感じさせる（ページの作り）

- **叩く・押すゲームの操作は `pointerdown` で受ける。** `click` は離したときに起きるので、押してから離すまでの分だけ遅れて感じる。
  キーボード（Enter・Space）でも押せるようにするなら、`click` の `event.detail === 0`（ポインターなしのクリック）も受ける
- **効果音は Web Audio で、先に `fetch` と `decodeAudioData` で展開しておく。** 鳴り始めは出力の遅れだけ（WKWebView で `outputLatency` 16 ms）。
  `<audio>` を使い回すと、`src` を差し替えるたびに読み直しになり、鳴り始めまで 56〜171 ms かかった。`<audio>` の出力の経路そのものの遅れは、ページの中からは測れない
- BGM のように長く鳴らし続ける音は `<audio>` でよい

## WebView の上に重ねる

スライドのページの上に VRM の体や字幕を重ねる（spirit-canvas の Part 9）。macOS・iOS（Simulator）・Android（Pixel 6）・Windows で、実際の画面で重なった。

- `Stack` で WebView より後ろ（手前に描かれる側）に、舞台と同じ位置・同じ縮み方の層をもう 1 枚置き、重ねたい要素だけをそこへ描く。プラットフォームのビューの上にも Flutter は描ける
- クリックを下のページへ通したい要素は `IgnorePointer` で包む。Android では、体・字幕の上の実際のタップ（`adb shell input tap`）がページの `pointerdown` に届いた。ほかの OS の実際のクリックは未確認
- `RepaintBoundary.toImage` の撮影は、その層を別に撮り、WebView の絵の上に重ねる
- 同じ id・同じ HTML の WebView を消してすぐ置き直すと、ウィジェットが使い回されて前のページの状態が残った。置き直した（新しい要素の）ときは読み込み直す

## iOS と Android で違うところ

2026-11-26 に iOS Simulator（iOS 27.2）と Pixel 6 で確かめた。

- ループバックの HTTP を読ませるには、iOS は `Info.plist` の `NSAppTransportSecurity` に `NSAllowsLocalNetworking`、Android は `INTERNET` の許可と `android:usesCleartextTraffic="true"` が要る
- Android WebView も、既定では利用者の操作なしの再生を止める。`AndroidWebViewController.setMediaPlaybackRequiresUserGesture(false)`
- `runJavaScriptReturningResult` の文字列は、Android ではもう一段 JSON の引用符で包まれて返る（WKWebView は包まない）
- iOS の WebKit では、JS の `label.click()` で中のチェックボックスが切り替わらなかった（`input.click()` と実際のタップは切り替わる）
- 撮影: iOS は macOS と同じ Swift を AppDelegate（`FlutterImplicitEngineDelegate` の `didInitializeImplicitFlutterEngine` で、`pluginRegistry.registrar(forPlugin:)` から MethodChannel を作る）に置けば動いた。外部 API は `webView(forIdentifier:withPluginRegistrar:)`

## Windows

`webview_flutter` は Windows に対応していないので、Windows だけ `webview_all_windows`（WebView2。`webview_platform_interface` の API）を使い、
両方を小さな型の裏に隠すのが楽だった（spirit-canvas の `lib/canvas/web_page.dart`）。必要な口（読み込み・JavaScript channel・JS の実行）はどちらにもある。

- WebView2 の版は Flutter のテクスチャとして描く（プラットフォームのビューではない）ので、縮めた枠の中のクリックのずれは起きない作りのはず（未確認）
- 撮影は `WindowsWebViewController.takeScreenshot()` が PNG を返す（ネイティブのコードは要らない）。窓が前面でなくても撮れたが、**最小化の間は返らない**（打ち切りが要る）。最後に撮れた絵と時刻を残しておき、古いと断って使うとよい
- ループバックの HTTP、`asset://` の書き換え、ページの中の音（`mediaPlaybackPolicy: allowWithoutUserGesture`）はそのまま動いた

## 対応する OS

`webview_flutter`（公式）は Android・iOS・macOS だけで、Windows に対応していない（4.14.1、2026-11 時点）。
Windows では `webview_all_windows`（WebView2、2026-11 の版）で動いた（上の「Windows」）。2024 年で更新の止まった `webview_windows` は試していない。
`flutter_inappwebview` は独自スキームなどの口が多いが、2024 年 10 月から更新が止まっている。
