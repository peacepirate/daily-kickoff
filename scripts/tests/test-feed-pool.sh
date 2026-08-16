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

print("── publish_edition: the write side that closes the loop ──────────────────")
#
# The read side (feed_edition.py excluding ledger_ids from selection) has always
# existed. Nothing wrote the ledger, so the exclusion set was permanently empty
# and two of the first three editions shared three items. These assertions are
# the ones that would have failed on 2026-08-11.

pool0, _ = fp.ingest([rec(1), rec(2), rec(3), rec(4)], [], set(), D0, TERMS)
ed = [{"id": pool0[0]["id"], "url": pool0[0]["url"]},
      {"id": pool0[1]["id"], "url": pool0[1]["url"]}]

p3, rows3, st5 = fp.publish_edition(ed, pool0, [], D0)
chk("one ledger row per edition item", len(rows3), 2)
chk("...and they leave the pool", len(p3), 2)
chk("...reported as marked", st5["marked"], 2)
chk("the row carries the url, not just the hash", bool(rows3[0]["url"]), True)
chk("the row is marked published", rows3[0]["status"], "published")
chk("the row carries the edition's date", rows3[0]["published"], D0.isoformat())

# Idempotency. append_jsonl never rewrites, so a second run for the same date
# would otherwise append a second set of rows. A retried night, a hand re-run
# after a failed push, and the replay path all reach this.
p4, rows4, st6 = fp.publish_edition(ed, p3, rows3, D0)
chk("publishing the same edition twice adds no rows", len(rows4), 0)
chk("...and says so rather than staying silent", st6["already"], 2)
chk("...and does not disturb the pool", len(p4), 2)

# The failure mode mark_published() has: an item pruned between ingest and
# publish produces no row when rows are built from the pool, and an item with no
# row is eligible again tomorrow.
_, rows5, _ = fp.publish_edition([{"id": "never-pooled", "url": "https://example.com/x"}],
                                 [], [], D0)
chk("an item absent from the pool still gets a ledger row", len(rows5), 1)

# The end-to-end assertion: the loop is actually closed.
_, st7 = fp.ingest([rec(1)], p3, fp.ledger_ids(rows3), D0 + timedelta(days=1), TERMS)
chk("a published item cannot re-enter the pool", st7["dup_ledger"], 1)

# An id repeated inside one edition must not produce two rows for one item.
dupe = [{"id": "same", "url": "u"}, {"id": "same", "url": "u"}]
_, rows6, st8 = fp.publish_edition(dupe, [], [], D0)
chk("an id repeated within one edition yields one row", len(rows6), 1)
chk("...counted, not dropped silently", st8["already"], 1)

# Mutation test. An idempotency check that never fires is the shape of guard
# this project keeps rediscovering, so prove it can fail: with the ledger hidden
# from it, the same call must produce rows again.
_, rows_mut, _ = fp.publish_edition(ed, p3, [], D0)
chk("the idempotency guard is load-bearing (blind to the ledger, rows return)",
    len(rows_mut), 2)

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

print("── the titles-only exemption (a per-source opt-out) ──────────────────────")

# A source whose feed carries titles by design, not by accident. The exemption
# waives the summary bar and NOTHING ELSE, and it has to be asked for.
def rec(**kw):
    r = {"id": "a" * 12, "title": "A headline of a perfectly ordinary length here",
         "url": "https://example.com/x", "summary": "short", "source": "S",
         "first_seen": "2026-08-10", "date": "2026-08-10"}
    r.update(kw); return r

chk("a thin summary is refused without the flag", fp.qualifies(rec()), False)
chk("...and admitted with it", fp.qualifies(rec(substance="title-only")), True)

# Fail closed. A flag that defaults open would hand the Hacker News failure —
# "Article URL: Comments URL: Points: 3" clearing the bar on the length of two
# urls — back to every source at once.
for bad_flag in ("title only", "Title-Only", "titles-only", "true", "", "yes"):
    chk(f"a misspelled flag ({bad_flag!r}) leaves the gate on",
        fp.qualifies(rec(substance=bad_flag)), False)
