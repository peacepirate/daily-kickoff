#!/bin/bash
# Epic 4's central regression: the nightly path must be byte-identical.
#
#   bash scripts/tests/test-prompt-baseline.sh
#
# Digest *output* is non-deterministic — the model writes it — so the only
# surface that can be compared byte-for-byte is what the runner assembles before
# Claude is invoked: the resolved output path, the producer command line, and
# the rendered prompt. This suite recomputes all three for 4 topics x 7 days with
# the code as it stands and diffs against
# scripts/tests/fixtures/prompt-baseline-pre-epic4.txt, which was frozen from the
# pre-Epic-4 runner.
#
# NEVER regenerate that fixture to make this pass. A reference regenerated from
# the new code compares it with itself and passes no matter what broke. A
# deliberate prompt edit is the one legitimate way to fail this: re-freeze it in
# the same commit and say so in the message.
#
# 2026-08-03 is a Monday, so +0..6 covers Mon..Sun and every schedule word.
#
# No network, no git writes, no Claude. Reads the real configs and prompts —
# that is the point; a fixture copy of them would drift and prove nothing.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$REPO_DIR/scripts/tests/fixtures/prompt-baseline-pre-epic4.txt"

FAIL=0
COUNT=0
ok()   { COUNT=$((COUNT + 1)); printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad()  { COUNT=$((COUNT + 1)); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=1; }
skip() { printf "  \033[33mskip\033[0m  %s\n" "$*"; }

echo "prompt/producer baseline"

PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
if ! "$PYBIN" -c 'import yaml' 2>/dev/null; then
  skip "pyyaml unavailable in $PYBIN — run any kickoff command once to build scripts/.venv"
  exit 0
fi

[ -f "$FIXTURE" ] || { bad "frozen baseline missing: $FIXTURE"; echo; echo "FAIL"; exit 1; }

. "$REPO_DIR/scripts/lib/job-config.sh"
ensure_venv

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── The mirror ───────────────────────────────────────────────────────────────
#
# These lines reproduce run-job.sh's assembly. A mirror can drift from the thing
# it mirrors, so the structural assertions further down pin the two together:
# they fail if run-job.sh stops rendering the producer, starts appending a flag
# of its own, or stops passing the prompt through render_placeholders.

emit_rows() {
  local cfg JOB SCHEDULE PRODUCER_TPL PROMPT_REL OUTPUT_TPL offset DATE PRODUCER OUT_ABS OUT_REL SHA
  for cfg in "$REPO_DIR"/scripts/topics/*.yaml; do
    JOB="$(basename "$cfg" .yaml)"
    # A fetch-step config has no prompt and no output, so it has no row to
    # freeze. Skipped rather than counted, which keeps this baseline about the
    # nightly *publish* path and keeps the 28-row assertion meaningful as
    # fetch-only source pools are added beside it.
    [ "$(cfg_get "$cfg" step llm)" = "fetch" ] && continue
    SCHEDULE="$(cfg_get "$cfg" schedule daily)"
    PRODUCER_TPL="$(cfg_get "$cfg" producer)"
    PROMPT_REL="$(cfg_get "$cfg" prompt)"
    OUTPUT_TPL="$(cfg_get "$cfg" output)"
    for offset in 0 1 2 3 4 5 6; do
      DATE="$(date_offset 2026-08-03 "$offset")"
      set_tpl_vars "$DATE" "$SCHEDULE"
      PRODUCER="$(render_placeholders "$PRODUCER_TPL")"
      OUT_ABS="$(resolve_output "$OUTPUT_TPL")"
      OUT_REL="${OUT_ABS#$REPO_DIR/}"
      SHA="$(printf '%s\n' "$(render_placeholders "$(cat "$REPO_DIR/$PROMPT_REL")")" \
             | shasum -a 256 | cut -d' ' -f1)"
      # `echo scripts/$PRODUCER` unquoted, reproducing the expansion at the
      # producer call site verbatim — including how an empty {{WEEKLY_FLAG}}
      # collapses under word-splitting. That collapse is what is being frozen.
      echo "job=$JOB date=$DATE dow=$(day_of_week "$DATE") schedule=$SCHEDULE | $OUT_REL | producer=$(echo scripts/$PRODUCER) | prompt_sha256=$SHA"
    done
  done
}

grep -v '^#' "$FIXTURE" > "$WORK/expected.txt"
emit_rows > "$WORK/actual.txt" 2>"$WORK/emit.err"

exp_rows="$(wc -l < "$WORK/expected.txt" | tr -d ' ')"
act_rows="$(wc -l < "$WORK/actual.txt" | tr -d ' ')"

[ "$exp_rows" = "28" ] \
  && ok "frozen baseline holds 28 rows (4 topics x 7 days)" \
  || bad "frozen baseline holds $exp_rows rows, expected 28 — was it edited?"

[ "$act_rows" = "$exp_rows" ] \
  && ok "recomputed $act_rows rows" \
  || bad "recomputed $act_rows rows against $exp_rows frozen$( [ -s "$WORK/emit.err" ] && echo " (stderr: $(head -3 "$WORK/emit.err" | tr '\n' ' '))" )"

if diff -q "$WORK/expected.txt" "$WORK/actual.txt" >/dev/null 2>&1; then
  ok "all 28 rows byte-identical to the pre-Epic-4 runner"
else
  bad "the nightly path changed — divergent rows below"
  # Name the row and the column, so the operator does not diff 28 sha256s by eye.
  n=0
  while IFS= read -r want; do
    n=$((n + 1))
    got="$(sed -n "${n}p" "$WORK/actual.txt")"
    [ "$want" = "$got" ] && continue
    printf "        row %d\n          frozen:      %s\n          recomputed:  %s\n" "$n" "$want" "$got"
    IFS='|' read -r w_key w_out w_prod w_sha <<<"$want"
    IFS='|' read -r g_key g_out g_prod g_sha <<<"$got"
    [ "$w_key"  = "$g_key"  ] || printf "          ↳ job/date/schedule differs\n"
    [ "$w_out"  = "$g_out"  ] || printf "          ↳ output path differs\n"
    [ "$w_prod" = "$g_prod" ] || printf "          ↳ producer command line differs\n"
    [ "$w_sha"  = "$g_sha"  ] || printf "          ↳ assembled prompt differs\n"
  done < "$WORK/expected.txt"
fi

# ── Structural pins — keep the mirror honest ─────────────────────────────────
#
# The rows above are recomputed by this file, not by run-job.sh. If run-job.sh
# grew a second producer argument, these rows would still match and the suite
# would be worth nothing. Assert the shape of the real call site instead.

RUNJOB="$REPO_DIR/scripts/run-job.sh"

grep -q 'PRODUCER="\$(render_placeholders "\$PRODUCER_TPL")"' "$RUNJOB" \
  && ok "run-job.sh renders the producer through render_placeholders" \
  || bad "run-job.sh no longer renders the producer — this suite's mirror is stale"

grep -q 'scripts/\$PRODUCER > "\$CONTENT_FILE"' "$RUNJOB" \
  && ok "run-job.sh invokes the producer as \`scripts/\$PRODUCER\` and nothing more" \
  || bad "the producer call site changed — this suite's mirror is stale"

# A shell variable named WEEKLY_FLAG, not a mention of the placeholder in a
# comment: the flag is the config's to declare now.
grep -qE '\$\{?WEEKLY_FLAG|^[[:space:]]*WEEKLY_FLAG=' "$RUNJOB" \
  && bad "run-job.sh still carries a WEEKLY_FLAG variable — the flag belongs to the config now (S4.2)" \
  || ok "run-job.sh appends no flag of its own (S4.2)"

# Every topic must ask for the flag by name, or Saturday silently loses its
# full-week window and the digest quietly narrows.
for cfg in "$REPO_DIR"/scripts/topics/*.yaml; do
  JOB="$(basename "$cfg" .yaml)"
  grep -q '^producer:.*{{WEEKLY_FLAG}}' "$cfg" \
    && ok "topics/$JOB.yaml declares {{WEEKLY_FLAG}}" \
    || bad "topics/$JOB.yaml does not declare {{WEEKLY_FLAG}} — Saturday loses its weekly window"
done

echo
if [ "$FAIL" = "0" ]; then
  echo "PASS ($COUNT) — prompt/producer baseline unchanged"
else
  echo "FAIL — prompt/producer baseline FAILED ($COUNT assertions run)"
fi
exit "$FAIL"
