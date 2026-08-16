#!/bin/bash
# D2 — the bundle the private digest reads is frozen, so a fetcher change cannot
# alter it in silence.
#
#   bash scripts/tests/test-fetch-golden.sh
#
# The gap this closes, measured before it was written: `fetch_github_trending`
# was mutated to prefix every repository title, which changes every GitHub line
# in the nightly AI digest. ALL 26 SUITES PASSED. test-prompt-baseline.sh says
# so in its own header — it freezes "the resolved output path, the producer
# command line, and the rendered prompt", and the bundle is on none of those
# lists. test-bundle.sh covers format_item against a frozen copy, not the
# fetchers that feed it.
#
# So `bundle.py`, `fetch_sources.py` and `feed_pool.py` are shared between the
# private digest and the public feed, and nothing could tell you that a change
# made for one had moved the other.
#
# What this freezes, per fetch kind: the parsed item dicts, the sidecar record
# (item_record), and the wire format the model actually reads (format_item).
#
# What it does NOT do, stated so nobody over-trusts it: the fixtures are shapes,
# not recordings of live hosts. This detects a change in OUR parsing and
# formatting. It cannot detect github.com changing its markup — that failure is
# a remote one, and it presents as zero items rather than as different items.
#
# ONE THING THE GOLDEN ENCODES THAT IS A LATENT BUG, NOT AN INTENTION.
#
# All three releasebot records carry the SAME id. `fetch_releasebot` builds each
# url as `<page>#<version>`, and `normalize_url` drops the fragment before
# hashing — so every release from one releasebot source collapses to one
# item_id. It is harmless today and only today: releasebot appears in
# scripts/topics/ai.yaml alone, and no topic config passes `--records`, so
# nothing it produces is ever ingested into the pool. The digest reads the
# bundle, which is text, and the bundle is correct.
#
# It stops being harmless the moment a releasebot source is added to
# scripts/feed/10-feed.yaml: ingest dedups on id, so ten releases would become
# one pool row. Frozen here deliberately — if someone fixes it, this test fails
# and they are told what they changed rather than discovering it in a pool.
#
# NEVER regenerate the golden to make this pass. A reference regenerated from
# the new code compares it with itself. A deliberate change is the one
# legitimate way to fail: re-freeze with KICKOFF_FREEZE_GOLDEN=1 in the same
# commit and say why in the message.
#
# No network — httpx is stubbed at fetch_sources.client. No clock — SINCE is
# pinned. No writes outside the golden, and only when explicitly asked.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN=python3

echo "fetcher golden (the bundle the digest reads)"

"$PYBIN" - "$REPO_DIR" <<'PY'
import sys, pathlib, json
from datetime import datetime, timezone

repo = pathlib.Path(sys.argv[1])
FIX  = repo / "scripts/tests/fixtures/fetch-golden"
GOLD = repo / "scripts/tests/fixtures/fetch-golden.txt"

# fetch_sources parses argv at import time, so it needs a plausible one.
sys.argv = ["fetch_sources.py", "--config", "scripts/feed/10-feed.yaml"]
sys.path.insert(0, str(repo / "scripts"))
sys.path.insert(0, str(repo / "scripts/lib"))
import fetch_sources as fs                       # noqa: E402
from bundle import format_item, item_record      # noqa: E402

FAIL = 0
def ok(m):  print(f"  \033[32mok\033[0m    {m}")
def bad(m):
    global FAIL; FAIL = 1; print(f"  \033[31mFAIL\033[0m  {m}")

# ── the two sources of non-determinism, both pinned ──────────────────────────
#
# SINCE is computed from datetime.now() at import. Left alone, the RSS recency
# filter would drop different fixture entries depending on the day this runs,
# and the golden would rot into a test that everyone reruns with --freeze.
fs.SINCE = datetime(2026, 8, 1, 0, 0, 0, tzinfo=timezone.utc)

class _Resp:
    def __init__(self, text): self.text = text; self.status_code = 200
    def raise_for_status(self): pass

class _Client:
    """Serves a fixture regardless of url. Each case fetches exactly one page."""
    def __init__(self, body): self._body = body
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def get(self, url, *a, **k): return _Resp(self._body)

def stub(body):
    fs.client = lambda *a, **k: _Client(body)

# ── the cases ────────────────────────────────────────────────────────────────
#
# One per fetch kind, because the kind is what selects the parser. `atom` is
# deliberately absent: fetch() routes it to fetch_rss, which `rss` already
# covers, and a second identical case would only look like coverage.
CASES = [
    ("Fixture RSS",       "rss",        "https://fixture.example/feed.xml",   "rss.xml",         10),
    ("GitHub Trending",   "github",     "https://github.com/trending",        "trending.html",   15),
    ("Claude Code Releases", "releasebot", "https://fixture.example/updates", "releasebot.html", 10),
    ("Fixture Blog",      "html",       "https://fixture.example/blog",       "generic.html",    10),
]

lines = []
for name, kind, url, fixture, max_items in CASES:
    stub((FIX / fixture).read_text(encoding="utf-8"))
    items = fs.fetch(name, kind, url, max_items)

    lines.append(f"=== {name} [{kind}] — {len(items)} item(s)")
    for it in items:
        rec = item_record(name, it["title"], it["url"], it["date"], it["summary"])
        lines.append("--- record")
        lines.append(json.dumps(rec, sort_keys=True, ensure_ascii=False))
        lines.append("--- bundle")
        lines.append(format_item(name, it["title"], it["url"], it["date"], it["summary"]).rstrip("\n"))
    lines.append("")

actual = "\n".join(lines) + "\n"

import os
if os.environ.get("KICKOFF_FREEZE_GOLDEN") == "1":
    GOLD.write_text(actual, encoding="utf-8")
    print(f"  \033[33mfroze\033[0m {GOLD.relative_to(repo)} ({len(actual)} bytes)")
    print("  Re-freezing is a deliberate act. Say why in the commit message.")
    sys.exit(0)

if not GOLD.exists():
    bad(f"no golden at {GOLD.relative_to(repo)} — create it with KICKOFF_FREEZE_GOLDEN=1")
    sys.exit(FAIL)

expected = GOLD.read_text(encoding="utf-8")
if actual == expected:
    n = sum(1 for line in expected.splitlines() if line.startswith("--- record"))
    ok(f"bundle and sidecar byte-identical for {len(CASES)} fetch kinds, {n} items")
else:
    import difflib
    bad("the bundle the digest reads has CHANGED")
    diff = list(difflib.unified_diff(expected.splitlines(), actual.splitlines(),
                                     "golden", "now", lineterm="", n=1))
    for line in diff[:40]:
        print(f"        {line}")
    if len(diff) > 40:
        print(f"        … {len(diff) - 40} more diff lines")
    print("        If this change is intended, re-freeze in the same commit:")
    print("          KICKOFF_FREEZE_GOLDEN=1 bash scripts/tests/test-fetch-golden.sh")

# ── the recency filter must be doing something ───────────────────────────────
#
# A golden alone cannot tell "the filter dropped the old entry" from "the filter
# is gone and the fixture never had one". The fixture carries an entry dated
# before the pinned SINCE, and this asserts it is absent — so deleting the
# recency check fails here with a sentence that says what broke, rather than as
# an unexplained diff.
if "posts/ancient" in actual:
    bad("an entry older than SINCE reached the bundle — the RSS recency filter is not firing")
else:
    ok("the RSS recency filter dropped the pre-window entry")

print()
if FAIL:
    print("\033[31mfetcher golden FAILED\033[0m")
else:
    print("\033[32mfetcher golden ok\033[0m")
sys.exit(FAIL)
PY
