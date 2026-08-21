#!/bin/bash
# The public feed's GitHub repository lane — scripts/fetch_sources.py.
#
#   bash scripts/tests/test-github-repos.sh
#
# The pipeline screens repositories; the reviewer does not open them. A reviewer
# approves a title, a description and a url, so `fetch_github_repos` is the only
# thing between a typosquat and a published card. That makes every assertion
# below a gate, not a formality.
#
# Three properties are the reason this file exists:
#
#   1. FAIL CLOSED. An API call that times out, 403s or 404s drops its
#      candidate. It is never admitted from the scraped record — an enrichment
#      step that falls back on failure is a gate that opens exactly when the
#      network is unusual, and it presents as an ordinary night.
#   2. NO MEASURED FACT IN `summary`. The card body is rewritable by the house
#      voice and an edition page never regenerates, so a star count placed there
#      is wrong the next day and wrong forever in the archive.
#   3. THE DIGEST IS UNTOUCHED. `kind: github` still routes to
#      `fetch_github_trending`, which this lane neither calls nor resembles.
#      test-fetch-golden.sh proves the bundle byte-for-byte; this proves the
#      routing.
#
# Every drop is asserted as "the record is absent", never as "the constant
# exists" — deleting a floor has to fail something here.
#
# No network: both HTTP clients are stubbed. No clock: fetch_sources.NOW is
# pinned, so the fixtures' absolute timestamps mean one fixed age forever.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

if ! "$PYBIN" -c 'import yaml, bs4, feedparser, httpx' 2>/dev/null; then
  printf "  \033[33mskip\033[0m  deps unavailable in %s — run any kickoff command once\n" "$PYBIN"
  exit 0
fi

echo "github repositories (public feed lane)"

"$PYBIN" - "$REPO_DIR" <<'PY'
import io, json, pathlib, re, sys
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone

repo = pathlib.Path(sys.argv[1])
FIX  = repo / "scripts/tests/fixtures/github-repos"

# fetch_sources parses argv at import time, so it needs a plausible one.
sys.argv = ["fetch_sources.py", "--config", "scripts/feed/10-feed.yaml"]
sys.path.insert(0, str(repo / "scripts"))
sys.path.insert(0, str(repo / "scripts/lib"))
import fetch_sources as fs                       # noqa: E402

FAIL = 0
COUNT = 0
def ok(m):
    global COUNT; COUNT += 1; print(f"  \033[32mok\033[0m    {m}")
def bad(m):
    global FAIL, COUNT; COUNT += 1; FAIL = 1; print(f"  \033[31mFAIL\033[0m  {m}")
def chk(label, got, want):
    ok(label) if got == want else bad(f"{label} (got {got!r}, wanted {want!r})")

# ── the clock, pinned ────────────────────────────────────────────────────────
#
# The fixtures carry absolute timestamps expressed as offsets from this instant:
# 2026-05-14T06:00:00Z is exactly 90 days before it, 2026-02-13T06:00:00Z
# exactly 180. Left unpinned, the boundary cases would drift a day at a time
# until they stopped testing a boundary and nobody would notice.
fs.NOW = datetime(2026, 8, 12, 6, 0, 0, tzinfo=timezone.utc)

# ── the two floors that must not drift apart ─────────────────────────────────
#
# Admission is this fetcher's job; being CHOOSABLE is feed_select's. If the
# description floor sits below MIN_SUMMARY_SELECT, a repository is admitted to
# the pool that selection can never pick: it waits at `thin_summary` for the
# full 14-day staleness window, expires, and writes a tombstone — which, since
# the entity cooldown landed, bars that repository for a further 180 days. A
# floor set one gate too low therefore does not waste a slot, it silently bans
# real candidates for six months.
#
# That is not hypothetical. This shipped at 80 (matching feed_pool.MIN_SUMMARY,
# the wrong gate) and was caught during integration, by execution rather than by
# reading. This assertion is what makes the second occurrence impossible.
import feed_select as _sel                        # noqa: E402
chk("the description floor is at least the SELECTION floor, not the pool's",
    fs.REPO_MIN_DESCRIPTION >= _sel.MIN_SUMMARY_SELECT, True)

