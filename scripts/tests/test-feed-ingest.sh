#!/bin/bash
# S5.0 — the nightly wiring: fetch produces a sidecar, the sidecar becomes pool
# state, and the state gets committed.
#
# test-feed-pool.sh already proves the pool logic. This file proves the parts
# that live outside it and would otherwise be exercised for the first time at
# 06:00:
#
#   1. the sidecar path is defined once and reached by placeholder, so the path
#      the producer writes and the path the ingest reads cannot drift;
#   2. ingest_feed_records fails CLOSED on a missing sidecar and on an
#      unreadable blocklist — the pool is committed to a public repo;
#   3. `ingest:` is a closed vocabulary and is refused outside `step: fetch`;
#   4. a stored-bundle replay does NOT ingest, because its sidecar belongs to
#      another date and would restart the staleness clock;
#   5. run-jobs.sh commits exactly the path run-job.sh wrote, gated on its own
#      blocklist scan.
#
# No network, no LLM, no writes outside $TMPDIR, no git writes anywhere.
#
#   bash scripts/tests/test-feed-ingest.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_DIR/scripts/lib/job-config.sh"
PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
COUNT=0
ok()  { COUNT=$((COUNT + 1)); printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad() { COUNT=$((COUNT + 1)); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=1; }
chk() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (exit $2, wanted $3)"; }

# A scratch blocklist, so the real one in the private studio is never read here
# and its contents never reach this repo's test output.
printf '# scratch\nBlockedCorp\n' > "$TMP/blocklist.txt"

records() {  # FILE — three qualifying records, one of them blocked
  cat > "$1" <<'JSON'
{"id":"aaaaaaaaaaaa","source":"S1","title":"A perfectly ordinary headline about things","url":"https://example.com/a","date":"2026-08-08","summary":"This summary is comfortably longer than the eighty character floor the pool applies to everything."}
{"id":"bbbbbbbbbbbb","source":"S2","title":"A second headline that is also long enough","url":"https://example.com/b","date":"2026-08-08","summary":"Another summary that clears the eighty character floor without any trouble at all whatsoever."}
{"id":"cccccccccccc","source":"S3","title":"A headline naming BlockedCorp in passing","url":"https://example.com/c","date":"2026-08-08","summary":"BlockedCorp appears here, so this record must never reach a pool that gets committed publicly."}
JSON
}

echo "── the sidecar path is defined once ──────────────────────────────────────"
# The producer must reach the path by placeholder. A hard-coded scripts/logs/...
# in the config would be a second copy of a path the ingest step derives, and
# the two agreeing today says nothing about tomorrow.
FEED="$(KICKOFF_LIB_REPO_DIR="$REPO_DIR"; . "$REPO_DIR/scripts/lib/job-config.sh" >/dev/null 2>&1; find_job_config feed)"
if grep -qF -- '--records {{RECORDS}}' "$FEED"; then
  ok "feed.yaml reaches the sidecar as {{RECORDS}}"
else
  bad "feed.yaml does not use {{RECORDS}} — the path is spelled out twice"
fi
if grep -qE '^\s*producer:.*records-\{\{DATE\}\}' "$FEED"; then
  bad "feed.yaml still hard-codes the sidecar path in producer:"
else
  ok "feed.yaml no longer hard-codes the sidecar path"
fi
if grep -qE '^TPL_RECORDS=' "$REPO_DIR/scripts/run-job.sh"; then
  ok "run-job.sh defines TPL_RECORDS"
else
  bad "run-job.sh does not define TPL_RECORDS — {{RECORDS}} would not render"
fi
# It must be set before the producer is rendered, or {{RECORDS}} survives into
# the command line and assert_no_placeholders kills the job.
tpl_line="$(grep -n '^TPL_RECORDS=' "$REPO_DIR/scripts/run-job.sh" | head -1 | cut -d: -f1)"
rnd_line="$(grep -n '^PRODUCER="\$(render_placeholders' "$REPO_DIR/scripts/run-job.sh" | head -1 | cut -d: -f1)"
if [ -n "$tpl_line" ] && [ -n "$rnd_line" ] && [ "$tpl_line" -lt "$rnd_line" ]; then
  ok "TPL_RECORDS is set before the producer is rendered (line $tpl_line before $rnd_line)"
else
  bad "TPL_RECORDS is not set before render_placeholders — {{RECORDS}} would leak through"
fi

echo "── the state path is a constant, not a config field ──────────────────────"
# A config that could name its own directory could aim a nightly writer anywhere
# in a public repo, and run-jobs.sh would be committing a different path than
# run-job.sh wrote.
if grep -qE '^\s*ingest:.*/' "$FEED"; then
  bad "feed.yaml's ingest: names a path — it must name a mode only"
else
  ok "feed.yaml's ingest: names a mode, not a directory"
fi
state_rel="$( . "$LIB" >/dev/null 2>&1; echo "$FEED_STATE_REL" )"
chk "FEED_STATE_REL is defined in job-config.sh" "$([ -n "$state_rel" ] && echo 0 || echo 1)" 0
case "$state_rel" in
  scripts/logs/*) bad "the state lives under scripts/logs/, which is gitignored — it would never commit" ;;
  src/content/*)  bad "the state lives under src/content/, the published site and Phase 2 corpus" ;;
  /*)             bad "the state path is absolute — run-jobs.sh commits it as a pathspec" ;;
  *)              ok  "the state path is repo-relative and outside logs/ and src/content/ ($state_rel)" ;;
esac
if grep -qE '^\s*scripts/feed-state' "$REPO_DIR/.gitignore" 2>/dev/null; then
  bad "the state path is gitignored — S5.0 would commit nothing"
else
  ok "the state path is not gitignored"
fi
# The one that actually matters: both scripts must reach it through the same
# name. A literal in run-jobs.sh would drift the day the constant moves.
if grep -q 'FEED_STATE_REL' "$REPO_DIR/scripts/run-jobs.sh"; then
  ok "run-jobs.sh commits the path via FEED_STATE_REL"
else
  bad "run-jobs.sh does not reference FEED_STATE_REL — it commits a literal"
fi

echo "── ingest_feed_records: the happy path ───────────────────────────────────"
records "$TMP/rec.jsonl"
run_ingest() {  # DATE RECORDS STATE [BLOCKLIST]
  ( . "$LIB" >/dev/null 2>&1
    ensure_venv >/dev/null 2>&1
    LOG_FILE=""
    FEED_STATE_DIR="$3"
    KICKOFF_BLOCKLIST="${4-$TMP/blocklist.txt}"
    export KICKOFF_BLOCKLIST
    ingest_feed_records "$1" "$2" ) >/dev/null 2>&1
}

run_ingest 2026-08-08 "$TMP/rec.jsonl" "$TMP/state"
chk "an ingest over a good sidecar succeeds" $? 0
chk "pool.jsonl was created" "$([ -f "$TMP/state/pool.jsonl" ] && echo yes || echo no)" yes

pool_n="$(grep -c . "$TMP/state/pool.jsonl" 2>/dev/null || true)"
chk "two of the three records entered the pool" "${pool_n:-0}" 2
if grep -qi 'BlockedCorp' "$TMP/state/pool.jsonl"; then
  bad "a blocked term reached the pool — it would be committed to a public repo"
else
  ok "the blocked record never entered the pool"
fi
if grep -q '"first_seen"' "$TMP/state/pool.jsonl"; then
  ok "pool rows carry first_seen, which is what the staleness bound reads"
else
  bad "pool rows have no first_seen — nothing would ever expire"
fi

# Idempotent: the nightly job may be re-run, and a second ingest of the same
# sidecar must add nothing rather than duplicate every row.
run_ingest 2026-08-08 "$TMP/rec.jsonl" "$TMP/state"
pool_n2="$(grep -c . "$TMP/state/pool.jsonl" 2>/dev/null || true)"
chk "re-ingesting the same sidecar adds nothing" "${pool_n2:-0}" 2

echo "── ingest_feed_records fails closed ──────────────────────────────────────"
run_ingest 2026-08-08 "$TMP/nonexistent.jsonl" "$TMP/state2"
chk "a missing sidecar fails the job rather than ingesting nothing quietly" $? 1
chk "no state directory was created for the failed run" \
    "$([ -d "$TMP/state2" ] && echo yes || echo no)" no

run_ingest 2026-08-08 "$TMP/rec.jsonl" "$TMP/state3" "$TMP/does-not-exist.txt"
chk "an unreadable blocklist refuses to ingest" $? 1
# feed_pool.py refuses a bad blocklist too, so the exit code above passes with
# or without the shell check. This is the part only the shell check does: refuse
# before mkdir, so a machine with no studio does not accumulate empty
# feed-state directories that run-jobs.sh then tries to commit.
chk "the refusal happens before the state directory is created" \
    "$([ -d "$TMP/state3" ] && echo yes || echo no)" no

printf '# only comments\n\n' > "$TMP/empty-blocklist.txt"
run_ingest 2026-08-08 "$TMP/rec.jsonl" "$TMP/state4" "$TMP/empty-blocklist.txt"
chk "a blocklist with no terms refuses to ingest" $? 1
# An empty term list passes every string in the world and looks exactly like
# success. If it had been accepted, the blocked record would be in the pool.
if [ -f "$TMP/state4/pool.jsonl" ] && grep -qi 'BlockedCorp' "$TMP/state4/pool.jsonl"; then
  bad "an empty blocklist admitted the blocked record"
else
  ok "an empty blocklist admitted nothing at all"
fi

echo "── the ingest vocabulary is closed ───────────────────────────────────────"
RJ="$REPO_DIR/scripts/run-job.sh"
grep -q "unknown ingest" "$RJ" \
  && ok "run-job.sh refuses an unrecognised ingest: value" \
  || bad "run-job.sh accepts any ingest: value"
grep -q 'ingest: is only meaningful on step: fetch' "$RJ" \
  && ok "run-job.sh refuses ingest: on a non-fetch step" \
  || bad "run-job.sh allows ingest: on an llm job"
# Refusing by default is the point: an unrecognised word must not read as
# "no ingestion" and silently stop filling the pool.
if grep -qE '^\s*\*\)\s*log "ERROR: \[\$JOB\] unknown ingest' "$RJ"; then
  ok "the default branch of the ingest case refuses"
else
  bad "the ingest case has no refusing default"
fi

echo "── a stored-bundle replay does not touch the pool ────────────────────────"
# Executed, not grepped. `grep -q 'skipping ingest'` passes even when the branch
# condition is replaced with `if false` — the log line is still in the file. The
# decision lives in ingest_applies precisely so it can be run.
applies() { ( . "$LIB" >/dev/null 2>&1; BUNDLE_FILE="${1-}"; ingest_applies ) >/dev/null 2>&1; }
applies;                      chk "a real fetch ingests"                      $? 0
applies "$TMP/stored.txt";    chk "a BUNDLE_FILE replay does not ingest"      $? 1
applies "";                   chk "an empty BUNDLE_FILE is not a replay"      $? 0
grep -q 'if ingest_applies; then' "$RJ" \
  && ok "run-job.sh gates the ingest on ingest_applies" \
  || bad "run-job.sh decides in-line — the tested function is not the one that runs"
# Skipping silently would be its own trap — the operator needs to know the pool
# did not move, and how to move it by hand.
grep -q 'feed_pool.py ingest --records' "$RJ" \
  && ok "the skip says how to ingest the sidecar by hand" \
  || bad "the skip is silent about the manual path"

echo "── run-jobs.sh commits the state, gated ──────────────────────────────────"
RJS="$REPO_DIR/scripts/run-jobs.sh"
grep -q 'assert_no_blocked_tree "the feed pool"' "$RJS" \
  && ok "the feed state is blocklist-scanned before it is committed" \
  || bad "the feed state is committed without a blocklist scan"
grep -qE 'commit_and_push "\$REPO_DIR" "\$FEED_STATE_REL/"' "$RJS" \
  && ok "the commit is path-scoped to the feed state" \
  || bad "the feed state commit is not path-scoped"
# Scoping is a confidentiality property here, not tidiness: the digests and the
# pool are separate subject matter and a crossed pathspec publishes one under
# the other's message.
if grep -qE 'commit_and_push "\$REPO_DIR" "src/content/".*feed' "$RJS"; then
  bad "the digest commit pathspec was widened to include feed state"
else
  ok "the digest commit is still scoped to src/content/ alone"
fi
# The scan must precede the commit, or it is reporting on something already sent.
scan_line="$(grep -n 'assert_no_blocked_tree "the feed pool"' "$RJS" | head -1 | cut -d: -f1)"
cmt_line="$(grep -n 'FEED_STATE_REL/" "feed: pool' "$RJS" | head -1 | cut -d: -f1)"
if [ -n "$scan_line" ] && [ -n "$cmt_line" ] && [ "$scan_line" -lt "$cmt_line" ]; then
  ok "the scan runs before the commit (line $scan_line before $cmt_line)"
else
  bad "the feed-state scan does not precede its commit"
fi
# A failed scan or push has to reach FAILED_JOBS, or the run exits 0 and the
# marker file is cleared — the 13-night shape, where local files look right.
grep -q 'FAILED_JOBS="\$FAILED_JOBS feed-blocklist"' "$RJS" \
  && ok "a blocked pool marks the run failed" \
  || bad "a blocked pool would not fail the run"
grep -q 'FAILED_JOBS="\$FAILED_JOBS feed-\$COMMIT_PUSH_FAIL"' "$RJS" \
  && ok "a failed feed-state push marks the run failed" \
  || bad "a failed feed-state push would exit 0"

echo "── doctor reports the pool ───────────────────────────────────────────────"
K="$REPO_DIR/scripts/studio/kickoff"
grep -q 'doctor_feed_pool' "$K" \
  && ok "kickoff doctor reports the pool" \
  || bad "nothing reports the pool — selection is Epic 6, so nothing else reads it"
grep -q 'FEED_POOL_STALE_DAYS' "$K" \
  && ok "doctor fails when the pool stops filling" \
  || bad "doctor reports the pool but not its staleness"

echo
if [ "$FAIL" -eq 0 ]; then
  printf "\033[32mPASS\033[0m (%d) — feed ingest wiring tests passed\n" "$COUNT"
else
  printf "\033[31mFAIL\033[0m — feed ingest wiring tests FAILED (%d assertions run)\n" "$COUNT"
fi
exit "$FAIL"
