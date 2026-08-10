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

# Ordering is declared before anything runs, so a half-applied numeric prefix
# is a refusal rather than a job silently executing in the wrong place.
assert_job_order || { log "ERROR: refusing to run with ambiguous job order."; exit 1; }

# TWO PHASES, and the split is the point (S10.4, S10.5).
#
# Phase 1 is the private digest and the studio generators. Phase 2 is the public
# feed. The digest commit sits between them, so a feed job that fails — a model
# refusal, a missing feed checkout, a site that will not build — cannot cost the
# night its digests, because they are already committed by the time it runs. The
# reverse holds too: phase 2 runs whether or not phase 1 succeeded.
#
# Before this, both lived in one loop and the ordering was whichever way the
# directory globs happened to fall.
PHASE_MAIN=(); PHASE_FEED=()
while IFS= read -r config; do
  case "$(basename "$(dirname "$config")")" in
    feed) PHASE_FEED+=("$config") ;;
    *)    PHASE_MAIN+=("$config") ;;
  esac
done < <(job_config_files)

run_configs() {  # CONFIG... — updates COMMITTED and FAILED_JOBS in place
  local config JOB JOB_KIND SCHEDULE OUTPUT_TPL STEP OUTPUT_FILE SCHEDULED
  for config in "$@"; do
  [ -f "$config" ] || continue
  JOB="$(job_name_of "$config")"
  JOB_KIND="$(basename "$(dirname "$config")")"
  # A malformed config must fail its own job, not abort the whole run before
  # the commit and push gates. `||` suspends set -e for the assignment.
  SCHEDULE="$(cfg_get "$config" schedule daily)" \
    || { log "ERROR: $JOB: unreadable config $config"; FAILED_JOBS="$FAILED_JOBS $JOB"; continue; }
  OUTPUT_TPL="$(cfg_get "$config" output)" \
    || { log "ERROR: $JOB: unreadable config $config"; FAILED_JOBS="$FAILED_JOBS $JOB"; continue; }
  STEP="$(cfg_get "$config" step llm)" \
    || { log "ERROR: $JOB: unreadable config $config"; FAILED_JOBS="$FAILED_JOBS $JOB"; continue; }
  [ -n "$STEP" ] || STEP="llm"

  # A fetch job declares no output, so these have nothing to check. Everything
  # that follows — the schedule gate above all — still applies to it.
  if [ "$STEP" != "fetch" ]; then
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

  # A fetch job writes no output file, so there is nothing to skip on and no
  # LLM call to make idempotent. Accumulating a bundle every scheduled day is
  # the whole point of the step, so it runs unconditionally once scheduled.
  if [ "$STEP" = "fetch" ]; then
    log "--- Running job: $JOB (step: fetch) ---"
    (DIGEST_DATE="$DATE" bash "$REPO_DIR/scripts/run-job.sh" "$JOB") \
      || { log "WARN: $JOB failed"; FAILED_JOBS="$FAILED_JOBS $JOB"; }
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
}

# Phase 1 — digests and generators. `set -u` makes an empty array an error in
# the bash macOS ships, so both calls are guarded rather than splatted blind.
# An `if`, not `&&`: a false test as a bare command list is a non-zero exit,
# which under `set -e` would end the run on the day a phase happens to be empty.
if [ ${#PHASE_MAIN[@]} -gt 0 ]; then run_configs "${PHASE_MAIN[@]}"; fi

# Single commit for all successfully generated content. All the guards — branch,
# porcelain-not-diff, push split from commit with retry — live in
# commit_and_push, shared with the studio repo so there is only one copy.
# The blocklist gate. This repo is public, and this is the last moment before
# tonight's content leaves the machine.
#
# Placed before the commit rather than after generation, because a quarantined
# digest is recoverable and a pushed one is not: history can be rewritten over,
# never actually recalled. Everything else this orchestrator does can be retried
# tomorrow. This cannot.
#
# Fails CLOSED, including when the list itself cannot be read. The list lives in
# the private studio, so a machine without a studio cannot publish. That is the
# intended trade — with no list there is no way to know the content is clean, and
# "publish anyway" is the answer that makes the whole guard decorative.
#
# Scoped to src/content/ only. The studio commit below is deliberately not gated:
# the studio is private, and its notes legitimately carry the terms this list
# exists to keep out of *this* repo.
if ! assert_no_blocked_tree "tonight's content" "$REPO_DIR/src/content"; then
  log "ERROR: refusing to commit or push. The generated files are on disk and untouched."
  FAILED_JOBS="$FAILED_JOBS blocklist"
  CP_RC=2
else
  commit_and_push "$REPO_DIR" "src/content/" "digest: $DATE [automated]" && CP_RC=0 || CP_RC=$?
fi
case "$CP_RC" in
  0) log "Committed $COMMITTED job(s)." ;;
  2) ;;  # nothing to commit — commit_and_push already said so
  *) FAILED_JOBS="$FAILED_JOBS $COMMIT_PUSH_FAIL" ;;
esac