TRENDING = (FIX / "trending.html").read_text(encoding="utf-8")
API      = json.loads((FIX / "api-repos.json").read_text(encoding="utf-8"))
TREND_URL = "https://github.com/trending"

class _HttpError(Exception):
    pass

class _Resp:
    def __init__(self, text="", payload=None, status=200):
        self.text = text; self.status_code = status; self._payload = payload
    def raise_for_status(self):
        if self.status_code >= 400:
            raise _HttpError(f"{self.status_code} for url")
    def json(self):
        if self._payload is None:
            raise ValueError("response body is not json")
        return self._payload

class _Client:
    """Serves the trending fixture or an API fixture, dispatching on url.

    Records every url it is asked for, so a test can assert what was NOT
    requested — the cheap way to prove the candidate list was capped before
    enrichment rather than after it.
    """
    def __init__(self, html, calls):
        self._html = html; self._calls = calls
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def get(self, url, *a, **k):
        self._calls.append(url)
        if url.startswith("https://api.github.com/repos/"):
            full_name = url[len("https://api.github.com/repos/"):]
            payload = API.get(full_name)
            if payload == "_raise":
                raise _HttpError("connect timeout")
            if payload == "_403":
                return _Resp(status=403)
            if payload in (None, "_404"):
                return _Resp(status=404)
            return _Resp(payload=payload)
        return _Resp(text=self._html)

def run(html=TRENDING, name="GitHub Trending", url=TREND_URL, max_items=20):
    """Returns (items, stderr text, urls requested)."""
    calls = []
    fs.client            = lambda *a, **k: _Client(html, calls)
    fs.github_api_client = lambda *a, **k: _Client(html, calls)
    err = io.StringIO()
    with redirect_stderr(err):
        items = fs.fetch(name, "github_repos", url, max_items)
    return items, err.getvalue(), calls

# ── the happy path, through the dispatch ─────────────────────────────────────

print("── admission ─────────────────────────────────────────────────────────────")

items, err, calls = run()
# `.get`, so a missing key is reported as a named failure below rather than as a
# traceback from this line — a test that dies before it prints has not told you
# which property broke.
by_entity = {it.get("entity"): it for it in items}
titles = [it["title"] for it in items]

chk("kind: github_repos reaches the new fetcher and admits the screened three",
    titles,
    ["facebook / react",
     "ChromeDevTools / chrome-devtools-mcp",
     "edge / exactly-at-the-floors"])

react = by_entity.get("github:facebook/react", {})
chk("title is owner / repo, from the API's full_name", react.get("title"), "facebook / react")
chk("url is the canonical repository page",
    react.get("url"), "https://github.com/facebook/react")
chk("date is the day it trended, taken from the pinned clock",
    react.get("date"), "2026-08-12")
chk("every admitted item carries that date",
    sorted({it.get("date") for it in items}), ["2026-08-12"])
# Compared against the fixture's own value rather than a copy of it. A hardcoded
# expectation here is a second source of truth for the same string, and it
# breaks the moment a fixture is re-lengthened for an unrelated reason — which
# is exactly what happened when the description floor moved to 120.
chk("summary is the API description, verbatim",
    react.get("summary"), API["facebook/react"]["description"])
chk("...and is NOT the scraped description",
    "SCRAPED-NOT-API" in (react.get("summary") or ""), False)

# ── the summary carries no measured fact ─────────────────────────────────────

print("── the summary is a description and nothing else ─────────────────────────")

scraped = [it for it in items if "SCRAPED-NOT-API" in it["summary"]]
chk("no scraped description reached an item — every fact comes from the API",
    scraped, [])
starred = [it["summary"] for it in items
           if re.search(r"\d[\d,]*\s*stars?", it["summary"], re.I)]
