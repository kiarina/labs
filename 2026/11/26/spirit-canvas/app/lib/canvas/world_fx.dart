import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'canvas_model.dart';

/// The parts of a world beyond plain shapes: particles, scattered copies,
/// tubes along a curve (Part 12).

/// A soft round dot, for particles.
Future<TextureSource> softDot() async {
  const n = 64;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawCircle(
    const Offset(n / 2, n / 2),
    n / 2,
    ui.Paint()
      ..shader = ui.Gradient.radial(
        const Offset(n / 2, n / 2),
        n / 2,
        const [
          Color(0xFFFFFFFF),
          Color(0x99FFFFFF),
          Color(0x22FFFFFF),
          Color(0x00FFFFFF),
        ],
        const [0, 0.25, 0.6, 1],
      ),
  );
  final image = await recorder.endRecording().toImage(n, n);
  return GpuTextureSource(await gpuTextureFromImage(image));
}

/// `#RRGGBB` as linear-ish RGB.
vm.Vector3 rgb(String? hex, [String fallback = '#FFFFFF']) {
  final h = (hex ?? fallback).replaceAll('#', '');
  double part(int i) => h.length >= i + 2
      ? (int.tryParse(h.substring(i, i + 2), radix: 16) ?? 255) / 255
      : 1;
  return vm.Vector3(part(0), part(2), part(4));
}

/// The particle presets, by name.
const kParticlePresets = [
  'fireflies',
  'snow',
  'petals',
  'embers',
  'sparkles',
  'rain',
  'dust',
  'magic',
];

