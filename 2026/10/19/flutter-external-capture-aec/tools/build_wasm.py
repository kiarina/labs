#!/usr/bin/env python3
"""Build the exact same AEC C ABI and pinned source core for browser use."""
import os
from pathlib import Path
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor
import hashlib

root = Path(__file__).resolve().parents[1]
source = root / "vendor/webrtc-aec3/src"
engine = root / "native/aec_engine.cc"
if not engine.exists():
    raise SystemExit("native/aec_engine.cc is missing")
includes = ["", "api", "base/rtc_base", "base", "base/system_wrappers/include",
            "audio_processing", "absl", "base/jsoncpp/include",
            "audio_processing/aec3", "audio_processing/resampler",
            "audio_processing/logging", "audio_processing/include",
            "audio_processing/utility", "rtc_base/experiments", "common_audio",
            "common_audio/third_party/ooura/fft_size_128"]
sources = sorted(p for p in source.rglob("*")
                 if p.suffix in (".cc", ".c", ".cpp")
                 and not any(p.name.endswith(x) for x in
                             ("_avx2.cc", "_sse2.cc", "_sse.cc", "_neon.cc")))
compiler = os.environ.get("EMXX", "em++")
if shutil.which(compiler) is None:
    raise SystemExit("Install Emscripten (em++) before building the browser core")
compile_flags = ["-O2", "-DWEBRTC_POSIX", "-Wno-deprecated", "-fexceptions",
           *["-I" + str(source / p) for p in includes],
           "-I" + str(root / "native")]
cache = root / "build/wasm-objects"
cache.mkdir(parents=True, exist_ok=True)
header_hash = hashlib.sha256()
for header in sorted([*source.rglob("*.h"), *engine.parent.glob("*.h")]):
    header_hash.update(header.read_bytes())
toolchain = subprocess.check_output([compiler, "--version"])
def compile_object(path):
    digest = hashlib.sha256(path.read_bytes() + header_hash.digest() + toolchain
                            + repr(compile_flags).encode()).hexdigest()[:16]
    target = cache / (path.stem + "-" + digest + ".o")
    if not target.exists():
        # C must remain C: compiling splitting_filter_c.c as C++ mangles QMF symbols.
        cc = os.environ.get("EMCC", "emcc") if path.suffix == ".c" else compiler
        flags = compile_flags if path.suffix == ".c" else ["-std=c++20", *compile_flags]
        subprocess.run([cc, *flags, "-c", str(path), "-o", str(target)], check=True)
    return target
with ThreadPoolExecutor(max_workers=4) as pool:
    objects = list(pool.map(compile_object, [engine, *sources]))
command = [compiler, "-O2", "-fexceptions", "--no-entry", *map(str, objects),
           "-sMODULARIZE=1", "-sEXPORT_ES6=1", "-sEXPORT_NAME=createAecModule",
           "-sENVIRONMENT=web,node", "-sALLOW_MEMORY_GROWTH=1",
           "-sEXPORTED_FUNCTIONS=['_aec_create','_aec_reverse','_aec_capture','_aec_reset','_aec_destroy','_malloc','_free']",
           "-sEXPORTED_RUNTIME_METHODS=['HEAP16','HEAPU8']",
           "-o", str(root / "app/web/aec_engine.js")]
subprocess.run(command, cwd=root, check=True)
