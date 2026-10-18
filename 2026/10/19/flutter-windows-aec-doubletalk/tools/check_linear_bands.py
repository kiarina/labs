#!/usr/bin/env python3
"""Device-free profile 0/12 diagnostics; no acceptance thresholds are fitted.

uv run --with numpy==2.5.4 --with scipy==1.18.1 python tools/check_linear_bands.py
Only derived metrics are saved. No devices, playback or new build are used.
"""
import ctypes as C
import hashlib
import json
from pathlib import Path

import numpy as np
import scipy
from scipy.signal import chirp, correlate, correlation_lags

ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / "build/aec/libaec_engine.dylib"
LIBRARY_SHA = hashlib.sha256(LIBRARY.read_bytes()).hexdigest()
lib = C.CDLL(str(LIBRARY))
PTR = C.POINTER(C.c_int16)
lib.aec_create_config.argtypes = [C.c_int, C.c_int]
lib.aec_create_config.restype = C.c_void_p
lib.aec_reverse.argtypes = [C.c_void_p, PTR, C.c_int]
lib.aec_reverse.restype = C.c_int
lib.aec_capture.argtypes = [C.c_void_p, PTR, PTR, C.c_int, C.c_int]
lib.aec_capture.restype = C.c_int
lib.aec_destroy.argtypes = [C.c_void_p]
RATE = 48000
BANDS = [(300, 3500), (6500, 7500), (7500, 8500), (8500, 10000),
         (14500, 15500), (15500, 16500), (16500, 18000), (18000, 22000)]


def db(value):
    return float(20 * np.log10(max(abs(float(value)), 1e-12)))


def rms(x):
    return float(np.sqrt(np.mean(np.asarray(x, dtype=float) ** 2))) if len(x) else 0.0


def pcm(x):
    return np.clip(np.rint(x), -32768, 32767).astype(np.int16)


def run(profile, render, capture):
    assert len(render) == len(capture) and len(render) % 480 == 0
    handle = lib.aec_create_config(1, profile)
    if not handle:
        raise RuntimeError(f"Profile {profile} is unavailable")
    out = np.zeros(len(capture), np.int16)
    try:
        for i in range(0, len(out), 480):
            ref, mic, dst = render[i:i + 480], capture[i:i + 480], out[i:i + 480]
            assert lib.aec_reverse(handle, ref.ctypes.data_as(PTR), 480) == 0
            assert lib.aec_capture(handle, mic.ctypes.data_as(PTR),
                                   dst.ctypes.data_as(PTR), 480, 80) == 0
    finally:
        lib.aec_destroy(handle)
    return out


def lag_for(y, x, limit=960):
    c = correlate(y.astype(float), x.astype(float), method="fft")
    lags = correlation_lags(len(y), len(x))
    keep = (lags >= 0) & (lags <= limit)
    return int(lags[keep][np.argmax(c[keep])])


def matched(y, x):
    y, x = np.asarray(y, float), np.asarray(x, float)
    gain = float(np.dot(y, x) / max(np.dot(x, x), 1e-20))
    corr = float(np.dot(y, x) / max(np.linalg.norm(y) * np.linalg.norm(x), 1e-20))
    return {"signedGain": gain, "gainDb": db(gain), "correlation": corr,
            "residualRmsDbfs": db(rms(y - gain * x) / 32768),
            "outputRmsDbfs": db(rms(y) / 32768)}


