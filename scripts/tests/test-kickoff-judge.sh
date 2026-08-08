#!/bin/bash
# Regression test for `kickoff judge` — S4.5.7 — and the calibration report, S4.5.8.
#
# `kickoff judge <week>` COMMITS. That makes this the one suite in the tree with
# a way to write to the real studio, so it never learns where the real one is:
# every run builds a throwaway studio under $TMPDIR, git-inits it, and points
# STUDIO_DIR at that. The last assertion re-checks that no scratch path leaked.
#
# The CLI is exercised against a COPY of scripts/{lib,studio,topics,generators}
# over a fixture src/content/, the same way test-kickoff-corpus.sh does it:
# kickoff derives REPO_DIR from its own resolved path, so a symlink would
# resolve straight back to the real repo whose corpus changes every night.
#
# No network, no writes outside $TMPDIR, no git writes to any real repo.
#
#   bash scripts/tests/test-kickoff-judge.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

FAIL=0
COUNT=0
ok()   { COUNT=$((COUNT + 1)); printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad()  { COUNT=$((COUNT + 1)); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=1; }
skip() { printf "  \033[33mskip\033[0m  %s\n" "$*"; }

if ! "$PYBIN" -c 'import yaml' 2>/dev/null; then
  echo "kickoff judge"
  skip "pyyaml unavailable in $PYBIN — run any kickoff command once to build scripts/.venv"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── A fixture repo carrying the real CLI over a fixture corpus ───────────────

FIX="$WORK/repo"
mkdir -p "$FIX/scripts" "$FIX/src/content"
cp -R "$REPO_DIR/scripts/lib" "$FIX/scripts/lib"
cp -R "$REPO_DIR/scripts/studio" "$FIX/scripts/studio"
cp -R "$REPO_DIR/scripts/topics" "$FIX/scripts/topics"
cp -R "$REPO_DIR/scripts/generators" "$FIX/scripts/generators"
cp "$REPO_DIR/src/content.config.ts" "$FIX/src/content.config.ts"
KICKOFF="$FIX/scripts/studio/kickoff"

# ensure_venv() only probes for scripts/.venv/bin/python3, so the real venv is
# symlinked in whole — symlinking the interpreter alone leaves CPython looking
# for pyvenv.cfg beside the link and falling back to a base install with no
# pyyaml. Nothing here may reach the network.
if [ -d "$REPO_DIR/scripts/.venv" ]; then
  ln -s "$REPO_DIR/scripts/.venv" "$FIX/scripts/.venv"
else
  mkdir -p "$FIX/scripts/.venv/bin"
  ln -s "$PYBIN" "$FIX/scripts/.venv/bin/python3"
fi

# Nothing below reaches run_llm_job, but PATH alone was never sufficient and a
# future edit that does reach it must not find a real `claude` on this machine.
export KICKOFF_CLAUDE_BIN="$WORK/no-such-claude"

mkdigest() {  # THEME DATE
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
---

Body.
EOF
}
mkdigest ai 2026-08-04
mkdigest leadership 2026-08-05

# ── The real studio, recorded before anything runs ───────────────────────────
#
# Not asserted to be clean — a human mid-judgement legitimately has uncommitted
# verdicts, and an always-red gate is worse than no gate. Asserted to be
# *unchanged by this suite*, which is the claim that actually matters.

REAL="$( (STUDIO_DIR="" bash -c '. '"$REPO_DIR"'/scripts/lib/job-config.sh; resolve_studio_dir') 2>/dev/null)"
studio_fingerprint() {  # DIR -> a line per file, path and checksum
  [ -d "$1" ] || return 0
  find "$1" -type f ! -path '*/.git/*' -exec shasum {} \; 2>/dev/null | sort
  git -C "$1" rev-parse HEAD 2>/dev/null
  git -C "$1" status --porcelain 2>/dev/null
}
REAL_BEFORE="$(studio_fingerprint "$REAL")"

# ── Scratch studios, never the real one ─────────────────────────────────────

new_studio() {  # NAME -> path
  local d="$WORK/$1" x
  for x in notes angles drafts published engagement state; do mkdir -p "$d/$x"; done
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  touch "$d/state/.gitkeep"
  git -C "$d" add -A >/dev/null && git -C "$d" commit -qm seed
  # A real remote, so "made exactly one commit" is a claim about behaviour
  # rather than an accident of configuration.
  git init -q --bare "$d.git"
  git -C "$d" remote add origin "$d.git"
  git -C "$d" push -q -u origin main
  echo "$d"
}

# One angle. The scores are the whole point of the fixture, so they are
# arguments; everything else is boilerplate that only has to validate.
emit_angle() {  # N TITLE P C E R VERDICT
  cat <<EOF

## A$1 — $2
- **pillar:** 2 — Engineering leadership in the AI era
- **altitude:** enterprise
- **thesis:** $2, stated as one arguable and falsifiable sentence.
- **why now:** A public item this week made the question concrete rather than theoretical.
- **evidence:**
  - \`[ai/2026-08-04]\` a write-up of harness containment design — https://example.invalid/a
  - \`[leadership/2026-08-05]\` guidance on splitting work between agents and engineers — https://example.invalid/b
- **blocker:** none
- **prep:** verify the figure against the primary source before drafting
- **verdict:** $7
- **score provability:** $3 — justification for provability
- **score consequence:** $4 — justification for consequence
- **score edge:** $5 — justification for edge
- **score readiness:** $6 — justification for readiness
EOF
}

start_week() {  # FILE WEEK COUNT
  cat > "$1" <<EOF
---
week: $2
generated: 2026-08-16
corpusCoverage: "ai 1/1 · leadership 1/1"
angleCount: $3
schemaVersion: 2
---
EOF
}

# The window every assertion below reads. File order is deliberately NOT
# composite order — A1 is the lowest-scoring angle and A3 the highest — so an
# implementation that sorted by composite would reorder the table and be caught.
#
# It also carries both shapes of disagreement (A1: BLOCKED judged post; A3:
# DRAFT judged pass) and one `maybe` with no dimension tag.
seed_week() {  # STUDIO WEEK
  local f="$1/angles/$2.md"
  start_week "$f" "$2" 6
  emit_angle 1 "Governance is a rollout feature, not a tax on one" \
             1 1 1 1 "post — —: the weakened version is still worth posting" >> "$f"
  emit_angle 2 "The hardest output a reviewer produces is nothing new today" \
             2 1 3 2 "pending" >> "$f"
  emit_angle 3 "Any metric an agent can move has stopped measuring productivity" \
             3 3 3 1 "pass — C: nothing a reader owns actually changes" >> "$f"
  emit_angle 4 "Delegate by task horizon, not by difficulty" \
             2 2 2 3 "post — the horizon split carries the whole post" >> "$f"
  emit_angle 5 "Adoption stalls at the second team, not the first" \
             3 2 2 0 "maybe — E: one step from the same feed" >> "$f"
  emit_angle 6 "Model choice is not a mitigation" \
             1 3 2 2 "pending" >> "$f"
}

run_kickoff() {  # STUDIO [ARGS...]
  ( cd "$WORK" && HOME="$WORK/home" STUDIO_DIR="$1" bash "$KICKOFF" "${@:2}" ) \
    >"$WORK/out.txt" 2>"$WORK/err.txt"
  RC=$?
  OUT="$(cat "$WORK/out.txt")"
  ERR="$(cat "$WORK/err.txt")"
}

# `grep -q` exits on its first match; under `set -o pipefail` the writer then
# dies with SIGPIPE and fails the whole pipeline despite the match succeeding.
# A here-string has no writer to kill.
says()     { grep -q -- "$2" <<<"$1"; }
says_not() { ! grep -q -- "$2" <<<"$1"; }

mkdir -p "$WORK/home"

echo "kickoff judge"

# ── Status: an unjudged latest week is a finding, and commits nothing ────────

S="$(new_studio status)"
before="$(git -C "$S" rev-list --count HEAD)"
seed_week "$S" 2026-W33
# Wipe the verdicts back to pending — this is what a freshly generated week is.
sed -i '' -E 's/^- \*\*verdict:\*\* .*/- **verdict:** pending/' "$S/angles/2026-W33.md"
run_kickoff "$S" judge
[ "$RC" = 1 ] && ok "bare 'judge' exits non-zero when the latest week is unjudged" \
  || bad "bare judge on an unjudged week: rc=$RC"
says "$OUT" "UNJUDGED" && ok "status names the unjudged state" || bad "status did not say UNJUDGED"
says "$OUT" "kickoff judge 2026-W33" && ok "status names the command that fixes it" \
  || bad "status did not name the next command"
[ "$(git -C "$S" rev-list --count HEAD)" = "$before" ] \
  && ok "status made no commit" || bad "status committed something"

# ── The judged path: one commit, scoped to angles/, labelled [judged] ────────

S="$(new_studio judged)"
seed_week "$S" 2026-W33
before="$(git -C "$S" rev-list --count HEAD)"
run_kickoff "$S" judge 2026-W33
[ "$RC" = 0 ] && ok "judge <week> on a valid judged file exits 0" \
  || { bad "judge <week>: rc=$RC"; printf '%s\n%s\n' "$OUT" "$ERR" | sed 's/^/        /'; }

after="$(git -C "$S" rev-list --count HEAD)"
[ "$after" = "$((before + 1))" ] && ok "exactly one new commit" \
  || bad "expected 1 new commit, got $((after - before))"

MSG="$(git -C "$S" log -1 --pretty=%s)"
says "$MSG" "\[judged\]" && ok "commit message contains [judged]" || bad "message: $MSG"
says_not "$MSG" "\[automated\]" \
  && ok "commit message does NOT contain [automated]" || bad "message claims [automated]: $MSG"
says "$MSG" "2026-W33 verdicts" && ok "commit message names the week" || bad "message: $MSG"

TOUCHED="$(git -C "$S" show --name-only --pretty=format: HEAD | grep -v '^$')"
[ "$TOUCHED" = "angles/2026-W33.md" ] \
  && ok "the commit touches only angles/" || bad "commit touched: $TOUCHED"

# A second run has nothing new. It must say so and must not manufacture an
# empty commit — a week's verdicts appearing twice in the log is a week that
# looks re-judged when nobody re-read it.
run_kickoff "$S" judge 2026-W33
[ "$RC" = 0 ] && [ "$(git -C "$S" rev-list --count HEAD)" = "$after" ] \
  && ok "re-running judge on an unchanged week makes no second commit" \
  || bad "second run: rc=$RC, commits now $(git -C "$S" rev-list --count HEAD)"

# ── The table: file order, band as a column, never sorted by composite ───────

run_kickoff "$S" judge 2026-W33
ORDER="$(grep -oE '^  A[0-9]+' <<<"$OUT" | tr -d ' ' | tr '\n' ' ')"
[ "$ORDER" = "A1 A2 A3 A4 A5 A6 " ] \
  && ok "angles print in file order A1…An" || bad "print order was: $ORDER"
# A1 scores 3 and A3 scores 9. Composite order would put A3 first.
says "$OUT" "^  A1 *BLOCKED" && ok "the band is a column on the angle's own row" \
  || bad "no band column on A1's row"
says "$OUT" "^  A3 *DRAFT" && ok "A3 (composite 9) still prints third" \
  || bad "A3 did not print in file order"
says "$OUT" "bands *DRAFT 3" && ok "the band tally is printed" || bad "no band tally"

# ── A broken hand-edit fails, and commits nothing ────────────────────────────

S="$(new_studio broken)"
seed_week "$S" 2026-W33
before="$(git -C "$S" rev-list --count HEAD)"
# The shape a hand-edit actually breaks: a verdict word nobody agreed to.
sed -i '' -E 's/^- \*\*verdict:\*\* pending$/- **verdict:** yes/' "$S/angles/2026-W33.md"
run_kickoff "$S" judge 2026-W33
[ "$RC" != 0 ] && ok "a broken hand-edit fails validation" || bad "broken file: rc=$RC"
[ "$(git -C "$S" rev-list --count HEAD)" = "$before" ] \
  && ok "a failed validation commits nothing" || bad "committed a file that failed validation"
says "$ERR" "committed nothing" && ok "the failure says nothing was committed" \
  || bad "failure message did not mention the commit"

# ── A missing dimension tag WARNS, and never fails ───────────────────────────
#
# The tag is the tuning signal and it is written by a human. A rule that fails
# the week on a missing one teaches the human to stop writing reasons, which is
# the only free-text signal this loop collects.

S="$(new_studio untagged)"
seed_week "$S" 2026-W33
sed -i '' -E 's/^- \*\*verdict:\*\* maybe .*/- **verdict:** maybe — one step from the same feed/' \
  "$S/angles/2026-W33.md"
run_kickoff "$S" judge --since 1
[ "$RC" = 0 ] && ok "an untagged maybe does not fail the report" || bad "untagged: rc=$RC"
says "$OUT" "WARN.*A5 verdict 'maybe' has no dimension tag" \
  && ok "an untagged maybe is warned about by name" || bad "no warning for the untagged verdict"

# ── The calibration report: three sections ──────────────────────────────────

S="$(new_studio report)"
seed_week "$S" 2026-W33
seed_week "$S" 2026-W34
cp "$REPO_DIR/scripts/tests/fixtures/angles-v1-verdicts-2026-W31.md" "$S/angles/2026-W31.md"
run_kickoff "$S" judge --since 2
[ "$RC" = 0 ] && ok "--since prints and exits 0" \
  || { bad "--since: rc=$RC"; printf '%s\n%s\n' "$OUT" "$ERR" | sed 's/^/        /'; }
says "$OUT" "1\. Verdicts by band" && ok "section 1: per-band verdict counts" || bad "no section 1"
says "$OUT" "2\. Disagreements"    && ok "section 2: the disagreement list"    || bad "no section 2"
says "$OUT" "3\. Per dimension"    && ok "section 3: per-dimension breakdown"  || bad "no section 3"
says "$OUT" "window.*2026-W33, 2026-W34" \
  && ok "--since 2 takes the two most recent weeks with files" || bad "wrong window"

# Every DRAFT judged pass and every BLOCKED/REWORK judged post, each with its
# tag and its reason. This is the prompt-tuning input.
says "$OUT" "2026-W33/A3 *DRAFT *judged pass" \
  && ok "a DRAFT judged pass appears in the disagreement list" || bad "missing DRAFT/pass row"
says "$OUT" "tag C *nothing a reader owns actually changes" \
  && ok "the disagreement carries its dimension tag and its reason" || bad "tag/reason missing"
says "$OUT" "2026-W33/A1 *BLOCKED *judged post" \
  && ok "a BLOCKED judged post appears in the disagreement list" || bad "missing BLOCKED/post row"

# Spread is per dimension. R spreads 0-3 in this fixture while P spreads 1-3, so
# an aggregate figure would report one number for four different pictures.
says "$OUT" "^  P .* 2 " && ok "P prints its own spread column" || bad "no per-dimension P spread"
says "$OUT" "^  R .* 3 " && ok "R prints a different spread from P" || bad "no per-dimension R spread"
says_not "$OUT" "aggregate spread" && ok "no aggregate spread figure is printed" \
  || bad "an aggregate spread was printed"

# ── v1 rows: counted separately, in no rate ─────────────────────────────────

run_kickoff "$S" judge --since 3
says "$OUT" "12 scored (v2) · 8 unscored (v1)" \
  && ok "v1 rows are counted separately from scored rows" || bad "v1/v2 counts wrong"
says "$OUT" "2026-W31 carry verdicts and no predictions" \
  && ok "the v1 week is named as verdicts-only" || bad "v1 week not named"
# 20 rows in the window: 12 scored over two weeks plus W31's 8 v1 rows. The
# rate sees 6 judged DRAFT rows and nothing else.
says "$OUT" "DRAFT precision *2/6" \
  && ok "the rate denominator is judged DRAFT rows, not the 20 in the window" \
  || bad "a rate absorbed the v1 rows"

# ── Score compression is named, and is not a failure ────────────────────────

S="$(new_studio flat)"
f="$S/angles/2026-W33.md"
start_week "$f" 2026-W33 6
for n in 1 2 3 4 5 6; do
  emit_angle "$n" "A thesis that is the $n th of six" 3 3 "$n" $((n % 4)) \
             "post — it is postable" >> "$f"
done
# E is 1-6 above; clamp it into range without touching P or C.
sed -i '' -E 's/^- \*\*score edge:\*\* [456]/- **score edge:** 3/' "$f"
run_kickoff "$S" judge --since 1
[ "$RC" = 0 ] && ok "a compressed score set is not a run failure" || bad "compression: rc=$RC"
says "$OUT" "COMPRESSED: P .* spread 0" && ok "zero spread in P is named" || bad "P compression not named"
says "$OUT" "COMPRESSED: C .* spread 0" && ok "zero spread in C is named" || bad "C compression not named"
says "$OUT" "prompt-tuning finding, not a run" \
  && ok "compression is reported as a tuning finding" || bad "compression framed as a failure"

# ── Argument handling ───────────────────────────────────────────────────────

S="$(new_studio args)"
seed_week "$S" 2026-W33
run_kickoff "$S" judge 2026-W33 --since 2
[ "$RC" != 0 ] && says "$ERR" "not both" \
  && ok "a week and --since together are refused" || bad "week + --since: rc=$RC"
run_kickoff "$S" judge W33
[ "$RC" != 0 ] && says "$ERR" "must look like" \
  && ok "a malformed week is refused before anything is read" || bad "bad week: rc=$RC"
run_kickoff "$S" judge 2026-W99
[ "$RC" != 0 ] && says "$ERR" "no angles file" \
  && ok "a week with no file is refused by name" || bad "missing week: rc=$RC"

# ── The real studio was never a party to any of this ────────────────────────
#
# Every studio above lives under $WORK. If a code path ever resolved the studio
# itself instead of honouring $STUDIO_DIR, this is where it shows.

if [ -n "$REAL" ] && [ -d "$REAL" ]; then
  [ "$(studio_fingerprint "$REAL")" = "$REAL_BEFORE" ] \
    && ok "the real studio is byte-for-byte unchanged by this suite" \
    || bad "THE REAL STUDIO CHANGED during this suite: $REAL"
else
  skip "no real studio on this machine — nothing to check for collateral damage"
fi

echo
echo "$COUNT assertion(s)"
[ "$FAIL" = "0" ] && echo "kickoff judge tests passed" || echo "kickoff judge tests FAILED"
exit "$FAIL"