chk("a non-string flag leaves the gate on", fp.qualifies(rec(substance=True)), False)

# The exemption reaches the summary rule only.
chk("an exempt row with an unsafe url is still refused",
    fp.qualifies(rec(substance="title-only", url="javascript:alert(1)")), False)
chk("an exempt row with no title is still refused",
    fp.qualifies(rec(substance="title-only", title="")), False)
chk("an exempt row with a too-short title is still refused",
    fp.qualifies(rec(substance="title-only", title="Tiny")), False)

print("── the repository exemption (MIN_TITLE, and only MIN_TITLE) ──────────────")

# `owner / repo` is a name, not a headline. 38% of 226 measured repositories are
# under the 20-character minimum. The rule exists to reject navigation furniture
# and scraped page chrome; a repository name is neither.
def rrec(**kw):
    r = {"id": "c" * 12, "title": "facebook / react", "summary": "s" * 120,
         "url": "https://github.com/facebook/react", "source": "GitHub Trending",
         "first_seen": "2026-08-10", "date": "2026-08-10"}
    r.update(kw); return r

chk("`facebook / react` (16 chars) is refused without the flag", fp.qualifies(rrec()), False)
chk("...and ADMITTED with substance: repo", fp.qualifies(rrec(substance="repo")), True)
chk("`microsoft / vscode` (18) is admitted",
    fp.qualifies(rrec(substance="repo", title="microsoft / vscode")), True)
chk("this project's own frozen fixture `NomaDamas / k-skill` (19) is admitted",
    fp.qualifies(rrec(substance="repo", title="NomaDamas / k-skill")), True)

# Fail closed, mirroring the titles-only flag above and for the same reason: a
# flag that defaults open waives the rule for every source at once.
for bad_flag in ("Repo", "repos", "repository", "repo-listing", "", "true"):
    chk(f"a misspelled flag ({bad_flag!r}) leaves the gate on",
        fp.qualifies(rrec(substance=bad_flag)), False)
chk("a non-string flag leaves the gate on", fp.qualifies(rrec(substance=True)), False)

# The exemption reaches the title MINIMUM only. Everything else is spent
# elsewhere in qualifies() and none of it is waivable from here.
chk("the maximum still applies to a repo record",
    fp.qualifies(rrec(substance="repo", title="t" * (fp.MAX_TITLE + 1))), False)
chk("an empty title is still refused — a card with no title is not a card",
    fp.qualifies(rrec(substance="repo", title="")), False)
chk("a whitespace-only title is still refused",
    fp.qualifies(rrec(substance="repo", title="   ")), False)
chk("a repo record gets NO summary waiver — that is why it is not title-only",
    fp.qualifies(rrec(substance="repo", summary="short")), False)
chk("a repo record with an unsafe url is still refused",
    fp.qualifies(rrec(substance="repo", url="javascript:alert(1)")), False)
chk("a repo record with no id is still refused",
    fp.qualifies(rrec(substance="repo", id="")), False)
# ...and the two exemptions do not leak into each other.
chk("title-only still does not waive the title minimum",
    fp.qualifies(rrec(substance="title-only")), False)

print("── entity: a second identity, never a replacement for the id ─────────────")

from bundle import item_record, RECORD_FIELDS, RECORD_OPTIONAL_FIELDS

RU  = "https://github.com/facebook/react"
ENT = "github:facebook/react"
plain  = item_record("GitHub Trending", "facebook / react", RU, "2026-08-10", "s" * 120)
tagged = item_record("GitHub Trending", "facebook / react", RU, "2026-08-10", "s" * 120,
                     entity=ENT)

chk("entity is declared optional, not appended to RECORD_FIELDS",
    RECORD_OPTIONAL_FIELDS, ("entity",))
