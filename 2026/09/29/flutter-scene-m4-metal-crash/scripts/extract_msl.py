"""Writes every MSL source in Flutter GPU .shaderbundle files to out/msl/.

Usage: python3 scripts/extract_msl.py <bundle>...
The Metal backends of a shader bundle carry MSL text as flatbuffer strings
(a little-endian u32 length followed by the text), so each source is found by
its `metal_stdlib` include and read back from the length before it.
"""
import os
import re
import struct
import sys

os.makedirs("out/msl", exist_ok=True)
for path in sys.argv[1:]:
    data = open(path, "rb").read()
    bundle = os.path.basename(path).split(".")[1]
    seen = set()
    count = 0
    for match in re.finditer(rb"metal_stdlib", data):
        for back in range(400):
            start = match.start() - back
            if data[start:start + 1] != b"#":
                continue
            length = struct.unpack("<I", data[start - 4:start])[0]
            if match.start() < start + length <= len(data) and length > 100:
                break
        else:
            continue
        if start in seen:
            continue
        seen.add(start)
        source = data[start:start + length].decode("utf-8", "replace")
        entry = re.findall(r"(vertex|fragment)\s+\S+\s+(\w+)\s*\(", source)
        count += 1
        stage, name = entry[0] if entry else ("unknown", "unknown")
        with open(f"out/msl/{bundle}_{count:03d}_{stage}_{name}.metal", "w") as f:
            f.write(source)
    print(f"{path}: {count}")
