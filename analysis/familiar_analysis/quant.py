"""A NumPy reference for Familiar's 8-bit vectors (Sources/FamiliarCore/VectorKernels.swift and Lookup.swift), written
from the description rather than translated line by line, so the two can check each other. And the shortlist study:
how much of the exact top 10 survives 8-bit scoring, with and without exact rescoring.

Each row is stored as int8 plus one float scale: its largest |value| maps to ±127. The query is rounded the same way.
A score is (row · query) summed exactly in int32, times both scales. A compact search takes the best `shortlist` rows
by that score (1,000) and rescores them exactly from the float32 vectors."""

from __future__ import annotations

import numpy as np

DIMENSION = 768
SHORTLIST = 1000
#: The largest |row · query| possible in int8: 768 × 127 × 127 = 12,387,072. It fits int32 with room to spare, and is
#: under 2^24 = 16,777,216, so the int32 → float conversion before scaling is exact too.
DOT_BOUND = DIMENSION * 127 * 127


def round_half_away(x: np.ndarray) -> np.ndarray:
    """Swift's `.rounded()`: to nearest, ties away from zero. NumPy's `round` sends ties to even (2.5 → 2), which
    would make a different int8 for a value exactly halfway."""
    return np.sign(x) * np.floor(np.abs(x) + np.float32(0.5))


def quantize(vectors: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Rows as int8, and their scales. float32 arithmetic throughout, as in Swift; an all-zero row gets scale 0."""
    v = np.atleast_2d(np.asarray(vectors, dtype=np.float32))
    scales = (np.abs(v).max(axis=1) / np.float32(127)).astype(np.float32)
    divisor = np.where(scales > 0, scales, np.float32(1))
    q = np.clip(round_half_away(v / divisor[:, None]), -127, 127).astype(np.int8)
    q[scales == 0] = 0
    return q, scales


def int8_scores(matrix: np.ndarray, scales: np.ndarray, query: np.ndarray, query_scale: float) -> np.ndarray:
    """What Int8Kernels.c computes: exact int32 sums, then float(sum) × row scale × query scale, in that order."""
    dots = matrix.astype(np.int32) @ query.astype(np.int32)
    return (dots.astype(np.float32) * scales) * np.float32(query_scale)


def top_k(scores: np.ndarray, k: int) -> np.ndarray:
    """Indices of the k best scores, best first."""
    k = min(k, len(scores))
    if k <= 0:
        return np.zeros(0, dtype=np.int64)
    part = np.argpartition(-scores, k - 1)[:k]
    return part[np.argsort(-scores[part], kind="stable")]


def compact_search(vectors: np.ndarray, quantized: tuple[np.ndarray, np.ndarray], query: np.ndarray,
                   top: int = 10, shortlist: int = SHORTLIST) -> np.ndarray:
    """The `top` best rows: shortlist by 8-bit score, then rescore the shortlist exactly."""
    matrix, scales = quantized
    qq, qs = quantize(query)
    approx = int8_scores(matrix, scales, qq[0], float(qs[0]))
    candidates = top_k(approx, max(top, shortlist))
    return candidates[top_k(vectors[candidates] @ query, top)]


def normalize(v: np.ndarray) -> np.ndarray:
    v = np.asarray(v, dtype=np.float32)
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.where(n > 0, n, 1)


def synthetic(rows: int, dimension: int = DIMENSION, seed: int = 0, clusters: int = 256,
              spread: float = 0.6) -> np.ndarray:
    """Unit vectors in clusters. Real embeddings have close neighbours and many far rows; plain Gaussian vectors are
    all nearly equidistant, which makes any approximate search look worse than it is."""
    rng = np.random.default_rng(seed)
    centres = normalize(rng.standard_normal((clusters, dimension)))
    noise = normalize(rng.standard_normal((rows, dimension)))
    return normalize(centres[rng.integers(0, clusters, rows)] + spread * noise)


def study(corpus: np.ndarray, queries: np.ndarray, top: int = 10,
          shortlists: tuple[int, ...] = (10, 25, 50, 100, 250, 500, 1000, 2000)) -> dict:
    """For each query: the exact top `top` by float32, against 8-bit scoring alone and 8-bit with exact rescoring of
    each shortlist size. Agreement = share of the exact top `top` found, over all queries. Also the largest error of
    an 8-bit score, and the exact score at rank `top` (how crowded the top is)."""
    corpus = np.ascontiguousarray(corpus, dtype=np.float32)
    queries = np.asarray(queries, dtype=np.float32)
    matrix, scales = quantize(corpus)
    shortlists = tuple(s for s in shortlists if s < len(corpus)) + (len(corpus),)
    raw, agree, errors, kth = 0, dict.fromkeys(shortlists, 0), [], []
    for query in queries:
        exact = corpus @ query
        truth_idx = top_k(exact, top)
        truth = set(truth_idx.tolist())
        kth.append(float(exact[truth_idx[-1]]))
        qq, qs = quantize(query)
        approx = int8_scores(matrix, scales, qq[0], float(qs[0]))
        errors.append(float(np.abs(approx - exact).max()))
        raw += len(truth & set(top_k(approx, top).tolist()))
        order = top_k(approx, max(shortlists))
        for s in shortlists:
            cand = order[:max(top, s)]
            agree[s] += len(truth & set(cand[top_k(exact[cand], top)].tolist()))
    total = top * len(queries)
    return {
        "rows": int(len(corpus)), "dimension": int(corpus.shape[1]), "queries": int(len(queries)), "top": top,
        "float32MB": corpus.nbytes / 2**20, "int8MB": (matrix.nbytes + scales.nbytes) / 2**20,
        "agreeInt8": raw / total,
        "agreeRescored": {int(s): n / total for s, n in agree.items()},
        "scoreError": {"median": float(np.median(errors)), "max": float(np.max(errors))},
        "scoreAtTop": {"median": float(np.median(kth))},
    }


def held_out(vectors: np.ndarray, queries: int, seed: int = 0) -> tuple[np.ndarray, np.ndarray]:
    """Real vectors as queries: `queries` rows drawn out of the corpus (so a query can't find itself)."""
    rng = np.random.default_rng(seed)
    pick = rng.choice(len(vectors), size=min(queries, len(vectors) // 2), replace=False)
    keep = np.ones(len(vectors), bool)
    keep[pick] = False
    return vectors[keep], vectors[pick]