# The frozen fetch golden and every committed pool row depend on this: a record
# built without an entity has to be byte-identical to one built before entities
# existed.
chk("a record with no entity carries no entity key at all", tuple(plain.keys()), RECORD_FIELDS)
chk("a record with one carries it", tagged.get("entity"), ENT)
chk("...normalised, so case cannot fork one repository into two names",
    item_record("S", "T", RU, "d", "s", entity=" GitHub:Facebook/React ")["entity"], ENT)
# Re-keying item_id would re-hash the whole pool and ledger and republish
# everything ever published. The entity is a SECOND key.
chk("the entity does not move the id", tagged["id"], plain["id"])

repo_rec = {**tagged, "substance": "repo"}
pool_e, st_e = fp.ingest([repo_rec], [], fp.ledger_ids([]), D0, TERMS)
chk("a repo record is admitted", st_e["added"], 1)
chk("...and the POOL ROW carries the entity", pool_e[0].get("entity"), ENT)

_, marked = fp.mark_published([repo_rec["id"]], pool_e, D0)
chk("a published ledger row carries the entity", marked[0].get("entity"), ENT)

# Edition items carry only the fields the published schema declares, and entity
# is deliberately not one of them — so publish_edition reads it back out of the
# pool while the row itself still comes from the edition.
_, rows_pub, _ = fp.publish_edition([{"id": repo_rec["id"], "url": RU}], pool_e, [], D0)
chk("publish_edition recovers the entity the edition does not carry",
    rows_pub[0].get("entity"), ENT)

_, retired_e, _ = fp.prune(pool_e, D0 + timedelta(days=fp.MAX_AGE_DAYS + 1))
chk("an expiry tombstone carries it too, or the cooldown has nothing to expire",
    retired_e[0].get("entity"), ENT)

idx = fp.ledger_ids(rows_pub)
chk("ledger_ids indexes entity -> date", idx.entities.get(ENT), D0.isoformat())
chk("...and is still the set of ids every caller already asks", repo_rec["id"] in idx, True)
chk("a ledger of articles carries an empty index",
    fp.ledger_ids([{"id": "x", "url": "u", "published": "2026-08-01"}]).entities, {})
chk("the MOST RECENT date wins when one entity appears twice",
    fp.ledger_ids([{"id": "a", "entity": ENT, "status": "expired", "date": "2026-01-01"},
                   {"id": "b", "entity": ENT, "published": "2026-06-01"}]).entities[ENT],
    "2026-06-01")

print("── the cooldown bounds the ledger's refusal, for an entity only ──────────")

LED_E = fp.ledger_ids(rows_pub)
W = fp.ENTITY_COOLDOWN_DAYS
_, st_in = fp.ingest([repo_rec], [], LED_E, D0 + timedelta(days=W - 1), TERMS)
chk("inside the window the same repository cannot re-enter the pool", st_in["dup_ledger"], 1)
_, st_out = fp.ingest([repo_rec], [], LED_E, D0 + timedelta(days=W), TERMS)
chk("past it, it is a candidate again — 'published once' is not 'banned forever'",
    st_out["added"], 1)

# Fails closed in all three directions.
art = {"id": "d" * 12, "url": "https://example.com/a1", "source": "S",
       "title": "A headline of a perfectly ordinary length here", "summary": "s" * 120}
led_art = fp.ledger_ids([{"id": "d" * 12, "url": art["url"],
                          "status": "published", "published": D0.isoformat()}])
_, st_art = fp.ingest([art], [], led_art, D0 + timedelta(days=W + 99), TERMS)
chk("an article carries no entity, so its refusal stays permanent", st_art["dup_ledger"], 1)

led_old = fp.ledger_ids([{"id": repo_rec["id"], "url": RU,
                          "status": "published", "published": D0.isoformat()}])
_, st_old = fp.ingest([repo_rec], [], led_old, D0 + timedelta(days=W + 99), TERMS)
chk("a ledger row written before entities existed keeps its permanent refusal",
    st_old["dup_ledger"], 1)
