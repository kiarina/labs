#!/usr/bin/env python3
"""Run one echo session: a device under test (DUT) records while it plays the
far-end speech; a helper device plays the near-end speech on the same
schedule. Writes results/<label>.json.

The apps must already be built/installed (see README). Schedules are wall
clock (epoch ms) on each device, so the near-end correlation searches +-2.5 s.
"""

import argparse
import base64
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent
APP = LAB / "app"
PKG = "com.kiarina.labs.echo_app"
BUNDLE = "com.kiarina.labs.echoApp"
PERIOD_MS = 27000
NEAR_AT = (10500, 17500)
ADB = os.environ.get("ADB", "adb")
IOS_DEVICE = os.environ.get("IOS_DEVICE", "")


def sh(*args, check=True, **kw):
    return subprocess.run(args, check=check, text=True, capture_output=True, **kw)


def b64(obj):
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode()


def android_start(config):
    sh(ADB, "shell", "am", "force-stop", PKG)
    sh(ADB, "shell", "pm", "grant", PKG, "android.permission.RECORD_AUDIO", check=False)
    sh(ADB, "logcat", "-c")
    sh(ADB, "shell", "am", "start", "-n", f"{PKG}/.MainActivity", "--es", "config", b64(config))


def android_result(timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        log = sh(ADB, "logcat", "-d", "-s", "flutter").stdout
        parts = {}
        total = None
        for m in re.finditer(r"ECHO_PART (\d+)/(\d+) (.*)", log):
            parts[int(m.group(1))] = m.group(2 + 1)
            total = int(m.group(2))
        if total and len(parts) == total:
            return json.loads("".join(parts[i] for i in range(1, total + 1)))
        time.sleep(3)
    raise TimeoutError("android result")


def ios_start(config):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(config, f)
    base = ["xcrun", "devicectl", "device"]
    dev = ["--device", IOS_DEVICE]
    sh(*base, "copy", "to", *dev, "--source", f.name, "--destination", "tmp/echo_config.json",
       "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE)
    sh(*base, "copy", "to", *dev, "--source", f.name, "--destination", "tmp/echo_result.json",
       "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE)
    sh(*base, "process", "launch", *dev, "--terminate-existing", BUNDLE)


def ios_result(timeout):
    deadline = time.time() + timeout
    out = Path(tempfile.mkdtemp()) / "r.json"
    while time.time() < deadline:
        time.sleep(5)
        sh("xcrun", "devicectl", "device", "copy", "from", "--device", IOS_DEVICE,
           "--source", "tmp/echo_result.json", "--destination", str(out),
           "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE, check=False)
        try:
            data = json.loads(out.read_text())
            if "results" in data:
                return data
        except Exception:
            pass
    raise TimeoutError("ios result")


def macos_app():
    return APP / "build/macos/Build/Products/Release/echo_app.app"


def macos_start(config, log, patch=""):
    return subprocess.Popen(
        ["open", "-W", "-n", "--env", f"ECHO_CONFIG={json.dumps(config)}",
         "--env", f"ECHO_RECORD_MACOS_PATCH={patch}",
         "--stdout", str(log), "--stderr", str(log), str(macos_app())])


def macos_result(proc, log, timeout):
    proc.wait(timeout=timeout)
    parts = {}
    for m in re.finditer(r"ECHO_PART (\d+)/(\d+) (.*)", log.read_text()):
        parts[int(m.group(1))] = m.group(3)
    return json.loads("".join(parts[i] for i in sorted(parts)))


class WebServer(http.server.SimpleHTTPRequestHandler):
    result = None

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(APP / "build/web"), **kw)

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        WebServer.result = json.loads(body)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *a):
        pass


def web_start(config):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 8791), WebServer)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    profile = tempfile.mkdtemp(prefix="echo-chrome-")
    chrome = os.environ.get(
        "CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    # Real microphone and speaker: no fake devices; the permission prompt is
    # auto-accepted and autoplay is allowed so playback needs no gesture.
    return subprocess.Popen(
        [chrome, f"--user-data-dir={profile}", "--no-first-run",
         "--use-fake-ui-for-media-stream",
         "--autoplay-policy=no-user-gesture-required",
         "--new-window", f"http://127.0.0.1:8791/?config={b64(config)}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL), profile


def web_result(timeout):
    deadline = time.time() + timeout
    while time.time() < deadline and WebServer.result is None:
        time.sleep(1)
    if WebServer.result is None:
        raise TimeoutError("web result")
    return WebServer.result


def mac_helper(start, slots):
    wav = APP / "assets/near.wav"

    def run():
        for i in range(slots):
            for at in NEAR_AT:
                t = (start + i * PERIOD_MS + at) / 1000
                time.sleep(max(0, t - time.time()))
                subprocess.Popen(["afplay", str(wav)])

    th = threading.Thread(target=run, daemon=True)
    th.start()
    return th


def environment():
    env = {}
    try:
        env["macVolume"] = sh("osascript", "-e", "output volume of (get volume settings)").stdout.strip()
    except Exception:
        pass
    try:
        out = sh(ADB, "shell", "cmd", "media_session", "volume", "--stream", "3", "--get", check=False).stdout
        env["androidMusicVolume"] = out.strip().splitlines()[-1] if out.strip() else None
        t0 = time.time()
        dev = int(sh(ADB, "shell", "date", "+%s%3N").stdout.strip())
        env["androidClockMinusMacMs"] = dev - int((t0 + time.time()) / 2 * 1000)
    except Exception:
        pass
    return env


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dut", required=True, choices=["macos", "ios", "android", "web"])
    ap.add_argument("--helper", required=True, choices=["mac", "android", "none"])
    ap.add_argument("--variants", default="raw,ec,ec-ns-agc")
    ap.add_argument("--label", required=True)
    ap.add_argument("--mac-patch", default="", help="ECHO_RECORD_MACOS_PATCH for the macOS DUT")
    ap.add_argument("--lead", type=int, default=20, help="seconds before the first slot")
    args = ap.parse_args()

    variants = args.variants.split(",")
    start = int((time.time() + args.lead) * 1000)
    base = {"startEpochMs": start, "periodMs": PERIOD_MS, "exit": True}
    env = environment()

    if args.helper == "android":
        android_start({**base, "role": "helper", "slots": len(variants)})
    elif args.helper == "mac":
        mac_helper(start, len(variants))

    timeout = args.lead + len(variants) * PERIOD_MS / 1000 + 120
    dut = {**base, "role": "dut", "variants": variants, "label": args.label}
    LAB.joinpath("build").mkdir(exist_ok=True)
    if args.dut == "macos":
        log = LAB / f"build/{args.label}.log"
        log.unlink(missing_ok=True)
        result = macos_result(macos_start(dut, log, args.mac_patch), log, timeout)
        result["macPatch"] = args.mac_patch
        result["macPatchLog"] = [l for l in log.read_text().splitlines() if l.startswith(("ECHO_PATCH", "ECHO_TAP"))][:40]
    elif args.dut == "android":
        android_start(dut)
        result = android_result(timeout)
    elif args.dut == "ios":
        ios_start(dut)
        result = ios_result(timeout)
    else:
        proc, profile = web_start(dut)
        try:
            result = web_result(timeout)
        finally:
            proc.terminate()
            shutil.rmtree(profile, ignore_errors=True)

    result["helper"] = args.helper
    result["environment"] = env
    out = LAB / "results" / f"{args.label}.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(out)


if __name__ == "__main__":
    sys.exit(main())
