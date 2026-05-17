#!/bin/bash
# Run a single topic end-to-end: fetch sources → Claude synthesis → write content file.
# Git operations are NOT performed here — run-all-topics.sh handles the single commit.
#
# Usage:
#   bash scripts/run-topic.sh TOPIC
#   bash scripts/run-topic.sh ai
#   bash scripts/run-topic.sh leadership   # orchestrator passes this on Saturdays only

set -euo pipefail

TOPIC="${1:-}"
if [ -z "$TOPIC" ]; then
  echo "Usage: $0 TOPIC" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$REPO_DIR/scripts/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d).log"

log() { echo "$*" | tee -a "$LOG_FILE"; }

log "=== run-topic.sh [$TOPIC] started $(date) ==="

# ── Python venv ───────────────────────────────────────────────────────────────
VENV="$REPO_DIR/scripts/.venv"
if [ ! -f "$VENV/bin/python3" ]; then
  log "Creating Python venv and installing deps (one-time)..."
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q httpx feedparser beautifulsoup4 pyyaml
fi
PYTHON_BIN="$VENV/bin/python3"

# ── Schedule / weekly flag ────────────────────────────────────────────────────
DAY_OF_WEEK=$(date +%u)  # 1=Mon … 6=Sat … 7=Sun
WEEKLY_FLAG=""
[ "$DAY_OF_WEEK" = "6" ] && WEEKLY_FLAG="--weekly"

# ── Fetch sources ─────────────────────────────────────────────────────────────
log "Fetching sources for topic: $TOPIC ($([ -n "$WEEKLY_FLAG" ] && echo 'weekly — last 7 days' || echo 'daily — last 24 hours'))..."
CONTENT_FILE="$LOG_DIR/fetched-$(date +%Y-%m-%d)-$TOPIC.txt"

cd "$REPO_DIR"
"$PYTHON_BIN" scripts/fetch_sources.py --topic "$TOPIC" $WEEKLY_FLAG > "$CONTENT_FILE" 2>&1
ITEM_COUNT=$(grep -c "^URL:" "$CONTENT_FILE" 2>/dev/null || echo "0")
log "[$TOPIC] Fetched $ITEM_COUNT items from sources."

if [ "$ITEM_COUNT" = "0" ]; then
  log "ERROR: No content fetched for $TOPIC. Check $CONTENT_FILE for errors."
  exit 1
fi

# ── Claude synthesis ──────────────────────────────────────────────────────────
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
if [ -z "$CLAUDE_BIN" ]; then
  log "ERROR: claude CLI not found on PATH."
  exit 1
fi

PROMPT_FILE="$REPO_DIR/scripts/prompts/$TOPIC.md"
if [ ! -f "$PROMPT_FILE" ]; then
  log "ERROR: Prompt file not found: $PROMPT_FILE"
  exit 1
fi

log "[$TOPIC] Synthesizing with Claude ($CLAUDE_BIN)..."

FULL_PROMPT="$(cat "$PROMPT_FILE")

---
# FETCHED SOURCE CONTENT

$(cat "$CONTENT_FILE")"

"$CLAUDE_BIN" \
  --dangerously-skip-permissions \
  --print \
  "$FULL_PROMPT" \
  2>&1 | tee -a "$LOG_FILE"

log "=== run-topic.sh [$TOPIC] finished $(date) ==="
