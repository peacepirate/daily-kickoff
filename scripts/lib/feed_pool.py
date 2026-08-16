"""The candidate pool and the published ledger for the public feed.

The problem this exists for is measured, not hypothetical: **52% of urls arrive
on more than one day, and the worst appeared on 32 of 34 days sampled.** News
index pages re-emit their front page nightly. Without a memory that outlives the
run, a feed built on these bundles republishes the same item every night, which
is the most visible way a curation product can look broken.

Two files, both JSONL, both committed:

  pool.jsonl     candidates seen but not yet published
  ledger.jsonl   append-only, every id ever published

Committed rather than kept in scripts/logs/, which is gitignored and
single-machine — a ledger that does not survive a fresh clone is not a ledger.
Committed to the *engine* repo rather than the feed repo, because the pool
records what was considered and rejected, and publishing rejection judgements
about other people's writing is a different product than the one being built.

The pool is a **staleness-bounded overflow, not a savings account.** Holding a
fresh item back to pad a thin day later is precisely the dishonesty the product
forbids; the pool exists so that a day which genuinely has nothing new can say
so without the pipeline pretending otherwise.

Pure stdlib. No network, no git, no clock of its own — `today` is always passed
in, so a test can run any calendar it likes and a replay of a stored bundle
reproduces exactly.
"""
from __future__ import annotations

import json
import os
from datetime import date as Date, timedelta
from pathlib import Path

try:                                    # normal: scripts/lib is on the path
    from bundle import is_safe_url, sanitise_summary
except ImportError:                     # imported by a caller that put only the
    import sys                          # repo root there. The url rules live in
    sys.path.insert(0, str(Path(__file__).resolve().parent))  # exactly one file.
    from bundle import is_safe_url, sanitise_summary

# An item whose body is shorter than this cannot become a card: the public card
# *is* the summary. 80 characters is the same threshold the ingestion
# measurement used, so "qualifying pool" means one thing in both places.
MIN_SUMMARY = 80

# The one way out of MIN_SUMMARY, and it has to be asked for. A source declares
# `substance: title-only` in the feed pool config; fetch_sources.py stamps
# the declaration onto every record it writes for that source, so the decision
# is made once, from config, and rides with the item rather than being
# re-derived from a source-name list in each module that gates on it.
#
# Exact equality, and only when the key is present. An absent or misspelled
# value means the gate applies — Hacker News cleared the 80-character bar on the
# length of two urls, and a flag that defaults open would hand that failure back
# to every source at once.
SUBSTANCE_TITLE_ONLY = "title-only"

# The one way out of MIN_TITLE, and it rides on the same per-record declaration
# for the same reason: the decision is made once, from config, rather than
# re-derived from a source-name list in each module that gates on it. Exact
# equality, and only when the key is present — a misspelling means the gate
# applies, because a flag that defaults open waives the rule for every source at
# once.
#
# `owner / repo` is a name, not a headline. 38% of 226 measured repositories are
# under the 20-character minimum, including `facebook / react` (16),
# `microsoft / vscode` (18) and this project's own frozen GitHub fixture
# `NomaDamas / k-skill` (19) — which today would be refused by its own pipeline.
# MIN_TITLE exists to reject navigation furniture and scraped page chrome; a
# repository name is neither.
SUBSTANCE_REPO = "repo"

# Titles outside this range are navigation furniture or scraped page chrome, not
# articles. Mirrors the bounds fetch_html already applies.
MIN_TITLE, MAX_TITLE = 20, 250

# How long a candidate stays eligible. Past this it is not news, and publishing
# it would be the pool acting as a savings account.
MAX_AGE_DAYS = 14

# Hard ceiling, oldest dropped first. A pool that grows without bound is a
# memory leak with a diff attached.
POOL_CAP = 600

