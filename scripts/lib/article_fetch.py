"""Fetch an article and extract its readable text — the input the house voice writes from.

Without this the model only ever sees the publisher's own blurb, and a "house
summary" is then a paraphrase of a paraphrase: it buys original prose, which
removes the quotation exposure, but it adds nothing a reader did not already
have and it is exactly the situation where a model invents a detail to fill
space. Summarising the actual article is what makes the word "enhanced" true.

**Measured on the seven items the feed would have published on 2026-08-09,
before any of this was written:** 6 of 7 extracted usable text, every request
returned 200, none hit a paywall, and the slowest took 1.0s. The seventh was a
video round-up whose page genuinely is mostly embedded players — 257 characters
of prose. That is not an extraction failure, it is an article with nothing to
summarise, and it must degrade to the publisher-summary rung rather than
producing a confident paragraph about a page nobody read.

One measurement drove the cap: a podcast episode page yielded 55,078 characters.
Sending that to a model to produce two sentences is most of a nightly bill for
no gain.

Runs at selection, over the chosen seven — not at admission over everything.
Only items that will actually publish are worth fetching, and the summary is
then written the same night it appears.

Network, and therefore deliberately separate from every other module here, all
of which are offline and reproducible.
"""
from __future__ import annotations

import re

# Below this there is not enough prose to write a full card from. It does not
# mean the item is dropped — see MEDIA below. Set from the probe: the six usable
# articles ran 3,906–55,078 characters and the seventh 257.
MIN_ARTICLE_CHARS = 1_200

# Past this the article is not sent whole. Rather than cutting at a character
# count — which lands mid-sentence, mid-thought, and hands the model a fragment
# that ends nowhere — the opening paragraphs are used instead. News prose is
# written inverted-pyramid, so the top of the piece is where the substance is,
# and a clean stop at a paragraph boundary is better input than a longer
# fragment. The podcast page that yielded 55,078 characters is the case this
# exists for.
MAX_ARTICLE_CHARS = 12_000
LEAD_PARAGRAPHS = 2

# A page can be worth linking to and have almost no prose: a video round-up, a
# conference talk, a gallery, a podcast episode. Those are not extraction
# failures and must not be treated as one — the item still deserves a card, with
# a short summary and the link left exactly as the publisher wrote it, opening
# in a new tab like every other card. Anything below MIN_ARTICLE_CHARS that
# carries embedded media is classified `media` rather than discarded.
MEDIA_EMBED_RE = re.compile(
    r"<(?:video|audio)\b|<iframe[^>]+(?:youtube|youtu\.be|vimeo|wistia|spotify"
    r"|soundcloud|libsyn|megaphone|simplecast|buzzsprout)|"
    r"(?:og:video|twitter:player)", re.I)

# What a card was written from. `media` is a first-class outcome, not a
# degraded one.
FETCH_KINDS = ("article", "media", "")

# A paragraph shorter than this is a caption, a byline, a cookie notice or a
# "share this" line, not prose.
MIN_PARAGRAPH_CHARS = 40

FETCH_TIMEOUT = 15

# Stripped before extraction. `noscript` matters more than it looks: a
# JavaScript-only page often puts "please enable JavaScript" inside one, and
# without this that becomes the article.
_DROP_TAGS = ("script", "style", "nav", "header", "footer", "aside", "form",
              "noscript", "iframe", "svg", "button", "figcaption")

# Not a paywall detector — a paywall *marker*. A page can carry this text and
# still have served the whole article, so it downgrades confidence rather than
# rejecting outright; the length check is what actually decides.
_PAYWALL_RE = re.compile(
    r"subscribe to (?:continue|read)|already a (?:member|subscriber)"
    r"|this (?:article|story) is for subscribers|create a free account to"
    r"|sign in to (?:continue|read)", re.I)

_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                  "AppleWebKit/537.36 (KHTML, like Gecko) "
                  "Chrome/124.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
}

# Every way this can decline to produce text. A closed vocabulary so the caller
# can count reasons rather than log strings, and so a new failure mode has to be
# named rather than folded into "other".
FETCH_REASONS = ("ok", "unsafe_url", "http_error", "not_html", "too_thin",
                 "network_error", "no_client")


def extract_text(html: str) -> list[str]:
    """Readable prose from an HTML document. Never raises.

    Deliberately heuristic and dependency-free rather than a readability
    library. The sources are a fixed, known list of about thirty feeds; a
    general-purpose extractor solves a harder problem than this one has, and the
    failure mode here is bounded — bad extraction yields short text, and short
    text falls back to the publisher's summary.
    """
    if not html:
        return []
    try:
        from bs4 import BeautifulSoup
    except ImportError:
        return []
    try:
        soup = BeautifulSoup(html, "html.parser")
    except Exception:                                   # noqa: BLE001
        return []

    for tag in soup(list(_DROP_TAGS)):
        tag.decompose()

    # An explicit article container when the page offers one, otherwise the
    # block holding the most direct paragraph text. Picking by paragraph density
    # rather than total text is what keeps a sidebar of headlines from winning.
    node = (soup.find("article")
            or soup.find(attrs={"role": "main"})
            or soup.find("main"))
    if node is None:
        best, best_len = None, 0
        for cand in soup.find_all(["div", "section"]):
            direct = cand.find_all("p", recursive=False)
            n = sum(len(p.get_text(" ", strip=True)) for p in direct)
            if n > best_len:
                best, best_len = cand, n
        node = best or soup

    paras = [re.sub(r"\s+", " ", p.get_text(" ", strip=True))
             for p in node.find_all("p")]
    return [p for p in paras if len(p) >= MIN_PARAGRAPH_CHARS]


