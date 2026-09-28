import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart';

import 'vrm_avatar.dart';

/// A place in the garden an avatar can occupy, at human scale (meters).
class Spot {
  const Spot(
    this.name,
    this.activity,
    this.position,
    this.yaw, {
    this.seatHeight = 0.45,
  });
  final String name;
  final AvatarActivity activity;
  final Vector3 position; // floor point (standing/sitting) or hips (lying)
  final double yaw; // 0 faces -Z
  final double seatHeight;
}

/// A wall segment that the camera may cut away when it stands between the
/// camera and the room. [outward] points away from the room it bounds.
class Wall {
  Wall(this.full, this.low, this.outward, this.interior);
  final Node full;
  final Node low;
  final Vector3 outward;
  final bool interior;
}

/// Low-poly, human-scale version of the Spirits Garden tile garden: a Brain
/// living room on top, a shared corridor, and Body rooms below it with doors
/// onto the corridor. 1 tile = 1 m. +X is east, +Z is south.
class Garden {
  Garden(this.bodyRooms);

  final int bodyRooms;
  final Node root = Node(name: 'garden');
  final List<Wall> walls = [];
  final List<Spot> spots = [];
  late final Vector3 center;
  late final double extent;

  static const double wallHeight = 2.4;
  static const double wallThickness = 0.12;

  static const double livingWidth = 12;
  static const double livingDepth = 7;
  static const double corridorDepth = 2;
  static const double roomWidth = 5;
  static const double roomDepth = 4.5;

  final Map<int, PhysicallyBasedMaterial> _materials = {};

  PhysicallyBasedMaterial _mat(
    int rgb, {
    double roughness = 0.8,
    double metallic = 0.0,
  }) {
    return _materials.putIfAbsent(rgb ^ (roughness * 1000).round() << 24, () {
      final m = PhysicallyBasedMaterial()
        ..baseColorFactor = Vector4(
          ((rgb >> 16) & 0xff) / 255,
          ((rgb >> 8) & 0xff) / 255,
          (rgb & 0xff) / 255,
          1,
        )
        ..roughnessFactor = roughness
        ..metallicFactor = metallic;
      return m;
    });
  }

  Node _box(
    String name,
    Vector3 center,
    Vector3 size,
    int rgb, {
    double roughness = 0.8,
  }) {
    return Node(
      name: name,
      localTransform: Matrix4.translation(center),
      mesh: Mesh(CuboidGeometry(size), _mat(rgb, roughness: roughness)),
    );
  }

  void _add(Node n) => root.add(n);

  void build() {
    final corridorZ0 = livingDepth;
    final corridorZ1 = livingDepth + corridorDepth;
    final width = math.max(livingWidth, bodyRooms * roomWidth + 1);
    final roomsZ1 = corridorZ1 + roomDepth;
    center = Vector3(width / 2, 0, roomsZ1 / 2);
    extent = math.max(width, roomsZ1);

    // Ground and floors.
    _add(
      _box(
        'ground',
        Vector3(width / 2, -0.06, roomsZ1 / 2),
        Vector3(width + 8, 0.1, roomsZ1 + 8),
        0x2c3a2c,
        roughness: 1,
      ),
    );
    _add(
      _box(
        'floor_living',
        Vector3(livingWidth / 2, 0, livingDepth / 2),
        Vector3(livingWidth, 0.02, livingDepth),
        0x9b7653,
      ),
    );
    _add(
      _box(
        'floor_corridor',
        Vector3(width / 2, 0, corridorZ0 + 1),
        Vector3(width, 0.02, corridorDepth),
        0x8a8a84,
      ),
    );
    for (var i = 0; i < bodyRooms; i++) {
      final x0 = 0.5 + i * roomWidth;
      _add(
        _box(
          'floor_room$i',
          Vector3(x0 + roomWidth / 2, 0, corridorZ1 + roomDepth / 2),
          Vector3(roomWidth, 0.02, roomDepth),
          0xb59a7a,
        ),
      );
    }

    // Walls. North and west/east of the living room, corridor ends, room
    // separators. Doors are gaps.
    _wallX('living_n', 0, livingWidth, 0, Vector3(0, 0, -1));
    _wallZ('living_w', 0, 0, corridorZ1, Vector3(-1, 0, 0));
    _wallZ('living_e', livingWidth, 0, livingDepth, Vector3(1, 0, 0));
    if (width > livingWidth) {
      _wallX('corr_ne', livingWidth, width, corridorZ0, Vector3(0, 0, -1));
    }
    _wallZ('corr_e', width, corridorZ0, roomsZ1, Vector3(1, 0, 0));
    // Living/corridor boundary with a 1.6 m opening in the middle.
    _wallX(
      'living_s1',
      0,
      livingWidth / 2 - 0.8,
      corridorZ0,
      Vector3(0, 0, 1),
      interior: true,
    );
    _wallX(
      'living_s2',
      livingWidth / 2 + 0.8,
      livingWidth,
      corridorZ0,
      Vector3(0, 0, 1),
      interior: true,
    );
    for (var i = 0; i < bodyRooms; i++) {
      final x0 = 0.5 + i * roomWidth;
      final door = x0 + 1.2;
      _wallX(
        'room${i}_n1',
        x0,
        door,
        corridorZ1,
        Vector3(0, 0, -1),
        interior: true,
      );
      _wallX(
        'room${i}_n2',
        door + 1.0,
        x0 + roomWidth,
        corridorZ1,
        Vector3(0, 0, -1),
        interior: true,
      );
      _wallX('room${i}_s', x0, x0 + roomWidth, roomsZ1, Vector3(0, 0, 1));
      _wallZ(
        'room${i}_w',
        x0,
        corridorZ1,
        roomsZ1,
        Vector3(-1, 0, 0),
        interior: i > 0,
      );
      if (i == bodyRooms - 1) {
        _wallZ(
          'room${i}_e',
          x0 + roomWidth,
          corridorZ1,
          roomsZ1,
          Vector3(1, 0, 0),
        );
      }
    }

    _furnishLiving();
    for (var i = 0; i < bodyRooms; i++) {
      _furnishRoom(i, 0.5 + i * roomWidth, corridorZ1);
    }
  }