# How long an *entity* — not a url — is refused after the ledger last dealt with
# it. See `entity_of`: the entity is a second identity for the one content class
# where a url is a permanent name rather than an event.
#
# Two failures, in opposite directions, and one number settles both. An id-keyed
# ledger refuses a url forever, so a repository published once (or expired
# unpublished with a tombstone) can never appear again even when it ships a
# significant 2.0 six months later. And the same project arriving by a different
# door — a release tag, a Show HN link, a link to its README — gets a different
# id and republishes freely.
#
# 180 days is two quarters: long enough that nothing recurs as news inside it
# (the pool itself expires candidates at 14 days, so the window is an order of
# magnitude wider than any candidate's life), and short enough that a genuine
# re-release is not silently unpublishable forever. It protects against a
# permanent ban wearing the name of a cooldown.
ENTITY_COOLDOWN_DAYS = 180


# ── storage ──────────────────────────────────────────────────────────────────

def read_jsonl(path) -> list[dict]:
    """Every well-formed object in `path`. Missing file is empty, not an error.

    A malformed line is skipped rather than fatal. These files are appended to
    by a nightly job; one truncated write must not make the whole history
    unreadable, because the failure mode of "unreadable ledger" is republishing
    everything ever published.
    """
    p = Path(path)
    if not p.exists():
        return []
    out = []
    with open(p) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict):
                out.append(obj)
    return out


def write_jsonl(path, rows: list[dict]) -> None:
    """Rewrite `path` atomically. Used for the pool, which is rewritten whole."""
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    with open(tmp, "w") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    os.replace(tmp, p)


def append_jsonl(path, rows: list[dict]) -> None:
    """Append to `path`. Used for the ledger, which is never rewritten.

    Append-only on purpose: a rewrite that goes wrong silently un-publishes
    history, and the pool would then re-offer everything the rewrite dropped.
    """
    if not rows:
        return
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, "a") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")


# ── admission ────────────────────────────────────────────────────────────────

def contains_blocked(record: dict, terms: list[str]) -> bool:
    """True when any blocked term appears in the record's text.

    The pool is committed to a public repo, so a news story that merely mentions
    a blocked name would put it back the day after it was removed. Filtering on
    entry rather than scanning the file afterwards means such an item is never
    written, never committed, and never becomes a card — which is what a neutral
    brand wants regardless of the repo.

    Spaces are stripped from both sides before comparison, the same rule the
    shell checker uses, so "Example Corp" also catches "ExampleCorp".
    """
    if not terms:
        return False
    hay = " ".join(str(record.get(f, "")) for f in ("title", "summary", "url", "source")).lower()
    squashed = hay.replace(" ", "")
    for term in terms:
        t = term.strip().lower()
        if not t:
            continue
        if t in hay or t.replace(" ", "") in squashed:
            return True
    return False


def summary_exempt(record: dict) -> bool:
    """True when this record's source declared itself titles-only.

    Lives here and is imported by `feed_select`, so admission and selection
    cannot drift into two readings of one flag.
    """
    return record.get("substance") == SUBSTANCE_TITLE_ONLY


def title_min_exempt(record: dict) -> bool:
    """True when this record's source declared itself a repository listing.

    Same shape as `summary_exempt`, same file, and imported rather than
    re-derived for the same reason. Waives the title MINIMUM and nothing else:
    MAX_TITLE, an empty title, url safety, the id and the summary bar are all
    spent elsewhere and none of them is waivable from here.
    """
    return record.get("substance") == SUBSTANCE_REPO


# ── the second identity ──────────────────────────────────────────────────────
#
# `item_id` answers "have I seen this url?", which for an article is the whole
# question — one url is one event. For a repository the url is a permanent
# name, so the same question answered the same way means "published once,
# banned forever" in one direction and "the same project under a different
# path is a different item" in the other. `entity` answers the second question
# — "have I dealt with this thing recently?" — and ENTITY_COOLDOWN_DAYS bounds
# how long "recently" lasts.
#
# It never replaces `item_id`. Re-keying that would re-hash the whole pool and
# ledger and republish everything ever published.


