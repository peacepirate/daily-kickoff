#!/usr/bin/env python3
"""
Fetch tiered news sources for a given topic and print structured content to stdout.
No Anthropic API — pure HTTP. Output is piped to claude for synthesis.

Usage:
  python3 scripts/fetch_sources.py --topic ai           # last 24 hours (daily)
  python3 scripts/fetch_sources.py --topic ai --weekly  # last 7 days (Saturday)
  python3 scripts/fetch_sources.py --topic leadership --weekly
"""
from __future__ import annotations

import argparse
import calendar
import html
import json
import os
import re
import sys
from datetime import datetime, date as Date, timedelta, timezone
from pathlib import Path
from urllib.parse import urlparse

try:
    import httpx
    import feedparser
    import yaml
    from bs4 import BeautifulSoup
except ImportError:
    print("Missing deps. Run: pip install httpx feedparser beautifulsoup4 pyyaml", file=sys.stderr)
    sys.exit(1)

parser = argparse.ArgumentParser(description="Fetch topic sources")
parser.add_argument("--topic", help="Topic name (resolves to scripts/topics/TOPIC.yaml)")
parser.add_argument("--config", metavar="PATH",
                    help="Path to the fetch config, relative to the repo root. Use instead of "
                         "--topic for a config that does not live in scripts/topics/")
parser.add_argument("--weekly", action="store_true", help="Use 7-day lookback window instead of 24h")
parser.add_argument("--records", metavar="PATH",
                    help="Also write a JSONL record per item to PATH (structured twin of the bundle)")
args = parser.parse_args()

IS_WEEKLY = args.weekly
LOOKBACK  = timedelta(days=7 if IS_WEEKLY else 1)
# One reading of the clock, shared by everything below it. Two separate now()
# calls straddling midnight would give SINCE and TODAY different days, and a
# module constant is also the only thing a test can pin — the repository floors
# measure ages against NOW, so a frozen fixture stays frozen.
NOW       = datetime.now(tz=timezone.utc)
SINCE     = NOW - LOOKBACK
TODAY     = NOW.date()
EVENT_WINDOW_START = TODAY + timedelta(days=2)   # Monday after Saturday run
EVENT_WINDOW_END   = TODAY + timedelta(days=30)

SCRIPT_DIR = Path(__file__).parent
# scripts/lib carries the shared wire format. Put it on the path rather than
# making scripts/ a package, so a producer at any depth (studio/) imports it
# the same way and no invocation depends on the caller's cwd.
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from bundle import clean_text, format_item, item_record, sanitise_summary  # noqa: E402  — needs the path line above

# Two ways in, and exactly one must be given.
#
# `--topic ai` resolves to scripts/topics/ai.yaml. That is the whole rule, and
# it is why the feed pool broke: `scripts/topics/feed.yaml` moved to
# `scripts/feed/10-feed.yaml`, its producer kept saying `--topic feed`, and this
# lookup went on pointing at a file that no longer existed. The rename was
# committed and the nightly job failed the next morning — the config the runner
# discovers and the config the producer reads had drifted apart with nothing
# holding them together.
#
# `--config scripts/feed/10-feed.yaml` is the fix, and it is the convention the
# sibling job already uses: 20-edition.yaml names this same file by hand for the
# reason written there — one string, one directory away, and it fails loudly on
# a rename rather than quietly selecting from an empty tier map. A config
# outside scripts/topics/ must name itself, so a future move breaks the path
# rather than the meaning.
if bool(args.topic) == bool(args.config):
    print("ERROR: pass exactly one of --topic or --config", file=sys.stderr)
    sys.exit(1)

if args.config:
    # Relative to the repo root, which is where run-job.sh cd's before running a
    # producer. Resolved against it explicitly rather than trusting cwd, so the
    # same string works from a terminal in any directory.
    CONFIG_PATH = Path(args.config)
    if not CONFIG_PATH.is_absolute():
        CONFIG_PATH = SCRIPT_DIR.resolve().parent / args.config
else:
    CONFIG_PATH = SCRIPT_DIR / "topics" / f"{args.topic}.yaml"

if not CONFIG_PATH.exists():
    print(f"ERROR: Fetch config not found: {CONFIG_PATH}", file=sys.stderr)
    sys.exit(1)

