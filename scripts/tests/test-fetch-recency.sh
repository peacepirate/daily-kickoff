#!/bin/bash
# Ingestion repair — article recency filtering in scripts/fetch_sources.py.
#
# The recency cutoff used to be consulted in exactly one of the four fetch
# paths. fetch_html, fetch_releasebot and fetch_github_trending re-emitted their
# top-N page every night regardless of age, so two thirds of the ai bundle was
# content it had already served: six sources contributing 15.6 items a night
# yielded 1.6 new ones.
#
# fetch_html now drops what it can prove is stale. The load-bearing distinction
# is that "no date found" and "old" are different claims, and only one of them
# justifies dropping a story — so an article whose page marks up no date must
# still pass. Events keep their full-text date scan; articles do not get it,
# because a date an article merely mentions is not its publication date.
#
# No network: the HTTP client is stubbed. No LLM, no writes, no git.
#
#   bash scripts/tests/test-fetch-recency.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

if ! "$PYBIN" -c 'import yaml, bs4, feedparser, httpx' 2>/dev/null; then
  printf "  \033[33mskip\033[0m  deps unavailable in %s — run any kickoff command once\n" "$PYBIN"
  exit 0
fi

"$PYBIN" - "$REPO_DIR" <<'PY'
import sys, datetime, importlib.util
from datetime import timedelta

repo = sys.argv[1]
sys.argv = ["fetch_sources.py", "--topic", "ai"]

spec = importlib.util.spec_from_file_location("fs", f"{repo}/scripts/fetch_sources.py")
fs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fs)

from bs4 import BeautifulSoup

FAIL = 0
COUNT = 0
def ok(m):
    global COUNT; COUNT += 1; print(f"  \033[32mok\033[0m    {m}")
def bad(m):
    global FAIL, COUNT; COUNT += 1; FAIL = 1; print(f"  \033[31mFAIL\033[0m  {m}")
def chk(label, got, want):
    ok(label) if got == want else bad(f"{label} (got {got!r}, wanted {want!r})")

today = fs.TODAY
old   = today - timedelta(days=400)
fresh = today

def frag(html):
    return BeautifulSoup(html, "html.parser")

print("── extract_article_date: marked-up dates only ────────────────────────────")
chk("<time datetime> is read",
    fs.extract_article_date(frag(f'<article><time datetime="{old.isoformat()}">x</time></article>')), old)
chk("<time> inner text is read",
    fs.extract_article_date(frag(f'<article><time>{old.strftime("%B %d, %Y")}</time></article>')), old)
chk("a date-hinting css class is read",
    fs.extract_article_date(frag(f'<article><span class="post-date">{old.isoformat()}</span></article>')), old)
chk("a data-date attribute is read",
    fs.extract_article_date(frag(f'<article><div data-date="{old.isoformat()}">x</div></article>')), old)
chk("prose that merely mentions a date is NOT a publication date",
    fs.extract_article_date(frag('<article><p>Back in 2024-01-15 the team shipped it.</p></article>')), None)
chk("an article with no date at all yields None",
    fs.extract_article_date(frag('<article><h2>A title with no date anywhere</h2></article>')), None)

print("── extract_event_date: unchanged, still scans body text ──────────────────")
chk("an event listing still finds a body-text date",
    fs.extract_event_date(frag('<li><p>Join us on 2026-09-14 at the hall.</p></li>')),
    datetime.date(2026, 9, 14))
chk("marked-up dates still win for events",
    fs.extract_event_date(frag(f'<li><time datetime="{old.isoformat()}">x</time><p>2026-09-14</p></li>')), old)

