"""The producer wire format — one copy, shared by every producer.

`run-job.sh` validates a bundle on a `^URL:` check and every prompt is written
against these exact field labels, so the format is a contract between the
producers (`fetch_sources.py`, `studio/select_corpus.py`) and the prompts. Two
copies of a format that must agree is the drift class this project has already
paid for once; this module is the single copy.

Pure stdlib, no I/O, no argparse — importable from anywhere.
"""
from __future__ import annotations

import re
from urllib.parse import urlsplit, urlunsplit

# Query parameters whose name starts with this are tracking, never identity.
_TRACKING_PREFIX = "utm_"


def format_item(source: str, title: str, url: str, date: str, summary: str) -> str:
    """Return one item block, including its trailing blank line.

    `source` is accepted and never emitted — that is deliberate, not a missing
    line: the caller passes it, and printing it would change the nightly wire
    format and therefore digest quality.
    """
    lines = [f"**{title}**", f"URL: {url}"]
    if date and date != "recent":
        # Uppercase DATE: for event-mode values (ISO dates and UNKNOWN),
        # legacy lowercase Date: for RSS publication dates.
        label = "DATE" if (date == "UNKNOWN" or re.match(r"\d{4}-\d{2}-\d{2}$", date)) else "Date"
        lines.append(f"{label}: {date}")
    if summary:
        lines.append(f"Summary: {summary}")
    lines.append("")
    return "\n".join(lines) + "\n"


def normalize_url(url: str) -> str:
    """Return a stable identity string for `url`.

    The whole rule:

    1. surrounding whitespace is dropped;
    2. scheme and netloc are lowercased (both are case-insensitive; the path is
       not, and is left exactly as given);
    3. the fragment is dropped;
    4. query parameters whose name begins with `utm_`, case-insensitively, are
       dropped; every other parameter is kept, in its original order and
       original encoding;
    5. trailing `/` is stripped from the path, so a bare domain normalizes with
       no path at all and `…/a/` and `…/a` agree.

    Only `utm_*` counts as tracking, and the query as a whole is *not* dropped:
    this project fetches Hacker News, where `item?id=…` is the entire identity,
    so dropping the query would collapse every HN item onto one key. Other
    trackers (`fbclid`, `gclid`) are deliberately not handled — extend the rule
    when one is actually observed in the corpus. A false-distinct key costs a
    duplicate; a false-same key costs an item.

    Known consequence of (3): releasebot items are `…/updates/anthropic#2.1.219`,
    where the fragment *is* the version, so every version of one product
    normalizes to the same string. That is what stripping the fragment means
    here; a consumer needing per-version identity must carry the title too.

    Not a validator. Input that is not a URL, or is empty, comes back trimmed
    rather than rejected — a producer must not die on one odd scraped href.
    """
    url = (url or "").strip()
    if not url:
        return ""
    try:
        parts = urlsplit(url)
    except ValueError:
        return url
    query = "&".join(
        p for p in parts.query.split("&")
        if p and not p.split("=", 1)[0].lower().startswith(_TRACKING_PREFIX)
    )
    return urlunsplit(
        (parts.scheme.lower(), parts.netloc.lower(), parts.path.rstrip("/"), query, "")
    )