with open(CONFIG_PATH) as f:
    TOPIC_CONFIG = yaml.safe_load(f)

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                  "AppleWebKit/537.36 (KHTML, like Gecko) "
                  "Chrome/124.0.0.0 Safari/537.36",
    "Accept":          "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
}

def client() -> httpx.Client:
    return httpx.Client(timeout=20, headers=HEADERS, follow_redirects=True)

def warn(msg: str) -> None:
    print(f"  [WARN] {msg}", file=sys.stderr)

# Accumulated in memory and written once at the end, not appended per item: a
# run that dies halfway should leave no sidecar rather than a truncated one a
# consumer would read as complete.
RECORDS: list[dict] = []


def print_item(source: str, title: str, url: str, date: str, summary: str,
               substance: str | None = None, entity: str | None = None) -> None:
    # Entity decoding and tag stripping apply to both consumers. RSS summaries
    # already arrived clean — they pass through BeautifulSoup's `get_text`,
    # which unescapes as a side effect — but titles never did, and that
    # asymmetry put `Google Earth&#8217;s` into the digest bundles for weeks.
    #
    # `url` is untouched: item_id() hashes it, so normalising it here would
    # re-key the whole pool and ledger and republish everything.
    #
    # The heavier card-body sanitising — feed boilerplate, call-to-action tails,
    # sentence trimming — is deliberately NOT applied here. It lives inside
    # item_record, so it reaches the feed and not the digest: a card body must
    # be reader-ready, while the synthesis prompt copes with a clipped sentence
    # and would only lose content to the trim.
    title, summary = clean_text(title), clean_text(summary)
    print(format_item(source, title, url, date, summary), end="")
    if args.records:
        record = item_record(source, title, url, date, summary, entity=entity or "")
        # `substance` is declared once — by the topic config for a whole source,
        # or by a fetcher for one item it verified — and copied verbatim onto the
        # record, so the pool and selection both read one decision instead of
        # each carrying its own list of source names. Set only when declared:
        # the consumers compare it for exact equality, so an absent or
        # misspelled value leaves their gates on.
        if substance:
            record["substance"] = substance
        RECORDS.append(record)


def write_records() -> None:
    """Write the sidecar, or warn. Never raises.

    The bundle is the contract the nightly digest depends on and it is already
    on stdout by the time this runs. A sidecar is an extra for a product that
    does not exist yet, so a full disk or a bad path must cost the feed its
    records and cost the digest nothing.
    """
    if not args.records:
        return
    try:
        path = Path(args.records)
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w") as fh:
            for rec in RECORDS:
                fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception as ex:
        warn(f"records sidecar not written to {args.records}: {ex}")


# ── Event date extraction ─────────────────────────────────────────────────────

def parse_date_text(text: str) -> Date | None:
    """
    Try to extract the earliest date in `text` using stdlib regex + strptime.
    Returns a date object on first match, or None.
    Handles: ISO (2026-05-25), "May 25, 2026", "May 25–27, 2026" (start date),
    "Sunday May 25 2026", "5/25/2026".
    """
    if not text:
        return None

    # 1. ISO YYYY-MM-DD (also catches datetime attributes like "2026-05-25T10:00:00")
    # Use negative lookahead (?!\d) instead of \b so "25T" still matches.
    m = re.search(r'\b(20\d{2})-(\d{2})-(\d{2})(?!\d)', text)
    if m:
        try:
            return Date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        except ValueError:
            pass

    # 2. "Month DD, YYYY" — handles ranges "May 25–27, 2026" by taking start day
    m = re.search(
        r'\b(January|February|March|April|May|June|July|August|September|October|November|December'
        r'|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)'
        r'\s+(\d{1,2})(?:\s*[–\-]\s*\d{1,2})?,\s*(20\d{2})\b',
        text, re.I,
    )
    if m:
        try:
            return datetime.strptime(f"{m.group(1)[:3].capitalize()} {m.group(2)} {m.group(3)}", "%b %d %Y").date()
        except ValueError:
            pass

    # 3. "Weekday, Month DD, YYYY" or "Weekday Month DD YYYY"
    m = re.search(
        r'\b(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|Mon|Tue|Wed|Thu|Fri|Sat|Sun)'
        r'[,\s]+'
        r'(January|February|March|April|May|June|July|August|September|October|November|December'
        r'|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)'
        r'\s+(\d{1,2}),?\s+(20\d{2})\b',
        text, re.I,
    )
    if m:
        try:
            return datetime.strptime(f"{m.group(1)[:3].capitalize()} {m.group(2)} {m.group(3)}", "%b %d %Y").date()
        except ValueError:
            pass

    # 4. MM/DD/YYYY
    m = re.search(r'\b(\d{1,2})/(\d{1,2})/(20\d{2})\b', text)
    if m:
        try:
            return datetime.strptime(f"{m.group(1)}/{m.group(2)}/{m.group(3)}", "%m/%d/%Y").date()
        except ValueError:
            pass

    return None