impulses = []
for position in [0, 4800, 4801, 4802]:
    x = np.zeros(RATE * 2, np.int16)
    x[position] = 12000
    zero = np.zeros_like(x)
    variants = {}
    for name, profile in [("baseline", 0), ("linear80", 12)]:
        y = run(profile, zero, x)
        h = np.fft.rfft(y.astype(float)) / np.fft.rfft(x.astype(float))
        f = np.fft.rfftfreq(len(x), 1 / RATE)
        phase = np.unwrap(np.angle(h))
        delay = -np.gradient(phase, f) * RATE / (2 * np.pi)
        bands = []
        for lo, hi in BANDS:
            take = (f >= lo) & (f < hi)
            gains = 20 * np.log10(np.maximum(abs(h[take]), 1e-12))
            bands.append({"hz": [lo, hi], "gainMedianDb": float(np.median(gains)),
                          "gainP01Db": float(np.quantile(gains, .01)),
                          "gainP99Db": float(np.quantile(gains, .99)),
                          "groupDelayMedianSamples": float(np.median(delay[take])),
                          "groupDelayP10Samples": float(np.quantile(delay[take], .1)),
                          "groupDelayP90Samples": float(np.quantile(delay[take], .9))})
        variants[name] = {"peakDelaySamples": int(np.argmax(abs(y.astype(float))) - position),
                          "outputPeak": int(np.max(abs(y.astype(np.int32)))), "bands": bands}
    impulses.append({"inputSample": position, "inputPeak": 12000, "variants": variants})

sweeps = []
for low, high in [(7000, 9000), (15000, 17000)]:
    duration = 4
    t = np.arange(duration * RATE) / RATE
    envelope = np.minimum(1, np.minimum(t / .05, (duration - t) / .05))
    x = pcm(6000 * envelope * chirp(t, low, duration, high, method="linear"))
    out = {name: run(profile, np.zeros_like(x), x)
           for name, profile in [("baseline", 0), ("linear80", 12)]}
    rows = []
    # Compare profile outputs at the same frame positions; do not fit per-band
    # delays to hide a boundary mismatch. RMS gain does not depend on carrier phase.
    for start in np.arange(.1, 3.9, .1):
        s, e = round(start * RATE), round((start + .1) * RATE)
        row = {"startSeconds": float(start),
               "centerHz": float(low + (high - low) * (start + .05) / duration)}
        for name, y in out.items():
            row[name + "RmsGainDb"] = db(rms(y[s + 432:e + 432]) / rms(x[s:e]))
        row["linearVsBaseline"] = matched(out["linear80"][s:e], out["baseline"][s:e])
        rows.append(row)
    sweeps.append({"hz": [low, high], "seconds": duration, "peak": 6000,
                   "comparisonShiftSamples": 0, "inputRmsWindowShiftSamples": 432,
                   "windows100ms": rows})

# Fullband independent seeded near/far; a deterministic abrupt path change is a
# stress diagnostic, not a model of every room. Delay hint stays fixed at 80 ms.
rng = np.random.default_rng(20261019)
seconds, change = 24, 12 * RATE
length = seconds * RATE
far = pcm(np.clip(rng.standard_normal(length), -3, 3) * 1800)
near = pcm(np.clip(rng.standard_normal(length), -3, 3) * 1000)
echo = np.zeros(length)
old_delay, new_delay, reflection = 3840, 5760, 960
echo[old_delay:change] = .4 * far[:change - old_delay]
echo[change:] = -.35 * far[change - new_delay:length - new_delay]
echo[change:] += .15 * far[change - new_delay - reflection:length - new_delay - reflection]
mixed_float = near.astype(float) + echo
assert np.max(abs(mixed_float)) < 32767
mixed = pcm(mixed_float)
path_outputs = {name: run(profile, far, mixed)
                for name, profile in [("baseline", 0), ("linear80", 12)]}
# Calibrate near latency independently with render=0; freeze for the stress run.
cal_near = near[:RATE * 2]
latencies = {name: lag_for(run(profile, np.zeros_like(cal_near), cal_near), cal_near)
             for name, profile in [("baseline", 0), ("linear80", 12)]}
# A no-render run of the same fullband near provides each profile's own filterbank
# reference. This separates extra DT attenuation from existing crossover loss.
dry_near = {name: run(profile, np.zeros_like(near), near)
            for name, profile in [("baseline", 0), ("linear80", 12)]}
path_windows = []
for s in range(0, length - 4800 - max(latencies.values()) + 1, 4800):
    e = s + 4800
    row = {"startSeconds": s / RATE, "relativeToPathChangeSeconds": (s - change) / RATE,
           "variants": {}}
    for name, y in path_outputs.items():
        lag = latencies[name]
        row["variants"][name] = matched(y[s + lag:e + lag], near[s:e])
        row["variants"][name]["outputClipSamples"] = int(np.sum(abs(y[s + lag:e + lag].astype(np.int32)) >= 32700))
    path_windows.append(row)

