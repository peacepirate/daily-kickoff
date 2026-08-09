"""S2.0 — the launch gate, defined so that it can fail.

The question is one sentence: **can the source pool sustain seven public cards a
day, indefinitely?** Everything downstream assumes yes, and nothing had measured
it.

The gate as first written could not fail. It counted qualifying items in the
pool against a round threshold, and the same filter already cleared that
threshold before any work was done. A gate that is met on the day it is written
measures nothing.

So this measures **arrivals, not inventory.** A pool of sixty is not a supply of
sixty: the feed spends seven a day, and what matters is how many new qualifying
items arrive each day to replace them. A pool that gains two and spends seven
drains in under two weeks, and it looks perfectly healthy the whole time.

Three tests, and PASS requires all three:

  sustainability   mean net daily admissions >= DAILY_CAP
                   Below this the pool drains. Arithmetic, not preference.

  selectivity      mean net daily admissions >= SELECTIVITY_RATIO x DAILY_CAP
                   Below this the ranking is decorative: everything that
                   arrives gets published, and the product is a link dump with
                   extra steps. The plan already recorded a 1.5:1 ratio as
                   "publish-almost-everything"; 2:1 is the floor for the word
                   "selection" to mean anything.

  diversity        median distinct sources per day >= DAILY_CAP
                   feasibility  FINAL_PER_SOURCE is 1, so seven cards from six
                   sources is not thin — it is impossible. This one is not an
                   opinion about quality; it is a constraint the selector
                   already enforces.

**The waiver rule.** Selectivity may be waived by the owner for a stated window,
recorded in the plan document with a date. Sustainability and diversity may not
be: waiving them does not lower a standard, it asserts something arithmetically
false about what the product can do. A gate whose every clause is waivable is
not a gate either.

Reads the record sidecars in `scripts/logs/`, which are the only per-day arrival
record that exists. That directory is gitignored and single-machine, so this
measures the machine it runs on and says so.
"""
from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

# Both imported rather than restated. A gate whose numbers drift from the
# selector's is a gate measuring a product that does not exist.
try:
    from feed_select import DAILY_CAP, FINAL_PER_SOURCE
    from feed_pool import qualifies
except ImportError:                                     # pragma: no cover
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from feed_select import DAILY_CAP, FINAL_PER_SOURCE
    from feed_pool import qualifies

# Two arrivals per published card. At 1:1 the ranking chooses nothing — every
# item that clears the quality bar goes out, and the day's list is whatever the
# feeds happened to emit.
SELECTIVITY_RATIO = 2

# Below this many days the numbers are weather, not climate. A weekend alone
# moves daily arrivals by more than any threshold here.
MIN_SOAK_DAYS = 14


def read_records(log_dir: Path, topic: str = "feed") -> dict[str, list[dict]]:
    """Every day's fetched records, keyed by the date in the filename.

    The filename date, not a field inside the row: the sidecar belongs to the
    night it was fetched on, and that is the arrival date the gate is about.
    """
    out: dict[str, list[dict]] = {}
    for path in sorted(log_dir.glob(f"records-*-{topic}.jsonl")):
        date = path.name[len("records-"):-len(f"-{topic}.jsonl")]
        rows = []
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except ValueError:
                continue
        out[date] = rows
    return out


def daily_arrivals(by_date: dict[str, list[dict]]) -> list[dict]:
    """Per day: what arrived, what was new, and what was worth keeping.

    "New" is cumulative against every earlier day, not against yesterday. A feed
    that re-emits the same item for five days would otherwise look like five
    days of supply.
    """
    seen: set[str] = set()
    rows = []
    for i, date in enumerate(sorted(by_date)):
        records = by_date[date]
        # Marked seen as we go, not in a batch at the end. Doing it at the end
        # counts an item fetched twice in one morning — the same story from two
        # feeds — as two arrivals, and the pool's own ingest counts it once.
        # That one-item disagreement is what the differential assertion in
        # scripts/tests/test-feed-gate.sh caught.
        new = []
        for r in records:
            rid = r.get("id")
            if not rid or rid in seen:
                continue
            seen.add(rid)
            new.append(r)
        admitted = [r for r in new if qualifies(r)]
        rows.append({
            "date": date,
            "fetched": len(records),
            "new": len(new),
            "admitted": len(admitted),
            "sources": len({r.get("source", "") for r in admitted if r.get("source")}),
            "by_source": Counter(r.get("source", "") for r in admitted),
            # On the first day nothing has been seen before, so every item every
            # feed is holding counts as an arrival — a backfill of whatever
            # window the sources publish, not a day's supply. Measured live: 65
            # admitted on day one against 2 on day two, which dragged the mean to
            # 33.5 and turned a failing supply into a passing gate. That is
            # exactly the trap this file was written against, arriving in a new
            # disguise, so the cold start is excluded from every statistic.
            "cold_start": i == 0,
        })
    return rows


def _median(xs: list[int]) -> float:
    if not xs:
        return 0.0
    s = sorted(xs)
    mid = len(s) // 2
    return float(s[mid]) if len(s) % 2 else (s[mid - 1] + s[mid]) / 2


