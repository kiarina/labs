import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:webview_flutter/webview_flutter.dart';

import '../media.dart';

/// Serves the `web` elements' pages and their assets on a loopback port,
/// so pages refer to media as `asset://<name>` whatever the web view is:
///
/// - `asset://` in the page's HTML is rewritten to this server's
///   `/asset/<name>` before it is served, and a small script (the `sg`
///   object, [_shim]) rewrites the ones that the page's own JavaScript adds
///   later (src, href, poster, CSS url(), fetch).
/// - The page talks to the app through the `SGHost` JavaScript channel:
///   `sg.emit(name, data, {wake})` (an event for the spirit) and
///   `sg.setState(obj)` (state the spirit can read without running code).
/// - The app runs JavaScript in the page for the spirit
///   (`canvas_web_eval`).
class WebHost {
  WebHost._();

  static final instance = WebHost._();

  HttpServer? _server;
  final _pages = <String, String>{};
  final controllers = <String, WebViewController>{};

  /// The native web view of each element (WKWebView on macOS and iOS), for
  /// pictures of the page.
  final nativeIds = <String, int>{};

  static const _native = MethodChannel('spirit_canvas/webview');

  /// A PNG of the page as it is drawn now, or null where this platform has
  /// no way here (only macOS so far) or it failed ([lastSnapshotError]).
  Future<Uint8List?> snapshot(String id) async {
    if (!Platform.isMacOS && !Platform.isIOS) {
      lastSnapshotError =
          'pictures of web views are only taken on macOS and iOS so far';
      return null;
    }
    final nativeId = nativeIds[id];
    if (nativeId == null) {
      lastSnapshotError = 'the page is not on the screen yet (the window may be minimized or hidden)';
      return null;
    }
    try {
      return await _native
          .invokeMethod<Uint8List>('snapshot', {'id': nativeId})
          .timeout(const Duration(seconds: 3));
    } on Object catch (e) {
      lastSnapshotError = '$e';
      return null;
    }
  }

  String? lastSnapshotError;

  /// The latest `sg.setState` of each page.
  final states = <String, Object?>{};

  /// Events from pages: (element id, message).
  void Function(String id, Map<String, dynamic> message)? onMessage;

  int get port => _server?.port ?? 0;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_serve);
  }

  String pageUrl(String id, int version) =>
      'http://127.0.0.1:$port/page/${Uri.encodeComponent(id)}?v=$version';

  String assetBase() => 'http://127.0.0.1:$port/asset/';

  void setPage(String id, String html) => _pages[id] = html;

  void remove(String id) {
    _pages.remove(id);
    controllers.remove(id);
    nativeIds.remove(id);
    states.remove(id);
  }

  /// The page as served: `asset://` rewritten, and the shim first in head.
  String render(String id, String html) {
    final rewritten = html.replaceAll('asset://', assetBase());
    final shim =
        '<script>${_shim.replaceAll('__ASSET_BASE__', assetBase()).replaceAll('__ID__', jsonEncode(id))}</script>';
    final head = RegExp(
      r'<head[^>]*>',
      caseSensitive: false,
    ).firstMatch(rewritten);
    if (head != null) {
      return rewritten.replaceRange(head.end, head.end, shim);
    }
    return '<!doctype html><html><head><meta charset="utf-8">$shim</head><body>$rewritten</body></html>';
  }

  Future<void> _serve(HttpRequest req) async {
    final res = req.response;
    try {
      final segs = req.uri.pathSegments;
      if (segs.length == 2 && segs[0] == 'page') {
        final html = _pages[segs[1]];
        if (html == null) {
          res.statusCode = 404;
        } else {
          res.headers.contentType = ContentType.html;
          res.write(render(segs[1], html));
        }
      } else if (segs.isNotEmpty && segs[0] == 'asset') {
        final name = segs.skip(1).join('/');
        final r =
            MediaLibrary.instance.resolve(name) ??
            switch (MediaLibrary.instance.vrmFile(name)) {
              final f? when name == 'vrm/default' => (url: null, file: f),
              _ => null,
            };
        if (r == null) {
          res.statusCode = 404;
        } else if (r.url != null) {
          res.redirect(Uri.parse(r.url!));
          return;
        } else {
          res.headers.contentType = _type(name);
          res.headers.set('Access-Control-Allow-Origin', '*');
          res.headers.set('Accept-Ranges', 'bytes');
          // WebKit reads audio and video in byte ranges; without 206
          // answers, Audio.play() fails with NotSupportedError.
          final length = await r.file!.length();
          final range = RegExp(r'bytes=(\d*)-(\d*)')
              .firstMatch(req.headers.value(HttpHeaders.rangeHeader) ?? '');
          if (range != null) {
            var start = int.tryParse(range[1]!) ?? 0;
            var end = int.tryParse(range[2]!) ?? length - 1;
            if (range[1]!.isEmpty && range[2]!.isNotEmpty) {
              start = length - end;
              end = length - 1;
            }
            end = end.clamp(0, length - 1);
            res.statusCode = HttpStatus.partialContent;
            res.headers.set('Content-Range', 'bytes $start-$end/$length');
            res.contentLength = end - start + 1;
            await res.addStream(r.file!.openRead(start, end + 1));
          } else {
            res.contentLength = length;
            await res.addStream(r.file!.openRead());
          }
        }
      } else {
        res.statusCode = 404;
      }
    } on Object catch (e) {
      res.statusCode = 500;
      res.write('$e');
    }
    await res.close();
  }

  ContentType _type(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => ContentType('image', 'jpeg'),
      'png' => ContentType('image', 'png'),
      'gif' => ContentType('image', 'gif'),
      'webp' => ContentType('image', 'webp'),
      'svg' => ContentType('image', 'svg+xml'),
      'mp4' => ContentType('video', 'mp4'),
      'mov' => ContentType('video', 'quicktime'),
      'mp3' => ContentType('audio', 'mpeg'),
      'wav' => ContentType('audio', 'wav'),
      'm4a' => ContentType('audio', 'mp4'),
      'json' => ContentType.json,
      _ => ContentType.binary,
    };
  }

  /// A message on the `SGHost` channel.
  void receive(String id, String text) {
    Map<String, dynamic> m;
    try {
      m = (jsonDecode(text) as Map).cast<String, dynamic>();
    } on Object {
      return;
    }
    if (m['type'] == 'state') {
      states[id] = m['state'];
    }
    onMessage?.call(id, m);
  }

  /// Runs [js] in the page and returns its result as text (JSON when it can).
  Future<String> eval(String id, String js) async {
    final c = controllers[id];
    if (c == null) return 'error: no web element "$id" on the canvas';
    try {
      final wrapped =
          '(function(){ try { var __r = (function(){ return eval(${jsonEncode(js)}); })(); '
          'return JSON.stringify(__r === undefined ? null : __r); } '
          'catch (e) { return JSON.stringify({error: String(e)}); } })()';
      final r = await c
          .runJavaScriptReturningResult(wrapped)
          .timeout(const Duration(seconds: 5));
      // The page returns JSON text. WKWebView hands it over as it is;
      // Android WebView quotes it once more. A string result is itself
      // quoted JSON: unwrap JSON strings, at most twice.
      var s = r is String ? r : '$r';
      for (
        var i = 0;
        i < 2 && s.length >= 2 && s.startsWith('"') && s.endsWith('"');
        i++
      ) {
        try {
          s = jsonDecode(s) as String;
        } on Object {
          break;
        }
      }
      return s;
    } on TimeoutException {
      return 'error: timed out';
    } on Object catch (e) {
      return 'error: $e';
    }
  }

  Future<void> close() async => _server?.close(force: true);
}

