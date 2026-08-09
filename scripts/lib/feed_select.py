"""Deterministic selection over the candidate pool — the code half of E6.

Reconciliation 6 split selection rather than picking a winner:

  code decides eligibility, ordering and the final veto
  the model judges topical relevance and writes
  code has the last word — anything the model returns that breaks a rule is
  dropped, not argued with

This module is the code half, entire. It contains no model call, no network and
no clock: `today` is passed in, so the same pool produces the same shortlist on
any machine on any day, which is what makes S6.5 testable and what everything
downstream assumes.

**What the measurement says the job actually is.** On the first real day the
pool held 64 candidates from 27 sources across 29 domains, against a ceiling of
seven. Every hard filter here is nearly satisfied before it runs — the pool's
own admission rule already did that work. So filtering is not where this earns
its keep; **narrowing fairly and ordering honestly is.** The ingestion plan says
the same thing from the other end: precision of the seven chosen, not recall of
the pool, is what has to be measured.

**What is deliberately not ranked on.** Summary length is the obvious available
proxy for substance and is not used. Vendor-owned blogs write the longest
summaries in the pool, so ranking on length would quietly amplify the 54%
vendor concentration this product exists to counter — a metric that rewards
exactly the thing it was introduced to control. Code orders by declared
editorial priority and by freshness, both of which mean what they say, and
leaves judgement of substance to the model that can actually read the item.
"""
from __future__ import annotations

import re
from datetime import date as Date
from pathlib import Path
from urllib.parse import urlsplit

try:                                    # normal: scripts/lib is on the path
    from bundle import is_safe_url
except ImportError:                     # imported with only the repo root there
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from bundle import is_safe_url

# How many candidates the model is shown. Large enough that it is exercising
# judgement rather than rubber-stamping a set code already chose; small enough
# that code is genuinely narrowing. At 64 candidates a day this is roughly a
# 3:1 narrowing, and the model then works a 3:1 selection down to the ceiling.
SHORTLIST_SIZE = 20

# The ceiling, and never a target. Padding to reach it is the failure mode that
# would destroy a curation product, so nothing in this module tries to.
DAILY_CAP = 7

# Diversity, at two strengths. The shortlist is loose so the model sees range;
# the final veto is strict so no returned set can concentrate.
#
# 54% of everything this pipeline has ever published came from vendor-owned
# domains. Both caps exist to make that arithmetically impossible rather than
# unlikely: seven items under one-per-source is seven distinct publications.
SHORTLIST_PER_SOURCE, SHORTLIST_PER_DOMAIN = 2, 3
FINAL_PER_SOURCE, FINAL_PER_DOMAIN = 1, 2

# The substance gate. Measured before it was chosen: on the first real pool it
# removes 8 of 64, because admission at 80 characters already did most of this
# work. It is a real effect and a small one, and it is documented as small so
# nobody later reads it as a strong control and stops looking for one.
MIN_SUMMARY_SELECT = 120

# Two write-ups of one announcement are not two items. Advisory only — the
# clusters are handed to the model, which can read them, rather than resolved
# here by token overlap, which cannot tell a follow-up from a rewrite.
NEAR_DUP_JACCARD = 0.6

# Words that carry no topical signal and would inflate every pairwise overlap.
_STOPWORDS = frozenset("""
a an the and or but of for to in on at by with from as is are was were be been
being it its this that these those how why what when who new now more most can
could will would should may might must into over under about after before
""".split())

_TOKEN_RE = re.compile(r"[a-z0-9]+")


# ── source metadata ──────────────────────────────────────────────────────────

def source_tiers(config_path) -> dict[str, int]:
    """Map source name to tier number from a fetch config.

    The tiers in `scripts/topics/feed.yaml` are the only place editorial
    priority is written down, so ranking reads them rather than inventing a
    second opinion that would immediately disagree with the first.

    Read at selection time, not captured at ingest time. The consequence is
    real and is the better of the two: editing a tier re-ranks candidates still
    in the pool. That is what "this is my current priority" should mean, and the
    alternative — a 14-day tail of rows ranked by a policy no longer in force —
    is harder to reason about than a change that takes effect.
    """
    import yaml
    cfg = yaml.safe_load(Path(config_path).read_text()) or {}
    out: dict[str, int] = {}
    for n, key in ((1, "tier1"), (2, "tier2"), (3, "tier3")):
        for src in (cfg.get("sources") or {}).get(key) or []:
            name = (src or {}).get("name")
            if name:
                out[name] = n
    return out


