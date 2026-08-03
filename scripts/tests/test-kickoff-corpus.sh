#!/bin/bash
# Regression test for `kickoff corpus` — S3.6, and for the `never` schedule word
# that generators/angles.yaml depends on.
#
# The CLI is exercised against a COPY of scripts/{lib,studio,topics,generators}
# over a fixture src/content/, because kickoff derives REPO_DIR from its own
# resolved path — a symlink would resolve straight back to the real repo, and
# the real corpus changes every night. The copy is made fresh from the working
# tree on every run, so it is always the current code under test.
#
# The second half re-plays run-jobs.sh's per-config gate against the REAL
# scripts/generators/angles.yaml. That config exists only for its `selection:`
# block; `output:` and `schedule:` are there because the orchestrator globs
# scripts/generators/*.yaml and marks a job FAILED — exit 1 for the whole
# nightly run — if `output:` is empty or `schedule:` is a word it does not know.
#
# No network, no writes outside $TMPDIR, no git writes to the real repo.
#
#   bash scripts/tests/test-kickoff-corpus.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

FAIL=0
COUNT=0
ok()   { COUNT=$((COUNT + 1)); printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad()  { COUNT=$((COUNT + 1)); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=1; }
skip() { printf "  \033[33mskip\033[0m  %s\n" "$*"; }

# Every assertion below runs Python through the project's own venv. On a clone
# where it has not been built yet there is nothing to test against and no way to
# build one without the network, so say so rather than reporting a red.
if ! "$PYBIN" -c 'import yaml' 2>/dev/null; then
  echo "kickoff corpus"
  skip "pyyaml unavailable in $PYBIN — run any kickoff command once to build scripts/.venv"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

END=2026-08-02

# ── A fixture repo carrying the real CLI over a fixture corpus ───────────────

FIX="$WORK/repo"
mkdir -p "$FIX/scripts" "$FIX/src/content"
cp -R "$REPO_DIR/scripts/lib" "$FIX/scripts/lib"
cp -R "$REPO_DIR/scripts/studio" "$FIX/scripts/studio"
cp -R "$REPO_DIR/scripts/topics" "$FIX/scripts/topics"
cp -R "$REPO_DIR/scripts/generators" "$FIX/scripts/generators"
cp "$REPO_DIR/src/content.config.ts" "$FIX/src/content.config.ts"
KICKOFF="$FIX/scripts/studio/kickoff"

# ensure_venv() would otherwise `python3 -m venv` + `pip install` inside the
# fixture — a network call, in a suite that must not make one. It only probes
# for scripts/.venv/bin/python3, so the real venv is symlinked in whole:
# symlinking the interpreter alone would leave CPython looking for pyvenv.cfg
# beside the link, find none, and fall back to the base install with no pyyaml.
if [ -d "$REPO_DIR/scripts/.venv" ]; then
  ln -s "$REPO_DIR/scripts/.venv" "$FIX/scripts/.venv"
else
  mkdir -p "$FIX/scripts/.venv/bin"
  ln -s "$PYBIN" "$FIX/scripts/.venv/bin/python3"
fi

mkdigest() {  # THEME SLUG
  mkdir -p "$FIX/src/content/$1"
  cat > "$FIX/src/content/$1/$2.md" <<EOF
---
title: "TITLE $1 $2"
date: $2
theme: $1
format: daily
tldr: "TLDR $1 $2"
itemCount: 2
readTimeMinutes: 3
actions:
  try:
    - "TRY $1 $2 zero"
---

Body.
EOF
}
mkdigest ai 2026-07-28
mkdigest ai 2026-07-30
mkdigest leadership 2026-08-01
mkdigest tech 2026-07-21
mkdigest rva-events 2026-07-25

git -C "$FIX" init -q -b main
git -C "$FIX" config user.email t@t.t
git -C "$FIX" config user.name t
git -C "$FIX" add -A >/dev/null && git -C "$FIX" commit -qm seed

# A studio with a remote it could push to, so "made no commit" is a real claim
# rather than an accident of configuration.
new_studio() {  # NAME -> path
  local d="$WORK/$1" x
  for x in notes angles drafts published engagement state; do mkdir -p "$d/$x"; done
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  touch "$d/state/.gitkeep"
  git -C "$d" add -A >/dev/null && git -C "$d" commit -qm seed
  git init -q --bare "$d.git"
  git -C "$d" remote add origin "$d.git"
  git -C "$d" push -q -u origin main
  echo "$d"
}

run_kickoff() {  # STUDIO [ARGS...]
  local studio="$1"; shift
  ( cd "$WORK" && HOME="$WORK/home" STUDIO_DIR="$studio" bash "$KICKOFF" "$@" ) \
    >"$WORK/out.txt" 2>"$WORK/err.txt"
  RC=$?
  OUT="$(cat "$WORK/out.txt")"
  ERR="$(cat "$WORK/err.txt")"
}

studio_fingerprint() {  # STUDIO -> a line per file, path and checksum
  find "$1" -type f ! -path '*/.git/*' -exec shasum {} \; | sort
}

mkdir -p "$WORK/home"
S="$(new_studio studio)"

echo "kickoff corpus"

# ── S3.6 — it prints a bundle, and writes nothing anywhere ───────────────────

before_studio="$(studio_fingerprint "$S")"
before_commits="$(git -C "$S" rev-list --count HEAD)"

run_kickoff "$S" corpus --date "$END"
[ "$RC" = 0 ] && ok "kickoff corpus exits 0" || bad "rc=$RC err=$ERR"
grep -q "^# CORPUS 2026-07-20 → $END\$" <<<"$OUT" \
  && ok "the bundle header goes to stdout" || bad "header: $(head -1 "$WORK/out.txt")"
grep -q '^# coverage: ' <<<"$OUT" && ok "the coverage header is printed" || bad "no coverage line"
grep -q '^# signals:  ' <<<"$OUT" && ok "the signals header is printed" || bad "no signals line"
for s in "YOUR NOTES" "YOUR SIGNAL" "CORPUS"; do
  grep -q "^## $s\$" <<<"$OUT" && ok "section '## $s' is printed" || bad "section '$s' missing"
done
grep -q '^URL: ' <<<"$OUT" \
  && ok "the bundle carries ^URL: lines, which is what run-job.sh validates on" \
  || bad "no URL lines"

# Writes nothing: not into the studio, not into src/content/, and no commit —
# the whole point of S3.6 is that it is safe to run for inspection.
[ "$(studio_fingerprint "$S")" = "$before_studio" ] \
  && ok "nothing under \$STUDIO_DIR is created or changed" || bad "studio changed"
[ "$(git -C "$S" rev-list --count HEAD)" = "$before_commits" ] \
  && ok "no commit is made in the studio" || bad "studio gained a commit"
[ -z "$(git -C "$FIX" status --porcelain)" ] \
  && ok "the repo working tree is untouched, src/content/ included" \
  || bad "repo changed: $(git -C "$FIX" status --porcelain | head -3)"

# ── S3.6 — argument handling ─────────────────────────────────────────────────

# --job must actually select. A second config restricted to one collection makes
# a hardcoded 'angles' visible instead of passing by luck.
cat > "$FIX/scripts/generators/aionly.yaml" <<'EOF'
name:     "AI only"
schedule: never
output:   $STUDIO_DIR/angles/{{DATE}}.md
selection:
  lookback_days: 14
  collections: [ai]
  half_life_days: 7
  weights:
    theme: { ai: 1.0 }
EOF
run_kickoff "$S" corpus --job aionly --date "$END"
[ "$RC" = 0 ] && ! grep -q 'daily-kickoff/leadership/' <<<"$OUT" \
  && grep -q 'daily-kickoff/ai/' <<<"$OUT" \
  && ok "--job selects the named config's collections" || bad "--job ignored: rc=$RC"
rm -f "$FIX/scripts/generators/aionly.yaml"

run_kickoff "$S" corpus --job angles --date "$END"
[ "$RC" = 0 ] && grep -q 'daily-kickoff/leadership/' <<<"$OUT" \
  && ok "--job angles is the default config, and names it explicitly too" || bad "--job angles: rc=$RC"

run_kickoff "$S" corpus --date 2026-07-25
grep -q '^# CORPUS 2026-07-12 → 2026-07-25$' <<<"$OUT" \
  && ok "--date is passed through and moves the window" || bad "date: $(head -1 "$WORK/out.txt")"

run_kickoff "$S" corpus --job nosuchjob --date "$END"
[ "$RC" != 0 ] && grep -q 'scripts/generators/nosuchjob.yaml' <<<"$ERR" \
  && ok "an unknown --job exits non-zero, naming the paths searched" || bad "unknown job: rc=$RC"

run_kickoff "$S" corpus --bogus
[ "$RC" != 0 ] && grep -q 'unknown option' <<<"$ERR" \
  && ok "an unknown option is refused" || bad "unknown option: rc=$RC out=$OUT err=$ERR"

run_kickoff "$S" corpus stray
[ "$RC" != 0 ] && grep -q 'unexpected argument' <<<"$ERR" \
  && ok "a stray positional argument is refused" || bad "stray arg: rc=$RC"

run_kickoff "$S" corpus --job
[ "$RC" != 0 ] && grep -q 'needs a value' <<<"$ERR" \
  && ok "--job with no value is refused" || bad "--job bare: rc=$RC"

# require_studio, same gate every other command uses: an unresolvable studio must
# fail before anything is read, not yield a plausible bundle with no notes.
run_kickoff "$WORK/no-such-studio" corpus --date "$END"
[ "$RC" != 0 ] && [ -z "$OUT" ] && grep -q 'STUDIO_DIR does not exist' <<<"$ERR" \
  && ok "a missing STUDIO_DIR fails before any output is printed" || bad "missing studio: rc=$RC"

INCOMPLETE="$WORK/incomplete"
mkdir -p "$INCOMPLETE/notes"
run_kickoff "$INCOMPLETE" corpus --date "$END"
[ "$RC" != 0 ] && grep -q 'missing required directories' <<<"$ERR" \
  && ok "a studio missing its layout is refused" || bad "incomplete studio: rc=$RC"

# ── S3.6 — the command is wired, and no longer stubbed ───────────────────────

run_kickoff "$S" --help
grep -q '^  corpus \[--job' <<<"$OUT" \
  && ok "usage lists corpus" || bad "usage: $(grep -i corpus <<<"$OUT")"

run_kickoff "$S" corpus --date "$END"
if grep -q 'not implemented yet' <<<"$ERR"; then
  bad "corpus is still stubbed with not_yet"
else
  ok "corpus is dispatched to cmd_corpus, not to the not_yet stub"
fi

echo
echo "generators/angles.yaml — the run-jobs.sh gate"

# ── D2 — the real config must survive the real orchestrator's per-config gate ─
#
# Replays exactly what run-jobs.sh does to every scripts/generators/*.yaml,
# against the REAL angles.yaml. If `never` were dropped from the schedule
# vocabulary, or `output:` emptied, the orchestrator would mark this job FAILED
# and exit 1 every night until Epic 4 turns it on.

gate() {  # CONFIG STUDIO DATE -> prints one of: FAILED(...) | SKIP | RUN
  (
    set -uo pipefail
    export STUDIO_DIR="$2"
    . "$REPO_DIR/scripts/lib/job-config.sh"
    LOG_FILE="$WORK/gate.log"
    # run-jobs.sh calls this once before its config loop; cfg_get needs PYTHON_BIN.
    ensure_venv >/dev/null 2>&1
    local schedule output resolved rc
    schedule="$(cfg_get "$1" schedule daily)" || { echo "FAILED(unreadable)"; exit 0; }
    output="$(cfg_get "$1" output)"           || { echo "FAILED(unreadable)"; exit 0; }
    [ -n "$output" ] || { echo "FAILED(no output:)"; exit 0; }
    set_tpl_vars "$3" "$schedule"
    resolved="$(resolve_output "$output")"
    assert_no_placeholders "$resolved" "output:" || { echo "FAILED(placeholder)"; exit 0; }
    assert_output_boundary generators "$resolved" || { echo "FAILED(boundary)"; exit 0; }
    job_scheduled_today "$schedule" "$(day_of_week "$3")" && rc=0 || rc=$?
    case "$rc" in
      2) echo "FAILED(unknown schedule '$schedule')" ;;
      0) echo "RUN" ;;
      *) echo "SKIP" ;;
    esac
  )
}

