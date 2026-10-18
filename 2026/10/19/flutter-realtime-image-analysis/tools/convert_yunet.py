"""Make the YuNet model that kiarina uses runnable on ONNX Runtime.

kiarina runs `face_detection_yunet_2023mar_int8bq.onnx` through OpenCV's
FaceDetectorYN. ONNX Runtime cannot run that file: its bias DequantizeLinear
nodes carry `block_size` with per-tensor scales, which ONNX Runtime rejects,
and the input is declared as a fixed 1x3x640x640 while OpenCV feeds the image
at its own size (padded to a multiple of 32).

This script dequantizes every constant DequantizeLinear into a float32
initializer ((q - zero_point) * scale, each scale repeated over its block),
and makes the input height and width symbolic. Nothing else changes, so the
float32 weights are exactly the values OpenCV computes from the same file.

Usage (from the lab directory):
  uv run --project tools python tools/convert_yunet.py
"""

import hashlib
import json
import sys
from pathlib import Path

import numpy as np
import onnx
from onnx import numpy_helper

LAB_DIR = Path(__file__).resolve().parent.parent
SRC = LAB_DIR / "models/kiarina-cache/models/yunet/face_detection_yunet_2023mar_int8bq.onnx"
DST = LAB_DIR / "models/yunet/yunet_2023mar_dequantized.onnx"


def dequantize(q: np.ndarray, scale: np.ndarray, zero_point: np.ndarray, axis: int, block: int) -> np.ndarray:
    q = q.astype(np.float32)
    zp = zero_point.astype(np.float32)
    s = scale.astype(np.float32)

    if s.size == 1:
        return ((q - zp.reshape(())) * s.reshape(())).astype(np.float32)

    if block > 0:
        s = np.repeat(s, block, axis=axis)
        zp = np.repeat(zp, block, axis=axis)
        index = [slice(None)] * q.ndim
        index[axis] = slice(0, q.shape[axis])
        s = s[tuple(index)]
        zp = zp[tuple(index)]
    else:
        shape = [1] * q.ndim
        shape[axis] = -1
        s = s.reshape(shape)
        zp = zp.reshape(shape)

    return ((q - zp) * s).astype(np.float32)


def main() -> None:
    if not SRC.exists():
        sys.exit(f"missing {SRC.relative_to(LAB_DIR)}: run tools/make_fixtures.py first (kiarina downloads it)")

    model = onnx.load(SRC)
    graph = model.graph
    inits = {i.name: i for i in graph.initializer}
    kept_nodes = []
    new_inits = []
    removed = set()

    for node in graph.node:
        if node.op_type == "DequantizeLinear" and all(name in inits for name in node.input):
            attrs = {a.name: onnx.helper.get_attribute_value(a) for a in node.attribute}
            q, s, zp = (numpy_helper.to_array(inits[name]) for name in node.input)
            value = dequantize(q, s, zp, int(attrs.get("axis", 1)), int(attrs.get("block_size", 0)))
            new_inits.append(numpy_helper.from_array(value, node.output[0]))
            removed.update(node.input)
            continue
        kept_nodes.append(node)

    still_used = {name for node in kept_nodes for name in node.input}
    graph.ClearField("node")
    graph.node.extend(kept_nodes)
    remaining = [i for i in graph.initializer if i.name not in removed or i.name in still_used]
    graph.ClearField("initializer")
    graph.initializer.extend(remaining + new_inits)

    dims = graph.input[0].type.tensor_type.shape.dim
    dims[2].ClearField("dim_value")
    dims[2].dim_param = "height"
    dims[3].ClearField("dim_value")
    dims[3].dim_param = "width"

    onnx.checker.check_model(model)
    DST.parent.mkdir(parents=True, exist_ok=True)
    onnx.save(model, DST)

    print(json.dumps({
        "source": SRC.name,
        "source_sha256": hashlib.sha256(SRC.read_bytes()).hexdigest(),
        "output": DST.name,
        "output_sha256": hashlib.sha256(DST.read_bytes()).hexdigest(),
        "dequantized_nodes": len(new_inits),
        "bytes": DST.stat().st_size,
    }, indent=1))


if __name__ == "__main__":
    main()