_, st_set = fp.ingest([repo_rec], [], {repo_rec["id"]}, D0 + timedelta(days=W + 99), TERMS)
chk("a plain set disables the cooldown, it does not open the gate",
    st_set["dup_ledger"], 1)

print("── batch dedup keeps the better record, not the first ────────────────────")

# A Show HN of a repository links to the repository, so it produces the SAME
# item_id as the trending record — and HN's summary sanitises to nothing.
# First-wins meant the outcome depended on the order of two YAML blocks, with no
# assertion anywhere.
HN_SUMMARY = ("Article URL: https://github.com/facebook/react "
              "Comments URL: https://news.ycombinator.com/item?id=1 Points: 42 # Comments: 7")
TREND_SUMMARY = ("The library for web and native user interfaces, maintained by Meta "
                 "and a community of individual developers.")

def hn():
    return {**item_record("Hacker News", "facebook / react", RU, "2026-08-10",
                          HN_SUMMARY, entity=ENT), "substance": "repo"}
def trend():
    return {**item_record("GitHub Trending", "facebook / react", RU, "2026-08-10",
                          TREND_SUMMARY, entity=ENT), "substance": "repo"}

GOOD = trend()["summary"]
chk("HN's summary sanitises to nothing", hn()["summary"], "")
chk("...and the trending description survives", len(GOOD) >= fp.MIN_SUMMARY, True)
chk("the two records share one id", hn()["id"] == trend()["id"], True)

p_hn, st_hn = fp.ingest([hn(), trend()], [], fp.ledger_ids([]), D0, TERMS)
chk("HN first, trending second: one row is added", st_hn["added"], 1)
chk("...counted as a batch duplicate", st_hn["dup_batch"], 1)
# Compared as a list, not by indexing row 0. Under first-wins the pool is EMPTY
# — HN's blank summary loses the item at the 80-character bar — and an
# IndexError would end the run before the rest of these assertions ever ran.
chk("THE POOL ROW CARRIES THE TRENDING DESCRIPTION",
    [r["summary"] for r in p_hn], [GOOD])
p_tr, _ = fp.ingest([trend(), hn()], [], fp.ledger_ids([]), D0, TERMS)
chk("...and the reverse order gives the same row — tier order no longer decides",
    [r["summary"] for r in p_tr], [GOOD])

# Strictly greater, so an exact tie still keeps the first arrival and tier order
# breaks ties the way it always did.
p_tie, _ = fp.ingest([{**trend(), "source": "First"}, {**trend(), "source": "Second"}],
                     [], fp.ledger_ids([]), D0, TERMS)
chk("an exact tie keeps the first arrival", p_tie[0]["source"], "First")

# A record with no id is a different event from a duplicate and stays countable.
_, st_noid = fp.ingest([{"title": "x" * 40, "summary": "s" * 120},
                        {"title": "y" * 40, "summary": "s" * 120}],
                       [], fp.ledger_ids([]), D0, TERMS)
chk("records with no id are counted unqualified, not collapsed together",
    st_noid["unqualified"], 2)

print("── the cooldown must not become a nightly republish ──────────────────────")
# Found by adversarial review, reproduced by execution: publish_edition refused a
# second row for an id already in the ledger, so the entity's date stayed frozen
# at the FIRST publish. Once that date was 180 days old the release was
# permanent and the card came back every single night — the duplicate-publish
# defect that cost three shared items, on a delayed fuse.
REPO_ROW = {"id": "f" * 12, "title": "acme / thing", "url": "https://github.com/acme/thing",
            "date": "recent", "first_seen": D0.isoformat(), "source": "GitHub Trending",
            "substance": fp.SUBSTANCE_REPO, "entity": "github:acme/thing",
            "summary": "d" * 200}