# CSS class pattern for date-hinting elements
_DATE_CLASS_RE = re.compile(
    r'event.?date|start.?date|end.?date|tribe.event|event.?time'
    r'|event.?schedule|event.?when|(?:^|\s)when(?:\s|$)|(?:^|\s)date(?:\s|$)',
    re.I,
)


# Article indexes label their dates differently from event listings: `post-date`,
# `entry-date`, `published`, `pubdate`. Kept separate from _DATE_CLASS_RE rather
# than merged into it, so that broadening article coverage cannot shift what the
# Saturday events digest extracts.
_ARTICLE_DATE_CLASS_RE = re.compile(
    r'post.?date|entry.?date|article.?date|pub(?:lish(?:ed)?)?.?date|published'
    r'|date.?published|byline.?date|timestamp|(?:^|\s)date(?:\s|$)',
    re.I,
)


def _marked_up_date(container, class_re) -> Date | None:
    """
    The date a page states *about itself*, from markup that exists to carry a
    date: <time>, date-hinting CSS classes, data-* attributes. Returns None when
    the page never marks one up.

    Split out from extract_event_date so article recency can use these four
    signals without the fifth. Scanning an article's body text for a date finds
    dates the article merely *mentions*, and dropping a fresh post because its
    prose says "2024" loses content silently — the worst failure available here.
    An event listing can afford that scan because a date is the point of the
    listing; an article cannot.
    """
    # 1 & 2 — <time> tags
    for t in container.find_all("time"):
        dt_attr = t.get("datetime", "")
        if dt_attr:
            d = parse_date_text(dt_attr[:20])
            if d:
                return d
        d = parse_date_text(t.get_text(" ", strip=True))
        if d:
            return d

    # 3 — date-hinting CSS classes
    for el in container.find_all(class_=class_re):
        d = parse_date_text(el.get_text(" ", strip=True))
        if d:
            return d

    # 4 — data attributes
    for el in container.find_all(True):
        for attr in ("data-date", "data-start", "data-start-date", "data-event-date"):
            val = el.get(attr, "")
            if val:
                d = parse_date_text(val)
                if d:
                    return d

    return None


def extract_event_date(container) -> Date | None:
    """
    The best date in an event listing, or None. Marked-up signals first, then a
    full-text scan of the container — broadest, and prone to false positives,
    but an undated event listing is useless and a wrong date is visible.
    """
    d = _marked_up_date(container, _DATE_CLASS_RE)
    if d:
        return d
    # 5 — full container text (broadest scan, risk of false positives)
    return parse_date_text(container.get_text(" ", strip=True))


def extract_article_date(container) -> Date | None:
    """The date an article page states about itself, or None. Marked up only."""
    return _marked_up_date(container, _ARTICLE_DATE_CLASS_RE)


# ── Releasebot.io ─────────────────────────────────────────────────────────────

def fetch_releasebot(name: str, url: str, max_items: int) -> list[dict]:
    try:
        with client() as c:
            r = c.get(url)
            r.raise_for_status()
        soup = BeautifulSoup(r.text, "html.parser")
        items = []
        for h2 in soup.find_all("h2", class_=re.compile(r"text-h2")):
            version = h2.get_text(strip=True)
            container = h2.find_parent(["div", "section", "article"]) or h2.parent
            prose = container.find("div", class_=re.compile(r"\bprose\b"))
            notes = prose.get_text(" ", strip=True)[:500] if prose else ""
            item_url = url.rstrip("/") + f"#{version.replace(' ', '-')}"
            items.append({"title": f"{name.split()[0]} {version}",
                           "url": item_url, "date": "recent", "summary": notes})
            if len(items) >= max_items:
                break
        return items
    except Exception as ex:
        warn(f"{name}: {ex}")
        return []


