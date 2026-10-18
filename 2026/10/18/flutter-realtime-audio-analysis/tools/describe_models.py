"""Write fixtures/models.json: download facts, licenses and I/O signatures.

Usage (from the lab directory, after make_fixtures.py and convert_yamnet.sh):
  uv run --project tools python tools/describe_models.py
"""

import hashlib
import json
from pathlib import Path
from typing import Any

import onnx
import onnxruntime as ort
from ai_edge_litert.interpreter import Interpreter

LAB_DIR = Path(__file__).resolve().parent.parent
CACHE = LAB_DIR / "models" / "kiarina-cache" / "models"

# url = what kiarina-agi-audio (commit 9d483457) downloads.
# pinned_url = an immutable URL that served the same bytes on 2026-10-18 (checked by sha256),
# for the Dart app to use where kiarina's url points at a moving branch.
MODELS: list[dict[str, Any]] = [
    {
        "name": "silero-vad",
        "file": CACHE / "silero-vad" / "silero_vad.onnx",
        "url": "https://raw.githubusercontent.com/snakers4/silero-vad/master/src/silero_vad/data/silero_vad.onnx",
        "pinned_url": "https://raw.githubusercontent.com/snakers4/silero-vad/bfdc0193023f121ea5b3cc7b176dbed570a68a59/src/silero_vad/data/silero_vad.onnx",
        "license": "MIT",
        "license_source": "github.com/snakers4/silero-vad LICENSE",
        "notes": "kiarina's url follows the master branch; bfdc019 ('add v6.2 model', 2025-11-06) is the last commit touching the file.",
    },
    {
        "name": "pyannote-segmentation-3.0",
        "file": CACHE / "pyannote-segmentation-3.0" / "model.onnx",
        "url": "https://huggingface.co/onnx-community/pyannote-segmentation-3.0/resolve/main/onnx/model.onnx",
        "pinned_url": "https://huggingface.co/onnx-community/pyannote-segmentation-3.0/resolve/733a93b6473d019a773298e08cefa686894b1854/onnx/model.onnx",
        "license": "MIT",
        "license_source": "HF model card of onnx-community/pyannote-segmentation-3.0 (license: mit, base_model pyannote/segmentation-3.0) and of pyannote/segmentation-3.0 (license: mit, gated: auto)",
        "notes": "The original pyannote/segmentation-3.0 is gated (accept conditions to download); the onnx-community export is not gated.",
    },
    {
        "name": "ecapa-tdnn-onnx",
        "file": CACHE / "ecapa-tdnn-onnx" / "ecapa_tdnn.onnx",
        "url": "https://huggingface.co/pranjal-pravesh/ecapa_tdnn_onnx/resolve/04c3ffe4fd00b3b7853fd57db44e2e531d4817f2/ecapa_tdnn.onnx",
        "pinned_url": "https://huggingface.co/pranjal-pravesh/ecapa_tdnn_onnx/resolve/04c3ffe4fd00b3b7853fd57db44e2e531d4817f2/ecapa_tdnn.onnx",
        "license": "MIT",
        "license_source": "HF model card of pranjal-pravesh/ecapa_tdnn_onnx (license: mit). The card does not name its source checkpoint; SpeechBrain's spkrec-ecapa-voxceleb is apache-2.0.",
    },
    {
        "name": "clap-htsat-unfused-audio",
        "file": CACHE / "clap-onnx" / "audio_model.onnx",
        "url": "https://huggingface.co/Xenova/clap-htsat-unfused/resolve/main/onnx/audio_model.onnx",
        "pinned_url": "https://huggingface.co/Xenova/clap-htsat-unfused/resolve/c28f2883575e590e04d3146ff0713c2448d691ba/onnx/audio_model.onnx",
        "license": "Apache-2.0 (inherited)",
        "license_source": "Xenova/clap-htsat-unfused card has no license field (base_model laion/clap-htsat-unfused); laion/clap-htsat-unfused card: license apache-2.0",
        "notes": "kiarina's url follows the main branch.",
    },
    {
        "name": "clap-htsat-unfused-preprocessor-config",
        "file": CACHE / "clap-onnx" / "preprocessor_config.json",
        "url": "https://huggingface.co/laion/clap-htsat-unfused/resolve/84bcbbd1d619e407a8216371ddef36e458d95d93/preprocessor_config.json",
        "pinned_url": "https://huggingface.co/laion/clap-htsat-unfused/resolve/84bcbbd1d619e407a8216371ddef36e458d95d93/preprocessor_config.json",
        "license": "Apache-2.0",
        "license_source": "HF model card of laion/clap-htsat-unfused (license: apache-2.0)",
    },
    {
        "name": "yamnet-tflite",
        "file": CACHE / "yamnet" / "yamnet.tflite",
        "url": "https://tfhub.dev/google/lite-model/yamnet/classification/tflite/1?lite-format=tflite",
        "pinned_url": None,
        "license": "Apache-2.0",
        "license_source": "TF Hub / Kaggle Models page for google/yamnet (tflite classification v1); not re-checked by API",
        "notes": "tfhub.dev now 302-redirects to a short-lived signed storage.googleapis.com (Kaggle) URL. Int8-quantized; reads only waveform[0:15600].",
    },
    {
        "name": "yamnet-class-map",
        "file": CACHE / "yamnet" / "yamnet_class_map.csv",
        "url": "https://raw.githubusercontent.com/tensorflow/models/5c597f85268743140854f0e670f2175e8668553a/research/audioset/yamnet/yamnet_class_map.csv",
        "pinned_url": "https://raw.githubusercontent.com/tensorflow/models/5c597f85268743140854f0e670f2175e8668553a/research/audioset/yamnet/yamnet_class_map.csv",
        "license": "Apache-2.0",
        "license_source": "github.com/tensorflow/models LICENSE",
        "notes": "CSV header index,mid,display_name; 521 rows; display_name may contain commas (quoted).",
    },
    {
        "name": "yamnet-onnx",
        "file": LAB_DIR / "models" / "yamnet" / "yamnet.onnx",
        "url": None,
        "pinned_url": None,
        "license": "Apache-2.0 (derived from yamnet-tflite)",
        "license_source": "conversion of yamnet-tflite by tools/convert_yamnet.sh (tf2onnx 1.16.1, opset 17)",
        "notes": "Not hosted yet. Input length symbolic; N must be >= 15600.",
    },
]


