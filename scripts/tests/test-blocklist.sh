#!/bin/bash
# Epic public-feed, S1.1 — the blocklist loader and checker in scripts/lib/job-config.sh.
#
# The blocklist names strings that must never appear in this repo or in anything
# it publishes. Two properties are worth more than the matching itself:
#
#   1. it fails CLOSED. A missing, unreadable or empty list is an error. The
#      alternative is an empty denylist, which passes every string in existence
#      and is indistinguishable from success — this project's characteristic
#      failure shape.
#   2. it does not echo what it caught. A guard that prints the matched term
#      writes the leak into the log it was protecting.
#
# Every case here uses a SYNTHETIC term against a temporary list, because this
# repo is public and a fixture containing the real term would be the leak the
# blocklist exists to prevent. The real list is only ever checked for existence
# and non-emptiness, never printed.
#
# No network, no LLM, no writes outside $TMPDIR, no git writes anywhere.
#
#   bash scripts/tests/test-blocklist.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_DIR/scripts/lib/job-config.sh"

FAIL=0
COUNT=0
ok()  { COUNT=$((COUNT + 1)); printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad() { COUNT=$((COUNT + 1)); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A term that appears nowhere in this repo, so a match can only come from the
# list under test.
TERM_SPACED="Zorbex Dynamics"
TERM_SQUASHED="ZorbexDynamics"

printf '# a comment\n\n%s\n' "$TERM_SPACED" > "$TMP/list.txt"
: > "$TMP/empty.txt"
printf '# only comments\n\n   \n' > "$TMP/comments.txt"

printf 'nothing interesting here at all\n'            > "$TMP/clean.txt"
printf 'a keynote at %s HQ\n' "$TERM_SPACED"          > "$TMP/spaced.txt"
printf 'see https://www.%s.com/x\n' "$(tr '[:upper:]' '[:lower:]' <<<"$TERM_SQUASHED")" > "$TMP/squashed.txt"
printf '%s ANNOUNCED SOMETHING\n' "$(tr '[:lower:]' '[:upper:]' <<<"$TERM_SPACED")"     > "$TMP/upper.txt"

# Run one check with a chosen list. Prints nothing; returns the exit status.
run() {  # LIST FILE...
  local list="$1"; shift
  ( KICKOFF_BLOCKLIST="$list"; . "$LIB" >/dev/null 2>&1
    assert_no_blocked "test" "$@" ) >/dev/null 2>&1
}

expect() {  # LABEL WANT LIST FILE...
  local label="$1" want="$2"; shift 2
  run "$@"
  local got=$?
  [ "$got" -eq "$want" ] && ok "$label" || bad "$label (exit $got, wanted $want)"
}

echo "── matching ──────────────────────────────────────────────────────────────"
expect "a file with no blocked term passes"      0 "$TMP/list.txt" "$TMP/clean.txt"
expect "a spaced term is caught"                 1 "$TMP/list.txt" "$TMP/spaced.txt"
expect "the same term with spaces removed is caught" \
                                                 1 "$TMP/list.txt" "$TMP/squashed.txt"
expect "matching is case-insensitive"            1 "$TMP/list.txt" "$TMP/upper.txt"
expect "one bad file among several still fails"  1 "$TMP/list.txt" "$TMP/clean.txt" "$TMP/spaced.txt"
expect "a file that does not exist is skipped, not fatal" \
                                                 0 "$TMP/list.txt" "$TMP/nosuchfile.txt"

echo "── fails closed ──────────────────────────────────────────────────────────"
expect "a missing list is an error, not an empty denylist" \
                                                 1 "$TMP/nosuchlist.txt" "$TMP/clean.txt"
expect "an empty list is an error"               1 "$TMP/empty.txt"    "$TMP/clean.txt"
expect "a comment-only list is an error"         1 "$TMP/comments.txt"  "$TMP/clean.txt"

echo "── does not leak ─────────────────────────────────────────────────────────"
msg="$( ( KICKOFF_BLOCKLIST="$TMP/list.txt"; . "$LIB" >/dev/null 2>&1
          assert_no_blocked "test" "$TMP/spaced.txt" ) 2>&1 )"
if grep -qiF "Zorbex" <<<"$msg"; then
  bad "the failure message repeats the matched term"
else
  ok "the failure message names the file, never the term"
fi
if grep -qF "$TMP/spaced.txt" <<<"$msg"; then
  ok "the failure message names the offending file"
else
  bad "the failure message does not say which file matched"
fi

echo "── the real list ─────────────────────────────────────────────────────────"
# Existence and non-emptiness only. Never printed, never asserted against a
# known value — this file is public.
real_path="$( . "$LIB" >/dev/null 2>&1; resolve_blocklist_file )"
if [ -n "$real_path" ]; then
  ok "the real blocklist path resolves"
else
  bad "the real blocklist path did not resolve"
fi
if ( . "$LIB" >/dev/null 2>&1; blocklist_terms >/dev/null 2>&1 ); then
  ok "the real blocklist is readable and has at least one term"
else
  bad "the real blocklist is missing, unreadable or empty — check it by hand"
fi

echo "── this repo ─────────────────────────────────────────────────────────────"
# The machinery only — prompts, configs, library, tooling. NOT src/content/,
# where the published digests still carry the name pending S1.8. A check that
# fails every run for a known, already-scheduled reason is a check people learn
# to ignore, and then it is worth nothing on the day it means something.
#
# Widen this to the whole repo the moment S1.8 lands. That is the point of
# saying so here rather than in a plan document nobody greps.
# No `mapfile` — macOS ships bash 3.2, where it does not exist. It fails to
# stderr and leaves the array unset, which under `set -u` without `set -e`
# skipped straight past this check while the suite still printed PASS. A leak
# guard that reports success because it never ran is the exact shape this file
# exists to prevent, so the list goes through a file and the count is asserted.
find "$REPO_DIR/scripts" "$REPO_DIR/.claude" \
     -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' \
                -o -name '*.sh' -o -name '*.py' -o -name '*.ts' \) \
     -not -path '*/.venv/*' -not -path '*/logs/*' -not -path '*/__pycache__/*' \
     2>/dev/null | sort > "$TMP/machinery.txt"
mach_count="$(wc -l < "$TMP/machinery.txt" | tr -d ' ')"

if [ "${mach_count:-0}" -lt 20 ]; then
  bad "only ${mach_count:-0} machinery files found — the find expression is wrong, not the repo"
elif ( . "$LIB" >/dev/null 2>&1
       set --
       while IFS= read -r f; do set -- "$@" "$f"; done < "$TMP/machinery.txt"
       assert_no_blocked "repo machinery" "$@" ) 2>/dev/null; then
  ok "no prompt, config, script or planning doc names a blocked term ($mach_count files)"
else
  bad "a blocked term is present in this repo's machinery — run the check by hand to see which file"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf "\033[32mPASS\033[0m (%d) — blocklist tests passed\n" "$COUNT"
else
  printf "\033[31mFAIL\033[0m — blocklist tests FAILED (%d assertions run)\n" "$COUNT"
fi
exit "$FAIL"