# ── RSS / Atom ────────────────────────────────────────────────────────────────

def fetch_rss(name: str, url: str, max_items: int) -> list[dict]:
    try:
        with client() as c:
            r = c.get(url)
            r.raise_for_status()
        feed = feedparser.parse(r.text)
        items = []
        for e in feed.entries:
            pub = None
            for attr in ("published_parsed", "updated_parsed"):
                val = getattr(e, attr, None)
                if val:
                    pub = datetime.fromtimestamp(calendar.timegm(val), tz=timezone.utc)
                    break
            if pub and pub < SINCE:
                continue
            raw = (getattr(e, "summary", "") or
                   (getattr(e, "content", [{}])[0].get("value", "") if hasattr(e, "content") else ""))
            summary = BeautifulSoup(raw, "html.parser").get_text(" ", strip=True)[:600]
            items.append({
                "title":   getattr(e, "title", "").strip(),
                "url":     getattr(e, "link", url),
                "date":    pub.strftime("%Y-%m-%d") if pub else "recent",
                "summary": summary,
            })
            if len(items) >= max_items:
                break
        return items
    except Exception as ex:
        warn(f"{name}: {ex}")
        return []


# ── Generic HTML ──────────────────────────────────────────────────────────────

def fetch_html(name: str, url: str, max_items: int,
               container_sel=None,
               title_sel=None,
               event_mode: bool = False) -> list[dict]:
    """
    Scrape an HTML page for article/event items.

    When event_mode=True, each container is inspected for an event date:
    - Date found and within EVENT_WINDOW_START..EVENT_WINDOW_END → include with DATE: YYYY-MM-DD
    - Date found and outside that window (past OR too far future) → silently drop
    - No date found → include with DATE: UNKNOWN (Claude adds "check website" note)

    When event_mode=False (default, used by non-event topics), all items pass
    through unchanged with date="recent" as before.
    """
    try:
        with client() as c:
            r = c.get(url)
            r.raise_for_status()
        soup = BeautifulSoup(r.text, "html.parser")
        base = urlparse(url)

        if container_sel:
            containers = soup.select(container_sel)[:60]
        else:
            containers = (
                soup.find_all(["article", "li"],
                              class_=re.compile(r"post|news|article|entry|card|item", re.I))
                or [soup]
            )

        items, seen = [], set()
        for block in containers:
            if title_sel:
                heading = block.select_one(title_sel)
            else:
                heading = block.find(["h1", "h2", "h3", "h4"])
            link = block.find("a", href=True)
            if not (heading or link):
                continue
            title = (heading or link).get_text(strip=True)
            if not title or not (20 <= len(title) <= 250):
                continue
            href = (link["href"] if link else "").strip()
            if any(s in href for s in ["#", "twitter", "linkedin", "facebook", "mailto:", "javascript:"]):
                continue
            if href.startswith("/"):
                href = f"{base.scheme}://{base.netloc}{href}"
            if not href.startswith("http"):
                href = url
            if href in seen:
                continue
            seen.add(href)
            summary = ""
            for p in block.find_all("p")[:3]:
                t = p.get_text(strip=True)
                if len(t) > 40:
                    summary = t[:400]
                    break

            if event_mode:
                event_date = extract_event_date(block)
                if event_date is None:
                    # No date found — include but flag for Claude to verify
                    ev_date_str = "UNKNOWN"
                elif event_date < EVENT_WINDOW_START or event_date > EVENT_WINDOW_END:
                    # Outside the 30-day forward window (past or too far future) — drop
                    continue
                else:
                    ev_date_str = event_date.strftime("%Y-%m-%d")
                items.append({"title": title, "url": href, "date": ev_date_str, "summary": summary})
            else:
                # Recency, the same rule fetch_rss applies. Without this a news
                # index re-emits its whole front page every night: measured
                # across the stored bundles, two thirds of the ai bundle was
                # content it had already served, and six sources contributing
                # 15.6 items a night yielded 1.6 new ones.
                #
                # Drops only what it can prove is stale. An item whose page
                # marks up no date passes, because "no date found" and "old"
                # are different claims and only one of them justifies dropping
                # a story.
                pub = extract_article_date(block)
                if pub is not None and pub < SINCE.date():
                    continue
                items.append({"title": title, "url": href,
                              "date": pub.strftime("%Y-%m-%d") if pub else "recent",
                              "summary": summary})

            if len(items) >= max_items:
                break
        return items
    except Exception as ex:
        warn(f"{name}: {ex}")
        return []


