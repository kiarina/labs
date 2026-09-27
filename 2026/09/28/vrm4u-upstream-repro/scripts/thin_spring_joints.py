#!/usr/bin/env python3
"""Derive a VRM 1.0 whose spring chains skip intermediate nodes.

VRMC_springBone 1.0 allows joints[j] and joints[j+1] to be an ancestor and a
descendant rather than a direct parent and child. This keeps the first joint,
every even-indexed joint and the last joint of each spring, so the skipped
nodes remain in the skeleton as plain (non-joint) nodes between authored
joints. Geometry and every other extension are untouched.
"""

import json
import struct
import sys


def main(src: str, dst: str) -> None:
    data = open(src, "rb").read()
    magic, version, _ = struct.unpack_from("<III", data, 0)
    assert magic == 0x46546C67 and version == 2, "not a glTF 2.0 binary"
    json_len, json_type = struct.unpack_from("<II", data, 12)
    assert json_type == 0x4E4F534A
    gltf = json.loads(data[20:20 + json_len])
    rest = data[20 + json_len:]

    removed = 0
    for spring in gltf["extensions"]["VRMC_springBone"]["springs"]:
        joints = spring["joints"]
        if len(joints) < 3:
            continue
        kept = [j for i, j in enumerate(joints) if i % 2 == 0 or i == len(joints) - 1]
        removed += len(joints) - len(kept)
        spring["joints"] = kept

    chunk = json.dumps(gltf, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    chunk += b" " * (-len(chunk) % 4)
    body = struct.pack("<II", len(chunk), 0x4E4F534A) + chunk + rest
    with open(dst, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, 12 + len(body)) + body)
    print(f"{dst}: removed {removed} intermediate joints")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
