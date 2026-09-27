"""Inspect material and UV isolation of the face on a rigged FBX.

Run with Blender: MIINEKO_FBX=/path/to/model.fbx blender --background \
    --python scripts/inspect_face_uv.py
"""

import bpy
import json
import os
from collections import Counter
from pathlib import Path


fbx_path = os.environ.get("MIINEKO_FBX")
if not fbx_path:
    raise RuntimeError("Set MIINEKO_FBX to the local Tripo FBX path")

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.fbx(filepath=fbx_path, use_image_search=True)
meshes = [obj for obj in bpy.data.objects if obj.type == "MESH"]
if len(meshes) != 1:
    raise RuntimeError(f"Expected one mesh, got {[obj.name for obj in meshes]}")
obj = meshes[0]
mesh = obj.data
uv_layer = mesh.uv_layers.active
if not uv_layer:
    raise RuntimeError("No active UV layer")


def in_ellipse(center, x, z, radius_x, radius_z):
    return ((center.x - x) / radius_x) ** 2 + ((center.z - z) / radius_z) ** 2 < 1


regions = {
    "eye_left": lambda p: p.y < -0.17 and in_ellipse(p, 0.15, 0.62, 0.105, 0.100),
    "eye_right": lambda p: p.y < -0.17 and in_ellipse(p, -0.15, 0.62, 0.105, 0.100),
    "nose_mouth": lambda p: p.y < -0.17 and in_ellipse(p, 0, 0.476, 0.095, 0.075),
    "head_front": lambda p: p.y < 0 and 0.39 < p.z < 0.87,
}


def face_uv_bounds(polygons):
    values = [uv_layer.data[loop].uv for poly in polygons for loop in poly.loop_indices]
    return {
        "u": [round(min(v.x for v in values), 6), round(max(v.x for v in values), 6)],
        "v": [round(min(v.y for v in values), 6), round(max(v.y for v in values), 6)],
    } if values else None


def uv_island_sizes(polygons):
    selected = {poly.index for poly in polygons}
    parent = {index: index for index in selected}

    def root(index):
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index

    edges = {}
    for poly in polygons:
        loops = list(poly.loop_indices)
        for i, loop_index in enumerate(loops):
            other_loop = loops[(i + 1) % len(loops)]
            ends = []
            for index in (loop_index, other_loop):
                loop = mesh.loops[index]
                uv = uv_layer.data[index].uv
                ends.append((loop.vertex_index, round(uv.x, 6), round(uv.y, 6)))
            key = tuple(sorted(ends))
            previous = edges.get(key)
            if previous is None:
                edges[key] = poly.index
            else:
                parent[root(poly.index)] = root(previous)
    return sorted(Counter(root(index) for index in selected).values(), reverse=True)


report = {
    "blenderVersion": bpy.app.version_string,
    "mesh": obj.name,
    "vertices": len(mesh.vertices),
    "polygons": len(mesh.polygons),
    "materials": [slot.material.name if slot.material else None for slot in obj.material_slots],
    "shapeKeys": [k.name for k in mesh.shape_keys.key_blocks] if mesh.shape_keys else [],
    "regions": {},
}
for name, predicate in regions.items():
    polygons = [poly for poly in mesh.polygons if predicate(poly.center)]
    island_sizes = uv_island_sizes(polygons)
    report["regions"][name] = {
        "polygons": len(polygons),
        "materialSlots": sorted({poly.material_index for poly in polygons}),
        "uvBounds": face_uv_bounds(polygons),
        "uvIslandCount": len(island_sizes),
        "largestUvIslands": island_sizes[:10],
    }
print(json.dumps(report, ensure_ascii=False, indent=2))
output = os.environ.get("MIINEKO_UV_REPORT")
if output:
    Path(output).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
