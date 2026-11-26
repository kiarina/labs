import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:flutter_vrm/flutter_vrm.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../media.dart';
import 'canvas_model.dart';

const kVrmPoses = [
  'rest',
  'idle',
  'wave',
  'nod',
  'bow',
  'cheer',
  'think',
  'walk',
  'sleep',
  'work',
];
const kVrmExpressions = [
  'neutral',
  'happy',
  'angry',
  'sad',
  'relaxed',
  'surprised',
];

vm.Quaternion _about(double x, double y, double z, double degrees) =>
    vm.Quaternion.axisAngle(vm.Vector3(x, y, z), degrees * math.pi / 180);

final _relaxedArms = {
  VrmHumanBone.leftUpperArm: _about(0, 0, 1, -72),
  VrmHumanBone.rightUpperArm: _about(0, 0, 1, 72),
  VrmHumanBone.leftLowerArm: _about(0, 1, 0, -10),
  VrmHumanBone.rightLowerArm: _about(0, 1, 0, 10),
};

/// A VRM on the canvas: the spirit's own body. Props: `src` (default: the
/// lab's VRM), `expression`, `expression_weight`, `pose` ([kVrmPoses]),
/// `animation` (a .vrma; `default` for the lab's), `framing` (`bust` or
/// `full`), `look_at_viewer`, `talking` (moves the mouth), `turn` (degrees
/// the body turns from facing the viewer: 90 faces right, -90 left; it
/// turns there smoothly).
class VrmElementView extends StatefulWidget {
  const VrmElementView({super.key, required this.element, this.controller});

  final CanvasElement element;

  /// For the mouth while the element speaks (`speak` with its id).
  final CanvasController? controller;

  @override
  State<VrmElementView> createState() => _VrmElementViewState();
}

class _VrmElementViewState extends State<VrmElementView> {
  Scene? _scene;
  VrmAvatar? _avatar;
  VrmAnimationPlayer? _player;
  String? _loadedSrc;
  String? _loadedAnimation;
  String _status = 'loading';
  final _camera = PerspectiveCamera(
    fovRadiansY: 25 * vm.degrees2Radians,
    fovNear: 0.05,
    fovFar: 100,
  );
  vm.Vector3 _eye = vm.Vector3(0, 1.3, 2.5);
  vm.Vector3 _target = vm.Vector3(0, 1.3, 0);
  String? _framedFor;

  /// The turn shown now (eases toward the `turn` prop).
  double _turn = 0;

  /// The box's width / height: a narrow box pulls the camera back so the
  /// body still fits across.
  double _aspect = 1;