# Unknown sources sort last rather than being dropped. A source renamed or
# retired in the config must not silently delete the candidates already in the
# pool from it — that would be a config edit quietly discarding captured days,
# and fetch_sources.py anchors to now(), so those days cannot be re-fetched.
UNKNOWN_TIER = 9


def tier_of(row: dict, tiers: dict[str, int]) -> int:
    return tiers.get(row.get("source", ""), UNKNOWN_TIER)


def domain_of(url: str) -> str:
    """Registrable-ish host, lowercased, `www.` dropped.

    Not a public-suffix implementation on purpose. The per-domain cap exists to
    stop one publication taking the day; treating `blog.example.com` and
    `example.com` as one is the behaviour that wants, and a full PSL dependency
    buys correctness this cap does not need.
    """
    host = (urlsplit(url or "").netloc or "").lower()
    if host.startswith("www."):
        host = host[4:]
    parts = [p for p in host.split(".") if p]
    return ".".join(parts[-2:]) if len(parts) > 2 else host


# ── eligibility ──────────────────────────────────────────────────────────────

# Every reason a candidate can fail, as a closed vocabulary. Counting rejections
# by reason is what makes a thin day explicable instead of merely thin.
ELIGIBILITY_REASONS = ("published", "stale", "thin_summary", "no_url",
                       "no_title", "unsafe_url")


def ineligible_reason(row: dict, today: Date, ledger: set,
                      max_age_days: int, min_summary: int) -> str | None:
    """The first rule `row` breaks, or None. Order is diagnostic, not logical."""
    if not row.get("id") or not (row.get("url") or "").strip():
        return "no_url"
    # Re-checked here even though admission refuses these, for the same reason
    # the ledger is re-checked below: pool.jsonl is a committed file that gets
    # hand-edited and migrated, and rows admitted before this rule existed have
    # never been through it. Selection is the last place a url can be refused
    # while it is still cheap.
    if not is_safe_url(row.get("url")):
        return "unsafe_url"
    if row["id"] in ledger:
        return "published"
    if not (row.get("title") or "").strip():
        return "no_title"
    try:
        seen = Date.fromisoformat(row.get("first_seen", ""))
    except ValueError:
        seen = today
    if (today - seen).days > max_age_days:
        return "stale"
    if len((row.get("summary") or "").strip()) < min_summary:
        return "thin_summary"
    return None


def eligible(pool: list[dict], today: Date, ledger: set,
             max_age_days: int = 14,
             min_summary: int = MIN_SUMMARY_SELECT) -> tuple[list[dict], dict]:
    """Candidates that may be shown, plus a count of why the rest were not.

    The ledger is re-checked here even though `ingest` already excludes
    published ids. The ledger is the authority and the pool is a working set;
    one bad pool write should cost a rebuild, not a republished item.
    """
    rows, stats = [], {r: 0 for r in ELIGIBILITY_REASONS}
    for row in pool:
        reason = ineligible_reason(row, today, ledger, max_age_days, min_summary)
        if reason:
            stats[reason] += 1
        else:
            rows.append(row)
    stats["eligible"] = len(rows)
    return rows, stats


# ── ranking ──────────────────────────────────────────────────────────────────

def _ordinal(value: str, default: int = 0) -> int:
    try:
        return Date.fromisoformat(value).toordinal()
    except (ValueError, TypeError):
        return default


def rank_key(row: dict, tiers: dict[str, int]) -> tuple:
    """A total order. Every component is a stable function of the row.

    tier, then most recently seen, then most recently published, then id. The id
    is a hash and its order is arbitrary — that is the point of having it last.
    It is a tiebreaker that cannot be gamed and cannot vary between runs, which
    is worth more here than any ordering it could be replaced with: the
    remaining judgement belongs to the model, and a code-side proxy invented to
    fill this slot would be a preference nobody chose.
    """
    return (
        tier_of(row, tiers),
        -_ordinal(row.get("first_seen", "")),
        -_ordinal(row.get("date", "")),
        row.get("id", ""),
    )


def rank(rows: list[dict], tiers: dict[str, int]) -> list[dict]:
    return sorted(rows, key=lambda r: rank_key(r, tiers))


# ── diversity ────────────────────────────────────────────────────────────────

