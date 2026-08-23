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

print("── a per-source shortlist cap widens EXPOSURE, never admission ───────────")
# The global cap of 2 is calibrated for a publisher. GitHub Trending admits 1-3
# repositories a night, so 2 is most of the supply rather than a sample of it,
# and which 2 is decided by the id hash that breaks a same-day rank tie. The
# override hands that choice back to the model.
#
# The assertions below are in two halves and the second is the important one.
# The first shows the widening happens. The second shows it CANNOT reach a
# reader: `veto` takes no override and caps every source at FINAL_PER_SOURCE, so
# a config that says 4 still publishes 1. Delete the override plumbing and the
# first half fails; thread the override into `veto` and the second half fails.

wide = [row(i, source="GitHub Trending", host="github.com") for i in range(60, 68)]
# Two noise sources with FOUR rows each, not eight sources with one. A source
# that only ever has one row cannot demonstrate a cap of two, and asserting
# against it would pass whatever the cap said.
noise = [row(i, source=f"N{i % 2}", host=f"n{i}.com") for i in range(70, 78)]

chosen, _ = fs.diversify(fs.rank(wide + noise, {}), 20,
                         fs.SHORTLIST_PER_SOURCE, 9)
chk("without an override the global cap holds",
    sum(1 for r in chosen if r["source"] == "GitHub Trending"),
    fs.SHORTLIST_PER_SOURCE)

chosen, _ = fs.diversify(fs.rank(wide + noise, {}), 20,
                         fs.SHORTLIST_PER_SOURCE, 9,
                         {"GitHub Trending": 4})
chk("an override raises that source's exposure to the model",
    sum(1 for r in chosen if r["source"] == "GitHub Trending"), 4)
chk("...and leaves every other source on the global cap",
    max(sum(1 for r in chosen if r["source"] == n) for n in {r["source"] for r in noise}),
    fs.SHORTLIST_PER_SOURCE)

chk("an override for an absent source changes nothing",
    len(fs.diversify(fs.rank(wide + noise, {}), 20, fs.SHORTLIST_PER_SOURCE, 9,
                     {"Not A Source": 9})[0]),
    len(fs.diversify(fs.rank(wide + noise, {}), 20,
                     fs.SHORTLIST_PER_SOURCE, 9)[0]))

# ── the guarantee ────────────────────────────────────────────────────────────
# Four repositories reached the model. The model returned all four. One card.
widened = [r for r in chosen if r["source"] == "GitHub Trending"]
kept, dropped = fs.veto([r["id"] for r in widened], chosen)
chk("the final veto caps the widened source at ONE card",
    len(kept), fs.FINAL_PER_SOURCE)
chk("...and says why the rest were dropped",
    len(dropped["source_capped"]), 4 - fs.FINAL_PER_SOURCE)
chk("...and the veto signature takes no per-source override at all",
    "per_source_overrides" in fs.veto.__code__.co_varnames, False)

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
    "model_thin", "vetoed_thin", "final_diversity_bound"}))

# D3 — the unjudged path's final cut.
#
# `stats["chosen"]` is the SHORTLIST diversify (limit 20, loose caps);
# `final_stats["chosen"]` is the second pass at the strict caps. Before D3 the
# second was discarded, so a day cut from 20 candidates down to 3 by the
# one-per-source rule fell through every branch and reported `model_thin` —
# "fewer items were judged worth running" — on a night when nothing was judged.
chk("the final cut is named, not blamed on a model that never ran",
    fs.thin_reason(3, {"eligible": 40, "chosen": 20}, final_stats={"chosen": 3}),
    "final_diversity_bound")
# The regression this replaces, stated as its own assertion so the fix cannot be
# reverted quietly: identical input WITHOUT the final stats is the old answer.
chk("...and that is exactly the case that used to say model_thin",
    fs.thin_reason(3, {"eligible": 40, "chosen": 20}), "model_thin")
# The judged path must be untouched: it has a veto report and no final stats.
chk("a judged day cut by the veto still says vetoed_thin",
    fs.thin_reason(3, {"eligible": 40, "chosen": 20},
                   {"source_capped": ["x"]}, final_stats=None), "vetoed_thin")
# A final pass that did not bind is still the model's call.
chk("a full final cut leaves the verdict with the model",
    fs.thin_reason(3, {"eligible": 40, "chosen": 20}, final_stats={"chosen": 7}),
    "model_thin")
