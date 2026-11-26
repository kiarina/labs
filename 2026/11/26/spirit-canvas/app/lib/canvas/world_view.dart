import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:flutter_vrm/flutter_vrm.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../media.dart';
import 'canvas_model.dart';
import 'vrm_element.dart';
import 'world_fx.dart';

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
///
/// The look (Part 12): `sky: "physical"` draws a sky from the sun
/// (`sun_elevation`, `sun_azimuth` in degrees; below 0 is night) that also
/// lights the world. `bloom` (strength; things with `glow` above 1 shine
/// out), `fog` (density) and `fog_color`, `exposure`, `warmth`,
/// `saturation`, `vignette`, `god_rays`, `focus` (metres; with `aperture`),
/// `reflections` (true: shiny things reflect the world), `ao` (true: soft
/// shade in corners). All numbers move with a transition.
/// More things: `light` (a point light: `color`, `intensity`, `range`,
/// `flicker`), `particles`, `scatter` and `tube` (see world_fx.dart).
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
  PointLight? light;
  Particles? particles;
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
  TextureSource? _dot;
  PhysicalSkySource? _sky;
  SunLight? _sunLight;
  vm.Vector3? _bakedSun;
  double _sinceBake = 0;

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
      softDot().then((dot) {
        if (!mounted) return;
        setState(() {
          _dot = dot;
          _ready = true;
        });
      });
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
    'light' => 'light',
    // Rebuilt when what they are made of changes (not when they move).
    'particles' =>
      'particles:${jsonEncode([
        for (final k in const ['preset', 'w', 'h', 'd', 'color', 'size', 'glow', 'burst']) e.props[k],
      ])}',
    'tube' => 'tube:${jsonEncode([e.props['points'], e.props['radius']])}',
    'scatter' =>
      'scatter:${jsonEncode([
        for (final k in const ['shape', 'count', 'seed', 'w', 'd', 'size', 'stretch', 'colors', 'color', 'dome', 'glow', 'roughness', 'metallic', 'spin']) e.props[k],
      ])}',
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
    } else if (e.type == 'light') {
      final light = thing.light = PointLight();
      node.addComponent(PointLightComponent(light));
    } else if (e.type == 'particles') {
      final p = thing.particles = Particles(e, _dot!);
      node.add(p.node);
    } else if (e.type == 'scatter') {
      node.add(scatter(e, _geometry));
    } else if (e.type == 'tube') {
      final geometry = tube(e);
      if (geometry != null) {
        final material = thing.material = PhysicallyBasedMaterial();
        node.add(Node(mesh: Mesh(geometry, material)));
      }
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
    _look(dt);
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
    // Particles keep a turn-free box, scatter its own sizes.
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
      // `glow` 1 is lit by itself; above 1 is brighter than lit (and blooms).
      final glow = v['glow'] ?? 0;
      final emissive = rgb(e.str('glow_color') ?? e.str('color')) * glow;
      m.emissiveFactor = vm.Vector4(emissive.x, emissive.y, emissive.z, 1);
      m.alphaMode = color.w < 0.999 ? AlphaMode.blend : AlphaMode.opaque;
    }
    final light = thing.light;
    if (light != null) {
      var strength = v['intensity'] ?? 1;
      if (e.flag('flicker', false)) {
        final p = (e.id.hashCode % 100) / 10;
        strength *=
            0.82 +
            0.1 * math.sin(t * 7.1 + p) +
            0.08 * math.sin(t * 13.7 + p * 2.3);
      }
      light
        ..color = rgb(e.str('color'), '#FFD9A0')
        ..intensity = strength * (e.flag('visible', true) ? 1 : 0)
        ..range = e.num_('range', 0);
    }
    thing.particles?.update(e, v['rate'] ?? 0);
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
    // `fov` is the vertical angle on a landscape (16:10) screen. A narrower
    // screen keeps that width in view and shows more above and below, so a
    // phone held upright does not cut the sides off.
    var fov = v['fov']!.clamp(10, 120) * math.pi / 180;
    final aspect = _size.isEmpty ? 1.6 : _size.width / _size.height;
    if (aspect < 1.6) {
      fov = math.min(
        2 * math.atan(math.tan(fov / 2) * 1.6 / aspect),
        150 * math.pi / 180,
      );
    }
    _camera
      ..fovRadiansY = fov
      ..position = look + offset
      ..target = look;
  }

  /// The world's sky, sun, light and finish.
  void _look(double dt) {
    final v = c.currentValues(w);
    final el = v['sun_elevation']! * math.pi / 180;
    final az = v['sun_azimuth']! * math.pi / 180;
    final toSun = vm.Vector3(
      math.cos(el) * math.sin(az),
      math.sin(el),
      math.cos(el) * math.cos(az),
    );
    if (w.str('sky') == 'physical') {
      var sky = _sky;
      if (sky == null) {
        sky = _sky = PhysicalSkySource();
        _scene.skybox = Skybox(sky);
        _scene.skyEnvironment = SkyEnvironment(sky, faceResolution: 64);
        _scene.sunLight = _sunLight = SunLight(
          sky,
          shadowCascadeCount: 2,
          shadowMaxDistance: 40,
        );
      }
      sky.sunDirection = toSun;
      _sunLight!
        ..intensityScale = v['light']! / 3
        ..castsShadow = w.flag('shadows', true);
      // The soft light from the sky is baked again when the sun has moved
      // (at most 4 times a second).
      _sinceBake += dt;
      final baked = _bakedSun;
      if (baked == null ||
          (_sinceBake > 0.25 && baked.angleTo(toSun) > 0.4 * math.pi / 180)) {
        _scene.skyEnvironment?.invalidate();
        _bakedSun = toSun.clone();
        _sinceBake = 0;
      }
    } else {
      if (_sky != null) {
        _sky = null;
        _scene.sunLight = null;
        _scene.skyEnvironment = null;
        _scene.skybox = null;
        _scene.directionalLight = _sun;
      }
      final sun = _sun;
      if (sun != null) {
        sun.intensity = v['light']!;
        sun.castsShadow = w.flag('shadows', true);
        if (w.props.containsKey('sun_elevation')) {
          sun.direction = -toSun;
        }
      }
    }
    final post = _scene.postProcess;
    post.bloom
      ..enabled = v['bloom']! > 0
      ..intensity = v['bloom']!
      ..threshold = w.num_('bloom_threshold', 1);
    _scene.fog
      ..enabled = v['fog']! > 0
      ..density = v['fog']!
      ..color = rgb(w.str('fog_color'), '#9FB4C8')
      // Glow toward the sun, only while it is up.
      ..sunInScatter = w.str('sky') == 'physical'
          ? 0.3 * (v['sun_elevation']! / 10).clamp(0.0, 1.0)
          : 0;
    _scene.exposure = v['exposure']!;
    post.colorGrading
      ..enabled = v['warmth'] != 0 || v['saturation'] != 1
      ..temperature = v['warmth']!.clamp(-1, 1)
      ..saturation = v['saturation']!;
    post.vignette
      ..enabled = v['vignette']! > 0
      ..intensity = v['vignette']!;
    _scene.godRays
      ..enabled = v['god_rays']! > 0
      ..intensity = v['god_rays']!;
    _scene.depthOfField
      ..enabled = v['focus']! > 0
      ..focusDistance = math.max(0.1, v['focus']!)
      ..fStop = w.num_('aperture', 2.8);
    _scene.screenSpaceReflections.enabled = w.flag('reflections', false);
    _scene.ambientOcclusion.enabled = w.flag('ao', false);
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
    final sky = w.str('sky') == 'physical' ? null : w.str('sky');
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
