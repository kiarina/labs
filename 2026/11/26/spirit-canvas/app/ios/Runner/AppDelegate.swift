import Flutter
import UIKit
import WebKit
import webview_flutter_wkwebview

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SpiritCanvasWebSnapshot") {
      WebViewSnapshot.register(with: registrar)
    }
  }
}

/// Pictures of the `web` elements' pages (see the macOS Runner): the page's
/// WKWebView, from webview_flutter_wkwebview's external API, renders itself
/// with `takeSnapshot`.
enum WebViewSnapshot {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "spirit_canvas/webview", binaryMessenger: registrar.messenger())
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
          forIdentifier: id.int64Value, withPluginRegistrar: registrar)
      else {
        result(FlutterError(code: "no_webview", message: "no web view \(id)", details: nil))
        return
      }
      let config = WKSnapshotConfiguration()
      config.afterScreenUpdates = true
      web.takeSnapshot(with: config) { image, error in
        guard let png = image?.pngData() else {
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
