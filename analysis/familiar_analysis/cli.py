"""`uv run python -m familiar_analysis <command>` (from analysis/). Commands:

  quant-study    shortlist study: how much of the exact top 10 survives 8-bit scoring, by shortlist size
  vector-health  are an index's vectors unit length, finite, distinct; how far 8-bit rounding moves them
  compare        eval reports against a baseline, with paired bootstrap intervals
  summary        eval reports side by side, by tag
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from . import quant, vectors
from .evalstats import METRICS, Report, comparison_table, plot, summary_table


def _index(arg: str | None) -> Path:
    if arg in (None, "test"):
        found = vectors.test_indexes()
        if not found:
            raise SystemExit("no test index under build/: run `fam eval evals/core.json` once, or pass --index")
        return found[0]
    return vectors.default_index() if arg == "app" else Path(arg).expanduser()


def quant_study(a: argparse.Namespace) -> None:
    if a.synthetic:
        corpus = quant.synthetic(a.synthetic, seed=a.seed)
        queries = quant.synthetic(a.queries, seed=a.seed + 1)
        source = f"synthetic, {a.synthetic:,} clustered unit vectors"
    else:
        path = _index(a.index)
        data, _ = vectors.load(path)
        if len(data) < 2 * a.top:
            raise SystemExit(f"{path} has {len(data)} vectors: too few to study, try --index app or --synthetic")
        corpus, queries = quant.held_out(quant.normalize(data), a.queries, seed=a.seed)
        source = f"{path.name}, {len(queries)} of its vectors held out as queries"
    r = quant.study(corpus, queries, top=a.top)
    r["source"] = source
    print(f"{source}\n{r['rows']:,} rows × {r['dimension']}, top {r['top']}: "
          f"{r['float32MB']:.1f} MB as float32, {r['int8MB']:.1f} MB as int8")
    print(f"8-bit scores alone find {100 * r['agreeInt8']:.1f}% of the exact top {r['top']}")
    print("shortlist rescored exactly → share of the exact top found:")
    for s, v in r["agreeRescored"].items():
        print(f"  {s:>7,}  {100 * v:6.2f}%" + ("   ← the app" if s == quant.SHORTLIST else ""))
    print(f"largest 8-bit score error per query: median {r['scoreError']['median']:.4f}, "
          f"worst {r['scoreError']['max']:.4f}; median score at rank {r['top']}: {r['scoreAtTop']['median']:.3f}")
    if a.json:
        Path(a.json).write_text(json.dumps(r, indent=1))
    if a.plot:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        xs, ys = zip(*r["agreeRescored"].items())
        fig, ax = plt.subplots(figsize=(6, 3.6))
        ax.plot(xs, [100 * y for y in ys], marker="o")
        ax.axhline(100 * r["agreeInt8"], color="0.6", linestyle="--", label="8-bit alone")
        ax.axvline(quant.SHORTLIST, color="0.8", linewidth=0.8)
        ax.set_xscale("log")
        ax.set_xlabel("shortlist rescored exactly (rows)")
        ax.set_ylabel(f"% of exact top {r['top']} found")
        ax.set_title(source, fontsize=9)
        ax.legend(frameon=False)
        fig.tight_layout()
        fig.savefig(a.plot, dpi=160)


def vector_health(a: argparse.Namespace) -> None:
    path = _index(a.index)
    data, kinds = vectors.load(path)
    h = vectors.health(data)
    counts = {k: kinds.count(k) for k in sorted(set(kinds))}
    print(json.dumps({"index": path.name, "byKind": counts, **h}, indent=1))


def compare_cmd(a: argparse.Namespace) -> None:
    baseline = Report.load(a.baseline)
    candidates = [Report.load(p) for p in a.candidates]
    for c in candidates:
        print(comparison_table(baseline, c, by_tag=a.by_tag) + "\n")
    if a.plot:
        plot(baseline, candidates, a.plot, metric=a.metric)
        print(f"Saved {a.plot}")


def summary_cmd(a: argparse.Namespace) -> None:
    print(summary_table([Report.load(p) for p in a.reports], by_tag=not a.overall))


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(prog="familiar_analysis", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)

    q = sub.add_parser("quant-study", help="8-bit scoring against exact, by shortlist size")
    q.add_argument("--index", help="'test' (newest build/eval-*.sqlite, the default), 'app' (your own index: only "
                                   "numbers are printed), or a path")
    q.add_argument("--synthetic", type=int, metavar="ROWS", help="clustered synthetic vectors instead of an index")
    q.add_argument("--queries", type=int, default=200)
    q.add_argument("--top", type=int, default=10)
    q.add_argument("--seed", type=int, default=0)
    q.add_argument("--json", metavar="OUT")
    q.add_argument("--plot", metavar="PNG", help="needs the plot extra: uv run --extra plot …")
    q.set_defaults(run=quant_study)

    h = sub.add_parser("vector-health", help="unit length, finite, duplicates, 8-bit rounding error")
    h.add_argument("--index", help="'test' (default), 'app', or a path")
    h.set_defaults(run=vector_health)

    c = sub.add_parser("compare", help="eval reports against a baseline, with 95% intervals")
    c.add_argument("baseline")
    c.add_argument("candidates", nargs="+")
    c.add_argument("--by-tag", action="store_true")
    c.add_argument("--plot", metavar="PNG")
    c.add_argument("--metric", default="reciprocalRank", choices=list(METRICS), help="for --plot")
    c.set_defaults(run=compare_cmd)

    s = sub.add_parser("summary", help="eval reports side by side")
    s.add_argument("reports", nargs="+")
    s.add_argument("--overall", action="store_true", help="one row per run, no tags")
    s.set_defaults(run=summary_cmd)

    a = p.parse_args(argv)
    np.set_printoptions(suppress=True)
    a.run(a)