def entity_of(record: dict) -> str:
    """The record's second identity, normalised, or "" when it has none.

    Trimmed and lowercased at every read as well as at the single write in
    `bundle.item_record`, so `github:Owner/Repo` and `github:owner/repo` cannot
    become two names for one repository — which would hand the cooldown a fresh
    window on every capitalisation change.

    Absent on every record but a repository's, and absent means "the url is the
    identity": today's behaviour, unchanged.
    """
    value = record.get("entity")
    return value.strip().lower() if isinstance(value, str) else ""


class Ledger(set):
    """Every id the pool must never offer again, plus the entity index.

    A `set` first and always: every existing caller asks `id in ledger` and goes
    on asking exactly that. `entities` maps entity to the most recent date the
    ledger dealt with it, which is the extra question the cooldown needs.

    Carried on the same object rather than threaded as a second argument
    through `shortlist()`, `eligible()` and `ineligible_reason()` so that
    `feed_edition.py` — which already passes `ledger_ids(...)` straight into
    `shortlist()` — gets the cooldown without a call-site change. A gate wired
    into no caller is a gate that reports success because it never ran.

    A plain `set` in its place is legal and means "no entity index". The
    cooldown then cannot fire and the id refusal stays permanent, which is the
    behaviour that predates it — so every existing test and every caller that
    builds its own set keeps the old semantics rather than silently losing a
    refusal.
    """

    def __init__(self, ids=(), entities: dict | None = None):
        super().__init__(ids)
        self.entities: dict[str, str] = dict(entities or {})


def entity_cooldown_days(record: dict, ledger, today: Date) -> int | None:
    """Days since this record's entity was last published or retired, or None.

    None is "the question does not apply", and it is three distinct cases that
    all want the same answer — the record carries no entity, the ledger has no
    entity index, or nothing in the index names this entity. Each of them means
    the url is still the only identity available, so the caller must fall back
    to the id rule rather than treat an unanswered question as a clearance.
    """
    # The substance check is the difference between "this row names a
    # repository" and "this row carries a string in a field". Only the GitHub
    # lane stamps both today, so this is unreachable through the automated
    # path — but this function RELEASES a permanent id refusal, and every
    # other guard in this file re-checks what it was told on the stated
    # grounds that a pool row can be edited by hand. A forged `entity` on an
    # ordinary article would otherwise republish it.
    if record.get("substance") != SUBSTANCE_REPO:
        return None
    entity = entity_of(record)
    index = getattr(ledger, "entities", None)
    if not entity or not index:
        return None
    try:
        last = Date.fromisoformat(index.get(entity) or "")
    except (ValueError, TypeError):
        # An unparseable date cannot bound a window. Answering None hands the
        # decision back to the permanent id rule, which is the safe direction.
        return None
    return (today - last).days


def entity_released(record: dict, ledger, today: Date) -> bool:
    """True when this record's entity is known to the ledger and out of window.

    The read side of the cooldown that *admits* rather than refuses. Without it
    a repository published under its own url could never return, because
    `ingest` refuses the id before selection ever sees the row — and the
    cooldown's expiry would be unreachable for exactly the case it was written
    for.
    """
    since = entity_cooldown_days(record, ledger, today)
    return since is not None and since >= ENTITY_COOLDOWN_DAYS


def qualifies(record: dict) -> bool:
    """The quality bar, and the definition of a 'qualifying' item.

    Deliberately the same predicate the ingestion measurement uses. A launch
    gate whose threshold is measured by one rule and enforced by another is a
    gate that cannot be reasoned about.

    The url safety rule is inside this predicate as well as counted separately
    in `ingest`, deliberately. `ingest` checks first so the stats can say
    `unsafe_url` rather than the useless `unqualified`; the copy here is what
    protects every *other* caller — the ingestion measurement, a replay, a
    future migration — because a guard that only runs on one of two call paths
    is the guard that reports success because it never ran.
    """
    if not record.get("id"):
        return False
    if not is_safe_url(record.get("url")):
        return False
    title = (record.get("title") or "").strip()
    # Split from the range test so the repository exemption can reach the
    # minimum and only the minimum. An empty title and MAX_TITLE are refused
    # first and are not waivable: a card with no title is not a card, and the
    # upper bound is what rejects a scraped page of chrome.
    if not title or len(title) > MAX_TITLE:
        return False
    if not title_min_exempt(record) and len(title) < MIN_TITLE:
        return False
    # Last, so the exemption can only ever waive the summary rule. Id, url
    # safety and the title bounds are already spent above and are not waivable.
    if summary_exempt(record):
        return True
    return len((record.get("summary") or "").strip()) >= MIN_SUMMARY


