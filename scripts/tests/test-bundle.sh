#!/bin/bash
# Regression test for scripts/lib/bundle.py — S3.1, the extracted wire format.
#
# The risk this covers is silent drift in the nightly fetch path: format_item()
# now produces every item the digest prompt ever sees, so a byte that moves
# changes digest quality with nothing looking broken. Sampling a few strings
# does not cover that, so this suite does two things:
#
#   1. Differential — the pre-extraction print_item() is frozen verbatim below
#      and executed, and its stdout is compared byte-for-byte with format_item
#      across a matrix that hits every branch and both sides of the date
#      regex's anchor. The frozen copy is checked against
#      `git show HEAD:scripts/fetch_sources.py` while HEAD still carries the
#      original, so the freeze has provenance rather than being a retype.
#   2. Golden — real field values from stored bundles in scripts/logs/, with
#      the expected block embedded here. scripts/logs/ is gitignored and
#      single-machine, so embedding is what keeps this runnable on a fresh
#      clone; when the log is present its bytes are re-checked against the
#      embedded copy.
#
# Plus normalize_url()'s rule, and the wiring that lets fetch_sources.py import
# scripts/lib from any cwd. No network, no git writes, nothing written outside
# $TMPDIR.
#
#   bash scripts/tests/test-bundle.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