summaries = {}
for name in path_outputs:
    groups = {}
    for label, begin, end in [("coldStart0to1s", 0, 1), ("settled8to11s", 8, 11),
                              ("pathChange12to13s", 12, 13), ("recovery13to15s", 13, 15),
                              ("settled20to23s", 20, 23)]:
        values = [w["variants"][name] for w in path_windows if begin <= w["startSeconds"] < end]
        gains = [v["gainDb"] for v in values]
        groups[label] = {"nearGainMinDb": min(gains), "nearGainP01Db": float(np.quantile(gains, .01)),
                         "nearGainMedianDb": float(np.median(gains)),
                         "nearCorrelationMin": min(v["correlation"] for v in values),
                         "residualRmsMedianDbfs": float(np.median([v["residualRmsDbfs"] for v in values])),
                         "outputClipSamples": sum(v["outputClipSamples"] for v in values)}
        s, e = round(begin * RATE), round(end * RATE)
        lag = latencies[name]
        ref = np.fft.rfft(dry_near[name][s + lag:e + lag].astype(float))
        actual = np.fft.rfft(path_outputs[name][s + lag:e + lag].astype(float))
        freq = np.fft.rfftfreq(e - s, 1 / RATE)
        band_rows = []
        for lo, hi in BANDS:
            take = (freq >= lo) & (freq < hi)
            xx = float(np.sum(abs(ref[take]) ** 2))
            yy = float(np.sum(abs(actual[take]) ** 2))
            xy = float(np.sum(np.real(actual[take] * np.conj(ref[take]))))
            band_rows.append({"hz": [lo, hi], "signedGainVsDryNear": xy / max(xx, 1e-20),
                              "gainVsDryNearDb": db(xy / max(xx, 1e-20)),
                              "correlationVsDryNear": xy / max(np.sqrt(xx * yy), 1e-20)})
        groups[label]["bandNearTransferVsNoRender"] = band_rows
    summaries[name] = groups

result = {"kind": "device-free-linear80-band-and-transition-diagnostic", "sampleRate": RATE,
          "versions": {"numpy": np.__version__, "scipy": scipy.__version__},
          "acceptance": "No pass/fail thresholds or improvement claim; diagnostic measurements only.",
          "profiles": {"baseline": 0, "linear80": 12}, "librarySha256": LIBRARY_SHA,
          "libraryChangedDuringRun": LIBRARY_SHA != hashlib.sha256(LIBRARY.read_bytes()).hexdigest(),
          "impulseDiagnostics": impulses, "sweepDiagnostics": sweeps,
          "pathChange": {"seed": 20261019, "seconds": seconds, "changeSeconds": 12,
                         "oldEcho": {"delayMs": 80, "gain": .4},
                         "newEcho": {"delayMs": 120, "gain": -.35, "reflectionAfterMs": 20, "reflectionGain": .15},
                         "near": "independent seeded fullband noise, std1000 clipped at +/-3000",
                         "far": "independent seeded fullband noise, std1800 clipped at +/-5400",
                         "delayHintMs": 80, "latencyByProfileSamples": latencies,
                         "summary": summaries, "windows100ms": path_windows},
          "limitations": ["No physical device, human speech or subjective listening is tested.",
                          "Near matched gain/correlation is contaminated by residual echo; it is not exact source separation.",
                          "Path-change band transfer uses the same profile's no-render near output as reference to factor out its filterbank response.",
                          "Band impulse response describes this fixed cold/no-render state, not nonlinear DT behavior.",
                          "Sweep carrier phase makes sample correlation sensitive; output-to-output comparison and RMS are reported separately.",
                          "The abrupt path-change stress uses one synthetic path and a fixed delay hint, not all real room changes."]}
target = ROOT / "results/linear-band-check.json"
target.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
print(json.dumps({"pathChangeSummary": summaries, "latencies": latencies,
                  "libraryChangedDuringRun": result["libraryChangedDuringRun"]}, indent=2))