led_rows = []
pool_r, _ = fp.ingest([REPO_ROW], [], fp.ledger_ids(led_rows), D0, TERMS)
pool_r, rows_r, _ = fp.publish_edition(pool_r, pool_r, led_rows, D0)
led_rows += rows_r
_, _, st_same = fp.publish_edition([REPO_ROW], [REPO_ROW], led_rows, D0)
chk("a re-run on the same night still writes no second row", st_same["marked"], 0)

published_on = []
for offset in (179, 180, 181, 400):
    day = D0 + timedelta(days=offset)
    led = fp.ledger_ids(led_rows)
    p, _ = fp.ingest([REPO_ROW], [], led, day, TERMS)
    if p:
        _, r2, _ = fp.publish_edition(p, p, led_rows, day)
        led_rows += r2
        published_on.append(offset)
chk("a repository republishes ONCE at the window, not every night after it",
    published_on, [180, 400])
chk("...and each republish advances the ledger", len(led_rows), 3)

print("── a forged entity cannot release an article's permanent refusal ─────────")
# entity_cooldown_days releases a refusal, so it re-checks that the row really is
# a repository rather than merely carrying a string in a field. Unreachable
# through the automated path today; every other guard in this file re-checks
# what it was told for the same stated reason — a pool row can be edited by hand.
forged = {"id": "b" * 12, "title": "An ordinary article headline, long enough",
          "url": "https://example.com/a", "summary": "s" * 200,
          "first_seen": D0.isoformat(), "date": D0.isoformat(),
          "entity": "github:foo/bar"}
old_led = fp.Ledger({"b" * 12}, {"github:foo/bar": "2020-01-01"})
chk("an article carrying an entity but no substance is NOT released",
    fp.entity_released(forged, old_led, D0), False)
chk("...and the same row WITH substance is",
    fp.entity_released({**forged, "substance": fp.SUBSTANCE_REPO}, old_led, D0), True)

print("── collapsing a batch merges, it does not replace ────────────────────────")
# `source` is the tier key, the diversity key and the string on the card, and
# substance/entity carry the MIN_TITLE exemption, the cooldown identity and the
# house-voice exclusion. Replacing the record wholesale handed all of them to
# whichever duplicate happened to have three more characters of summary.
def _dup(src, summary, **kw):
    d = {"id": "a" * 12, "source": src, "title": "A headline long enough to pass",
         "url": "https://github.com/acme/thing", "date": D0.isoformat(),
         "summary": summary}
    d.update(kw)
    return d

trend = _dup("GitHub Trending", "A canonical repository description long enough to be a card body.",
             substance=fp.SUBSTANCE_REPO, entity="github:acme/thing")
longer = _dup("Lobsters", "A much longer community write-up about the very same repository here.")
merged, n_col = fp._collapse_batch([trend, longer])
chk("the duplicate is collapsed", n_col, 1)
chk("the incumbent keeps its source, so tier order still decides placement",
    merged[0]["source"], "GitHub Trending")
chk("...and keeps substance", merged[0].get("substance"), fp.SUBSTANCE_REPO)
chk("...and keeps entity", merged[0].get("entity"), "github:acme/thing")
chk("...while taking the fuller body", merged[0]["summary"].startswith("A much longer"), True)

before = dict(trend)
fp._collapse_batch([trend, longer])
chk("the caller's own records are never mutated", trend, before)

empty_first, _ = fp._collapse_batch([_dup("Hacker News", ""), trend])
chk("an empty incumbent still recovers the real body",
    empty_first[0]["summary"].startswith("A canonical"), True)
chk("...and inherits the identity fields it lacked",
    (empty_first[0].get("substance"), bool(empty_first[0].get("entity"))),
    (fp.SUBSTANCE_REPO, True))

print()
if FAIL == 0:
    print(f"\033[32mPASS\033[0m ({COUNT}) — feed pool tests passed")
else:
    print(f"\033[31mFAIL\033[0m — feed pool tests FAILED ({COUNT} assertions run)")
sys.exit(FAIL)
PY