FAIL=0
COUNT=0
ok()   { COUNT=$((COUNT + 1)); printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad()  { COUNT=$((COUNT + 1)); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=1; }
skip() { printf "  \033[33mskip\033[0m  %s\n" "$*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/driver.py" <<'PY'
"""Assertions over scripts/lib/bundle.py. Prints STATUS<TAB>description lines."""
import inspect
import io
import os
import re
import subprocess
import sys
from contextlib import redirect_stdout

REPO = sys.argv[1]
sys.path.insert(0, os.path.join(REPO, "scripts", "lib"))
from bundle import format_item, normalize_url


def emit(status, desc):
    print(f"{status}\t{desc}")


def check(cond, desc, detail=""):
    if cond:
        emit("PASS", desc)
    else:
        emit("FAIL", f"{desc}{' — ' + detail if detail else ''}")


# ── 1. Differential against the frozen pre-extraction implementation ──────────
#
# Verbatim from scripts/fetch_sources.py at c0e9d79, the commit before the
# extraction. Raw string: the date regex must reach Python unescaped.
REFERENCE_SRC = r'''def print_item(source: str, title: str, url: str, date: str, summary: str) -> None:
    print(f"**{title}**")
    print(f"URL: {url}")
    if date and date != "recent":
        # Use uppercase DATE: for event-mode values (ISO dates and UNKNOWN),
        # legacy lowercase Date: for RSS publication dates.
        label = "DATE" if (date == "UNKNOWN" or re.match(r"\d{4}-\d{2}-\d{2}$", date)) else "Date"
        print(f"{label}: {date}")
    if summary:
        print(f"Summary: {summary}")
    print()
'''

_ns = {"re": re}
exec(compile(REFERENCE_SRC, "<frozen print_item>", "exec"), _ns)
reference_print_item = _ns["print_item"]


def slice_print_item(src_text):
    """Return the source of print_item() from a fetch_sources.py text, or None."""
    lines = src_text.split("\n")
    start = None
    for i, line in enumerate(lines):
        if line.startswith("def print_item("):
            start = i
            break
    if start is None:
        return None
    end = start + 1
    while end < len(lines) and (lines[end].strip() == "" or lines[end][:1] in (" ", "\t")):
        end += 1
    return "\n".join(lines[start:end]).rstrip() + "\n"


# Provenance: while HEAD still carries the original, the freeze must match it
# byte for byte. Once the extraction is committed HEAD holds the wrapper, this
# can no longer be checked, and it says so instead of passing vacuously.
try:
    head_src = subprocess.run(
        ["git", "-C", REPO, "show", "HEAD:scripts/fetch_sources.py"],
        capture_output=True, text=True, check=True,
    ).stdout
except Exception as ex:                                     # noqa: BLE001
    emit("SKIP", f"frozen reference vs HEAD: git unavailable ({ex.__class__.__name__})")
else:
    head_fn = slice_print_item(head_src)
    if head_fn is None or "format_item" in head_fn:
        emit("SKIP", "frozen reference vs HEAD: HEAD carries the wrapper, freeze is the only reference")
    else:
        check(head_fn == REFERENCE_SRC,
              "frozen reference is byte-identical to HEAD:scripts/fetch_sources.py",
              repr(head_fn))

DATES = [
    "",                                  # falsy — no date line
    "recent",                            # sentinel — no date line
    "2026-08-01",                        # ISO — uppercase DATE:
    "UNKNOWN",                           # event mode — uppercase DATE:
    "Fri, 01 Aug 2026 09:00:00 GMT",     # RSS style — lowercase Date:
    "2026-8-1",                          # near miss, too few digits
    "2026-08-01T10:00",                  # near miss, trailing content past $
    "2026-08-011",                       # near miss, one digit too many
    "2026-08-01\n",                      # $ matches before a trailing newline
    " 2026-08-01",                       # re.match anchors at 0, so no match
    "unknown",                           # case-sensitive sentinel
    "20260801",                          # no separators
]
SUMMARIES = ["", "A plain summary.", "line one\nline two", "has ** bold ** markers",
             "  padded  ", "0"]
TITLES = ["", "Plain title", "Unicode — em dash · ünïcødé 日本語", "with\nnewline",
          "**already bold**"]
URLS = ["", "https://x.com/a?utm_source=b&id=42", "https://x.com/with space",
        "url\nwith\nnewline"]
SOURCES = ["LeadDev", "", "unused"]

cases = mismatch = 0
first_bad = ""
seen_upper = seen_lower = seen_nodate = seen_summary = seen_nosummary = 0
for date in DATES:
    for summary in SUMMARIES:
        for title in TITLES:
            for url in URLS:
                for source in SOURCES:
                    buf = io.StringIO()
                    with redirect_stdout(buf):
                        reference_print_item(source, title, url, date, summary)
                    old = buf.getvalue()
                    new = format_item(source, title, url, date, summary)
                    cases += 1
                    if old != new:
                        mismatch += 1
                        if not first_bad:
                            first_bad = (f"date={date!r} summary={summary!r} title={title!r} "
                                         f"url={url!r} old={old!r} new={new!r}")
                    body = new.split("\n")
                    seen_upper += any(l.startswith("DATE: ") for l in body)
                    seen_lower += any(l.startswith("Date: ") for l in body)
                    seen_nodate += not any(l.startswith(("DATE: ", "Date: ")) for l in body)
                    seen_summary += any(l.startswith("Summary: ") for l in body)
                    seen_nosummary += not any(l.startswith("Summary: ") for l in body)

check(mismatch == 0 and cases > 0,
      f"differential: {cases - mismatch}/{cases} matrix cases byte-identical to the frozen print_item",
      first_bad)
# A matrix that stopped reaching a branch would make the line above pass while
# proving less, so each branch is asserted to have actually been exercised.
check(seen_upper > 0, f"matrix exercised the uppercase DATE: branch ({seen_upper} cases)")
check(seen_lower > 0, f"matrix exercised the lowercase Date: branch ({seen_lower} cases)")
check(seen_nodate > 0, f"matrix exercised the no-date-line branch ({seen_nodate} cases)")
check(seen_summary > 0, f"matrix exercised the Summary: branch ({seen_summary} cases)")
check(seen_nosummary > 0, f"matrix exercised the no-summary branch ({seen_nosummary} cases)")

# D1: the dead `source` parameter stays, and stays dead.
params = list(inspect.signature(format_item).parameters)
check(params == ["source", "title", "url", "date", "summary"],
      "format_item keeps print_item's signature, dead source parameter included",
      repr(params))
check(format_item("LeadDev", "t", "u", "2026-08-01", "s")
      == format_item("Hacker News", "t", "u", "2026-08-01", "s"),
      "source is accepted and never emitted")


# ── 2. Golden strings from stored bundles ─────────────────────────────────────
#
# Field values and expected bytes lifted verbatim from the logs named below.
# `source` is the producing source's name from its `### ` heading — it is never
# emitted (D1), so it is recorded here for provenance, not compared.
GOLDEN = [
    dict(
        label='DATE + Summary (RSS pub date)',
        log='scripts/logs/fetched-2026-08-01-leadership.txt',
        args=('LeadDev', 'AI-coding agents kill team collaboration',
              'https://leaddev.com/ai/ai-coding-agents-kill-team-collaboration?utm_source=leaddev&utm_medium=RSS',
              '2026-07-28', 'Agents code alone. Teams don’t. The post AI-coding agents kill team collaboration appeared first on LeadDev .'),
        expected='**AI-coding agents kill team collaboration**\nURL: https://leaddev.com/ai/ai-coding-agents-kill-team-collaboration?utm_source=leaddev&utm_medium=RSS\nDATE: 2026-07-28\nSummary: Agents code alone. Teams don’t. The post AI-coding agents kill team collaboration appeared first on LeadDev .\n\n',
    ),
    dict(
        label='DATE: UNKNOWN, no summary (event mode)',
        log='scripts/logs/fetched-2026-08-01-richmond-events.txt',
        args=('Richmond Family Magazine Calendar', 'Arts & Entertainment',
              'https://richmondfamilymagazine.com/arts/',
              'UNKNOWN', ''),
        expected='**Arts & Entertainment**\nURL: https://richmondfamilymagazine.com/arts/\nDATE: UNKNOWN\n\n',
    ),
    dict(
        label='no date line, summary present (date=recent)',
        log='scripts/logs/fetched-2026-08-01-ai.txt',
        args=('GitHub Trending', 'NomaDamas / k-skill',
              'https://github.com/NomaDamas/k-skill',
              'recent', '한국인을 위한 스킬 모음집 - 에이전트를 한국인으로 (6,700 stars)'),
        expected='**NomaDamas / k-skill**\nURL: https://github.com/NomaDamas/k-skill\nSummary: 한국인을 위한 스킬 모음집 - 에이전트를 한국인으로 (6,700 stars)\n\n',
    ),
    dict(
        label='no date line, no summary (date=recent)',
        log='scripts/logs/fetched-2026-08-01-ai.txt',
        args=('Anthropic Releases', 'Anthropic 2.1.219',
              'https://releasebot.io/updates/anthropic#2.1.219',
              'recent', ''),
        expected='**Anthropic 2.1.219**\nURL: https://releasebot.io/updates/anthropic#2.1.219\n\n',
    ),
]

for g in GOLDEN:
    got = format_item(*g["args"])
    check(got == g["expected"],
          f"golden [{g['label']}] reproduced byte-identically",
          f"got={got!r} want={g['expected']!r}")
    path = os.path.join(REPO, g["log"])
    if not os.path.exists(path):
        emit("SKIP", f"golden [{g['label']}] provenance: {g['log']} absent (gitignored, single-machine)")
        continue
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    check(g["expected"] in text,
          f"golden [{g['label']}] appears verbatim in {os.path.basename(g['log'])}")


# ── 3. normalize_url ──────────────────────────────────────────────────────────

# The AC: two URLs differing only in UTM parameters and a trailing slash.
A = "https://leaddev.com/ai/ai-coding-agents-kill-team-collaboration?utm_source=leaddev&utm_medium=RSS"
B = "https://leaddev.com/ai/ai-coding-agents-kill-team-collaboration/"
check(normalize_url(A) == normalize_url(B) == "https://leaddev.com/ai/ai-coding-agents-kill-team-collaboration",
      "UTM parameters and a trailing slash normalize to the same string",
      f"{normalize_url(A)!r} vs {normalize_url(B)!r}")

URL_CASES = [
    ("https://x.com/a?utm_source=b", "https://x.com/a", "every parameter is tracking"),
    ("https://x.com/a?UTM_Source=q&Utm_Medium=r", "https://x.com/a", "utm_ match is case-insensitive"),
    ("https://news.ycombinator.com/item?id=42&utm_source=x",
     "https://news.ycombinator.com/item?id=42", "a meaningful parameter survives"),
    ("https://x.com/a?b=2&a=1", "https://x.com/a?b=2&a=1", "kept parameters keep their order"),
    ("https://x.com/a?flag&utm_x=1", "https://x.com/a?flag", "a valueless parameter survives"),
    ("https://x.com/a?", "https://x.com/a", "an empty query leaves no ?"),
    ("https://x.com/A%20B/", "https://x.com/A%20B", "existing encoding is preserved"),
    ("https://releasebot.io/updates/anthropic#2.1.219",
     "https://releasebot.io/updates/anthropic", "the fragment is dropped"),
    ("https://x.com/a?utm_source=b#frag", "https://x.com/a", "query and fragment together"),
    ("https://x.com/", "https://x.com", "a bare domain sheds its root slash"),
    ("https://x.com", "https://x.com", "a bare domain with no slash is unchanged"),
    ("https://x.com/a//", "https://x.com/a", "repeated trailing slashes"),
    ("https://x.com:8443/a/", "https://x.com:8443/a", "the port survives"),
    ("HTTPS://X.COM/Path/", "https://x.com/Path", "host lowercased, path left alone"),
    ("  https://x.com/a  ", "https://x.com/a", "surrounding whitespace"),
    ("", "", "the empty string"),
    ("   ", "", "whitespace only"),
    ("#section", "", "a fragment with nothing else"),
    ("not a url", "not a url", "a non-URL is returned, not rejected"),
    ("http://[::1", "http://[::1", "an unparseable URL does not raise"),
]
bad_url = ""
for raw, want, why in URL_CASES:
    got = normalize_url(raw)
    if got != want and not bad_url:
        bad_url = f"{why}: normalize_url({raw!r}) = {got!r}, want {want!r}"
    check(got == want, f"normalize_url — {why}", f"{raw!r} -> {got!r}, want {want!r}")

non_idempotent = [raw for raw, _, _ in URL_CASES + [(A, "", ""), (B, "", "")]
                  if normalize_url(normalize_url(raw)) != normalize_url(raw)]
check(not non_idempotent, "normalize_url is idempotent over every case", repr(non_idempotent))
PY

echo "bundle.py — wire format"

# The driver runs from $WORK, so it proves bundle.py imports with nothing but
# scripts/lib on the path, from a cwd that is not the repo.
( cd "$WORK" && "$PYBIN" "$WORK/driver.py" "$REPO_DIR" ) >"$WORK/out.txt" 2>"$WORK/err.txt"
RC=$?
while IFS=$'\t' read -r status desc; do
  case "$status" in
    PASS) ok   "$desc" ;;
    FAIL) bad  "$desc" ;;
    SKIP) skip "$desc" ;;
  esac