/// The page's side: the `sg` object, and rewriting of `asset://` that the
/// page adds later.
const _shim = r'''
(function () {
  var base = '__ASSET_BASE__';
  var id = __ID__;
  function fix(v) { return typeof v === 'string' ? v.split('asset://').join(base) : v; }
  function post(m) {
    try { SGHost.postMessage(JSON.stringify(m)); } catch (e) { console.log('SGHost missing', e); }
  }
  // The app lays the web view out at the canvas's scale: zoom the page by
  // it, so the page's CSS pixels are the canvas's (1280x800 for a full one).
  function setZoom(z) { document.documentElement.style.zoom = String(z); }
  var z0 = new URLSearchParams(location.search).get('zoom');
  if (z0) setZoom(z0);
  window.sg = {
    id: id,
    setZoom: setZoom,
    asset: function (name) { return base + name; },
    emit: function (name, data, opts) {
      post({ type: 'event', name: String(name), data: data === undefined ? null : data, wake: opts && opts.wake });
    },
    setState: function (state) { window.sg.state = state; post({ type: 'state', state: state }); },
    state: null,
    log: function () { post({ type: 'log', text: Array.prototype.join.call(arguments, ' ') }); },
  };
  window.addEventListener('error', function (e) {
    post({ type: 'error', text: String(e.message) + ' @' + e.lineno });
  });
  var attrs = ['src', 'href', 'poster', 'style'];
  function fixNode(n) {
    if (!n || n.nodeType !== 1) return;
    attrs.forEach(function (a) {
      var v = n.getAttribute && n.getAttribute(a);
      if (v && v.indexOf('asset://') >= 0) n.setAttribute(a, fix(v));
    });
    if (n.tagName === 'STYLE' && n.textContent.indexOf('asset://') >= 0) n.textContent = fix(n.textContent);
    if (n.querySelectorAll) n.querySelectorAll('*').forEach(function (c) { fixNode(c); });
  }
  new MutationObserver(function (list) {
    list.forEach(function (m) {
      if (m.type === 'attributes') fixNode(m.target);
      m.addedNodes && m.addedNodes.forEach(fixNode);
    });
  }).observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: attrs });
  var origFetch = window.fetch;
  if (origFetch) window.fetch = function (u, o) { return origFetch(fix(typeof u === 'string' ? u : u), o); };
  var origAudio = window.Audio;
  if (origAudio) window.Audio = function (src) { return new origAudio(fix(src)); };
  document.addEventListener('DOMContentLoaded', function () { fixNode(document.documentElement); });
})();
''';