# The feed pool and ledger. A separate commit from the digests, deliberately:
# the two have different subject matter, and a night where the digests are
# quarantined must still be able to record what the fetch saw. Same repo, same
# branch, so this is a second commit and a second push, not a second remote.
#
# Gated on its own blocklist scan even though ingest already filters on
# admission. Two checks of one property is not redundancy here — admission is
# the only one that can keep a term out cheaply, and this one is the only one
# that sees the file as git will send it.
#
# If this ever fires it will fire every night until someone edits the file:
# the offending row is already on disk and nothing removes it. That is the
# intended shape. A gate that clears itself by dropping the thing it caught is
# not a gate.
# Phase 2 — the public feed, strictly after the digest commit (S10.5).
#
# Everything above this line is already committed and pushed, so nothing below
# can cost the night its digests. That is the whole reason the loop was split.
if [ ${#PHASE_FEED[@]} -gt 0 ]; then run_configs "${PHASE_FEED[@]}"; fi

if [ -d "$REPO_DIR/$FEED_STATE_REL" ]; then
  if ! assert_no_blocked_tree "the feed pool" "$REPO_DIR/$FEED_STATE_REL"; then
    log "ERROR: refusing to commit the feed pool. Edit $FEED_STATE_REL/pool.jsonl by hand;"
    log "       nothing else will remove the row."
    FAILED_JOBS="$FAILED_JOBS feed-blocklist"
  else
    commit_and_push "$REPO_DIR" "$FEED_STATE_REL/" "feed: pool $DATE [automated]" && FS_RC=0 || FS_RC=$?
    case "$FS_RC" in
      0) log "Committed the feed pool and ledger." ;;
      2) ;;  # nothing to commit — commit_and_push already said so
      *) FAILED_JOBS="$FAILED_JOBS feed-$COMMIT_PUSH_FAIL" ;;
    esac
  fi
fi

# The feed site — a third repo, verified and pushed (E10).
#
# Runs only if tonight's edition actually exists. A feed job that failed leaves
# no file, and there is nothing to publish; building and committing anyway
# would re-push yesterday's edition under tonight's message.
#
# An absent or non-git feed checkout is a warning, never a run failure — same
# asymmetry as the studio, and for the same reason: a machine without the clone
# must still publish digests. Everything past that gate is a real failure.
FEED_SITE_DIR="$(resolve_feed_site_dir)"
FEED_EDITION="$FEED_SITE_DIR/src/content/editions/$DATE.json"
if [ ! -d "$FEED_SITE_DIR" ]; then
  log "No feed site at $FEED_SITE_DIR — skipping the feed publish. Digests are unaffected."
elif [ ! -f "$FEED_EDITION" ]; then
  log "No edition for $DATE at $FEED_EDITION — nothing to publish."
else
  publish_feed_site "$FEED_SITE_DIR" "$DATE" && PF_RC=0 || PF_RC=$?
  case "$PF_RC" in
    0) log "Published the feed edition for $DATE." ;;
    2) ;;  # nothing to commit — commit_and_push already said so
    *) FAILED_JOBS="$FAILED_JOBS feed-site${COMMIT_PUSH_FAIL:+-$COMMIT_PUSH_FAIL}" ;;
  esac
fi

# The second commit: generated artifacts live in $STUDIO_DIR, not in this repo.
# Two path-scoped commits, never crossed — this repo is public and the studio is
# not, so the scoping is a confidentiality property, not tidiness.
#
# Scoped to angles/ because that is the only generator-owned directory in the
# studio. notes/, drafts/ and published/ are hand-edited; an "[automated]"
# commit must never claim someone else's half-written work.
#
# Unconditional, not gated on "a generator ran tonight". commit_and_push's own
# `status --porcelain` check is the gate for *committing* — a failed job leaves
# angles/ clean, because run-job.sh performs no git operations and quarantines
# invalid output into scripts/logs/, outside this pathspec. Calling it every
# night is also what retries a commit whose push failed: a generator runs one
# day in seven, and a gated call would strand those commits for a week.
#
# An absent or non-git studio is a warning, never a run failure — most nights
# there is nothing for it to do, and a machine with no studio clone must still
# publish digests. Everything past that gate (wrong branch, failed push) is a
# real publish failure and is surfaced exactly like the site repo's.
if [ ! -d "$STUDIO_DIR" ]; then
  log "No studio at $STUDIO_DIR — skipping the studio commit. Digests are unaffected."
elif ! git -C "$STUDIO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  log "WARN: $STUDIO_DIR is not a git repository — anything generated there stays unversioned."
elif [ "$(git -C "$STUDIO_DIR" rev-parse --show-toplevel 2>/dev/null || echo studio)" \
     = "$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null || echo site)" ]; then
  # `git -C <subdir>` walks up to the nearest repo, so a STUDIO_DIR misconfigured
  # to somewhere inside this checkout would commit studio content to the public
  # site repo under an "angles:" message. Refuse rather than publish.
  #
  # Both sides go through git so both are normalized: $REPO_DIR is `pwd`, which
  # on macOS keeps /var/..., while rev-parse resolves it to /private/var/... —
  # comparing the two directly silently never matches.
  log "ERROR: STUDIO_DIR ($STUDIO_DIR) resolves inside this repo — refusing to commit studio content to it."
  FAILED_JOBS="$FAILED_JOBS studio-inside-site-repo"
else
  commit_and_push "$STUDIO_DIR" "angles/" "angles: $DATE [automated]" && SP_RC=0 || SP_RC=$?
  case "$SP_RC" in
    0) log "Committed generated angles to $STUDIO_DIR." ;;
    2) ;;  # nothing to commit — commit_and_push already said so
    *) FAILED_JOBS="$FAILED_JOBS studio-$COMMIT_PUSH_FAIL" ;;
  esac
fi

# cleanup-old-digests.sh is intentionally not wired in — run it manually.

log "=== run-jobs finished $(date) ==="

# Exit non-zero so failures are visible in `launchctl list` — the dated log is
# gitignored and never leaves this machine.
if [ -n "$FAILED_JOBS" ]; then
  log "FAILED jobs:$FAILED_JOBS"
  mark_run_failed "$LOG_DIR" "$DATE failed:$FAILED_JOBS"
  notify_desktop "Daily Kickoff — $DATE failed" \
                 "Not published:$FAILED_JOBS. Run: kickoff doctor"
  exit 1
fi
clear_run_failed "$LOG_DIR"
