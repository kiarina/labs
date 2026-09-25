import 'dart:async';
import 'dart:collection';

import '../domain/media.dart';

/// A media event plus the monotonic time it entered the pipeline.
final class QueuedMediaEvent {
  final MediaEvent event;
  final Duration arrivedAt;

  const QueuedMediaEvent(this.event, this.arrivedAt);
}

/// Buffers media events between a source and a slower processor.
///
/// - Video frames: **latest-frame-wins**. One slot; a new frame replaces an
///   unprocessed one and counts as dropped.
/// - Audio levels: **bounded FIFO**. Time order matters for audio, so events
///   are kept in order; when full, the oldest is dropped and counted.
/// - Everything else (start, stop, stats, errors): unbounded FIFO. These are
///   rare and must not be lost.
///
/// Delivery order: control first, then audio and video alternate so that a
/// busy audio queue cannot starve video (or the reverse).
final class MediaEventIntake {
  final int audioCapacity;

  final Queue<QueuedMediaEvent> _control = Queue();
  final Queue<QueuedMediaEvent> _audio = Queue();
  QueuedMediaEvent? _latestVideo;
  bool _preferVideo = false;
  bool _closed = false;
  Completer<void>? _waiter;

  int droppedVideoFrames = 0;
  int droppedAudioEvents = 0;

  MediaEventIntake({this.audioCapacity = 64}) : assert(audioCapacity > 0);

  bool get isClosed => _closed;

  int get pending =>
      _control.length + _audio.length + (_latestVideo == null ? 0 : 1);

  void add(QueuedMediaEvent queued) {
    if (_closed) return;
    switch (queued.event) {
      case VideoFrameObserved():
        if (_latestVideo != null) droppedVideoFrames++;
        _latestVideo = queued;
      case AudioLevelChanged():
        if (_audio.length >= audioCapacity) {
          _audio.removeFirst();
          droppedAudioEvents++;
        }
        _audio.add(queued);
      case MediaStarted() ||
          MediaStopped() ||
          MediaStatsUpdated() ||
          MediaErrorOccurred():
        _control.add(queued);
    }
    _wake();
  }

  /// Stops accepting events. Already buffered events are still delivered;
  /// [next] returns null once they are drained.
  void close() {
    _closed = true;
    _wake();
  }

  /// Drops everything buffered and closes. Used by an immediate stop.
  void abort() {
    _control.clear();
    _audio.clear();
    _latestVideo = null;
    close();
  }

  Future<QueuedMediaEvent?> next() async {
    while (true) {
      final item = _take();
      if (item != null) return item;
      if (_closed) return null;
      final waiter = _waiter = Completer<void>();
      await waiter.future;
    }
  }

  QueuedMediaEvent? _take() {
    if (_control.isNotEmpty) return _control.removeFirst();
    final video = _latestVideo;
    final hasAudio = _audio.isNotEmpty;
    if (video != null && (_preferVideo || !hasAudio)) {
      _latestVideo = null;
      _preferVideo = false;
      return video;
    }
    if (hasAudio) {
      _preferVideo = true;
      return _audio.removeFirst();
    }
    return null;
  }

  void _wake() {
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }
}