def _body_length(record: dict) -> int:
    """Characters of summary a reader could actually use.

    Measured through `sanitise_summary` rather than on the raw field, because
    the raw field is what made the two indistinguishable: Hacker News serves
    `Article URL: … Comments URL: … Points: N`, which is 100+ raw characters and
    zero real ones. Idempotent, so a record whose summary was already sanitised
    at `item_record` measures the same here.
    """
    return len(sanitise_summary(record.get("summary") or "").strip())


def _collapse_batch(records: list[dict]) -> tuple[list[dict], int]:
    """One record per id within a batch, keeping the fuller summary.

    Returns (records, collapsed_count). Order is first-arrival, so tier order
    still decides *where* an item sits; only its content is upgraded.

    **Why quality and not arrival order.** A Show HN of a repository links to
    the repository, so it produces the same `item_id` as the trending record —
    and its summary sanitises to empty. First-wins meant the outcome depended on
    which of two YAML blocks came first: with the aggregator ahead, the pool got
    the empty summary and rejected the item at the 80-character bar while a
    perfectly good description sat in the record right behind it. Nothing
    asserted the ordering, so the feature worked or did not by accident.

    Strictly greater, so an exact tie keeps the first arrival and tier order
    still breaks ties the way it always did.
    """
    out: list[dict] = []
    at: dict[str, int] = {}
    collapsed = 0
    for rec in records:
        rid = rec.get("id")
        if not rid:
            # Kept in place: the main loop counts it as `unqualified`, which is
            # a different event from a duplicate and has to stay countable.
            out.append(rec)
            continue
        if rid not in at:
            at[rid] = len(out)
            out.append(rec)
            continue
        collapsed += 1
        # MERGE, never replace. Replacing the whole record hands the loser's
        # `source` to the winner, and `source` is the tier key, the diversity
        # key and the string printed on the card — so a length comparison would
        # silently re-tier an item that config order had already placed. Live
        # pairs that collide on one url exist today: two TechCrunch tag feeds,
        # InfoQ Culture (tier 1) against InfoQ AI/ML (tier 2), and any
        # aggregator whose <link> is the target url.
        #
        # It would also drop `substance` and `entity`, which is worse than
        # untidy: losing them costs a repository its MIN_TITLE exemption, its
        # cooldown identity, and its exclusion from the house voice — the
        # prompt-injection defence — all from one summary being three characters
        # longer somewhere else.
        #
        # So: take the better body, and fill the identity fields only where the
        # incumbent has none. Everything that decides placement stays put.
        # Copied, not mutated in place. The caller's list is the sidecar just
        # read off disk, and a function that quietly rewrites its own input
        # makes the second call on the same data behave differently from the
        # first — which is exactly how this was noticed.
        incumbent = dict(out[at[rid]])
        if _body_length(rec) > _body_length(incumbent):
            incumbent["summary"] = rec.get("summary", "")
        for key in ("substance", "entity"):
            if not incumbent.get(key) and rec.get(key):
                incumbent[key] = rec[key]
        out[at[rid]] = incumbent
    return out, collapsed