/// Particles for `type: particles`: `preset` (above), the box they start in
/// (`w`, `h`, `d` metres; `y` its bottom), `rate` (a second; default by
/// preset), `color`, `size` (metres), `glow` (brightness; above 1 blooms).
/// `burst` (a count): instead of a steady stream, that many at once, again
/// each time `trigger` changes.
class Particles {
  Particles(CanvasElement e, TextureSource dot)
    : preset = e.str('preset') ?? 'sparkles' {
    final burst = e.num_('burst', 0).round();
    final half = vm.Vector3(
      e.num_('w', 1) / 2,
      e.num_('h', 1) / 2,
      e.num_('d', 1) / 2,
    );
    final color = rgb(e.str('color'), _defaultColor[preset] ?? '#FFFFFF');
    final glow = switch (e.props['glow']) {
      final num n => n.toDouble(),
      _ => _defaultGlow[preset] ?? 1.0,
    };
    final c = color * glow;
    vm.Vector4 at(double a) => vm.Vector4(c.x, c.y, c.z, a);
    final size = e.num_('size', _defaultSize[preset] ?? 0.05);
    final up = vm.Vector3(0, 1, 0);
    final (
      lifetime,
      speed,
      gravity,
      modules,
      facing,
      additive,
    ) = switch (preset) {
      'fireflies' => (
        const UniformFloat(4, 8),
        const UniformFloat(0.02, 0.1),
        vm.Vector3(0, 0.02, 0),
        <ParticleModule>[
          TurbulenceModule(strength: 0.6, frequency: 0.5, seed: 3),
          // Blinking: bright, faint, bright.
          ColorOverLifeModule(
            GradientColor(
              ColorGradient([
                ColorStop(0, at(0)),
                ColorStop(0.15, at(1)),
                ColorStop(0.35, at(0.15)),
                ColorStop(0.55, at(1)),
                ColorStop(0.75, at(0.2)),
                ColorStop(0.9, at(1)),
                ColorStop(1, at(0)),
              ]),
            ),
          ),
        ],
        BillboardFacing.spherical,
        true,
      ),
      'snow' => (
        const UniformFloat(6, 10),
        const UniformFloat(0, 0.05),
        vm.Vector3(0, -0.35, 0),
        <ParticleModule>[
          TurbulenceModule(strength: 0.25, frequency: 0.6, seed: 5),
          ColorOverLifeModule(
            GradientColor(
              ColorGradient([
                ColorStop(0, at(0)),
                ColorStop(0.1, at(0.9)),
                ColorStop(0.9, at(0.9)),
                ColorStop(1, at(0)),
              ]),
            ),
          ),
        ],
        BillboardFacing.spherical,
        false,
      ),
      'petals' => (
        const UniformFloat(5, 9),
        const UniformFloat(0, 0.1),
        vm.Vector3(0, -0.25, 0),
        <ParticleModule>[
          TurbulenceModule(strength: 0.5, frequency: 0.7, seed: 9),
          const RotationModule(),
          ColorOverLifeModule(
            GradientColor(
              ColorGradient([
                ColorStop(0, at(0)),
                ColorStop(0.1, at(1)),
                ColorStop(0.85, at(1)),
                ColorStop(1, at(0)),
              ]),
            ),
          ),
        ],
        BillboardFacing.spherical,
        false,
      ),
      'embers' => (
        const UniformFloat(1.2, 2.4),
        const UniformFloat(0.4, 1.2),
        vm.Vector3(0, 0.8, 0),
        <ParticleModule>[
          LinearDragModule(0.4),
          TurbulenceModule(strength: 2.0, frequency: 1.4, seed: 41),
          SizeOverLifeModule(
            CurveFloat(ParticleCurve.linear(from: 1, to: 0.4)),
          ),
          ColorOverLifeModule(
            GradientColor(
              ColorGradient([
                ColorStop(0, at(0)),
                ColorStop(0.05, at(1)),
                ColorStop(0.6, at(0.8)),
                ColorStop(1, vm.Vector4(c.x * 0.5, c.y * 0.2, 0, 0)),
              ]),
            ),
          ),
        ],
        BillboardFacing.velocityStretched,
        true,
      ),
      'rain' => (
        const UniformFloat(0.8, 1.2),
        const UniformFloat(0, 0.2),
        vm.Vector3(0, -9, 0),
        <ParticleModule>[ColorOverLifeModule(ConstantColor(at(0.45)))],
        BillboardFacing.velocityStretched,
        false,
      ),
      'dust' => (
        const UniformFloat(4, 8),
        const UniformFloat(0.01, 0.04),
        vm.Vector3(0, 0.01, 0),
        <ParticleModule>[
          TurbulenceModule(strength: 0.15, frequency: 0.8, seed: 71),
          ColorOverLifeModule(
            GradientColor(
              ColorGradient([
                ColorStop(0, at(0)),
                ColorStop(0.3, at(0.6)),
                ColorStop(0.7, at(0.5)),
                ColorStop(1, at(0)),
              ]),
            ),
          ),
        ],
        BillboardFacing.spherical,
        true,
      ),
      'magic' => (
        const UniformFloat(1.5, 3),
        const UniformFloat(0.2, 0.6),
        vm.Vector3(0, 0.6, 0),
        <ParticleModule>[
          TurbulenceModule(
            strength: 1.2,
            frequency: 1.1,
            scroll: vm.Vector3(0, 0.6, 0),
            seed: 13,
          ),
          SizeOverLifeModule(
            CurveFloat(ParticleCurve.linear(from: 1, to: 0.2)),
          ),
          ColorOverLifeModule(
            GradientColor(
              ColorGradient([
                ColorStop(0, at(0)),
                ColorStop(0.1, at(1)),
                ColorStop(1, at(0)),
              ]),
            ),
          ),
        ],
        BillboardFacing.spherical,
        true,
      ),
      // sparkles
      _ => (
        const UniformFloat(0.6, 1.4),
        burst > 0 ? const UniformFloat(1.5, 3.5) : const UniformFloat(0.2, 0.6),
        vm.Vector3(0, burst > 0 ? -2.0 : 0.1, 0),
        <ParticleModule>[
          LinearDragModule(burst > 0 ? 2.5 : 0.5),
          SizeOverLifeModule(CurveFloat(ParticleCurve.linear(from: 1, to: 0))),
          ColorOverLifeModule(
            GradientColor(
              ColorGradient([
                ColorStop(0, at(1)),
                ColorStop(0.5, at(0.9)),
                ColorStop(1, at(0)),
              ]),
            ),
          ),
        ],
        BillboardFacing.spherical,
        true,
      ),
    };
    final EmitterShape shape = burst > 0
        ? const SphereEmitterShape(radius: 0.05)
        : BoxEmitterShape(halfExtents: half, direction: up);
    system = ParticleSystem(
      maxParticles: burst > 0 ? math.max(burst, 1) : 2048,
      shape: shape,
      spawner: burst > 0
          ? Spawner(bursts: [ParticleBurst(time: 0, count: burst)])
          : Spawner(rate: e.num_('rate', _defaultRate[preset] ?? 20)),
      lifetime: lifetime,
      startSpeed: speed,
      startSize: UniformFloat(size * 0.6, size * 1.3),
      gravity: gravity,
      modules: modules,
      looping: burst <= 0,
      duration: burst > 0 ? 4 : 5,
      // Steady ones start already full.
      prewarm: burst > 0 ? 0 : 6,
      seed: e.id.hashCode & 0xFFFF,
    );
    final material = SpriteMaterial(colorTexture: dot)
      ..blendMode = additive ? SpriteBlendMode.additive : SpriteBlendMode.alpha
      ..softDepthFade = 0.2;
    final emitter = ParticleEmitterComponent(system: system, material: material)
      ..facing = facing
      ..velocityStretch = preset == 'rain' ? 0.06 : 0.03;
    // Bursts come from the element's point; streams fill the box above it.
    node = Node(
      localTransform: vm.Matrix4.translation(
        vm.Vector3(0, burst > 0 ? 0 : half.y, 0),
      ),
    )..addComponent(emitter);
    trigger = e.props['trigger'];
  }

