import 'dart:io';

import 'package:test/test.dart';

/// `core/lib` is the Domain + Application layer. It must stay Pure Dart so it
/// runs under `dart test`, on the Dart VM (CLI), and in the browser.
void main() {
  const forbidden = [
    'package:flutter/',
    'package:flutter_webrtc/',
    'dart:html',
    'dart:js_interop',
    'dart:js',
    'dart:ffi',
    'dart:io',
    'dart:ui',
  ];

  test('core/lib imports no platform or UI library', () {
    final violations = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    final directive = RegExp(r'''^\s*(import|export)\s+['"]([^'"]+)['"]''');
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final uri = directive.firstMatch(lines[i])?.group(2);
        if (uri == null) continue;
        if (forbidden.any(uri.startsWith)) {
          violations.add('${file.path}:${i + 1}: $uri');
        }
      }
    }
    expect(violations, isEmpty);
  });

  test('pubspec has no runtime dependencies', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      pubspec,
      isNot(contains(RegExp(r'^dependencies:', multiLine: true))),
    );
  });
}
