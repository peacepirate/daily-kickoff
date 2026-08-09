#!/bin/bash
# E6 — deterministic selection over the pool.
#
# S6.5 is the keystone: same pool in, same shortlist out, every time. Everything
# downstream assumes it, and the assumption is only worth what it is tested at,
# so determinism here is checked against shuffled input rather than by running
# the same list twice — which would pass on any implementation that is merely
# repeatable, including one that depends on insertion order.
#
# The other half is the veto (S6.6). Code has the last word over whatever the
# model returns, and every way a returned set can be wrong is exercised:
# hallucinated ids, repeats, concentration, and overrun.
#
# No network, no LLM, no writes outside $TMPDIR, no git writes anywhere.
#
#   bash scripts/tests/test-feed-select.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

if ! "$PYBIN" -c 'import yaml' 2>/dev/null; then
  printf "  \033[33mskip\033[0m  pyyaml unavailable in %s — run any kickoff command once\n" "$PYBIN"
  exit 0
fi

"$PYBIN" - "$REPO_DIR" <<'PY'
import sys, random, json
from pathlib import Path
from datetime import date as Date, timedelta

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "scripts" / "lib"))
import feed_select as fs

FAIL = 0
COUNT = 0
def ok(m):
    global COUNT; COUNT += 1; print(f"  \033[32mok\033[0m    {m}")
def bad(m):
    global FAIL, COUNT; COUNT += 1; FAIL = 1; print(f"  \033[31mFAIL\033[0m  {m}")
def chk(label, got, want):
    ok(label) if got == want else bad(f"{label} (got {got!r}, wanted {want!r})")

TODAY = Date(2026, 8, 8)
LONG = "s" * 200          # clears MIN_SUMMARY_SELECT
SHORT = "s" * 90          # clears pool admission (80) but not selection (120)

def row(i, source="Src", host="example.com", summary=LONG, seen=TODAY,
        title=None, date="2026-08-08"):
    return {"id": f"{i:012d}", "source": source, "url": f"https://{host}/{i}",
            "title": title or f"A headline number {i} that is long enough",
            "summary": summary, "date": date, "first_seen": seen.isoformat()}

TIERS = {"T1": 1, "T2": 2, "T3": 3}

print("── eligibility is a closed vocabulary ────────────────────────────────────")
pool = [
    row(1),                                        # fine
    row(2, summary=SHORT),                         # thin
    row(3, seen=TODAY - timedelta(days=30)),       # stale
    row(4),                                        # published, below
    {**row(5), "url": ""},                         # no url
    {**row(6), "title": "  "},                     # no title
]
rows, st = fs.eligible(pool, TODAY, {f"{4:012d}"})
chk("only the clean row survives", [r["id"] for r in rows], [f"{1:012d}"])
chk("a thin summary is counted as thin", st["thin_summary"], 1)
chk("an aged-out row is counted as stale", st["stale"], 1)
chk("a ledger hit is counted as published", st["published"], 1)
chk("a row with no url is counted", st["no_url"], 1)
chk("a row with no title is counted", st["no_title"], 1)
chk("every reason in the vocabulary is reported",
    sorted(k for k in st if k != "eligible"), sorted(fs.ELIGIBILITY_REASONS))

# The ledger is re-checked here even though ingest already excludes published
# ids. A pool that somehow holds a published row must not republish it.
rows, _ = fs.eligible([row(1)], TODAY, {f"{1:012d}"})
chk("a published id in the pool is still refused at selection", rows, [])

print("── ranking is a total order ──────────────────────────────────────────────")
# Ids run *against* the tier order on purpose. With ids ascending alongside the
# tiers, deleting tier from the sort key still produced the right answer — the
# id tiebreaker agreed with it by coincidence and the assertion proved nothing.
a = row(12, source="T1"); b = row(11, source="T2"); c = row(10, source="T3")
chk("tier orders before anything else",
    [r["source"] for r in fs.rank([c, b, a], TIERS)], ["T1", "T2", "T3"])
chk("tier beats the id tiebreaker, which here disagrees with it",
    [r["id"] for r in fs.rank([c, b, a], TIERS)], [a["id"], b["id"], c["id"]])

older = row(13, source="T1", seen=TODAY - timedelta(days=3))
newer = row(14, source="T1", seen=TODAY)
chk("within a tier, more recently seen comes first",
    [r["id"] for r in fs.rank([older, newer], TIERS)], [newer["id"], older["id"]])

# An unknown source must sort last and must NOT vanish: a config edit that
# renames a source cannot be allowed to delete candidates already captured.
unknown = row(15, source="NotInConfig")
ranked = fs.rank([unknown, a], TIERS)
chk("an unknown source ranks last", ranked[-1]["id"], unknown["id"])
chk("an unknown source is still present", len(ranked), 2)

