"""Vectors out of an index (the app's index.sqlite, or a `fam eval` index under build/). The file is opened read-only
and only vectors and their kinds are read: never paths, names or text, since the app's index holds what's on
someone's Mac."""

from __future__ import annotations

import os
import sqlite3
from pathlib import Path

import numpy as np

from . import REPO

APP_INDEX = Path.home() / "Library" / "Application Support" / "Familiar" / "index.sqlite"


def default_index() -> Path:
    return Path(os.environ.get("FAMILIAR_INDEX", APP_INDEX))


def test_indexes() -> list[Path]:
    """The `fam eval` indexes built from the test collection (nothing private), newest first."""
    return sorted((REPO / "build").glob("eval-*.sqlite"), key=lambda p: p.stat().st_mtime, reverse=True)


def load(path: str | Path, kinds: set[str] | None = None) -> tuple[np.ndarray, list[str]]:
    """The stored float32 vectors (rows × 768) and each row's kind (text, page, image, frame, audio…)."""
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"no index at {path}")
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        rows = db.execute("SELECT kind, vector FROM segments ORDER BY id").fetchall()
    finally:
        db.close()
    rows = [(k, v) for k, v in rows if kinds is None or k in kinds]
    if not rows:
        return np.zeros((0, 768), np.float32), []
    lengths = {len(v) for _, v in rows}
    if len(lengths) != 1 or lengths.pop() % 4:
        raise ValueError("vectors of different or odd lengths in the index")
    matrix = np.frombuffer(b"".join(v for _, v in rows), dtype="<f4").reshape(len(rows), -1).copy()
    return matrix, [k for k, _ in rows]


def health(vectors: np.ndarray) -> dict:
    """What search assumes of the vectors: unit length, finite, and how much 8-bit rounding moves a value."""
    from .quant import quantize

    if len(vectors) == 0:
        return {"rows": 0}
    norms = np.linalg.norm(vectors, axis=1)
    matrix, scales = quantize(vectors)
    error = np.abs(matrix.astype(np.float32) * scales[:, None] - vectors)
    return {
        "rows": int(len(vectors)), "dimension": int(vectors.shape[1]),
        "norm": {"min": float(norms.min()), "median": float(np.median(norms)), "max": float(norms.max())},
        "notUnitLength": int(np.sum(np.abs(norms - 1) > 1e-3)),
        "nonFinite": int(np.sum(~np.isfinite(vectors).all(axis=1))),
        "duplicateRows": int(len(vectors) - len(np.unique(vectors, axis=0))),
        "int8ValueError": {"median": float(np.median(error)), "max": float(error.max())},
    }
