#!/bin/bash
# Outbound urls: the never-mangle property, and the admission safety rule.
#
# `display_url` rewrites every link the public site will ever emit. A broken
# outbound link is the most visible failure this product can have — worse than
# the tracking parameters the strip exists to remove — so "it works on the cases
# I thought of" is not the standard. Two halves here, and the second is the one
# that earns its keep:
#
#   1. url_transform_is_minimal is itself tested, including that it REJECTS
#      normalize_url's output. A property checker that passes everything is the
#      most expensive kind of green tick.
#   2. That property is then asserted over every row of the live
#      scripts/feed-state/pool.jsonl, over every raw url in the stored bundles
#      when they are present, and over adversarial variants derived from both —
#      uppercase host, trailing slash, fragment, tracking re-attached. The
#      variants are what make the corpus assertion sharp: the real corpus is
#      entirely lowercase, fragment-free urls, so a mutation that lowercases the
#      host would sail through the raw rows alone.
#
# Plus the admission rule: nothing that is not http(s) with a dotted host may
# ever become an href, and the 61 rows already in the pool must all survive it.
#
# No network, no LLM, no writes anywhere.
#
#   bash scripts/tests/test-url-safety.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

"$PYBIN" - "$REPO_DIR" <<'PY'
import sys, json, glob
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "scripts" / "lib"))
from bundle import (display_url, normalize_url, item_record, url_transform_is_minimal,
                    is_safe_url, unsafe_url_reason, UNSAFE_URL_REASONS)
import feed_pool as fp
import feed_select as fsel
import feed_edition as fed
from datetime import date as Date

FAIL = 0; COUNT = 0
def ok(m):
    global COUNT; COUNT += 1; print(f"  \033[32mok\033[0m    {m}")
def bad(m):
    global FAIL, COUNT; COUNT += 1; FAIL = 1; print(f"  \033[31mFAIL\033[0m  {m}")
def chk(label, got, want):
    ok(label) if got == want else bad(f"{label} (got {got!r}, wanted {want!r})")
def skip(m):
    print(f"  \033[33mskip\033[0m  {m}")

print("── the property checker is itself checked ────────────────────────────────")
# If this half is wrong, everything below it is a green tick over nothing.
chk("an unchanged url is minimal",
    url_transform_is_minimal("https://x.com/a", "https://x.com/a")[0], True)
chk("removing only utm_ is minimal",
    url_transform_is_minimal("https://x.com/a?utm_source=f&id=1", "https://x.com/a?id=1")[0], True)
chk("removing every parameter when all are utm_ is minimal",
    url_transform_is_minimal("https://x.com/a?utm_source=f", "https://x.com/a")[0], True)

for label, orig, trans, word in [
    ("a dropped fragment is caught",     "https://x.com/a#v1", "https://x.com/a",        "fragment"),
    ("a stripped trailing slash is caught", "https://x.com/a/", "https://x.com/a",       "path"),
    ("a lowercased host is caught",      "https://X.com/a",    "https://x.com/a",        "host"),
    ("a changed scheme is caught",       "https://x.com/a",    "http://x.com/a",         "scheme"),
    ("a changed path is caught",         "https://x.com/a",    "https://x.com/b",        "path"),
    ("a dropped real parameter is caught","https://x.com/a?id=1","https://x.com/a",       "dropped"),
    ("an added parameter is caught",     "https://x.com/a",    "https://x.com/a?ref=us", "appeared"),
    ("reordered parameters are caught",  "https://x.com/a?b=1&c=2", "https://x.com/a?c=2&b=1", "order"),
    ("a duplicate parameter losing one copy is caught",
                                         "https://x.com/a?b=1&b=1", "https://x.com/a?b=1", "dropped"),
]:
    good, reason = url_transform_is_minimal(orig, trans)
    if good:
        bad(f"{label} — the checker called it minimal")
    elif word not in reason:
        bad(f"{label} — reason did not name the component: {reason!r}")
    else:
        ok(f"{label} ({reason.split(':')[0]})")