done < "$WORK/out.txt"
if [ "$RC" != 0 ]; then
  bad "driver exited $RC"
  sed 's/^/        /' "$WORK/err.txt"
fi

echo "fetch_sources.py — import wiring"

# fetch_sources.py must find scripts/lib both ways it is invoked. Both runs stop
# at the missing-topic check, which is *after* the import, so neither touches the
# network.
probe() {  # DESC  CWD  SCRIPT_PATH
  local desc="$1" dir="$2" script="$3" out rc
  out="$( cd "$dir" && "$PYBIN" "$script" --topic __no_such_topic__ 2>&1 )"
  rc=$?
  if grep -q 'Missing deps' <<<"$out"; then
    skip "$desc — producer deps not installed in $PYBIN"
  elif [ "$rc" = 1 ] && grep -q 'Topic config not found' <<<"$out"; then
    ok "$desc"
  else
    bad "$desc — rc=$rc out=$out"
  fi
}

# The nightly form: run-job.sh does `cd "$REPO_DIR"` then `scripts/<producer>`.
probe "imports format_item when run as scripts/fetch_sources.py from the repo root" \
      "$REPO_DIR" "scripts/fetch_sources.py"
# And from anywhere else, by absolute path.
probe "imports format_item when run by absolute path from another cwd" \
      "$WORK" "$REPO_DIR/scripts/fetch_sources.py"

