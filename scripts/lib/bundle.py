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
import html
import re
from urllib.parse import urlsplit, urlunsplit

# Query parameters whose name starts with this are tracking, never identity.
_TRACKING_PREFIX = "utm_"

# Tag-like runs only. A bare `<` in prose ("scale to < 5ms") is left alone: it
# is not markup, and anything rendering this escapes it anyway.
_TAG_RE = re.compile(r"<[a-zA-Z/!][^>]*>")


def clean_text(s: str) -> str:
    """Decode HTML entities, then strip any markup that decoding produced.

    **The order is the safety property, not a style choice.** `html.unescape`
    turns `&lt;script&gt;` into `<script>` — decoding is what *creates* markup —
    so the tag strip has to run after it, never before. Decode once, then strip.

    Deliberately a single unescape pass rather than a loop to a fixed point.
    Double-encoded input (`&amp;lt;script&amp;gt;`) decodes to the inert text
    `&lt;script&gt;` and stops there; chasing it further would reconstruct the
    exact tag this function exists to remove.

    Lives here rather than in the producer so that `item_record` is safe when
    called directly, not only when reached through `fetch_sources.print_item`.
    A sanitiser that only runs on one of two call paths is the kind of guard
    that reports success because it never ran.
    """
    if not s:
        return ""
    return re.sub(r"\s+", " ", _TAG_RE.sub(" ", html.unescape(s))).strip()


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


# ── the publisher summary as a card body ─────────────────────────────────────
#
# Rung two of the card's fallback ladder. Measured over 1,577 distinct items
# from the stored bundles before any of these rules were written:
#
#   21.8%  end mid-word — feeds truncate to a character budget, not a sentence
#    7.1%  contain a bare url
#    6.3%  carry a `[…]` elision marker
#    4.3%  end in "The post X appeared first on Y" (WordPress feed boilerplate)
#    2.8%  end in a read-more or subscribe call to action
#
# The single most consequential finding was not in that list. Hacker News items
# have no summary at all — the field holds `Article URL: … Comments URL: …
# Points: N # Comments: M`, which cleared the pool's 80-character bar purely on
# the length of two urls. Every one of those would have become a card whose body
# read "Article URL: Comments URL: Points: 3 # Comments: 0". Lobsters is the
# same shape, with the word "Comments" as the entire summary.
#
# So this does not only tidy: it makes the quality bar mean what it says, by
# measuring characters a reader could actually use.

_BOILERPLATE_RE = re.compile(r"\s*\bThe post\b.*?\bappeared first on\b.*$", re.I | re.S)
_CTA_RE = re.compile(
    r"\s*\b(read more|continue reading|read the full (story|article|post)"
    r"|sign up for|subscribe to|the post appeared first)\b.*$", re.I | re.S)
_BARE_URL_RE = re.compile(r"\s*https?://\S+")
_ELISION_RE = re.compile(r"\s*\[(?:…|\.\.\.)\]\s*")
_TRAILING_ELLIPSIS_RE = re.compile(r"\s*(?:…|\.\.\.)\s*$")

# Aggregator field furniture. These are labels, not prose, and they survive url
# removal — which is exactly how they cleared the length bar.
_AGGREGATOR_RE = re.compile(
    r"(Article URL|Comments URL|Points|#\s*Comments|Comments)\s*:\s*\d*", re.I)
_LONE_COMMENTS_RE = re.compile(r"^\s*Comments\s*$", re.I)

# The last position where a sentence genuinely ends, closing quote included.
#
# Three details, each of which was a wrong answer first:
#
# 1. The closing quote is *matched*, not looked ahead. A lookahead leaves it
#    outside the result and emits `He said "it works.` — a broken quotation on
#    a public card.
# 2. `(?<!\.)` excludes a dot that follows another dot, so `...` is not a
#    sentence end. Without it the trim cut at the final dot of an internal
#    ellipsis and *reintroduced* a trailing `...` that the rule above had
#    already removed — which also made the whole function non-idempotent, so
#    re-running the pool migration kept eating text.
# 3. The `(?=\s|$)` lookahead is what keeps "Inc. announced" and "v1.2.3" from
#    reading as terminal.
_LAST_SENTENCE_RE = re.compile(r"^.*(?<!\.)[.!?][\"')\]]?(?=\s|$)", re.S)


