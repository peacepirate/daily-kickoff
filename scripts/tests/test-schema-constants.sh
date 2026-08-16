#!/bin/bash
# D1, second half — the constants duplicated across the language boundary must
# agree, or the producer writes an edition the schema refuses.
#
#   bash scripts/tests/test-schema-constants.sh
#
# The feed's schema is deliberately stated twice: Python decides what an edition
# IS, and src/content.config.ts in the feed repo refuses to build one that does
# not match. That duplication is the right trade — a disagreement stops a deploy
# instead of publishing a broken page — but only while the two copies agree.
#
# When they disagree the producer emits an edition every night that the schema
# rejects every night, and until D1's quarantine landed that also stalled every
# subsequent build. This is the cheapest possible detector for that: read both
# declarations and compare them.
#
# Skips green when the feed site is not checked out. That is deliberate — the
# engine is public and clonable on its own, and a test that fails on a healthy
# machine is a test that gets deleted.
#
# No network, no writes anywhere. Reads two files.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export KICKOFF_LIB_REPO_DIR="$REPO_DIR"
LOG_FILE="/dev/null"
. "$REPO_DIR/scripts/lib/job-config.sh"

echo "cross-language schema constants"

SITE="$(resolve_feed_site_dir)"
CONFIG="$SITE/src/content.config.ts"

if [ ! -f "$CONFIG" ]; then
  printf "  \033[33mskip\033[0m  feed site not checked out at %s\n" "$SITE"
  exit 0
fi

PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN=python3

"$PYBIN" - "$REPO_DIR" "$CONFIG" "$SITE" <<'PY'
import re, sys, pathlib

repo, config_path, site = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, f"{repo}/scripts/lib")
import feed_select, feed_edition          # noqa: E402 — needs the path line above

ts = pathlib.Path(config_path).read_text(encoding="utf-8")


def strip_line_comments(s: str) -> str:
    """Drop `// ...` so prose cannot be read as code.

    Not cosmetic. A comment containing an apostrophe — "the unjudged path's
    final cut" — makes every single-quoted value after it pair with the wrong
    delimiter, and the extractor then reports a value as missing that is sitting
    right there in the file. That is exactly how this function came to exist:
    the first version of this test failed against a correct schema.
    """
    return re.sub(r"//[^\n]*", "", s)

FAIL = 0
def ok(m):  print(f"  \033[32mok\033[0m    {m}")
def bad(m):
    global FAIL; FAIL = 1; print(f"  \033[31mFAIL\033[0m  {m}")

def ts_number(name):
    m = re.search(rf"const\s+{name}\s*=\s*(\d+)\s*;", ts)
    return int(m.group(1)) if m else None

def ts_list(name):
    m = re.search(rf"const\s+{name}\s*=\s*\[(.*?)\]\s*as const;", ts, re.S)
    return tuple(re.findall(r"'([^']*)'", strip_line_comments(m.group(1)))) if m else None

# ── the three numbers ────────────────────────────────────────────────────────
#
# Named on the TypeScript side specifically so this can read them. Two of them
# were bare literals inside a superRefine until D1, where no regex could find
# them without breaking on the first reformat.
for name, py_value, where in (
    ("DAILY_CAP",       feed_select.DAILY_CAP,        "feed_select.py"),
    ("MAX_TITLE_ONLY",  feed_edition.MAX_TITLE_ONLY,  "feed_edition.py"),
    ("PUBLISHER_CHARS", feed_edition.PUBLISHER_CHARS, "feed_edition.py"),
):
    ts_value = ts_number(name)
    if ts_value is None:
        bad(f"{name} is not declared as a named const in content.config.ts — "
            f"it cannot be compared, so the drift is undetectable again")
    elif ts_value != py_value:
        bad(f"{name} disagrees: {where} says {py_value}, content.config.ts says {ts_value}. "
            f"An edition built to the Python value would be refused by the schema.")
    else:
        ok(f"{name} = {py_value} on both sides")

# ── the tag vocabulary ───────────────────────────────────────────────────────
#
# Drift here is silent rather than fatal: feed_edition drops a tag the schema
# does not know, so a tag added on one side only never appears and nothing says
# so. That is worse than a build failure, not better.
ts_tags = ts_list("TAGS")
if ts_tags is None:
    bad("TAGS could not be parsed out of content.config.ts")
