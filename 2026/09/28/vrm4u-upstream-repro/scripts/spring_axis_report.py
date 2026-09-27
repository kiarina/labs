#!/usr/bin/env python3
"""Compare the two candidate boneAxis definitions on a VRM 1.0 rest skeleton.

VRMC_springBone 1.0: consecutive joints[j] (Head) and joints[j+1] (Tail) form a
pair, and the simulated tail starts at the Tail's rest position. VRM4U (master
615e632) instead derives boneAxis/boneLength from the Head's own local
translation (parent -> Head) and starts the simulated tail at the Head.

For every Head joint this prints the angle between
  spec axis    : Head -> Tail   (world rest positions)
  VRM4U axis   : parent -> Head (world rest positions)
and whether Tail is a direct child of Head.
"""

import json
import math
import struct
import sys


def local_matrix(node):
    x, y, z, w = node.get("rotation", [0, 0, 0, 1])
    sx, sy, sz = node.get("scale", [1, 1, 1])
    tx, ty, tz = node.get("translation", [0, 0, 0])
    r = [
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ]
    return [[r[0][0] * sx, r[0][1] * sy, r[0][2] * sz, tx],
            [r[1][0] * sx, r[1][1] * sy, r[1][2] * sz, ty],
            [r[2][0] * sx, r[2][1] * sy, r[2][2] * sz, tz],
            [0, 0, 0, 1]]


def mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def sub(a, b):
    return [a[i] - b[i] for i in range(3)]


def angle_deg(a, b):
    dot = sum(a[i] * b[i] for i in range(3))
    na = math.sqrt(sum(v * v for v in a))
    nb = math.sqrt(sum(v * v for v in b))
    return math.degrees(math.acos(max(-1.0, min(1.0, dot / (na * nb)))))


def main(path):
    data = open(path, "rb").read()
    json_len = struct.unpack_from("<I", data, 12)[0]
    gltf = json.loads(data[20:20 + json_len])
    nodes = gltf["nodes"]
    parent = {c: i for i, n in enumerate(nodes) for c in n.get("children", [])}

    world = {}

    def world_of(i):
        if i in world:
            return world[i]
        m = local_matrix(nodes[i])
        world[i] = mul(world_of(parent[i]), m) if i in parent else m
        return world[i]

    def pos(i):
        m = world_of(i)
        return [m[0][3], m[1][3], m[2][3]]

    print(f"{'spring':<12} {'head':<16} {'tail':<16} {'direct':<6} {'angle(spec,VRM4U)':>18}")
    for spring in gltf["extensions"]["VRMC_springBone"]["springs"]:
        joints = [j["node"] for j in spring["joints"]]
        for head, tail in zip(joints, joints[1:]):
            angle = angle_deg(sub(pos(tail), pos(head)), sub(pos(head), pos(parent[head])))
            print(f"{spring.get('name', ''):<12} {nodes[head]['name']:<16} {nodes[tail]['name']:<16} "
                  f"{str(parent.get(tail) == head):<6} {angle:18.1f}")


if __name__ == "__main__":
    main(sys.argv[1])
