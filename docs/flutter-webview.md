# Flutter のアプリに WebView を埋め込む

Flutter のアプリの画面の一部に WebView を置き、ページへ素材を渡す・ページとやり取りする・操作を速く感じさせるときの手順と落とし穴。
2026-11-26 の [spirit-canvas](../2026/11/26/spirit-canvas/README.md)（macOS、`webview_flutter` 4.14.1、WKWebView）で実際に確かめた内容で、
iOS・Android・Windows で同じになるかは未検証。別の OS や WebView で反証が出たら、この文書を直す。

## 置き方: 縮める枠の中に入れない

**WebView を `FittedBox`・`Transform` で縮めた中に置くと、見た目は縮むが、クリックは縮める前の位置で届く。**
WebView はプラットフォームのビューで、ネイティブのビューは縮める前の大きさのまま置かれる。
1280x800 の舞台を窓に合わせて縮めた中に置いたとき、窓の (400, 400) のクリックがページの (398, 323) に届いた（見た目どおりなら、およそ (663, 538)）。
アクセシビリティの座標も見た目とずれる。JS からボタンを押す試験では気づけない。

- WebView だけを縮める枠の外に出し、窓の上の実際の位置と大きさ（舞台の座標 × 縮みの割合）で `Positioned` に置く
- ページの中の座標を舞台に合わせたいなら、同じ割合の CSS `zoom` を `document.documentElement` にかける
- その結果、WebView はほかの Flutter の要素より常に手前に出る。`Opacity`・回転・拡大も WebView には効かせられない
- macOS の WebView は透明な背景に対応していない（`setBackgroundColor` が `UnimplementedError: opaque`）。ページが自分の背景を塗る
- `RepaintBoundary.toImage` の撮影に WebView は写らない。画面を誰かに見せたいときは、ページの本文や状態を JS で取って渡す

## 素材の渡し方: ループバックの HTTP サーバー

ページから手元のファイル（画像・音・動画）を使わせるには、アプリの中にループバック（`127.0.0.1`、ポートは OS 任せ）だけの HTTP サーバーを立て、ページもそこから配る。
独自の URL スキーム（`asset://` など）を使いたいときは、配る前の HTML と、ページが後から足す要素（`src`・`href`・`poster`・`style`、`fetch`、`new Audio`）の両方でサーバーの URL に書き換える。
後者は、ページの先頭に入れる小さな JS の `MutationObserver` と関数の包み直しで行う。WebView の独自スキームの仕組みに頼らないので、WebView の種類を選ばない。

**音声と動画は、HTTP の Range に答えないと再生できない。** WebKit は部分取得で読むので、`206 Partial Content` を返さないと
`Audio.play()` が `NotSupportedError: The operation is not supported.` で失敗する。`Accept-Ranges: bytes` と `Content-Range` を返す。
WebKit の「利用者の操作なしの再生を止める」設定（`WebKitWebViewControllerCreationParams.mediaTypesRequiringUserAction`）を空にしても、この失敗は直らない。
ページが操作なしで鳴らすなら、その設定も空にしておく。

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

## 対応する OS

`webview_flutter`（公式）は Android・iOS・macOS だけで、Windows に対応していない（4.14.1、2026-11 時点）。
Windows では、API 互換の `webview_all`（WebView2、2026-11 の版）か、2024 年で更新の止まった `webview_windows` を選ぶことになる。どちらもこの文書の時点では動かしていない。
`flutter_inappwebview` は独自スキームなどの口が多いが、2024 年 10 月から更新が止まっている。
