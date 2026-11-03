"""Independent checks and measurements for Familiar. The app is Swift; nothing here ships in it.

- kernel: the C kernel (Sources/Int8Kernels) built as a library and called from Python, for tests against NumPy.
- quant: a NumPy reference for the 8-bit vectors and the shortlist study.
- vectors: reading vectors out of an index, read-only.
- evalstats: paired comparisons of `fam eval --json` reports, with bootstrap intervals.
"""

from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