elif tuple(feed_edition.TAGS) != ts_tags:
    only_py = [t for t in feed_edition.TAGS if t not in ts_tags]
    only_ts = [t for t in ts_tags if t not in feed_edition.TAGS]
    bad(f"TAGS disagree — python-only: {only_py or '-'}, ts-only: {only_ts or '-'}. "
        f"A tag missing from the schema is dropped in silence.")
else:
    ok(f"TAGS agree — {len(ts_tags)} values, same order")

# ── the rung ladder, which does NOT match one-for-one and must not ───────────
#
# Python carries a fourth rung, `drop`, for items that produced nothing usable.
# A dropped item never becomes a card, so it never reaches the schema — but it
# IS a key in the `rungs` tally the edition carries. The correct relationship is
# therefore containment, not equality, and asserting equality here would fail on
# healthy code and teach whoever hit it to delete the test.
ts_rungs = ts_list("RUNGS")
DROP = "drop"
if ts_rungs is None:
    bad("RUNGS could not be parsed out of content.config.ts")
else:
    card_rungs = tuple(r for r in feed_edition.RUNGS if r != DROP)
    if card_rungs != ts_rungs:
        bad(f"card rungs disagree: python {card_rungs} vs schema {ts_rungs}")
    elif DROP not in feed_edition.RUNGS:
        bad(f"'{DROP}' vanished from feed_edition.RUNGS — the rungs tally would "
            f"lose the count of items that produced nothing usable")
    elif DROP in ts_rungs:
        bad(f"'{DROP}' appeared in the schema's RUNGS — a dropped item is not a card")
    else:
        ok(f"rung ladder agrees — {card_rungs} on cards, '{DROP}' tally-only")

# ── the thin-day vocabulary, which lives in TWO places ───────────────────────
#
# feed_select.THIN_REASONS decides what a reason IS. content.config.ts refuses
# an edition carrying one it does not know — so a reason added on the Python
# side alone fails every build until someone notices.
#
# It used to live in four. Edition.astro and feed-html.js each carried a map
# turning a reason into a sentence for the reader, and those were the dangerous
# copies: a missing key there is not an error, it renders as nothing, and the
# page said " 3 today." with the explanation silently gone. Both maps are gone
# now — the thin-day sentence was removed as copy a reader had no use for — so
# `reason` is a diagnostic field with no reader-facing surface. The guard below
# holds that: it is the condition under which two of these four checks were
# allowed to be deleted rather than fixed.
reasons_py = set(feed_select.THIN_REASONS)

m = re.search(r"reason:\s*z\.enum\(\[(.*?)\]\)", ts, re.S)
reasons_ts = set(re.findall(r"'([^']*)'", strip_line_comments(m.group(1)))) if m else None

def js_map_keys(path, name):
    """Keys of a `const NAME = { ... };` object literal, comments stripped."""
    src = pathlib.Path(path).read_text(encoding="utf-8")
    mm = re.search(rf"const {name}[^=]*=\s*\{{(.*?)\n\}};", src, re.S)
    if not mm:
        return None
    body = strip_line_comments(mm.group(1))
    return set(re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:", body, re.M))

surfaces = [
    ("content.config.ts reason enum", reasons_ts),
]

# The condition the two deleted checks rested on. A renderer that grows a
# REASONS map again is back in the four-place world, where a key missing from
# one copy is invisible — so it has to come back with its check.
for path in (f"{site}/src/components/Edition.astro", f"{site}/src/lib/feed-html.js"):
    name = pathlib.Path(path).name
    if js_map_keys(path, "REASONS") is None:
        ok(f"{name} renders no thin-day sentence")
    else:
        bad(f"{name} has a REASONS map again — `reason` is reader-facing once more, "
            f"and a key missing from one copy renders as nothing. Add it back to "
            f"`surfaces` above so it is checked against THIN_REASONS.")

for label, found in surfaces:
    if found is None:
        bad(f"could not parse the reason vocabulary out of {label}")
        continue
    missing = reasons_py - found
    extra   = found - reasons_py
    if missing:
        bad(f"{label} is missing {sorted(missing)} — "
            + ("the build refuses every edition using it"
               if "config" in label else
               "the page drops the explanation and prints a bare count"))
    elif extra:
        bad(f"{label} carries {sorted(extra)}, which feed_select can never emit")
    else:
        ok(f"{label} — {len(found)} reasons, exactly matching THIN_REASONS")

print()
if FAIL:
    print("\033[31mschema constants FAILED\033[0m")
else:
    print("\033[32mschema constants ok\033[0m")
sys.exit(FAIL)
PY
