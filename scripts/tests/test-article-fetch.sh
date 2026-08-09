#!/bin/bash
# E8 — fetching the article the house voice writes from.
#
# Without this the model only ever sees the publisher's blurb, and a "house
# summary" is a paraphrase of a paraphrase: original prose, which removes the
# quotation exposure, but no information the reader did not already have — and
# thin input is exactly where a model invents a detail.
#
# Two rules under test, both set by the owner:
#
#   1. A long article is not cut at a character count. The opening paragraphs
#      are used instead, because a character cut ends mid-sentence and hands the
#      model a fragment that stops nowhere.
#   2. A page that is mostly video or audio is NOT a failure. It gets a short
#      card and the publisher's link, unchanged. Classifying it `media` is what
#      keeps a video round-up from silently dropping to the publisher-blurb rung.
#
# The HTTP client is stubbed throughout — no network, no writes, no git.
#
#   bash scripts/tests/test-article-fetch.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

if ! "$PYBIN" -c 'import bs4' 2>/dev/null; then
  printf "  \033[33mskip\033[0m  beautifulsoup4 unavailable in %s\n" "$PYBIN"
  exit 0
fi

"$PYBIN" - "$REPO_DIR" <<'PY'
import sys
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "scripts" / "lib"))
import article_fetch as af

FAIL = 0; COUNT = 0
def ok(m):
    global COUNT; COUNT += 1; print(f"  \033[32mok\033[0m    {m}")
def bad(m):
    global FAIL, COUNT; COUNT += 1; FAIL = 1; print(f"  \033[31mFAIL\033[0m  {m}")
def chk(label, got, want):
    ok(label) if got == want else bad(f"{label} (got {got!r}, wanted {want!r})")


def stub(html, status=200, ctype="text/html; charset=utf-8", raises=None):
    class Resp:
        status_code = status
        text = html
        headers = {"content-type": ctype}
    class Client:
        def __enter__(self):
            if raises: raise raises
            return self
        def __exit__(self, *a): return False
        def get(self, url):
            if raises: raise raises
            return Resp()
    return lambda: Client()


PARA = "This is a real paragraph of article prose with enough length to count. "
def page(n_paras, extra="", tag="article"):
    body = "".join(f"<p>{PARA}{i}</p>" for i in range(n_paras))
    return f"<html><body>{extra}<{tag}>{body}</{tag}></body></html>"


print("── extraction keeps prose and drops furniture ────────────────────────────")
chk("paragraphs are returned as a list", type(af.extract_text(page(3))), list)
chk("three real paragraphs survive", len(af.extract_text(page(3))), 3)
chk("a short paragraph is dropped as furniture",
    len(af.extract_text("<html><article><p>Share this</p><p>" + PARA + "</p></article></html>")), 1)
for junk in ("script", "style", "nav", "footer", "aside", "noscript"):
    html = f"<html><body><{junk}><p>{PARA}JUNK</p></{junk}><article><p>{PARA}real</p></article></body></html>"
    if any("JUNK" in p for p in af.extract_text(html)):
        bad(f"<{junk}> content leaked into the extraction")
        break
else:
    ok("script, style, nav, footer, aside and noscript are all stripped")
# A JavaScript-only page puts its "enable JavaScript" notice in a <noscript>.
# Without stripping it, that notice becomes the article.
chk("an empty document yields nothing", af.extract_text(""), [])
chk("unparseable input does not raise", af.extract_text("<<<>>>") is not None, True)

print("── rule 1: a long article uses its opening paragraphs ────────────────────")
lead = ["The opening paragraph carries the news and ends properly.",
        "The second adds the number and the name that matter here."]
rest = [f"Filler paragraph {i} that no summary needs at all whatsoever." for i in range(400)]

chk("a short article is sent whole",
    af.trim_to_lead(lead + rest[:1]), " ".join(lead + rest[:1]))
long_out = af.trim_to_lead(lead + rest)
chk("a long article is cut to the first two paragraphs", long_out, " ".join(lead))
# The whole point of paragraph-wise trimming rather than a character slice.
chk("and it ends on a sentence boundary, not mid-word", long_out.endswith("here."), True)
chk("the result is far smaller than the input",
    len(long_out) < len(" ".join(lead + rest)) / 10, True)
chk("no paragraphs yields empty, not an error", af.trim_to_lead([]), "")
# One enormous paragraph is the only case where a cut can land mid-sentence.
chk("a single huge paragraph is still bounded",
    len(af.trim_to_lead(["x" * 99_999])), af.MAX_ARTICLE_CHARS)

