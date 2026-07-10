import cv2
import httpx
from pathlib import Path
import hashlib
import sys
import time
import statistics

MODEL_URL = "https://media.githubusercontent.com/media/opencv/opencv_zoo/47534e27c9851bb1128ccc0102f1145e27f23f98/models/face_detection_yunet/face_detection_yunet_2023mar_int8bq.onnx"
MODEL_FILENAME = "face_detection_yunet_2023mar_int8bq.onnx"
MODEL_SHA256 = "49f000ec501fef24739071fc7e68267d32209045b6822c0c72dce1da25726f10"
IMAGE_PATH = "../../../../assets/jpg/many_face_1280x720_275kb.jpg"

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

def run_benchmark(detector, image, num_iterations=100):
    print(f"\n--- Inference Speed Benchmark (Iterations: {num_iterations}) ---")
    height, width = image.shape[:2]
    detector.setInputSize((width, height))

    # Warmup
    for _ in range(5):
        detector.detect(image)

    times = []
    for _ in range(num_iterations):
        start_time = time.perf_counter()
        detector.detect(image)
        end_time = time.perf_counter()
        times.append((end_time - start_time) * 1000) # ms

    avg_time = statistics.mean(times)
    min_time = min(times)
    max_time = max(times)
    stdev_time = statistics.stdev(times) if len(times) > 1 else 0

    print(f"Average time: {avg_time:.2f} ms")
    print(f"Min time:     {min_time:.2f} ms")
    print(f"Max time:     {max_time:.2f} ms")
    print(f"Std dev:      {stdev_time:.2f} ms")


def run_scale_experiment(detector, original_image):
    print("\n--- Scale Variance Experiment ---")
    scales = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0]

    print(f"{'Scale':>6} | {'Resolution':>13} | {'Faces':>6} | {'Max Score':>9} | {'Min Score':>9}")
    print("-" * 55)

    for scale in scales:
        width = int(original_image.shape[1] * scale)
        height = int(original_image.shape[0] * scale)
        dim = (width, height)

        resized_img = cv2.resize(original_image, dim, interpolation=cv2.INTER_LINEAR)
        detector.setInputSize((width, height))

        status, faces = detector.detect(resized_img)

        num_faces = len(faces) if faces is not None else 0
        max_score = 0.0
        min_score = 0.0

        if num_faces > 0:
            scores = [float(face[14]) for face in faces]
            max_score = max(scores)
            min_score = min(scores)

        resolution_str = f"{width}x{height}"
        print(f"{scale:6.2f} | {resolution_str:>13} | {num_faces:6d} | {max_score:9.3f} | {min_score:9.3f}")

def main():
    model_path = Path(__file__).parent / MODEL_FILENAME
    download_model(MODEL_URL, model_path, MODEL_SHA256)

    image_path = Path(__file__).parent / IMAGE_PATH
    if not image_path.exists():
        print(f"Error: Image not found at {image_path}", file=sys.stderr)
        sys.exit(1)

    image = cv2.imread(str(image_path))
    if image is None:
        print("Error: Failed to load image.", file=sys.stderr)
        sys.exit(1)

    # Initialize YuNet
    detector = cv2.FaceDetectorYN.create(
        model=str(model_path),
        config="",
        input_size=(image.shape[1], image.shape[0]),
        score_threshold=0.6, # Lowered to see more faces in scale exp
        nms_threshold=0.3,
        top_k=5000
    )

    run_benchmark(detector, image)
    run_scale_experiment(detector, image)
    visualize_faces(detector, image)

def visualize_faces(detector, image):
    print("\n--- Visualizing Detections (Scale 1.0) ---")
    height, width = image.shape[:2]
    detector.setInputSize((width, height))
    status, faces = detector.detect(image)

    output_image = image.copy()
    if faces is not None:
        for face in faces:
            x, y, w, h = (int(v) for v in face[:4])
            score = float(face[14])

            # Draw bounding box
            cv2.rectangle(output_image, (x, y), (x + w, y + h), (0, 255, 0), 2)

            # Draw landmarks (5 points)
            for i in range(5):
                lx, ly = int(face[4 + i*2]), int(face[5 + i*2])
                cv2.circle(output_image, (lx, ly), 2, (0, 0, 255), 2)

            # Draw score
            text = f"{score:.2f}"
            cv2.putText(output_image, text, (x, y - 5), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 255, 0), 1)

    output_path = Path(__file__).parent / "output_1.00.jpg"
    cv2.imwrite(str(output_path), output_image)
    print(f"Saved visualization to {output_path}")

if __name__ == "__main__":
    main()