def sanitise_summary(summary: str) -> str:
    """The publisher's summary, reduced to what can honestly go on a card.

    Returns "" when nothing usable survives. That is a result, not a failure:
    the card ladder falls to the title, and a caller that treats "" as an error
    has misread which rung it is on.

    Order is load-bearing at two points. Boilerplate and the call-to-action tail
    go **before** the sentence trim, or the trim happily preserves "…appeared
    first on LeadDev." as the final sentence. Urls go before whitespace is
    collapsed, so removing one does not weld the words on either side together.

    The sentence trim is the only lossy rule and it is applied last. Roughly
    6.5% of items still end mid-word afterwards — those had no sentence boundary
    to trim back to, and keeping a slightly clipped real sentence beats
    returning nothing.
    """
    if not summary:
        return ""
    s = clean_text(summary)
    s = _LONE_COMMENTS_RE.sub("", s)
    s = _BOILERPLATE_RE.sub("", s)
    s = _CTA_RE.sub("", s)
    s = _BARE_URL_RE.sub(" ", s)
    s = _AGGREGATOR_RE.sub(" ", s)
    s = _ELISION_RE.sub(" ", s)
    s = re.sub(r"\s+", " ", s).strip()
    s = _TRAILING_ELLIPSIS_RE.sub("", s).strip()
    # Leading punctuation left behind by a removal, e.g. a summary that opened
    # with a url followed by a dash.
    s = re.sub(r"^[\s\-–—:;,.]+", "", s)
    match = _LAST_SENTENCE_RE.match(s)
    if match:
        s = match.group(0).strip()
    return s


def display_url(url: str) -> str:
    """The url a reader clicks and copies: tracking removed, nothing else touched.

    **Deliberately NOT `normalize_url`, and this is the whole point of it
    existing.** `normalize_url` builds a fingerprint — it also drops the
    fragment, strips the trailing slash and lowercases the host. Those are right
    for answering "have I seen this before?" and wrong for a link someone
    clicks: dropping the fragment turns `…/updates/anthropic#2.1.219` into a
    link to the wrong version. No card in the pool carries a fragment today, so
    reusing the fingerprint function here would break links silently and only
    later.

    So this touches the query string and nothing else. Same `utm_` rule as
    `normalize_url`, same reason it is only `utm_`: extend it when another
    tracker is actually observed in the corpus, not before. Measured across the
    live pool, the only query parameters present were four `utm_*` keys and a
    single `source=`, which is left alone because it may be functional routing.

    **Why strip at all**, given the tags belong to the publisher. Passing
    `utm_source=infoq&utm_medium=feed` through does not credit the publisher —
    it tells their analytics the reader came from *their own feed*, because
    analytics trusts those tags over the referrer. The feed is therefore
    invisible in the numbers of the one publisher most likely to notice it.
    Removing them lets the ordinary referrer through instead. This is also why
    outbound links carry `rel="noopener external"` and deliberately NOT
    `noreferrer`, which would suppress that signal and undo the same thing.

    Leaves the id untouched: `item_id` hashes `normalize_url`, which already
    drops `utm_`, so cleaning here cannot re-key the pool or the ledger.
    """
    url = (url or "").strip()
    if not url:
        return ""
    try:
        parts = urlsplit(url)
    except ValueError:
        return url
    if not parts.query:
        return url
    query = "&".join(
        p for p in parts.query.split("&")
        if p and not p.split("=", 1)[0].lower().startswith(_TRACKING_PREFIX)
    )
    return urlunsplit((parts.scheme, parts.netloc, parts.path, query, parts.fragment))


def item_record(source: str, title: str, url: str, date: str, summary: str) -> dict:
    """The structured twin of `format_item`, from the same arguments.

    `source` IS emitted here, unlike in the bundle, where printing it would
    change the nightly wire format. A consumer needs to know which feed an item
    came from — per-source caps and diversity limits are unenforceable without
    it — and a sidecar has no prompt to disturb.

    The summary is sanitised here and deliberately **not** in `format_item`.
    The card body *is* the summary, so it has to be reader-ready; the digest
    bundle is read by a model that copes with a truncated sentence perfectly
    well, and trimming it there would discard content the synthesis might use
    for no gain. This asymmetry is the same one `source` already established.
    """
    return {
        # Hashed from the ORIGINAL url, not the cleaned one. They agree today
        # because normalize_url drops `utm_` too — asserted in the tests — but
        # deriving the id from a value another rule may later change is how a
        # ledger silently re-keys and republishes everything.
        "id": item_id(url),
        "source": source,
        "title": title,
        "url": display_url(url),
        "date": date,
        "summary": sanitise_summary(summary),
    }
