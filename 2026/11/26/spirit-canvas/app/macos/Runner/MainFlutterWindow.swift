import Cocoa
import FlutterMacOS
import WebKit
import webview_flutter_wkwebview

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    WebViewSnapshot.register(with: flutterViewController)

    super.awakeFromNib()
  }
}

/// Pictures of the `web` elements' pages, for the spirit's canvas_view: a
/// web view is a platform view, so Flutter's own capture of the canvas
/// leaves it out. The page's WKWebView comes from webview_flutter_wkwebview's
/// external API (`WebKitWebViewController.webViewIdentifier` on the Dart
/// side) and renders itself with `takeSnapshot`.
enum WebViewSnapshot {
  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "spirit_canvas/webview",
      binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "snapshot",
        let args = call.arguments as? [String: Any],
        let id = args["id"] as? NSNumber
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let web = FWFWebViewFlutterWKWebViewExternalAPI.webView(
          forIdentifier: id.int64Value, withPluginRegistry: controller)
      else {
        result(FlutterError(code: "no_webview", message: "no web view \(id)", details: nil))
        return
      }
      let config = WKSnapshotConfiguration()
      config.afterScreenUpdates = true
      web.takeSnapshot(with: config) { image, error in
        guard let image = image,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
        else {
          result(
            FlutterError(
              code: "snapshot_failed",
              message: error?.localizedDescription ?? "no image", details: nil))
          return
        }
        result(FlutterStandardTypedData(bytes: png))
      }
    }
  }
}
