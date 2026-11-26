import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_vrm/flutter_vrm.dart';
import 'package:vector_math/vector_math.dart';

import 'bridge.dart';

/// A generated frame: hips position and normalized rotations, in VRM model
/// space, in the order of [MotionDirector.bones].
class MotionFrame {
  MotionFrame(this.hips, this.rotations);

  final Vector3 hips;
  final List<Quaternion> rotations;
}

/// One generation request, for the lab's measurements.
class GenerationRecord {
  GenerationRecord(this.mode, this.prompt, this.requestedAt, this.playheadAtRequest);

  final String mode;
  final String prompt;
  final DateTime requestedAt;
  final double playheadAtRequest;

  /// The frame the new motion starts at (branch / replace).
  int? fromFrame;
  DateTime? firstChunkAt;
  DateTime? completedAt;

  /// When playback reached [fromFrame]: the user sees the new motion.
  DateTime? visibleAt;
  int frames = 0;
  Map<String, dynamic>? timingsMs;

  Map<String, dynamic> toJson() => {
    'mode': mode,
    'prompt': prompt,
    'fromFrame': fromFrame,
    'playheadAtRequest': playheadAtRequest.toStringAsFixed(1),
    'firstChunkMs': firstChunkAt?.difference(requestedAt).inMilliseconds,
    'completeMs': completedAt?.difference(requestedAt).inMilliseconds,
    'visibleMs': visibleAt?.difference(requestedAt).inMilliseconds,
    'frames': frames,
    'timingsMs': timingsMs,
  };
}

/// Owns the motion timeline and the playhead, and keeps ARDY generating
/// ahead of playback (append), or from a little ahead of the playhead when
/// the prompt changes (branch), like ARDY Mini's own app.
class MotionDirector extends ChangeNotifier {
  MotionDirector(this.bridge);

  final ArdyBridge bridge;

  /// Frames ahead of the playhead that a prompt change keeps (ARDY Mini's
  /// replan buffer is 20 frames = 1 s at 20 FPS).
  static int replanBufferFrames = 20;

  /// Start the next append when fewer frames than this remain.
  static int leadFrames = 30;

  final frames = <MotionFrame>[];
  List<VrmHumanBone> bones = const [];
  double fps = 20;
  double playhead = 0;
  String? prompt;
  String? _pendingPrompt;
  bool generating = false;
  bool loaded = false;

  /// Seconds the playhead waited at the end of the timeline.
  double stallSeconds = 0;
  int stalls = 0;
  bool _stalled = false;
  final records = <GenerationRecord>[];
  GenerationRecord? _active;
  final _seed = math.Random().nextInt(1 << 30);

  int get frameCount => frames.length;

  /// Asks for [text] as the motion from about one second ahead.
  void setPrompt(String text) {
    _pendingPrompt = text.trim();
    _pump();
  }

