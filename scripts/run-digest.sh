#!/bin/bash
# Generates the daily AI digest.
# Step 1: Python fetches all sources (no Anthropic API — pure HTTP).
# Step 2: Claude synthesizes the fetched content (uses your subscription).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$REPO_DIR/scripts/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d).log"

log() { echo "$*" | tee -a "$LOG_FILE"; }

log "=== Digest run started $(date) ==="

# ── Python: fetch sources ─────────────────────────────────────────────────────
VENV="$REPO_DIR/scripts/.venv"
if [ ! -f "$VENV/bin/python3" ]; then
  log "Creating Python venv and installing deps (one-time)..."
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q httpx feedparser beautifulsoup4
fi
PYTHON_BIN="$VENV/bin/python3"

DAY_OF_WEEK=$(date +%u)  # 6 = Saturday
WEEKLY_FLAG=""
[ "$DAY_OF_WEEK" = "6" ] && WEEKLY_FLAG="--weekly"

log "Fetching sources ($([ -n "$WEEKLY_FLAG" ] && echo 'weekly — last 7 days' || echo 'daily — last 24 hours'))..."
CONTENT_FILE="$LOG_DIR/fetched-$(date +%Y-%m-%d).txt"

cd "$REPO_DIR"
"$PYTHON_BIN" scripts/fetch_sources.py $WEEKLY_FLAG > "$CONTENT_FILE" 2>&1
ITEM_COUNT=$(grep -c "^URL:" "$CONTENT_FILE" 2>/dev/null || echo "0")
log "Fetched $ITEM_COUNT items from sources."

if [ "$ITEM_COUNT" = "0" ]; then
  log "ERROR: No content fetched. Check $CONTENT_FILE for errors."
  exit 1
fi

# ── Claude: synthesize ────────────────────────────────────────────────────────
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
if [ -z "$CLAUDE_BIN" ]; then
  log "ERROR: claude CLI not found on PATH."
  exit 1
fi
log "Synthesizing with Claude ($CLAUDE_BIN)..."

FULL_PROMPT="$(cat scripts/digest-prompt.md)

---
# FETCHED SOURCE CONTENT

$(cat "$CONTENT_FILE")"

"$CLAUDE_BIN" \
  --dangerously-skip-permissions \
  --print \
  "$FULL_PROMPT" \
  2>&1 | tee -a "$LOG_FILE"

log "=== Digest run finished $(date) ==="
