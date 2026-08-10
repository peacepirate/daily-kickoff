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
STEP="$(cfg_get "$CONFIG_FILE" step llm)"
[ -n "$STEP" ] || STEP="llm"
if ! is_known_step "$STEP"; then
  log "ERROR: [$JOB] unknown step '$STEP' in $CONFIG_FILE (known: $JOB_STEPS)"
  exit 1
fi

# What a job does with its record sidecar once the bundle exists. A closed
# vocabulary, refusing by default like every other one here: an unrecognised
# word must not read as "no ingestion" and quietly stop filling the pool.
#
# `pool` is the only value, and it names no path — see FEED_STATE_REL.
INGEST="$(cfg_get "$CONFIG_FILE" ingest)"
case "$INGEST" in
  ""|None) INGEST="" ;;
  pool)    ;;
  *) log "ERROR: [$JOB] unknown ingest '$INGEST' in $CONFIG_FILE (known: pool)"; exit 1 ;;
esac
if [ -n "$INGEST" ] && [ "$STEP" != "fetch" ]; then
  log "ERROR: [$JOB] ingest: is only meaningful on step: fetch — $CONFIG_FILE is step: $STEP."
  exit 1
fi

# A `fetch` job stops at the bundle, so it declares neither a prompt nor an
# output: there is nothing to render and nothing to write. Requiring them anyway
# was what made a fetch-only config inexpressible.
if [ "$STEP" = "fetch" ]; then
  if [ -z "$PRODUCER_TPL" ]; then
    log "ERROR: [$JOB] $CONFIG_FILE is step: fetch and must declare producer:"
    exit 1
  fi
  if [ -n "$PROMPT_REL" ] || [ -n "$OUTPUT_TPL" ]; then
    log "ERROR: [$JOB] $CONFIG_FILE is step: fetch — it must declare neither prompt: nor output:."
    log "       Declaring them implies a publish this step will never perform."
    exit 1
  fi
elif [ "$STEP" = "transform" ]; then
  # A transform declares what it runs and where the result lands, and nothing
  # else. No prompt, because the runner invokes no model — the producer owns
  # whatever it does internally, including calling one. Declaring a prompt would
  # imply a render this step never performs, the same way a fetch declaring an
  # output implies a publish.
  if [ -z "$PRODUCER_TPL" ] || [ -z "$OUTPUT_TPL" ]; then
    log "ERROR: [$JOB] $CONFIG_FILE is step: transform and must declare producer: and output:"
    exit 1
  fi
  if [ -n "$PROMPT_REL" ]; then
    log "ERROR: [$JOB] $CONFIG_FILE is step: transform — it must not declare prompt:."
    log "       The runner renders no prompt and calls no model for this step."
    exit 1
  fi
elif [ -z "$PRODUCER_TPL" ] || [ -z "$PROMPT_REL" ] || [ -z "$OUTPUT_TPL" ]; then
  log "ERROR: [$JOB] $CONFIG_FILE must declare producer:, prompt: and output:"
  exit 1
fi
[ -n "$MODEL" ] || MODEL="claude-sonnet-5"

# At config load, not at verification time: a typo'd schema would otherwise cost
# a full Claude call and then quarantine a file that was never going to pass.
#
# Only the model path has a schema. SCHEMA defaults to `digest`, so checking it
# for a transform would enforce a frontmatter contract against a JSON artifact
# that will never have one.
if [ "$STEP" = "llm" ] && ! is_known_schema "$SCHEMA"; then
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

# The feed site, resolved and validated before anything is written — including
# the refusal to resolve inside this repo. Scoped to feed jobs, so a topic
# job's environment is unchanged, and exported because the producer is a Python
# subprocess.
if [ "$JOB_KIND" = "feed" ] && [ "$STEP" != "fetch" ]; then
  FEED_SITE_DIR="$(resolve_feed_site_dir)"
  require_feed_site_dir "$FEED_SITE_DIR" || exit 1
  export FEED_SITE_DIR
fi

set_tpl_vars "$DATE" "$SCHEDULE"