def diversify(ranked: list[dict], limit: int,
              per_source: int, per_domain: int) -> tuple[list[dict], dict]:
    """Take from `ranked` in order, skipping anything that would breach a cap.

    Greedy over an already-total order, so the result is deterministic. Skipped
    items are not dropped from consideration by any later stage — they are just
    not in this set.
    """
    chosen: list[dict] = []
    by_source: dict[str, int] = {}
    by_domain: dict[str, int] = {}
    stats = {"source_capped": 0, "domain_capped": 0}
    for row in ranked:
        if len(chosen) >= limit:
            break
        src = row.get("source", "")
        dom = domain_of(row.get("url", ""))
        if by_source.get(src, 0) >= per_source:
            stats["source_capped"] += 1
            continue
        if by_domain.get(dom, 0) >= per_domain:
            stats["domain_capped"] += 1
            continue
        by_source[src] = by_source.get(src, 0) + 1
        by_domain[dom] = by_domain.get(dom, 0) + 1
        chosen.append(row)
    stats["chosen"] = len(chosen)
    return chosen, stats


# ── near duplicates ──────────────────────────────────────────────────────────

def _tokens(text: str) -> frozenset:
    return frozenset(t for t in _TOKEN_RE.findall((text or "").lower())
                     if t not in _STOPWORDS and len(t) > 2)


