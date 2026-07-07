import cv2
import httpx
from pathlib import Path
import hashlib
import sys

MODEL_URL = "https://media.githubusercontent.com/media/opencv/opencv_zoo/47534e27c9851bb1128ccc0102f1145e27f23f98/models/face_detection_yunet/face_detection_yunet_2023mar_int8bq.onnx"
MODEL_FILENAME = "face_detection_yunet_2023mar_int8bq.onnx"
MODEL_SHA256 = "49f000ec501fef24739071fc7e68267d32209045b6822c0c72dce1da25726f10"
IMAGE_PATH = "../../../../tests/assets/jpg/many_face_1280x720_275kb.jpg"

def verify_file(filepath: Path, expected_sha256: str) -> bool:
    if not filepath.exists():
        return False
    sha256_hash = hashlib.sha256()
    with open(filepath, "rb") as f:
        for byte_block in iter(lambda: f.read(4096), b""):
            sha256_hash.update(byte_block)
    return sha256_hash.hexdigest() == expected_sha256

def download_model(url: str, filepath: Path, expected_sha256: str) -> None:
    if verify_file(filepath, expected_sha256):
        print(f"Model already exists and verified: {filepath}")
        return

    print(f"Downloading model from {url} ...")
    with httpx.stream("GET", url, follow_redirects=True) as r:
        r.raise_for_status()
        with open(filepath, "wb") as f:
            for chunk in r.iter_bytes(chunk_size=8192):
                f.write(chunk)
    
    if not verify_file(filepath, expected_sha256):
        raise RuntimeError("Downloaded file failed SHA256 checksum verification.")
    print("Download and verification complete.")

def main():
    model_path = Path(__file__).parent / MODEL_FILENAME
    download_model(MODEL_URL, model_path, MODEL_SHA256)
    
    image_path = Path(__file__).parent / IMAGE_PATH
    if not image_path.exists():
        print(f"Error: Image not found at {image_path}", file=sys.stderr)
        sys.exit(1)

    print(f"Loading image from {image_path} ...")
    image = cv2.imread(str(image_path))
    if image is None:
        print("Error: Failed to load image.", file=sys.stderr)
        sys.exit(1)
        
    height, width = image.shape[:2]

    # Initialize YuNet
    detector = cv2.FaceDetectorYN.create(
        model=str(model_path),
        config="",
        input_size=(width, height),
        score_threshold=0.9,
        nms_threshold=0.3,
        top_k=5000
    )

    # YuNet requires input size to match the image exactly if we set it this way
    # We already set it at create, but we can set it again
    detector.setInputSize((width, height))

    # Detect faces
    status, faces = detector.detect(image)
    
    if faces is None:
        print("No faces detected.")
    else:
        print(f"Detected {len(faces)} faces.")
        for i, face in enumerate(faces):
            x, y, w, h = (int(v) for v in face[:4])
            score = float(face[14])
            print(f"Face {i+1}: bbox=({x}, {y}, {w}, {h}), score={score:.3f}")
            
if __name__ == "__main__":
    main()
