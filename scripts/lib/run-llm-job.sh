#!/bin/bash
# Tier 1 — the shared LLM job core. Indifferent to producer, schedule,
# destination and naming.
#
#   run_llm_job PROMPT_FILE BUNDLE_FILE OUTPUT_FILE [MODEL]
#
# Environment:
#   LOG_FILE     Required. Run log; also the quarantine directory for bad output.
#   TPL_<NAME>   Substituted into the prompt wherever {{<NAME>}} appears.
#   JOB_LABEL    Optional prefix for log lines.

KICKOFF_LIB_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log() { echo "$*" | tee -a "$LOG_FILE"; }

date_offset() {  # BSD date with GNU fallback
  date -j -v"+${2}d" -f %Y-%m-%d "$1" +%Y-%m-%d 2>/dev/null || date -d "$1 + $2 days" +%Y-%m-%d
}

ensure_venv() {  # sets PYTHON_BIN
  local venv="$KICKOFF_LIB_REPO_DIR/scripts/.venv"
  if [ ! -f "$venv/bin/python3" ]; then
    log "Creating Python venv and installing deps (one-time)..."
    python3 -m venv "$venv"
    "$venv/bin/pip" install -q httpx feedparser beautifulsoup4 pyyaml
  fi
  PYTHON_BIN="$venv/bin/python3"
}

# Never log from here — callers capture stdout.
render_placeholders() {
  local text="$1" var
  # With no TPL_ vars set this would silently return the text unrendered, and
  # the symptom surfaces later as a misleading prompt/output mismatch.
  if [ -z "${TPL_DATE:-}" ]; then
    echo "ERROR: render_placeholders called before set_tpl_vars" >&2
    return 1
  fi
  for var in ${!TPL_@}; do
    text="${text//\{\{${var#TPL_}\}\}/${!var}}"
  done
  printf '%s' "$text"
}

PLACEHOLDER_RE='\{\{[A-Z_0-9]+\}\}|(^|[^A-Za-z_])TODAY([^A-Za-z_]|$)'

assert_no_placeholders() {  # TEXT LABEL
  if printf '%s' "$1" | grep -qE "$PLACEHOLDER_RE"; then
    log "ERROR: ${JOB_LABEL:+[$JOB_LABEL] }unsubstituted placeholder in $2:"
    printf '%s' "$1" | grep -nE "$PLACEHOLDER_RE" | tee -a "$LOG_FILE"
    return 1
  fi
}

# Invalid output left in place would be committed by the orchestrator's
# `git add -A` and would then block the job forever via the idempotency guard.
quarantine_output() {
  [ -e "$1" ] || return 0
  local dest
  dest="$(dirname "$LOG_FILE")/invalid-$(basename "$(dirname "$1")")-$(basename "$1")"
  mv -f "$1" "$dest"
  log "       moved invalid output to $dest"
}

validate_frontmatter() {
  ensure_venv
  local problems
  if ! problems=$("$PYTHON_BIN" - "$1" <<'PY' 2>&1
import os, sys, yaml

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().split("\n")
if lines[0].strip() != "---":
    sys.exit("no opening frontmatter delimiter")
end = None
for i, line in enumerate(lines[1:], 1):
    if line.strip() == "---":
        end = i
        break
if end is None:
    sys.exit("unterminated frontmatter")
try:
    fm = yaml.safe_load("\n".join(lines[1:end])) or {}
except yaml.YAMLError as exc:
    sys.exit("frontmatter is not valid YAML: %s" % exc)
if not isinstance(fm, dict):
    sys.exit("frontmatter is not a mapping")

problems = []
for key in ("title", "date", "theme", "format", "tldr", "itemCount", "readTimeMinutes"):
    if fm.get(key) in (None, "", []):
        problems.append("missing required field: %s" % key)
for key in ("itemCount", "readTimeMinutes"):
    val = fm.get(key)
    if val is not None and (isinstance(val, bool) or not isinstance(val, (int, float))):
        problems.append("%s must be a number, got %r" % (key, val))
if fm.get("format") not in (None, "daily", "weekly-synthesis"):
    problems.append("format must be daily or weekly-synthesis, got %r" % fm["format"])
# Mirrors the enum in src/content.config.ts — a value outside it fails the
# Astro build, which the nightly job cannot see.
if fm.get("theme") not in (None, "ai", "leadership", "rva-events", "tech"):
    problems.append("theme %r is not a declared collection" % fm.get("theme"))
if fm.get("title") is not None and not isinstance(fm["title"], str):
    problems.append("title must be a string, got %r" % (fm["title"],))
expected_theme = os.path.basename(os.path.dirname(os.path.abspath(path)))
if fm.get("theme") not in (None, expected_theme):
    problems.append("theme %r does not match directory %r" % (fm["theme"], expected_theme))
if problems:
    sys.exit("; ".join(problems))
PY
  ); then
    log "ERROR: ${JOB_LABEL:+[$JOB_LABEL] }frontmatter fails the content schema: $1"
    log "       $problems"
    return 1
  fi
}

# The claude CLI exits 0 whether or not it wrote anything.
verify_output() {
  local label="${JOB_LABEL:+[$JOB_LABEL] }"
  if [ ! -s "$1" ]; then
    log "ERROR: ${label}Claude exited 0 but $1 is missing or empty."
    quarantine_output "$1"
    return 1
  fi
  if ! head -1 "$1" | grep -q '^---'; then
    log "ERROR: ${label}$1 has no frontmatter — likely truncated."
    quarantine_output "$1"
    return 1
  fi
  if ! validate_frontmatter "$1"; then
    quarantine_output "$1"
    return 1
  fi
}

run_llm_job() {
  local prompt_file="$1" bundle_file="$2" output_file="$3" model="${4:-claude-sonnet-5}"
  local label="${JOB_LABEL:+[$JOB_LABEL] }"

  [ -f "$prompt_file" ] || { log "ERROR: ${label}prompt file not found: $prompt_file"; return 1; }
  [ -f "$bundle_file" ] || { log "ERROR: ${label}bundle file not found: $bundle_file"; return 1; }

  export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
  local claude_bin
  claude_bin=$(command -v claude 2>/dev/null || true)
  if [ -z "$claude_bin" ]; then
    log "ERROR: claude CLI not found on PATH."
    return 1
  fi

  local prompt_text
  prompt_text="$(render_placeholders "$(cat "$prompt_file")")"
  # Checked before the bundle is appended: scraped text may contain "TODAY".
  assert_no_placeholders "$prompt_text" "$prompt_file" || return 1

  log "${label}Synthesizing with Claude ($claude_bin) → $output_file ..."

  local full_prompt="$prompt_text

---
# FETCHED SOURCE CONTENT

$(cat "$bundle_file")"

  # Verification must run even when claude exits non-zero: a refusal or a
  # truncated stream can still leave a partial file behind, and an unverified
  # file gets committed and then blocks the job forever via the -s guard.
  set +e
  "$claude_bin" \
    --dangerously-skip-permissions \
    --print \
    --model "$model" \
    "$full_prompt" \
    2>&1 | tee -a "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
  set -e

  if [ "$rc" -ne 0 ]; then
    log "${label}claude exited $rc"
    # Anything written during a failed run is unreviewed and would be swept up
    # by the orchestrator's `git add -A`. Quarantine unconditionally.
    quarantine_output "$output_file"
    return 1
  fi

  verify_output "$output_file" || return 1
  log "${label}Wrote $(wc -c < "$output_file" | tr -d ' ') bytes to $output_file"
}