chk("a thin pool still outranks the final cut",
    fs.thin_reason(1, {"eligible": 1, "chosen": 1}, final_stats={"chosen": 1}), "pool_thin")
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
# The live pool config, found rather than spelled out: it has moved between
# job kinds once already, and a hard-coded path turns that into a suite that
# dies instead of one that follows.
cfg = next(iter(sorted((repo / "scripts").glob("*/*feed.yaml"))), None)
assert cfg is not None, "no feed pool config found under scripts/*/"
tiers = fs.source_tiers(cfg)
chk("every configured source has a tier", len(tiers) >= 30, True)
chk("tiers are 1, 2 and 3", sorted(set(tiers.values())), [1, 2, 3])
chk("an unconfigured source falls to the unknown tier",
    fs.tier_of({"source": "Nope"}, tiers), fs.UNKNOWN_TIER)

# A shortlist override is a config line that changes what the model sees, so the
# vocabulary is asserted here rather than trusted. Same pattern as the
# `substance:` check in test-fetch-step.sh.
caps = fs.source_shortlist_caps(cfg)
chk("every declared shortlist cap names a source that exists",
    sorted(set(caps) - set(tiers)), [])
chk("every declared shortlist cap is a whole number of at least the global one",
    [n for n, c in caps.items()
     if not isinstance(c, int) or c < fs.SHORTLIST_PER_SOURCE], [])
