"""Eval comparisons on small made-up reports, and a reading of every report kept in evals/results/ if there are any."""

import json

import numpy as np
import pytest

from familiar_analysis import REPO
from familiar_analysis.evalstats import Report, compare, comparison_table, moved, paired_bootstrap, summarize, \
    summary_table


def outcome(q, rr, tag="image", margin=0.1, expected=1):
    rank = None if rr == 0 else round(1 / rr)
    return {"q": q, "tag": tag, "ranks": [rank] if rank else [], "expectedFiles": expected,
            "recall1": float(rank == 1), "recall5": float(bool(rank) and rank <= 5),
            "recall10": float(bool(rank) and rank <= 10), "reciprocalRank": rr, "ndcg10": rr, "location": None,
            "absentShown": [], "milliseconds": 7.0, "margin": margin, "top": []}


def report(tmp_path, name, outcomes):
    path = tmp_path / f"{name}.json"
    path.write_text(json.dumps({"label": name, "date": "", "budgets": {}, "profile": "standard", "files": 0,
                                "vectors": 0, "outcomes": outcomes}))
    return Report.load(path)


def test_bootstrap_interval():
    a = np.zeros(100)
    assert paired_bootstrap(a, a) == (0.0, 0.0, 0.0)
    mean, lo, hi = paired_bootstrap(a, np.full(100, 0.5))
    assert mean == lo == hi == 0.5
    rng = np.random.default_rng(0)
    noise = rng.normal(0, 1, 100)
    mean, lo, hi = paired_bootstrap(a, noise)
    assert lo < mean < hi and lo < 0 < hi                 # pure noise: the interval spans zero


def test_one_query_moving_is_not_a_clear_change(tmp_path):
    base = report(tmp_path, "base", [outcome(f"q{i}", 1.0) for i in range(100)])
    one = report(tmp_path, "one", [outcome("q0", 0.5)] + [outcome(f"q{i}", 1.0) for i in range(1, 100)])
    mrr = next(d for d in compare(base, one) if d.metric == "reciprocalRank")
    assert mrr.mean == pytest.approx(-0.005) and not mrr.clear
    assert [a["q"] for a, _ in moved(base, one)] == ["q0"]


def test_a_broad_drop_is_clear(tmp_path):
    base = report(tmp_path, "base", [outcome(f"q{i}", 1.0) for i in range(100)])
    worse = report(tmp_path, "worse", [outcome(f"q{i}", 0.5 if i % 3 else 1.0) for i in range(100)])
    mrr = next(d for d in compare(base, worse) if d.metric == "reciprocalRank")
    assert mrr.clear and mrr.high < 0


def test_pairs_by_query_and_skips_check_only_queries(tmp_path):
    base = report(tmp_path, "base", [outcome("a", 1.0), outcome("b", 0.5), outcome("trap", 0, expected=0)])
    cand = report(tmp_path, "cand", [outcome("b", 1.0), outcome("a", 1.0), outcome("new", 0.2)])
    mrr = next(d for d in compare(base, cand) if d.metric == "reciprocalRank")
    assert mrr.n == 2 and mrr.mean == pytest.approx(0.25)
    s = summarize(base)
    assert s["n"] == 2 and s["checksOnly"] == 1


def test_tables_render(tmp_path):
    base = report(tmp_path, "base", [outcome("a", 1.0, "image"), outcome("b", 0.5, "audio")])
    cand = report(tmp_path, "cand", [outcome("a", 0.5, "image"), outcome("b", 1.0, "audio")])
    assert "| base | **all** | 2 |" in summary_table([base, cand])
    table = comparison_table(base, cand, by_tag=True)
    assert "\"a\": 1 → 2" in table and "| audio |" in table


@pytest.mark.parametrize("path", sorted((REPO / "evals" / "results").glob("*.json")), ids=lambda p: p.name)
def test_saved_reports_load(path):
    """The local results (not in the repository) still parse; skipped where there are none."""
    data = json.loads(path.read_text())
    if "outcomes" not in data:
        pytest.skip("not a search eval report")
    r = Report.load(path)
    s = summarize(r)
    assert s["n"] > 0 and 0 <= s["reciprocalRank"] <= 1