def onnx_io(path: Path) -> dict[str, Any]:
    session = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    meta = session.get_modelmeta()
    return {
        "runtime": "onnx",
        "inputs": [{"name": i.name, "type": i.type, "shape": i.shape} for i in session.get_inputs()],
        "outputs": [{"name": o.name, "type": o.type, "shape": o.shape} for o in session.get_outputs()],
        "producer": meta.producer_name,
        "opsets": None,
    }


def onnx_opsets(path: Path) -> dict[str, int]:
    model = onnx.load(str(path), load_external_data=False)
    return {o.domain or "ai.onnx": o.version for o in model.opset_import}


def tflite_io(path: Path) -> dict[str, Any]:
    interpreter = Interpreter(model_path=str(path))

    def info(detail: dict[str, Any]) -> dict[str, Any]:
        return {
            "name": detail["name"],
            "type": detail["dtype"].__name__,
            "shape": [int(x) for x in detail["shape"]],
            "shape_signature": [int(x) for x in detail["shape_signature"]],
        }

    return {
        "runtime": "tflite",
        "inputs": [info(d) for d in interpreter.get_input_details()],
        "outputs": [info(d) for d in interpreter.get_output_details()],
    }


def main() -> None:
    out = []

    for model in MODELS:
        path: Path = model["file"]
        data = path.read_bytes()
        entry = {k: v for k, v in model.items() if k != "file"}
        entry.update(
            {
                "local_path": str(path.relative_to(LAB_DIR)),
                "sha256": hashlib.sha256(data).hexdigest(),
                "bytes": len(data),
            }
        )

        if path.suffix == ".onnx":
            io = onnx_io(path)
            io["opsets"] = onnx_opsets(path)
            entry["io"] = io
        elif path.suffix == ".tflite":
            entry["io"] = tflite_io(path)

        out.append(entry)

    target = LAB_DIR / "fixtures" / "models.json"
    target.write_text(json.dumps({"onnxruntime": ort.__version__, "models": out}, indent=1) + "\n")
    print(f"wrote {target.relative_to(LAB_DIR)}")


if __name__ == "__main__":
    main()