print("── fetch_html drops the provably stale ───────────────────────────────────")
PAGE = f"""<html><body>
<article class="post"><h2>A stale headline that is long enough to pass</h2>
  <a href="/stale">x</a><time datetime="{old.isoformat()}">old</time>
  <p>{'s'*60}</p></article>
<article class="post"><h2>A fresh headline that is long enough to pass</h2>
  <a href="/fresh">x</a><time datetime="{fresh.isoformat()}">new</time>
  <p>{'f'*60}</p></article>
<article class="post"><h2>An undated headline that is long enough to pass</h2>
  <a href="/undated">x</a><p>{'u'*60}</p></article>
</body></html>"""

class FakeResp:
    text = PAGE
    def raise_for_status(self): pass
class FakeClient:
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def get(self, url): return FakeResp()

fs.client = lambda: FakeClient()
items = fs.fetch_html("Test", "https://example.com/news/", max_items=10)
urls = [i["url"].rsplit("/", 1)[-1] for i in items]

chk("the stale item is dropped", "stale" in urls, False)
chk("the fresh item is kept", "fresh" in urls, True)
chk("the undated item is kept", "undated" in urls, True)
chk("exactly two items survive", len(items), 2)

by = {i["url"].rsplit("/", 1)[-1]: i for i in items}
chk("a kept dated item carries its real date, not 'recent'",
    by["fresh"]["date"], fresh.strftime("%Y-%m-%d"))
chk("an undated item still reports 'recent'", by["undated"]["date"], "recent")

print("── event_mode is untouched by this change ────────────────────────────────")
EV = f"""<html><body>
<li class="event"><h3>An event happening within the forward window</h3>
  <a href="/ev1">x</a><time datetime="{(today + timedelta(days=10)).isoformat()}">d</time>
  <p>{'e'*60}</p></li>
<li class="event"><h3>An event that already happened last year</h3>
  <a href="/ev2">x</a><time datetime="{old.isoformat()}">d</time>
  <p>{'e'*60}</p></li>
</body></html>"""
class EvResp:
    text = EV
    def raise_for_status(self): pass
class EvClient:
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def get(self, url): return EvResp()
fs.client = lambda: EvClient()
evs = fs.fetch_html("Ev", "https://example.com/events/", max_items=10, event_mode=True)
ev_urls = [i["url"].rsplit("/", 1)[-1] for i in evs]
chk("a forthcoming event is kept", "ev1" in ev_urls, True)
chk("a past event is still dropped", "ev2" in ev_urls, False)

print("── clean_text: decode entities, then strip what decoding produced ────────")
# The order is the safety property. html.unescape is what CREATES markup, so
# strip-then-decode would emit a live tag. Every case below fails on the
# reversed order.
chk("a numeric entity is decoded", fs.clean_text("it&#8217;s here"), "it’s here")
chk("a named entity is decoded", fs.clean_text("AT&amp;T merger"), "AT&T merger")
chk("a hex entity is decoded", fs.clean_text("caf&#xe9; talk"), "café talk")
chk("an escaped script tag does NOT survive decoding",
    fs.clean_text("&lt;script&gt;alert(1)&lt;/script&gt;"), "alert(1)")
chk("a literal tag is stripped", fs.clean_text("a <b>bold</b> claim"), "a bold claim")
chk("an img tag with attributes is stripped",
    fs.clean_text('x <img src="a.png" onerror="alert(1)"> y'), "x y")
# Single pass, not a loop to a fixed point: chasing double-encoded input would
# reconstruct the tag this function exists to remove.
chk("double-encoded markup decodes to inert text and stops",
    fs.clean_text("&amp;lt;script&amp;gt;"), "&lt;script&gt;")
# A bare `<` is prose, not markup, and must survive.
chk("a bare less-than in prose survives", fs.clean_text("scale to < 5ms"), "scale to < 5ms")
chk("whitespace is collapsed", fs.clean_text("a\n\n  b\tc"), "a b c")
chk("empty input is empty, not None", fs.clean_text(""), "")
chk("None is tolerated", fs.clean_text(None), "")

