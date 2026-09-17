"""Minimal TypeSafe HTTP client shared by the scripts in this lab."""

import os
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Any

import httpx

BASE_URL = "https://api.typesafe.ai"
MODEL = os.environ.get("TYPESAFE_MODEL", "jev-latest")


def api_key() -> str:
    for name in ("TYPESAFE_AI_API_KEY", "TYPESAFE_API_KEY"):
        if os.environ.get(name):
            return os.environ[name]
    raise SystemExit("Set TYPESAFE_AI_API_KEY (or TYPESAFE_API_KEY) before running.")


@dataclass
class Result:
    status: int
    ms: float
    body: Any

    @property
    def ok(self) -> bool:
        return self.status == 200

    @property
    def input_tokens(self) -> int:
        return self.body["usage"]["input_tokens"]

    def answer(self, key: str) -> dict:
        return self.body["answers"][key]


class Client:
    def __init__(self) -> None:
        self.http = httpx.Client(
            base_url=BASE_URL,
            headers={"Authorization": f"Bearer {api_key()}"},
            timeout=300,
        )

    def models(self) -> Any:
        return self.http.get("/v1/models").json()

    def raw(self, body: dict) -> Result:
        """POST once; retry only on 429/529 with backoff."""
        for attempt in range(6):
            start = time.perf_counter()
            r = self.http.post("/v1/systemone", json=body)
            ms = (time.perf_counter() - start) * 1000
            if r.status_code not in (429, 529):
                break
            time.sleep(float(r.headers.get("retry-after", 2**attempt)))
        try:
            payload = r.json()
        except ValueError:
            payload = r.text
        return Result(r.status_code, ms, payload)

    def ask(self, state: Any, questions: dict) -> Result:
        return self.raw({"state": state, "model": MODEL, "questions": questions})

    def ask_many(self, jobs: list[tuple[Any, dict]], workers: int = 8) -> list[Result]:
        with ThreadPoolExecutor(max_workers=workers) as pool:
            return list(pool.map(lambda job: self.ask(*job), jobs))