def ingest(records: list[dict], pool: list[dict], ledger_ids: set,
           today: Date, blocked_terms: list[str] | None = None) -> tuple[list[dict], dict]:
    """Fold today's records into the pool. Returns (new_pool, stats).

    Deduplication runs over three horizons, and they are genuinely different
    questions:

      within the batch   the same story fetched from two sources this morning
      against the pool   a candidate carried over from a previous day
      against the ledger something already published, possibly weeks ago

    Only the third needs to be permanent — and for a record carrying an
    `entity` it is not permanent but bounded, because there the url is a name
    rather than an event. See ENTITY_COOLDOWN_DAYS.

    Within the batch, a duplicate id is resolved by summary quality rather than
    by arrival order — see `_collapse_batch`.

    `first_seen` is set once, on entry, and never refreshed. Refreshing it on
    every re-arrival would make an item that appears daily immortal — exactly
    the items that most need to age out.
    """
    blocked_terms = blocked_terms or []
    by_id = {r["id"]: r for r in pool if r.get("id")}
    stats = {"seen": len(records), "added": 0, "dup_batch": 0,
             "dup_pool": 0, "dup_ledger": 0, "unqualified": 0, "blocked": 0,
             "unsafe_url": 0}

    records, stats["dup_batch"] = _collapse_batch(records)

    for rec in records:
        rid = rec.get("id")
        if not rid:
            stats["unqualified"] += 1
            continue
        # The ledger's refusal is permanent for a url and bounded for an
        # entity. Fails closed: `entity_released` is true only when the ledger
        # actually names this entity and the window has passed, so a row
        # written before entities existed keeps the refusal it always had.
        if rid in ledger_ids and not entity_released(rec, ledger_ids, today):
            stats["dup_ledger"] += 1
            continue
        if rid in by_id:
            stats["dup_pool"] += 1
            continue
        if contains_blocked(rec, blocked_terms):
            stats["blocked"] += 1
            continue
        # Counted apart from `unqualified`, which mixes a thin summary with a
        # short title and would hide this entirely. A `javascript:` url arriving
        # from a scraped href is a different event from a boring one, and the
        # night it happens the stats have to say so.
        if not is_safe_url(rec.get("url")):
            stats["unsafe_url"] += 1
            continue
        if not qualifies(rec):
            stats["unqualified"] += 1
            continue
        entry = dict(rec)
        entry["first_seen"] = today.isoformat()
        by_id[rid] = entry
        stats["added"] += 1

    return list(by_id.values()), stats


def prune(pool: list[dict], today: Date,
          max_age_days: int = MAX_AGE_DAYS,
          cap: int = POOL_CAP) -> tuple[list[dict], list[dict], dict]:
    """Drop what is too old, then what does not fit.

    Returns (pool, retired_rows, stats). The retired rows are ledger rows, and
    writing them is not optional.

    **Why retirement must be recorded.** Expiring an item only removes it from
    the pool. The source that served it on day 1 is usually still serving it on
    day 15, so without a tombstone the item walks straight back in with a fresh
    `first_seen` and becomes publishable as news three weeks after it was news.
    That is the same republishing failure this module exists to prevent, running
    slower and therefore harder to notice. The 30-day replay test caught exactly
    this and it is the reason retirement is a ledger event rather than a delete.

    Age first, then cap: capping first would keep a stale item over a fresh one
    purely because the stale one was already there.

    A tombstone carries the row's `entity` when it has one, for the same reason
    it carries the url: without it an expired repository is refused by its id
    forever and the cooldown has nothing to expire.
    """
    cutoff = today - timedelta(days=max_age_days)
    stats = {"before": len(pool), "expired": 0, "over_cap": 0}
    kept, retired = [], []
    for row in pool:
        try:
            seen = Date.fromisoformat(row.get("first_seen", ""))
        except ValueError:
            # No usable first_seen: treat as today rather than dropping it. A
            # parse failure must not delete a candidate.
            seen = today
        if seen < cutoff:
            stats["expired"] += 1
            retired.append(_ledger_row(row, {"id": row.get("id", ""),
                                             "url": row.get("url", ""),
                                             "status": "expired",
                                             "date": today.isoformat()}))
            continue
        kept.append(row)

    kept.sort(key=lambda r: (r.get("first_seen", ""), r.get("id", "")), reverse=True)
    if len(kept) > cap:
        # Over-cap items are retired too. Dropping them silently would leave the
        # same resurrection hole the age bound had.
        for row in kept[cap:]:
            retired.append(_ledger_row(row, {"id": row.get("id", ""),
                                             "url": row.get("url", ""),
                                             "status": "over_cap",
                                             "date": today.isoformat()}))
        stats["over_cap"] = len(kept) - cap
        kept = kept[:cap]
    stats["after"] = len(kept)
    return kept, retired, stats