# ── GitHub Trending ───────────────────────────────────────────────────────────

def fetch_github_trending(max_items: int) -> list[dict]:
    try:
        with client() as c:
            r = c.get("https://github.com/trending")
            r.raise_for_status()
        soup = BeautifulSoup(r.text, "html.parser")
        items = []
        for article in soup.find_all("article")[:max_items]:
            h2 = article.find("h2")
            if not h2:
                continue
            title = re.sub(r"\s+", " ", h2.get_text(separator=" ", strip=True))
            a_tag = h2.find("a", href=True)
            href  = "https://github.com" + a_tag["href"] if a_tag else ""
            desc_el = article.find("p")
            summary = desc_el.get_text(strip=True)[:300] if desc_el else ""
            stars_el = article.find("a", href=re.compile(r"stargazers"))
            stars = stars_el.get_text(strip=True) if stars_el else ""
            if stars:
                summary = f"{summary} ({stars} stars)".strip()
            if title and href:
                items.append({"title": title, "url": href, "date": "recent", "summary": summary})
        return items
    except Exception as ex:
        warn(f"GitHub Trending: {ex}")
        return []


# ── GitHub repositories — the public feed's own path ─────────────────────────
#
# A second, complete route to the same page, and the duplication is the whole
# point. `fetch_github_trending` above is read nightly by scripts/topics/ai.yaml
# and has been for the life of the private digest, so one shared fetcher makes
# every feed change an untested digest change. Measured before this was written:
# a marker prefixed onto every repository title — which rewrites every GitHub
# line in the nightly digest — passed all 26 suites. Nothing here may call
# anything in that function, and nothing there may call anything here.
#
# The trending page supplies the *list* and nothing else. Every fact used to
# admit a repository comes from `GET /repos/{owner}/{repo}`, because the review
# gate sees a title, a description and a url and does not open the repository.
# The screening below is therefore the only thing between a typosquat and a
# published card, which is what makes it load-bearing rather than advisory.

GITHUB_API_URL = "https://api.github.com/repos/{full_name}"

# Unauthenticated: 60 requests an hour, against a candidate list capped at
# `max_items` (15 in the feed config). No token, so no secret to rotate and no
# authenticated-quota failure at 06:00. The budget is per IP, which is why the
# cap is applied to the candidate list *before* enrichment and not to the
# survivors after it.
GITHUB_API_HEADERS = {
    "Accept":                "application/vnd.github+json",
    "X-GitHub-Api-Version":  "2022-11-28",
    # GitHub rejects an API request with no User-Agent outright. Named rather
    # than borrowed from HEADERS above: that one impersonates a browser to get
    # HTML, and doing so against a documented API is both unnecessary and the
    # thing that gets an IP blocked.
    "User-Agent":            "daily-kickoff (+https://daily-kickoff.com)",
}

# Shorter than the 20s the HTML client uses. Every candidate costs one call in
# sequence, so the timeout multiplies by the candidate count: 15 × 10s is the
# worst case this can add to a nightly fetch, and 15 × 20s is not acceptable.
GITHUB_API_TIMEOUT = 10

# ── the admission floors ─────────────────────────────────────────────────────
#
# Chosen by replaying the 41 repositories that cleared the pool's own bars
# across the stored bundles (2026-07-01 → 2026-08-12), not by sketching numbers.
# What each one costs in supply is recorded beside it, because a floor whose
# price nobody measured is a floor nobody can argue with later.

# Cuts 2 of 41 (5%). The typosquat and credential-stealer window is the first
# weeks of a repository's life — it trends on manufactured stars and is taken
# down within days — and no measured candidate was younger than 72 days, so this
# sits just above the observed floor rather than inside the distribution.
REPO_MIN_AGE_DAYS = 90