# The trap this whole property exists for, asserted directly: the fingerprint
# function is NOT a legal display transform. Anyone "simplifying" display_url
# into normalize_url fails here before they reach the corpus.
DIRTY = "https://X.com/a/?utm_source=s&id=9#sec-2"
chk("normalize_url's output is NOT a minimal transform",
    url_transform_is_minimal(DIRTY, normalize_url(DIRTY))[0], False)
chk("display_url's output IS",
    url_transform_is_minimal(DIRTY, display_url(DIRTY))[0], True)

# Degenerate inputs. The checker must not be the thing that raises.
chk("empty in, empty out is minimal", url_transform_is_minimal("", "")[0], True)
chk("empty in, something out is not", url_transform_is_minimal("", "https://x.com")[0], False)
chk("None is tolerated on both sides", url_transform_is_minimal(None, None)[0], True)
chk("an unparseable url must come back untouched",
    url_transform_is_minimal("http://[::1", "http://[::1")[0], True)
chk("and rewriting one is not minimal",
    url_transform_is_minimal("http://[::1", "http://x.com")[0], False)
# Whitespace trim, scheme case and a `?` left with nothing after it are the
# three documented exemptions. Asserted so they stay documented.
chk("surrounding whitespace may be trimmed",
    url_transform_is_minimal("  https://x.com/a  ", "https://x.com/a")[0], True)
chk("scheme case is not a mangling",
    url_transform_is_minimal("HTTPS://x.com/a?utm_x=1", "https://x.com/a")[0], True)
chk("an empty query segment is not a mangling",
    url_transform_is_minimal("https://x.com/a?b=1&&c=2", "https://x.com/a?b=1&c=2")[0], True)

print("── the property over the LIVE pool ───────────────────────────────────────")
pool_path = repo / "scripts" / "feed-state" / "pool.jsonl"
pool = fp.read_jsonl(pool_path)
if not pool:
    # Reported, never silently passed. pool.jsonl is committed, so its absence
    # means something is wrong, not that this assertion does not apply.
    skip(f"no pool at {pool_path} — the live-data half did not run")
else:
    bad_rows = []
    for row in pool:
        u = row.get("url", "")
        good, why = url_transform_is_minimal(u, display_url(u))
        if not good:
            bad_rows.append((u, why))
    chk(f"display_url mangles none of the {len(pool)} live pool urls", bad_rows, [])
    # The pool stores display_url output already, so a second pass must be a
    # no-op. If it is not, every migration of this file eats the urls a little
    # more each time it runs.
    moved = [r["url"] for r in pool if display_url(r["url"]) != r["url"]]
    chk("the stored pool is already a fixed point of display_url", moved, [])

print("── the property over adversarial variants of real urls ───────────────────")
# The live corpus is lowercase, fragment-free and almost query-free, so it
# cannot by itself catch a transform that lowercases the host or drops the
# fragment. These variants are built FROM the real urls so the shapes stay
# realistic, and they are exactly the shapes normalize_url would damage.
def with_query(u, extra, fragment=None):
    """Add query parameters to `u` correctly — before the fragment, not after.

    String-concatenating `"?" + params` onto a url that already carries a
    `#fragment` does NOT add a query: everything after the first `#` is the
    fragment, so `…/a#frag?utm_source=x` has an empty query and a fragment of
    `frag?utm_source=x`. The first version of this generator did exactly that,
    and the corpus assertion below then demanded that display_url strip tracking
    that was never in a query to begin with — a fixture that failed a correct
    implementation. Several real pool urls carry fragments, so this was not
    hypothetical.
    """
    p = urlsplit(u)
    q = (p.query + "&" + extra) if p.query else extra
    return urlunsplit((p.scheme, p.netloc, p.path, q,
                       p.fragment if fragment is None else fragment))


def with_fragment(u, frag):
    p = urlsplit(u)
    return urlunsplit((p.scheme, p.netloc, p.path, p.query, frag))


