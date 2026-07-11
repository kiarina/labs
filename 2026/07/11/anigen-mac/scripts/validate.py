import json
import struct
from pathlib import Path

from pygltflib import GLTF2


ROOT = Path(__file__).resolve().parents[1]
NAMES = ("miineko1", "miineko2")


def glb_header(path: Path) -> dict:
    with path.open("rb") as f:
        magic, version, length = struct.unpack("<4sII", f.read(12))
    return {
        "magic": magic.decode("ascii", errors="replace"),
        "version": version,
        "declared_bytes": length,
        "file_bytes": path.stat().st_size,
    }


def inspect(path: Path, require_skin: bool) -> dict:
    if not path.is_file() or path.stat().st_size == 0:
        raise FileNotFoundError(f"missing or empty: {path}")
    header = glb_header(path)
    if header["magic"] != "glTF" or header["version"] != 2:
        raise ValueError(f"not a glTF 2 binary: {path}")
    gltf = GLTF2().load_binary(str(path))
    primitives = [primitive for mesh in gltf.meshes for primitive in mesh.primitives]
    position_accessors = [
        gltf.accessors[p.attributes.POSITION]
        for p in primitives
        if p.attributes.POSITION is not None
    ]
    index_accessors = [gltf.accessors[p.indices] for p in primitives if p.indices is not None]
    attrs = sorted(
        {
            key
            for primitive in primitives
            for key, value in vars(primitive.attributes).items()
            if value is not None and not key.startswith("_")
        }
    )
    result = {
        **header,
        "meshes": len(gltf.meshes),
        "primitives": len(primitives),
        "vertices": sum(a.count for a in position_accessors),
        "indices": sum(a.count for a in index_accessors),
        "triangles": sum(a.count // 3 for a in index_accessors),
        "nodes": len(gltf.nodes),
        "skins": len(gltf.skins),
        "joints": sum(len(skin.joints) for skin in gltf.skins),
        "animations": len(gltf.animations),
        "attributes": attrs,
    }
    if result["meshes"] == 0 or result["vertices"] == 0:
        raise ValueError(f"GLB has no mesh geometry: {path}")
    if require_skin and (
        result["skins"] == 0
        or result["joints"] == 0
        or "JOINTS_0" not in attrs
        or "WEIGHTS_0" not in attrs
    ):
        raise ValueError(f"rigged mesh is missing skin/joint attributes: {path}")
    return result


report = {"cases": {}, "valid": True}
for name in NAMES:
    case = {}
    try:
        case["mesh"] = inspect(ROOT / "results" / name / "mesh.glb", True)
        case["skeleton"] = inspect(ROOT / "results" / name / "skeleton.glb", False)
        processed = ROOT / "results" / name / "processed_image.png"
        if not processed.is_file() or processed.stat().st_size == 0:
            raise FileNotFoundError(f"missing or empty: {processed}")
        case["processed_image_bytes"] = processed.stat().st_size
        case["valid"] = True
    except Exception as exc:
        case["valid"] = False
        case["error"] = str(exc)
        report["valid"] = False
    report["cases"][name] = case

output = ROOT / "results" / "validation.json"
output.parent.mkdir(exist_ok=True)
output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
raise SystemExit(0 if report["valid"] else 1)