# ── publishing ───────────────────────────────────────────────────────────────

def _ledger_row(source_row: dict, row: dict) -> dict:
    """`row`, plus the entity `source_row` carries. One write point.

    Omitted when there is none, so a ledger of articles is byte-identical to
    the one written before entities existed — the ledger is committed, and a
    field that is empty on every row is a diff nobody can read.
    """
    entity = entity_of(source_row)
    if entity:
        row["entity"] = entity
    return row


def ledger_ids(ledger: list[dict]) -> Ledger:
    """Every id the pool must never offer again — published AND retired.

    One set, deliberately. The pool only ever asks "have I finished with this?",
    and splitting the answer across two files invites a caller that checks one.

    Returns a `Ledger`, which IS that set and additionally carries the entity
    index the cooldown reads. Every caller that treats the result as a plain set
    keeps working unchanged; see `Ledger`.

    The index holds the MOST RECENT date per entity — ISO strings compare
    chronologically — so a repository dealt with twice is measured from the
    later of the two. Measuring from the earlier would let a cooldown expire
    while the item was still in the ledger's recent past.
    """
    ids = {row["id"] for row in ledger if row.get("id")}
    entities: dict[str, str] = {}
    for row in ledger:
        entity = entity_of(row)
        if not entity:
            continue
        # `published` on a published row, `date` on a tombstone. Both are the
        # day the ledger dealt with the item, which is what the window measures.
        # Coerced, because a hand-edited or externally produced ledger line
        # carrying a non-string date used to raise TypeError here and take
        # down both the nightly edition build and ingest. A malformed line
        # must cost its own row, never the run — the same rule read_jsonl
        # already applies to an unparseable line.
        when = str(row.get("published") or row.get("date") or "")
        if when > entities.get(entity, ""):
            entities[entity] = when
    return Ledger(ids, entities)


def published_rows(ledger: list[dict]) -> list[dict]:
    """Only the rows that were actually published, for permalinks and rebuilds."""
    return [r for r in ledger if r.get("status", "published") == "published"]


def mark_published(ids: list[str], pool: list[dict], today: Date) -> tuple[list[dict], list[dict]]:
    """Move `ids` out of the pool and into ledger rows. Returns (pool, rows).

    The url is carried into the ledger, not just the id. An id is a hash and
    cannot be read; when something goes wrong at 06:00 the question is always
    "which item was that", and a ledger that cannot answer it is a ledger nobody
    trusts enough to act on.
    """
    wanted = set(ids)
    rows, kept = [], []
    for row in pool:
        if row.get("id") in wanted:
            rows.append(_ledger_row(row, {"id": row["id"], "url": row.get("url", ""),
                                          "status": "published",
                                          "published": today.isoformat()}))
        else:
            kept.append(row)
    return kept, rows