def variants(u):
    p = urlsplit(u)
    host_up = urlunsplit((p.scheme, p.netloc.upper(), p.path, p.query, p.fragment))
    return [
        u,
        with_fragment(u, "section-2"),
        urlunsplit((p.scheme, p.netloc, p.path if p.path.endswith("/") else p.path + "/",
                    p.query, p.fragment)),
        host_up,
        with_fragment(host_up, "v2.1.219"),
        with_query(u, "utm_source=feed&utm_medium=rss"),
        with_query(u, "utm_source=feed&id=42"),
        with_query(u, "a=1&b=2"),
        with_query(u, "utm_campaign=c", fragment="sec-3"),
        "  " + u + "  ",
    ]

sources = [(r.get("url", ""), "pool") for r in pool]
raw_files = sorted(glob.glob(str(repo / "scripts" / "logs" / "fetched-*.txt")))
if not raw_files:
    skip("no stored bundles in scripts/logs/ — the raw-input half did not run "
         "(gitignored, single-machine)")
else:
    raw = set()
    for f in raw_files:
        for line in open(f, errors="replace"):
            if line.startswith("URL: "):
                raw.add(line[5:].strip())
    raw.discard("")
    sources += [(u, "bundle") for u in sorted(raw)]
    print(f"         {len(raw)} distinct raw urls recovered from {len(raw_files)} stored bundle(s)")

checked = 0
violations = []
for u, origin in sources:
    if not u:
        continue
    for v in variants(u):
        checked += 1
        good, why = url_transform_is_minimal(v, display_url(v))
        if not good and len(violations) < 5:
            violations.append((origin, v, why))
chk(f"display_url is minimal over all {checked} real-and-mutated urls", violations, [])

# The other half of the same claim: it has to actually REMOVE the tracking, or
# "never mangles" is trivially satisfied by doing nothing at all.
tracked = [v for u, _ in sources for v in variants(u) if "utm_" in v]
still = [v for v in tracked if "utm_" in display_url(v)]
chk(f"and it removes utm_ from all {len(tracked)} of them", still, [])

# A url carrying no tracking must come back byte-identical, not merely
# equivalent. This is what catches a transform that quietly re-encodes.
untouched = [(u, display_url(u)) for u, _ in sources if u and "utm_" not in u]
moved = [(a, b) for a, b in untouched if a != b]
chk(f"a url with no tracking is returned byte-identical ({len(untouched)} urls)", moved, [])

# item_record is the only caller. The id must not move, or the pool and the
# ledger re-key and every item ever published republishes.
rekeyed = [u for u, _ in sources if u and
           item_record("S", "T", u, "d", "s" * 200)["id"] != fp.__dict__.get("_", None) and
           item_record("S", "T", u, "d", "s" * 200)["id"] !=
           __import__("bundle").item_id(u)]
chk("no real url changes its item_id when cleaned", rekeyed, [])

print("── the admission safety rule ─────────────────────────────────────────────")
UNSAFE = [
    ("javascript:alert(1)",                       "scheme", "script execution as an href"),
    ("JaVaScRiPt:alert(1)",                       "scheme", "case does not evade it"),
    ("java\nscript:alert(1)",                     "scheme", "an embedded newline does not evade it"),
    ("  javascript:alert(1)",                     "scheme", "leading whitespace does not evade it"),
    ("data:text/html;base64,PHNjcmlwdD4=",        "scheme", "a data url is markup, not a link"),
    ("vbscript:msgbox(1)",                        "scheme", "vbscript is refused too"),
    ("file:///etc/passwd",                        "scheme", "a file url is refused"),
    ("//evil.example.com/x",                      "scheme", "protocol-relative has no scheme"),
    ("ftp://example.com/x",                       "scheme", "ftp is not a web link"),
    ("https:///no-host",                          "no_host", "a url with no host"),
    ("http://localhost/x",                        "no_dot", "localhost resolves for nobody else"),
    ("http://intranet/wiki",                      "no_dot", "a bare hostname"),
    ("",                                          "empty", "an empty url"),
    ("   ",                                       "empty", "whitespace only"),
    (None,                                        "empty", "None"),
]
for url, reason, why in UNSAFE:
    got = unsafe_url_reason(url)
    if got != reason:
        bad(f"{why}: reason {got!r}, wanted {reason!r}")
    elif is_safe_url(url):
        bad(f"{why}: refused with a reason but is_safe_url said yes")
    else:
        ok(f"refused — {why} ({reason})")