# The invariant that matters after this runs: no output may contain a tag.
for probe in ("&lt;script&gt;x&lt;/script&gt;", "<script>x</script>",
              "&lt;iframe src=a&gt;", "plain text", "5 &lt; 7 &amp;&amp; 8 &gt; 6"):
    if fs._TAG_RE.search(fs.clean_text(probe)):
        bad(f"a tag survived clean_text: {probe!r} -> {fs.clean_text(probe)!r}")
        break
else:
    ok("no probe leaves a tag in the output")

print("── print_item cleans both the bundle and the sidecar ─────────────────────")
import io as _io, contextlib as _cl
fs.args.records = "unused"
fs.RECORDS.clear()
_buf = _io.StringIO()
with _cl.redirect_stdout(_buf):
    fs.print_item("Src", "Google Earth&#8217;s AI tool", "https://example.com/e",
                  "2026-08-08", "A summary with AT&amp;T in it")
_out = _buf.getvalue()
chk("the digest bundle carries no entity", "&#8217;" in _out, False)
chk("the digest bundle carries the decoded character", "Earth’s" in _out, True)
chk("the sidecar title is cleaned too", fs.RECORDS[0]["title"], "Google Earth’s AI tool")
chk("the sidecar summary is cleaned too", fs.RECORDS[0]["summary"], "A summary with AT&T in it")
# item_id hashes the url, so cleaning the text must not move any existing id —
# otherwise the whole pool and ledger would re-key and republish.
import importlib.util as _ilu
_bspec = _ilu.spec_from_file_location("bundle_mod", f"{repo}/scripts/lib/bundle.py")
_bundle = _ilu.module_from_spec(_bspec); _bspec.loader.exec_module(_bundle)
chk("the id is unchanged by cleaning",
    fs.RECORDS[0]["id"], _bundle.item_id("https://example.com/e"))
fs.args.records = None
fs.RECORDS.clear()

print("── the record sidecar cannot cost the digest anything ────────────────────")
import io, json, os, tempfile, contextlib

# The bundle on stdout is the contract the nightly digest depends on. The
# sidecar is an extra for a product that does not exist yet, so the only
# acceptable failure mode is: feed loses its records, digest loses nothing.
fs.args.records = None
fs.RECORDS.clear()
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    fs.print_item("Src", "A title", "https://example.com/x", "2026-08-08", "A summary")
without = buf.getvalue()

tmpdir = tempfile.mkdtemp()
fs.args.records = os.path.join(tmpdir, "sub", "rec.jsonl")
fs.RECORDS.clear()
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    fs.print_item("Src", "A title", "https://example.com/x", "2026-08-08", "A summary")
with_records = buf.getvalue()

chk("the bundle is byte-identical with and without --records", with_records, without)
chk("one record was captured", len(fs.RECORDS), 1)

fs.write_records()
chk("the sidecar is written, creating parent directories",
    os.path.isfile(fs.args.records), True)
with open(fs.args.records) as fh:
    lines = [json.loads(l) for l in fh if l.strip()]
chk("one json object per line", len(lines), 1)
chk("the record carries the item id", lines[0]["id"], fs.item_record("S","T","https://example.com/x","d","s")["id"])

# An unwritable path is the realistic failure: a full disk, a bad config, a
# read-only volume. It must warn and return, never raise.
fs.args.records = "/proc/definitely/not/writable/rec.jsonl"
raised = False
try:
    fs.write_records()
except Exception:
    raised = True
chk("an unwritable sidecar path warns instead of raising", raised, False)

fs.args.records = None
fs.RECORDS.clear()
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    fs.print_item("Src", "A title", "https://example.com/x", "2026-08-08", "A summary")
chk("with --records off, nothing is accumulated", len(fs.RECORDS), 0)

print()
if FAIL == 0:
    print(f"\033[32mPASS\033[0m ({COUNT}) — fetch recency tests passed")
else:
    print(f"\033[31mFAIL\033[0m — fetch recency tests FAILED ({COUNT} assertions run)")
sys.exit(FAIL)
PY