# analysis

Checks and measurements for Familiar, written in Python. The app is all Swift, and nothing in this folder ships
with it. The `fam` command already runs the evals, self-tests and benchmarks. This folder covers what `fam` doesn't:

| | What | Why it's here and not in `fam` |
|---|---|---|
| `tests/test_kernel.py` | The 8-bit C kernel (`Sources/Int8Kernels`) is compiled as a library and called from Python, then checked against exact NumPy arithmetic on both paths (SDOT and the plain loop) | It tests the kernel on its own, without Swift. It covers every row count, range edge and dimension, the way the threads split the rows, and the ±127 extremes |
| `familiar_analysis/quant.py`, `tests/test_quant.py` | A separate NumPy version of the 8-bit vectors: rounding, scales, shortlist, exact rescoring | A second implementation to check the first. Swift rounds ties away from zero, NumPy rounds them to even, and the tests hold to Swift's rule |
| `quant-study` | How much of the exact top 10 survives 8-bit scoring, for each shortlist size, on real or synthetic vectors | `fam bench-vectors` measures speed on synthetic data. This measures accuracy on the vectors you actually index |
| `compare`, `summary` | `fam eval --json` reports, paired by query, with 95% bootstrap intervals, overall and by tag, plus an optional plot | With ~100 queries, a small change in MRR can be noise. The interval says whether it is |

## Setup

Needs [uv](https://docs.astral.sh/uv/) (`brew install uv`) and Xcode's command-line tools (for `clang`). Run
everything from this folder:

```sh
cd analysis
uv run --group dev pytest                       # all tests (the kernel tests need Apple silicon)
```

## Commands

```sh
# The shortlist study: on the newest test index under build/, on your own index, or on synthetic vectors
uv run python -m familiar_analysis quant-study                     # build/eval-*.sqlite (the test collection)
uv run python -m familiar_analysis quant-study --index app         # your index: prints only numbers
uv run python -m familiar_analysis quant-study --synthetic 100000 --json out.json
uv run --extra plot python -m familiar_analysis quant-study --synthetic 100000 --plot shortlist.png

# Whether an index's vectors are unit length, finite and distinct, and how far 8-bit rounding moves them
uv run python -m familiar_analysis vector-health --index test

# Eval runs: make reports with fam, then compare them
fam eval evals/core.json --index build/eval-a.sqlite --json evals/results/a.json
FAMILIAR_BUDGET_PHOTO=280 fam eval evals/core.json --index build/eval-b.sqlite --json evals/results/b.json
uv run python -m familiar_analysis compare ../evals/results/a.json ../evals/results/b.json --by-tag
uv run python -m familiar_analysis summary ../evals/results/*.json --overall
uv run --extra plot python -m familiar_analysis compare a.json b.json c.json --plot delta.png
```

## Privacy

`--index app` opens your own index read-only and reads only the vectors and their kinds, never paths, names or text.
The output is counts and numbers. Eval reports name only files from the generated test collection.