  void _wallX(
    String name,
    double x0,
    double x1,
    double z,
    Vector3 outward, {
    bool interior = false,
  }) {
    final len = x1 - x0;
    if (len <= 0.05) return;
    _wall(
      name,
      Vector3((x0 + x1) / 2, 0, z),
      Vector3(len, 0, wallThickness),
      outward,
      interior,
    );
  }

  void _wallZ(
    String name,
    double x,
    double z0,
    double z1,
    Vector3 outward, {
    bool interior = false,
  }) {
    final len = z1 - z0;
    if (len <= 0.05) return;
    _wall(
      name,
      Vector3(x, 0, (z0 + z1) / 2),
      Vector3(wallThickness, 0, len),
      outward,
      interior,
    );
  }

  void _wall(
    String name,
    Vector3 at,
    Vector3 footprint,
    Vector3 outward,
    bool interior,
  ) {
    final color = interior ? 0xd8d2c4 : 0xe6e0d2;
    final full = _box(
      '${name}_full',
      at + Vector3(0, wallHeight / 2, 0),
      Vector3(footprint.x, wallHeight, footprint.z),
      color,
    );
    final low = _box(
      '${name}_low',
      at + Vector3(0, 0.15, 0),
      Vector3(footprint.x, 0.3, footprint.z),
      0xa89f8c,
    )..visible = false;
    _add(full);
    _add(low);
    walls.add(Wall(full, low, outward, interior));
  }

  /// Cut away walls whose outward side faces the camera, so the quarter
  /// view looks into the rooms (the usual life-sim cutaway).
  void updateCutaway(Vector3 cameraForwardFlat, {bool enabled = true}) {
    for (final w in walls) {
      // Interior walls always come down in the overview; exterior walls
      // only on the side facing the camera.
      final facesCamera = w.outward.dot(cameraForwardFlat) < -0.3;
      final cut = enabled && (w.interior || facesCamera);
      w.full.visible = !cut;
      w.low.visible = cut;
    }
  }

