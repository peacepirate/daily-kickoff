#!/bin/bash
# S2.0 — proving the launch gate can fail.
#
# The gate this replaces could not. It counted qualifying items sitting in the
# pool against a round threshold, and the same filter already cleared that
# threshold on the day it was written, before any work was done. A gate met by
# the status quo measures nothing.
#
# The replacement measures arrivals rather than inventory, and the first thing
# it did on real data was reproduce the same trap in a new disguise: on day one
# nothing has been seen before, so every item every feed is holding counts as an
# arrival. Sixty-five admitted on day one against two on day two, mean 33.5, and
# a failing supply reads as a comfortable pass. The cold-start exclusion is the
# single most load-bearing line in that module and it has its own tests here.
#
# No network, no writes outside a temp directory.
#
#   bash scripts/tests/test-feed-gate.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

"$PYBIN" - "$REPO_DIR" <<'PY'
import json, sys, tempfile
from datetime import date as Date
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "scripts" / "lib"))
import feed_gate as fg
import feed_pool as fp

FAIL = 0; COUNT = 0
def ok(m):
    global COUNT; COUNT += 1; print(f"  \033[32mok\033[0m    {m}")
def bad(m):
    global FAIL, COUNT; COUNT += 1; FAIL = 1; print(f"  \033[31mFAIL\033[0m  {m}")
def chk(label, got, want):
    ok(label) if got == want else bad(f"{label} (got {got!r}, wanted {want!r})")


def rec(i, source="S1"):
    """A record that passes the pool's quality bar."""
    return {"id": f"{i:012x}", "source": source, "title": f"A title long enough {i}",
            "url": f"https://example.com/{i}",
            "summary": "A publisher summary comfortably past the eighty-character "
                       "minimum so that it qualifies for the pool.",
            "date": "2026-08-09"}


def days(spec):
    """spec: {date: [records]} -> the arrival table."""
    return fg.daily_arrivals(spec)


print("── the cold start is excluded, or the gate cannot fail ────────────────────")
# The live shape: a backfill on day one, then real daily supply.
spec = {"2026-08-01": [rec(i) for i in range(65)],
        "2026-08-02": [rec(100 + i) for i in range(2)]}
rows = days(spec)
chk("day one is flagged as a cold start", rows[0]["cold_start"], True)
chk("later days are not", rows[1]["cold_start"], False)
res = fg.evaluate(rows, min_days=1)
chk("the backfill is excluded from the mean", res["mean_admitted"], 2.0)
chk("...and the day count is of measured days only", res["days"], 1)
chk("...and the excluded days are reported, not silently dropped",
    res["cold_start_days"], 1)
# The assertion that matters: without the exclusion this is a PASS.
chk("supply of 2 against a cap of 7 FAILS", res["tests"]["sustainability"]["pass"], False)
chk("...and the verdict is FAIL, not a soft grade", res["verdict"], "FAIL")

# Proving the trap was real rather than theoretical.
naive = [dict(r, cold_start=False) for r in rows]
chk("including the cold start would have passed it",
    fg.evaluate(naive, min_days=1)["tests"]["sustainability"]["pass"], True)

print("── newness is cumulative, not day-over-day ───────────────────────────────")
# A feed that re-emits the same item every day is not a supply of one a day.
same = [rec(1), rec(2)]
rows = days({"2026-08-01": same, "2026-08-02": same, "2026-08-03": same})
chk("a repeated item is new exactly once", [r["new"] for r in rows], [2, 0, 0])
chk("...and admitted exactly once", [r["admitted"] for r in rows], [2, 0, 0])

print("── the three tests ───────────────────────────────────────────────────────")
def synth(n_per_day, n_sources, n_days=20):
    spec = {}
    k = 0
    for d in range(n_days + 1):          # +1 for the cold start day
        batch = []
        for i in range(n_per_day):
            batch.append(rec(k, source=f"S{i % n_sources}"))
            k += 1
        spec[f"2026-09-{d + 1:02d}"] = batch
    return fg.evaluate(days(spec))