def trim_to_lead(paragraphs: list[str],
                 max_chars: int = MAX_ARTICLE_CHARS,
                 lead: int = LEAD_PARAGRAPHS) -> str:
    """Whole paragraphs, and the opening ones when the piece is long.

    Under the cap the article goes whole. Over it, the first `lead` paragraphs
    are used rather than a slice of the first `max_chars` characters. A
    character cut ends mid-sentence and gives the model a fragment that stops
    nowhere; the top of a news piece is where the substance is, and it stops
    where the author meant it to.

    The final clamp is a backstop for the pathological case of one enormous
    paragraph, and it is the only place a cut can land mid-sentence.
    """
    if not paragraphs:
        return ""
    whole = " ".join(paragraphs).strip()
    if len(whole) <= max_chars:
        return whole
    return " ".join(paragraphs[:lead]).strip()[:max_chars]


def fetch_article(url: str, client_factory=None,
                  min_chars: int = MIN_ARTICLE_CHARS) -> tuple[str, str, str]:
    """Return (text, kind, reason). `text` is "" whenever reason != "ok".

    `kind` is `article` when there is enough prose to write a full card from,
    and `media` when there is not but the page carries embedded video, audio or
    a player. A media page is a normal outcome with a short card, not a failure:
    the item still gets a summary of a line or two and the publisher's link,
    unchanged, opening in a new tab exactly like every other card.

    **Never raises, for any input, ever.** This runs inside the nightly job
    between selection and publication. A summary that cannot be written costs
    one card its top rung; an exception escaping here costs the whole edition,
    which is the trade this project has already paid for once.

    `client_factory` is injected so the test suite can run the whole path with
    no network.
    """
    from bundle import is_safe_url

    if not is_safe_url(url):
        return "", "", "unsafe_url"

    if client_factory is None:
        try:
            import httpx
        except ImportError:
            return "", "", "no_client"

        def client_factory():
            return httpx.Client(timeout=FETCH_TIMEOUT, headers=_HEADERS,
                                follow_redirects=True)

    try:
        with client_factory() as client:
            resp = client.get(url)
        status = getattr(resp, "status_code", 0)
        if status != 200:
            return "", "", "http_error"
        # A PDF or an image would otherwise be fed to the HTML parser and yield
        # confident nonsense.
        ctype = ""
        headers = getattr(resp, "headers", None)
        if headers is not None:
            try:
                ctype = (headers.get("content-type") or "").lower()
            except Exception:                           # noqa: BLE001
                ctype = ""
        if ctype and "html" not in ctype:
            return "", "", "not_html"
        html = getattr(resp, "text", "") or ""
        # Media detection reads the RAW html, before extraction: extract_text
        # strips <iframe> and <video>, so asking afterwards would always say no.
        is_media = bool(MEDIA_EMBED_RE.search(html))
        paragraphs = extract_text(html)
        # Two different questions, and conflating them was a real bug: "is there
        # enough article here to write from?" is asked of the WHOLE piece, while
        # "what do we send?" is the trimmed lead. Measuring the trimmed text
        # instead meant every article long enough to be trimmed was then judged
        # too thin and demoted to media — the exact opposite of the intent, and
        # it fired on a real page before the tests caught it.
        prose_chars = len(" ".join(paragraphs))
        text = trim_to_lead(paragraphs)
    except Exception:                                   # noqa: BLE001
        return "", "", "network_error"

    if prose_chars >= min_chars:
        return text, "article", "ok"
    if is_media:
        # Whatever prose exists is returned even though it is under the bar. It
        # is usually the standfirst, which is exactly what a one-line summary of
        # a video should be written from — and it is far better than writing
        # that line from the headline alone.
        return text, "media", "ok"
    return "", "", "too_thin"


def has_paywall_marker(html: str) -> bool:
    """Advisory only — see the note on `_PAYWALL_RE`."""
    return bool(html) and bool(_PAYWALL_RE.search(html[:200_000]))


def fetch_many(urls: list[str], client_factory=None) -> dict[str, tuple[str, str]]:
    """Sequential on purpose. Seven requests a night to seven different hosts is
    not worth a thread pool, and sequential keeps the per-host rate obviously
    polite without a scheduler to reason about.
    """
    return {u: fetch_article(u, client_factory) for u in urls}
