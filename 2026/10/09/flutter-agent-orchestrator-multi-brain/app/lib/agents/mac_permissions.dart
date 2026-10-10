import 'dart:io';

import 'package:flutter/services.dart';

/// This app's macOS privacy permissions (Screen Recording, Accessibility),
/// through the runner's `orchestrator/permissions` channel. Workers run as
/// this app's children, so what they do in the shell (`screencapture`, an
/// AppleScript that clicks) asks macOS on this app's behalf.
class MacPermissions {
  const MacPermissions();

  static const _channel = MethodChannel('orchestrator/permissions');

  /// `{accessibility: bool, screenRecording: bool}`, or null off macOS (and
  /// in tests).
  Future<Map<String, bool>?> status() async {
    try {
      final r = await _channel.invokeMethod<Map>('status');
      return r?.cast<String, bool>();
    } on MissingPluginException {
      return null;
    }
  }

  /// macOS's dialog that leads to System Settings (shown once per app).
  Future<void> requestAccessibility() => _call('requestAccessibility');

  /// Adds this app to Screen Recording and shows macOS's dialog (once). The
  /// grant takes effect after a restart ([relaunch]).
  Future<void> requestScreenRecording() => _call('requestScreenRecording');

  /// System Settings › Privacy & Security at [pane]
  /// (`Privacy_Accessibility`, `Privacy_ScreenCapture`).
  Future<void> openSettings(String pane) => _call('openSettings', pane);

  Future<void> _call(String method, [Object? arg]) async {
    try {
      await _channel.invokeMethod<void>(method, arg);
    } on MissingPluginException {
      // Not on macOS.
    }
  }

  /// Starts this app again with the same settings and quits. `open` would
  /// hand over the caller's environment, and macOS's own relaunch (after a
  /// permission change) drops it: pass on what the app reads.
  Future<Never> relaunch() async {
    final env = Platform.environment;
    final forward = {
      ...(env['ORCH_FORWARD_ENV'] ?? '').split(RegExp(r'\s+')).where((n) => n.isNotEmpty),
    };
    bool keep(String k) =>
        k.startsWith('ORCH_') ||
        k.startsWith('KIAPI_') ||
        forward.contains(k) ||
        const {'CLAUDE_FLUTTER_SIDECAR', 'NODE_BIN', 'CODEX_BIN', 'PEEKABOO_BIN'}.contains(k);
    // .../agent_orchestrator.app/Contents/MacOS/agent_orchestrator
    final bundle = File(Platform.resolvedExecutable).parent.parent.parent.path;
    await Process.start(
      '/usr/bin/env',
      [
        '-i',
        'HOME=${env['HOME']}',
        'USER=${env['USER']}',
        'LOGNAME=${env['USER']}',
        'PATH=/usr/bin:/bin:/usr/sbin:/sbin',
        '/usr/bin/open',
        '-n',
        for (final e in env.entries)
          if (keep(e.key)) ...['--env', '${e.key}=${e.value}'],
        bundle,
      ],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
}
