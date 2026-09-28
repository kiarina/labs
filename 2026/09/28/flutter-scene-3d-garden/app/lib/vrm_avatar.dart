import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart';

/// What a Spirit is doing in the garden. Mirrors the Spirits Garden activity
/// names the 3D garden would have to show.
enum AvatarActivity { idle, rest, lightSleep, deepSleep }

/// The VRM 1.0 parts this lab reads itself. flutter_scene imports the GLB as
/// plain glTF and drops the `VRMC_vrm` JSON, so the JSON is parsed here and
/// glTF node indices are mapped onto the imported [Node]s.
class VrmDocument {
  VrmDocument._(this.json, this.vrm);

  final Map<String, dynamic> json;
  final Map<String, dynamic> vrm;

  static VrmDocument parse(Uint8List glb) {
    final bd = ByteData.sublistView(glb);
    if (bd.getUint32(0, Endian.little) != 0x46546C67) {
      throw const FormatException('not a GLB');
    }
    final jsonLength = bd.getUint32(12, Endian.little);
    final json = jsonDecode(
      utf8.decode(glb.sublist(20, 20 + jsonLength)),
    ) as Map<String, dynamic>;
    final vrm =
        (json['extensions'] as Map<String, dynamic>?)?['VRMC_vrm']
            as Map<String, dynamic>?;
    if (vrm == null) throw const FormatException('no VRMC_vrm (VRM 0.x?)');
    return VrmDocument._(json, vrm);
  }

  String get name =>
      (vrm['meta'] as Map<String, dynamic>?)?['name'] as String? ?? '?';

  /// humanBones name -> glTF node index.
  Map<String, int> get humanBones {
    final bones =
        (vrm['humanoid'] as Map<String, dynamic>)['humanBones']
            as Map<String, dynamic>;
    return {
      for (final e in bones.entries)
        e.key: (e.value as Map<String, dynamic>)['node'] as int,
    };
  }

  /// preset expression name -> list of (node, morph index, weight).
  Map<String, List<(int, int, double)>> get presetMorphBinds {
    final preset =
        ((vrm['expressions'] as Map<String, dynamic>?)?['preset']
            as Map<String, dynamic>?) ??
        const {};
    return {
      for (final e in preset.entries)
        e.key: [
          for (final b
              in ((e.value as Map<String, dynamic>)['morphTargetBinds']
                      as List?) ??
                  const [])
            (
              (b as Map<String, dynamic>)['node'] as int,
              b['index'] as int,
              (b['weight'] as num).toDouble(),
            ),
        ],
    };
  }
}

/// preset expression name -> list of (material, offset, scale) from
/// `textureTransformBinds` (eyelid / mouth overlays that slide a UV atlas).
extension VrmTextureBinds on VrmDocument {
  Map<String, List<(int, Vector2, Vector2)>> get presetTextureBinds {
    final preset =
        ((vrm['expressions'] as Map<String, dynamic>?)?['preset']
            as Map<String, dynamic>?) ??
        const {};
    Vector2 v2(Object? o, double d) {
      final l = (o as List?)?.cast<num>();
      return l == null
          ? Vector2(d, d)
          : Vector2(l[0].toDouble(), l[1].toDouble());
    }

    return {
      for (final e in preset.entries)
        e.key: [
          for (final b
              in ((e.value as Map<String, dynamic>)['textureTransformBinds']
                      as List?) ??
                  const [])
            (
              (b as Map<String, dynamic>)['material'] as int,
              v2(b['offset'], 0),
              v2(b['scale'], 1),
            ),
        ],
    };
  }
}

