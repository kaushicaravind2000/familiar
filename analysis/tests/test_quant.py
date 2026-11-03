"""The 8-bit reference: rounding as Swift does it, the scale rule, and that shortlist rescoring recovers the exact top."""

import numpy as np

from familiar_analysis import quant


def test_ties_round_away_from_zero():
    """Swift's .rounded() takes 2.5 to 3 and -2.5 to -3; NumPy's round would give 2 and -2."""
    x = np.array([0.5, 1.5, 2.5, -0.5, -2.5, 2.4999, -2.5001], np.float32)
    assert quant.round_half_away(x).tolist() == [1, 2, 3, -1, -3, 2, -3]
    assert np.round(np.float32(2.5)) == 2        # the difference this guards against


def test_largest_value_maps_to_127():
    rng = np.random.default_rng(0)
    v = quant.normalize(rng.standard_normal((50, 768)))
    q, s = quant.quantize(v)
    assert (np.abs(q).max(axis=1) == 127).all()
    np.testing.assert_allclose(s, np.abs(v).max(axis=1) / 127, rtol=1e-6)
    assert np.abs(q.astype(np.float32) * s[:, None] - v).max() <= s.max() / 2 * (1 + 1e-5)


def test_zero_row_and_symmetry():
    q, s = quant.quantize(np.zeros((1, 768), np.float32))
    assert s[0] == 0 and not q.any()
    v = quant.synthetic(10, seed=1)
    qa, sa = quant.quantize(v)
    qb, sb = quant.quantize(-v)
    np.testing.assert_array_equal(qa, -qb)       # ±127, never -128: negation is exact
    np.testing.assert_array_equal(sa, sb)
    assert qa.min() >= -127


def test_scores_error_is_small_on_unit_vectors():
    corpus = quant.synthetic(2000, seed=2)
    query = quant.synthetic(1, seed=3)[0]
    m, s = quant.quantize(corpus)
    qq, qs = quant.quantize(query)
    assert np.abs(quant.int8_scores(m, s, qq[0], qs[0]) - corpus @ query).max() < 0.02


def test_rescoring_a_shortlist_finds_the_exact_top():
    corpus = quant.synthetic(20_000, seed=4)
    queries = quant.synthetic(50, seed=5)
    quantized = quant.quantize(corpus)
    for q in queries:
        exact = quant.top_k(corpus @ q, 10)
        np.testing.assert_array_equal(quant.compact_search(corpus, quantized, q, top=10, shortlist=1000), exact)


def test_study_reports_agreement_that_grows_with_the_shortlist():
    r = quant.study(quant.synthetic(5000, seed=6), quant.synthetic(40, seed=7), top=10)
    values = list(r["agreeRescored"].values())
    assert values == sorted(values) and values[-1] == 1.0
    assert r["agreeRescored"][1000] == 1.0
    assert r["int8MB"] < r["float32MB"] / 3.9


def test_held_out_queries_are_not_in_the_corpus():
    v = quant.synthetic(100, seed=8)
    corpus, queries = quant.held_out(v, 20)
    assert len(corpus) == 80 and len(queries) == 20
    assert not any((corpus == q).all(axis=1).any() for q in queries)