chk("no summary carries a star count — the card body is rewritable and the "
    "archive never regenerates", starred, [])
chk("the trending page's star figure appears nowhere",
    [it["summary"] for it in items if "240,001" in it["summary"]], [])

# ── the entity contract ──────────────────────────────────────────────────────

print("── entity: the deduplication key ─────────────────────────────────────────")

chk("every admitted item carries an entity",
    [it["title"] for it in items if not it.get("entity")], [])
chk("every admitted item carries a substance",
    [it["title"] for it in items if not it.get("substance")], [])
chk("entity is github:owner/repo", react.get("entity"), "github:facebook/react")
chk("entity lowercases a mixed-case owner and repo",
    [it["entity"] for it in items if "chrome-devtools" in it["entity"]],
    ["github:chromedevtools/chrome-devtools-mcp"])
shape = re.compile(r"^github:[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$")
chk("every entity matches the contract shape — no host, no trailing slash",
    [it["entity"] for it in items if not shape.match(it["entity"])], [])
chk("every record is marked as a repository",
    sorted({it.get("substance") for it in items}), ["repo"])

# ── the date must be a date, because ranking reads it ────────────────────────
#
# This is the assertion the field exists for, and it is written against
# feed_select rather than against a string, because the string is not the
# property. `rank_key` sorts on -_ordinal(date); `_ordinal` answers 0 for
# anything unparseable, and 0 sorts BELOW every real date rather than above it.
# A repository stamped with a sentinel therefore ranks under every article
# sharing its tier and its first_seen — off the end of the 20-slot shortlist,
# where no judge ever sees it and no test that reads only the fetcher's output
# would notice.
#
# Asserting `date == "<some string>"` above cannot catch that. This can: it
# ranks a repository against an article that is identical in every other
# respect, and requires the tie to break on the id rather than on the date.

print("── the date is load-bearing for ranking ──────────────────────────────────")

_TIERS = {"GitHub Trending": 2, "Some Publication": 2}

# The repository is given the LOWER id so that the two rows tie on every
# component up to the id and the repository wins that tie. It can only lose if
# its date has sunk it — which is precisely the failure, and which is why the
# ids are not interchangeable here.
def _rank_pair(repo_date):
    """A repository and an article, alike but for source, date and id."""
    repo = {"id": "0000", "source": "GitHub Trending", "first_seen": "2026-08-12",
            "date": repo_date, "substance": "repo"}
    art  = {"id": "ffff", "source": "Some Publication", "first_seen": "2026-08-12",
            "date": "2026-08-12"}
    return [r["id"] for r in _sel.rank([repo, art], _TIERS)]

chk("a repository dated the day it trended ranks level with a same-day "
    "article, tie broken on id", _rank_pair(react.get("date")), ["0000", "ffff"])
chk("...and an unparseable date sinks it below that article — the regression "
    "this guards", _rank_pair("recent"), ["ffff", "0000"])

# ── the floors, one drop per floor ───────────────────────────────────────────
#
# Each asserts the RECORD IS ABSENT. Deleting the corresponding floor in
# fetch_sources.py must fail the line below it.

print("── the admission floors ──────────────────────────────────────────────────")

def absent(entity, why):
    chk(why, entity in by_entity, False)

absent("github:typosquat/two-days-old",
       "a 2-day-old repository is dropped (age floor, 90 days)")
absent("github:someone/a-fork-of-something",
       "a fork is dropped, however old and however starred")
absent("github:oldco/archived-tool", "an archived repository is dropped")
absent("github:oldco/disabled-tool", "a disabled repository is dropped")
absent("github:tiny/starveling",
       "a repository under the star floor is dropped (500)")
absent("github:stale/abandoned-spike",
       "a spike on a repository unpushed for 400 days is dropped (180)")
absent("github:terse/no-description",
       "a 20-character description is dropped — 'Node Version Manager' is not a card")
absent("github:edge/one-short-of-the-description-floor",
       "a 119-character description is dropped — the floor is >= 120, not > 120")

