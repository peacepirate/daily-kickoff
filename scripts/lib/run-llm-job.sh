#!/bin/bash
# Tier 1 — the shared LLM job core. Indifferent to producer, schedule,
# destination and naming.
#
#   run_llm_job PROMPT_FILE BUNDLE_FILE OUTPUT_FILE [MODEL] [SCHEMA]
#
# Environment:
#   LOG_FILE     Required. Run log; also the quarantine directory for bad output.
#   TPL_<NAME>   Substituted into the prompt wherever {{<NAME>}} appears.
#   JOB_LABEL    Optional prefix for log lines.
#   STUDIO_DIR   Required by `schema: angles` only, to resolve `[note …]` citations.
#   KICKOFF_CLAUDE_BIN
#                Explicit path to the CLI, winning over PATH. Tests set it to a
#                stub; PATH alone is not enough, because this function extends
#                PATH itself and a bare `claude` may resolve to the real one.

KICKOFF_LIB_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Falls back to stderr rather than requiring LOG_FILE: the kickoff CLI has no
# log file, and `tee -a "$LOG_FILE"` would abort on the unbound variable under
# `set -u` — which would kill the first CLI run on a fresh clone inside
# ensure_venv, before it could report anything.
log() {
  if [ -n "${LOG_FILE:-}" ]; then echo "$*" | tee -a "$LOG_FILE"; else echo "$*" >&2; fi
}

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
  # Here-string, not a pipe: under `set -o pipefail`, `grep -q` exits on first
  # match and the writer dies of SIGPIPE (141), failing the pipeline even though
  # the match succeeded — which would make this fail-closed guard fail open.
  if grep -qE "$PLACEHOLDER_RE" <<<"$1"; then
    log "ERROR: ${JOB_LABEL:+[$JOB_LABEL] }unsubstituted placeholder in $2:"
    grep -nE "$PLACEHOLDER_RE" <<<"$1" | tee -a "$LOG_FILE"
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

# The frontmatter shapes a job config may declare. Callers validate against this
# list at config load, so an unknown word costs nothing; validate_frontmatter
# rejects it a second time because a shape with no validator must never pass
# silently.
# What a job *does*. `llm` is the original and only behaviour: produce a bundle,
# render a prompt, invoke the model, verify the file it wrote. `fetch` stops
# after the bundle — no prompt, no model, no output file — which is what a source
# pool being measured before anything is published needs, and what the runner
# previously had no way to express.
JOB_STEPS="llm fetch"

is_known_step() { case " $JOB_STEPS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

JOB_SCHEMAS="digest angles"

is_known_schema() { case " $JOB_SCHEMAS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

validate_frontmatter() {  # FILE [SCHEMA]
  case "${2:-digest}" in
    digest) validate_frontmatter_digest "$1" ;;
    angles) validate_frontmatter_angles "$1" ;;
    *)      log "ERROR: ${JOB_LABEL:+[$JOB_LABEL] }no validator for schema '${2:-digest}'"
            return 1 ;;
  esac
}

# Citations are resolved against disk here, not by the model — see
# scripts/lib/validate_angles.py.
validate_frontmatter_angles() {
  ensure_venv
  local problems
  if ! problems=$("$PYTHON_BIN" "$KICKOFF_LIB_REPO_DIR/scripts/lib/validate_angles.py" \
                    "$1" --repo-dir "$KICKOFF_LIB_REPO_DIR" 2>&1); then
    log "ERROR: ${JOB_LABEL:+[$JOB_LABEL] }output fails the angles schema: $1"
    log "       $problems"
    return 1
  fi
}

validate_frontmatter_digest() {
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
#
# Exists, non-empty, opens with `---` are checked unconditionally and are not
# pluggable: they are what turned a 13-night silent failure into a loud one, and
# a caller allowed to skip them reintroduces that bug class. Only the
# frontmatter *shape* varies by schema.
verify_output() {  # FILE [SCHEMA]
  local label="${JOB_LABEL:+[$JOB_LABEL] }"
  if [ ! -s "$1" ]; then
    log "ERROR: ${label}Claude exited 0 but $1 is missing or empty."
    quarantine_output "$1"
    return 1
  fi
  if ! grep -q '^---' <<<"$(head -1 "$1")"; then
    log "ERROR: ${label}$1 has no frontmatter — likely truncated."
    quarantine_output "$1"
    return 1
  fi
  if ! validate_frontmatter "$1" "${2:-digest}"; then
    quarantine_output "$1"
    return 1
  fi
}

run_llm_job() {
  local prompt_file="$1" bundle_file="$2" output_file="$3" model="${4:-claude-sonnet-5}"
  local schema="${5:-digest}"
  local label="${JOB_LABEL:+[$JOB_LABEL] }"

  if ! is_known_schema "$schema"; then
    log "ERROR: ${label}unknown schema '$schema' (known: $JOB_SCHEMAS)"
    return 1
  fi

  [ -f "$prompt_file" ] || { log "ERROR: ${label}prompt file not found: $prompt_file"; return 1; }
  [ -f "$bundle_file" ] || { log "ERROR: ${label}bundle file not found: $bundle_file"; return 1; }

  # Appended, never prepended. launchd runs with a minimal PATH, so the usual
  # install locations have to be added — but prepending them silently shadowed
  # anything the caller had already put on PATH, including a test's stub. Every
  # suite that thought it was stubbing `claude` was calling the real CLI: real
  # spend, real latency, and end-to-end tests that were never hermetic.
  export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$HOME/.local/bin"
  local claude_bin="${KICKOFF_CLAUDE_BIN:-}"
  [ -n "$claude_bin" ] || claude_bin=$(command -v claude 2>/dev/null || true)
  if [ -z "$claude_bin" ]; then
    log "ERROR: claude CLI not found on PATH."
    return 1
  fi
  if [ ! -x "$claude_bin" ]; then
    log "ERROR: claude CLI is not executable: $claude_bin"
    return 1
  fi

  local prompt_text
  prompt_text="$(render_placeholders "$(cat "$prompt_file")")"
  # Checked before the bundle is appended: scraped text may contain "TODAY".
  assert_no_placeholders "$prompt_text" "$prompt_file" || return 1

  # The model is named because it is now a config value: a run whose quality
  # changed must be attributable from the log alone.
  log "${label}Synthesizing with Claude ($claude_bin, model $model, schema $schema) → $output_file ..."

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

  verify_output "$output_file" "$schema" || return 1
  log "${label}Wrote $(wc -c < "$output_file" | tr -d ' ') bytes to $output_file"
}