def near_duplicates(rows: list[dict], threshold: float = NEAR_DUP_JACCARD) -> list[list[str]]:
    """Clusters of ids whose titles overlap enough to be one story.

    Advisory. Nothing is dropped here, and that is deliberate: token overlap
    cannot distinguish two write-ups of one announcement from a genuine
    follow-up, and dropping the follow-up is the more expensive mistake. The
    clusters go to the model, which can read both.

    Returned sorted, and each cluster sorted, so the output is stable.
    """
    ids = [r.get("id", "") for r in rows]
    toks = [_tokens(r.get("title", "")) for r in rows]
    parent = list(range(len(rows)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(len(rows)):
        for j in range(i + 1, len(rows)):
            a, b = toks[i], toks[j]
            if not a or not b:
                continue
            union = len(a | b)
            if union and len(a & b) / union >= threshold:
                parent[find(i)] = find(j)

    groups: dict[int, list[str]] = {}
    for i, rid in enumerate(ids):
        groups.setdefault(find(i), []).append(rid)
    return sorted((sorted(g) for g in groups.values() if len(g) > 1))


# ── the shortlist ────────────────────────────────────────────────────────────

def shortlist(pool: list[dict], ledger: set, today: Date,
              tiers: dict[str, int],
              size: int = SHORTLIST_SIZE) -> dict:
    """Everything code decides, in one reproducible pass.

    Returns the candidates the model should judge, the ranked eligible set
    behind them, the near-duplicate advisory, and the stage counts that make a
    thin day explicable.
    """
    rows, elig_stats = eligible(pool, today, ledger)
    ranked = rank(rows, tiers)
    chosen, div_stats = diversify(ranked, size, SHORTLIST_PER_SOURCE, SHORTLIST_PER_DOMAIN)
    return {
        "date": today.isoformat(),
        "shortlist": chosen,
        "ranked_ids": [r.get("id", "") for r in ranked],
        "near_duplicates": near_duplicates(chosen),
        "stats": {**elig_stats, **div_stats, "pool": len(pool)},
    }


# ── the veto ─────────────────────────────────────────────────────────────────

def veto(returned_ids: list[str], shortlist_rows: list[dict],
         cap: int = DAILY_CAP,
         per_source: int = FINAL_PER_SOURCE,
         per_domain: int = FINAL_PER_DOMAIN) -> tuple[list[dict], dict]:
    """Code's last word over whatever the model returned.

    Four ways to lose a slot, and none of them are a negotiation:

      not_offered   an id that was not on the shortlist. Covers both a
                    hallucinated id and a real pool item the model reached past
                    the shortlist to grab
      duplicate     the same id returned twice
      source_capped / domain_capped
                    concentration, re-checked at the strict caps. The shortlist
                    was diversified loosely so the model had range; that is not
                    a licence to hand back seven items from one publisher
      over_cap      anything past the ceiling

    Order is preserved as the model returned it. Relevance ordering is its
    judgement to make and there is nothing code could substitute for it — code's
    stake is in *which* items appear, not in which is most interesting.
    """
    by_id = {r.get("id", ""): r for r in shortlist_rows}
    kept: list[dict] = []
    by_source: dict[str, int] = {}
    by_domain: dict[str, int] = {}
    seen: set = set()
    dropped = {"not_offered": [], "duplicate": [],
               "source_capped": [], "domain_capped": [], "over_cap": []}

    for rid in returned_ids:
        row = by_id.get(rid)
        if row is None:
            dropped["not_offered"].append(rid)
            continue
        if rid in seen:
            dropped["duplicate"].append(rid)
            continue
        seen.add(rid)
        if len(kept) >= cap:
            dropped["over_cap"].append(rid)
            continue
        src = row.get("source", "")
        dom = domain_of(row.get("url", ""))
        if by_source.get(src, 0) >= per_source:
            dropped["source_capped"].append(rid)
            continue
        if by_domain.get(dom, 0) >= per_domain:
            dropped["domain_capped"].append(rid)
            continue
        by_source[src] = by_source.get(src, 0) + 1
        by_domain[dom] = by_domain.get(dom, 0) + 1
        kept.append(row)

    return kept, dropped


# ── the thin-day vocabulary ──────────────────────────────────────────────────
#
# Fewer than seven is a normal outcome, not an error, and it needs words of its
# own so a quiet day and a broken pipeline never read the same. Each value names
# the stage that actually bound the count, which is also what tells you whether
# to do anything about it.

THIN_REASONS = {
    "full":            "A full edition.",
    "pool_thin":       "Not enough eligible candidates — the pool itself was thin.",
    "substance_thin":  "Enough candidates, but too few cleared the substance gate.",
    "stale_thin":      "Enough candidates, but most had aged out of the window.",
    "diversity_bound": "Enough candidates, but they concentrated into too few sources.",
    "model_thin":      "Code offered a full shortlist; fewer items were judged worth running.",
    "vetoed_thin":     "The returned set broke eligibility rules and was cut back.",
}


def thin_reason(final_count: int, stats: dict, dropped: dict | None = None,
                cap: int = DAILY_CAP) -> str:
    """Which stage bound the day. A key of THIN_REASONS.

    Checked in the order the pipeline runs, so the reason names the *first*
    place the count was lost rather than the last. A day that was thin at the
    pool and also concentrated is a thin pool — fixing diversity would not have
    helped it.
    """
    if final_count >= cap:
        return "full"
    eligible_n = stats.get("eligible", 0)
    if eligible_n < cap:
        if stats.get("thin_summary", 0) >= cap:
            return "substance_thin"
        if stats.get("stale", 0) >= cap:
            return "stale_thin"
        return "pool_thin"
    if stats.get("chosen", 0) < cap:
        return "diversity_bound"
    if dropped and any(dropped.get(k) for k in
                       ("not_offered", "duplicate", "source_capped", "domain_capped")):
        return "vetoed_thin"
    return "model_thin"


# ── CLI ──────────────────────────────────────────────────────────────────────
#
# `shortlist` is what E8 will hand the model. It runs standalone now so the
# narrowing can be read by a person before any model is wired to it, and so
# S6.8's ranking precision has something to score against from the first day
# rather than from the day the model lands.

def _main(argv=None):
    import argparse, json
    from feed_pool import read_jsonl, ledger_ids

    ap = argparse.ArgumentParser(description="Deterministic feed selection")
    ap.add_argument("command", choices=["shortlist", "explain"])
    ap.add_argument("--state", required=True, help="Directory holding pool.jsonl and ledger.jsonl")
    ap.add_argument("--config", required=True, help="Fetch config supplying the source tiers")
    ap.add_argument("--date", required=True, help="Run date, YYYY-MM-DD")
    ap.add_argument("--size", type=int, default=SHORTLIST_SIZE)
    a = ap.parse_args(argv)

    state = Path(a.state)
    result = shortlist(
        read_jsonl(state / "pool.jsonl"),
        ledger_ids(read_jsonl(state / "ledger.jsonl")),
        Date.fromisoformat(a.date),
        source_tiers(a.config),
        size=a.size,
    )

    if a.command == "shortlist":
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
        return 0

    st = result["stats"]
    print(f"pool {st['pool']} → eligible {st['eligible']} → shortlist {st['chosen']}")
    print("  rejected: " + ", ".join(f"{k}={st[k]}" for k in ELIGIBILITY_REASONS))
    print(f"  capped:   source={st['source_capped']} domain={st['domain_capped']}")
    # Code-side only. Whether the day is actually full depends on how many of
    # these the model judges worth running, which is E8 — so this says what code
    # can supply, not what will publish.
    reason = thin_reason(min(st["chosen"], DAILY_CAP), st)
    print(f"  code can supply: {THIN_REASONS[reason]}")
    if result["near_duplicates"]:
        print(f"  {len(result['near_duplicates'])} near-duplicate cluster(s) flagged")
    print()
    for i, row in enumerate(result["shortlist"], 1):
        print(f"{i:2}. [{row.get('source','?')}] {row.get('title','')[:88]}")
    return 0


if __name__ == "__main__":
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    raise SystemExit(_main())
