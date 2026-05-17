#!/usr/bin/env python3
"""
Fetch tiered news sources for a given topic and print structured content to stdout.
No Anthropic API — pure HTTP. Output is piped to claude for synthesis.

Usage:
  python3 scripts/fetch_sources.py --topic ai           # last 24 hours (daily)
  python3 scripts/fetch_sources.py --topic ai --weekly  # last 7 days (Saturday)
  python3 scripts/fetch_sources.py --topic leadership --weekly
"""

import argparse
import calendar
import os
import re
import sys
from datetime import datetime, timedelta, timezone
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
args = parser.parse_args()

IS_WEEKLY = args.weekly
LOOKBACK  = timedelta(days=7 if IS_WEEKLY else 1)
SINCE     = datetime.now(tz=timezone.utc) - LOOKBACK

SCRIPT_DIR = Path(__file__).parent
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

def print_item(source: str, title: str, url: str, date: str, summary: str) -> None:
    print(f"**{title}**")
    print(f"URL: {url}")
    if date and date != "recent":
        print(f"Date: {date}")
    if summary:
        print(f"Summary: {summary}")
    print()


# ── Releasebot.io ─────────────────────────────────────────────────────────────
# Targets <h2 class="text-h2 ..."> version headings; grabs release notes from
# the sibling .prose div.

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
               title_sel=None) -> list[dict]:
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
            items.append({"title": title, "url": href, "date": "recent", "summary": summary})
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


def fetch(name: str, kind: str, url: str, max_items: int) -> list[dict]:
    print(f"  {name}", file=sys.stderr)
    if kind == "releasebot":
        return fetch_releasebot(name, url, max_items)
    if kind == "github":
        return fetch_github_trending(max_items)
    if kind in ("rss", "atom"):
        return fetch_rss(name, url, max_items)
    return fetch_html(name, url, max_items)


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
            name      = src["name"]
            kind      = src["kind"]
            url       = src["url"]
            max_items = src.get("max_items", 10)
            filter_re = src.get("filter_regex")
            filter_cap = src.get("filter_cap")

            items = fetch(name, kind, url, max_items)

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
    print(f"Total fetched: {total} items", file=sys.stderr)


if __name__ == "__main__":
    main()
