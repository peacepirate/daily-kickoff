#!/bin/bash
# Run a single job end-to-end: producer → bundle → Claude synthesis → verified
# output file. Git operations are NOT performed here — run-jobs.sh handles the
# single commit.
#
# Usage:
#   bash scripts/run-job.sh JOB
#
# Environment:
#   DIGEST_DATE=YYYY-MM-DD   Run date (default: today). Set by run-jobs.sh.
#   BUNDLE_FILE=path         Reuse a stored bundle instead of running the producer.

set -euo pipefail

JOB="${1:-}"
if [ -z "$JOB" ]; then
  echo "Usage: $0 JOB" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO_DIR/scripts/lib/job-config.sh"

DATE="${DIGEST_DATE:-$(date +%Y-%m-%d)}"
if ! [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "ERROR: DIGEST_DATE must be YYYY-MM-DD, got: $DATE" >&2
  exit 1
fi

LOG_DIR="$REPO_DIR/scripts/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$DATE.log"
JOB_LABEL="$JOB"

log "=== run-job.sh [$JOB] started $(date) (run date: $DATE) ==="

CONFIG_FILE="$(find_job_config "$JOB")" || {
  log "ERROR: No job config at scripts/{topics,generators}/$JOB.yaml"
  log "       Available: $(list_jobs)"
  exit 1
}
JOB_KIND="$(basename "$(dirname "$CONFIG_FILE")")"

ensure_venv

SCHEDULE="$(cfg_get "$CONFIG_FILE" schedule daily)"
PRODUCER_TPL="$(cfg_get "$CONFIG_FILE" producer)"
PROMPT_REL="$(cfg_get "$CONFIG_FILE" prompt)"
OUTPUT_TPL="$(cfg_get "$CONFIG_FILE" output)"
MODEL="$(cfg_get "$CONFIG_FILE" model claude-sonnet-5)"
SCHEMA="$(cfg_get "$CONFIG_FILE" schema digest)"
if [ -z "$PRODUCER_TPL" ] || [ -z "$PROMPT_REL" ] || [ -z "$OUTPUT_TPL" ]; then
  log "ERROR: [$JOB] $CONFIG_FILE must declare producer:, prompt: and output:"
  exit 1
fi
[ -n "$MODEL" ] || MODEL="claude-sonnet-5"

# At config load, not at verification time: a typo'd schema would otherwise cost
# a full Claude call and then quarantine a file that was never going to pass.
if ! is_known_schema "$SCHEMA"; then
  log "ERROR: [$JOB] unknown schema '$SCHEMA' in $CONFIG_FILE (known: $JOB_SCHEMAS)"
  exit 1
fi

# Resolved before set_tpl_vars, which publishes it as {{STUDIO_DIR}}.
NEEDS_STUDIO=0
if [ "$JOB_KIND" = "generators" ]; then NEEDS_STUDIO=1; fi
case "$OUTPUT_TPL" in *'$STUDIO_DIR'*|*'${STUDIO_DIR}'*) NEEDS_STUDIO=1 ;; esac
if [ "$NEEDS_STUDIO" = 1 ]; then
  STUDIO_DIR="$(resolve_studio_dir)"
  require_studio_dir "$STUDIO_DIR" || exit 1
  # Exported, because the producer runs as a Python subprocess and
  # select_corpus.py refuses to guess where the studio is (D5) — unexported it
  # dies on its first run. Scoped to jobs that need a studio, so a topic job's
  # environment is unchanged.
  export STUDIO_DIR
fi

set_tpl_vars "$DATE" "$SCHEDULE"

# The producer is a template like every other config string: `--weekly` belongs
# to fetch_sources.py, and appending it to every producer handed select_corpus.py
# a flag it cannot parse.
PRODUCER="$(render_placeholders "$PRODUCER_TPL")"
assert_no_placeholders "$PRODUCER" "producer: in $CONFIG_FILE" || exit 1

OUTPUT_FILE="$(resolve_output "$OUTPUT_TPL")"
assert_no_placeholders "$OUTPUT_FILE" "output: in $CONFIG_FILE" || exit 1
assert_output_boundary "$JOB_KIND" "$OUTPUT_FILE" || exit 1

PROMPT_FILE="$REPO_DIR/$PROMPT_REL"
if [ ! -f "$PROMPT_FILE" ]; then
  log "ERROR: [$JOB] prompt file not found: $PROMPT_FILE"
  exit 1
fi

# A prompt that names a path other than the one this job verifies is a silent,
# permanent skip loop.
#
# Either spelling is accepted, and nothing else. A digest prompt names the
# repo-relative path; a studio-writing prompt cannot, because its output is
# absolute and outside the repo — it names {{STUDIO_DIR}}/…, which renders to
# the absolute form. Both are exact matches against this job's own resolved
# output, so a prompt naming some other path still fails here, before Claude.
OUTPUT_REL="${OUTPUT_FILE#$REPO_DIR/}"
# Here-string, not a pipe: under `set -o pipefail`, `grep -q` exits on first
# match and the writer dies of SIGPIPE (141), failing the whole pipeline even
# though the match succeeded.
PROMPT_RENDERED="$(render_placeholders "$(cat "$PROMPT_FILE")")"
if ! grep -qF "$OUTPUT_REL" <<<"$PROMPT_RENDERED" \
   && ! grep -qF "$OUTPUT_FILE" <<<"$PROMPT_RENDERED"; then
  log "ERROR: [$JOB] $PROMPT_REL names neither $OUTPUT_REL nor $OUTPUT_FILE (output: in $CONFIG_FILE)."
  exit 1
fi

# ── Producer ──────────────────────────────────────────────────────────────────
CONTENT_FILE="$LOG_DIR/fetched-$DATE-$JOB.txt"
cd "$REPO_DIR"

if [ -n "${BUNDLE_FILE:-}" ]; then
  [ -f "$BUNDLE_FILE" ] || { log "ERROR: BUNDLE_FILE not found: $BUNDLE_FILE"; exit 1; }
  CONTENT_FILE="$BUNDLE_FILE"
  log "[$JOB] Using stored bundle: $CONTENT_FILE (producer not run)"
else
  log "Running producer for $JOB: $PRODUCER ..."
  # Unquoted on purpose: $PRODUCER is a whole command line, and an empty
  # {{WEEKLY_FLAG}} must collapse under word-splitting rather than becoming an
  # empty argument.
  if ! "$PYTHON_BIN" scripts/$PRODUCER > "$CONTENT_FILE" 2>&1; then
    log "ERROR: [$JOB] producer failed:"
    tail -20 "$CONTENT_FILE" | tee -a "$LOG_FILE"
    exit 1
  fi
fi

# grep -c prints 0 *and* exits 1 on no-match, so `|| echo 0` yields "0\n0" and
# defeats an equality test. Test for presence instead.
if ! grep -q "^URL:" "$CONTENT_FILE"; then
  log "ERROR: No content produced for $JOB. Check $CONTENT_FILE."
  exit 1
fi
log "[$JOB] Produced $(grep -c "^URL:" "$CONTENT_FILE") items."

run_llm_job "$PROMPT_FILE" "$CONTENT_FILE" "$OUTPUT_FILE" "$MODEL" "$SCHEMA"

log "=== run-job.sh [$JOB] finished $(date) ==="
