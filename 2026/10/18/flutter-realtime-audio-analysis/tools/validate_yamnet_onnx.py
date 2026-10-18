"""Compare the converted YAMNet ONNX against the pinned TFLite on the lab input.

Usage (from the lab directory, after tools/convert_yamnet.sh and make_fixtures.py):
  uv run --project tools python tools/validate_yamnet_onnx.py
Writes fixtures/yamnet_onnx_parity.json.
"""

import csv
import hashlib
import json
import platform
import re
import time
from pathlib import Path
from typing import Any

import numpy as np
import onnxruntime as ort
import soundfile as sf
from ai_edge_litert.interpreter import Interpreter, OpResolverType

LAB_DIR = Path(__file__).resolve().parent.parent
WAV_PATH = LAB_DIR / "work" / "conversation_16k.wav"
TFLITE_PATH = LAB_DIR / "models" / "kiarina-cache" / "models" / "yamnet" / "yamnet.tflite"
CLASS_MAP_PATH = TFLITE_PATH.with_name("yamnet_class_map.csv")
ONNX_PATH = LAB_DIR / "models" / "yamnet" / "yamnet.onnx"
SR = 16_000


def run_tflite(samples: np.ndarray, **kwargs: Any) -> np.ndarray:
    # Same calls as kiarina's YamnetAudioTaggingProvider._invoke (fresh interpreter;
    # default op resolver = XNNPACK delegate, like kiarina).
    interpreter = Interpreter(model_path=str(TFLITE_PATH), **kwargs)
    interpreter.allocate_tensors()
    index = interpreter.get_input_details()[0]["index"]
    interpreter.resize_tensor_input(index, [len(samples)], strict=False)
    interpreter.allocate_tensors()
    interpreter.set_tensor(index, samples.astype(np.float32))
    interpreter.invoke()
    out = interpreter.get_output_details()[0]["index"]
    return np.array(interpreter.get_tensor(out), dtype=np.float32)


def try_call(fn: Any, samples: np.ndarray) -> tuple[np.ndarray | None, str | None]:
    try:
        return fn(samples), None
    except Exception as exc:  # noqa: BLE001 - recorded as an observation
        message = re.sub(r"\S*/onnxruntime/", "onnxruntime/", str(exc).splitlines()[0])
        return None, f"{type(exc).__name__}: {message[:240]}"


def time_call(fn: Any, samples: np.ndarray, repeat: int = 20) -> dict[str, float]:
    fn(samples)
    times = []

    for _ in range(repeat):
        start = time.perf_counter()
        fn(samples)
        times.append((time.perf_counter() - start) * 1000)

    return {"median_ms": round(float(np.median(times)), 3), "min_ms": round(float(np.min(times)), 3)}


