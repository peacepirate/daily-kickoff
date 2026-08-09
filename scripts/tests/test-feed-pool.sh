#!/bin/bash
# E5 — the candidate pool and the published ledger, scripts/lib/feed_pool.py.
#
# The failure this exists to prevent is measured: 52% of urls arrive on more
# than one day, and the worst appeared on 32 of 34 days sampled. A feed built on
# these bundles with no memory republishes the same item nightly.
#
# The keystone is the 30-day repeat below. It replays a REAL record sidecar —
# the 74 items an actual feed fetch returned — once a day for thirty days, and
# asserts the pool stops growing after the first. That is the exact shape of the
# bug, run against the exact data that exhibits it.
#
# No network, no LLM, no writes outside $TMPDIR, no git writes anywhere.
#
#   bash scripts/tests/test-feed-pool.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

"$PYBIN" - "$REPO_DIR" <<'PY'
import sys, json, glob, tempfile, os
from datetime import date, timedelta
sys.path.insert(0, sys.argv[1] + "/scripts/lib")
import feed_pool as fp
from bundle import item_id

FAIL = 0; COUNT = 0
def ok(m):
    global COUNT; COUNT += 1; print(f"  \033[32mok\033[0m    {m}")
def bad(m):
    global FAIL, COUNT; COUNT += 1; FAIL = 1; print(f"  \033[31mFAIL\033[0m  {m}")
def chk(label, got, want):
    ok(label) if got == want else bad(f"{label} (got {got!r}, wanted {want!r})")

D0 = date(2026, 8, 8)
def rec(i, summary=None, title=None, url=None, source="Src"):
    u = url or f"https://example.com/post-{i}"
    return {"id": item_id(u), "source": source, "url": u,
            "title": title if title is not None else f"A headline number {i} long enough",
            "date": D0.isoformat(),
            "summary": summary if summary is not None else "s" * 120}

print("── the quality bar ───────────────────────────────────────────────────────")
chk("a full record qualifies", fp.qualifies(rec(1)), True)
chk("a short summary does not", fp.qualifies(rec(2, summary="too short")), False)
chk("a summary exactly at the bar does", fp.qualifies(rec(3, summary="s" * fp.MIN_SUMMARY)), True)
chk("a one-word title does not", fp.qualifies(rec(4, title="Nav")), False)
chk("a record with no id does not", fp.qualifies({"title": "x" * 40, "summary": "s" * 120}), False)

print("── the blocklist is an admission rule ────────────────────────────────────")
TERMS = ["Zorbex Dynamics"]
chk("a clean record is admitted", fp.contains_blocked(rec(5), TERMS), False)
chk("a blocked term in the summary is caught",
    fp.contains_blocked(rec(6, summary="news about Zorbex Dynamics " + "s" * 100), TERMS), True)
chk("a blocked term in the title is caught",
    fp.contains_blocked(rec(7, title="Zorbex Dynamics ships something"), TERMS), True)
chk("a blocked term in the url is caught",
    fp.contains_blocked(rec(8, url="https://zorbexdynamics.com/x"), TERMS), True)
chk("spaces-removed matching works", fp.contains_blocked(rec(9, title="ZorbexDynamics again"), TERMS), True)
chk("case does not matter", fp.contains_blocked(rec(10, title="zorbex dynamics again"), TERMS), True)

print("── three dedup horizons ──────────────────────────────────────────────────")
batch = [rec(1), rec(1), rec(2)]
pool, st = fp.ingest(batch, [], set(), D0, TERMS)
chk("the same item twice in one batch is counted once", st["dup_batch"], 1)
chk("two distinct items are added", st["added"], 2)

pool2, st2 = fp.ingest([rec(1), rec(3)], pool, set(), D0 + timedelta(days=1), TERMS)
chk("an item already in the pool is not re-added", st2["dup_pool"], 1)
chk("a genuinely new item still is", st2["added"], 1)

led = {item_id("https://example.com/post-1")}
_, st3 = fp.ingest([rec(1)], [], led, D0, TERMS)
chk("an item already published never returns", st3["dup_ledger"], 1)
chk("and it is not added", st3["added"], 0)

print("── first_seen is set once, never refreshed ───────────────────────────────")
p, _ = fp.ingest([rec(1)], [], set(), D0, TERMS)
p, _ = fp.ingest([rec(1)], p, set(), D0 + timedelta(days=5), TERMS)
chk("re-arrival does not reset first_seen — a daily repeater must still age out",
    p[0]["first_seen"], D0.isoformat())

