/// Cross-cutting interfaces the domain needs from the outside world.
library;

/// Monotonic time. Wall clock (`DateTime.now()`) is never used for ordering or
/// latency inside the pipeline.
abstract interface class MonotonicClock {
  Duration now();
}

final class StopwatchClock implements MonotonicClock {
  final Stopwatch _stopwatch = Stopwatch()..start();

  @override
  Duration now() => _stopwatch.elapsed;
}

abstract interface class AppLogger {
  void debug(String message);

  void info(String message);

  void warning(String message);

  void error(String message, [Object? error, StackTrace? stackTrace]);
}

final class SilentLogger implements AppLogger {
  const SilentLogger();

  @override
  void debug(String message) {}

  @override
  void info(String message) {}

  @override
  void warning(String message) {}

  @override
  void error(String message, [Object? error, StackTrace? stackTrace]) {}
}

/// WebRTC signaling kept apart from media processing. Messages are plain data
/// so the same client interface works over WebSocket, copy-paste, or memory.
sealed class SignalingMessage {
  const SignalingMessage();

  Map<String, Object?> toJson();

  static SignalingMessage fromJson(Map<String, Object?> json) =>
      switch (json['type']) {
        'offer' => SdpOffer(json['sdp'] as String),
        'answer' => SdpAnswer(json['sdp'] as String),
        'candidate' => IceCandidateMessage(
          candidate: json['candidate'] as String,
          sdpMid: json['sdpMid'] as String?,
          sdpMLineIndex: json['sdpMLineIndex'] as int?,
        ),
        'hello' => PeerHello(json['role'] as String),
        'bye' => const PeerBye(),
        final type => throw FormatException('unknown signaling type: $type'),
      };
}

final class SdpOffer extends SignalingMessage {
  final String sdp;

  const SdpOffer(this.sdp);

  @override
  Map<String, Object?> toJson() => {'type': 'offer', 'sdp': sdp};
}

final class SdpAnswer extends SignalingMessage {
  final String sdp;

  const SdpAnswer(this.sdp);

  @override
  Map<String, Object?> toJson() => {'type': 'answer', 'sdp': sdp};
}

final class IceCandidateMessage extends SignalingMessage {
  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  const IceCandidateMessage({
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  @override
  Map<String, Object?> toJson() => {
    'type': 'candidate',
    'candidate': candidate,
    'sdpMid': sdpMid,
    'sdpMLineIndex': sdpMLineIndex,
  };
}

/// Announces a peer to the room so the publisher knows when to send an offer.
final class PeerHello extends SignalingMessage {
  final String role;

  const PeerHello(this.role);

  @override
  Map<String, Object?> toJson() => {'type': 'hello', 'role': role};
}

final class PeerBye extends SignalingMessage {
  const PeerBye();

  @override
  Map<String, Object?> toJson() => {'type': 'bye'};
}

abstract interface class SignalingClient {
  Stream<SignalingMessage> get messages;

  Future<void> connect();

  Future<void> send(SignalingMessage message);

  Future<void> disconnect();
}
