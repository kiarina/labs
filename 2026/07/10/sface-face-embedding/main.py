from __future__ import annotations

import hashlib
import json
import statistics
import time
from dataclasses import dataclass
from pathlib import Path

import cv2
import httpx
import numpy as np
from sklearn.datasets import fetch_lfw_people
from scipy.io import loadmat


MODEL_URL = (
    "https://media.githubusercontent.com/media/opencv/opencv_zoo/"
    "47534e27c9851bb1128ccc0102f1145e27f23f98/"
    "models/face_recognition_sface/face_recognition_sface_2021dec.onnx"
)
MODEL_SHA256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
MODEL_PATH = Path("models/face_recognition_sface_2021dec.onnx")

DATASET_URL = "https://ndownloader.figshare.com/files/5976027"
DATASET_SHA256 = "b612fb967f2dc77c9c62d3e1266e0c73d5fca46a4b8906c18e454d41af987794"
DATASET_PATH = Path("data/olivetti_faces.mat")
LFW_DATA_HOME = Path("data/lfw")

INPUT_SIZE = 112
EMBEDDING_DIMENSION = 128
PEOPLE = 40
IMAGES_PER_PERSON = 10
REFERENCE_IMAGES_PER_PERSON = 5


@dataclass(frozen=True)
class FaceSample:
    image: np.ndarray
    person_id: int
    image_index: int
    image_number: int
    person_name: str


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, destination: Path, expected_sha256: str) -> None:
    if destination.exists() and sha256_file(destination) == expected_sha256:
        return

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".part")
    print(f"download: {url}", flush=True)
    with httpx.stream("GET", url, follow_redirects=True, timeout=60.0) as response:
        response.raise_for_status()
        with temporary.open("wb") as file:
            for chunk in response.iter_bytes(chunk_size=1024 * 1024):
                file.write(chunk)
    actual_sha256 = sha256_file(temporary)
    if actual_sha256 != expected_sha256:
        temporary.unlink(missing_ok=True)
        raise ValueError(
            f"SHA-256 mismatch for {destination}: "
            f"expected {expected_sha256}, got {actual_sha256}"
        )
    temporary.replace(destination)


def load_olivetti_faces(path: Path) -> list[FaceSample]:
    mat = loadmat(path)
    if "faces" not in mat:
        raise ValueError(f"dataset does not contain 'faces': {sorted(mat)}")

    faces = np.asarray(mat["faces"], dtype=np.float32)
    if faces.shape == (4096, 400):
        faces = faces.T
    if faces.shape != (400, 4096):
        raise ValueError(f"unexpected faces shape: {faces.shape}")

    images = faces.reshape(400, 64, 64)
    targets = np.repeat(np.arange(40), 10)
    return [
        FaceSample(
            image=images[index],
            person_id=int(targets[index]),
            image_index=index,
            image_number=index % IMAGES_PER_PERSON,
            person_name=f"person_{int(targets[index]):02d}",
        )
        for index in range(len(images))
    ]


def load_lfw_faces(data_home: Path) -> list[FaceSample]:
    data_home.mkdir(parents=True, exist_ok=True)
    dataset = fetch_lfw_people(
        data_home=data_home,
        color=True,
        resize=1.0,
        min_faces_per_person=20,
        download_if_missing=True,
    )
    images = np.asarray(dataset.images)
    targets = np.asarray(dataset.target)
    target_names = list(dataset.target_names)

    selected_targets = sorted(np.unique(targets))[:PEOPLE]
    samples = []
    image_index = 0
    for person_id, target in enumerate(selected_targets):
        indices = np.flatnonzero(targets == target)[:IMAGES_PER_PERSON]
        if len(indices) != IMAGES_PER_PERSON:
            raise ValueError(f"target {target} has only {len(indices)} images")
        for image_number, source_index in enumerate(indices):
            samples.append(
                FaceSample(
                    image=images[source_index],
                    person_id=person_id,
                    image_index=image_index,
                    image_number=image_number,
                    person_name=target_names[int(target)],
                )
            )
            image_index += 1
    return samples


class SFaceEmbedder:
    def __init__(self, model_path: Path) -> None:
        actual_sha256 = sha256_file(model_path)
        if actual_sha256 != MODEL_SHA256:
            raise ValueError(
                f"model SHA-256 mismatch: expected {MODEL_SHA256}, got {actual_sha256}"
            )
        self.recognizer = cv2.FaceRecognizerSF.create(str(model_path), "")

    def embed(self, image: np.ndarray) -> np.ndarray:
        face = prepare_face_crop(image)
        feature = np.asarray(self.recognizer.feature(face), dtype=np.float32).reshape(-1)
        if feature.shape != (EMBEDDING_DIMENSION,):
            raise ValueError(f"unexpected embedding shape: {feature.shape}")
        norm = float(np.linalg.norm(feature))
        if not np.isfinite(norm) or norm == 0.0:
            raise ValueError(f"invalid embedding norm: {norm}")
        return feature / norm


def prepare_face_crop(image: np.ndarray) -> np.ndarray:
    if float(np.nanmax(image)) <= 1.0:
        uint8_image = np.round(np.clip(image, 0.0, 1.0) * 255.0).astype(np.uint8)
    else:
        uint8_image = np.clip(image, 0.0, 255.0).astype(np.uint8)
    resized = cv2.resize(
        uint8_image, (INPUT_SIZE, INPUT_SIZE), interpolation=cv2.INTER_LINEAR
    )
    if resized.ndim == 2:
        return cv2.cvtColor(resized, cv2.COLOR_GRAY2BGR)
    return cv2.cvtColor(resized, cv2.COLOR_RGB2BGR)


