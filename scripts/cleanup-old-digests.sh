#!/bin/bash
# Deletes digest .md files older than N days that do NOT have `starred: true` in their frontmatter.
# Manual tool — not wired into run-all-topics.sh.
#
# `starred: true` must be added to the frontmatter by hand. The site's ★ button
# is unrelated: it writes per-action-item keys to browser localStorage only.
#
# Usage:
#   bash scripts/cleanup-old-digests.sh               # dry-run (safe, prints only)
#   bash scripts/cleanup-old-digests.sh --confirm      # actually deletes
#   bash scripts/cleanup-old-digests.sh --days 90      # override threshold

set -euo pipefail

DAYS=365
CONFIRM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM=true; shift ;;
    --days)    DAYS="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONTENT_DIR="$REPO_DIR/src/content"
CUTOFF=$(date -v-${DAYS}d +%Y-%m-%d 2>/dev/null || date -d "${DAYS} days ago" +%Y-%m-%d)

echo "Threshold: files with date < $CUTOFF (${DAYS} days ago)"
echo "Mode: $( [ "$CONFIRM" = true ] && echo 'DELETE' || echo 'DRY-RUN')"
echo ""

deleted=0
starred=0
skipped=0

while IFS= read -r file; do
  base="$(basename "$file")"
  if [[ "$base" == ".gitkeep" ]]; then continue; fi
  date_part="${base%.md}"
  if ! [[ "$date_part" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then continue; fi

  if [[ "$date_part" < "$CUTOFF" ]]; then
    # Check for starred: true in frontmatter — skip protected files
    if grep -qm1 "^starred: true$" "$file" 2>/dev/null; then
      echo "STARRED (kept): $file"
      starred=$((starred + 1))
      continue
    fi

    if [ "$CONFIRM" = true ]; then
      rm "$file"
      echo "DELETED: $file"
    else
      echo "WOULD DELETE: $file"
    fi
    deleted=$((deleted + 1))
  else
    skipped=$((skipped + 1))
  fi
done < <(find "$CONTENT_DIR" -name "*.md" | sort)

echo ""
echo "Summary: $deleted file(s) $( [ "$CONFIRM" = true ] && echo 'deleted' || echo 'would be deleted'), $starred starred (kept), $skipped too recent (kept)"
if [ "$CONFIRM" = false ] && [ "$deleted" -gt 0 ]; then
  echo "Run with --confirm to actually delete."
fi
