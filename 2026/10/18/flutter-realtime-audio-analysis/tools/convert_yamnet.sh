#!/usr/bin/env bash
# Convert the exact YAMNet TFLite used by kiarina-agi-audio to ONNX.
#   input : waveform_binary float32 [N]  (N >= 15600; only the first 15600 are read)
#   output: tower0/network/layer32/final_output float32 [1, 521]
# Usage: tools/convert_yamnet.sh   (run from anywhere; paths are relative to the lab)
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$TOOLS_DIR")"
WORK_DIR="$LAB_DIR/work"
OUT_DIR="$LAB_DIR/models/yamnet"
VENV="$TOOLS_DIR/.venv-tf"
OPSET="${OPSET:-17}"

TFLITE_URL="https://tfhub.dev/google/lite-model/yamnet/classification/tflite/1?lite-format=tflite"
TFLITE_SHA256="10c95ea3eb9a7bb4cb8bddf6feb023250381008177ac162ce169694d05c317de"

mkdir -p "$WORK_DIR" "$OUT_DIR"

if [ ! -x "$VENV/bin/python" ]; then
  uv venv --python 3.11 "$VENV"
  uv pip install --python "$VENV/bin/python" -r "$TOOLS_DIR/convert-requirements.txt"
fi

TFLITE="$WORK_DIR/yamnet.tflite"
if [ ! -f "$TFLITE" ] || [ "$(shasum -a 256 "$TFLITE" | cut -d' ' -f1)" != "$TFLITE_SHA256" ]; then
  # tfhub.dev redirects to a signed Kaggle storage URL.
  curl -fsSL -o "$TFLITE" "$TFLITE_URL"
fi
echo "$TFLITE_SHA256  $TFLITE" | shasum -a 256 -c -

RAW="$WORK_DIR/yamnet_raw_op${OPSET}.onnx"
"$VENV/bin/python" -m tf2onnx.convert --tflite "$TFLITE" --output "$RAW" --opset "$OPSET"

# The TFLite input is declared [15600] but kiarina resizes it per call; make the
# ONNX input dimension symbolic so any length works (the graph slices [0:15600]).
"$VENV/bin/python" - "$RAW" "$OUT_DIR/yamnet.onnx" <<'PY'
import sys
import onnx

src, dst = sys.argv[1], sys.argv[2]
model = onnx.load(src)
graph = model.graph
(inp,) = graph.input
dim = inp.type.tensor_type.shape.dim[0]
dim.ClearField("dim_value")
dim.dim_param = "num_samples"

# tf2onnx's generated node/tensor name suffixes vary between runs (the graph
# itself does not). Rename everything except graph inputs/outputs in graph
# order so the output bytes are reproducible.
keep = {i.name for i in graph.input} | {o.name for o in graph.output}
mapping = {}

def canon(name, prefix):
    if not name or name in keep:
        return name
    if name not in mapping:
        mapping[name] = f"{prefix}{len(mapping)}"
    return mapping[name]

for index, node in enumerate(graph.node):
    node.name = f"node{index}_{node.op_type}"
    for k, name in enumerate(node.input):
        node.input[k] = canon(name, "t")
    for k, name in enumerate(node.output):
        node.output[k] = canon(name, "t")
for init in graph.initializer:
    init.name = canon(init.name, "t")
inits = sorted(graph.initializer, key=lambda t: int(t.name[1:]) if t.name[1:].isdigit() else -1)
del graph.initializer[:]
graph.initializer.extend(inits)
for value in graph.value_info:
    value.name = canon(value.name, "t")
del graph.value_info[:]

onnx.checker.check_model(model)
onnx.save(model, dst)
print("wrote", dst)
PY

shasum -a 256 "$OUT_DIR/yamnet.onnx"
wc -c < "$OUT_DIR/yamnet.onnx"