print("── S6.5 determinism: same pool in, same shortlist out ────────────────────")
# Shuffled input, not a repeated run. A repeated run passes on any
# implementation that merely does the same thing twice, including one that
# depends on the order the pool happened to be written in.
big = [row(i, source=f"S{i % 9}", host=f"h{i % 11}.com") for i in range(60)]
base = fs.shortlist(big, set(), TODAY, {f"S{i}": (i % 3) + 1 for i in range(9)})
base_ids = [r["id"] for r in base["shortlist"]]
rng = random.Random(1)
same = True
for _ in range(25):
    shuffled = big[:]
    rng.shuffle(shuffled)
    got = fs.shortlist(shuffled, set(), TODAY, {f"S{i}": (i % 3) + 1 for i in range(9)})
    if [r["id"] for r in got["shortlist"]] != base_ids:
        same = False
        break
chk("25 shuffles of one pool produce one shortlist", same, True)
chk("the ranked id list is also stable",
    fs.shortlist(list(reversed(big)), set(), TODAY,
                 {f"S{i}": (i % 3) + 1 for i in range(9)})["ranked_ids"],
    base["ranked_ids"])
# Ties must be broken by something stable. Identical rows but for the id is the
# case that catches an implementation relying on Python's sort being stable
# over whatever order the caller supplied.
twins = [row(i, source="T1") for i in (30, 31, 32)]
chk("identical rows are ordered by id, not by arrival",
    [r["id"] for r in fs.rank(list(reversed(twins)), TIERS)],
    [r["id"] for r in twins])

print("── S6.2 diversity caps ───────────────────────────────────────────────────")
same_source = [row(i, source="T1", host=f"h{i}.com") for i in range(20, 28)]
chosen, dstats = fs.diversify(fs.rank(same_source, TIERS), 7, per_source=1, per_domain=2)
chk("one source cannot fill the day", len(chosen), 1)
chk("the rest are counted as source-capped", dstats["source_capped"], 7)

same_domain = [row(i, source=f"S{i}", host="one.example.com") for i in range(30, 38)]
chosen, dstats = fs.diversify(fs.rank(same_domain, {}), 7, per_source=1, per_domain=2)
chk("one domain cannot fill the day", len(chosen), 2)
chk("subdomains collapse onto the registrable domain", fs.domain_of("https://blog.a.com/x"), "a.com")
chk("www is dropped", fs.domain_of("https://www.a.com/x"), "a.com")

print("── S6.6 the veto: code has the last word ─────────────────────────────────")
offered = [row(i, source=f"S{i}", host=f"h{i}.com") for i in range(40, 52)]
ids = [r["id"] for r in offered]

kept, dropped = fs.veto(ids[:5], offered)
chk("a clean set of five passes untouched", [r["id"] for r in kept], ids[:5])
chk("nothing is dropped from a clean set", any(dropped.values()), False)

kept, dropped = fs.veto(["ffffffffffff"] + ids[:3], offered)
chk("an id that was never offered is dropped", dropped["not_offered"], ["ffffffffffff"])
chk("the rest of the set survives it", len(kept), 3)

kept, dropped = fs.veto([ids[0], ids[0], ids[1]], offered)
chk("a repeated id is dropped once", dropped["duplicate"], [ids[0]])
chk("the first occurrence is kept", [r["id"] for r in kept], [ids[0], ids[1]])

kept, dropped = fs.veto(ids[:10], offered)
chk("the ceiling is enforced", len(kept), fs.DAILY_CAP)
chk("the overrun is counted", len(dropped["over_cap"]), 3)

# The shortlist is diversified loosely so the model sees range. That is not a
# licence to hand back a concentrated set, so the strict caps are re-applied.
crowd = [row(i, source="OneSource", host=f"h{i}.com") for i in range(60, 66)]
kept, dropped = fs.veto([r["id"] for r in crowd], crowd)
chk("a returned set from one source is cut to the strict cap", len(kept), 1)
chk("the rest are counted as source-capped", len(dropped["source_capped"]), 5)

crowd = [row(i, source=f"S{i}", host="one.com") for i in range(70, 76)]
kept, dropped = fs.veto([r["id"] for r in crowd], crowd)
chk("a returned set from one domain is cut to the strict cap", len(kept), 2)

# Relevance ordering is the model's judgement and code has nothing to replace
# it with, so a legal set must come back in the order it was returned.
back = [ids[4], ids[0], ids[2]]
kept, _ = fs.veto(back, offered)
chk("the model's ordering is preserved", [r["id"] for r in kept], back)

