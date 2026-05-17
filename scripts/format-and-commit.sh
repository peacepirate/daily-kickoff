#!/usr/bin/env bash
# Assembles an Astro-formatted digest .md from Cowork's output and commits
# it to the content-staging branch.
#
# Usage: ./scripts/format-and-commit.sh <cowork-output.md> [YYYY-MM-DD]
#
# The input file must contain a ---ASTRO--- / ---END--- block after the body.
# Output goes to src/content/ai/YYYY-MM-DD.md.

set -euo pipefail

INPUT="${1:-}"
DATE_ARG="${2:-$(date +%Y-%m-%d)}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTENT_DIR="$REPO_ROOT/src/content/ai"
DEST="$CONTENT_DIR/${DATE_ARG}.md"

if [ -z "$INPUT" ] || [ ! -f "$INPUT" ]; then
  echo "ERROR: input file not found: '$INPUT'"
  echo "Usage: $0 <cowork-output.md> [YYYY-MM-DD]"
  exit 1
fi

# Extract body: everything before the ---ASTRO--- delimiter
BODY=$(awk '/^---ASTRO---/{exit} {print}' "$INPUT")

# Extract frontmatter: lines between ---ASTRO--- and ---END---
FRONTMATTER=$(awk '/^---ASTRO---/{found=1; next} /^---END---/{exit} found{print}' "$INPUT")

if [ -z "$FRONTMATTER" ]; then
  echo "ERROR: No ---ASTRO--- block found in '$INPUT'. Check Cowork output."
  exit 1
fi

# Assemble the Astro .md: YAML frontmatter + body
mkdir -p "$CONTENT_DIR"
{
  printf -- '---\n'
  printf '%s\n' "$FRONTMATTER"
  printf -- '---\n\n'
  printf '%s\n' "$BODY"
} > "$DEST"

echo "Assembled: $DEST"

# Switch to or create content-staging branch
cd "$REPO_ROOT"
git fetch origin

if git ls-remote --exit-code --heads origin content-staging > /dev/null 2>&1; then
  # Branch exists on remote — check it out tracking origin
  git checkout content-staging 2>/dev/null || git checkout -b content-staging --track origin/content-staging
  git pull --ff-only origin content-staging
else
  # First time — branch off main
  git checkout main
  git pull --ff-only origin main
  git checkout -b content-staging
fi

git add "src/content/ai/${DATE_ARG}.md"
git commit -m "digest: add ${DATE_ARG} AI digest"
git push origin content-staging

echo "Pushed to content-staging. Site will publish at 11:59 PM ET."