ANGLES="$REPO_DIR/scripts/generators/angles.yaml"
[ -f "$ANGLES" ] && ok "scripts/generators/angles.yaml exists" || bad "angles.yaml missing"

# Every day of one full week, because a schedule word is only safe if it is safe
# on all seven — a Sunday-only failure would be invisible for six days.
allskip=1; verdicts=""
for d in 2026-07-27 2026-07-28 2026-07-29 2026-07-30 2026-07-31 2026-08-01 2026-08-02; do
  v="$(gate "$ANGLES" "$S" "$d")"
  verdicts="$verdicts $d=$v"
  [ "$v" = "SKIP" ] || allskip=0
done
[ "$allskip" = 1 ] \
  && ok "angles.yaml is SKIP, never FAILED, on all seven days of a week" \
  || bad "orchestrator gate:$verdicts"

# The individual claims, so a failure above points at which one broke.
out_tpl="$( . "$REPO_DIR/scripts/lib/job-config.sh" >/dev/null 2>&1
            ensure_venv >/dev/null 2>&1; cfg_get "$ANGLES" output )"
[ -n "$out_tpl" ] \
  && ok "angles.yaml declares a non-empty output: (an empty one is FAILED)" \
  || bad "output: is empty"
sched="$( . "$REPO_DIR/scripts/lib/job-config.sh" >/dev/null 2>&1
          ensure_venv >/dev/null 2>&1; cfg_get "$ANGLES" schedule daily )"
