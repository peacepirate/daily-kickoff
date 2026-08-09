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
parser.add_argument("--topic", required=True, help="Topic name (must match scripts/topics/TOPIC.yaml)")
parser.add_argument("--weekly", action="store_true", help="Use 7-day lookback window instead of 24h")
parser.add_argument("--records", metavar="PATH",
                    help="Also write a JSONL record per item to PATH (structured twin of the bundle)")
args = parser.parse_args()

IS_WEEKLY = args.weekly
LOOKBACK  = timedelta(days=7 if IS_WEEKLY else 1)
SINCE     = datetime.now(tz=timezone.utc) - LOOKBACK
TODAY     = datetime.now(tz=timezone.utc).date()
EVENT_WINDOW_START = TODAY + timedelta(days=2)   # Monday after Saturday run
EVENT_WINDOW_END   = TODAY + timedelta(days=30)

SCRIPT_DIR = Path(__file__).parent
# scripts/lib carries the shared wire format. Put it on the path rather than
# making scripts/ a package, so a producer at any depth (studio/) imports it
# the same way and no invocation depends on the caller's cwd.
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from bundle import format_item, item_record  # noqa: E402  — needs the path line above

CONFIG_PATH = SCRIPT_DIR / "topics" / f"{args.topic}.yaml"
if not CONFIG_PATH.exists():
    print(f"ERROR: Topic config not found: {CONFIG_PATH}", file=sys.stderr)
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


def print_item(source: str, title: str, url: str, date: str, summary: str) -> None:
    print(format_item(source, title, url, date, summary), end="")
    if args.records:
        RECORDS.append(item_record(source, title, url, date, summary))


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


def fetch(name: str, kind: str, url: str, max_items: int,
          event_mode: bool = False) -> list[dict]:
    print(f"  {name}", file=sys.stderr)
    if kind == "releasebot":
        return fetch_releasebot(name, url, max_items)
    if kind == "github":
        return fetch_github_trending(max_items)
    if kind in ("rss", "atom"):
        return fetch_rss(name, url, max_items)
    return fetch_html(name, url, max_items, event_mode=event_mode)


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    topic_name = TOPIC_CONFIG.get("name", args.topic)
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
                print_item(name, item["title"], item["url"], item["date"], item["summary"])
                total += 1

    print(f"\n---\n*End of fetched content — {total} total items*")
    write_records()
    print(f"Total fetched: {total} items", file=sys.stderr)


if __name__ == "__main__":
    main()