def publish_edition(items: list[dict], pool: list[dict], ledger: list[dict],
                    today: Date) -> tuple[list[dict], list[dict], dict]:
    """Ledger rows for everything an edition published, and a pool without them.

    Returns (pool, rows, stats). This is the write side of the loop whose read
    side has always existed: feed_edition.py excludes `ledger_ids()` from
    selection, and until something wrote the ledger that exclusion set was
    permanently empty. Two of the first three editions shared three items
    because of it.

    **Rows come from the edition, not from the pool.** `mark_published()` builds
    them by matching ids back into the pool, which silently produces no row for
    an item pruned between ingest and publish — and an item with no row is
    eligible again tomorrow. The edition file is the authority on what was
    published, which is the same argument `rebuild_ledger()` already makes: it
    is what readers saw.

    **Idempotent, which is a requirement rather than a nicety.** `append_jsonl`
    never rewrites, so a second run for the same date would append a second set
    of rows. A retried night, a hand re-run after a failed push, and the replay
    path all reach this. An id already in the ledger produces no new row and is
    counted as `already`.

    Removal from the pool is keyed on every id the edition names, not only the
    newly-marked ones. An id that is somehow in both the pool and the ledger is
    a bug this should absorb rather than preserve.

    **The entity comes from the pool row, the ledger row does not.** An edition
    item carries only the fields the published schema declares, and `entity` is
    deliberately not one of them — nothing on the card needs it. So the row is
    still built from the edition, which is the authority on what was published;
    only the second identity is read back out of the pool. An item pruned
    between ingest and publish therefore still gets a ledger row, exactly as
    before — it just gets one with no entity, and the id refusal stays permanent
    for it, which is the safe direction.
    """
    known = ledger_ids(ledger)
    pool_by_id = {r["id"]: r for r in pool if r.get("id")}
    rows, seen = [], set()
    stats = {"marked": 0, "already": 0, "no_id": 0}

    for item in items:
        rid = item.get("id")
        if not rid:
            # Defensive: the CLI refuses an edition containing one of these
            # before calling, because an item with no id cannot be excluded
            # from tomorrow and would republish forever.
            stats["no_id"] += 1
            continue
        if rid in seen:
            stats["already"] += 1
            continue
        source_row = item if entity_of(item) else pool_by_id.get(rid, {})
        # An id already in the ledger normally produces no row — that is the
        # idempotency this function is built around. The exception is a
        # repository republishing after its cooldown: refusing the row there
        # would leave the entity's date frozen at the FIRST publish, so
        # `entity_released` would stay true from that day on and the card would
        # reappear every single night, forever. Verified by execution before
        # this branch existed: day 180, 181, 400 and 900 all republished while
        # the ledger stayed at one row.
        #
        # Same-night idempotency is unaffected: once this writes a row dated
        # today the entity is zero days old, `entity_released` is false, and a
        # re-run counts `already` exactly as before.
        if rid in known and not entity_released(source_row, known, today):
            stats["already"] += 1
            seen.add(rid)
            continue
        seen.add(rid)
        rows.append(_ledger_row(source_row, {"id": rid, "url": item.get("url", ""),
                                             "status": "published",
                                             "published": today.isoformat()}))
        stats["marked"] += 1

    kept = [row for row in pool if row.get("id") not in seen]
    stats["pool"] = len(kept)
    return kept, rows, stats


def rebuild_ledger(published_records: list[dict], fallback_date: str) -> list[dict]:
    """Reconstruct ledger rows from what was actually published.

    The recovery path for a lost or corrupted ledger. Published output is the
    authority — it is what readers saw — and the ledger is a cache of it. Losing
    a cache should cost a rebuild, never a week of duplicate cards.
    """
    out, seen = [], set()
    for rec in published_records:
        rid = rec.get("id")
        if not rid or rid in seen:
            continue
        seen.add(rid)
        out.append(_ledger_row(rec, {
            "id": rid, "url": rec.get("url", ""),
            "published": rec.get("published") or rec.get("date") or fallback_date}))
    return out


# ── CLI ──────────────────────────────────────────────────────────────────────
#
# `ingest` is invoked nightly by the `feed` job's fetch step, via
# ingest_feed_records in scripts/lib/job-config.sh, and by hand for replays.
#
# `publish` is invoked by run-jobs.sh AFTER publish_feed_site returns 0 — that
# is, only once the edition is confirmed at the remote. Marking earlier would
# retire seven items on a night whose verify or push then failed, and nothing
# returns them to the pool. A quarantined edition is recoverable; a retired item
# is not.
#
# It is a command rather than a call inside feed_edition.py for three reasons:
# feed_edition.py runs before the publish and must not know about it; a command
# can be re-run by hand after a recovered failure; and it is testable without a
# network or a model.
#
# A replay produces exactly what the nightly path would have, because ingest()
# and publish_edition() both take `today` as an argument instead of reading a
# clock.

