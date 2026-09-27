import bpy
import json
import os
from pathlib import Path

if not os.environ.get("MIINEKO_FBX"):
    raise RuntimeError("Set MIINEKO_FBX to the local Tripo FBX path")
SOURCE = Path(os.environ["MIINEKO_FBX"])
OUT = Path(__file__).resolve().parents[1] / "artifacts"
OUT.mkdir(exist_ok=True)

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.fbx(filepath=str(SOURCE), use_image_search=True)

report = {"source": str(SOURCE), "objects": [], "images": [], "materials": []}
for obj in bpy.data.objects:
    entry = {"name": obj.name, "type": obj.type, "parent": obj.parent.name if obj.parent else None,
             "location": list(obj.location), "rotation": list(obj.rotation_euler), "scale": list(obj.scale),
             "dimensions": list(obj.dimensions)}
    if obj.type == "ARMATURE":
        entry["bones"] = [{"name": b.name, "parent": b.parent.name if b.parent else None,
                           "head_local": list(b.head_local), "tail_local": list(b.tail_local)} for b in obj.data.bones]
    if obj.type == "MESH":
        entry["vertices"] = len(obj.data.vertices)
        entry["faces"] = len(obj.data.polygons)
        entry["shape_keys"] = [k.name for k in obj.data.shape_keys.key_blocks] if obj.data.shape_keys else []
        entry["vertex_groups"] = [g.name for g in obj.vertex_groups]
        entry["material_slots"] = [s.material.name if s.material else None for s in obj.material_slots]
        entry["modifiers"] = [(m.name, m.type) for m in obj.modifiers]
    report["objects"].append(entry)
for img in bpy.data.images:
    report["images"].append({"name": img.name, "filepath": img.filepath, "size": list(img.size), "packed": bool(img.packed_file)})
for mat in bpy.data.materials:
    report["materials"].append({"name": mat.name, "nodes": [{"name": n.name, "type": n.type,
                                    "image": n.image.name if n.type == "TEX_IMAGE" and n.image else None}
                                   for n in mat.node_tree.nodes] if mat.use_nodes else []})
(OUT / "fbx-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
bpy.ops.wm.save_as_mainfile(filepath=str(OUT / "imported.blend"))
print(json.dumps({"object_count": len(report["objects"]), "mesh_count": sum(o["type"] == "MESH" for o in report["objects"]),
                  "armature_count": sum(o["type"] == "ARMATURE" for o in report["objects"]),
                  "bone_count": sum(len(o.get("bones", [])) for o in report["objects"]),
                  "materials": len(report["materials"]), "images": len(report["images"])}, ensure_ascii=False))