  CanvasElement get e => widget.element;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant VrmElementView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (e.str('src') != _loadedSrc) _load();
    if (e.str('animation') != _loadedAnimation) _loadAnimation();
  }

  Future<void> _load() async {
    final src = e.str('src');
    _loadedSrc = src;
    final file = MediaLibrary.instance.vrmFile(src);
    if (file == null) {
      setState(() => _status = 'no VRM "${src ?? 'default'}"');
      return;
    }
    try {
      final scene = _scene ??= Scene();
      await Scene.initializeStaticResources();
      scene.directionalLight ??= DirectionalLight(
        direction: vm.Vector3(0.3, -0.5, 1)..normalize(),
        intensity: 3,
      );
      final avatar = await VrmAvatar.fromBytes(await file.readAsBytes());
      if (!mounted) return;
      if (_avatar case final old?) scene.remove(old.root);
      scene.add(avatar.root);
      // Face the camera (the model looks along its +Z; the camera is on +Z).
      avatar.update(0);
      setState(() {
        _avatar = avatar;
        _framedFor = null;
        _status = 'ready';
      });
      _loadAnimation();
    } on Object catch (err) {
      if (mounted) setState(() => _status = 'failed: $err');
    }
  }

  Future<void> _loadAnimation() async {
    final name = e.str('animation');
    _loadedAnimation = name;
    final avatar = _avatar;
    if (avatar == null) return;
    if (name == null || name.isEmpty || name == 'none') {
      setState(() => _player = null);
      avatar.humanoid.resetPose();
      return;
    }
    final file = MediaLibrary.instance.vrmaFile(name);
    if (file == null) return;
    try {
      final anim = VrmAnimation.fromGlb(await file.readAsBytes());
      if (!mounted) return;
      setState(() => _player = VrmAnimationPlayer(avatar, anim));
    } on Object catch (err) {
      if (mounted) setState(() => _status = 'animation failed: $err');
    }
  }

  void _frame(VrmAvatar a) {
    final framing = e.str('framing') ?? 'bust';
    final key = '$framing@${_aspect.toStringAsFixed(2)}';
    if (_framedFor == key) return;
    _framedFor = key;
    // The bust framing knows which way the avatar faces; the full one
    // looks from the same side.
    final f = VrmPortrait.bust(a, fovYRadians: _camera.fovRadiansY);
    if (framing == 'full') {
      final facing = (f.position - f.target)..y = 0;
      facing.normalize();
      final head = a.humanoid.worldPosition(VrmHumanBone.head);
      final top = (head?.y ?? 1.4) + 0.2;
      final mid = top / 2;
      final dist = (top + 0.2) / 2 / math.tan(_camera.fovRadiansY / 2) * 1.05;
      _target = vm.Vector3(f.target.x, mid, f.target.z);
      _eye = _target + facing * dist;
    } else {
      _target = f.target;
      _eye = f.position;
    }
    // Framed by height; the body needs about this width / height to fit
    // across (shoulders for the bust, arms for the full body).
    final needs = framing == 'full' ? 0.55 : 0.9;
    if (_aspect < needs) {
      _eye = _target + (_eye - _target) * (needs / _aspect);
    }
  }

  void _pose(VrmAvatar a, double t) {
    final h = a.humanoid;
    h.resetPose();
    final pose = e.str('pose') ?? 'idle';
    if (pose == 'rest') return;
    _relaxedArms.forEach(h.setNormalizedRotation);
    final breathe = math.sin(t * 2 * math.pi / 4) * 0.02;
    h.setNormalizedRotation(
      VrmHumanBone.spine,
      vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), breathe),
    );
    switch (pose) {
      case 'wave':
        // The right arm up, the forearm swinging.
        h.setNormalizedRotation(
          VrmHumanBone.rightUpperArm,
          _about(0, 0, 1, -10),
        );
        h.setNormalizedRotation(
          VrmHumanBone.rightLowerArm,
          _about(0, 0, 1, -70 + math.sin(t * 2 * math.pi * 1.5) * 25),
        );
      case 'nod':
        h.setNormalizedRotation(
          VrmHumanBone.head,
          _about(1, 0, 0, 12 * (0.5 + 0.5 * math.sin(t * 2 * math.pi * 1.2))),
        );
      case 'bow':
        h.setNormalizedRotation(VrmHumanBone.spine, _about(1, 0, 0, 25));
        h.setNormalizedRotation(VrmHumanBone.chest, _about(1, 0, 0, 10));
      case 'cheer':
        final bounce = math.sin(t * 2 * math.pi * 2) * 8;
        h.setNormalizedRotation(
          VrmHumanBone.leftUpperArm,
          _about(0, 0, 1, 40 + bounce),
        );
        h.setNormalizedRotation(
          VrmHumanBone.rightUpperArm,
          _about(0, 0, 1, -40 - bounce),
        );
        h.setNormalizedRotation(VrmHumanBone.leftLowerArm, _about(0, 0, 1, 20));
        h.setNormalizedRotation(
          VrmHumanBone.rightLowerArm,
          _about(0, 0, 1, -20),
        );
      case 'walk':
        // Legs and arms swinging, two steps a second.
        final swing = math.sin(t * 2 * math.pi * 1.0);
        h.setNormalizedRotation(
          VrmHumanBone.leftUpperLeg,
          _about(1, 0, 0, 28 * swing),
        );
        h.setNormalizedRotation(
          VrmHumanBone.rightUpperLeg,
          _about(1, 0, 0, -28 * swing),
        );
        h.setNormalizedRotation(
          VrmHumanBone.leftLowerLeg,
          _about(1, 0, 0, -30 * math.max(0, swing)),
        );
        h.setNormalizedRotation(
          VrmHumanBone.rightLowerLeg,
          _about(1, 0, 0, -30 * math.max(0, -swing)),
        );
        h.setNormalizedRotation(
          VrmHumanBone.leftUpperArm,
          _about(1, 0, 0, -20 * swing) * _about(0, 0, 1, -72),
        );
        h.setNormalizedRotation(
          VrmHumanBone.rightUpperArm,
          _about(1, 0, 0, 20 * swing) * _about(0, 0, 1, 72),
        );
      case 'sleep':
        // Dozing: the head down and to the side, breathing slowly.
        final slow = math.sin(t * 2 * math.pi / 5);
        h.setNormalizedRotation(
          VrmHumanBone.head,
          _about(1, 0, 0, 22 + 3 * slow) * _about(0, 0, 1, 12),
        );
        h.setNormalizedRotation(VrmHumanBone.spine, _about(1, 0, 0, 8));
      case 'work':
        // At a desk: forearms forward, the hands tapping, eyes down.
        final tap = math.sin(t * 2 * math.pi * 3);
        h.setNormalizedRotation(
          VrmHumanBone.leftUpperArm,
          _about(0, 1, 0, -30) * _about(0, 0, 1, -65),
        );
        h.setNormalizedRotation(
          VrmHumanBone.rightUpperArm,
          _about(0, 1, 0, 30) * _about(0, 0, 1, 65),
        );
        h.setNormalizedRotation(
          VrmHumanBone.leftLowerArm,
          _about(0, 1, 0, -75 - 4 * tap),
        );
        h.setNormalizedRotation(
          VrmHumanBone.rightLowerArm,
          _about(0, 1, 0, 75 + 4 * tap),
        );
        h.setNormalizedRotation(VrmHumanBone.head, _about(1, 0, 0, 14));
      case 'think':
        h.setNormalizedRotation(
          VrmHumanBone.rightUpperArm,
          _about(0, 1, 0, 50) * _about(0, 0, 1, 60),
        );
        h.setNormalizedRotation(
          VrmHumanBone.rightLowerArm,
          _about(0, 1, 0, 120),
        );
        h.setNormalizedRotation(
          VrmHumanBone.head,
          _about(0, 0, 1, 8) * _about(1, 0, 0, 5),
        );
    }
  }

  void _onTick(Duration elapsed, double dt) {
    final a = _avatar;
    if (a == null) return;
    final t = elapsed.inMicroseconds / 1e6;
    final player = _player;
    if (player != null) {
      player.update(dt);
    } else {
      _pose(a, t);
    }
    a.expressions.resetValues();
    final name = e.str('expression') ?? 'neutral';
    final preset = VrmExpressionPreset.values
        .where((p) => p.name == name)
        .firstOrNull;
    if (preset != null && preset != VrmExpressionPreset.neutral) {
      a.expressions.setPreset(
        preset,
        e.num_('expression_weight', 1).clamp(0, 1),
      );
    }
    // Asleep: eyes shut (the automatic blink would open them again).
    final asleep = e.str('pose') == 'sleep';
    a.autoBlink.enabled = !asleep;
    if (asleep) a.expressions.setPreset(VrmExpressionPreset.blink, 1);
    final voice = widget.controller?.mouthLevel(e.id);
    if (voice != null) {
      // Speaking: the mouth follows the voice's loudness.
      a.expressions.setPreset(
        VrmExpressionPreset.aa,
        (voice * 0.9).clamp(0, 1),
      );
    } else if (e.flag('talking', false)) {
      final open =
          (math.sin(t * 2 * math.pi * 4) * 0.5 + 0.5) *
          (0.6 + 0.4 * math.sin(t * 2 * math.pi * 1.3).abs());
      a.expressions.setPreset(VrmExpressionPreset.aa, open);
    }
    a.update(dt, camera: _camera);
    _frame(a);
    // Turning: the camera goes around the avatar the other way (the
    // framing stays the one made facing the viewer).
    final want = e.num_('turn', 0);
    _turn += (want - _turn) * math.min(1, dt * 8);
    final eye = _turn.abs() < 0.01
        ? _eye
        : _target +
              (vm.Matrix3.rotationY(_turn * math.pi / 180) * (_eye - _target));
    _camera
      ..position = eye
      ..target = _target;
    a.mtoonLighting.fromScene(_scene!);
    final look = e.flag('look_at_viewer', true);
    a.lookAt.enabled = look;
    a.lookAt.target = look ? eye : null;
  }

  @override
  Widget build(BuildContext context) {
    final scene = _scene;
    if (_avatar == null || scene == null) {
      return Center(
        child: Text(
          'VRM: $_status',
          style: const TextStyle(color: Colors.white54, fontSize: 14),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth.isFinite && box.maxHeight > 0) {
          _aspect = box.maxWidth / box.maxHeight;
        }
        return SceneView(scene, camera: _camera, onTick: _onTick);
      },
    );
  }
}
