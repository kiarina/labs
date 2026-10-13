import 'dart:io';

import 'package:agent_orchestrator/rpc/rpc_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the sidecar: the variable, or else found above the app', () {
    final root = Directory.systemTemp.createTempSync('lab');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/sidecar/src/main.ts').createSync(recursive: true);
    final exe =
        '${root.path}/app/build/macos/Build/Products/Debug/x.app/Contents/MacOS/x';
    expect(sidecarDir({'CLAUDE_FLUTTER_SIDECAR': '/set'}, exe), '/set');
    expect(sidecarDir(const {}, exe), '${root.path}/sidecar');
    expect(sidecarDir(const {}, '/nowhere/x.app/Contents/MacOS/x'), isNull);
  });
}