# The record sidecar path, defined once and reached by the config as {{RECORDS}}.
# The producer writes it and the ingest step reads it, so a path spelled out in
# the producer line and derived again below would be two copies that must agree
# — the drift class bundle.py exists to prevent, in a different place.
#
# Repo-relative because the producer runs with $REPO_DIR as its cwd. Under
# scripts/logs/ because a sidecar is a run artifact: the pool is the durable
# record, and re-ingesting a month of sidecars must not be mistaken for history.
TPL_RECORDS="scripts/logs/records-$DATE-$JOB.jsonl"

# The producer is a template like every other config string: `--weekly` belongs
# to fetch_sources.py, and appending it to every producer handed select_corpus.py
# a flag it cannot parse.
# A transform's producer writes the output file itself rather than piping a
# bundle to stdout, so it has to be able to name it — hence {{OUTPUT}}, and
# hence resolving the path before the producer line is rendered. The boundary
# is asserted here, before the producer is handed a path it could write to.
if [ "$STEP" = "transform" ]; then
  OUTPUT_FILE="$(resolve_output "$OUTPUT_TPL")"
  assert_no_placeholders "$OUTPUT_FILE" "output: in $CONFIG_FILE" || exit 1
  assert_output_boundary "$JOB_KIND" "$OUTPUT_FILE" || exit 1
  TPL_OUTPUT="$OUTPUT_FILE"
fi

PRODUCER="$(render_placeholders "$PRODUCER_TPL")"
assert_no_placeholders "$PRODUCER" "producer: in $CONFIG_FILE" || exit 1

if [ "$STEP" = "llm" ]; then
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
fi  # STEP = llm

# ── Producer ──────────────────────────────────────────────────────────────────
CONTENT_FILE="$LOG_DIR/fetched-$DATE-$JOB.txt"
cd "$REPO_DIR"

# A transform has no bundle. Its producer reads durable state this repo already
# holds — the pool, the ledger — and writes its artifact directly, so there is
# nothing to capture on stdout and nothing for the `^URL:` assertion below to
# find. It exits here rather than threading a third set of conditions through
# the fetch/llm path.
if [ "$STEP" = "transform" ]; then
  ensure_tool_path
  log "Running transform for $JOB: $PRODUCER ..."
  set +e
  "$PYTHON_BIN" scripts/$PRODUCER 2>&1 | tee -a "$LOG_FILE"
  TRANSFORM_RC=${PIPESTATUS[0]}
  set -e
  if [ "$TRANSFORM_RC" -ne 0 ]; then
    log "ERROR: [$JOB] transform exited $TRANSFORM_RC — nothing written."
    exit 1
  fi
  # The producer exiting 0 is not evidence it wrote anything. That is the exact
  # shape this project has already paid thirteen nights for, and the claude CLI
  # does the same thing, which is why verify_output exists on the model path.
  if [ ! -s "$OUTPUT_FILE" ]; then
    log "ERROR: [$JOB] transform exited 0 but wrote no output: $OUTPUT_FILE"
    exit 1
  fi
  log "[$JOB] step: transform — wrote $OUTPUT_FILE ($(wc -c < "$OUTPUT_FILE" | tr -d ' ') bytes)."
  log "=== run-job.sh [$JOB] finished $(date) ==="
  exit 0
fi

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

if [ "$STEP" = "fetch" ]; then
  log "[$JOB] step: fetch — bundle written to $CONTENT_FILE. Nothing published."
  if [ -n "$INGEST" ]; then
    if ingest_applies; then
      ingest_feed_records "$DATE" "$REPO_DIR/$TPL_RECORDS" || exit 1
    else
      # Silence here would be its own trap: the operator needs to know the pool
      # did not move, and how to move it by hand with the right date.
      log "[$JOB] BUNDLE_FILE set — skipping ingest. See ingest_applies for why."
      log "       To ingest that sidecar, name the date it was fetched on:"
      log "       scripts/.venv/bin/python3 scripts/lib/feed_pool.py ingest --records … --state $(feed_state_dir) --date … --blocklist …"
    fi
  fi
else
  run_llm_job "$PROMPT_FILE" "$CONTENT_FILE" "$OUTPUT_FILE" "$MODEL" "$SCHEMA"
fi

log "=== run-job.sh [$JOB] finished $(date) ==="