/// glTF material index -> the engine materials the importer made for it,
/// found through each mesh node's primitives (in glTF primitive order).
Map<int, Set<Material>> mapGltfMaterials(
  Map<String, dynamic> json,
  List<Node?> gltfNodes,
) {
  final nodes = (json['nodes'] as List).cast<Map<String, dynamic>>();
  final meshes = (json['meshes'] as List? ?? const [])
      .cast<Map<String, dynamic>>();
  final out = <int, Set<Material>>{};
  for (var i = 0; i < nodes.length; i++) {
    final meshIndex = nodes[i]['mesh'] as int?;
    final engine = gltfNodes[i];
    if (meshIndex == null || engine?.mesh == null) continue;
    final prims = (meshes[meshIndex]['primitives'] as List)
        .cast<Map<String, dynamic>>();
    final enginePrims = engine!.mesh!.primitives;
    if (prims.length != enginePrims.length) {
      debugPrint(
        'material mapping: node $i has ${prims.length} glTF '
        'primitives but ${enginePrims.length} engine primitives',
      );
      continue;
    }
    for (var p = 0; p < prims.length; p++) {
      final m = prims[p]['material'] as int?;
      if (m == null) continue;
      (out[m] ??= {}).add(enginePrims[p].material);
    }
  }
  return out;
}

/// Maps glTF node index -> imported [Node] by walking the glTF scene tree and
/// the imported tree in parallel. The runtime importer builds one engine node
/// per glTF node and adds children in glTF order; the names are checked so a
/// mismatch fails loudly instead of posing the wrong bone.
List<Node?> mapGltfNodes(Map<String, dynamic> json, Node importedRoot) {
  final nodes = (json['nodes'] as List).cast<Map<String, dynamic>>();
  final result = List<Node?>.filled(nodes.length, null);
  final scenes = (json['scenes'] as List?)?.cast<Map<String, dynamic>>();
  final sceneIndex = json['scene'] as int? ?? 0;
  final rootIndices = (scenes?[sceneIndex]['nodes'] as List? ?? const [])
      .cast<int>();

  void walk(int gltfIndex, Node engine) {
    final expected = (nodes[gltfIndex]['name'] as String?)?.isNotEmpty == true
        ? nodes[gltfIndex]['name'] as String
        : 'node_$gltfIndex';
    if (engine.name != expected) {
      throw StateError(
        'node mapping mismatch at $gltfIndex: $expected vs ${engine.name}',
      );
    }
    result[gltfIndex] = engine;
    final children = (nodes[gltfIndex]['children'] as List? ?? const [])
        .cast<int>();
    final engineChildren = engine.children
        .where((c) => !c.name.startsWith('__'))
        .toList();
    for (var i = 0; i < children.length; i++) {
      walk(children[i], engineChildren[i]);
    }
  }

  for (var i = 0; i < rootIndices.length; i++) {
    walk(rootIndices[i], importedRoot.children[i]);
  }
  return result;
}

class _Bone {
  _Bone(this.node) : rest = node.localTransform.clone();
  final Node node;
  final Matrix4 rest;
}

/// One VRM avatar placed in the garden. [root] is a wrapper the garden moves
/// and turns; the importer's own root (which carries the glTF handedness
/// flip) sits under it untouched.
class VrmAvatar {
  VrmAvatar._({
    required this.label,
    required this.doc,
    required this.root,
    required this.imported,
    required this.gltfNodes,
    required this.loadMilliseconds,
    required this.parseMilliseconds,
  }) {
    for (final e in doc.humanBones.entries) {
      final n = gltfNodes[e.value];
      if (n != null) _bones[e.key] = _Bone(n);
    }
    _binds = doc.presetMorphBinds;
    _textureBinds = doc.presetTextureBinds;
    _materials = mapGltfMaterials(doc.json, gltfNodes);
    pickProxy = Node(
      name: '__pick_$label',
      mesh: Mesh(
        CapsuleGeometry(radius: 0.28, height: 1.0),
        PhysicallyBasedMaterial(),
      ),
    )..visible = false;
    _blinkTimer = 1.0 + _rng.nextDouble() * 3.0;
    // The wrapper is still identity here, so this is the standing hips height.
    _restHipsHeight = _bones.containsKey('hips') ? boneWorld('hips').y : 0.9;
    _restHeadHeight = _bones.containsKey('head') ? boneWorld('head').y : 1.4;
  }

  final String label;
  final VrmDocument doc;
  final Node root;
  final Node imported;
  final List<Node?> gltfNodes;
  final int loadMilliseconds;
  final int parseMilliseconds;
  late final Node pickProxy;

