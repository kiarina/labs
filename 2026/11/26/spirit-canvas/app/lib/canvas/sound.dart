import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../media.dart';

/// The canvas's sounds: one-shot effects, and one background music channel
/// that crossfades when the track changes.
class SoundBoard {
  /// Effects playing at once; a new one past this stops the oldest.
  static const maxEffects = 8;

  final _effects = <AudioPlayer>[];
  _Track? _bgm;
  final _fading = <_Track>[];
  Timer? _fadeTimer;

  /// Plays [src] once. Returns an error message, if any.
  Future<String?> play(String src, {double volume = 1}) async {
    final source = _source(src);
    if (source == null) return 'sound "$src" not found';
    final p = AudioPlayer();
    _effects.add(p);
    if (_effects.length > maxEffects) {
      final old = _effects.removeAt(0);
      unawaited(old.dispose());
    }
    p.onPlayerComplete.listen((_) {
      _effects.remove(p);
      p.dispose();
    });
    try {
      await p.setReleaseMode(ReleaseMode.stop);
      await p.setVolume(volume.clamp(0, 1));
      await p.play(source);
    } on Object catch (e) {
      _effects.remove(p);
      unawaited(p.dispose());
      return 'sound "$src": $e';
    }
    return null;
  }

  /// Background music: [src] loops at [volume], crossfading from the
  /// current track over [fadeMs]. The same [src] only moves the volume;
  /// null fades the music out.
  Future<String?> bgm(
    String? src, {
    double volume = 0.5,
    double fadeMs = 1000,
  }) async {
    volume = volume.clamp(0, 1);
    final current = _bgm;
    if (src != null && current != null && current.src == src) {
      current.fadeTo(volume, fadeMs);
      _runFades();
      return null;
    }
    if (current != null) {
      current.fadeTo(0, fadeMs, thenDispose: true);
      _fading.add(current);
      _bgm = null;
    }
    if (src != null) {
      final source = _source(src);
      if (source == null) {
        _runFades();
        return 'music "$src" not found';
      }
      final p = AudioPlayer();
      final t = _Track(src, p)..volume = 0;
      try {
        await p.setReleaseMode(ReleaseMode.loop);
        await p.setVolume(0);
        await p.play(source);
      } on Object catch (e) {
        unawaited(p.dispose());
        _runFades();
        return 'music "$src": $e';
      }
      t.fadeTo(volume, fadeMs);
      _bgm = t;
      _fading.add(t);
    }
    _runFades();
    return null;
  }

  Map<String, dynamic>? get bgmState => switch (_bgm) {
    final t? => {
      'src': t.src,
      'volume': double.parse(t.target.toStringAsFixed(2)),
    },
    null => null,
  };

  void _runFades() {
    if (_fadeTimer?.isActive ?? false) return;
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 40), (timer) {
      for (final t in [..._fading]) {
        if (t.step()) {
          _fading.remove(t);
          if (t.disposeWhenDone) {
            unawaited(t.player.stop().then((_) => t.player.dispose()));
          }
        }
      }
      if (_fading.isEmpty) timer.cancel();
    });
  }

  Source? _source(String src) {
    final r = MediaLibrary.instance.resolve(src);
    if (r == null) return null;
    return r.file != null ? DeviceFileSource(r.file!.path) : UrlSource(r.url!);
  }

  /// Stops everything (the canvas was cleared).
  Future<void> stopAll() async {
    await bgm(null, fadeMs: 300);
    for (final p in [..._effects]) {
      unawaited(p.dispose());
    }
    _effects.clear();
  }

  void dispose() {
    _fadeTimer?.cancel();
    for (final p in [
      ..._effects,
      ?_bgm?.player,
      for (final t in _fading) t.player,
    ]) {
      unawaited(p.dispose().catchError((Object e) => debugPrint('$e')));
    }
  }
}

class _Track {
  _Track(this.src, this.player);

  final String src;
  final AudioPlayer player;
  double volume = 0;
  double target = 0;
  double _from = 0;
  DateTime _start = DateTime.now();
  double _ms = 0;
  bool disposeWhenDone = false;

  void fadeTo(double v, double ms, {bool thenDispose = false}) {
    _from = volume;
    target = v;
    _start = DateTime.now();
    _ms = math.max(0, ms);
    disposeWhenDone = thenDispose;
  }

  /// Moves the volume one step; true when it has arrived.
  bool step() {
    final t = _ms <= 0
        ? 1.0
        : (DateTime.now().difference(_start).inMicroseconds / 1000 / _ms).clamp(
            0.0,
            1.0,
          );
    volume = _from + (target - _from) * t;
    player.setVolume(volume);
    return t >= 1;
  }
}