def _blocklist_terms(path) -> list[str]:
    """Read the shared blocklist. Missing file raises — callers decide.

    Fails loudly rather than returning [] : an empty term list silently disables
    the one admission rule whose failure is unrecoverable.
    """
    out = []
    with open(path) as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if line:
                out.append(line)
    if not out:
        raise ValueError(f"blocklist has no terms: {path}")
    return out


def _main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description="Feed candidate pool and published ledger")
    ap.add_argument("command", choices=["ingest", "publish", "stats"])
    ap.add_argument("--records", help="JSONL record sidecar to ingest")
    ap.add_argument("--edition", help="Edition JSON to mark published (required for publish)")
    ap.add_argument("--state", required=True, help="Directory holding pool.jsonl and ledger.jsonl")
    ap.add_argument("--date", required=True, help="Run date, YYYY-MM-DD")
    ap.add_argument("--blocklist", help="Path to the blocklist (required for ingest)")
    a = ap.parse_args(argv)

    state = Path(a.state)
    pool = read_jsonl(state / "pool.jsonl")
    ledger = read_jsonl(state / "ledger.jsonl")
    today = Date.fromisoformat(a.date)

    if a.command == "stats":
        print(f"pool   {len(pool)} candidate(s)")
        print(f"ledger {len(ledger)} published")
        if pool:
            ages = sorted(r.get("first_seen", "") for r in pool)
            print(f"oldest candidate first seen {ages[0]}, newest {ages[-1]}")
        return 0

    if a.command == "publish":
        import sys
        if not a.edition:
            ap.error("publish needs --edition")
        edition = json.loads(Path(a.edition).read_text())

        # The published date comes from the edition, and --date must agree with
        # it. Passing the wrong date here is not a cosmetic slip: the ledger row
        # is what tells a later run how old an item is, and backfilling under
        # today's date would claim a week-old item published this morning. The
        # same trap `feed_pool.py --date` already carries for replays.
        ed_date = edition.get("date")
        if ed_date and ed_date != a.date:
            print(f"refusing: --date is {a.date} but {a.edition} is dated {ed_date}. "
                  f"Pass the date the edition was published.", file=sys.stderr)
            return 1

        items = edition.get("items") or []
        if not items:
            print(f"refusing: {a.edition} has no items. Nothing was published, so "
                  f"marking it would retire nothing and hide a broken edition.", file=sys.stderr)
            return 1

        # Fails closed and before any write. An item with no id cannot be put in
        # the ledger, and an item not in the ledger is offered again tomorrow —
        # so a partial mark is the one outcome worse than no mark at all.
        missing = sum(1 for it in items if not it.get("id"))
        if missing:
            print(f"refusing: {missing} of {len(items)} item(s) in {a.edition} have no id. "
                  f"They could not be excluded from a future edition.", file=sys.stderr)
            return 1

        pool, rows, st = publish_edition(items, pool, ledger, today)
        write_jsonl(state / "pool.jsonl", pool)
        append_jsonl(state / "ledger.jsonl", rows)
        print(f"published {a.date}: marked={st['marked']} already={st['already']} "
              f"pool={st['pool']}")
        return 0

    if not a.records or not a.blocklist:
        ap.error("ingest needs --records and --blocklist")
    terms = _blocklist_terms(a.blocklist)
    records = read_jsonl(a.records)
    pool, st = ingest(records, pool, ledger_ids(ledger), today, terms)
    pool, retired, pst = prune(pool, today)
    write_jsonl(state / "pool.jsonl", pool)
    append_jsonl(state / "ledger.jsonl", retired)
    print(f"ingest {a.date}: seen={st['seen']} added={st['added']} "
          f"dup_batch={st['dup_batch']} dup_pool={st['dup_pool']} dup_ledger={st['dup_ledger']} "
          f"unqualified={st['unqualified']} blocked={st['blocked']} "
          f"unsafe_url={st['unsafe_url']}")
    print(f"prune:  expired={pst['expired']} over_cap={pst['over_cap']} pool={pst['after']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