print("── staleness and cap ─────────────────────────────────────────────────────")
p, _ = fp.ingest([rec(1)], [], set(), D0, TERMS)
kept, retired, pst = fp.prune(p, D0 + timedelta(days=fp.MAX_AGE_DAYS + 1))
chk("a candidate past the age bound expires", pst["expired"], 1)
chk("expiry produces a ledger tombstone, not a silent delete", len(retired), 1)
chk("the tombstone says why", retired[0]["status"], "expired")
kept, _, pst = fp.prune(p, D0 + timedelta(days=fp.MAX_AGE_DAYS - 1))
chk("a candidate inside the bound survives", len(kept), 1)

big, _ = fp.ingest([rec(i) for i in range(fp.POOL_CAP + 50)], [], set(), D0, TERMS)
kept, _, pst = fp.prune(big, D0)
chk("the pool is capped", len(kept), fp.POOL_CAP)
chk("the overflow is reported, not silent", pst["over_cap"], 50)

print("── publishing moves items pool -> ledger ─────────────────────────────────")
p, _ = fp.ingest([rec(1), rec(2), rec(3)], [], set(), D0, TERMS)
ids = [p[0]["id"]]
p2, rows = fp.mark_published(ids, p, D0)
chk("the published item leaves the pool", len(p2), 2)
chk("one ledger row is produced", len(rows), 1)
chk("the ledger row carries the url, not just the hash", bool(rows[0]["url"]), True)
_, st4 = fp.ingest([rec(1)], p2, fp.ledger_ids(rows), D0 + timedelta(days=1), TERMS)
chk("and it cannot re-enter the pool afterwards", st4["dup_ledger"], 1)

print("── ledger rebuild from published output ──────────────────────────────────")
rebuilt = fp.rebuild_ledger([{"id": "aaa", "url": "u1", "published": "2026-08-01"},
                             {"id": "aaa", "url": "u1", "published": "2026-08-01"},
                             {"id": "bbb", "url": "u2"}], "2026-08-08")
chk("rebuild dedupes", len(rebuilt), 2)
chk("rebuild falls back to a supplied date", rebuilt[1]["published"], "2026-08-08")

print("── a malformed line cannot make the ledger unreadable ────────────────────")
tmp = tempfile.mkdtemp()
lp = os.path.join(tmp, "ledger.jsonl")
with open(lp, "w") as fh:
    fh.write('{"id": "good1"}\n')
    fh.write('this is not json\n')
    fh.write('\n')
    fh.write('{"id": "good2"}\n')
chk("well-formed rows survive a corrupt neighbour", len(fp.read_jsonl(lp)), 2)
chk("a missing file reads as empty, not an error", fp.read_jsonl(os.path.join(tmp, "nope.jsonl")), [])

print("── THE KEYSTONE: 30 days of the same real bundle ─────────────────────────")
recs = sorted(glob.glob(sys.argv[1] + "/scripts/logs/records-*-feed.jsonl"))
if not recs:
    print("  \033[33mskip\033[0m  no record sidecar in scripts/logs/ (gitignored, single-machine)")
else:
    real = fp.read_jsonl(recs[-1])
    led = set()
    pool, first = fp.ingest(real, [], led, D0, TERMS)
    day1 = len(pool)
    chk("day 1 admits items from the real bundle", day1 > 0, True)
    added_after = 0
    for n in range(1, 30):
        pool, st = fp.ingest(real, pool, led, D0 + timedelta(days=n), TERMS)
        added_after += st["added"]
        pool, retired_n, _ = fp.prune(pool, D0 + timedelta(days=n))
        led |= {r["id"] for r in retired_n}
    chk("29 further days of the identical bundle add NOTHING", added_after, 0)
    # The pool shrinks rather than holding: items age out at MAX_AGE_DAYS and,
    # because first_seen is never refreshed, a source re-serving the same story
    # forever cannot keep it alive forever.
    chk("and the pool does not grow", len(pool) <= day1, True)
    print(f"         {len(real)} real records, {day1} admitted on day 1, "
          f"{len(pool)} left after 30 days of repeats")

print()
if FAIL == 0:
    print(f"\033[32mPASS\033[0m ({COUNT}) — feed pool tests passed")
else:
    print(f"\033[31mFAIL\033[0m — feed pool tests FAILED ({COUNT} assertions run)")
sys.exit(FAIL)
PY
