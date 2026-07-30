from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path


ASSET_NAME = "ltx2_dialogue_512x512_24fps_7s_355kb.mp4"
EXPECTED_SHA256 = "20e1c86950574d95ad72ed2d324407aa7e48d6013a5d556cdd9517fb71e412ff"
EXPECTED_DURATION = 6.708


def main() -> None:
    repo_root = Path(__file__).resolve().parents[4]
    asset = repo_root / "tests" / "assets" / "mp4" / ASSET_NAME
    if not asset.is_file():
        raise SystemExit(f"missing asset: {asset}")

    digest = hashlib.sha256(asset.read_bytes()).hexdigest()
    if digest != EXPECTED_SHA256:
        raise SystemExit(f"unexpected sha256: {digest}")

    probe = json.loads(
        subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_format",
                "-show_streams",
                "-of",
                "json",
                str(asset),
            ],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    )

    duration = float(probe["format"]["duration"])
    if abs(duration - EXPECTED_DURATION) > 0.02:
        raise SystemExit(f"unexpected duration: {duration}")

    video = next(stream for stream in probe["streams"] if stream["codec_type"] == "video")
    audio = next(stream for stream in probe["streams"] if stream["codec_type"] == "audio")

    expected_video = {
        "codec_name": "h264",
        "width": 512,
        "height": 512,
        "r_frame_rate": "24/1",
    }
    for key, value in expected_video.items():
        if video.get(key) != value:
            raise SystemExit(f"unexpected video {key}: {video.get(key)!r}")

    expected_audio = {
        "codec_name": "aac",
        "sample_rate": "48000",
        "channels": 1,
    }
    for key, value in expected_audio.items():
        if audio.get(key) != value:
            raise SystemExit(f"unexpected audio {key}: {audio.get(key)!r}")

    print(
        json.dumps(
            {
                "asset": ASSET_NAME,
                "sha256": digest,
                "duration_s": duration,
                "video": expected_video,
                "audio": expected_audio,
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