def main() -> None:
    pcm, sr = sf.read(WAV_PATH, dtype="int16")
    assert sr == SR
    wav = pcm.astype(np.float32) / 32768.0
    with open(CLASS_MAP_PATH, newline="", encoding="utf-8") as file:
        labels = [row["display_name"] for row in csv.DictReader(file)]

    sessions = {
        "ort_default": ort.InferenceSession(str(ONNX_PATH), providers=["CPUExecutionProvider"]),
    }
    options = ort.SessionOptions()
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    sessions["ort_no_optim"] = ort.InferenceSession(
        str(ONNX_PATH), sess_options=options, providers=["CPUExecutionProvider"]
    )
    input_name = sessions["ort_default"].get_inputs()[0].name

    def onnx_fn(name: str) -> Any:
        return lambda x: sessions[name].run(None, {input_name: x.astype(np.float32)})[0]

    cases = [
        ("window0_10s", wav[0:160000]),
        ("window1_remainder", wav[160000:]),
        ("slice_0.5s", wav[16000:24000]),
        ("slice_1s", wav[16000:32000]),
        ("slice_3.3s", wav[16000:68800]),
        ("exact_15600", wav[48000:63600]),
    ]
    # Extra: every 15600-sample crop at a 0.25 s hop over the whole file.
    crops = [wav[i : i + 15600] for i in range(0, len(wav) - 15600 + 1, 4000)]

    results = []
    lsb = 1.0 / 256.0  # output quantization step of the int8 logistic

    for name, samples in cases:
        ref, ref_err = try_call(run_tflite, samples)
        entry: dict[str, Any] = {"case": name, "num_samples": int(len(samples)), "tflite_error": ref_err}

        for sess in sessions:
            got, err = try_call(onnx_fn(sess), samples)
            item: dict[str, Any] = {"error": err}

            if got is not None:
                item["shape"] = list(got.shape)

            if got is not None and ref is not None:
                diff = np.abs(got - ref)
                item.update(
                    {
                        "max_abs_diff": float(diff.max()),
                        "mean_abs_diff": float(diff.mean()),
                        "max_abs_diff_in_lsb": float(diff.max() / lsb),
                        "num_scores_differing": int((diff > 0).sum()),
                        "top3_equal": [int(i) for i in np.argsort(-ref[0], kind="stable")[:3]]
                        == [int(i) for i in np.argsort(-got[0], kind="stable")[:3]],
                        "top1_equal": int(np.argmax(ref[0])) == int(np.argmax(got[0])),
                        "top3": [labels[i] for i in np.argsort(-got[0], kind="stable")[:3]],
                    }
                )

            if got is not None and sess == "ort_default" and name.startswith("window"):
                # Reference for a Dart port running the ONNX (scores are multiples of 1/256).
                item["scores"] = [float(v) for v in got[0]]

            entry[sess] = item

        if ref is not None:
            entry["tflite_shape"] = list(ref.shape)
            entry["tflite_top3"] = [labels[i] for i in np.argsort(-ref[0], kind="stable")[:3]]

        results.append(entry)

    crop_stats = {}
    candidates = {name: onnx_fn(name) for name in sessions}
    # For scale: TFLite's own builtin int8 kernels (no XNNPACK) vs the XNNPACK reference.
    candidates["tflite_builtin_without_xnnpack"] = lambda x: run_tflite(
        x, experimental_op_resolver_type=OpResolverType.BUILTIN_WITHOUT_DEFAULT_DELEGATES
    )
    refs = [run_tflite(c) for c in crops]

    for sess, fn in candidates.items():
        outs = [fn(c) for c in crops]
        diffs = [np.abs(o - r) for o, r in zip(outs, refs, strict=True)]
        top3 = [
            list(np.argsort(-o[0], kind="stable")[:3]) == list(np.argsort(-r[0], kind="stable")[:3])
            for o, r in zip(outs, refs, strict=True)
        ]
        crop_stats[sess] = {
            "max_abs_diff_in_lsb": float(max(d.max() for d in diffs) / lsb),
            "crops_top1_equal": int(sum(int(np.argmax(o)) == int(np.argmax(r)) for o, r in zip(outs, refs, strict=True))),
            "num_crops": len(crops),
            "max_abs_diff": float(max(d.max() for d in diffs)),
            "mean_abs_diff": float(np.mean([d.mean() for d in diffs])),
            "crops_bit_exact": int(sum(1 for d in diffs if d.max() == 0)),
            "crops_top3_equal": int(sum(top3)),
        }

    timing = {
        "tflite_xnnpack_resize_and_invoke_10s": time_call(run_tflite, wav[:160000]),
        "ort_default_10s": time_call(onnx_fn("ort_default"), wav[:160000]),
        "ort_no_optim_10s": time_call(onnx_fn("ort_no_optim"), wav[:160000]),
    }

    # tflite timing without the per-call interpreter construction
    interp = Interpreter(model_path=str(TFLITE_PATH))
    idx = interp.get_input_details()[0]["index"]
    interp.resize_tensor_input(idx, [160000], strict=False)
    interp.allocate_tensors()

    def tflite_invoke_only(x: np.ndarray) -> np.ndarray:
        interp.set_tensor(idx, x.astype(np.float32))
        interp.invoke()
        return interp.get_tensor(interp.get_output_details()[0]["index"])

    timing["tflite_xnnpack_invoke_only_10s"] = time_call(tflite_invoke_only, wav[:160000])

    out = {
        "onnx": {
            "path": str(ONNX_PATH.relative_to(LAB_DIR)),
            "sha256": hashlib.sha256(ONNX_PATH.read_bytes()).hexdigest(),
            "bytes": ONNX_PATH.stat().st_size,
        },
        "onnxruntime": ort.__version__,
        "machine": f"{platform.system()} {platform.machine()} (Python {platform.python_version()})",
        "output_quantization_step": lsb,
        "cases": results,
        "crops_15600_hop_4000": crop_stats,
        "timing": timing,
    }
    path = LAB_DIR / "fixtures" / "yamnet_onnx_parity.json"
    path.write_text(json.dumps(out, indent=1) + "\n")
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