  final Map<String, _Bone> _bones = {};
  late final Map<String, List<(int, int, double)>> _binds;
  late final Map<String, List<(int, Vector2, Vector2)>> _textureBinds;
  late final Map<int, Set<Material>> _materials;
  final Map<String, double> _expressionValues = {};
  final math.Random _rng = math.Random();

  AvatarActivity activity = AvatarActivity.idle;
  Vector3 position = Vector3.zero();
  double yaw = 0; // radians; 0 faces -Z in engine space.
  double seatHeight = 0.45;
  bool talking = false;
  Vector3? lookTarget;

  double _time = 0;
  double _blinkTimer = 0;
  double _blink = 0;
  double _blinkPhase = -1;

  static Future<VrmAvatar> load(String label, Uint8List bytes) async {
    final sw = Stopwatch()..start();
    final doc = VrmDocument.parse(bytes);
    final parseMs = sw.elapsedMilliseconds;
    final imported = await Node.fromGlbBytes(
      bytes,
      onWarning: (w) => debugPrint('[$label] glTF warning: $w'),
    );
    final loadMs = sw.elapsedMilliseconds;
    final mapping = mapGltfNodes(doc.json, imported);
    final wrapper = Node(name: 'avatar_$label')..add(imported);
    return VrmAvatar._(
      label: label,
      doc: doc,
      root: wrapper,
      imported: imported,
      gltfNodes: mapping,
      loadMilliseconds: loadMs,
      parseMilliseconds: parseMs,
    );
  }

  bool get hasFullLegs =>
      _bones.containsKey('leftLowerLeg') && _bones.containsKey('rightLowerLeg');

  Node? bone(String name) => _bones[name]?.node;

  Vector3 boneWorld(String name) =>
      _bones[name]!.node.globalTransform.getTranslation();

  /// Character front in world space for the current wrapper transform.
  Vector3 get front => Quaternion.axisAngle(
    Vector3(0, 1, 0),
    yaw,
  ).asRotationMatrix().transformed(Vector3(0, 0, -1));

  Vector3 get headWorld => boneWorld('head');

  /// Where the face looks, in world space: the character front carried
  /// through the wrapper's lying tilt.
  Vector3 get faceForward {
    if (activity == AvatarActivity.lightSleep ||
        activity == AvatarActivity.deepSleep) {
      return Vector3(0, 1, 0);
    }
    return front;
  }

  void setExpression(String preset, double value) {
    _expressionValues[preset] = value;
    final binds = _binds[preset];
    if (binds == null) return;
    for (final (node, index, weight) in binds) {
      final n = gltfNodes[node];
      if (n == null) continue;
      try {
        n.setMorphWeight(index, weight * value);
      } on Object catch (e) {
        debugPrint('[$label] morph $preset failed: $e');
      }
    }
  }

  bool posedOnce = false;

  void update(double dt) {
    posedOnce = true;
    _time += dt;
    _placeWrapper();
    for (final b in _bones.values) {
      b.node.localTransform = b.rest.clone();
    }
    _pose();
    _updateFace(dt);
    _updatePickProxy();
  }

  void _placeWrapper() {
    final lying =
        activity == AvatarActivity.lightSleep ||
        activity == AvatarActivity.deepSleep;
    final m = Matrix4.translation(position)..rotateY(yaw);
    if (activity == AvatarActivity.rest) {
      // Sitting: drop the body so the hips rest just above the seat.
      m.translateByVector3(
        Vector3(0, seatHeight + 0.09 - _restHipsHeight, 0.08),
      );
    }
    if (lying) {
      // Lie on the back: tilt the body so its front faces up, head toward
      // the character's original back. Hips sit on the mattress.
      m.rotateX(math.pi / 2);
      m.translateByVector3(Vector3(0, -_restHipsHeight, 0.0));
    }
    root.localTransform = m;
  }

  late final double _restHipsHeight;
  late final double _restHeadHeight;