def evaluate(
    *,
    dataset_name: str,
    dataset_config: dict,
    samples: list[FaceSample],
    embeddings: np.ndarray,
    elapsed: float,
) -> dict:
    references = [
        (sample, embedding)
        for sample, embedding in zip(samples, embeddings)
        if sample.image_number < REFERENCE_IMAGES_PER_PERSON
    ]
    queries = [
        (sample, embedding)
        for sample, embedding in zip(samples, embeddings)
        if sample.image_number >= REFERENCE_IMAGES_PER_PERSON
    ]
    reference_matrix = np.stack([embedding for _, embedding in references])

    results = []
    for sample, embedding in queries:
        similarities = reference_matrix @ embedding
        order = np.argsort(similarities)[::-1]
        nearest_sample = references[int(order[0])][0]
        top5_samples = [references[int(index)][0] for index in order[:5]]
        results.append(
            {
                "query_index": sample.image_index,
                "person_id": sample.person_id,
                "person_name": sample.person_name,
                "nearest_index": nearest_sample.image_index,
                "nearest_person_id": nearest_sample.person_id,
                "nearest_person_name": nearest_sample.person_name,
                "similarity": float(similarities[order[0]]),
                "top1_correct": nearest_sample.person_id == sample.person_id,
                "top5_correct": any(item.person_id == sample.person_id for item in top5_samples),
            }
        )

    positive_similarities = []
    negative_similarities = []
    by_person = {
        person_id: [
            embeddings[index]
            for index, sample in enumerate(samples)
            if sample.person_id == person_id
        ]
        for person_id in sorted({sample.person_id for sample in samples})
    }
    for person_embeddings in by_person.values():
        positive_similarities.extend(pairwise_upper(np.stack(person_embeddings)))
    people = sorted(by_person)
    for left_index, left in enumerate(people):
        for right in people[left_index + 1 :]:
            negative_similarities.append(float(by_person[left][0] @ by_person[right][0]))

    count = len(results)
    return {
        "configuration": {
            "dataset": dataset_name,
            **dataset_config,
            "reference_images_per_person": REFERENCE_IMAGES_PER_PERSON,
            "query_images_per_person": IMAGES_PER_PERSON
            - REFERENCE_IMAGES_PER_PERSON,
            "people": PEOPLE,
            "images": len(samples),
            "model_url": MODEL_URL,
            "model_sha256": MODEL_SHA256,
            "input_size": INPUT_SIZE,
            "embedding_dimension": EMBEDDING_DIMENSION,
            "normalization": "l2",
        },
        "metrics": {
            "top1_accuracy": sum(item["top1_correct"] for item in results) / count,
            "top5_accuracy": sum(item["top5_correct"] for item in results) / count,
            "mean_positive_similarity": statistics.mean(positive_similarities),
            "mean_negative_similarity": statistics.mean(negative_similarities),
            "embedding_elapsed_seconds": elapsed,
            "seconds_per_image": elapsed / len(samples),
        },
        "results": results,
    }


def pairwise_upper(vectors: np.ndarray) -> list[float]:
    values = []
    for left in range(len(vectors)):
        for right in range(left + 1, len(vectors)):
            values.append(float(vectors[left] @ vectors[right]))
    return values


def main() -> None:
    download(MODEL_URL, MODEL_PATH, MODEL_SHA256)
    download(DATASET_URL, DATASET_PATH, DATASET_SHA256)

    embedder = SFaceEmbedder(MODEL_PATH)
    experiments = [
        (
            "Olivetti Faces",
            load_olivetti_faces(DATASET_PATH),
            {
                "dataset_url": DATASET_URL,
                "dataset_sha256": DATASET_SHA256,
                "resolution": "64x64 grayscale",
            },
            Path("output/olivetti_report.json"),
        ),
        (
            "LFW people, funneled color crop",
            load_lfw_faces(LFW_DATA_HOME),
            {
                "dataset_loader": "sklearn.datasets.fetch_lfw_people",
                "data_home": str(LFW_DATA_HOME),
                "min_faces_per_person": 20,
                "resolution": "125x94 RGB before resize",
            },
            Path("output/lfw_report.json"),
        ),
    ]

    reports = []
    for dataset_name, samples, dataset_config, output_path in experiments:
        print(f"\n--- {dataset_name} ---")
        embeddings = []
        started = time.perf_counter()
        for index, sample in enumerate(samples, 1):
            if index == 1 or index % 50 == 0:
                print(f"embed {index:3d}/{len(samples)}", flush=True)
            embeddings.append(embedder.embed(sample.image))
        elapsed = time.perf_counter() - started

        report = evaluate(
            dataset_name=dataset_name,
            dataset_config=dataset_config,
            samples=samples,
            embeddings=np.stack(embeddings),
            elapsed=elapsed,
        )
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        reports.append(report)

        metrics = report["metrics"]
        print(f"top-1 accuracy: {metrics['top1_accuracy']:.3f}")
        print(f"top-5 accuracy: {metrics['top5_accuracy']:.3f}")
        print(
            "mean positive cosine similarity: "
            f"{metrics['mean_positive_similarity']:.3f}"
        )
        print(
            "mean negative cosine similarity: "
            f"{metrics['mean_negative_similarity']:.3f}"
        )
        print(f"{len(samples)} images elapsed: {metrics['embedding_elapsed_seconds']:.3f} s")
        print(f"seconds per image: {metrics['seconds_per_image']:.4f} s")
        print(f"report: {output_path}")

    summary_path = Path("output/summary.json")
    summary_path.write_text(
        json.dumps(
            [
                {
                    "dataset": report["configuration"]["dataset"],
                    **report["metrics"],
                }
                for report in reports
            ],
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"\nsummary: {summary_path}")


if __name__ == "__main__":
    main()