good = synth(20, 10)
chk("ample supply from many sources PASSES", good["verdict"], "PASS")
chk("...sustainability", good["tests"]["sustainability"]["pass"], True)
chk("...selectivity", good["tests"]["selectivity"]["pass"], True)
chk("...diversity", good["tests"]["diversity_feasibility"]["pass"], True)

thin = synth(4, 10)
chk("supply under the daily cap fails sustainability",
    thin["tests"]["sustainability"]["pass"], False)
chk("...and the whole gate", thin["verdict"], "FAIL")

# The case the old gate could not express: plenty of items, too few sources.
# FINAL_PER_SOURCE is 1, so this cannot produce seven cards however big it looks.
narrow = synth(40, 3)
chk("plenty of items from three sources still fails diversity",
    narrow["tests"]["diversity_feasibility"]["pass"], False)
chk("...even though supply is abundant",
    narrow["tests"]["sustainability"]["pass"], True)
chk("...and the gate fails overall", narrow["verdict"], "FAIL")

# Enough to sustain, not enough to choose from.
publish_everything = synth(8, 10)
chk("8 arrivals for 7 cards sustains but is not selection",
    (publish_everything["tests"]["sustainability"]["pass"],
     publish_everything["tests"]["selectivity"]["pass"]), (True, False))

print("── the waiver rule is in the data, not only in the prose ─────────────────")
# Waiving sustainability or diversity does not lower a standard — it asserts
# something arithmetically false about what the product can do.
t = good["tests"]
chk("selectivity is marked waivable", t["selectivity"].get("waivable"), True)
chk("sustainability is not", t["sustainability"].get("waivable"), None)
chk("diversity is not", t["diversity_feasibility"].get("waivable"), None)

print("── a short soak is INCONCLUSIVE, which is not a pass ─────────────────────")
short = fg.evaluate(days({"2026-08-01": [rec(i) for i in range(50)],
                          "2026-08-02": [rec(200 + i) for i in range(50)]}))
chk("two days is inconclusive however good the numbers look", short["verdict"], "INCONCLUSIVE")
chk("...and it says how many days it needs", short["min_days"], fg.MIN_SOAK_DAYS)

print("── the exit code carries the verdict ─────────────────────────────────────")
import contextlib, io

def run_cli(*args):
    """The CLI prints a full report; only its exit code is under test here."""
    with contextlib.redirect_stdout(io.StringIO()):
        return fg._main(list(args))

with tempfile.TemporaryDirectory() as tmp:
    logs = Path(tmp)
    chk("no sidecars at all exits non-zero", run_cli("--logs", str(logs)), 1)
    for d, n in (("2026-08-01", 50), ("2026-08-02", 2)):
        (logs / f"records-{d}-feed.jsonl").write_text(
            "\n".join(json.dumps(rec(hash((d, i)) % 10**11)) for i in range(n)) + "\n")
    chk("an inconclusive soak exits non-zero", run_cli("--logs", str(logs)), 1)
    chk("...and so does a failing one",
        run_cli("--logs", str(logs), "--min-days", "1"), 1)

print("── the gate measures the same bar the pool does ──────────────────────────")
# Two implementations of "is this item worth keeping" would drift, and the gate
# would then be measuring a product that does not exist. It imports the pool's
# own predicate rather than restating it, and this is what proves that: run the
# real ingest over the real records and require the same count.
real = repo / "scripts" / "logs" / "records-2026-08-08-feed.jsonl"
if real.exists():
    records = [json.loads(l) for l in real.read_text().splitlines() if l.strip()]
    _, stats = fp.ingest(records, [], set(), Date(2026, 8, 8))
    gate_admitted = days({"2026-08-08": records})[0]["admitted"]
    # ingest also drops blocked terms and unsafe urls; with no blocklist passed
    # the remaining difference is batch duplicates, which the gate counts once
    # via its own id set.
    chk("the gate's admission count matches the pool's",
        gate_admitted, stats["added"])
else:
    ok("skipped the corpus check — no stored sidecar on this machine")

print()
if FAIL == 0:
    print(f"\033[32mPASS\033[0m ({COUNT}) — launch gate tests passed")
else:
    print(f"\033[31mFAIL\033[0m — launch gate tests FAILED ({COUNT} assertions run)")
sys.exit(FAIL)
PY