  void _pose() {
    final up = Vector3(0, 1, 0);
    final wrapperRot = root.globalTransform.getRotation();
    // Character-space directions, carried into world by the wrapper (so the
    // same pose works lying down).
    Vector3 dir(double x, double y, double z) =>
        (wrapperRot * Vector3(x, y, z) as Vector3)..normalize();
    final charFront = dir(0, 0, -1);
    final charUp = dir(0, 1, 0);
    final charRight = up.cross(Vector3(0, 0, -1)); // (-1, 0, 0) in char space
    final charRightW = dir(charRight.x, charRight.y, charRight.z);
    final charLeftW = -charRightW;
    final charDown = -charUp;

    final breathe = math.sin(_time * 2 * math.pi / 4.2) * 0.02;
    _rotateInWorld('spine', charRightW, -breathe);

    // Arms down from whatever the rest pose is (T or A).
    _aim(
      'leftUpperArm',
      'leftLowerArm',
      (charDown * 0.95 + charLeftW * 0.18 + charFront * 0.05)..normalize(),
    );
    _aim(
      'rightUpperArm',
      'rightLowerArm',
      (charDown * 0.95 + charRightW * 0.18 + charFront * 0.05)..normalize(),
    );

    switch (activity) {
      case AvatarActivity.idle:
        _aim(
          'leftLowerArm',
          'leftHand',
          (charDown * 0.9 + charFront * 0.3)..normalize(),
        );
        _aim(
          'rightLowerArm',
          'rightHand',
          (charDown * 0.9 + charFront * 0.3)..normalize(),
        );
      case AvatarActivity.rest:
        _aim(
          'leftUpperLeg',
          'leftLowerLeg',
          (charFront * 0.98 + charLeftW * 0.08)..normalize(),
        );
        _aim(
          'rightUpperLeg',
          'rightLowerLeg',
          (charFront * 0.98 + charRightW * 0.08)..normalize(),
        );
        _aim('leftLowerLeg', 'leftFoot', charDown);
        _aim('rightLowerLeg', 'rightFoot', charDown);
        _aim(
          'leftLowerArm',
          'leftHand',
          (charFront * 0.9 + charDown * 0.3 + charRightW * 0.2)..normalize(),
        );
        _aim(
          'rightLowerArm',
          'rightHand',
          (charFront * 0.9 + charDown * 0.3 + charLeftW * 0.2)..normalize(),
        );
      case AvatarActivity.lightSleep:
      case AvatarActivity.deepSleep:
        _aim('leftLowerArm', 'leftHand', charDown);
        _aim('rightLowerArm', 'rightHand', charDown);
    }

    // Head follows a look target (the camera in focus view), clamped.
    final target = lookTarget;
    if (target != null && _bones.containsKey('head')) {
      final head = headWorld;
      final want = (target - head)..normalize();
      final face = charFront;
      final angle = math.acos(face.dot(want).clamp(-1.0, 1.0));
      if (angle > 1e-3 && angle < math.pi * 0.6) {
        final axis = face.cross(want)..normalize();
        _rotateInWorld('neck', axis, angle * 0.25);
        _rotateInWorld('head', axis, angle * 0.35);
      }
    }
  }

  /// Rotates [bone] about its own pivot by [angle] around the world [axis].
  void _rotateInWorld(String bone, Vector3 axis, double angle) {
    final b = _bones[bone];
    if (b == null || angle.abs() < 1e-6) return;
    final g = b.node.globalTransform;
    final pivot = g.getTranslation();
    final rot = Matrix4.compose(
      Vector3.zero(),
      Quaternion.axisAngle(axis, angle),
      Vector3(1, 1, 1),
    );
    final newGlobal =
        Matrix4.translation(pivot) * rot * Matrix4.translation(-pivot) * g
            as Matrix4;
    _setGlobal(b.node, newGlobal);
  }