print("── rule 2: a media page is a card, not a failure ─────────────────────────")
THIN = "<html><body><article><p>" + PARA + "</p></article></body></html>"
text, kind, reason = af.fetch_article("https://x.com/a", stub(THIN))
chk("a thin page with no media is refused", (kind, reason), ("", "too_thin"))

for embed in ('<iframe src="https://www.youtube.com/embed/abc"></iframe>',
              '<video src="a.mp4"></video>',
              '<iframe src="https://player.vimeo.com/video/1"></iframe>',
              '<meta property="og:video" content="https://x/v.mp4">',
              '<iframe src="https://open.spotify.com/embed/episode/1"></iframe>'):
    _, kind, reason = af.fetch_article("https://x.com/a", stub(
        "<html><body>" + embed + "<article><p>" + PARA + "</p></article></body></html>"))
    if (kind, reason) != ("media", "ok"):
        bad(f"embed not recognised as media: {embed[:40]} -> {(kind, reason)}")
        break
else:
    ok("video, audio and player embeds all classify as media")

text, kind, reason = af.fetch_article("https://x.com/a", stub(
    '<html><body><video src="a.mp4"></video><article><p>' + PARA + "</p></article></body></html>"))
chk("a media card still carries the prose it did find", len(text) > 0, True)
# Detection must read the raw html: extraction strips <iframe> and <video>, so
# asking after extraction would always answer no.
chk("media detection survives extraction stripping the embed", kind, "media")

long_media = "<html><body><video src=a.mp4></video><article>" + \
             "".join(f"<p>{PARA}{i}</p>" for i in range(400)) + "</article></body></html>"
_, kind, _ = af.fetch_article("https://x.com/a", stub(long_media))
chk("a page with plenty of prose AND a video is an article, not media", kind, "article")

print("── it never raises, whatever happens ─────────────────────────────────────")
chk("a 404 is reported, not raised",
    af.fetch_article("https://x.com/a", stub("", status=404))[2], "http_error")
chk("a non-html content type is refused",
    af.fetch_article("https://x.com/a", stub(page(9), ctype="application/pdf"))[2], "not_html")
chk("a network error is reported, not raised",
    af.fetch_article("https://x.com/a", stub("", raises=OSError("boom")))[2], "network_error")
chk("a javascript: url never reaches the network",
    af.fetch_article("javascript:alert(1)", stub(page(30)))[2], "unsafe_url")
chk("a data: url never reaches the network",
    af.fetch_article("data:text/html,<b>x", stub(page(30)))[2], "unsafe_url")
chk("an empty url is refused", af.fetch_article("", stub(page(30)))[2], "unsafe_url")
chk("every reason returned is in the vocabulary",
    af.fetch_article("https://x.com/a", stub(page(30)))[2] in af.FETCH_REASONS, True)
chk("every kind returned is in the vocabulary",
    af.fetch_article("https://x.com/a", stub(page(30)))[1] in af.FETCH_KINDS, True)

# The contract the caller depends on: text is empty whenever reason is not ok.
for html, status in ((page(9), 404), ("", 200), (THIN, 200)):
    t, k, r = af.fetch_article("https://x.com/a", stub(html, status=status))
    if r != "ok" and t != "":
        bad(f"text returned alongside reason {r!r}")
        break
else:
    ok("text is empty whenever the reason is not 'ok'")

print("── the happy path ────────────────────────────────────────────────────────")
text, kind, reason = af.fetch_article("https://x.com/a", stub(page(30)))
chk("a normal article succeeds", (kind, reason), ("article", "ok"))
# The bug this fixture was too small to catch: a long article gets trimmed to
# its lead, and if the minimum is measured on the TRIMMED text every long
# article is judged too thin and demoted to media.
_t, _k, _r = af.fetch_article("https://x.com/a", stub(page(400)))
chk("a LONG article is still an article, not too_thin", (_k, _r), ("article", "ok"))
chk("and only its lead is sent", len(_t) < 400, True)
chk("and returns its prose", PARA.strip() in text, True)
chk("fetch_many returns one triple per url",
    sorted(af.fetch_many(["https://a.com/x", "https://b.com/y"], stub(page(30)))),
    ["https://a.com/x", "https://b.com/y"])

print()
if FAIL == 0:
    print(f"\033[32mPASS\033[0m ({COUNT}) — article fetch tests passed")
else:
    print(f"\033[31mFAIL\033[0m — article fetch tests FAILED ({COUNT} assertions run)")
sys.exit(FAIL)
PY
