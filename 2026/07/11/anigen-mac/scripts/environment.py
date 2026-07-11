import json
import os
import platform
import subprocess
import sys

import PIL
import numpy
import torch


def command(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


data = {
    "anigen_commit": os.environ.get("ANIGEN_COMMIT"),
    "machine": platform.machine(),
    "macos": platform.mac_ver()[0],
    "python": sys.version.split()[0],
    "torch": torch.__version__,
    "numpy": numpy.__version__,
    "pillow": PIL.__version__,
    "mps_available": torch.backends.mps.is_available(),
    "xcode": command("xcodebuild", "-version").splitlines(),
    "metal": command("xcrun", "-sdk", "macosx", "metal", "--version").splitlines()[0],
}
print(json.dumps(data, indent=2))