  void onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'loaded':
        loaded = true;
        fps = (e['fps'] as num).toDouble();
        bones = [
          for (final b in (e['bones'] as List).cast<String>())
            VrmHumanBone.values.byName(b),
        ];
        _pump();
      case 'frames':
        _onFrames(e);
      case 'complete':
        generating = false;
        _active?.completedAt = DateTime.now();
        _active?.timingsMs = (e['timingsMs'] as Map?)?.cast<String, dynamic>();
        _active = null;
        _pump();
      case 'error' || 'cancelled':
        generating = false;
        _active = null;
    }
    notifyListeners();
  }

  void _onFrames(Map<String, dynamic> e) {
    final start = e['startFrame'] as int;
    final mode = e['mode'] as String;
    final list = (e['frames'] as List).cast<List>();
    final record = _active;
    if (record != null && record.firstChunkAt == null) {
      record
        ..firstChunkAt = DateTime.now()
        ..fromFrame = start;
    }
    if (mode == 'replace' && start == 0) {
      frames.clear();
      playhead = 0;
    }
    if (start < frames.length) frames.removeRange(start, frames.length);
    for (final values in list) {
      final v = values.cast<num>();
      frames.add(
        MotionFrame(Vector3(v[0].toDouble(), v[1].toDouble(), v[2].toDouble()), [
          for (var i = 3; i + 3 < v.length; i += 4)
            Quaternion(
              v[i].toDouble(),
              v[i + 1].toDouble(),
              v[i + 2].toDouble(),
              v[i + 3].toDouble(),
            ),
        ]),
      );
    }
    record?.frames += list.length;
  }

  void _pump() {
    if (!loaded || generating) return;
    final pending = _pendingPrompt;
    if (pending != null) {
      _pendingPrompt = null;
      prompt = pending;
      if (frames.isEmpty) {
        _generate('replace', pending);
      } else {
        final from = math.min(frames.length, playhead.floor() + replanBufferFrames);
        _generate('branch', pending, branchFrame: from);
      }
      return;
    }
    final current = prompt;
    if (current != null && frames.length - playhead < leadFrames) {
      _generate('append', current);
    }
  }

  Future<void> _generate(String mode, String text, {int? branchFrame}) async {
    generating = true;
    final record = GenerationRecord(mode, text, DateTime.now(), playhead);
    if (mode != 'append') records.add(record);
    _active = record;
    final reply = await bridge.command({
      'type': 'generate',
      'mode': mode,
      'prompt': text,
      'seed': _seed,
      'branchFrame': ?branchFrame,
    });
    if (reply['ok'] != true) {
      generating = false;
      _active = null;
      debugPrint('[motion] generate refused: $reply');
    }
    notifyListeners();
  }

  /// Advances the playhead and writes the pose into [avatar].
  void update(double dt, VrmAvatar avatar) {
    if (frames.isEmpty) return;
    final last = frames.length - 1;
    final next = playhead + dt * fps;
    if (next > last) {
      if (!_stalled && prompt != null) {
        _stalled = true;
        stalls++;
      }
      if (prompt != null) stallSeconds += (next - last) / fps;
      playhead = last.toDouble();
    } else {
      _stalled = false;
      playhead = next;
    }
    for (final r in records) {
      if (r.visibleAt == null && r.fromFrame != null && playhead >= r.fromFrame!) {
        r.visibleAt = DateTime.now();
      }
    }
    _pump();
    final i0 = playhead.floor();
    final i1 = math.min(i0 + 1, last);
    final a = frames[i0];
    final b = frames[i1];
    final t = playhead - i0;
    final humanoid = avatar.humanoid;
    for (var k = 0; k < bones.length && k < a.rotations.length; k++) {
      humanoid.setNormalizedRotation(bones[k], _slerp(a.rotations[k], b.rotations[k], t));
    }
    // The hips take ARDY's root motion as is. With flutter_vrm 6cdf97d the
    // skinned meshes (the hair) were culled once the hips traveled, so the
    // root node carried the travel instead; flutter_vrm 1569bdb fits their
    // bounds to the posed skeleton.
    humanoid.setHipsPosition(a.hips + (b.hips - a.hips) * t);
  }

  static Quaternion _slerp(Quaternion a, Quaternion b, double t) {
    var bx = b.x, by = b.y, bz = b.z, bw = b.w;
    var cos = a.x * bx + a.y * by + a.z * bz + a.w * bw;
    if (cos < 0) {
      bx = -bx;
      by = -by;
      bz = -bz;
      bw = -bw;
      cos = -cos;
    }
    double wa, wb;
    if (cos > 0.9995) {
      wa = 1 - t;
      wb = t;
    } else {
      final angle = math.acos(cos.clamp(-1.0, 1.0));
      final s = math.sin(angle);
      wa = math.sin((1 - t) * angle) / s;
      wb = math.sin(t * angle) / s;
    }
    return Quaternion(
      a.x * wa + bx * wb,
      a.y * wa + by * wb,
      a.z * wa + bz * wb,
      a.w * wa + bw * wb,
    )..normalize();
  }
}
