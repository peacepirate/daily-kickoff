#!/bin/bash
# Master orchestrator — discovers all scripts/topics/*.yaml configs, runs qualifying
# topics per schedule and day-of-week, then makes a single git commit for all content.
#
# Called nightly by launchd. Also safe to run manually for testing.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOPICS_DIR="$REPO_DIR/scripts/topics"
VENV="$REPO_DIR/scripts/.venv"
DAY_OF_WEEK=$(date +%u)   # 1=Mon … 6=Sat … 7=Sun
DATE=$(date +%Y-%m-%d)
LOG_DIR="$REPO_DIR/scripts/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$DATE.log"

log() { echo "$*" | tee -a "$LOG_FILE"; }
log "=== run-all-topics started $(date) ==="

# Global Sunday skip
if [ "$DAY_OF_WEEK" = "7" ]; then
  log "Sunday — no topics run"
  exit 0
fi

# Ensure venv exists with pyyaml (needed to read topic configs)
if [ ! -f "$VENV/bin/python3" ]; then
  log "Creating Python venv (one-time)..."
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q httpx feedparser beautifulsoup4 pyyaml
fi

COMMITTED=0
FAILED_TOPICS=""

for config in "$TOPICS_DIR"/*.yaml; do
  TOPIC=$(basename "$config" .yaml)
  SCHEDULE=$("$VENV/bin/python3" -c "import yaml; c=yaml.safe_load(open('$config')); print(c.get('schedule','daily'))")
  THEME=$("$VENV/bin/python3" -c "import yaml; c=yaml.safe_load(open('$config')); print(c.get('theme','$TOPIC'))")

  # Weekly topics only run on Saturday
  if [ "$SCHEDULE" = "weekly" ] && [ "$DAY_OF_WEEK" != "6" ]; then
    log "Weekday — skipping weekly topic: $TOPIC"
    continue
  fi

  # Idempotency: skip if today's output already exists (-s, so an empty file from
  # a killed run doesn't block the topic forever)
  OUTPUT_FILE="$REPO_DIR/src/content/$THEME/$DATE.md"
  if [ -s "$OUTPUT_FILE" ]; then
    log "$TOPIC: output exists — skipping"
    continue
  fi

  log "--- Running topic: $TOPIC ---"
  # Subshell isolates set -e failures so one topic failure doesn't kill the loop.
  # DIGEST_DATE is inherited so a run crossing midnight can't write a file this
  # orchestrator isn't guarding.
  (DIGEST_DATE="$DATE" bash "$REPO_DIR/scripts/run-topic.sh" "$TOPIC") \
    && COMMITTED=$((COMMITTED + 1)) \
    || { log "WARN: $TOPIC failed"; FAILED_TOPICS="$FAILED_TOPICS $TOPIC"; }
done

# Single commit for all successfully generated content.
# Uses porcelain, not `git diff HEAD`, which cannot see untracked files — and
# every new digest is untracked.
if [ -z "$(git -C "$REPO_DIR" status --porcelain -- src/content/)" ]; then
  log "No new content to commit."
else
  git -C "$REPO_DIR" add -A src/content/
  git -C "$REPO_DIR" commit -m "digest: $DATE [automated]"
  log "Committed $COMMITTED topic(s)."
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

if [ -n "$FAILED_TOPICS" ]; then
  log "FAILED topics:$FAILED_TOPICS"
fi

# cleanup-old-digests.sh is intentionally not wired in — run it manually.

log "=== run-all-topics finished $(date) ==="
