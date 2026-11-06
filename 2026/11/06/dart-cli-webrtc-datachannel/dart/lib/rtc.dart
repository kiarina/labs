/// The small surface the probe needs from a WebRTC implementation: one
/// peer connection with one ordered, reliable data channel, trickle ICE.
library;

import 'dart:async';

/// One data channel carrying text frames.
abstract class TextChannel {
  String get label;

  /// Received text messages, already decoded as UTF-8.
  Stream<String> get messages;

  /// Completes when the channel closes.
  Future<void> get closed;

  Future<void> send(String text);
}

abstract class Rtc {
  /// `{'k': 'offer'|'answer', 'sdp': ...}` and
  /// `{'k': 'cand', 'candidate', 'sdpMid', 'sdpMLineIndex'}` to send to the
  /// other end, in order.
  Stream<Map<String, dynamic>> get signals;

  /// `connecting`, `connected`, `disconnected`, `failed`, `closed`.
  Stream<String> get states;

  /// Makes the channel and the offer (offerer) or waits for the other end's
  /// channel (answerer).
  Future<TextChannel> start({required bool offer});

  /// A signal from the other end.
  Future<void> onSignal(Map<String, dynamic> m);

  Future<void> close();

  /// What this implementation is, for the result file.
  Map<String, Object?> get info;
}
