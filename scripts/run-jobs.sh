#!/bin/bash
# Master orchestrator — discovers all scripts/topics/*.yaml and
# scripts/generators/*.yaml configs, runs the jobs whose schedule matches today,
# then makes a single git commit for all generated content.
#
# Called nightly by launchd. Also safe to run manually for testing.
#
# Environment:
#   DIGEST_DATE=YYYY-MM-DD   Run date (default: today).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO_DIR/scripts/lib/job-config.sh"

DATE="${DIGEST_DATE:-$(date +%Y-%m-%d)}"
if ! [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "ERROR: DIGEST_DATE must be YYYY-MM-DD, got: $DATE" >&2
  exit 1
fi
DAY_OF_WEEK="$(day_of_week "$DATE")"

LOG_DIR="$REPO_DIR/scripts/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$DATE.log"

log "=== run-jobs started $(date) (run date: $DATE) ==="

ensure_venv
STUDIO_DIR="$(resolve_studio_dir)"

COMMITTED=0
FAILED_JOBS=""

for config in "$REPO_DIR/scripts/topics"/*.yaml "$REPO_DIR/scripts/generators"/*.yaml; do
  [ -f "$config" ] || continue
  JOB="$(basename "$config" .yaml)"
  JOB_KIND="$(basename "$(dirname "$config")")"
  SCHEDULE="$(cfg_get "$config" schedule daily)"
  OUTPUT_TPL="$(cfg_get "$config" output)"

  if [ -z "$OUTPUT_TPL" ]; then
    log "ERROR: $JOB: $config declares no output:"
    FAILED_JOBS="$FAILED_JOBS $JOB"
    continue
  fi

  set_tpl_vars "$DATE" "$SCHEDULE"
  OUTPUT_FILE="$(resolve_output "$OUTPUT_TPL")"
  if ! assert_no_placeholders "$OUTPUT_FILE" "output: in $config" \
    || ! assert_output_boundary "$JOB_KIND" "$OUTPUT_FILE"; then
    FAILED_JOBS="$FAILED_JOBS $JOB"
    continue
  fi

  job_scheduled_today "$SCHEDULE" "$DAY_OF_WEEK" && SCHEDULED=0 || SCHEDULED=$?
  if [ "$SCHEDULED" = "2" ]; then
    log "ERROR: $JOB: unknown schedule '$SCHEDULE' in $config (weekdays|saturday|sunday|daily)"
    FAILED_JOBS="$FAILED_JOBS $JOB"
    continue
  fi
  if [ "$SCHEDULED" != "0" ]; then
    log "$JOB: not scheduled today (schedule: $SCHEDULE)"
    continue
  fi

  # Idempotency: -s, so an empty file from a killed run doesn't block the job forever.
  if [ -s "$OUTPUT_FILE" ]; then
    log "$JOB: output exists — skipping"
    continue
  fi

  log "--- Running job: $JOB ---"
  # Subshell isolates set -e failures so one job failure doesn't kill the loop.
  # DIGEST_DATE is inherited so a run crossing midnight can't write a file this
  # orchestrator isn't guarding.
  (DIGEST_DATE="$DATE" bash "$REPO_DIR/scripts/run-job.sh" "$JOB") \
    && COMMITTED=$((COMMITTED + 1)) \
    || { log "WARN: $JOB failed"; FAILED_JOBS="$FAILED_JOBS $JOB"; }
done

# Single commit for all successfully generated content.
# Uses porcelain, not `git diff HEAD`, which cannot see untracked files — and
# every new digest is untracked.
if [ -z "$(git -C "$REPO_DIR" status --porcelain -- src/content/)" ]; then
  log "No new content to commit."
else
  git -C "$REPO_DIR" add -A src/content/
  git -C "$REPO_DIR" commit -m "digest: $DATE [automated]"
  log "Committed $COMMITTED job(s)."
fi

# Push separately so a push failure doesn't abort the run, and so unpushed
# commits are retried on later nights.
UNPUSHED=$(git -C "$REPO_DIR" rev-list --count @{u}..HEAD 2>/dev/null || echo "0")
if [ "$UNPUSHED" != "0" ]; then
  log "Pushing $UNPUSHED unpushed commit(s)..."
  if git -C "$REPO_DIR" push origin main 2>&1 | tee -a "$LOG_FILE"; then
    log "Push OK."
  else
    log "ERROR: push failed — $UNPUSHED commit(s) remain local. Will retry next run."
  fi
fi

if [ -n "$FAILED_JOBS" ]; then
  log "FAILED jobs:$FAILED_JOBS"
fi

# cleanup-old-digests.sh is intentionally not wired in — run it manually.

log "=== run-jobs finished $(date) ==="
