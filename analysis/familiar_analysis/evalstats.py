"""Comparing `fam eval --json` reports. `fam eval --baseline` prints how the averages moved; with ~100 queries a move
of a few hundredths can be noise. This pairs the runs query by query and gives each difference a 95% interval by
resampling the queries (paired bootstrap), overall and per tag, so a setting is chosen on more than luck."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np

METRICS = ("recall1", "recall5", "recall10", "reciprocalRank", "ndcg10", "margin")
NAMES = {"recall1": "R@1", "recall5": "R@5", "recall10": "R@10", "reciprocalRank": "MRR", "ndcg10": "nDCG@10",
         "margin": "margin"}
COMPARED = ("reciprocalRank", "ndcg10", "recall1", "margin")


@dataclass
class Report:
    path: Path
    label: str
    budgets: dict
    profile: str
    index_seconds: float | None
    outcomes: list[dict]

    @classmethod
    def load(cls, path: str | Path) -> "Report":
        path = Path(path)
        d = json.loads(path.read_text())
        return cls(path, d.get("label") or path.stem, d.get("budgets", {}), d.get("profile", "?"),
                   d.get("indexSeconds"), d["outcomes"])

    @property
    def scored(self) -> list[dict]:
        """Queries with right answers to find; the others only check what must not appear."""
        return [o for o in self.outcomes if o["expectedFiles"] > 0]

    @property
    def tags(self) -> list[str]:
        return sorted({o["tag"] for o in self.outcomes})


def summarize(report: Report, tag: str | None = None) -> dict:
    rows = [o for o in report.outcomes if tag is None or o["tag"] == tag]
    scored = [o for o in rows if o["expectedFiles"] > 0]
    s = {"n": len(scored), "checksOnly": len(rows) - len(scored),
         "absentShown": sum(len(o["absentShown"]) for o in rows)}
    for m in METRICS:   # older reports lack some (margin came later)
        values = [o[m] for o in scored if m in o]
        s[m] = float(np.mean(values)) if values else float("nan")
    locatable = [o for o in scored if o.get("location") is not None]
    s["located"], s["locatable"] = sum(bool(o["location"]) for o in locatable), len(locatable)
    ms = [o["milliseconds"] for o in rows]
    s["p50ms"] = float(np.median(ms)) if ms else float("nan")
    return s


def paired_bootstrap(before: np.ndarray, after: np.ndarray, rounds: int = 10_000,
                     seed: int = 0) -> tuple[float, float, float]:
    """Mean of after − before over paired queries, and its 95% interval from resampling the queries."""
    diff = np.asarray(after, float) - np.asarray(before, float)
    if len(diff) == 0:
        return (float("nan"),) * 3
    rng = np.random.default_rng(seed)
    means = diff[rng.integers(0, len(diff), (rounds, len(diff)))].mean(axis=1)
    lo, hi = np.percentile(means, [2.5, 97.5])
    return float(diff.mean()), float(lo), float(hi)


@dataclass
class Delta:
    metric: str
    tag: str | None
    n: int
    mean: float
    low: float
    high: float

    @property
    def clear(self) -> bool:
        """The interval leaves out zero: more than noise across these queries."""
        return self.low > 0 or self.high < 0


def pairs(baseline: Report, candidate: Report) -> list[tuple[dict, dict]]:
    old = {o["q"]: o for o in baseline.scored}
    return [(old[o["q"]], o) for o in candidate.scored if o["q"] in old]


def compare(baseline: Report, candidate: Report, by_tag: bool = False,
            metrics: tuple[str, ...] = COMPARED) -> list[Delta]:
    matched = pairs(baseline, candidate)
    tags = [None] + (sorted({b["tag"] for _, b in matched}) if by_tag else [])
    out = []
    for tag in tags:
        sel = [(a, b) for a, b in matched if tag is None or b["tag"] == tag]
        for m in metrics:
            both = [(a[m], b[m]) for a, b in sel if m in a and m in b]
            mean, lo, hi = paired_bootstrap(np.array([x for x, _ in both]), np.array([y for _, y in both]))
            out.append(Delta(m, tag, len(both), mean, lo, hi))
    return out


def moved(baseline: Report, candidate: Report) -> list[tuple[dict, dict]]:
    """Queries whose first right answer changed rank, worst change first."""
    changed = [(a, b) for a, b in pairs(baseline, candidate) if a["reciprocalRank"] != b["reciprocalRank"]]
    return sorted(changed, key=lambda p: p[1]["reciprocalRank"] - p[0]["reciprocalRank"])


def _f(x: float, signed: bool = False, digits: int = 3) -> str:
    if x != x:
        return "–"
    return f"{x:+.{digits}f}" if signed else f"{x:.{digits}f}"


def summary_table(reports: list[Report], by_tag: bool = True) -> str:
    """Markdown: each run overall, then by tag."""
    tags = sorted({t for r in reports for t in r.tags}) if by_tag else []
    lines = ["| run | tag | n | R@1 | R@5 | R@10 | MRR | nDCG@10 | margin | located | traps shown | p50 ms |",
             "|" + "---|" * 12]
    for r in reports:
        for tag in [None] + tags:
            s = summarize(r, tag)
            if s["n"] == 0 and s["checksOnly"] == 0:
                continue
            loc = f"{s['located']}/{s['locatable']}" if s["locatable"] else "–"
            lines.append(f"| {r.label if tag is None else ''} | {tag or '**all**'} | {s['n']} | "
                         f"{_f(s['recall1'], digits=2)} | {_f(s['recall5'], digits=2)} | {_f(s['recall10'], digits=2)} | "
                         f"{_f(s['reciprocalRank'])} | {_f(s['ndcg10'])} | {_f(s['margin'], signed=True)} | {loc} | "
                         f"{s['absentShown']} | {_f(s['p50ms'], digits=1)} |")
    return "\n".join(lines)


def comparison_table(baseline: Report, candidate: Report, by_tag: bool = False) -> str:
    lines = [f"**{candidate.label}** against **{baseline.label}**: paired by query, 95% bootstrap interval, "
             "★ where the interval leaves out zero", "",
             "| tag | n | metric | Δ | 95% interval |", "|---|---|---|---|---|"]
    for d in compare(baseline, candidate, by_tag):
        lines.append(f"| {d.tag or '**all**'} | {d.n} | {NAMES[d.metric]} | {_f(d.mean, signed=True)}"
                     f"{' ★' if d.clear else ''} | [{_f(d.low, signed=True)}, {_f(d.high, signed=True)}] |")
    if baseline.index_seconds and candidate.index_seconds:
        lines += ["", f"Indexing: {candidate.index_seconds:.0f} s against {baseline.index_seconds:.0f} s "
                      f"({candidate.index_seconds / baseline.index_seconds:.2f}×)"]
    changed = moved(baseline, candidate)
    if changed:
        lines += ["", "First right answer moved:", ""]
        for a, b in changed:
            before = a["ranks"][0] if a["ranks"] else "none"
            after = b["ranks"][0] if b["ranks"] else "none"
            lines.append(f"- [{b['tag']}] \"{b['q']}\": {before} → {after}")
    return "\n".join(lines)


def plot(baseline: Report, candidates: list[Report], out: str | Path, metric: str = "reciprocalRank") -> None:
    """Each candidate's change in one metric against the baseline, by tag, with its interval."""
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    tags = [None] + sorted({t for c in candidates for t in c.tags})
    fig, ax = plt.subplots(figsize=(8, 4))
    y, labels = 0, []
    for c in candidates:
        found = {d.tag: d for d in compare(baseline, c, by_tag=True, metrics=(metric,))}
        for tag in tags:
            if tag not in found or found[tag].n == 0:
                continue
            d = found[tag]
            if tag is not None and d.low == d.high == 0:   # every query in the tag ranked the same: left out
                continue
            ax.errorbar(d.mean, y, xerr=[[d.mean - d.low], [d.high - d.mean]], fmt="o",
                        color="C0" if d.clear else "0.55", capsize=3)
            labels.append(f"{c.label}: {tag or 'all'} (n={d.n})")
            y += 1
    fig.set_size_inches(8, 0.35 * y + 1.5)
    ax.axvline(0, color="0.3", linewidth=0.8)
    ax.set_yticks(range(len(labels)), labels)
    ax.invert_yaxis()
    ax.set_xlabel(f"Δ {NAMES[metric]} against {baseline.label} (95% interval; tags with no change left out)")
    fig.tight_layout()
    fig.savefig(out, dpi=160)
