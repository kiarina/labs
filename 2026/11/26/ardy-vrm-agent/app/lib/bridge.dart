import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

/// Serves the built bridge page (web/dist) on loopback only.
class LoopbackServer {
  LoopbackServer(this.root);

  final String root;
  HttpServer? _server;

  Uri get origin => Uri.parse('http://127.0.0.1:${_server!.port}/');

  static const _types = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.mjs': 'text/javascript; charset=utf-8',
    '.wasm': 'application/wasm',
    '.json': 'application/json',
  };

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) async {
      final response = request.response;
      var path = Uri.decodeComponent(request.uri.path);
      if (path.endsWith('/')) path = '${path}index.html';
      final file = File('$root$path');
      if (path.contains('..') || !await file.exists()) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final dot = path.lastIndexOf('.');
      response.headers
        ..set('Content-Type',
            _types[dot < 0 ? '' : path.substring(dot)] ?? 'application/octet-stream')
        ..set('Cache-Control', 'no-store');
      await response.addStream(file.openRead());
      await response.close();
    });
  }

  Future<void> close() async => _server?.close(force: true);
}

/// The WebView that runs ARDY Mini, and its message channel.
class ArdyBridge {
  ArdyBridge(this.pageUrl);

  final Uri pageUrl;
  late final WebViewController controller;
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get events => _events.stream;

  void create() {
    final params = WebKitWebViewControllerCreationParams(
      mediaTypesRequiringUserAction: const {},
    );
    controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'ArdyHost',
        onMessageReceived: (m) {
          try {
            _events.add((jsonDecode(m.message) as Map).cast<String, dynamic>());
          } catch (e) {
            debugPrint('[bridge] bad message: $e');
          }
        },
      )
      ..loadRequest(pageUrl);
    if (controller.platform case final WebKitWebViewController wk) {
      wk.setInspectable(true);
    }
  }

  /// Sends a command to the page; returns its synchronous reply.
  Future<Map<String, dynamic>> command(Map<String, dynamic> command) async {
    final arg = jsonEncode(jsonEncode(command));
    final raw = await controller.runJavaScriptReturningResult(
      'window.ardyBridge.command($arg)',
    );
    var text = raw is String ? raw : '$raw';
    // Some platforms wrap the returned string in one more JSON layer.
    if (text.startsWith('"')) text = jsonDecode(text) as String;
    return (jsonDecode(text) as Map).cast<String, dynamic>();
  }
}
