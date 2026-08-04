#!/bin/bash
# Epic 4, S4.1 and S4.2 — the placeholder vocabulary, the ${STUDIO_DIR} brace
# form, the prompt/output assert, and the STUDIO_DIR-reaches-the-producer fix.
#
#   bash scripts/tests/test-tpl-vars.sh
#
# Everything runs against scratch dirs under $TMPDIR with a scratch studio.
# Nothing is written to the real studio, to src/content/, or to any git repo.
# `claude` is never invoked: the end-to-end cases stub it on PATH.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

FAIL=0
COUNT=0
ok()   { COUNT=$((COUNT + 1)); printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad()  { COUNT=$((COUNT + 1)); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=1; }
skip() { printf "  \033[33mskip\033[0m  %s\n" "$*"; }

echo "template vars"

PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
if ! "$PYBIN" -c 'import yaml' 2>/dev/null; then
  skip "pyyaml unavailable in $PYBIN — run any kickoff command once to build scripts/.venv"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUDIO="$WORK/studio"
mkdir -p "$STUDIO"/{notes,angles,drafts,published,engagement,state}

. "$REPO_DIR/scripts/lib/job-config.sh"
ensure_venv

# ── {{WEEK}} — ISO %G-W%V ────────────────────────────────────────────────────
#
# The 2027-01-01 case is the whole reason %G is mandatory: with %Y it would read
# 2027-W53, a week that does not exist, and the file would collide with the real
# 2027-W53 eleven months later.

week_of() { STUDIO_DIR="$STUDIO" set_tpl_vars "$1" daily; echo "$TPL_WEEK"; }

check_week() {  # DATE EXPECTED WHY
  local got
  STUDIO_DIR="$STUDIO"
  set_tpl_vars "$1" daily
  got="$TPL_WEEK"
  [ "$got" = "$2" ] && ok "{{WEEK}} $1 → $2 ($3)" \
    || bad "{{WEEK}} $1 → $got, expected $2 ($3)"
}

check_week 2026-08-01 2026-W31 "Saturday"
check_week 2026-08-02 2026-W31 "Sunday of the same ISO week — a Sunday generator names the week that just ended"
check_week 2026-08-03 2026-W32 "Monday starts the next ISO week"
check_week 2027-01-01 2026-W53 "ISO year, not calendar year"
check_week 2026-12-31 2026-W53 "the tail of 2026 is still W53"

# ── {{STUDIO_DIR}} ───────────────────────────────────────────────────────────

STUDIO_DIR="$STUDIO"
set_tpl_vars 2026-08-02 sunday
[ "$TPL_STUDIO_DIR" = "$STUDIO" ] \
  && ok "{{STUDIO_DIR}} takes an already-resolved STUDIO_DIR" \
  || bad "{{STUDIO_DIR}} is '$TPL_STUDIO_DIR', expected '$STUDIO'"

rendered="$(render_placeholders 'see {{STUDIO_DIR}}/angles/{{WEEK}}.md')"
[ "$rendered" = "see $STUDIO/angles/2026-W31.md" ] \
  && ok "{{STUDIO_DIR}} and {{WEEK}} render together in a prompt" \
  || bad "rendered '$rendered'"

# Unconditional means one code path — and it must not blow up for a topic job on
# a machine with no studio, which is the machine most likely to run the tests.
( unset STUDIO_DIR
  XDG_CONFIG_HOME="$WORK/no-such-config" set_tpl_vars 2026-08-02 daily >/dev/null 2>&1 ) \
  && ok "set_tpl_vars survives with no STUDIO_DIR and no kickoff config (topic jobs)" \
  || bad "set_tpl_vars failed when no studio is configured — topic jobs would break"

# ── {{WEEKLY_FLAG}} ──────────────────────────────────────────────────────────

STUDIO_DIR="$STUDIO"
set_tpl_vars 2026-08-08 weekdays   # Saturday
[ "$TPL_WEEKLY_FLAG" = "--weekly" ] \
  && ok "{{WEEKLY_FLAG}} is --weekly on a Saturday" \
  || bad "{{WEEKLY_FLAG}} is '$TPL_WEEKLY_FLAG' on Saturday"

set_tpl_vars 2026-08-05 weekdays   # Wednesday
[ -z "$TPL_WEEKLY_FLAG" ] \
  && ok "{{WEEKLY_FLAG}} is empty midweek" \
  || bad "{{WEEKLY_FLAG}} is '$TPL_WEEKLY_FLAG' midweek"

set_tpl_vars 2026-08-05 saturday   # saturday-scheduled job, any day
[ "$TPL_WEEKLY_FLAG" = "--weekly" ] \
  && ok "{{WEEKLY_FLAG}} follows weekly_window, not the calendar day alone" \
  || bad "{{WEEKLY_FLAG}} is '$TPL_WEEKLY_FLAG' for a saturday-scheduled job"

# The empty flag must vanish, not become an empty argument — that is what the
# frozen baseline freezes, and what `select_corpus.py` could not have survived.
set_tpl_vars 2026-08-05 weekdays
p="$(render_placeholders 'fetch_sources.py --topic ai {{WEEKLY_FLAG}}')"
[ "$(echo scripts/$p)" = "scripts/fetch_sources.py --topic ai" ] \
  && ok "an empty {{WEEKLY_FLAG}} collapses under word-splitting" \
  || bad "collapsed to '$(echo scripts/$p)'"

# ── ${STUDIO_DIR} brace form ─────────────────────────────────────────────────
#
# Unsubstituted, this resolved to a literal directory named '${STUDIO_DIR}'
# inside the repo — output written where nobody would look.

STUDIO_DIR="$STUDIO"
set_tpl_vars 2026-08-02 sunday

[ "$(resolve_output '$STUDIO_DIR/angles/{{WEEK}}.md')" = "$STUDIO/angles/2026-W31.md" ] \
  && ok "resolve_output substitutes the bare \$STUDIO_DIR form" \
  || bad "bare form → $(resolve_output '$STUDIO_DIR/angles/{{WEEK}}.md')"

[ "$(resolve_output '${STUDIO_DIR}/angles/{{WEEK}}.md')" = "$STUDIO/angles/2026-W31.md" ] \
  && ok "resolve_output substitutes the \${STUDIO_DIR} brace form" \
  || bad "brace form → $(resolve_output '${STUDIO_DIR}/angles/{{WEEK}}.md')"

[ "$(resolve_output '${STUDIO_DIR}angles/{{WEEK}}.md')" = "${STUDIO}angles/2026-W31.md" ] \
  && ok "the brace form works without a separator, which is why it exists" \
  || bad "brace form without separator → $(resolve_output '${STUDIO_DIR}angles/{{WEEK}}.md')"

# ── run-job.sh, end to end, with a stubbed claude ────────────────────────────
#
# A scratch repo, a scratch studio, a stored bundle, and a `claude` on PATH that
# writes a canned file. No LLM call, no network, no writes outside $WORK.

SCRATCH="$WORK/repo"
mkdir -p "$SCRATCH/scripts"/{topics,generators,lib,prompts,logs,studio} "$SCRATCH/src/content/ai"
cp "$REPO_DIR/scripts/lib/job-config.sh" "$REPO_DIR/scripts/lib/run-llm-job.sh" \
   "$REPO_DIR/scripts/lib/validate_angles.py" "$REPO_DIR/scripts/lib/bundle.py" "$SCRATCH/scripts/lib/"
cp "$REPO_DIR/scripts/studio/select_corpus.py" "$SCRATCH/scripts/studio/"
cp "$REPO_DIR/scripts/run-job.sh" "$SCRATCH/scripts/"
ln -s "$REPO_DIR/scripts/.venv" "$SCRATCH/scripts/.venv"

BUNDLE="$WORK/bundle.txt"
printf 'URL: https://example.com/a\nTITLE: a\n\n' > "$BUNDLE"

# A producer that proves what its environment held, rather than one that needs a
# network. `printenv` exits 1 on an unset name, so the file says so either way.
cat > "$SCRATCH/scripts/echo_env.py" <<'PY'
import os, sys
sys.stderr.write("STUDIO_DIR=%s\n" % os.environ.get("STUDIO_DIR", "<unset>"))
print("URL: https://example.com/x")
print("TITLE: x")
print("ARGV: %s" % " ".join(sys.argv[1:]))
PY

mkdir -p "$WORK/bin"
cat > "$WORK/bin/claude" <<PYEOF
#!/bin/bash
# Stub. Writes the canned file named by CLAUDE_STUB_OUT and exits 0, exactly as
# the real CLI does whether or not it wrote anything.
[ -n "\${CLAUDE_STUB_OUT:-}" ] && { mkdir -p "\$(dirname "\$CLAUDE_STUB_OUT")"; cat "\$CLAUDE_STUB_BODY" > "\$CLAUDE_STUB_OUT"; }
echo "stub-claude ok"
exit 0
PYEOF
chmod +x "$WORK/bin/claude"

# A real digest for the angles fixture to cite. Written at setup rather than
# relying on an earlier test having produced one, so the citation resolves no
# matter which assertions run.
mkdir -p "$SCRATCH/src/content/leadership"
cat > "$SCRATCH/src/content/leadership/2026-08-01.md" <<'MD'
---
title: "x"
date: 2026-08-01
theme: leadership
format: weekly-synthesis
tldr: "x"
itemCount: 1
readTimeMinutes: 1
---
body
MD

# Six angles, because validate_angles.py enforces the 6-10 range the
# prompt states as a hard rule.
cat > "$WORK/angles-body.md" <<'MD'
---
week: 2026-W31
generated: 2026-08-02
corpusCoverage: "leadership 1/1"
angleCount: 6
---

## A1 — angle 1
- **pillar:** 2 — Engineering leadership in the AI era
- **altitude:** enterprise
- **thesis:** Throughput moved to review and nobody was assigned to it.
- **why now:** the week's synthesis says so outright
- **evidence:**
  - `[leadership/2026-08-01]` the weekly synthesis — https://example.com/x
- **risk:** none, public sources only

## A2 — angle 2
- **pillar:** 2 — Engineering leadership in the AI era
- **altitude:** enterprise
- **thesis:** Throughput moved to review and nobody was assigned to it.
- **why now:** the week's synthesis says so outright
- **evidence:**
  - `[leadership/2026-08-01]` the weekly synthesis — https://example.com/x
- **risk:** none, public sources only

## A3 — angle 3
- **pillar:** 2 — Engineering leadership in the AI era
- **altitude:** enterprise
- **thesis:** Throughput moved to review and nobody was assigned to it.
- **why now:** the week's synthesis says so outright
- **evidence:**
  - `[leadership/2026-08-01]` the weekly synthesis — https://example.com/x
- **risk:** none, public sources only

## A4 — angle 4
- **pillar:** 2 — Engineering leadership in the AI era
- **altitude:** enterprise
- **thesis:** Throughput moved to review and nobody was assigned to it.
- **why now:** the week's synthesis says so outright
- **evidence:**
  - `[leadership/2026-08-01]` the weekly synthesis — https://example.com/x
- **risk:** none, public sources only

## A5 — angle 5
- **pillar:** 2 — Engineering leadership in the AI era
- **altitude:** enterprise
- **thesis:** Throughput moved to review and nobody was assigned to it.
- **why now:** the week's synthesis says so outright
- **evidence:**
  - `[leadership/2026-08-01]` the weekly synthesis — https://example.com/x
- **risk:** none, public sources only

## A6 — angle 6
- **pillar:** 2 — Engineering leadership in the AI era
- **altitude:** enterprise
- **thesis:** Throughput moved to review and nobody was assigned to it.
- **why now:** the week's synthesis says so outright
- **evidence:**
  - `[leadership/2026-08-01]` the weekly synthesis — https://example.com/x
- **risk:** none, public sources only

MD

cat > "$WORK/digest-body.md" <<'MD'
---
title: "x"
date: 2026-08-02
theme: ai
format: daily
tldr: "x"
itemCount: 1
readTimeMinutes: 1
---
body
MD

run_scratch_job() {  # JOB [extra env assignments...] -> RC, OUT
  local job="$1"; shift
  OUT="$(cd "$SCRATCH" && env KICKOFF_CLAUDE_BIN="$WORK/bin/claude" \
        DIGEST_DATE=2026-08-02 BUNDLE_FILE="$BUNDLE" \
        STUDIO_DIR="$STUDIO" "$@" bash scripts/run-job.sh "$job" 2>&1)"
  RC=$?
}

# --- the prompt/output assert: repo-relative form still accepted -------------

cat > "$SCRATCH/scripts/topics/ai.yaml" <<'YML'
name:     "ai"
schedule: daily
producer: fetch_sources.py --topic ai {{WEEKLY_FLAG}}
prompt:   scripts/prompts/ai.md
output:   src/content/ai/{{DATE}}.md
YML
echo 'Write src/content/ai/{{DATE}}.md now.' > "$SCRATCH/scripts/prompts/ai.md"

run_scratch_job ai CLAUDE_STUB_OUT="$SCRATCH/src/content/ai/2026-08-02.md" \
                   CLAUDE_STUB_BODY="$WORK/digest-body.md"
[ "$RC" = 0 ] \
  && ok "prompt/output assert accepts the repo-relative form (topics unchanged)" \
  || bad "repo-relative prompt rejected: $(tail -3 <<<"$OUT")"

# --- the assert: absolute form, for a studio-writing job ---------------------

cat > "$SCRATCH/scripts/generators/g.yaml" <<'YML'
name:     "g"
schedule: daily
producer: echo_env.py
prompt:   scripts/prompts/g.md
output:   $STUDIO_DIR/angles/{{WEEK}}.md
schema:   angles
YML
echo 'Write {{STUDIO_DIR}}/angles/{{WEEK}}.md now.' > "$SCRATCH/scripts/prompts/g.md"

run_scratch_job g CLAUDE_STUB_OUT="$STUDIO/angles/2026-W31.md" \
                  CLAUDE_STUB_BODY="$WORK/angles-body.md"
[ "$RC" = 0 ] \
  && ok "prompt/output assert accepts the rendered absolute path (studio jobs)" \
  || bad "absolute-path prompt rejected: $(tail -3 <<<"$OUT")"
rm -f "$STUDIO/angles/2026-W31.md"

# --- the assert: anything else still fails, before Claude -------------------

echo 'Write {{STUDIO_DIR}}/angles/some-other-file.md now.' > "$SCRATCH/scripts/prompts/g.md"
run_scratch_job g CLAUDE_STUB_OUT="$STUDIO/angles/2026-W31.md" \
                  CLAUDE_STUB_BODY="$WORK/angles-body.md"
[ "$RC" != 0 ] && grep -q "names neither" <<<"$OUT" \
  && ok "a prompt naming another path fails, and names both accepted forms" \
  || bad "a prompt naming another path was accepted (rc=$RC)"
[ ! -e "$STUDIO/angles/2026-W31.md" ] \
  && ok "…and it failed before Claude was invoked" \
  || bad "Claude ran despite the mismatched prompt"
grep -q "stub-claude ok" <<<"$OUT" \
  && bad "the claude stub ran — the assert is not gating the call" \
  || ok "the claude stub was never reached"

# --- the new gap: STUDIO_DIR must reach the producer subprocess -------------
#
# select_corpus.py reads STUDIO_DIR from its environment and die()s without it,
# so an unexported STUDIO_DIR would fail the angles job on its very first
# producer run. scripts/studio/kickoff passes it inline; run-job.sh did not.

cat > "$SCRATCH/scripts/generators/g.yaml" <<'YML'
name:     "g"
schedule: daily
producer: echo_env.py
prompt:   scripts/prompts/g.md
output:   $STUDIO_DIR/angles/{{WEEK}}.md
schema:   angles
YML
echo 'Write {{STUDIO_DIR}}/angles/{{WEEK}}.md now.' > "$SCRATCH/scripts/prompts/g.md"
rm -f "$SCRATCH/scripts/logs/fetched-2026-08-02-g.txt"

# BUNDLE_FILE unset, so the producer actually runs.
OUT="$(cd "$SCRATCH" && env KICKOFF_CLAUDE_BIN="$WORK/bin/claude" DIGEST_DATE=2026-08-02 \
       STUDIO_DIR="$STUDIO" CLAUDE_STUB_OUT="$STUDIO/angles/2026-W31.md" \
       CLAUDE_STUB_BODY="$WORK/angles-body.md" bash scripts/run-job.sh g 2>&1)"
RC=$?
PRODUCED="$SCRATCH/scripts/logs/fetched-2026-08-02-g.txt"
if [ -f "$PRODUCED" ] && grep -q "^STUDIO_DIR=$STUDIO$" "$PRODUCED"; then
  ok "STUDIO_DIR is exported and reaches the producer subprocess"
else
  bad "the producer saw STUDIO_DIR=$(grep -o 'STUDIO_DIR=.*' "$PRODUCED" 2>/dev/null | head -1) (rc=$RC)"
fi
rm -f "$STUDIO/angles/2026-W31.md"

# …and only for jobs that need a studio, so a topic job's environment is
# unchanged. A topic producer must not inherit one from this runner.
cat > "$SCRATCH/scripts/topics/env.yaml" <<'YML'
name:     "env"
schedule: daily
producer: echo_env.py
prompt:   scripts/prompts/env.md
output:   src/content/ai/{{DATE}}.md
YML
echo 'Write src/content/ai/{{DATE}}.md now.' > "$SCRATCH/scripts/prompts/env.md"
rm -f "$SCRATCH/scripts/logs/fetched-2026-08-02-env.txt" "$SCRATCH/src/content/ai/2026-08-02.md"

OUT="$(cd "$SCRATCH" && env -u STUDIO_DIR KICKOFF_CLAUDE_BIN="$WORK/bin/claude" DIGEST_DATE=2026-08-02 \
       CLAUDE_STUB_OUT="$SCRATCH/src/content/ai/2026-08-02.md" \
       CLAUDE_STUB_BODY="$WORK/digest-body.md" bash scripts/run-job.sh env 2>&1)"
RC=$?
PRODUCED="$SCRATCH/scripts/logs/fetched-2026-08-02-env.txt"
if [ -f "$PRODUCED" ] && grep -q "^STUDIO_DIR=<unset>$" "$PRODUCED"; then
  ok "a topic job's producer inherits no STUDIO_DIR — the export stays scoped"
else
  bad "a topic producer saw $(grep -o 'STUDIO_DIR=.*' "$PRODUCED" 2>/dev/null | head -1) (rc=$RC)"
fi

# --- S4.2 end to end: the flag the config asked for is the flag passed -------

rm -f "$SCRATCH/scripts/logs/fetched-2026-08-08-env.txt"
cat > "$SCRATCH/scripts/topics/env.yaml" <<'YML'
name:     "env"
schedule: weekdays
producer: echo_env.py --topic env {{WEEKLY_FLAG}}
prompt:   scripts/prompts/env.md
output:   src/content/ai/{{DATE}}.md
YML
echo 'Write src/content/ai/{{DATE}}.md now.' > "$SCRATCH/scripts/prompts/env.md"
OUT="$(cd "$SCRATCH" && env -u STUDIO_DIR KICKOFF_CLAUDE_BIN="$WORK/bin/claude" DIGEST_DATE=2026-08-08 \
       CLAUDE_STUB_OUT="$SCRATCH/src/content/ai/2026-08-08.md" \
       CLAUDE_STUB_BODY="$WORK/digest-body.md" bash scripts/run-job.sh env 2>&1)"
grep -q '^ARGV: --topic env --weekly$' "$SCRATCH/scripts/logs/fetched-2026-08-08-env.txt" 2>/dev/null \
  && ok "Saturday: the producer receives exactly '--topic env --weekly'" \
  || bad "Saturday argv: $(grep '^ARGV:' "$SCRATCH/scripts/logs/fetched-2026-08-08-env.txt" 2>/dev/null)"

rm -f "$SCRATCH/scripts/logs/fetched-2026-08-05-env.txt"
OUT="$(cd "$SCRATCH" && env -u STUDIO_DIR KICKOFF_CLAUDE_BIN="$WORK/bin/claude" DIGEST_DATE=2026-08-05 \
       CLAUDE_STUB_OUT="$SCRATCH/src/content/ai/2026-08-05.md" \
       CLAUDE_STUB_BODY="$WORK/digest-body.md" bash scripts/run-job.sh env 2>&1)"
grep -q '^ARGV: --topic env$' "$SCRATCH/scripts/logs/fetched-2026-08-05-env.txt" 2>/dev/null \
  && ok "midweek: the producer receives exactly '--topic env', no empty argument" \
  || bad "midweek argv: $(grep '^ARGV:' "$SCRATCH/scripts/logs/fetched-2026-08-05-env.txt" 2>/dev/null)"

# A generator asking for no flag gets none, on any day — including Saturday,
# which is what F10 broke.
rm -f "$SCRATCH/scripts/logs/fetched-2026-08-08-g.txt"
OUT="$(cd "$SCRATCH" && env KICKOFF_CLAUDE_BIN="$WORK/bin/claude" DIGEST_DATE=2026-08-08 \
       STUDIO_DIR="$STUDIO" CLAUDE_STUB_OUT="$STUDIO/angles/2026-W32.md" \
       CLAUDE_STUB_BODY="$WORK/angles-body.md" bash scripts/run-job.sh g 2>&1)"
grep -q '^ARGV: $' "$SCRATCH/scripts/logs/fetched-2026-08-08-g.txt" 2>/dev/null \
  && ok "a generator gets no --weekly, even on a Saturday (F10)" \
  || bad "generator argv on Saturday: $(grep '^ARGV:' "$SCRATCH/scripts/logs/fetched-2026-08-08-g.txt" 2>/dev/null)"
rm -f "$STUDIO/angles/2026-W32.md"

# --- an unsubstituted placeholder in producer: must not reach Python ---------

cat > "$SCRATCH/scripts/topics/env.yaml" <<'YML'
name:     "env"
schedule: weekdays
producer: echo_env.py --topic env {{NOPE}}
prompt:   scripts/prompts/env.md
output:   src/content/ai/{{DATE}}.md
YML
rm -f "$SCRATCH/scripts/logs/fetched-2026-08-05-env.txt" "$SCRATCH/src/content/ai/2026-08-05.md"
OUT="$(cd "$SCRATCH" && env -u STUDIO_DIR KICKOFF_CLAUDE_BIN="$WORK/bin/claude" DIGEST_DATE=2026-08-05 \
       CLAUDE_STUB_OUT="$SCRATCH/src/content/ai/2026-08-05.md" \
       CLAUDE_STUB_BODY="$WORK/digest-body.md" bash scripts/run-job.sh env 2>&1)"
RC=$?
[ "$RC" != 0 ] && grep -q "unsubstituted placeholder in producer:" <<<"$OUT" \
  && ok "an unsubstituted placeholder in producer: fails before the producer runs" \
  || bad "a producer carrying {{NOPE}} was run anyway (rc=$RC)"

echo
if [ "$FAIL" = "0" ]; then
  echo "PASS ($COUNT) — template var tests passed"
else
  echo "FAIL — template var tests FAILED ($COUNT assertions run)"
fi
exit "$FAIL"