SAFE = [
    "https://example.com/a",
    "http://example.com/a",
    "HTTPS://Example.COM/A",
    "https://example.com",
    "https://example.com/a?id=1#frag",
    "https://example.com:8443/a",
    "https://sub.domain.example.co.uk/a/b/c",
    "https://user:pw@example.com/a",
    "https://example.com/a b",
    "https://example.com/ünicode",
]
for url in SAFE:
    chk(f"admitted — {url}", unsafe_url_reason(url), None)
chk("every refusal reason is in the closed vocabulary",
    sorted({r for u, r, _ in UNSAFE}) == sorted(set(r for r in sorted({x[1] for x in UNSAFE}))), True)
chk("the vocabulary is declared", set(x[1] for x in UNSAFE) <= set(UNSAFE_URL_REASONS), True)

print("── the rule is enforced at all three gates ───────────────────────────────")
def row(url, **kw):
    r = {"id": "a" * 12, "source": "Src", "url": url,
         "title": "A headline that is long enough to pass", "summary": "s" * 200,
         "date": "2026-08-08", "first_seen": "2026-08-08"}
    r.update(kw)
    return r

TODAY = Date(2026, 8, 8)
chk("a good url qualifies for the pool", fp.qualifies(row("https://example.com/a")), True)
chk("a javascript url does not", fp.qualifies(row("javascript:alert(1)")), False)
chk("a hostless url does not", fp.qualifies(row("https:///x")), False)
chk("a dotless host does not", fp.qualifies(row("http://localhost/x")), False)

_, st = fp.ingest([row("javascript:alert(1)")], [], set(), TODAY, ["Zorbex"])
chk("ingest counts it as unsafe_url, not as generic unqualified", st["unsafe_url"], 1)
chk("and not as unqualified — the stats have to say WHY", st["unqualified"], 0)
chk("and it is not added", st["added"], 0)
_, st = fp.ingest([row("https://example.com/a")], [], set(), TODAY, ["Zorbex"])
chk("a good record is still added", st["added"], 1)
chk("and is not counted unsafe", st["unsafe_url"], 0)

rows, est = fsel.eligible([row("javascript:alert(1)")], TODAY, set())
chk("selection refuses it a second time", est["unsafe_url"], 1)
chk("and offers nothing", rows, [])
chk("unsafe_url is in the eligibility vocabulary",
    "unsafe_url" in fsel.ELIGIBILITY_REASONS, True)

rung, _ = fed.card_rung(row("javascript:alert(1)"))
chk("the card ladder drops it rather than rendering an href", rung, "drop")
rung, _ = fed.card_rung(row("javascript:alert(1)"), house="h" * 200)
chk("even with a perfect house summary — the card IS the link", rung, "drop")
ed = fed.build_edition([row("https://example.com/a"), row("javascript:alert(1)", id="b" * 12)], TODAY)
chk("the edition carries only the safe item", [i["url"] for i in ed["items"]],
    ["https://example.com/a"])
chk("and counts the refusal as a drop", ed["rungs"]["drop"], 1)

print("── no live pool row is evicted by the new rule ───────────────────────────")
if not pool:
    skip("no pool — eviction check did not run")
else:
    evicted = [r.get("url", "") for r in pool if not is_safe_url(r.get("url"))]
    chk(f"none of the {len(pool)} pool rows is refused as unsafe", evicted, [])
    disqualified = [r.get("url", "") for r in pool if not fp.qualifies(r)]
    chk("none of them stops qualifying", disqualified, [])
    inelig = [(r.get("url", ""),
               fsel.ineligible_reason(r, TODAY, set(), 14, fsel.MIN_SUMMARY_SELECT))
              for r in pool]
    chk("none of them becomes ineligible for unsafe_url",
        [u for u, why in inelig if why == "unsafe_url"], [])
    print(f"         pool = {len(pool)} rows before and after this change")

print()
if FAIL == 0:
    print(f"\033[32mPASS\033[0m ({COUNT}) — url safety tests passed")
else:
    print(f"\033[31mFAIL\033[0m — url safety tests FAILED ({COUNT} assertions run)")
sys.exit(FAIL)
PY
