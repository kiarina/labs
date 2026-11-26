import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:flutter_vrm/flutter_vrm.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../media.dart';
import 'canvas_model.dart';
import 'vrm_element.dart';

/// A 3D world on the canvas (`type: world`), drawn with flutter_scene.
///
/// Things in it are canvas elements with `in: <world id>`:
/// - shapes (`box`, `sphere`, `cylinder`, `cone`, `plane`, `torus`,
///   `capsule`): `w`, `h`, `d` in metres, `color`, `roughness`, `metallic`,
///   `glow` (lit by itself), `opacity`
/// - a `vrm`: the spirit's body, with `pose`, `expression` and the voice's
///   mouth as on the 2D canvas
/// - any 2D element (text, image, svg, shape, button, choices, input):
///   drawn on a panel, `w`/`h` its size in pixels, `size_m` its height in
///   metres (default h / 400), `face_camera` to keep it turned to the
///   viewer. Buttons on a panel are pressed as on the canvas.
///
/// Every thing: `x`, `z` its middle and `y` its bottom (metres; x to the
/// right, y up, z away from the viewer), `rx`, `ry`, `rz` turns in degrees
/// (`ry` 90 turns a thing that faces the viewer to face right), `scale`.
///
/// The world: `cam_x/y/z` where the camera is, `look_x/y/z` what it looks
/// at, `fov` (degrees), `camera_mode` (`fixed`, `orbit`: going around the
/// look point at `orbit_speed` degrees a second, `follow`: keeping its
/// offset to the thing `follow` names), `user_camera` (drag to look
/// around), `sky` (a colour behind; none: transparent), `light`
/// (strength, default 3), `shadows` (default true). A `tap` event comes
/// for a tappable thing (or any thing, when the world is tappable) with
/// the point it was touched (x, y, z).
class WorldView extends StatefulWidget {
  const WorldView({
    super.key,
    required this.world,
    required this.controller,
    required this.panel,
  });

  final CanvasElement world;
  final CanvasController controller;

  /// Draws a 2D element for a panel.
  final Widget Function(CanvasElement e) panel;

  @override
  State<WorldView> createState() => _WorldViewState();
}

class _Thing {
  _Thing(this.node, this.signature);

  /// Placed by the element's position, turn and scale.
  final Node node;
  final String signature;
  VrmAvatar? avatar;
  PhysicallyBasedMaterial? material;
  bool faceCamera = false;
}

class _WorldViewState extends State<WorldView> {
  final _scene = Scene();
  final _camera = PerspectiveCamera(fovNear: 0.05, fovFar: 200);
  final _things = <String, _Thing>{};
  bool _ready = false;
  Size _size = Size.zero;
  double _orbit = 0;
  double _dragYaw = 0;
  double _dragPitch = 0;
  DirectionalLight? _sun;

  CanvasController get c => widget.controller;
  CanvasElement get w => widget.world;

  @override
  void initState() {
    super.initState();
    Scene.initializeStaticResources().then((_) {
      if (!mounted) return;
      _sun = DirectionalLight(
        direction: vm.Vector3(-0.4, -1, 0.5)..normalize(),
        intensity: 3,
        castsShadow: true,
      );
      _scene.directionalLight = _sun;
      setState(() => _ready = true);
    });
  }

  Iterable<CanvasElement> get _inside =>
      c.elements.values.where((e) => e.world == w.id);

  // --- building things ---------------------------------------------------------

  /// `#RRGGBB` or `#RRGGBBAA` (the canvas's spelling) as linear-ish RGBA.
  static vm.Vector4 _rgba(String? hex, double opacity) {
    final h = (hex ?? '#CCCCCC').replaceAll('#', '');
    int part(int i) => h.length >= i + 2
        ? int.tryParse(h.substring(i, i + 2), radix: 16) ?? 204
        : 255;
    return vm.Vector4(
      part(0) / 255,
      part(2) / 255,
      part(4) / 255,
      (h.length >= 8 ? part(6) / 255 : 1) * opacity,
    );
  }

  String _signature(CanvasElement e) => switch (e.type) {
    'vrm' => 'vrm:${e.str('src')}',
    _ when k3dShapes.contains(e.type) => 'shape:${e.type}',
    _ =>
      'panel:${e.type}:${e.num_('w', 400)}x${e.num_('h', 300)}:'
          '${e.props['size_m']}',
  };

  Geometry _geometry(String type) => switch (type) {
    'sphere' => SphereGeometry(radius: 0.5),
    'cylinder' => CylinderGeometry(),
    'cone' => CylinderGeometry(topRadius: 0),
    'plane' => PlaneGeometry(),
    'torus' => TorusGeometry(),
    'capsule' => CapsuleGeometry(radius: 0.5, height: 1),
    _ => CuboidGeometry(vm.Vector3(1, 1, 1)),
  };

