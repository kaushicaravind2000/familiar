"""Int8Kernels.c against exact NumPy arithmetic, on both paths (SDOT and the plain loop).

The app always uses 768 values a row, but the threads split the rows at rows × chunk / chunks, so a range rarely
starts or ends on a multiple of 4: the four-row fast path and the one-row tail both run on real searches. These
tests cover every row count and range edge, dimensions that aren't multiples of 32 (the 16-wide step and the scalar
tail), and the extremes the int32 sums must hold."""

import numpy as np
import pytest

from familiar_analysis import quant
from familiar_analysis.kernel import Kernel, apple_silicon

pytestmark = pytest.mark.skipif(not apple_silicon(), reason="the kernel is built for Apple silicon")

SENTINEL = np.float32(-12345.0)


@pytest.fixture(scope="module", params=["sdot", "plain"])
def kernel(request):
    return Kernel(request.param)


def reference(matrix, scales, query, query_scale):
    return quant.int8_scores(matrix, scales, query, query_scale)


def random_case(rng, rows, dimension):
    matrix = rng.integers(-127, 128, (rows, dimension), dtype=np.int8)
    query = rng.integers(-127, 128, dimension, dtype=np.int8)
    scales = rng.uniform(1e-4, 1e-2, rows).astype(np.float32)
    return matrix, scales, query, np.float32(rng.uniform(1e-4, 1e-2))


@pytest.mark.parametrize("dimension", [768, 32, 64, 16, 48, 80, 17, 31, 1])
@pytest.mark.parametrize("rows", [1, 2, 3, 4, 5, 7, 8, 9, 37])
def test_every_row_count_and_dimension(kernel, rows, dimension):
    rng = np.random.default_rng(rows * 1000 + dimension)
    matrix, scales, query, qs = random_case(rng, rows, dimension)
    np.testing.assert_array_equal(kernel.scores(matrix, scales, query, qs), reference(matrix, scales, query, qs))


def test_ranges_touch_only_their_rows(kernel):
    """Any first..<last fills exactly those rows, and the threads' split covers every row once."""
    rng = np.random.default_rng(1)
    matrix, scales, query, qs = random_case(rng, 103, 768)
    want = reference(matrix, scales, query, qs)
    for _ in range(200):
        first, last = sorted(rng.integers(0, 104, 2))
        out = np.full(103, SENTINEL, np.float32)
        kernel.scores(matrix, scales, query, qs, first, last, out)
        np.testing.assert_array_equal(out[first:last], want[first:last])
        assert (out[:first] == SENTINEL).all() and (out[last:] == SENTINEL).all()
    for chunks in (1, 3, 12, 16, 103):   # as VectorKernels.approximateScores splits the rows
        out = np.full(103, SENTINEL, np.float32)
        for c in range(chunks):
            kernel.scores(matrix, scales, query, qs, 103 * c // chunks, 103 * (c + 1) // chunks, out)
        np.testing.assert_array_equal(out, want)


def test_empty_range_writes_nothing(kernel):
    matrix, scales, query, qs = random_case(np.random.default_rng(2), 8, 768)
    out = np.full(8, SENTINEL, np.float32)
    kernel.scores(matrix, scales, query, qs, 5, 5, out)
    assert (out == SENTINEL).all()


@pytest.mark.parametrize("value", [127, -127])
def test_extremes_sum_exactly(kernel, value):
    """Every value at ±127: the largest sums there are (768 × 127 × 127 = 12,387,072). Scales of 1 show the raw
    int32 sum, exact as a float because it's under 2^24."""
    rows, dimension = 9, 768
    matrix = np.full((rows, dimension), value, np.int8)
    matrix[1::2] *= -1                        # alternate rows the other sign: the most negative sums too
    query = np.full(dimension, 127, np.int8)
    out = kernel.scores(matrix, np.ones(rows, np.float32), query, 1.0)
    expected = np.where(np.arange(rows) % 2 == 0, value, -value) * 127 * dimension
    np.testing.assert_array_equal(out, expected.astype(np.float32))
    assert abs(out).max() == quant.DOT_BOUND < 2**24


def test_matches_quantized_search_scores(kernel):
    """End to end on unit vectors: quantize as the Swift does, score with the kernel, and the scores track the exact
    cosines within the 8-bit error, with the same ranking at the top."""
    corpus = quant.synthetic(5000, seed=3)
    query = quant.synthetic(1, seed=4)[0]
    matrix, scales = quant.quantize(corpus)
    qq, qs = quant.quantize(query)
    got = kernel.scores(matrix, scales, qq[0], float(qs[0]))
    np.testing.assert_array_equal(got, quant.int8_scores(matrix, scales, qq[0], float(qs[0])))
    assert np.abs(got - corpus @ query).max() < 0.02


def test_both_paths_agree():
    rng = np.random.default_rng(5)
    matrix, scales, query, qs = random_case(rng, 1001, 768)
    np.testing.assert_array_equal(Kernel("sdot").scores(matrix, scales, query, qs),
                                  Kernel("plain").scores(matrix, scales, query, qs))