  final String preset;
  late final ParticleSystem system;
  late final Node node;
  Object? trigger;

  void update(CanvasElement e, double rate) {
    if (e.num_('burst', 0) > 0) {
      if (e.props['trigger'] != trigger) {
        trigger = e.props['trigger'];
        system.reset();
      }
    } else {
      system.spawner.rate = math.max(0, rate);
    }
  }

  static const _defaultColor = {
    'fireflies': '#C8FF6A',
    'snow': '#FFFFFF',
    'petals': '#FFB7D0',
    'embers': '#FF8A3D',
    'sparkles': '#FFE08A',
    'rain': '#AFC8E8',
    'dust': '#FFE9C0',
    'magic': '#7FE8FF',
  };
  static const _defaultGlow = {
    'fireflies': 3.0,
    'embers': 3.0,
    'sparkles': 3.0,
    'magic': 2.5,
    'dust': 1.2,
  };
  static const _defaultSize = {
    'fireflies': 0.05,
    'snow': 0.04,
    'petals': 0.06,
    'embers': 0.03,
    'sparkles': 0.06,
    'rain': 0.015,
    'dust': 0.02,
    'magic': 0.05,
  };
  static const _defaultRate = {
    'fireflies': 6.0,
    'snow': 60.0,
    'petals': 12.0,
    'embers': 25.0,
    'sparkles': 20.0,
    'rain': 400.0,
    'dust': 15.0,
    'magic': 30.0,
  };
}