[ "$sched" = "never" ] && ok "angles.yaml declares schedule: never" || bad "schedule is '$sched'"

# assert_output_boundary: generator output must resolve beneath $STUDIO_DIR,
# because src/content/** is read-only to studio jobs.
(
  export STUDIO_DIR="$S"
  . "$REPO_DIR/scripts/lib/job-config.sh"
  LOG_FILE="$WORK/gate.log"
  set_tpl_vars "$END" never
  resolved="$(resolve_output "$out_tpl")"
  case "$resolved" in "$S"/*) exit 0 ;; *) echo "$resolved"; exit 1 ;; esac
) && ok "angles.yaml output resolves beneath \$STUDIO_DIR" || bad "output escapes the studio"

# ── The `never` vocabulary itself ────────────────────────────────────────────

(
  . "$REPO_DIR/scripts/lib/job-config.sh"
  bad_day=""
  for d in 1 2 3 4 5 6 7; do
    job_scheduled_today never "$d" && rc=0 || rc=$?
    [ "$rc" = 1 ] || bad_day="$bad_day $d:rc=$rc"
  done
  [ -z "$bad_day" ] || { echo "$bad_day"; exit 1; }
) && ok "never returns skip (1) on every day of the week, never run and never unknown" \
  || bad "never vocabulary"

# Still 2 for a word that really is unknown — the guard that catches a typo'd
# schedule must not have been widened into accepting anything.
(
  . "$REPO_DIR/scripts/lib/job-config.sh"
  job_scheduled_today nevr 1 && rc=0 || rc=$?
  [ "$rc" = 2 ] || exit 1
) && ok "an unrecognised schedule word still returns 2 (unknown), so a typo is still FAILED" \
  || bad "unknown schedule no longer returns 2"

# The other four words are unchanged. weekdays is Mon–Sat, this project's
# documented gotcha, and the coverage denominator depends on it.
(
  . "$REPO_DIR/scripts/lib/job-config.sh"
  job_scheduled_today daily 7    || exit 1
  job_scheduled_today weekdays 6 || exit 1   # Saturday runs
  job_scheduled_today weekdays 7 && exit 1   # Sunday does not
  job_scheduled_today saturday 6 || exit 1
  job_scheduled_today sunday 7   || exit 1
  exit 0
) && ok "daily / weekdays (Mon–Sat) / saturday / sunday are unchanged" \
  || bad "existing schedule vocabulary changed"

echo
if [ "$FAIL" = "0" ]; then
  echo "PASS ($COUNT) — kickoff corpus tests passed"
else
  echo "FAIL — kickoff corpus tests FAILED ($COUNT assertions run)"
fi
exit "$FAIL"