edge = by_entity.get("github:edge/exactly-at-the-floors")
chk("a repository sitting EXACTLY on the age, star, push and description "
    "floors is admitted — no floor over-rejects by one", edge is not None, True)

# ── fail closed ──────────────────────────────────────────────────────────────

print("── enrichment failure drops the candidate ────────────────────────────────")

absent("github:forbidden/rate-limited",
       "a 403 / rate-limit drops the candidate")
absent("github:timeout/never-answers",
       "a timeout drops the candidate")
absent("github:topics/machine-learning",
       "a reserved path shaped like owner/repo is dropped by the API's 404")
chk("the scraped record is never the fallback — no dropped candidate's url "
    "reached an item",
    [it["url"] for it in items
     if "rate-limited" in it["url"] or "never-answers" in it["url"]], [])
chk("each enrichment failure says which candidate it cost",
    all(f"{n} dropped — API enrichment failed" in err
        for n in ("forbidden/rate-limited", "timeout/never-answers")), True)

# ── the API budget ───────────────────────────────────────────────────────────

print("── the unauthenticated API budget ────────────────────────────────────────")

api_calls = [u for u in calls if u.startswith("https://api.github.com/")]
chk("one API call per candidate, none per non-candidate",
    len(api_calls), 14)
chk("a three-segment href is not a candidate",
    [u for u in api_calls if "stargazers" in u], [])
chk("an <article> with no <h2> is skipped rather than fetched",
    len(calls) - len(api_calls), 1)

_, _, capped = run(max_items=2)
chk("max_items caps the CANDIDATE list, before enrichment — the budget is the "
    "thing being protected",
    len([u for u in capped if u.startswith("https://api.github.com/")]), 2)

# ── the zero-item warning ────────────────────────────────────────────────────
#
# The failure this exists for: find_all("article") returns [] after a markup
# change, the bundle reads *No items fetched*, run-job.sh's ^URL: gate passes on
# the other forty sources, and the edition publishes with zero repositories and
# exit code 0. Perfect silence, indistinguishable from a quiet night.

print("── a silent source is distinguishable from a quiet night ─────────────────")

blank, blank_err, blank_calls = run(html="<html><body><p>redesigned</p></body></html>")
chk("a markup change yields no items", blank, [])
chk("...and warns on stderr", "the markup may have changed" in blank_err, True)
chk("...and spends no API budget", blank_calls, ["https://github.com/trending"])

chk("a fetch that admits items does NOT warn — the warning means something",
    "0 repositories on the trending page" in err or
    "cleared the admission floors" in err, False)

# Every candidate present, every one refused: a different silence, and it has to
# be a different sentence.
only_bad = re.sub(r'<h2><a href="/(facebook/react|ChromeDevTools/chrome-devtools-mcp'
                  r'|edge/exactly-at-the-floors)">', '<h2><a href="/tiny/starveling">',
                  TRENDING)
none_pass, none_err, _ = run(html=only_bad)
chk("candidates that all fail the floors yield no items", none_pass, [])
chk("...and warn with a different sentence from a markup change",
    "cleared the admission floors" in none_err, True)

# ── the record the pool actually reads ───────────────────────────────────────

print("── the sidecar record ────────────────────────────────────────────────────")

fs.args.records = "unused-by-this-test"   # write_records is never called
fs.RECORDS.clear()
with redirect_stderr(io.StringIO()), redirect_stdout(io.StringIO()):
    for it in items:
        fs.print_item("GitHub Trending", it["title"], it["url"], it["date"],
                      it["summary"], it.get("substance"), it.get("entity"))

rec = fs.RECORDS[0]
chk("the record reaching the pool carries entity",
    rec.get("entity"), "github:facebook/react")
chk("the record reaching the pool carries substance: repo",
    rec.get("substance"), "repo")
chk("the record keeps its url identity", rec.get("url"),
    "https://github.com/facebook/react")
chk("the record has an id", bool(rec.get("id")), True)
chk("the record's summary survives sanitising at full length",
    len(rec.get("summary", "")) >= fs.REPO_MIN_DESCRIPTION, True)