def evaluate(rows: list[dict], cap: int = DAILY_CAP,
             ratio: int = SELECTIVITY_RATIO,
             min_days: int = MIN_SOAK_DAYS) -> dict:
    """The three tests, and a verdict that can be FAIL.

    A soak shorter than `min_days` returns INCONCLUSIVE rather than a verdict.
    That is not a third pass grade — it is the honest answer, and calling a
    two-day sample a PASS is how a gate stops being one.
    """
    measured = [r for r in rows if not r.get("cold_start")]
    days = len(measured)
    admitted = [r["admitted"] for r in measured]
    mean_admitted = sum(admitted) / days if days else 0.0
    # Reported beside the mean so a skew is visible rather than averaged away.
    # A single backfill day is what a mean cannot survive and a median can.
    median_admitted = _median(admitted)
    median_sources = _median([r["sources"] for r in measured])

    totals: Counter = Counter()
    for r in measured:
        totals.update(r["by_source"])
    total_admitted = sum(totals.values())
    top_source, top_n = (totals.most_common(1) or [("", 0)])[0]
    top_share = top_n / total_admitted if total_admitted else 0.0

    tests = {
        "sustainability": {
            "value": round(mean_admitted, 2),
            "threshold": cap,
            "pass": mean_admitted >= cap,
            "why": f"mean new qualifying items per day must reach the {cap} "
                   f"published per day, or the pool drains",
        },
        "selectivity": {
            "value": round(mean_admitted, 2),
            "threshold": cap * ratio,
            "pass": mean_admitted >= cap * ratio,
            "why": f"{ratio}:1 arrivals per published card, or the ranking "
                   f"chooses nothing and the day's list is whatever arrived",
            "waivable": True,
        },
        "diversity_feasibility": {
            "value": median_sources,
            "threshold": cap,
            "pass": median_sources >= cap,
            "why": f"FINAL_PER_SOURCE is {FINAL_PER_SOURCE}, so {cap} cards from "
                   f"fewer than {cap} sources is impossible, not merely thin",
        },
    }

    if days < min_days:
        verdict = "INCONCLUSIVE"
    elif all(t["pass"] for t in tests.values()):
        verdict = "PASS"
    else:
        verdict = "FAIL"

    return {
        "days": days,
        "cold_start_days": len(rows) - days,
        "min_days": min_days,
        "verdict": verdict,
        "tests": tests,
        "mean_admitted": round(mean_admitted, 2),
        "median_admitted": median_admitted,
        "median_sources": median_sources,
        "top_source": top_source,
        "top_source_share": round(top_share, 3),
        "total_admitted": total_admitted,
    }


def report_lines(rows: list[dict], result: dict) -> list[str]:
    out = ["", f"{'date':12} {'fetched':>8} {'new':>5} {'admitted':>9} {'sources':>8}",
           "-" * 60]
    for r in rows:
        tail = "   cold start — excluded" if r.get("cold_start") else ""
        out.append(f"{r['date']:12} {r['fetched']:>8} {r['new']:>5} "
                   f"{r['admitted']:>9} {r['sources']:>8}{tail}")
    out += ["-" * 60, ""]
    if result["mean_admitted"] and result["median_admitted"]:
        out.append(f"  admissions per day: mean {result['mean_admitted']}, "
                   f"median {result['median_admitted']}")
        out.append("")
    for name, t in result["tests"].items():
        mark = "pass" if t["pass"] else "FAIL"
        waiv = "  (waivable)" if t.get("waivable") else ""
        out.append(f"  [{mark}] {name}: {t['value']} vs {t['threshold']} required{waiv}")
        out.append(f"         {t['why']}")
    out.append("")
    if result["total_admitted"]:
        out.append(f"  heaviest source: {result['top_source']} "
                   f"({result['top_source_share']:.0%} of admissions)")
    if result["verdict"] == "INCONCLUSIVE":
        out.append(f"  VERDICT: INCONCLUSIVE — {result['days']} day(s) measured, "
                   f"{result['min_days']} needed. A weekend moves these numbers "
                   f"more than any threshold here.")
    else:
        out.append(f"  VERDICT: {result['verdict']}")
    out.append("")
    return out


def _main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description="S2.0 — measure the launch gate")
    ap.add_argument("--logs", default="scripts/logs",
                    help="where the record sidecars live (gitignored, single-machine)")
    ap.add_argument("--topic", default="feed")
    ap.add_argument("--cap", type=int, default=DAILY_CAP)
    ap.add_argument("--min-days", type=int, default=MIN_SOAK_DAYS)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)

    by_date = read_records(Path(a.logs), a.topic)
    if not by_date:
        print(f"no record sidecars in {a.logs} — nothing to measure.")
        return 1
    rows = daily_arrivals(by_date)
    result = evaluate(rows, cap=a.cap, min_days=a.min_days)
    if a.json:
        print(json.dumps({"days": rows, "result": result}, default=int, indent=2))
    else:
        print("\n".join(report_lines(rows, result)))
    # INCONCLUSIVE is not a pass. Exiting 0 on it would let a caller treat two
    # days of data as a green light.
    return 0 if result["verdict"] == "PASS" else 1


if __name__ == "__main__":
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    raise SystemExit(_main())
