"""The producer wire format — one copy, shared by every producer.

`run-job.sh` validates a bundle on a `^URL:` check and every prompt is written
against these exact field labels, so the format is a contract between the
producers (`fetch_sources.py`, `studio/select_corpus.py`) and the prompts. Two
copies of a format that must agree is the drift class this project has already
paid for once; this module is the single copy.

Pure stdlib, no I/O, no argparse — importable from anywhere.
"""
from __future__ import annotations

import hashlib
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


# The record sidecar — structured identity for consumers that are not a prompt.
#
# The bundle above is written for a language model: labelled prose, lossy on
# purpose. A feed needs the same items as data, with a key that survives
# rebuilds and can be deduplicated against. Rather than parse the prose back —
# two readers of one format is the drift this module exists to prevent — the
# producer emits both from the same call site.

RECORD_FIELDS = ("id", "source", "title", "url", "date", "summary")


def item_id(url: str) -> str:
    """A stable 12-hex-char identity for `url`, or "" when there is no url.

    sha256 over `normalize_url`, truncated. Two properties matter and neither is
    cryptographic:

    1. **Stable across runs and machines.** It is a pure function of the
       normalized url, so a rebuild produces the same key and a ledger written
       last month still matches today's fetch.
    2. **Usable as a permalink fragment.** Hex, fixed width, no escaping. The
       deduplication key and the anchor are therefore the same string, which is
       the point: two identifiers for one item eventually disagree, and the
       disagreement surfaces as a duplicate card or a dead link.

    48 bits. At corpus scale — tens of thousands of items — the birthday
    probability of a collision is on the order of 1e-5, and the cost of one is a
    single item silently treated as already-seen. Widen the slice before that
    trade stops being acceptable; do not widen it after.

    Inherits `normalize_url`'s fragment rule, so releasebot-style urls that
    differ only by `#version` share one id. Those sources are excluded from the
    feed for an unrelated reason (they carry no summary), but a future consumer
    that wants per-version identity must carry the title too.
    """
    norm = normalize_url(url)
    if not norm:
        return ""
    return hashlib.sha256(norm.encode("utf-8")).hexdigest()[:12]


def item_record(source: str, title: str, url: str, date: str, summary: str) -> dict:
    """The structured twin of `format_item`, from the same arguments.

    `source` IS emitted here, unlike in the bundle, where printing it would
    change the nightly wire format. A consumer needs to know which feed an item
    came from — per-source caps and diversity limits are unenforceable without
    it — and a sidecar has no prompt to disturb.
    """
    return {
        "id": item_id(url),
        "source": source,
        "title": title,
        "url": url,
        "date": date,
        "summary": summary,
    }