  void _furnishLiving() {
    // Rug.
    _add(
      _box(
        'rug',
        Vector3(4.5, 0.015, 3.8),
        Vector3(3.2, 0.01, 2.2),
        0x7d3b3b,
        roughness: 1,
      ),
    );
    // Sofa facing south (+Z): seat, back, arms. Sitting faces +Z => yaw pi.
    const sofaX = 4.5, sofaZ = 2.2;
    _add(
      _box(
        'sofa_seat',
        Vector3(sofaX, 0.22, sofaZ),
        Vector3(2.2, 0.44, 0.9),
        0x3d5a80,
      ),
    );
    _add(
      _box(
        'sofa_back',
        Vector3(sofaX, 0.6, sofaZ - 0.38),
        Vector3(2.2, 0.8, 0.18),
        0x3d5a80,
      ),
    );
    _add(
      _box(
        'sofa_arm_l',
        Vector3(sofaX - 1.02, 0.55, sofaZ),
        Vector3(0.18, 0.3, 0.9),
        0x34506f,
      ),
    );
    _add(
      _box(
        'sofa_arm_r',
        Vector3(sofaX + 1.02, 0.55, sofaZ),
        Vector3(0.18, 0.3, 0.9),
        0x34506f,
      ),
    );
    spots.add(
      Spot(
        'sofa_l',
        AvatarActivity.rest,
        Vector3(sofaX - 0.5, 0, sofaZ + 0.05),
        math.pi,
        seatHeight: 0.44,
      ),
    );
    spots.add(
      Spot(
        'sofa_r',
        AvatarActivity.rest,
        Vector3(sofaX + 0.5, 0, sofaZ + 0.05),
        math.pi,
        seatHeight: 0.44,
      ),
    );
    // Low table and a terminal on the east wall.
    _add(
      _box(
        'coffee_table',
        Vector3(sofaX, 0.2, 3.8),
        Vector3(1.2, 0.4, 0.6),
        0x6b4f3a,
      ),
    );
    _add(
      _box(
        'tv',
        Vector3(sofaX, 1.0, 5.2),
        Vector3(1.6, 0.9, 0.08),
        0x111111,
        roughness: 0.3,
      ),
    );
    _add(
      _box(
        'tv_stand',
        Vector3(sofaX, 0.25, 5.25),
        Vector3(1.8, 0.5, 0.4),
        0x4a3a2c,
      ),
    );

    // Dining table with four chairs.
    const tx = 9.3, tz = 3.2;
    _add(
      _box(
        'table_top',
        Vector3(tx, 0.72, tz),
        Vector3(1.4, 0.05, 0.9),
        0x8b6b4a,
      ),
    );
    for (final (dx, dz) in [
      (-0.62, -0.38),
      (0.62, -0.38),
      (-0.62, 0.38),
      (0.62, 0.38),
    ]) {
      _add(
        _box(
          'table_leg',
          Vector3(tx + dx, 0.35, tz + dz),
          Vector3(0.06, 0.7, 0.06),
          0x5a4533,
        ),
      );
    }
    for (final (i, dx, dz, yaw) in [
      (0, -0.35, -0.8, math.pi), // north side, facing south
      (1, 0.35, -0.8, math.pi),
      (2, -0.35, 0.8, 0.0), // south side, facing north
      (3, 0.35, 0.8, 0.0),
    ]) {
      final cx = tx + dx, cz = tz + dz;
      _chair('chair$i', Vector3(cx, 0, cz), yaw);
      spots.add(
        Spot(
          'chair$i',
          AvatarActivity.rest,
          Vector3(cx, 0, cz),
          yaw,
          seatHeight: 0.46,
        ),
      );
    }

    // Bookshelf and plants.
    _add(
      _box(
        'bookshelf',
        Vector3(1.2, 0.9, 0.35),
        Vector3(1.6, 1.8, 0.35),
        0x5b4636,
      ),
    );
    for (var r = 0; r < 4; r++) {
      _add(
        _box(
          'books$r',
          Vector3(1.2, 0.3 + r * 0.42, 0.42),
          Vector3(1.4, 0.26, 0.22),
          [0x8e3b46, 0x3b6e8e, 0x6e8e3b, 0xc9a227][r],
        ),
      );
    }
    _plant(Vector3(11.3, 0, 0.7));
    _plant(Vector3(0.7, 0, 6.3));

    // Standing spots in the living room and corridor.
    spots.add(
      Spot(
        'stand_living',
        AvatarActivity.idle,
        Vector3(6.8, 0, 4.4),
        math.pi * 0.8,
      ),
    );
    spots.add(
      Spot('stand_window', AvatarActivity.idle, Vector3(8.0, 0, 1.2), math.pi),
    );
    spots.add(
      Spot(
        'stand_corridor',
        AvatarActivity.idle,
        Vector3(3.0, 0, livingDepth + 1),
        -math.pi / 2,
      ),
    );
  }

