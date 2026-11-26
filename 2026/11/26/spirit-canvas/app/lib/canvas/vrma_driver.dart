import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_vrm/flutter_vrm.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../media.dart';
import 'canvas_model.dart';

/// Plays a body's `animation` (a .vrma by name, Part 16), for a body on the
/// 2D canvas or in a 3D world alike:
///
/// - `animation`: a name from canvas_media's vrma list; "none" (or absent):
///   the `pose` instead
/// - `animation_speed` (1), `animation_loop` (true; false plays once, then
///   the pose again)
///
/// The pose is applied first each frame and the motion overwrites the bones
/// it moves, so a motion without (say) the legs keeps the pose's; nothing
/// is left over from the frame before. A change blends from the pose the
/// body had over [blendSeconds]. Each file is read once and shared by every
/// body that plays it.
class VrmaDriver {
  VrmaDriver(this.avatar);

  final VrmAvatar avatar;
  static const blendSeconds = 0.35;

  /// Parsed motions by file path, shared by all bodies.
  static final _cache = <String, Future<VrmAnimation>>{};

  String? _wanted;
  VrmAnimationPlayer? _player;
  bool _finished = false;
  Map<VrmHumanBone, vm.Quaternion>? _from;

  /// The pose shown last frame (what a change blends from).
  Map<VrmHumanBone, vm.Quaternion> _shown = const {};
  double _blend = 1;

  /// Whether the motion moves the body now (the pose should not).
  bool get active => _player != null && !_finished;

  /// Follows the element's `animation`; call each frame after the pose was
  /// applied. Returns whether a motion was applied.
  bool update(CanvasElement e, double dt) {
    final name = e.str('animation');
    final key = name == null || name.isEmpty || name == 'none' ? null : name;
    if (key != _wanted) {
      _wanted = key;
      _start(key);
    }
    final p = _player;
    if (p == null || _finished) {
      _applyBlend(dt);
      _remember();
      return false;
    }
    p
      ..speed = e.num_('animation_speed', 1)
      ..loop = e.flag('animation_loop', true);
    p.update(dt);
    if (p.finished) {
      // Played once: back to the pose, blended.
      _finished = true;
      _snapshot();
      _applyBlend(dt);
      _remember();
      return false;
    }
    _applyBlend(dt);
    _remember();
    return true;
  }

  void _start(String? name) {
    _snapshot();
    if (name == null) {
      _player = null;
      return;
    }
    final file = MediaLibrary.instance.vrmaFile(name);
    if (file == null) {
      _player = null;
      return;
    }
    final future = _cache.putIfAbsent(
      file.path,
      () async => VrmAnimation.fromGlb(await file.readAsBytes()),
    );
    unawaited(
      future.then((anim) {
        if (_wanted != name) return;
        _snapshot();
        _player = VrmAnimationPlayer(avatar, anim);
        _finished = false;
      }),
    );
  }

  /// Blends from the pose shown last frame.
  void _snapshot() {
    _from = {
      for (final MapEntry(:key, :value) in _shown.entries) key: value.clone(),
    };
    _blend = 0;
  }

  void _remember() {
    final h = avatar.humanoid;
    _shown = {
      for (final b in h.bones)
        if (h.normalizedRotation(b) case final q?) b: q.clone(),
    };
  }

  void _applyBlend(double dt) {
    final from = _from;
    if (from == null || _blend >= 1) return;
    _blend = math.min(1, _blend + dt / blendSeconds);
    final k = _blend * _blend * (3 - 2 * _blend);
    final h = avatar.humanoid;
    for (final MapEntry(key: b, value: q0) in from.entries) {
      final q1 = h.normalizedRotation(b) ?? vm.Quaternion.identity();
      h.setNormalizedRotation(b, _slerp(q0, q1, k));
    }
    if (_blend >= 1) _from = null;
  }

  static vm.Quaternion _slerp(vm.Quaternion a, vm.Quaternion b, double t) {
    var d = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    final s = d < 0 ? -1.0 : 1.0;
    d = d.abs();
    if (d > 0.9995) {
      return vm.Quaternion(
        a.x + (s * b.x - a.x) * t,
        a.y + (s * b.y - a.y) * t,
        a.z + (s * b.z - a.z) * t,
        a.w + (s * b.w - a.w) * t,
      )..normalize();
    }
    final th = math.acos(d);
    final w0 = math.sin((1 - t) * th) / math.sin(th);
    final w1 = s * math.sin(t * th) / math.sin(th);
    return vm.Quaternion(
      a.x * w0 + b.x * w1,
      a.y * w0 + b.y * w1,
      a.z * w0 + b.z * w1,
      a.w * w0 + b.w * w1,
    );
  }
}