  /// Rotates [bone] so the direction to its [child] bone points along
  /// [desired] (world). Works whatever the rest pose is.
  void _aim(String bone, String child, Vector3 desired) {
    final b = _bones[bone];
    final c = _bones[child];
    if (b == null || c == null) return;
    final from =
        c.node.globalTransform.getTranslation() -
        b.node.globalTransform.getTranslation();
    if (from.length2 < 1e-10) return;
    from.normalize();
    final to = desired.normalized();
    final dot = from.dot(to).clamp(-1.0, 1.0);
    final angle = math.acos(dot);
    if (angle < 1e-4) return;
    var axis = from.cross(to);
    if (axis.length2 < 1e-10) axis = Vector3(1, 0, 0);
    _rotateInWorld(bone, axis.normalized(), angle);
  }

  void _setGlobal(Node node, Matrix4 global) {
    final parent = node.parent;
    if (parent == null) {
      node.localTransform = global;
      return;
    }
    final inv = Matrix4.inverted(parent.globalTransform);
    node.localTransform = inv * global as Matrix4;
  }

  void _updateFace(double dt) {
    final sleeping =
        activity == AvatarActivity.lightSleep ||
        activity == AvatarActivity.deepSleep;
    if (sleeping) {
      _blink = 1;
    } else {
      _blinkTimer -= dt;
      if (_blinkTimer <= 0 && _blinkPhase < 0) {
        _blinkPhase = 0;
        _blinkTimer = 2.0 + _rng.nextDouble() * 4.0;
      }
      if (_blinkPhase >= 0) {
        _blinkPhase += dt / 0.16;
        _blink = _blinkPhase < 0.5 ? _blinkPhase * 2 : (1 - _blinkPhase) * 2;
        if (_blinkPhase >= 1) {
          _blinkPhase = -1;
          _blink = 0;
        }
      }
    }
    setExpression('blink', _blink.clamp(0.0, 1.0));
    setExpression('relaxed', activity == AvatarActivity.rest ? 0.6 : 0);
    final mouth = talking
        ? (0.5 + 0.5 * math.sin(_time * 14)) *
              (0.6 + 0.4 * math.sin(_time * 3.1))
        : 0.0;
    setExpression('aa', mouth.clamp(0.0, 1.0));
    _applyTextureBinds();
  }

  /// Sums every active expression's UV offset per material (VRM blends
  /// texture transform binds additively) and writes it to the material.
  void _applyTextureBinds() {
    final offsets = <int, Vector2>{};
    final scales = <int, Vector2>{};
    for (final e in _textureBinds.entries) {
      final v = _expressionValues[e.key] ?? 0;
      for (final (material, offset, scale) in e.value) {
        offsets[material] = (offsets[material] ?? Vector2.zero()) + offset * v;
        scales[material] =
            (scales[material] ?? Vector2(1, 1)) + (scale - Vector2(1, 1)) * v;
      }
    }
    for (final m in offsets.keys) {
      for (final mat in _materials[m] ?? const <Material>{}) {
        final t = TextureTransform(offset: offsets[m], scale: scales[m]);
        if (mat is PhysicallyBasedMaterial) {
          mat.baseColorTextureTransform = t;
          mat.emissiveTextureTransform = t;
        } else if (mat is UnlitMaterial) {
          mat.baseColorTextureTransform = t;
        }
      }
    }
  }

  /// Standing head height, for framing the face view.
  double get standingHeadHeight => _restHeadHeight;

  void _updatePickProxy() {
    if (!_bones.containsKey('hips') || !_bones.containsKey('head')) return;
    final hips = boneWorld('hips');
    final head = headWorld;
    final mid = (hips + head) * 0.5;
    final axis = head - hips;
    final len = axis.length;
    // Rotation taking +Y onto the hips->head axis. (vector_math's
    // Quaternion.rotated applies the inverse of what compose applies, so
    // build it from axis/angle rather than fromTwoVectors.)
    final dir = axis.normalized();
    final cross = Vector3(0, 1, 0).cross(dir);
    final q = cross.length2 < 1e-10
        ? Quaternion.identity()
        : Quaternion.axisAngle(
            cross.normalized(),
            math.acos(dir.y.clamp(-1.0, 1.0)),
          );
    pickProxy.localTransform = Matrix4.compose(
      mid,
      q,
      Vector3(1, math.max(len / 1.0, 0.5) * 1.6, 1),
    );
  }
}
