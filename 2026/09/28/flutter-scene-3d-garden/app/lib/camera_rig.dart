import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart';

import 'vrm_avatar.dart';

enum CameraMode { quarter, focus }

/// Quarter view over the garden, and a view in front of one avatar's face,
/// with an eased transition between them. All input arrives as plain calls
/// so gestures, mouse, trackpad and keyboard share one path.
class CameraRig {
  CameraRig({required Vector3 target, required double distance})
    : _target = target.clone(),
      _distance = distance,
      _home = target.clone(),
      _homeDistance = distance;

  final PerspectiveCamera camera = PerspectiveCamera(
    fovRadiansY: 32 * degrees2Radians,
    fovNear: 0.05,
    fovFar: 300,
  );

  CameraMode mode = CameraMode.quarter;
  VrmAvatar? subject;

  // Quarter view state.
  Vector3 _target;
  double _yaw = math.pi / 4; // camera sits south-east of the target
  double _pitch = 50 * degrees2Radians;
  double _distance;
  final Vector3 _home;
  final double _homeDistance;

  // Focus view state (relative to the subject's face).
  double _focusDistance = 1.25;
  double _focusYaw = 0;
  double _focusPitch = 0;

  // Transition.
  Vector3? _fromEye;
  Vector3? _fromTarget;
  double _t = 1;
  static const double transitionSeconds = 0.9;

  bool get transitioning => _t < 1;
  double get yaw => _yaw;

  /// The flat forward direction of the camera (for wall cutaway).
  Vector3 get forwardFlat {
    final f = camera.target - camera.position;
    f.y = 0;
    return f.length2 < 1e-8 ? Vector3(0, 0, -1) : f.normalized();
  }

  void _beginTransition() {
    _fromEye = camera.position.clone();
    _fromTarget = camera.target.clone();
    _t = 0;
  }

  void focusOn(VrmAvatar avatar) {
    subject = avatar;
    mode = CameraMode.focus;
    _focusYaw = 0;
    _focusPitch = 0;
    // Frame the upper body whatever the avatar's size.
    _focusDistance = (avatar.standingHeadHeight * 0.85).clamp(1.0, 1.6);
    _beginTransition();
  }

  void backToQuarter() {
    final s = subject;
    if (s != null) {
      // Keep the garden centered on where the subject is.
      final p = s.root.globalTransform.getTranslation();
      _target = Vector3(p.x, 0, p.z);
    }
    subject = null;
    mode = CameraMode.quarter;
    _beginTransition();
  }

  void resetHome() {
    _target = _home.clone();
    _distance = _homeDistance;
    _yaw = math.pi / 4;
    _pitch = 50 * degrees2Radians;
    if (mode == CameraMode.focus) {
      backToQuarter();
    } else {
      _beginTransition();
    }
  }

  // ---- input -------------------------------------------------------------

  /// One-finger drag / left-mouse drag, in logical pixels.
  void drag(double dx, double dy, double viewHeight) {
    if (mode == CameraMode.quarter) {
      // Pan the target on the ground so the ground under the finger follows
      // it (approximately, from the view's vertical extent at the target).
      final worldPerPixel =
          2 * _distance * math.tan(camera.fovRadiansY / 2) / viewHeight;
      final right = Vector3(math.cos(_yaw), 0, -math.sin(_yaw));
      final forward = Vector3(-math.sin(_yaw), 0, -math.cos(_yaw));
      _target += right * (-dx * worldPerPixel);
      _target += forward * (dy * worldPerPixel / math.sin(_pitch));
    } else {
      _focusYaw -= dx * 0.008;
      _focusPitch = (_focusPitch + dy * 0.006).clamp(-0.6, 0.9);
    }
  }

  /// Pinch / wheel. [factor] > 1 zooms in.
  void zoom(double factor) {
    if (factor <= 0) return;
    if (mode == CameraMode.quarter) {
      _distance = (_distance / factor).clamp(4.0, 60.0);
    } else {
      _focusDistance = (_focusDistance / factor).clamp(0.45, 5.0);
    }
  }

  /// Two-finger twist / right-mouse drag / Q E keys, in radians.
  void rotate(double radians) {
    if (mode == CameraMode.quarter) {
      _yaw += radians;
    } else {
      _focusYaw += radians;
    }
  }

  /// Two-finger vertical drag / shift+wheel, in radians.
  void tilt(double radians) {
    if (mode == CameraMode.quarter) {
      _pitch = (_pitch + radians).clamp(
        20 * degrees2Radians,
        85 * degrees2Radians,
      );
    } else {
      _focusPitch = (_focusPitch + radians).clamp(-0.6, 0.9);
    }
  }

  // ---- per frame ---------------------------------------------------------

  (Vector3 eye, Vector3 target) _desired() {
    final s = subject;
    if (mode == CameraMode.focus && s != null) {
      final head = s.headWorld;
      final lying =
          s.activity == AvatarActivity.lightSleep ||
          s.activity == AvatarActivity.deepSleep;
      final face = head + Vector3(0, lying ? 0.02 : 0.03, 0);
      // Base direction: straight out of the face. Then orbit around the
      // face by the user's yaw / pitch offsets.
      var dir = s.faceForward.normalized();
      final up = lying ? s.front.normalized() * -1.0 : Vector3(0, 1, 0);
      dir = Quaternion.axisAngle(up, _focusYaw).rotated(dir);
      final side = up.cross(dir)..normalize();
      dir = Quaternion.axisAngle(side, -_focusPitch).rotated(dir);
      final eye = face + dir * _focusDistance;
      return (eye, face);
    }
    final eye =
        _target +
        Vector3(
              math.cos(_pitch) * math.sin(_yaw),
              math.sin(_pitch),
              math.cos(_pitch) * math.cos(_yaw),
            ) *
            _distance;
    return (eye, _target.clone());
  }

  void update(double dt) {
    final (eye, target) = _desired();
    if (_t < 1 && _fromEye != null) {
      _t = math.min(1, _t + dt / transitionSeconds);
      final k = _t < 0.5 ? 4 * _t * _t * _t : 1 - math.pow(-2 * _t + 2, 3) / 2;
      camera.position = _fromEye! + (eye - _fromEye!) * k.toDouble();
      camera.target = _fromTarget! + (target - _fromTarget!) * k.toDouble();
    } else {
      camera.position = eye;
      camera.target = target;
    }
    // Keep "up" sensible when looking straight down at a sleeper.
    final viewDir = (camera.target - camera.position).normalized();
    camera.up = viewDir.y.abs() > 0.97
        ? (subject?.front ?? Vector3(0, 0, -1))
        : Vector3(0, 1, 0);
  }
}