# Cuts 0 of 41. INERT ON MEASURED DATA: the minimum observed was 1,674 stars,
# more than three times this bar, so it has never rejected anything and is not
# expected to. Kept deliberately, and labelled so nobody deletes it as dead
# code: it is insurance against a population that has not occurred — a trending
# board thinned by an outage or an API change to how trending is computed —
# where the first cheap thing to lose is the crowd's signal. All-time stars are
# the wrong metric for ranking (they order the famous above the new), which is
# why this number is used here and nowhere else: a floor, never a sort key, and
# never displayed.
REPO_MIN_STARS = 500

# Cuts 0 of 41. Rejects a star spike on an abandoned repository — the shape
# where an old project trends because it was linked, not because it is alive.
REPO_MAX_PUSH_AGE_DAYS = 180

# Measured against the sanitised description rather than the raw one, because
# that is the string the pool will re-measure and the card will carry. A floor
# that reads a different value from the gate downstream admits candidates that
# die later and reports them as supply.
#
# THE NUMBER IS feed_select.MIN_SUMMARY_SELECT (120), NOT feed_pool.MIN_SUMMARY
# (80), and the difference is not cosmetic. Admission at 80 lets a repository
# into the pool that selection can never choose: it sits at `thin_summary` for
# the full 14-day staleness window, expires, and — since the entity cooldown
# landed — writes a tombstone carrying its entity, which then bars that
# repository for a further 180 days. An 80-char floor therefore does not merely
# waste a pool slot, it silently bans real candidates for six months.
#
# This is the "candidates that can never be chosen" failure `10-feed.yaml`
# already records against the release feeds, reached from a new direction and
# made worse by the cooldown. `test-github-repos.sh` asserts this constant is
# >= MIN_SUMMARY_SELECT so the two cannot drift apart again.
#
# Costs nothing against the calibration: the 41 repositories the floors were
# measured on were already the set clearing 120.
#
# `substance: title-only` was considered here and rejected: it waives the
# summary bar, which lands a repository on the title rung as a bare
# `facebook / react` with nothing under it — the link list this product exists
# not to be. The measurement says repository descriptions exist and are merely
# short, so requiring one is the right gate.
REPO_MIN_DESCRIPTION = 120

# Stamped onto every record this function emits. Compared for exact equality by
# the pool, which uses it to exempt a repository from the title-length rule —
# `facebook / react` is 16 characters and that rule exists to reject scraped
# page chrome, which a repository name is not.
#
# Stamped here, from the API response that was just verified, rather than
# declared in the source config the way `substance: title-only` is. The
# exemption is earned by screening, not by a line of YAML: a config typo must
# not be able to hand a non-repository the same waiver.
REPO_SUBSTANCE = "repo"

# Licence is deliberately NOT a floor. 7 of 41 (17%) carry none or
# NOASSERTION, and cutting a sixth of the supply to enforce a signal no card
# displays is a bad trade. It is not captured either: this project deletes
# fields with no consumer, and nothing reads a licence today.

# `owner/repo` and nothing else. Guards the entity string, which is a contract
# with the pool, against the trending page's other hrefs (`/topics/ai`,
# `/login?return_to=…`) and against a path with a third segment.
_REPO_FULL_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$")


def github_api_client() -> httpx.Client:
    """The API client. Separate from `client()`, which impersonates a browser."""
    return httpx.Client(timeout=GITHUB_API_TIMEOUT, headers=GITHUB_API_HEADERS,
                        follow_redirects=True)


def api_datetime(value) -> datetime | None:
    """An instant from an API timestamp, or None when it is absent or malformed.

    None means drop, never pass. The floors are the only screening a repository
    gets, and a floor that could not read its input has not been applied.
    """
    if not value:
        return None
    try:
        # `.replace` because Python 3.9's fromisoformat rejects a trailing `Z`,
        # which is the only form the GitHub API emits.
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def github_trending_candidates(name: str, url: str, max_items: int) -> list[str]:
    """`owner/repo` for each repository on the trending board, in board order.

    Reads `url` from the config, unlike `kind: github`, whose dispatch ignores
    it entirely — `url:` there is decorative and editing it to `?since=weekly`
    is a silent no-op. Here the string in the config is the page that is fetched.
    """
    try:
        with client() as c:
            r = c.get(url)
            r.raise_for_status()
    except Exception as ex:
        warn(f"{name}: trending page not fetched ({ex})")
        return []
    soup = BeautifulSoup(r.text, "html.parser")
    out = []
    for article in soup.find_all("article")[:max_items]:
        h2 = article.find("h2")
        a_tag = h2.find("a", href=True) if h2 else None
        if not a_tag:
            continue
        full_name = a_tag["href"].strip().strip("/")
        if _REPO_FULL_NAME_RE.match(full_name):
            out.append(full_name)
    return out