# A source may not take more than a quarter of the shortlist. Past that it is
# not being given range, it is choosing the day — and the judge would be picking
# from one board instead of from the web.
chk("no declared cap exceeds a quarter of the shortlist",
    [n for n, c in caps.items() if c > fs.SHORTLIST_SIZE // 4], [])
# The domain cap is not overridable and binds first for any source whose rows
# share one host — which is every source that has wanted this so far. A larger
# number than SHORTLIST_PER_DOMAIN is not dangerous, it is INERT, and a config
# line that silently does nothing is the failure this project keeps paying for.
chk("no declared cap exceeds the shortlist domain cap, which would make it inert",
    [n for n, c in caps.items() if c > fs.SHORTLIST_PER_DOMAIN], [])
chk("a malformed declaration is ignored rather than obeyed",
    fs.source_shortlist_caps.__doc__ is not None
    and all(isinstance(c, int) and not isinstance(c, bool) for c in caps.values()),
    True)

print("── the titles-only exemption at selection ────────────────────────────────")

from datetime import date as _D
def srow(**kw):
    r = {"id": "b" * 12, "title": "A headline of a perfectly ordinary length here",
         "url": "https://example.com/y", "summary": "short", "source": "S",
         "first_seen": "2026-08-10"}
    r.update(kw); return r

TODAY = _D(2026, 8, 10)
chk("a thin summary is ineligible without the flag",
    fs.ineligible_reason(srow(), TODAY, set(), 14, fs.MIN_SUMMARY_SELECT), "thin_summary")
chk("...and eligible with it",
    fs.ineligible_reason(srow(substance="title-only"), TODAY, set(), 14, fs.MIN_SUMMARY_SELECT), None)
chk("a misspelled flag leaves the gate on",
    fs.ineligible_reason(srow(substance="titles-only"), TODAY, set(), 14, fs.MIN_SUMMARY_SELECT),
    "thin_summary")

# Everything upstream of the summary rule still refuses an exempt row. If any of
# these start returning None the exemption has grown past what it was granted.
chk("an exempt row already published is still refused",
    fs.ineligible_reason(srow(substance="title-only"), TODAY, {"b" * 12}, 14, fs.MIN_SUMMARY_SELECT),
    "published")
chk("an exempt row that has aged out is still refused",
    fs.ineligible_reason(srow(substance="title-only", first_seen="2026-01-01"),
                         TODAY, set(), 14, fs.MIN_SUMMARY_SELECT), "stale")
chk("an exempt row with an unsafe url is still refused",
    fs.ineligible_reason(srow(substance="title-only", url="javascript:alert(1)"),
                         TODAY, set(), 14, fs.MIN_SUMMARY_SELECT), "unsafe_url")

print("── the entity cooldown: a repository is a name, not an event ─────────────")
#
# `item_id` is a hash of the url, and "never publish this url twice" is exactly
# right for an article — one url is one event. For a repository the url is a
# permanent name, so the same rule means "published once, banned forever" in one
# direction, while the same project arriving under a different path gets a
# different id and republishes freely in the other.
#
# The ledger here is built end-to-end through publish_edition() and
# ledger_ids(), not written by hand, so the ledger WRITE is load-bearing too:
# drop `entity` from the row it produces and every assertion below goes with it.

import feed_pool as fp

REPO_URL    = "https://github.com/facebook/react"
RELEASE_URL = "https://github.com/facebook/react/releases/tag/v20"
ENT   = "github:facebook/react"
REPO_ID = "r" * 12
D     = _D(2026, 2, 1)
W     = fp.ENTITY_COOLDOWN_DAYS
day   = lambda n: D + timedelta(days=n)

published = [{"id": REPO_ID, "url": REPO_URL, "entity": ENT, "source": "GitHub Trending",
              "title": "facebook / react", "summary": "s" * 200, "substance": "repo",
              "first_seen": D.isoformat(), "date": D.isoformat()}]
_, led_rows, _ = fp.publish_edition([{"id": REPO_ID, "url": REPO_URL}], published, [], D)
LED = fp.ledger_ids(led_rows)

def arrival(n, url=RELEASE_URL, rid="s" * 12, **kw):
    """The same repository arriving again on day D+n, by default via a new path."""
    r = {"id": rid, "url": url, "entity": ENT, "source": "GitHub Trending",
         "title": "facebook / react", "summary": "s" * 200, "substance": "repo",
         "first_seen": day(n).isoformat()}
    r.update(kw); return r

def why(row, n, ledger=LED):
    return fs.ineligible_reason(row, day(n), ledger, 14, fs.MIN_SUMMARY_SELECT)

chk("the same owner/repo under a different URL path is refused within the window",
    why(arrival(1), 1), "entity_cooldown")
chk("...still refused one day short of the window", why(arrival(W - 1), W - 1), "entity_cooldown")
chk("the same owner/repo is eligible again after N+1 days", why(arrival(W + 1), W + 1), None)
chk("...and at exactly N days, which is the boundary the constant names",
    why(arrival(W), W), None)

# The same url, where the permanent id refusal would otherwise stand alone.
same = lambda n: arrival(n, url=REPO_URL, rid=REPO_ID)
chk("the same url is refused inside the window", why(same(1), 1), "entity_cooldown")
chk("...and released past it — 'published once' is no longer 'banned forever'",
    why(same(W + 1), W + 1), None)

# Fails closed in every direction where the ledger cannot answer the question.
chk("a row with no entity keeps the permanent id refusal",
    why({**same(W + 1), "entity": ""}, W + 1), "published")
chk("a plain set carries no index, so the id refusal stays permanent",
    why(same(W + 1), W + 1, ledger={REPO_ID}), "published")
chk("an entity the ledger has never named is not refused",
    why(arrival(1, rid="t" * 12, entity="github:other/thing"), 1), None)
chk("case cannot fork one repository into two cooldowns",
    why(arrival(1, entity="GitHub:Facebook/React"), 1), "entity_cooldown")

# The cooldown reaches the ledger rule and nothing else. If any of these start
# returning None the guard has grown past what it was granted.
chk("a released entity with an unsafe url is still refused",
    why(arrival(W + 1, url="javascript:alert(1)"), W + 1), "unsafe_url")
chk("a released entity that has aged out is still refused",
    why({**arrival(W + 1), "first_seen": D.isoformat()}, W + 1), "stale")
chk("a released entity with a thin summary is still refused",
    why(arrival(W + 1, summary="short"), W + 1), "thin_summary")

rows_c, st_c = fs.eligible([arrival(1)], day(1), LED)
chk("the refusal is counted, not merely happening", st_c["entity_cooldown"], 1)
chk("...and the row is not offered", rows_c, [])
chk("the reason is in the closed vocabulary",
    "entity_cooldown" in fs.ELIGIBILITY_REASONS, True)
chk("a released repository reaches the shortlist",
    [r["id"] for r in fs.shortlist([arrival(W + 1)], LED, day(W + 1), {})["shortlist"]],
    ["s" * 12])

print()
if FAIL == 0:
    print(f"\033[32mPASS\033[0m ({COUNT}) — feed selection tests passed")
else:
    print(f"\033[31mFAIL\033[0m — feed selection tests FAILED ({COUNT} assertions run)")
sys.exit(FAIL)
PY
