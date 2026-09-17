"""Evaluation metrics shared by the moderation and command runs.

Everything here is pure and unit-tested (test_metrics.py). No API calls, no I/O.
Scores are probabilities in [0, 1]; labels are booleans (True = positive class).
"""

from __future__ import annotations

import math


def confusion(labels: list[bool], preds: list[bool]) -> dict:
    tp = sum(l and p for l, p in zip(labels, preds))
    fp = sum((not l) and p for l, p in zip(labels, preds))
    fn = sum(l and (not p) for l, p in zip(labels, preds))
    tn = sum((not l) and (not p) for l, p in zip(labels, preds))
    return {"tp": tp, "fp": fp, "fn": fn, "tn": tn}


def precision_recall_f1(labels: list[bool], preds: list[bool]) -> dict:
    c = confusion(labels, preds)
    tp, fp, fn = c["tp"], c["fp"], c["fn"]
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {"precision": precision, "recall": recall, "f1": f1, **c}


def threshold_preds(scores: list[float], threshold: float) -> list[bool]:
    return [s >= threshold for s in scores]


def average_precision(labels: list[bool], scores: list[float]) -> float:
    """Area under the precision-recall curve (average precision).

    Ranks by score descending and integrates precision over recall. This is the
    threshold-free quality summary; it needs at least one positive.
    """
    positives = sum(labels)
    if positives == 0:
        return float("nan")
    order = sorted(range(len(scores)), key=lambda i: scores[i], reverse=True)
    tp = 0
    fp = 0
    ap = 0.0
    prev_recall = 0.0
    # Group by equal score so ties are handled at the same operating point.
    i = 0
    while i < len(order):
        j = i
        while j < len(order) and scores[order[j]] == scores[order[i]]:
            j += 1
        for k in range(i, j):
            if labels[order[k]]:
                tp += 1
            else:
                fp += 1
        recall = tp / positives
        precision = tp / (tp + fp)
        ap += precision * (recall - prev_recall)
        prev_recall = recall
        i = j
    return ap


def roc_auc(labels: list[bool], scores: list[float]) -> float:
    """AUROC via the rank-sum (Mann-Whitney) identity, with tie handling."""
    pos = [s for s, l in zip(scores, labels) if l]
    neg = [s for s, l in zip(scores, labels) if not l]
    if not pos or not neg:
        return float("nan")
    order = sorted(range(len(scores)), key=lambda i: scores[i])
    ranks = [0.0] * len(scores)
    i = 0
    while i < len(order):
        j = i
        while j < len(order) and scores[order[j]] == scores[order[i]]:
            j += 1
        avg_rank = (i + j - 1) / 2 + 1  # 1-based average rank for the tie group
        for k in range(i, j):
            ranks[order[k]] = avg_rank
        i = j
    rank_sum_pos = sum(r for r, l in zip(ranks, labels) if l)
    n_pos, n_neg = len(pos), len(neg)
    return (rank_sum_pos - n_pos * (n_pos + 1) / 2) / (n_pos * n_neg)


def expected_calibration_error(labels: list[bool], scores: list[float], bins: int = 10) -> dict:
    """ECE plus per-bin detail. Bins are equal-width over [0, 1]."""
    edges = [i / bins for i in range(bins + 1)]
    detail = []
    ece = 0.0
    n = len(scores)
    for b in range(bins):
        lo, hi = edges[b], edges[b + 1]
        idx = [i for i, s in enumerate(scores) if (s >= lo and (s < hi or (b == bins - 1 and s <= hi)))]
        if not idx:
            detail.append({"lo": lo, "hi": hi, "count": 0, "confidence": None, "accuracy": None})
            continue
        conf = sum(scores[i] for i in idx) / len(idx)
        acc = sum(labels[i] for i in idx) / len(idx)
        ece += len(idx) / n * abs(conf - acc)
        detail.append({"lo": lo, "hi": hi, "count": len(idx), "confidence": conf, "accuracy": acc})
    return {"ece": ece, "bins": detail}


def automation_coverage(labels: list[bool], scores: list[float], low: float, high: float) -> dict:
    """Two-threshold triage: below `low` auto-negative, above `high` auto-positive, else review.

    Reports what fraction is handled automatically and the error rate among the
    auto-decided items (missed positives + false alarms / auto count).
    """
    auto_pos = [i for i, s in enumerate(scores) if s >= high]
    auto_neg = [i for i, s in enumerate(scores) if s < low]
    review = [i for i, s in enumerate(scores) if low <= s < high]
    auto = auto_pos + auto_neg
    errors = sum(not labels[i] for i in auto_pos) + sum(labels[i] for i in auto_neg)
    missed = sum(labels[i] for i in auto_neg)  # positives wrongly auto-passed
    n = len(scores)
    return {
        "low": low,
        "high": high,
        "auto_fraction": len(auto) / n if n else 0.0,
        "review_fraction": len(review) / n if n else 0.0,
        "auto_error_rate": errors / len(auto) if auto else 0.0,
        "auto_missed_positives": missed,
        "auto_count": len(auto),
        "review_count": len(review),
    }


def macro_average(per_class: dict[str, dict], keys: tuple[str, ...]) -> dict:
    out = {}
    for k in keys:
        vals = [m[k] for m in per_class.values() if isinstance(m.get(k), (int, float)) and not math.isnan(m[k])]
        out[k] = sum(vals) / len(vals) if vals else float("nan")
    return out