def github_repo_api(name: str, full_name: str) -> dict | None:
    """The API's record for `full_name`, or None when it could not be read.

    **Fails closed, and this is the property the whole gate rests on.** A
    timeout, a 403, a rate-limit or a malformed body returns None and the
    candidate is dropped — it is never admitted from the scraped record. An
    enrichment step that falls back on failure is a gate that opens exactly when
    the network is unusual, and it would present as an ordinary night.
    """
    try:
        with github_api_client() as c:
            r = c.get(GITHUB_API_URL.format(full_name=full_name))
            r.raise_for_status()
            data = r.json()
    except Exception as ex:
        warn(f"{name}: {full_name} dropped — API enrichment failed ({ex})")
        return None
    if not isinstance(data, dict):
        warn(f"{name}: {full_name} dropped — API returned {type(data).__name__}, not an object")
        return None
    return data


def fetch_github_repos(name: str, url: str, max_items: int) -> list[dict]:
    """Screened repositories from the trending board, feed-only."""
    api_failures = 0
    candidates = github_trending_candidates(name, url, max_items)
    if not candidates:
        # `find_all("article")` returning [] after a markup change, and every
        # card losing its <h2>, both yield an empty list with no exception. The
        # bundle then reads *No items fetched*, run-job.sh's `^URL:` gate passes
        # on the other forty sources, and the edition publishes with zero
        # repositories and exit code 0 — perfect silence, indistinguishable from
        # a quiet night. This is the only thing that tells the two apart.
        warn(f"{name}: 0 repositories on the trending page — the markup may have changed")

    items = []
    for full_name in candidates:
        data = github_repo_api(name, full_name)
        if data is None:
            api_failures += 1
            continue

        # The shape check, first: a valid `full_name` is what makes this a
        # repository object, and it is what licenses the `.get(...)` defaults
        # below to read an absent flag as False rather than as a drop.
        api_name = str(data.get("full_name") or "").strip().strip("/")
        if not _REPO_FULL_NAME_RE.match(api_name):
            continue

        # A trending fork is almost always noise or an attack; archived and
        # disabled repositories are not things to put in front of a reader.
        if data.get("fork") or data.get("archived") or data.get("disabled"):
            continue

        created = api_datetime(data.get("created_at"))
        if created is None or (NOW - created).days < REPO_MIN_AGE_DAYS:
            continue

        if int(data.get("stargazers_count") or 0) < REPO_MIN_STARS:
            continue

        pushed = api_datetime(data.get("pushed_at"))
        if pushed is None or (NOW - pushed).days > REPO_MAX_PUSH_AGE_DAYS:
            continue

        # The API's own description, and only that. **Nothing is appended to it
        # — least of all a star count.** `feed_edition.card_rung` may regenerate
        # this field from fetched page text, so a measured fact placed here can
        # be silently dropped or restated by a model; and an edition page never
        # regenerates, so "(94,544 stars)" would be wrong the next day and wrong
        # forever in the archive. Stars are a floor above and nothing else.
        summary = sanitise_summary(clean_text(data.get("description") or ""))
        if len(summary) < REPO_MIN_DESCRIPTION:
            continue

        items.append({
            "title":   api_name.replace("/", " / "),
            "url":     f"https://github.com/{api_name}",
            # The day it trended. Not "recent": `feed_select.rank_key` sorts on
            # -_ordinal(date), and `_ordinal` answers 0 for anything it cannot
            # parse — which sorts BELOW every real date rather than above it. An
            # unparseable date therefore ranks a repository under every article
            # sharing its tier and its first_seen, past the 20-slot shortlist,
            # and the judge never sees it.
            #
            # Set once and never refreshed: `feed_pool.ingest` skips a known id
            # as dup_pool, so a repository that holds the board for days keeps
            # the date it first trended and ages out on schedule.
            "date":    NOW.date().isoformat(),
            "summary": summary,
            # Lowercased owner/repo, no host, no trailing slash. A contract with
            # the pool's cooldown check — vary the format and the same project
            # arriving through a different url path stops matching.
            "entity":  f"github:{api_name.lower()}",
            "substance": REPO_SUBSTANCE,
        })

    if candidates and not items:
        # An outage and a quiet board are different events and must not share a
        # sentence. Every candidate failing enrichment means the API was
        # unreachable, rate-limited or refusing us — the night publishes with no
        # repository either way, exit 0, no FAILED_JOBS entry, so the log line
        # is the only thing that can tell them apart. This is the §6.3 silence
        # the zero-item warning exists to break, recreated on the API path.
        if api_failures == len(candidates):
            warn(f"{name}: 0 of {len(candidates)} candidates enriched — the GitHub API "
                 f"was unreachable or refusing requests, NOT a quiet board. "
                 f"Unauthenticated limit is 60/hour and is shared per IP.")
        else:
            warn(f"{name}: 0 of {len(candidates)} candidates cleared the admission floors "
                 f"({api_failures} lost to the API, {len(candidates) - api_failures} to the floors)")
    return items


