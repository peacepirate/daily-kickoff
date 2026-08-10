#!/bin/bash
# Regression test for scripts/studio/select_corpus.py — S3.2–S3.5.
#
# Everything runs against a FIXTURE repo tree built under $TMPDIR: fixture
# topic configs, a fixture generators/angles.yaml, a fixture src/content/, a
# fixture studio. The real src/content/ changes every night, so a suite that
# leaned on it would rot within the week and then be ignored — and the one thing
# this bundle must be is reproducible.
#
# The window is fixed at 2026-07-20 → 2026-08-02 (lookback_days: 14, inclusive
# both ends) so every count below is arithmetic, not observation:
#
#   Mondays..Saturdays in it   12   (`weekdays` — Mon–Sat, NOT Mon–Fri)
#   Saturdays in it             2   (2026-07-25, 2026-08-01)
#   Sundays in it               2   (2026-07-26, 2026-08-02)
#
# No network, no git writes to the real repo, nothing written outside $TMPDIR.
#
#   bash scripts/tests/test-select-corpus.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SELECT="$REPO_DIR/scripts/studio/select_corpus.py"

PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

FAIL=0
COUNT=0
ok()   { COUNT=$((COUNT + 1)); printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad()  { COUNT=$((COUNT + 1)); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=1; }
skip() { printf "  \033[33mskip\033[0m  %s\n" "$*"; }

# On a clone where scripts/.venv has not been built there is nothing to test
# against, and building one needs the network. Say so rather than reporting red.
if ! "$PYBIN" -c 'import yaml' 2>/dev/null; then
  echo "select_corpus.py"
  skip "pyyaml unavailable in $PYBIN — run any kickoff command once to build scripts/.venv"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

END=2026-08-02
START=2026-07-20

# The job kinds select_corpus.py must walk, as this suite's own copy of the
# vocabulary. Asserted equal to JOB_KINDS below, then exercised one kind at a
# time against real fixture directories.
KINDS="topics generators feed"

# ── Fixture builders ─────────────────────────────────────────────────────────

new_repo() {  # NAME -> path
  local r="$WORK/$1"
  mkdir -p "$r/scripts/topics" "$r/scripts/generators" "$r/src/content"
  echo "$r"
}

topic_cfg() {  # REPO JOBNAME SCHEDULE COLLECTION_DIR
  cat > "$1/scripts/topics/$2.yaml" <<EOF
name:     "$2"
schedule: $3
producer: fetch_sources.py --topic $2
prompt:   scripts/prompts/$2.md
output:   src/content/$4/{{DATE}}.md
EOF
}

# COLLECTIONS is a YAML flow list, WEIGHTS a YAML flow map of theme -> weight.
angles_cfg() {  # REPO COLLECTIONS THEME_WEIGHTS [LOOKBACK] [HALF_LIFE]
  cat > "$1/scripts/generators/angles.yaml" <<EOF
name:     "Angles"
schedule: never
output:   \$STUDIO_DIR/angles/{{DATE}}.md

selection:
  lookback_days: ${4:-14}
  collections: $2
  half_life_days: ${5:-7}
  weights:
    theme:   $3
    starred: 1.5
    noted:   2.0
    done:    0.3
EOF
}

# Every digest carries the same action shapes, so a signal key can address any
# of them: try[0..1], share[0] (a {what,who} object), readDeeper[0..1], skip[0].
mkdigest() {  # REPO THEME SLUG
  local dir="$1/src/content/$2"
  mkdir -p "$dir"
  cat > "$dir/$3.md" <<EOF
---
title: "TITLE $2 $3"
date: $3
theme: $2
format: daily
tldr: "TLDR $2 $3"
itemCount: 4
readTimeMinutes: 5
sources:
  - title: "A Source"
    url: "https://example.com/"
actions:
  try:
    - "TRY $2 $3 zero"
    - "TRY $2 $3 one"
  share:
    - what: "SHARE what $2 $3 zero"
      who: "the team"
  readDeeper:
    - "READ $2 $3 zero"
    - "READ $2 $3 one"
  skip:
    - "SKIP $2 $3 zero"
---

## TL;DR

Body text.
EOF
}

new_studio() {  # NAME -> path
  local d="$WORK/$1" x
  for x in notes angles drafts published engagement state; do mkdir -p "$d/$x"; done
  echo "$d"
}

# ── Runner ───────────────────────────────────────────────────────────────────

run_corpus() {  # REPO STUDIO [ARGS...] -> RC, $WORK/out.txt, $WORK/err.txt
  local repo="$1" studio="$2"; shift 2
  STUDIO_DIR="$studio" "$PYBIN" "$SELECT" --repo-dir "$repo" "$@" \
    >"$WORK/out.txt" 2>"$WORK/err.txt"
  RC=$?
  OUT="$(cat "$WORK/out.txt")"
  ERR="$(cat "$WORK/err.txt")"
}

# Only the three real section headers delimit a section. A note body may hold a
# line beginning "## " — one of the fixtures below deliberately does — and a
# naive /^## / split would silently truncate YOUR NOTES around it.
sec() {  # NAME [FILE]
  awk -v want="## $1" '
    /^## (YOUR NOTES|YOUR SIGNAL|CORPUS)$/ { inside = ($0 == want); next }
    inside { print }
  ' "${2:-$WORK/out.txt}"
}

urls_in() { sec "$1" | sed -n 's/^URL: //p'; }

echo "select_corpus.py — corpus, notes, signals, ranking, coverage"

# ═════════════════════════════════════════════════════════════════════════════
# The main fixture. Counts here are the arithmetic in the header comment.
#
#   leadership  saturday   2026-07-25, 2026-08-01                   ->  2/2
#   ai          weekdays   all 12 weekday dates except 2026-08-01    -> 11/12
#   tech        weekdays   2026-07-20 only                           ->  1/12
#   rva-events  saturday   2026-07-25, 2026-08-01, via
#                          topics/richmond-events.yaml's output:     ->  2/2
#
# Plus, all of which must be invisible in the bundle:
#   ai/2026-07-19 (Sunday before the window) and ai/2026-08-03 (after it),
#   local-llm/2026-07-28 and richmond/2026-07-28 (undeclared collections).
# ═════════════════════════════════════════════════════════════════════════════

MAIN="$(new_repo main)"
topic_cfg "$MAIN" ai         weekdays ai
topic_cfg "$MAIN" leadership saturday leadership
topic_cfg "$MAIN" tech       weekdays tech
# The near-miss the epic names: job richmond-events writes src/content/rva-events/.
topic_cfg "$MAIN" richmond-events saturday rva-events
angles_cfg "$MAIN" '[leadership, ai, tech, rva-events]' \
           '{ leadership: 3.0, ai: 1.0, tech: 0.6, rva-events: 0.1 }'

AI_DATES="2026-07-20 2026-07-21 2026-07-22 2026-07-23 2026-07-24 2026-07-25
          2026-07-27 2026-07-28 2026-07-29 2026-07-30 2026-07-31"
for d in $AI_DATES; do mkdigest "$MAIN" ai "$d"; done
mkdigest "$MAIN" ai 2026-07-19          # Sunday, one day before the window
mkdigest "$MAIN" ai 2026-08-03          # one day after the window
mkdigest "$MAIN" leadership 2026-07-25
mkdigest "$MAIN" leadership 2026-08-01
mkdigest "$MAIN" tech 2026-07-20
mkdigest "$MAIN" rva-events 2026-07-25
mkdigest "$MAIN" rva-events 2026-08-01
mkdigest "$MAIN" local-llm 2026-07-28   # retired-but-retained, undeclared
mkdigest "$MAIN" richmond  2026-07-28   # retired-but-retained, undeclared

git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email t@t.t
git -C "$MAIN" config user.name t
git -C "$MAIN" add -A >/dev/null && git -C "$MAIN" commit -qm seed

BARE="$(new_studio bare)"     # exists, holds no notes and no signals.json

# ── S3.2 — read the corpus ───────────────────────────────────────────────────

run_corpus "$MAIN" "$BARE" --job angles --date "$END"

[ "$RC" = 0 ] && ok "a window with gaps still produces a bundle, exit 0" \
  || bad "rc=$RC err=$ERR"

n="$(urls_in CORPUS | wc -l | tr -d ' ')"
[ "$n" = 16 ] \
  && ok "every declared in-window digest appears (2 leadership + 11 ai + 1 tech + 2 rva-events = 16)" \
  || bad "CORPUS holds $n items, want 16"

dupes="$(urls_in CORPUS | sort | uniq -d | tr '\n' ' ')"
[ -z "$dupes" ] && ok "each digest appears exactly once" || bad "duplicated: $dupes"

# Undeclared collections are driven off the config's collections: list, never
# off a glob of src/content/. Red the moment someone globs the directory.
if grep -q 'local-llm\|/richmond/' <<<"$OUT"; then
  bad "undeclared local-llm / richmond leaked into the bundle"
else
  ok "undeclared local-llm and richmond collections are ignored"
fi

# Window edges. Both files exist on disk one day outside the window.
if grep -q 'daily-kickoff/ai/2026-07-19' <<<"$OUT"; then
  bad "a digest one day before the window start was included"
else
  ok "a digest one day before the window start is excluded"
fi
if grep -q 'daily-kickoff/ai/2026-08-03' <<<"$OUT"; then
  bad "a digest one day after the window end was included"
else
  ok "a digest one day after the window end is excluded"
fi
grep -q 'daily-kickoff/ai/2026-07-20' <<<"$OUT" \
  && ok "a digest on the window's first day is included" || bad "start edge missing"
grep -q 'daily-kickoff/leadership/2026-08-01' <<<"$OUT" \
  && ok "a digest on the window's last day is included" || bad "end edge missing"

grep -q "^# CORPUS $START → $END\$" <<<"$OUT" \
  && ok "the header names the inclusive window ($START → $END is 14 days)" \
  || bad "window header: $(head -1 "$WORK/out.txt")"

# D4 — the digest URL is site + base + theme + file stem, which is what
# src/pages/[theme]/[slug].astro actually routes on.
grep -q '^URL: https://priyesh.fyi/daily-kickoff/leadership/2026-08-01$' <<<"$OUT" \
  && ok "digest URL is https://priyesh.fyi/daily-kickoff/<theme>/<slug>" \
  || bad "digest URL shape wrong"

grep -q '^\*\*TITLE leadership 2026-08-01\*\*$' <<<"$OUT" \
  && ok "title comes from frontmatter title" || bad "title missing"
grep -q '^Summary: TLDR leadership 2026-08-01$' <<<"$OUT" \
  && ok "summary comes from frontmatter tldr" || bad "tldr missing"
grep -q '^DATE: 2026-08-01$' <<<"$OUT" \
  && ok "date comes from frontmatter date, as YYYY-MM-DD" || bad "date missing"

# The invariant: Phase 2 reads and never writes. Red if anything ever caches,
# rewrites or normalises a digest in place.
[ -z "$(git -C "$MAIN" status --porcelain src/content/)" ] \
  && ok "git status --porcelain src/content/ is empty after a corpus run" \
  || bad "src/content/ was modified: $(git -C "$MAIN" status --porcelain src/content/)"

# Sections are always present, even when empty. A vanished section is
# indistinguishable from a bug, and on a fresh studio two of the three are empty.
for s in "YOUR NOTES" "YOUR SIGNAL" "CORPUS"; do
  grep -q "^## $s\$" <<<"$OUT" && ok "section '## $s' is printed" || bad "section '$s' missing"
done
[ "$(sec 'YOUR NOTES' | grep -c '^(none)$')" = 1 ] \
  && ok "an empty YOUR NOTES prints an explicit (none)" || bad "no (none) in YOUR NOTES"
[ "$(sec 'YOUR SIGNAL' | grep -c '^(none)$')" = 1 ] \
  && ok "an empty YOUR SIGNAL prints an explicit (none)" || bad "no (none) in YOUR SIGNAL"

# ── S3.2 — malformed frontmatter is a warning and a skip ─────────────────────

BAD="$(new_repo badfm)"
topic_cfg "$BAD" ai weekdays ai
angles_cfg "$BAD" '[ai]' '{ ai: 1.0 }'
mkdigest "$BAD" ai 2026-07-21
printf 'no frontmatter here at all\n' > "$BAD/src/content/ai/2026-07-22.md"
printf -- '---\ntitle: "x\ndate: 2026-07-23\n---\nbody\n' > "$BAD/src/content/ai/2026-07-23.md"
printf -- '---\ntitle: "x"\ndate: 2026-07-24\nbody with no closing fence\n' \
  > "$BAD/src/content/ai/2026-07-24.md"
printf -- '---\ntitle: "x"\ndate: 2026-07-27\ntheme: ai\n---\nno tldr\n' \
  > "$BAD/src/content/ai/2026-07-27.md"

run_corpus "$BAD" "$BARE" --job angles --date "$END"
[ "$RC" = 0 ] && [ "$(urls_in CORPUS | wc -l | tr -d ' ')" = 1 ] \
  && ok "four malformed digests are skipped and the one good digest survives" \
  || bad "malformed: rc=$RC items=$(urls_in CORPUS | wc -l | tr -d ' ') err=$ERR"
grep -q 'no opening frontmatter delimiter' <<<"$ERR" \
  && ok "a file with no frontmatter warns to stderr" || bad "no-frontmatter warning: $ERR"
grep -q 'not valid YAML' <<<"$ERR" \
  && ok "unparseable frontmatter YAML warns to stderr" || bad "bad-YAML warning: $ERR"
grep -q 'unterminated frontmatter' <<<"$ERR" \
  && ok "unterminated frontmatter warns to stderr" || bad "unterminated warning: $ERR"
grep -q 'missing required frontmatter field(s): tldr' <<<"$ERR" \
  && ok "a missing required field warns, naming the field" || bad "missing-field warning: $ERR"

# ── S3.2 — config resolution ─────────────────────────────────────────────────

run_corpus "$MAIN" "$BARE" --job nosuchjob --date "$END"
[ "$RC" != 0 ] && ok "an unknown job exits non-zero" || bad "unknown job: rc=$RC"
unnamed=""
for kind in $KINDS; do
  grep -q "scripts/$kind/nosuchjob.yaml" <<<"$ERR" || unnamed="$unnamed $kind"
done
[ -z "$unnamed" ] \
  && ok "the error names every kind searched ($KINDS)" \
  || bad "paths not named for:$unnamed — $ERR"

# The same idiom as fetch_sources.py --topic ai: a job defined under topics/ is
# found there. Red if resolution only ever looked in generators/.
cp "$MAIN/scripts/generators/angles.yaml" "$MAIN/scripts/topics/topicjob.yaml"
run_corpus "$MAIN" "$BARE" --job topicjob --date "$END"
[ "$RC" = 0 ] && ok "a job config under topics/ resolves too" || bad "topics/ lookup: rc=$RC err=$ERR"
rm -f "$MAIN/scripts/topics/topicjob.yaml"

# D5 — resolution lives in job-config.sh and is never re-implemented here.
( unset STUDIO_DIR; "$PYBIN" "$SELECT" --repo-dir "$MAIN" --job angles --date "$END" ) \
  >"$WORK/out.txt" 2>"$WORK/err.txt"
[ "$?" != 0 ] && grep -q 'resolve_studio_dir' "$WORK/err.txt" \
  && ok "an unset STUDIO_DIR is refused, pointing at resolve_studio_dir" \
  || bad "unset STUDIO_DIR: $(cat "$WORK/err.txt")"

# ── S4.9 — every job kind is walked ──────────────────────────────────────────
#
# A config is scripts/<kind>/<job>.yaml, and two loops walk the kinds:
# find_job_config() resolves the selecting job, and collection_schedules() builds
# the collection→schedule map the coverage header is computed from. The second is
# the dangerous one: a kind missing from it raises nothing, it just reports every
# collection that kind produces as `N/? (no job writes src/content/…/)` — a line
# that looks like a fact about the corpus rather than a hole in the tool.
#
# Each kind gets a fixture directory and a real run. Asserting the contents of
# JOB_KINDS would pass with either loop deleted.

py_kinds="$(sed -n 's/^JOB_KINDS = (\(.*\))$/\1/p' "$SELECT" | tr -d '",')"
[ -n "$py_kinds" ] && [ "$py_kinds" = "$KINDS" ] \
  && ok "JOB_KINDS matches the kinds exercised below ($KINDS)" \
  || bad "JOB_KINDS is '$py_kinds', this suite exercises '$KINDS' — one of them is stale"

for kind in $KINDS; do
  KR="$(new_repo "kind-$kind")"
  mkdir -p "$KR/scripts/$kind"

  # Writes a collection, so it must reach the schedule map. saturday over the
  # fixed window expects 2026-07-25 and 2026-08-01, and both digests exist.
  cat > "$KR/scripts/$kind/kindprod.yaml" <<EOF
name:     "kindprod"
schedule: saturday
producer: fetch_sources.py --topic kindprod
prompt:   scripts/prompts/kindprod.md
output:   src/content/kindcov/{{DATE}}.md
EOF

  # Two selecting jobs, identical but for where they live. The one under the
  # kind under test proves find_job_config() reaches that directory; the one
  # under generators/ stays resolvable when it does not, so the coverage
  # assertion below still runs and isolates collection_schedules().
  for picker in "$kind:kindpick" "generators:refpick"; do
    cat > "$KR/scripts/${picker%%:*}/${picker##*:}.yaml" <<EOF
name:     "${picker##*:}"
schedule: never
output:   \$STUDIO_DIR/angles/{{DATE}}.md

selection:
  lookback_days: 14
  collections: [kindcov]
  half_life_days: 7
  weights:
    theme:   { kindcov: 1.0 }
    starred: 1.5
    noted:   2.0
    done:    0.3
EOF
  done

  mkdigest "$KR" kindcov 2026-07-25
  mkdigest "$KR" kindcov 2026-08-01

  run_corpus "$KR" "$BARE" --job kindpick --date "$END"
  [ "$RC" = 0 ] \
    && ok "a selecting job under scripts/$kind/ resolves" \
    || bad "scripts/$kind/kindpick.yaml did not resolve: rc=$RC err=$ERR"

  run_corpus "$KR" "$BARE" --job refpick --date "$END"
  grep -q 'kindcov 2/2' <<<"$OUT" \
    && ok "a producer under scripts/$kind/ supplies its collection's schedule" \
    || bad "scripts/$kind/ absent from the schedule map: $(grep '^# coverage' <<<"$OUT")"
done

# ── S3.5 — coverage ──────────────────────────────────────────────────────────

run_corpus "$MAIN" "$BARE" --job angles --date "$END"
cov="$(grep '^# coverage:' <<<"$OUT")"

grep -q 'leadership 2/2' <<<"$cov" \
  && ok "a Saturday collection reads 2/2, not 2/14" || bad "leadership coverage: $cov"

# `weekdays` is Mon–Sat. Mon–Fri would make this 10, and would not expect
# 2026-08-01 (a Saturday) at all — so both halves of this go red together.
grep -q 'ai 11/12' <<<"$cov" \
  && ok "a weekdays collection expects 12 (Mon–Sat), not 10 (Mon–Fri)" || bad "ai coverage: $cov"
grep -q 'ai 11/12 (gap 2026-08-01)' <<<"$cov" \
  && ok "the missing Saturday of a weekdays collection is named as a gap" \
  || bad "Saturday gap not named: $cov"

# THE near-miss: topics/richmond-events.yaml writes src/content/rva-events/.
# Mapping collection -> schedule by config filename finds nothing for
# rva-events, which reads as 2/? here.
grep -q 'rva-events 2/2' <<<"$cov" \
  && ok "collection→schedule resolves through output:, so rva-events is 2/2" \
  || bad "richmond-events -> rva-events mapping: $cov"

# tech: 1 of 12, so 11 gaps — capped at 3 named, and it says so.
grep -q 'tech 1/12 (gap 2026-07-21, 2026-07-22, 2026-07-23 +8 more)' <<<"$cov" \
  && ok "a long gap list names 3 dates and declares the remainder (+8 more)" \
  || bad "gap cap: $cov"

grep -q 'signals:  none (absent)' <<<"$OUT" \
  && ok "an absent signals.json reads 'none (absent)', never a silent zero" \
  || bad "signals header: $(grep '^# signals' <<<"$OUT")"

# ── S3.5 — a digest on an unscheduled day must not fill a scheduled quota ────
#
# Not hypothetical: src/content/leadership/ really holds a Friday (2026-05-22), a
# Wednesday (2026-05-27) and a Sunday (2026-07-19) digest against a `saturday`
# schedule. Counting every digest in the window against a scheduled denominator
# printed `leadership 2/2 (gap 2026-07-18)` on the real corpus — full coverage
# claimed in the same breath as a named gap. The numerator now counts only
# digests landing on a scheduled day; off-schedule files are real content, so
# they are reported rather than dropped.
#
# The fixture mirrors the real shape exactly: window 2026-07-12 → 2026-07-25
# expects Saturdays 07-18 and 07-25; the collection holds 07-19 (Sunday) and
# 07-25 (Saturday).
OFFS="$(new_repo offsched)"
topic_cfg "$OFFS" leadership saturday leadership
angles_cfg "$OFFS" '[leadership]' '{ leadership: 3.0 }'
mkdigest "$OFFS" leadership 2026-07-19    # Sunday — off schedule
mkdigest "$OFFS" leadership 2026-07-25    # Saturday — on schedule
run_corpus "$OFFS" "$BARE" --job angles --date 2026-07-25
offcov="$(grep '^# coverage:' <<<"$OUT")"

grep -q 'leadership 1/2 (gap 2026-07-18) +1 off-schedule' <<<"$offcov" \
  && ok "an off-schedule digest does not fill a scheduled quota, and is reported" \
  || bad "off-schedule coverage: $offcov"

# The property, stated independently of the string: a header must never claim a
# complete count and name a gap at the same time. This is what actually went
# wrong, and it survives any future reformatting of the entry.
if grep -qE 'leadership ([0-9]+)/\1 .*gap' <<<"$offcov"; then
  bad "header claims full coverage AND names a gap: $offcov"
else
  ok "no coverage entry both claims a complete count and names a gap"
fi

# Both digests are still in the bundle — coverage accounting must not silently
# drop content it could not fit into the schedule.
n="$(urls_in CORPUS | wc -l | tr -d ' ')"
[ "$n" = 2 ] && ok "an off-schedule digest is still ranked into the corpus" \
  || bad "off-schedule digest count $n, want 2"

# ── S3.4 — a collection with no theme weight must not sink in silence ────────
#
# `theme_weights.get(theme, 0.0)` scores an unweighted collection 0.0, which put
# `leadership` below `rva-events` (0.1) — last, from first — with nothing on
# stderr and a coverage header still reading `leadership 2/2`. The config is
# meant to be hand-tuned over the first quarter, so a one-character typo is the
# expected failure, not an exotic one. A typo shows as one missing entry and one
# orphan, so both directions are checked.
TYPO="$(new_repo typo)"
topic_cfg "$TYPO" leadership saturday leadership
topic_cfg "$TYPO" ai weekdays ai
angles_cfg "$TYPO" '[leadership, ai]' '{ leadershp: 3.0, ai: 1.0 }'
mkdigest "$TYPO" leadership 2026-08-01
mkdigest "$TYPO" ai 2026-07-31
run_corpus "$TYPO" "$BARE" --job angles --date "$END"

grep -q "collections lists 'leadership' but weights.theme has no entry" <<<"$ERR" \
  && ok "a collection with no theme weight is named on stderr, not silently zeroed" \
  || bad "no missing-weight warning: $ERR"

grep -q "weights.theme names 'leadershp', which is not in selection.collections" <<<"$ERR" \
  && ok "an orphaned theme weight is named on stderr (the other half of a typo)" \
  || bad "no orphan-weight warning: $ERR"

# The consequence the warning is about, asserted so the warning cannot drift
# away from what actually happens: unweighted really does rank last.
first="$(urls_in CORPUS | head -1)"
grep -q '/ai/2026-07-31$' <<<"$first" \
  && ok "an unweighted collection really does rank below a weighted one" \
  || bad "expected the weighted ai digest first, got: $first"

# A correctly-spelled config must stay silent, or the warning is noise that
# trains you to ignore stderr — and this assertion is what keeps it honest.
run_corpus "$MAIN" "$BARE" --job angles --date "$END"
grep -q 'weights.theme' <<<"$ERR" \
  && bad "a correct config warned about weights: $ERR" \
  || ok "a config whose collections and weights agree warns about neither"

# A collection nothing writes to gets no invented denominator.
ORPH="$(new_repo orphan)"
angles_cfg "$ORPH" '[alpha]' '{ alpha: 1.0 }'
mkdigest "$ORPH" alpha 2026-07-21
run_corpus "$ORPH" "$BARE" --job angles --date "$END"
grep -q 'alpha 1/? (no job writes src/content/alpha/)' <<<"$OUT" \
  && ok "a collection with no producing job reports ?, not a guessed denominator" \
  || bad "orphan coverage: $(grep '^# coverage' <<<"$OUT")"

# ── S3.5 — the one error case ────────────────────────────────────────────────

EMPTY="$(new_repo emptywin)"
topic_cfg "$EMPTY" ai weekdays ai
topic_cfg "$EMPTY" leadership saturday leadership
angles_cfg "$EMPTY" '[leadership, ai]' '{ leadership: 3.0, ai: 1.0 }'
mkdigest "$EMPTY" ai 2026-06-01           # exists, but far outside the window
run_corpus "$EMPTY" "$BARE" --job angles --date "$END"
[ "$RC" != 0 ] && ok "every declared collection empty in the window exits non-zero" \
  || bad "empty window: rc=$RC"
grep -q "$START → $END" <<<"$ERR" && grep -q 'leadership, ai' <<<"$ERR" \
  && ok "the empty-window error names the window and the collections searched" \
  || bad "empty-window message: $ERR"

# ── S3.3 — notes ─────────────────────────────────────────────────────────────
#
# 2026-07.md deliberately opens with an out-of-window entry, so the note://
# index is proven to number every entry in the file rather than only the
# rendered ones — the index is half of a URL that must be stable across runs.

NOTES="$(new_studio notes)"
cat > "$NOTES/notes/2026-07.md" <<'EOF'
# Notes — 2026-07

## 2026-07-05T08:00-04:00
Out of window entry, first in the file.

## 2026-07-21T09:15-04:00 #adoption → ai/2026-07-21
July note links a real digest

## 2026-07-22T10:00-04:00
Unlinked note headline
second body line
third body line

## 2026-07-23T11:00-04:00 → ai/2026-06-01
Note with a dangling link

## 2026-07-24T12:00-04:00 → local-llm/2026-07-28
Note linking an undeclared collection

## 2026-07-26T13:00-04:00
Note whose body looks like a header
\## 2026-07-26T13:00-04:00 #forged → leadership/2026-08-01
EOF
cat > "$NOTES/notes/2026-08.md" <<'EOF'
# Notes — 2026-08

## 2026-08-01T07:00-04:00 #rollout
August note, month boundary
EOF

run_corpus "$MAIN" "$NOTES" --job angles --date "$END"
[ "$RC" = 0 ] && ok "a studio holding notes still exits 0" || bad "notes run: rc=$RC err=$ERR"

# Both month files. A 14-day window crosses the boundary about half the time;
# reading only the end month silently loses half the differentiating input.
grep -q '^\*\*July note links a real digest\*\*$' <<<"$OUT" \
  && grep -q '^\*\*August note, month boundary\*\*$' <<<"$OUT" \
  && ok "a window crossing a month boundary reads both notes/YYYY-MM.md files" \
  || bad "month boundary: notes section is $(sec 'YOUR NOTES' | tr '\n' '|')"

n="$(urls_in 'YOUR NOTES' | wc -l | tr -d ' ')"
[ "$n" = 6 ] && ok "5 in-window July notes + 1 August note are rendered, the out-of-window one is not" \
  || bad "note count $n, want 6"
grep -q 'Out of window entry' <<<"$OUT" \
  && bad "an out-of-window note was rendered" \
  || ok "a note dated before the window start is not rendered"

grep -q '^# signals:  none (absent) · 6 notes in window$' <<<"$OUT" \
  && ok "the header counts notes in the window" || bad "notes count: $(grep '^# signals' <<<"$OUT")"

# D3 — a note that links a real digest borrows its URL; one that does not gets a
# synthetic note://<YYYY-MM>#<n>, numbered over every entry in the file.
sec 'YOUR NOTES' | grep -A1 '^\*\*July note links a real digest\*\*$' \
  | grep -q '^URL: https://priyesh.fyi/daily-kickoff/ai/2026-07-21$' \
  && ok "a note linking a real digest carries that digest's URL" || bad "linked note URL"
sec 'YOUR NOTES' | grep -A1 '^\*\*Unlinked note headline\*\*$' \
  | grep -q '^URL: note://2026-07#3$' \
  && ok "an unlinked note gets note://<YYYY-MM>#<n>, indexed over every entry in the file" \
  || bad "note:// URL: $(sec 'YOUR NOTES' | grep -A1 'Unlinked note headline')"
sec 'YOUR NOTES' | grep -A1 '^\*\*Note with a dangling link\*\*$' \
  | grep -q '^URL: note://2026-07#4$' \
  && ok "a note whose link names no digest falls back to note:// and is still rendered" \
  || bad "dangling note URL"
grep -q 'links ai/2026-06-01, which names no digest' <<<"$ERR" \
  && ok "a dangling note link warns to stderr" || bad "dangling warning: $ERR"
grep -q 'links local-llm/2026-07-28, which names no digest in a declared collection' <<<"$ERR" \
  && ok "a note linking an existing file in an undeclared collection warns and earns no boost" \
  || bad "undeclared link warning: $ERR"

grep -q '^Summary: #adoption$' <<<"$OUT" \
  && ok "a note's tags are carried into its summary" || bad "tags missing"
# The first body line is the title, the rest are the summary — so line two opens
# the Summary: field and line three follows it bare.
sec 'YOUR NOTES' | grep -q '^Summary: second body line$' \
  && sec 'YOUR NOTES' | grep -q '^third body line$' \
  && ok "a multi-line note keeps every remaining body line" || bad "body lines lost"

# note_escape_body() escaped this line on write precisely so it could not parse
# as a second entry carrying a forged tag and a forged link. Honour it on read:
# the backslash comes off, and no seventh entry appears.
# It is body line two, so it lands in the Summary field — with its leading
# backslash removed, and without having parsed as an entry of its own.
sec 'YOUR NOTES' | grep -q '^Summary: ## 2026-07-26T13:00-04:00 #forged → leadership/2026-08-01$' \
  && ok "an escaped header-shaped body line is unescaped on read" \
  || bad "escaped body line: $(sec 'YOUR NOTES' | grep forged)"
if urls_in 'YOUR NOTES' | grep -q 'leadership/2026-08-01'; then
  bad "the forged link in an escaped body line was honoured"
else
  ok "the forged link in an escaped body line is not honoured"
fi

# ── S3.3 — signals ───────────────────────────────────────────────────────────

SIG="$(new_studio sig)"
cat > "$SIG/state/signals.json" <<'EOF'
{
  "schema": 2,
  "mergedAt": "2026-08-02T09:00:00-04:00",
  "items": {
    "wl:ai:2026-07-31:try:0":          { "starred": true, "seenAt": "2026-08-01T14:31:07-04:00" },
    "wl:leadership:2026-08-01:share:0":{ "starred": true, "status": "done", "seenAt": "2026-08-02T10:00:00-04:00" },
    "wl:leadership:2026-08-01:read:1": { "starred": true, "seenAt": "2026-08-02T10:00:01-04:00" },
    "wl:ai:2026-07-24:try:0":          { "note": "my own thought", "seenAt": "2026-07-30T08:00:00-04:00" },
    "wl:ai:2026-07-27:try:0":          { "status": "snoozed", "seenAt": "2026-07-30T08:00:00-04:00" },
    "wl:ai:2026-07-30:skip:0":         { "starred": true, "seenAt": "2026-07-31T08:00:00-04:00" },
    "wl:ai:2026-07-28:try:99":         { "starred": true, "seenAt": "2026-07-31T08:00:00-04:00" },
    "wl:ai:2026-08-01:try:0":          { "starred": true, "seenAt": "2026-08-01T08:00:00-04:00" },
    "wl:ai:2026-01-05:try:0":          { "starred": true, "seenAt": "2026-01-06T08:00:00-04:00" },
    "wl:malformed":                    { "starred": true, "seenAt": "2026-08-01T08:00:00-04:00" }
  }
}
EOF

run_corpus "$MAIN" "$SIG" --job angles --date "$END"
[ "$RC" = 0 ] && ok "a studio holding signals still exits 0" || bad "signals run: rc=$RC err=$ERR"

# THE TYPE TOKEN TRAP: the key says `read`, the frontmatter field is
# `readDeeper`. Using the key's token as the field name finds nothing and the
# item silently disappears.
grep -q '^\*\*READ leadership 2026-08-01 one\*\*$' <<<"$OUT" \
  && ok "a 'read' signal key resolves against the readDeeper frontmatter field" \
  || bad "read -> readDeeper mapping: $(sec 'YOUR SIGNAL' | tr '\n' '|')"

# share entries are {what, who} objects, rendered exactly as the site rendered
# them (src/pages/index.astro).
grep -q '^\*\*SHARE what leadership 2026-08-01 zero → the team\*\*$' <<<"$OUT" \
  && ok "a share signal renders as 'what → who'" || bad "share rendering"

grep -q '^\*\*TRY ai 2026-07-31 zero\*\*$' <<<"$OUT" \
  && ok "a try signal resolves against actions.try" || bad "try rendering"

sec 'YOUR SIGNAL' | grep -q '^Summary: starred · done · leadership/2026-08-01 SHARE #0$' \
  && ok "a signal carries its provenance: theme/date, type and index" \
  || bad "provenance: $(sec 'YOUR SIGNAL' | grep '^Summary')"
sec 'YOUR SIGNAL' | grep -q 'my own thought' \
  && ok "a signal's own note is carried into the bundle" || bad "signal note missing"

# skip items have no watchlist key at all, so `skip` is an unknown token — and
# the frontmatter DOES have a skip field, so a mapping built by guessing would
# resolve it and quietly widen the contract.
grep -q "unknown type 'skip'" <<<"$ERR" \
  && ok "an unknown type token warns and is skipped, never crashes" || bad "unknown token: $ERR"
if grep -q 'SKIP ai 2026-07-30 zero' <<<"$OUT"; then
  bad "a skip item was resolved through an invented type mapping"
else
  ok "a skip item is not resolved — skip has no watchlist key"
fi

grep -q 'points past actions.try' <<<"$ERR" \
  && ok "an out-of-range action index warns and is skipped" || bad "out-of-range: $ERR"
grep -q 'names no digest at src/content/ai/2026-08-01.md' <<<"$ERR" \
  && ok "a signal naming a deleted digest warns and is skipped" || bad "deleted digest: $ERR"
grep -q "signal key 'wl:malformed' is not wl:" <<<"$ERR" \
  && ok "a malformed signal key warns and is skipped" || bad "malformed key: $ERR"
if grep -q '2026-01-05' <<<"$ERR"; then
  bad "an ordinary out-of-window signal key produced a warning"
else
  ok "an out-of-window signal key is skipped in silence — it is ordinary, not a fault"
fi

# snoozed and archived are deliberate negative signal.
if grep -q 'TRY ai 2026-07-27 zero' <<<"$OUT"; then
  bad "a snoozed item was rendered under YOUR SIGNAL"
else
  ok "a snoozed item is not rendered as signal"
fi

n="$(urls_in 'YOUR SIGNAL' | wc -l | tr -d ' ')"
[ "$n" = 4 ] && ok "exactly the 4 resolvable in-window signals are rendered" \
  || bad "signal count $n, want 4"

# 8 starred keys in the store, 6 of them inside the window, 4 records rendered.
#
# The two star counts must share a denominator. The header previously read
# "8 starred (4 rendered in window)", pairing a store-wide star count with a
# rendered-RECORD count — and a record is not a star: a `done` item with no star
# renders, and a star whose action index no longer exists does not. That form
# read as "4 of your 8 stars are here" when the true figure was 6. `shown` is
# reported separately precisely because it counts a different thing.
grep -q '^# signals:  exported 2026-08-02 (0d old) · 6 of 8 starred in window · 4 shown · 0 notes in window$' <<<"$OUT" \
  && ok "the header reports export date, age, and star counts sharing a denominator" \
  || bad "signals header: $(grep '^# signals' <<<"$OUT")"

# The property behind the string above, so a future reshuffle of the header
# cannot quietly reintroduce a rendered-record count in a starred slot: the
# in-window star count must never exceed the store-wide one, and here it must
# also differ from the rendered count — otherwise this fixture would stop
# distinguishing the two and the assertion above would go vacuous.
hdr="$(grep '^# signals:' <<<"$OUT")"
s_win="$(sed -E 's/.*· ([0-9]+) of ([0-9]+) starred in window.*/\1/' <<<"$hdr")"
s_tot="$(sed -E 's/.*· ([0-9]+) of ([0-9]+) starred in window.*/\2/' <<<"$hdr")"
s_shown="$(sed -E 's/.*· ([0-9]+) shown.*/\1/' <<<"$hdr")"
if [ "$s_win" -le "$s_tot" ] && [ "$s_win" != "$s_shown" ]; then
  ok "in-window stars ($s_win) ≤ total ($s_tot), and distinct from records shown ($s_shown)"
else
  bad "header counts not comparable: win=$s_win tot=$s_tot shown=$s_shown"
fi

# Age is measured from --date, not wall-clock, or the bundle would stop being
# byte-reproducible the day after it was built.
run_corpus "$MAIN" "$SIG" --job angles --date 2026-08-05
grep -q 'exported 2026-08-02 (3d old)' <<<"$OUT" \
  && ok "signal age is measured from --date, so the bundle stays reproducible" \
  || bad "signal age: $(grep '^# signals' <<<"$OUT")"

# Corrupt is not the same as absent, and neither may pretend the signal was read.
CORRUPT="$(new_studio corrupt)"
printf 'not json at all\n' > "$CORRUPT/state/signals.json"
run_corpus "$MAIN" "$CORRUPT" --job angles --date "$END"
[ "$RC" = 0 ] && ok "a corrupt signals.json still produces a bundle, exit 0" || bad "corrupt: rc=$RC"
grep -q '^# signals:  none (unreadable' <<<"$OUT" \
  && ok "a corrupt signals.json reads 'none (unreadable …)' in the header" \
  || bad "corrupt header: $(grep '^# signals' <<<"$OUT")"
grep -q 'is unreadable' <<<"$ERR" \
  && ok "a corrupt signals.json warns to stderr" || bad "corrupt warning: $ERR"

SHAPED="$(new_studio shaped)"
printf '{"schema": 2, "mergedAt": "x"}\n' > "$SHAPED/state/signals.json"
run_corpus "$MAIN" "$SHAPED" --job angles --date "$END"
[ "$RC" = 0 ] && grep -q '^# signals:  none (not a signals store)' <<<"$OUT" \
  && ok "valid JSON of the wrong shape is reported, not read as empty signal" \
  || bad "wrong-shape store: rc=$RC $(grep '^# signals' <<<"$OUT")"

# ── S3.4 — ranking ───────────────────────────────────────────────────────────

run_corpus "$MAIN" "$BARE" --job angles --date "$END"
urls_in CORPUS > "$WORK/order.txt"
lead_max=0; ai_pos=""
while IFS= read -r line; do
  n="${line%%:*}"; u="${line#*:}"
  case "$u" in
    */leadership/*) [ "$n" -gt "$lead_max" ] && lead_max="$n" ;;
    */ai/*)         ai_pos="$ai_pos $n" ;;
  esac
done < <(grep -n . "$WORK/order.txt")
set -- $ai_pos
ai_median="${6:-0}"   # 11 ai digests -> the 6th in rank order is the median
[ "$lead_max" -lt "$ai_median" ] \
  && ok "both leadership digests rank above the median ai digest (2 against 11)" \
  || bad "leadership last at $lead_max, ai median at $ai_median"

# Same day, same theme is impossible — one file per date per collection — so the
# star / note cases use two equally weighted collections on one date. beta is
# boosted deliberately: alpha wins the tie-break on name, so an unapplied boost
# leaves alpha first and the assertion goes red.
BOOST="$(new_repo boost)"
angles_cfg "$BOOST" '[alpha, beta]' '{ alpha: 1.0, beta: 1.0 }'
mkdigest "$BOOST" alpha "$END"
mkdigest "$BOOST" beta  "$END"

run_corpus "$BOOST" "$BARE" --job angles --date "$END"
[ "$(urls_in CORPUS | head -1)" = "https://priyesh.fyi/daily-kickoff/alpha/$END" ] \
  && ok "with no boosts, an exact tie breaks on theme name (control)" \
  || bad "control order: $(urls_in CORPUS | tr '\n' ' ')"

STAR="$(new_studio star)"
cat > "$STAR/state/signals.json" <<EOF
{ "schema": 2, "items": {
  "wl:beta:$END:try:0": { "starred": true, "seenAt": "${END}T08:00:00-04:00" } } }
EOF
run_corpus "$BOOST" "$STAR" --job angles --date "$END"
[ "$(urls_in CORPUS | head -1)" = "https://priyesh.fyi/daily-kickoff/beta/$END" ] \
  && ok "of two same-day digests differing only in a star, the starred one ranks first" \
  || bad "star order: $(urls_in CORPUS | tr '\n' ' ')"

NOTED="$(new_studio noted)"
cat > "$NOTED/notes/2026-08.md" <<EOF
# Notes — 2026-08

## ${END}T09:00-04:00 → beta/$END
A note pointing at beta
EOF
run_corpus "$BOOST" "$NOTED" --job angles --date "$END"
[ "$(urls_in CORPUS | head -1)" = "https://priyesh.fyi/daily-kickoff/beta/$END" ] \
  && ok "a digest linked from a note ranks above an equivalent unlinked one" \
  || bad "noted order: $(urls_in CORPUS | tr '\n' ' ')"

# ── S3.4 — determinism ───────────────────────────────────────────────────────
#
# Byte-identical output over an unchanged corpus is what makes an Epic 4 prompt
# change A/B-testable against a fixed bundle. Two runs in one process would pass
# even if the code iterated a set, because CPython's set order is stable for a
# fixed hash seed — so the seed is varied deliberately.

FULL="$(new_studio full)"
cp "$NOTES/notes/2026-07.md" "$NOTES/notes/2026-08.md" "$FULL/notes/"
cp "$SIG/state/signals.json" "$FULL/state/"

STUDIO_DIR="$FULL" PYTHONHASHSEED=0 "$PYBIN" "$SELECT" --repo-dir "$MAIN" \
  --job angles --date "$END" >"$WORK/det1.txt" 2>/dev/null
STUDIO_DIR="$FULL" PYTHONHASHSEED=0 "$PYBIN" "$SELECT" --repo-dir "$MAIN" \
  --job angles --date "$END" >"$WORK/det2.txt" 2>/dev/null
diff -q "$WORK/det1.txt" "$WORK/det2.txt" >/dev/null \
  && ok "two runs over an unchanged corpus are byte-identical" || bad "runs differ"

STUDIO_DIR="$FULL" PYTHONHASHSEED=12345 "$PYBIN" "$SELECT" --repo-dir "$MAIN" \
  --job angles --date "$END" >"$WORK/det3.txt" 2>/dev/null
diff -q "$WORK/det1.txt" "$WORK/det3.txt" >/dev/null \
  && ok "output does not change under a different PYTHONHASHSEED (no set iteration leaked)" \
  || bad "hash-seed sensitive: $(diff "$WORK/det1.txt" "$WORK/det3.txt" | head -4)"

[ -s "$WORK/det1.txt" ] && grep -q '^URL: note://' "$WORK/det1.txt" \
  && grep -q '^\*\*TRY ai 2026-07-31 zero\*\*$' "$WORK/det1.txt" \
  && ok "the determinism fixture actually carries notes and signals" \
  || bad "determinism fixture is degenerate"

# A DELIBERATE score tie: half_life_days 7, so
#   alpha  weight 2.0, age 7 days -> 2.0 × 0.5**(7/7) = 1.0
#   zulu   weight 1.0, age 0 days -> 1.0 × 0.5**(0/7) = 1.0
# exactly equal in IEEE double. collections: is listed zulu-first, so a sort on
# -score alone is stable and leaves zulu first; a total key puts alpha first.
TIE="$(new_repo tie)"
angles_cfg "$TIE" '[zulu, alpha]' '{ zulu: 1.0, alpha: 2.0 }'
mkdigest "$TIE" zulu  "$END"
mkdigest "$TIE" alpha 2026-07-26
run_corpus "$TIE" "$BARE" --job angles --date "$END"
[ "$(urls_in CORPUS | head -1)" = "https://priyesh.fyi/daily-kickoff/alpha/2026-07-26" ] \
  && ok "a constructed score tie breaks on the total key, not on input order" \
  || bad "tie order: $(urls_in CORPUS | tr '\n' ' ')"
cp "$WORK/out.txt" "$WORK/tie1.txt"

# Same corpus, collections: reversed. Ordering must not move.
angles_cfg "$TIE" '[alpha, zulu]' '{ zulu: 1.0, alpha: 2.0 }'
run_corpus "$TIE" "$BARE" --job angles --date "$END"
diff -q <(urls_in CORPUS) <(sed -n 's/^URL: //p' "$WORK/tie1.txt") >/dev/null \
  && ok "reversing collections: leaves the tied order unchanged" \
  || bad "order follows config order: $(urls_in CORPUS | tr '\n' ' ')"

# And score still dominates the tie-break: give zulu more weight and it wins,
# which is what proves the case above was a tie rather than alpha simply
# outscoring zulu.
angles_cfg "$TIE" '[zulu, alpha]' '{ zulu: 1.5, alpha: 2.0 }'
run_corpus "$TIE" "$BARE" --job angles --date "$END"
[ "$(urls_in CORPUS | head -1)" = "https://priyesh.fyi/daily-kickoff/zulu/$END" ] \
  && ok "raising a theme weight past the tie makes it rank first — score dominates" \
  || bad "score does not dominate: $(urls_in CORPUS | tr '\n' ' ')"

# ── --date defaults to today ─────────────────────────────────────────────────

TODAY="$(date +%Y-%m-%d)"
OLD="$(date -j -v-20d +%Y-%m-%d 2>/dev/null || date -d '20 days ago' +%Y-%m-%d)"
NOW="$(new_repo nowrepo)"
angles_cfg "$NOW" '[alpha]' '{ alpha: 1.0 }'
mkdigest "$NOW" alpha "$TODAY"
mkdigest "$NOW" alpha "$OLD"
run_corpus "$NOW" "$BARE" --job angles
[ "$RC" = 0 ] && grep -q "→ $TODAY\$" <<<"$(head -1 "$WORK/out.txt")" \
  && ok "--date defaults to today" || bad "default date: $(head -1 "$WORK/out.txt")"
[ "$(urls_in CORPUS | wc -l | tr -d ' ')" = 1 ] \
  && ok "the default window still excludes a digest 20 days old" \
  || bad "default window: $(urls_in CORPUS | tr '\n' ' ')"

# ── D4 — the URL constant must track astro.config.mjs ────────────────────────
#
# A base-path change that is not mirrored in select_corpus.py emits dead links
# into every future bundle and nothing looks broken. Fail a test instead.

py_site="$(sed -n 's/^SITE = "\(.*\)"$/\1/p' "$SELECT")"
py_base="$(sed -n 's/^BASE = "\(.*\)"$/\1/p' "$SELECT")"
astro_site="$(sed -n "s/^[[:space:]]*site:[[:space:]]*'\(.*\)',*$/\1/p" "$REPO_DIR/astro.config.mjs")"
astro_base="$(sed -n "s/^[[:space:]]*base:[[:space:]]*'\(.*\)',*$/\1/p" "$REPO_DIR/astro.config.mjs")"
[ -n "$astro_site" ] && [ "$py_site" = "$astro_site" ] \
  && ok "SITE matches site: in astro.config.mjs ($astro_site)" \
  || bad "SITE '$py_site' vs astro.config.mjs '$astro_site'"
[ -n "$astro_base" ] && [ "$py_base" = "$astro_base" ] \
  && ok "BASE matches base: in astro.config.mjs ($astro_base)" \
  || bad "BASE '$py_base' vs astro.config.mjs '$astro_base'"

echo
if [ "$FAIL" = "0" ]; then
  echo "PASS ($COUNT) — select_corpus tests passed"
else
  echo "FAIL — select_corpus tests FAILED ($COUNT assertions run)"
fi
exit "$FAIL"