/// Many copies of one shape at once (`type: scatter`), drawn in one go:
/// `shape` (a 3D shape type), `count`, `seed`, the area (`w`, `d` metres
/// round the element's x, z; on the ground at its y), `size` [min, max]
/// metres, `stretch` [x, y, z] (the shape's proportions), `colors` (picked
/// at random), `roughness`, `metallic`, `glow`, `spin` (random turn round
/// y, default true). `dome` (metres): on a half sphere of that radius
/// instead, as stars.
Node scatter(CanvasElement e, Geometry Function(String) geometry) {
  final material = PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
    ..roughnessFactor = e.num_('roughness', 0.8).clamp(0, 1)
    ..metallicFactor = e.num_('metallic', 0).clamp(0, 1);
  final glow = switch (e.props['glow']) {
    final num n => n.toDouble(),
    true => 1.0,
    _ => 0.0,
  };
  final mesh = InstancedMesh(
    geometry: geometry(e.str('shape') ?? 'sphere'),
    material: material,
  );
  final rnd = math.Random(e.num_('seed', 1).round());
  final sizes = (e.props['size'] as List?)?.whereType<num>().toList();
  final lo = sizes != null && sizes.isNotEmpty ? sizes[0].toDouble() : 0.2;
  final hi = sizes != null && sizes.length > 1 ? sizes[1].toDouble() : lo;
  final st = (e.props['stretch'] as List?)?.whereType<num>().toList();
  final stretch = st != null && st.length == 3
      ? vm.Vector3(st[0].toDouble(), st[1].toDouble(), st[2].toDouble())
      : vm.Vector3.all(1);
  final colors = [
    for (final c
        in (e.props['colors'] as List?) ?? [e.str('color') ?? '#CCCCCC'])
      rgb('$c'),
  ];
  final w = e.num_('w', 4), d = e.num_('d', 4);
  final dome = e.num_('dome', 0);
  final count = e.num_('count', 100).round().clamp(1, 20000);
  final lift = e.str('shape') == 'plane' ? 0.0 : 0.5;
  for (var i = 0; i < count; i++) {
    final s = lo + (hi - lo) * rnd.nextDouble();
    final vm.Vector3 pos;
    if (dome > 0) {
      // Even over the upper half sphere.
      final u = rnd.nextDouble(), v = rnd.nextDouble();
      final theta = 2 * math.pi * u;
      final y = 0.03 + 0.97 * v;
      final r = math.sqrt(1 - y * y);
      pos = vm.Vector3(r * math.cos(theta), y, r * math.sin(theta)) * dome;
    } else {
      pos = vm.Vector3(
        (rnd.nextDouble() - 0.5) * w,
        0,
        (rnd.nextDouble() - 0.5) * d,
      );
    }
    final turn = e.flag('spin', true)
        ? vm.Quaternion.axisAngle(
            vm.Vector3(0, 1, 0),
            rnd.nextDouble() * 2 * math.pi,
          )
        : vm.Quaternion.identity();
    final scale = stretch * s;
    final m = vm.Matrix4.compose(pos, turn, scale)
      ..translateByVector3(vm.Vector3(0, lift, 0));
    final c = colors[rnd.nextInt(colors.length)];
    mesh.addInstance(m, color: vm.Vector4(c.x, c.y, c.z, 1));
  }
  if (glow > 0) {
    // The instance colour does not reach the emission: one glow colour.
    final c = colors.first * glow;
    material.emissiveFactor = vm.Vector4(c.x, c.y, c.z, 1);
  }
  return Node()..addComponent(InstancedMeshComponent(mesh));
}

/// A tube along a smooth curve (`type: tube`): `points` [[x, y, z], ...]
/// metres from the element's place, `radius`.
Geometry? tube(CanvasElement e) {
  final pts = [
    for (final p in (e.props['points'] as List?) ?? const [])
      if (p is List && p.length == 3 && p.every((x) => x is num))
        vm.Vector3(
          (p[0] as num).toDouble(),
          (p[1] as num).toDouble(),
          (p[2] as num).toDouble(),
        ),
  ];
  if (pts.length < 2) return null;
  return TubeGeometry(
    CatmullRomPath(pts),
    radius: e.num_('radius', 0.05),
    stations: math.max(32, pts.length * 16),
  );
}
