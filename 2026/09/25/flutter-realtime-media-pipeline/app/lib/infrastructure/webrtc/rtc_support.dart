import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:realtime_core/realtime_core.dart';

/// Rendering path, kept apart from the processing path: the UI asks an
/// adapter for a stream to preview; the pipeline never sees it.
abstract interface class VideoPreviewSource {
  ValueListenable<MediaStream?> get previewStream;
}

/// Adapter-specific facts for the lab report (which stats fields existed).
abstract interface class AdapterDiagnostics {
  Map<String, Object?> get diagnostics;
}

/// No STUN/TURN: the lab runs in one process or on one LAN.
const Map<String, dynamic> peerConfiguration = {
  'iceServers': <Map<String, dynamic>>[],
  'sdpSemantics': 'unified-plan',
};

Future<RTCPeerConnection> newPeerConnection() =>
    createPeerConnection(peerConfiguration);

/// Converts platform exceptions (PlatformException, DOMException, ...) into
/// Pure Dart failures. Matching is textual because each platform throws a
/// different type.
MediaFailure toMediaFailure(Object error) {
  final text = '$error';
  final lower = text.toLowerCase();
  if (lower.contains('notallowed') ||
      lower.contains('permission') ||
      lower.contains('denied')) {
    return PermissionDeniedFailure(text);
  }
  if (lower.contains('notfound') ||
      lower.contains('not found') ||
      lower.contains('overconstrained') ||
      lower.contains('no device')) {
    return DeviceNotFoundFailure(text);
  }
  if (lower.contains('notsupported') || lower.contains('unimplemented')) {
    return UnsupportedFeatureFailure(text);
  }
  return UnknownMediaFailure(text);
}

List<Map<String, Object?>> statsToMaps(List<StatsReport> reports) => [
  for (final r in reports)
    {
      for (final e in r.values.entries) '${e.key}': e.value,
      'id': r.id,
      'type': r.type,
    },
];

Map<String, dynamic> userMediaConstraints(MediaSourceConfig config) => {
  'audio': config.audioEnabled
      ? (config.audioDeviceId == null
            ? true
            : {'deviceId': config.audioDeviceId})
      : false,
  'video': config.videoEnabled
      ? {
          if (config.videoDeviceId != null) 'deviceId': config.videoDeviceId,
          'width': {'ideal': 1280},
          'height': {'ideal': 720},
          'frameRate': {'ideal': 30},
        }
      : false,
};

/// getUserMedia with failures converted to [MediaException].
Future<MediaStream> captureUserMedia(MediaSourceConfig config) async {
  try {
    return await navigator.mediaDevices.getUserMedia(
      userMediaConstraints(config),
    );
  } catch (e) {
    throw MediaException(toMediaFailure(e));
  }
}

Future<void> stopStream(MediaStream? stream) async {
  if (stream == null) return;
  for (final track in stream.getTracks()) {
    await track.stop();
  }
  await stream.dispose();
}
