import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_all_windows/webview_all_windows.dart' as wa;
import 'package:webview_flutter/webview_flutter.dart' as wf;
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:webview_platform_interface/webview_platform_interface.dart'
    as wpi;

/// One web view, whatever implements it: `webview_flutter` on macOS, iOS and
/// Android (WKWebView, Android WebView; platform views), and
/// `webview_all_windows` on Windows (WebView2, drawn as a Flutter texture),
/// which `webview_flutter` does not support. The canvas needs only these.
abstract class WebPage {
  /// [onMessage] gets what the page posts on the `SGHost` channel.
  factory WebPage({required void Function(String message) onMessage}) =>
      Platform.isWindows ? _WindowsPage(onMessage) : _FlutterPage(onMessage);

  Widget build(BuildContext context);
  Future<void> load(Uri uri);
  Future<Object> evaluate(String js);
  Future<void> run(String js);

  /// A PNG of the page, where the web view can take one itself (Windows);
  /// null where the app's native channel does it (macOS, iOS, Android).
  Future<Uint8List?> screenshot();

  /// The native web view's id for the app's channel (macOS, iOS, Android).
  int? get nativeId;

  void dispose();
}

class _FlutterPage implements WebPage {
  _FlutterPage(void Function(String) onMessage) {
    // Pages may play sound without a tap first (WebKit asks for one by
    // default: NotSupportedError from Audio.play()).
    _c = wf.WebViewController.fromPlatformCreationParams(
      Platform.isMacOS || Platform.isIOS
          ? WebKitWebViewControllerCreationParams(
              mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
            )
          : const wf.PlatformWebViewControllerCreationParams(),
    )..setJavaScriptMode(wf.JavaScriptMode.unrestricted);
    // A transparent background is not implemented for macOS's web view
    // (UnimplementedError: opaque); the page paints its own.
    if (!Platform.isMacOS) _c.setBackgroundColor(const Color(0x00000000));
    switch (_c.platform) {
      case final AndroidWebViewController android:
        // Android WebView also asks for a tap before a page may play sound.
        android.setMediaPlaybackRequiresUserGesture(false);
        nativeId = android.webViewIdentifier;
      case final WebKitWebViewController webkit:
        nativeId = webkit.webViewIdentifier;
    }
    _c.addJavaScriptChannel(
      'SGHost',
      onMessageReceived: (m) => onMessage(m.message),
    );
  }

  late final wf.WebViewController _c;

  @override
  int? nativeId;

  @override
  Widget build(BuildContext context) => wf.WebViewWidget(controller: _c);

  @override
  Future<void> load(Uri uri) => _c.loadRequest(uri);

  @override
  Future<Object> evaluate(String js) => _c.runJavaScriptReturningResult(js);

  @override
  Future<void> run(String js) => _c.runJavaScript(js);

  @override
  Future<Uint8List?> screenshot() async => null;

  @override
  void dispose() {}
}

class _WindowsPage implements WebPage {
  _WindowsPage(void Function(String) onMessage) {
    _c = wa.WindowsWebViewController(
      const wa.WindowsWebViewControllerCreationParams(
        mediaPlaybackPolicy:
            wpi.WebViewMediaPlaybackPolicy.allowWithoutUserGesture,
      ),
    );
    _widget = wa.WindowsWebViewWidget(
      wa.WindowsWebViewWidgetCreationParams(controller: _c),
    );
    _c.setJavaScriptMode(wpi.JavaScriptMode.unrestricted);
    _c.addJavaScriptChannel(
      wpi.JavaScriptChannelParams(
        name: 'SGHost',
        onMessageReceived: (m) => onMessage(m.message),
      ),
    );
  }

  late final wa.WindowsWebViewController _c;
  late final wa.WindowsWebViewWidget _widget;

  @override
  int? get nativeId => null;

  @override
  Widget build(BuildContext context) => _widget.build(context);

  @override
  Future<void> load(Uri uri) => _c.loadRequest(wpi.LoadRequestParams(uri: uri));

  @override
  Future<Object> evaluate(String js) => _c.runJavaScriptReturningResult(js);

  @override
  Future<void> run(String js) => _c.runJavaScript(js);

  @override
  Future<Uint8List?> screenshot() => _c.takeScreenshot();

  @override
  void dispose() => _c.dispose();
}