  void _chair(String name, Vector3 at, double yaw) {
    final chair = Node(
      name: name,
      localTransform: Matrix4.translation(at)..rotateY(yaw),
    );
    Node box(Vector3 c, Vector3 s, int rgb) => Node(
      localTransform: Matrix4.translation(c),
      mesh: Mesh(CuboidGeometry(s), _mat(rgb)),
    );
    // Chair local frame: sitter faces -Z, so the back is at +Z.
    chair.add(box(Vector3(0, 0.44, 0), Vector3(0.46, 0.05, 0.46), 0x7a5c41));
    chair.add(box(Vector3(0, 0.75, 0.21), Vector3(0.46, 0.6, 0.05), 0x7a5c41));
    for (final (dx, dz) in [
      (-0.2, -0.2),
      (0.2, -0.2),
      (-0.2, 0.2),
      (0.2, 0.2),
    ]) {
      chair.add(
        box(Vector3(dx, 0.21, dz), Vector3(0.04, 0.42, 0.04), 0x5a4533),
      );
    }
    _add(chair);
  }

  void _plant(Vector3 at) {
    _add(
      Node(
        name: 'pot',
        localTransform: Matrix4.translation(at + Vector3(0, 0.2, 0)),
        mesh: Mesh(
          CylinderGeometry(
            bottomRadius: 0.18,
            topRadius: 0.24,
            height: 0.4,
            radialSegments: 12,
          ),
          _mat(0x9a5b3c),
        ),
      ),
    );
    _add(
      Node(
        name: 'leaves',
        localTransform: Matrix4.translation(at + Vector3(0, 0.85, 0)),
        mesh: Mesh(
          IcosphereGeometry(radius: 0.45, subdivisions: 1),
          _mat(0x3f7d3a),
        ),
      ),
    );
  }

  void _furnishRoom(int i, double x0, double z0) {
    // Bed along the south-west, head at the west wall. Lying hips point.
    final bedX = x0 + 1.25, bedZ = z0 + roomDepth - 1.0;
    _add(
      _box(
        'bed_frame$i',
        Vector3(bedX, 0.2, bedZ),
        Vector3(2.1, 0.4, 1.0),
        0x6b5440,
      ),
    );
    _add(
      _box(
        'mattress$i',
        Vector3(bedX + 0.05, 0.47, bedZ),
        Vector3(1.95, 0.14, 0.92),
        0xe8e4dc,
      ),
    );
    _add(
      _box(
        'pillow$i',
        Vector3(x0 + 0.45, 0.58, bedZ),
        Vector3(0.35, 0.1, 0.6),
        0xffffff,
      ),
    );
    _add(
      _box(
        'blanket$i',
        Vector3(bedX + 0.45, 0.56, bedZ),
        Vector3(1.1, 0.06, 0.96),
        [0x6a8caf, 0xaf6a8c, 0x8caf6a][i % 3],
      ),
    );
    // Head toward -X (west): the body's head is opposite its front yaw, so
    // front faces +X => yaw = -pi/2.
    spots.add(
      Spot(
        'bed$i',
        i.isEven ? AvatarActivity.lightSleep : AvatarActivity.deepSleep,
        Vector3(x0 + 1.2, 0.62, bedZ),
        -math.pi / 2,
      ),
    );

    // Desk and chair on the east side.
    final deskX = x0 + roomWidth - 0.8, deskZ = z0 + 1.4;
    _add(
      _box(
        'desk$i',
        Vector3(deskX, 0.72, deskZ),
        Vector3(0.7, 0.05, 1.2),
        0x8b6b4a,
      ),
    );
    _add(
      _box(
        'desk_leg$i',
        Vector3(deskX, 0.36, deskZ),
        Vector3(0.6, 0.72, 0.05),
        0x5a4533,
      ),
    );
    _add(
      _box(
        'monitor$i',
        Vector3(deskX + 0.2, 1.0, deskZ),
        Vector3(0.05, 0.4, 0.6),
        0x151515,
        roughness: 0.3,
      ),
    );
    // Chair west of the desk, sitter faces +X (east) => yaw = -pi/2.
    _chair('desk_chair$i', Vector3(deskX - 0.75, 0, deskZ), -math.pi / 2);
    spots.add(
      Spot(
        'desk$i',
        AvatarActivity.rest,
        Vector3(deskX - 0.75, 0, deskZ),
        -math.pi / 2,
        seatHeight: 0.46,
      ),
    );
    // Lamp.
    _add(
      Node(
        name: 'lamp$i',
        localTransform: Matrix4.translation(Vector3(x0 + 0.4, 0.8, z0 + 0.5)),
        mesh: Mesh(
          CylinderGeometry(
            bottomRadius: 0.2,
            topRadius: 0.12,
            height: 0.3,
            radialSegments: 10,
          ),
          _mat(0xf2e3b3),
        ),
      ),
    );
    spots.add(
      Spot(
        'stand_room$i',
        AvatarActivity.idle,
        Vector3(x0 + 2.8, 0, z0 + 2.4),
        math.pi,
      ),
    );
  }
}
