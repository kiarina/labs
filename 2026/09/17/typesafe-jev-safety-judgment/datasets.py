"""Download and prepare the moderation datasets into data/.

English: openai/moderation-api-release (MIT) - 1,680 short prompts, per-category
0/1 labels (some rows omit a category). We evaluate the binary "is this flagged in
any category" task, which every row supports.

Japanese: LLM-jp Toxicity Dataset v1 (CC BY 4.0) - 1,847 web documents with an
overall label plus per-category yes/no. We map the overall label to flagged =
(toxic or has_toxic_expression). Long documents are truncated to fit Jev's limit.

Both are downloaded at run time into data/ (gitignored); we do not redistribute them.
"""

import gzip
import json
from pathlib import Path

import httpx

DATA = Path("data")
EN_URL = "https://raw.githubusercontent.com/openai/moderation-api-release/main/data/samples-1680.jsonl.gz"
JA_URL = "https://gitlab.llm-jp.nii.ac.jp/datasets/llm-jp-toxicity-dataset/-/raw/main/toxicity_dataset.jsonl"
# OpenAI's per-row category flags. SH = self-harm, others per their taxonomy.
EN_CATS = ["S", "H", "V", "HR", "SH", "S3", "H2", "V2"]
MAX_CHARS = 28_000  # safely under Jev's ~33k-token single-state limit for Japanese


def _get(url: str) -> bytes:
    with httpx.Client(timeout=120, follow_redirects=True) as c:
        r = c.get(url)
        r.raise_for_status()
        return r.content


def prepare_en() -> list[dict]:
    raw = _get(EN_URL)
    lines = gzip.decompress(raw).decode().split("\n")
    rows = []
    for i, line in enumerate(l for l in lines if l.strip()):
        d = json.loads(line)
        flagged = any(d.get(c) == 1 for c in EN_CATS)
        rows.append({"id": f"en{i:04d}", "text": d["prompt"], "flagged": flagged,
                     "categories": {c: d.get(c) for c in EN_CATS}})
    return rows


def prepare_ja() -> list[dict]:
    text = _get(JA_URL).decode()
    rows = []
    for line in text.split("\n"):
        if not line.strip():
            continue
        d = json.loads(line)
        flagged = d["label"] in ("toxic", "has_toxic_expression")
        body = d["text"]
        truncated = len(body) > MAX_CHARS
        rows.append({"id": f"ja{d['id']}", "text": body[:MAX_CHARS], "flagged": flagged,
                     "label": d["label"], "truncated": truncated,
                     "categories": {k: d[k] for k in
                                    ("obscene", "discriminatory", "violent", "illegal",
                                     "personal", "corporate", "others")}})
    return rows


def load(name: str) -> list[dict]:
    path = DATA / f"{name}.jsonl"
    return [json.loads(l) for l in path.read_text().split("\n") if l]


def main() -> None:
    DATA.mkdir(exist_ok=True)
    for name, fn in (("en", prepare_en), ("ja", prepare_ja)):
        rows = fn()
        (DATA / f"{name}.jsonl").write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows))
        flagged = sum(r["flagged"] for r in rows)
        print(f"{name}: {len(rows)} rows, {flagged} flagged ({flagged / len(rows):.1%})")


if __name__ == "__main__":
    main()