  _Thing _build(CanvasElement e) {
    final node = Node(name: e.id);
    final thing = _Thing(node, _signature(e));
    if (e.type == 'vrm') {
      _loadVrm(e, thing);
    } else if (k3dShapes.contains(e.type)) {
      final material = PhysicallyBasedMaterial()..metallicFactor = 0;
      thing.material = material;
      // Unit shapes are centred; lift them so y is the bottom. A plane is
      // flat already.
      final shape = Node(
        mesh: Mesh(_geometry(e.type), material),
        localTransform: e.type == 'plane'
            ? vm.Matrix4.identity()
            : vm.Matrix4.translation(vm.Vector3(0, 0.5, 0)),
      );
      node.add(shape);
    } else {
      final pw = e.num_('w', 400), ph = e.num_('h', 300);
      final height = e.num_('size_m', ph / 400);
      final panel = Node(
        localTransform: vm.Matrix4.translation(vm.Vector3(0, height / 2, 0)),
      );
      panel.addComponent(
        WidgetComponent(
          size: Size(pw, ph),
          pixelRatio: 2,
          worldHeight: height,
          child: ListenableBuilder(
            listenable: c,
            // The texture shows mirrored from the panel's front (the view
            // space is left-handed); drawn mirrored, it reads right.
            builder: (context, _) => Transform.flip(
              flipX: true,
              child: SizedBox(width: pw, height: ph, child: widget.panel(e)),
            ),
          ),
        ),
      );
      node.add(panel);
    }
    _scene.add(node);
    return thing;
  }

  Future<void> _loadVrm(CanvasElement e, _Thing thing) async {
    final file = MediaLibrary.instance.vrmFile(e.str('src'));
    if (file == null) return;
    final avatar = await VrmAvatar.fromBytes(await file.readAsBytes());
    if (!mounted || !identical(_things[e.id], thing)) return;
    thing.node.add(avatar.root);
    thing.avatar = avatar;
  }

  void _remove(_Thing t) => _scene.remove(t.node);

  // --- each frame ----------------------------------------------------------------

  void _onTick(Duration elapsed, double dt) {
    final t = elapsed.inMicroseconds / 1e6;
    final seen = <String>{};
    for (final e in _inside) {
      seen.add(e.id);
      var thing = _things[e.id];
      if (thing == null || thing.signature != _signature(e)) {
        if (thing != null) _remove(thing);
        thing = _things[e.id] = _build(e);
      }
      _place(e, thing, t, dt);
    }
    for (final id in [..._things.keys]) {
      if (!seen.contains(id)) _remove(_things.remove(id)!);
    }
    _aim(dt);
    final sun = _sun;
    if (sun != null) {
      sun.intensity = w.num_('light', 3);
      sun.castsShadow = w.flag('shadows', true);
    }
    for (final thing in _things.values) {
      final a = thing.avatar;
      if (a == null) continue;
      a.update(dt, camera: _camera);
      a.mtoonLighting.fromScene(_scene);
    }
  }