def fetch(name: str, kind: str, url: str, max_items: int,
          event_mode: bool = False) -> list[dict]:
    print(f"  {name}", file=sys.stderr)
    if kind == "releasebot":
        return fetch_releasebot(name, url, max_items)
    if kind == "github":
        return fetch_github_trending(max_items)
    if kind == "github_repos":
        return fetch_github_repos(name, url, max_items)
    if kind in ("rss", "atom"):
        return fetch_rss(name, url, max_items)
    return fetch_html(name, url, max_items, event_mode=event_mode)


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    # Falls back to the config's own stem rather than args.topic, which is None
    # whenever the config arrived via --config.
    topic_name = TOPIC_CONFIG.get("name") or args.topic or CONFIG_PATH.stem
    since_str = SINCE.strftime("%Y-%m-%d %H:%M UTC")
    print(f"# Fetched {topic_name} — {'last 7 days' if IS_WEEKLY else 'last 24 hours'} (since {since_str})\n")
    total = 0

    sources_block = TOPIC_CONFIG.get("sources", {})
    tier_defs = [
        ("TIER 1 — Primary Sources", sources_block.get("tier1", [])),
        ("TIER 2 — Curators",        sources_block.get("tier2", [])),
        ("TIER 3 — Discovery",       sources_block.get("tier3", [])),
    ]

    for tier_label, tier_sources in tier_defs:
        if not tier_sources:
            continue
        print(f"\n---\n## {tier_label}\n")
        print(f"Fetching {tier_label}…", file=sys.stderr)

        for src in tier_sources:
            name       = src["name"]
            kind       = src["kind"]
            url        = src["url"]
            max_items  = src.get("max_items", 10)
            filter_re  = src.get("filter_regex")
            filter_cap = src.get("filter_cap")
            event_mode = src.get("event_mode", False)
            substance  = src.get("substance")

            items = fetch(name, kind, url, max_items, event_mode=event_mode)

            if filter_re:
                pattern = re.compile(filter_re, re.I)
                items = [i for i in items if pattern.search(i["title"] + " " + i["summary"])]
            if filter_cap is not None:
                items = items[:filter_cap]

            if not items:
                print(f"### {name}\n*No items fetched*\n")
                continue

            print(f"### {name} — {len(items)} items\n")
            for item in items:
                # A per-item value wins over the source's declaration. Config
                # states an intention about a whole feed; a fetcher that set one
                # per item did so from a fact it verified about that item, and
                # the verified fact is the one to keep.
                print_item(name, item["title"], item["url"], item["date"], item["summary"],
                           item.get("substance") or substance, item.get("entity"))
                total += 1

    print(f"\n---\n*End of fetched content — {total} total items*")
    write_records()
    print(f"Total fetched: {total} items", file=sys.stderr)


if __name__ == "__main__":
    main()