fs.RECORDS.clear()
with redirect_stderr(io.StringIO()), redirect_stdout(io.StringIO()):
    fs.print_item("Some RSS Feed", "An ordinary article headline goes here",
                  "https://example.com/a", "2026-08-11", "x" * 200)
plain = fs.RECORDS[0]
chk("an ordinary record gains no entity — only a source that can name the "
    "underlying thing may claim to", "entity" in plain, False)
chk("an ordinary record gains no substance", "substance" in plain, False)
fs.args.records = None

# ── the private digest's path is a different path ────────────────────────────

print("── the digest is untouched ───────────────────────────────────────────────")

calls = []
fs.client = lambda *a, **k: _Client(TRENDING, calls)
with redirect_stderr(io.StringIO()):
    digest = fs.fetch("GitHub Trending", "github", TREND_URL, 15)
react_digest = next((it for it in digest if it["url"].endswith("/facebook/react")), {})
chk("kind: github still routes to fetch_github_trending — the scraped path, "
    "reading the scraped description",
    "SCRAPED-NOT-API" in react_digest.get("summary", ""), True)
chk("...and it makes no API call",
    [u for u in calls if "api.github.com" in u], [])
chk("...and stamps no entity on its items",
    any("entity" in it for it in digest), False)
chk("...and stamps no substance on its items",
    any("substance" in it for it in digest), False)

print("── an API outage must not read as a quiet board ──────────────────────────")
# Both produce an edition with no repository, exit 0 and no FAILED_JOBS entry,
# so the log line is the only thing that can tell them apart. `warn` writes to
# a gitignored, single-machine log — the sentence is all there is.
class _DeadApi:
    def __init__(self, html): self.html = html
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def get(self, url, *a, **k):
        if "api.github.com" in url:
            raise _HttpError("403 rate limit exceeded")
        return _Resp(self.html)

err = io.StringIO()
fs.client = lambda *a, **k: _DeadApi(TRENDING)
fs.github_api_client = lambda *a, **k: _DeadApi(TRENDING)
with redirect_stderr(err):
    out_dead = fs.fetch_github_repos("GitHub Trending", TREND_URL, 15)
msg = err.getvalue()
chk("an unreachable API yields no items", out_dead, [])
chk("...and the warning says the API failed, not that the board was quiet",
    "unreachable or refusing requests" in msg, True)
chk("...and does NOT claim the floors rejected them",
    "cleared the admission floors" in msg, False)

print("── the API headers are load-bearing and therefore asserted ───────────────")
# GitHub rejects an unauthenticated API request with no User-Agent outright.
# Without this, deleting GITHUB_API_HEADERS left every assertion in this file
# green while production 403'd every night — presenting as the outage above.
seen_headers = {}
class _HeaderSpy:
    def __init__(self, html): self.html = html
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def get(self, url, *a, **k):
        if "api.github.com" in url:
            seen_headers.update(fs.GITHUB_API_HEADERS)
            slug = url.split("/repos/", 1)[1]
            if slug not in API:
                raise _HttpError("404")
            return _Json(API[slug])
        return _Resp(self.html)

fs.client = lambda *a, **k: _HeaderSpy(TRENDING)
fs.github_api_client = lambda *a, **k: _HeaderSpy(TRENDING)
with redirect_stderr(io.StringIO()):
    fs.fetch_github_repos("GitHub Trending", TREND_URL, 15)
chk("the API request carries a User-Agent — GitHub refuses one without",
    bool(seen_headers.get("User-Agent")), True)
chk("...and asks for the documented JSON media type",
    seen_headers.get("Accept"), "application/vnd.github+json")

print()
if FAIL:
    print(f"\033[31mgithub repositories FAILED\033[0m ({COUNT} assertions)")
else:
    print(f"\033[32mgithub repositories ok\033[0m ({COUNT} assertions)")
sys.exit(FAIL)
PY
