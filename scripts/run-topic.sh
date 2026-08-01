#!/bin/bash
# Run a single topic end-to-end: fetch sources → Claude synthesis → write content file.
# Git operations are NOT performed here — run-all-topics.sh handles the single commit.
#
# Usage:
#   bash scripts/run-topic.sh TOPIC
#
# Environment:
#   DIGEST_DATE=YYYY-MM-DD   Run date (default: today). Set by run-all-topics.sh.
#   BUNDLE_FILE=path         Reuse a stored fetch bundle instead of fetching.

set -euo pipefail

TOPIC="${1:-}"
if [ -z "$TOPIC" ]; then
  echo "Usage: $0 TOPIC" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

DATE="${DIGEST_DATE:-$(date +%Y-%m-%d)}"
if ! [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "ERROR: DIGEST_DATE must be YYYY-MM-DD, got: $DATE" >&2
  exit 1
fi

date_offset() {  # BSD date with GNU fallback
  date -j -v"+${2}d" -f %Y-%m-%d "$1" +%Y-%m-%d 2>/dev/null || date -d "$1 + $2 days" +%Y-%m-%d
}

LOG_DIR="$REPO_DIR/scripts/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$DATE.log"

log() { echo "$*" | tee -a "$LOG_FILE"; }

log "=== run-topic.sh [$TOPIC] started $(date) (run date: $DATE) ==="

CONFIG_FILE="$REPO_DIR/scripts/topics/$TOPIC.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
  log "ERROR: No topic config at $CONFIG_FILE"
  log "       Available: $(ls -1 "$REPO_DIR/scripts/topics"/*.yaml | xargs -n1 basename | sed 's/\.yaml//' | tr '\n' ' ')"
  exit 1
fi

# ── Python venv ───────────────────────────────────────────────────────────────
VENV="$REPO_DIR/scripts/.venv"
if [ ! -f "$VENV/bin/python3" ]; then
  log "Creating Python venv and installing deps (one-time)..."
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q httpx feedparser beautifulsoup4 pyyaml
fi
PYTHON_BIN="$VENV/bin/python3"

TOPIC_SCHEDULE=$("$PYTHON_BIN" -c "import yaml; c=yaml.safe_load(open('$CONFIG_FILE')); print(c.get('schedule','daily'))")
THEME=$("$PYTHON_BIN" -c "import yaml; c=yaml.safe_load(open('$CONFIG_FILE')); print(c.get('theme','$TOPIC'))")

# ── Schedule / weekly flag ────────────────────────────────────────────────────
DAY_OF_WEEK=$(date -j -f %Y-%m-%d "$DATE" +%u 2>/dev/null || date -d "$DATE" +%u)  # 1=Mon … 6=Sat … 7=Sun

# Weekly topics always fetch with --weekly (full window) regardless of day.
# Daily topics use --weekly only on Saturdays (catchup window for the week).
WEEKLY_FLAG=""
if [ "$TOPIC_SCHEDULE" = "weekly" ] || [ "$DAY_OF_WEEK" = "6" ]; then
  WEEKLY_FLAG="--weekly"
fi

FORMAT="daily"
[ -n "$WEEKLY_FLAG" ] && FORMAT="weekly-synthesis"

OUTPUT_FILE="$REPO_DIR/src/content/$THEME/$DATE.md"

# ── Fetch sources ─────────────────────────────────────────────────────────────
CONTENT_FILE="$LOG_DIR/fetched-$DATE-$TOPIC.txt"
cd "$REPO_DIR"

if [ -n "${BUNDLE_FILE:-}" ]; then
  [ -f "$BUNDLE_FILE" ] || { log "ERROR: BUNDLE_FILE not found: $BUNDLE_FILE"; exit 1; }
  CONTENT_FILE="$BUNDLE_FILE"
  log "[$TOPIC] Using stored bundle: $CONTENT_FILE (no fetch)"
else
  log "Fetching sources for topic: $TOPIC ($([ -n "$WEEKLY_FLAG" ] && echo 'weekly — last 7 days' || echo 'daily — last 24 hours'))..."
  if ! "$PYTHON_BIN" scripts/fetch_sources.py --topic "$TOPIC" $WEEKLY_FLAG > "$CONTENT_FILE" 2>&1; then
    log "ERROR: [$TOPIC] fetch_sources.py failed:"
    tail -20 "$CONTENT_FILE" | tee -a "$LOG_FILE"
    exit 1
  fi
fi

# grep -c prints 0 *and* exits 1 on no-match, so `|| echo 0` yields "0\n0" and
# defeats an equality test. Test for presence instead.
if ! grep -q "^URL:" "$CONTENT_FILE"; then
  log "ERROR: No content fetched for $TOPIC. Check $CONTENT_FILE."
  exit 1
fi
log "[$TOPIC] Fetched $(grep -c "^URL:" "$CONTENT_FILE") items from sources."

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

# The prompt names its output dir in prose; the guard here and in run-all-topics
# derives it from `theme:`. If they drift, the topic skips forever in silence.
if ! grep -q "src/content/$THEME/" "$PROMPT_FILE"; then
  log "ERROR: [$TOPIC] prompt does not write to src/content/$THEME/ (theme from $CONFIG_FILE)."
  exit 1
fi

PROMPT_TEXT="$(cat "$PROMPT_FILE")"
PROMPT_TEXT="${PROMPT_TEXT//\{\{DATE_PLUS_30\}\}/$(date_offset "$DATE" 30)}"
PROMPT_TEXT="${PROMPT_TEXT//\{\{DATE_PLUS_1\}\}/$(date_offset "$DATE" 1)}"
PROMPT_TEXT="${PROMPT_TEXT//\{\{DATE\}\}/$DATE}"
PROMPT_TEXT="${PROMPT_TEXT//\{\{FORMAT\}\}/$FORMAT}"

# Fail closed on an unfilled placeholder. Checked before the fetched bundle is
# appended, since scraped article text may legitimately contain "TODAY".
if printf '%s' "$PROMPT_TEXT" | grep -qE '\{\{[A-Z_0-9]+\}\}|(^|[^A-Za-z_])TODAY([^A-Za-z_]|$)'; then
  log "ERROR: [$TOPIC] unsubstituted placeholder in $PROMPT_FILE:"
  printf '%s' "$PROMPT_TEXT" | grep -nE '\{\{[A-Z_0-9]+\}\}|(^|[^A-Za-z_])TODAY([^A-Za-z_]|$)' | tee -a "$LOG_FILE"
  exit 1
fi

log "[$TOPIC] Synthesizing with Claude ($CLAUDE_BIN) → src/content/$THEME/$DATE.md ..."

FULL_PROMPT="$PROMPT_TEXT

---
# FETCHED SOURCE CONTENT

$(cat "$CONTENT_FILE")"

"$CLAUDE_BIN" \
  --dangerously-skip-permissions \
  --print \
  --model claude-sonnet-5 \
  "$FULL_PROMPT" \
  2>&1 | tee -a "$LOG_FILE"

# The claude CLI exits 0 whether or not it wrote anything.
if [ ! -s "$OUTPUT_FILE" ]; then
  log "ERROR: [$TOPIC] Claude exited 0 but $OUTPUT_FILE is missing or empty."
  exit 1
fi
if ! head -1 "$OUTPUT_FILE" | grep -q '^---'; then
  log "ERROR: [$TOPIC] $OUTPUT_FILE has no frontmatter — likely truncated."
  exit 1
fi

log "[$TOPIC] Wrote $(wc -c < "$OUTPUT_FILE" | tr -d ' ') bytes to src/content/$THEME/$DATE.md"
log "=== run-topic.sh [$TOPIC] finished $(date) ==="