  void _place(CanvasElement e, _Thing thing, double t, double dt) {
    final v = c.currentValues(e);
    final s = v['scale'] ?? 1;
    final isShape = k3dShapes.contains(e.type);
    final size = isShape
        ? vm.Vector3(v['w']! * s, v['h']! * s, v['d']! * s)
        : vm.Vector3.all(s);
    final pos = vm.Vector3(v['x']!, v['y']!, v['z']!);
    double deg(String k) => (v[k] ?? 0) * math.pi / 180;
    // A VRM and a panel face -z (the viewer) at ry 0.
    var yaw = -deg('ry');
    if (e.flag('face_camera', false)) {
      final to = _camera.position - pos;
      yaw = math.atan2(to.x, to.z) + math.pi;
    }
    final turn =
        vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), yaw) *
        vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), deg('rx')) *
        vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), deg('rz'));
    thing.node.localTransform = vm.Matrix4.compose(pos, turn, size);
    thing.node.visible = e.flag('visible', true);
    final m = thing.material;
    if (m != null) {
      final opacity = (v['opacity'] ?? 1).clamp(0.0, 1.0);
      final color = _rgba(e.str('color'), opacity);
      m.baseColorFactor = color;
      m.roughnessFactor = e.num_('roughness', 0.7).clamp(0, 1);
      m.metallicFactor = e.num_('metallic', 0).clamp(0, 1);
      m.emissiveFactor = e.flag('glow', false)
          ? vm.Vector4(color.x, color.y, color.z, 1)
          : vm.Vector4.zero();
      m.alphaMode = color.w < 0.999 ? AlphaMode.blend : AlphaMode.opaque;
    }
    final a = thing.avatar;
    if (a != null) {
      poseVrm(a, e, t);
      expressVrm(a, e, t, c.mouthLevel(e.id));
      final look = e.flag('look_at_viewer', true);
      a.lookAt.enabled = look;
      a.lookAt.target = look ? _camera.position : null;
    }
  }

  /// Puts the camera where the world says, going round or following.
  void _aim(double dt) {
    final v = c.currentValues(w);
    var look = vm.Vector3(v['look_x']!, v['look_y']!, v['look_z']!);
    var eye = vm.Vector3(v['cam_x']!, v['cam_y']!, v['cam_z']!);
    final mode = w.str('camera_mode') ?? 'fixed';
    // Going round from where the camera is; back to it when it stops.
    _orbit = mode == 'orbit' ? _orbit + w.num_('orbit_speed', 10) * dt : 0;
    if (mode == 'follow') {
      final target = c.elements[w.str('follow') ?? ''];
      if (target != null && target.world == w.id) {
        final tv = c.currentValues(target);
        final at = vm.Vector3(tv['x']!, tv['y']! + 1.2, tv['z']!);
        eye += at - look;
        look = at;
      }
    }
    var offset = eye - look;
    final yaw = (_orbit + _dragYaw) * math.pi / 180;
    if (yaw != 0) offset = vm.Matrix3.rotationY(yaw) * offset;
    if (_dragPitch != 0) {
      final flat = vm.Vector3(offset.x, 0, offset.z);
      final dist = offset.length;
      final pitch =
          (math.asin((offset.y / dist).clamp(-1.0, 1.0)) +
                  _dragPitch * math.pi / 180)
              .clamp(-1.2, 1.4);
      final f = flat.length == 0 ? vm.Vector3(0, 0, -1) : flat.normalized();
      offset =
          f * (dist * math.cos(pitch)) +
          vm.Vector3(0, dist * math.sin(pitch), 0);
    }
    _camera
      ..fovRadiansY = (v['fov']!.clamp(10, 120)) * math.pi / 180
      ..position = look + offset
      ..target = look;
  }

  // --- touch -----------------------------------------------------------------------

  void _onTap(TapUpDetails d) {
    if (_size.isEmpty) return;
    // The ray's direction is not of unit length: made so, distances from
    // the scene and from the avatars compare.
    final raw = _camera.screenPointToRay(d.localPosition, _size);
    final ray = vm.Ray.originDirection(raw.origin, raw.direction.normalized());
    // Skinned meshes (a VRM's body) are left to the avatars' own test.
    final hit = _scene.raycast(ray, where: (n) => n.skin == null);
    String? id;
    var distance = hit?.distance ?? double.infinity;
    var point = hit?.worldPoint;
    // The thing the touched node belongs to.
    for (Node? n = hit?.node; n != null && id == null; n = n.parent) {
      for (final MapEntry(:key, :value) in _things.entries) {
        if (identical(value.node, n)) id = key;
      }
    }
    // A VRM's skinned body is not hit by the raycast (it tests the meshes
    // in their T pose): flutter_vrm's capsules follow the posed bones, and
    // tell which part was touched.
    String? part;
    for (final MapEntry(:key, :value) in _things.entries) {
      final h = value.avatar?.hitTest(ray);
      if (h != null && h.distance < distance) {
        distance = h.distance;
        id = key;
        point = h.point;
        part = h.bone?.name;
      }
    }
    final e = id == null ? null : c.elements[id];
    if (e == null || point == null) return;
    if (!e.flag('tappable', false) && !w.flag('tappable', false)) return;
    double r(double x) => double.parse(x.toStringAsFixed(2));
    c.emit(
      CanvasEvent('tap', e.id, {
        'x': r(point.x),
        'y': r(point.y),
        'z': r(point.z),
        'part': ?part,
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const SizedBox.expand();
    final sky = w.str('sky');
    Widget view = LayoutBuilder(
      builder: (context, box) {
        _size = Size(box.maxWidth, box.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _onTap,
          onPanUpdate: w.flag('user_camera', false)
              ? (d) => setState(() {
                  _dragYaw -= d.delta.dx * 0.3;
                  _dragPitch += d.delta.dy * 0.2;
                })
              : null,
          child: SceneView(_scene, camera: _camera, onTick: _onTick),
        );
      },
    );
    if (sky != null) {
      view = ColoredBox(color: _color(sky), child: view);
    }
    return view;
  }

  static Color _color(String hex) {
    final v = _rgba(hex, 1);
    return Color.from(alpha: v.w, red: v.x, green: v.y, blue: v.z);
  }
}