print("── S6.7 near-duplicate advisory ──────────────────────────────────────────")
# Distinct sources and hosts, because that is what the case actually is: two
# publications writing up one announcement. Sharing a source here would let the
# diversity cap, not the clustering, decide the result.
dupes = [
    row(80, source="A", host="a.com",
        title="OpenAI announces a new reasoning model for developers"),
    row(81, source="B", host="b.com",
        title="OpenAI announces new reasoning model aimed at developers"),
    row(82, source="C", host="c.com",
        title="Kubernetes 1.35 ships with improved scheduling controls"),
]
clusters = fs.near_duplicates(dupes)
chk("two write-ups of one story cluster", len(clusters), 1)
chk("the cluster holds both ids", clusters[0], sorted([dupes[0]["id"], dupes[1]["id"]]))
chk("an unrelated story is not clustered",
    any(dupes[2]["id"] in c for c in clusters), False)
# Advisory, not a filter. Token overlap cannot tell a rewrite from a follow-up,
# and dropping the follow-up is the more expensive mistake.
res = fs.shortlist(dupes, set(), TODAY, {})
chk("a flagged duplicate is still on the shortlist", len(res["shortlist"]), 3)
chk("clusters are reported alongside it", len(res["near_duplicates"]), 1)
chk("clusters are stable under input order",
    fs.near_duplicates(list(reversed(dupes))), clusters)

print("── S6.4 the thin-day vocabulary ──────────────────────────────────────────")
chk("a full day says so", fs.thin_reason(7, {"eligible": 20, "chosen": 20}), "full")
chk("a thin pool is named as a thin pool",
    fs.thin_reason(2, {"eligible": 2, "chosen": 2}), "pool_thin")
chk("a pool lost to the substance gate is named separately",
    fs.thin_reason(2, {"eligible": 2, "chosen": 2, "thin_summary": 9}), "substance_thin")
chk("a pool lost to staleness is named separately",
    fs.thin_reason(2, {"eligible": 2, "chosen": 2, "stale": 9}), "stale_thin")
chk("concentration is named as concentration",
    fs.thin_reason(3, {"eligible": 40, "chosen": 3}), "diversity_bound")
chk("a short model answer over a full shortlist is the model's call",
    fs.thin_reason(3, {"eligible": 40, "chosen": 20}), "model_thin")
chk("a set cut by the veto says so",
    fs.thin_reason(3, {"eligible": 40, "chosen": 20}, {"not_offered": ["x"]}), "vetoed_thin")
chk("every reason has words", sorted(fs.THIN_REASONS), sorted({
    "full", "pool_thin", "substance_thin", "stale_thin", "diversity_bound",
    "model_thin", "vetoed_thin"}))
# The first stage that lost the count is the one worth naming: fixing diversity
# would not have helped a day that was already thin at the pool.
chk("a day thin at the pool AND concentrated reports the pool",
    fs.thin_reason(1, {"eligible": 1, "chosen": 1}), "pool_thin")

print("── nothing pads to reach the ceiling ─────────────────────────────────────")
# Seven is a ceiling, never a target. The one behaviour that would destroy the
# product is reaching for it, so it is asserted directly.
three = [row(i, source=f"S{i}", host=f"h{i}.com") for i in range(90, 93)]
res = fs.shortlist(three, set(), TODAY, {})
chk("a three-item pool yields three, not seven", len(res["shortlist"]), 3)
kept, _ = fs.veto([r["id"] for r in three], three)
chk("the veto does not invent items either", len(kept), 3)
chk("an empty pool yields an empty shortlist",
    fs.shortlist([], set(), TODAY, {})["shortlist"], [])
chk("an empty pool does not crash the vocabulary",
    fs.thin_reason(0, fs.shortlist([], set(), TODAY, {})["stats"]), "pool_thin")

print("── the real config parses ────────────────────────────────────────────────")
tiers = fs.source_tiers(repo / "scripts" / "topics" / "feed.yaml")
chk("every configured source has a tier", len(tiers) >= 30, True)
chk("tiers are 1, 2 and 3", sorted(set(tiers.values())), [1, 2, 3])
chk("an unconfigured source falls to the unknown tier",
    fs.tier_of({"source": "Nope"}, tiers), fs.UNKNOWN_TIER)

print()
if FAIL == 0:
    print(f"\033[32mPASS\033[0m ({COUNT}) — feed selection tests passed")
else:
    print(f"\033[31mFAIL\033[0m — feed selection tests FAILED ({COUNT} assertions run)")
sys.exit(FAIL)
PY