# ── item_id / item_record — the sidecar's identity rules ─────────────────────
#
# item_id is both the deduplication key and the permalink anchor, deliberately:
# two identifiers for one item eventually disagree, and the disagreement shows
# up as a duplicate card or a dead link. So the properties below are not style
# preferences — a break in any of them corrupts a ledger that is meant to
# outlive the run that wrote it.
echo "item_id"
"$PYBIN" - "$REPO_DIR" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts/lib")
from bundle import item_id, item_record, normalize_url, RECORD_FIELDS

fails = []
def chk(label, cond):
    print(("  ok    " if cond else "  FAIL  ") + label)
    if not cond: fails.append(label)

A = "https://example.com/a"
chk("same url gives the same id across calls", item_id(A) == item_id(A))
chk("a trailing slash does not change identity", item_id(A) == item_id(A + "/"))
chk("a utm_ parameter does not change identity",
    item_id(A) == item_id(A + "?utm_source=newsletter"))
chk("scheme and host case do not change identity",
    item_id(A) == item_id("https://EXAMPLE.com/a"))
chk("a different path is a different id", item_id(A) != item_id("https://example.com/b"))
chk("path case IS significant — normalize_url leaves it alone",
    item_id(A) != item_id("https://example.com/A"))
chk("a real query is kept — HN item?id= is the whole identity",
    item_id("https://news.ycombinator.com/item?id=1") !=
    item_id("https://news.ycombinator.com/item?id=2"))
chk("empty url yields empty id, not a hash of nothing", item_id("") == "")
chk("id is 12 hex chars", len(item_id(A)) == 12 and all(c in "0123456789abcdef" for c in item_id(A)))
chk("id is usable as a url fragment with no escaping", item_id(A).isalnum())

# The documented consequence of dropping the fragment. Asserted so that changing
# normalize_url's rule breaks a test that explains itself, rather than silently
# splitting or merging every releasebot item in an existing ledger.
chk("urls differing only by fragment share an id (documented consequence)",
    item_id("https://r.io/u/a#1.2.3") == item_id("https://r.io/u/a#1.2.4"))

r = item_record("Src", "Title", A, "2026-08-08", "Summary text")
chk("record carries exactly the declared fields", tuple(r.keys()) == RECORD_FIELDS)
chk("record id agrees with item_id", r["id"] == item_id(A))
chk("record keeps the original url, not the normalized one", r["url"] == A)
chk("record carries source, which the bundle deliberately omits", r["source"] == "Src")

sys.exit(1 if fails else 0)
PYEOF
if [ "$?" = "0" ]; then COUNT=$((COUNT + 15)); else COUNT=$((COUNT + 15)); FAIL=1; fi

echo
if [ "$FAIL" = "0" ]; then
  echo "PASS ($COUNT) — bundle tests passed"
else
  echo "FAIL — bundle tests FAILED ($COUNT assertions run)"
fi
exit "$FAIL"
