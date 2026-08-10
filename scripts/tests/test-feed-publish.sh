#!/bin/bash
# E4 remainder + E10 — the runner can express a feed job, and the nightly can
# publish one.
#
# Everything here is a guard, and a guard is worth exactly what it refuses. The
# properties under test, in order of what they cost when wrong:
#
#   the feed site cannot resolve inside the engine repo   an edition committed
#                                                         and pushed to a PUBLIC
#                                                         repo
#   a feed job cannot write outside the editions dir      a nightly writer aimed
#                                                         at the site's own code
#   a push is only a success if the remote ref moved      the 13-night shape
#   a transform that writes nothing fails                 the claude-CLI shape:
#                                                         exit 0, no file
#   only transient failures retry                         a refusal retried in a
#                                                         loop, on a bill
#   job order is declared, not alphabetical               an edition built from
#                                                         yesterday's pool
#
# No network, no LLM, no writes outside $TMPDIR, no git writes to a real repo.
#
#   bash scripts/tests/test-feed-publish.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

FAIL=0
COUNT=0
ok()  { COUNT=$((COUNT+1)); printf "  \033[32mok\033[0m    %s\n" "$1"; }
bad() { COUNT=$((COUNT+1)); FAIL=1; printf "  \033[31mFAIL\033[0m  %s\n" "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }

TMP="$(mktemp -d -t feedpub)"
trap 'rm -rf "$TMP"' EXIT

# Sourced with a scratch repo root so nothing here can touch the real one.
export KICKOFF_LIB_REPO_DIR="$REPO_DIR"
LOG_FILE="$TMP/log"
. "$REPO_DIR/scripts/lib/job-config.sh"

echo "── job names, discovery and declared order ───────────────────────────────"

chk "a numeric prefix is not part of the job name" "$(job_name_of /x/scripts/feed/20-edition.yaml)" "edition"
# The pool job keeps the name `feed` across the move into its own kind, because
# feed_gate.py globs records-*-feed.jsonl and a rename would orphan the soak
# measurement rather than fail.
chk "10-feed.yaml is still the job named 'feed'" "$(job_name_of /x/scripts/feed/10-feed.yaml)" "feed"
chk "an unprefixed config is unaffected" "$(job_name_of /x/scripts/topics/ai.yaml)" "ai"
chk "a name that merely starts with digits is not a prefix" "$(job_name_of /x/scripts/topics/2026-review.yaml)" "2026-review"

chk "find_job_config reaches the new kind" \
  "$(basename "$(find_job_config edition)")" "20-edition.yaml"
chk "...and still finds a topic" "$(basename "$(find_job_config ai)")" "ai.yaml"
chk "an unknown job is not found" "$(find_job_config nosuchjob >/dev/null 2>&1; echo $?)" "1"

# The ordering that matters: the pool must fill before the edition reads it.
ORDER="$(job_config_files | sed 's|.*/scripts/||' | tr '\n' ' ')"
case "$ORDER" in
  *"feed/10-feed.yaml feed/20-edition.yaml"*) ok "the pool fetch is ordered before the edition" ;;
  *) bad "run order puts the edition before the pool: $ORDER" ;;
esac
case "$ORDER" in
  topics/*) ok "topics run first" ;;
  *) bad "topics do not run first: $ORDER" ;;
esac

chk "the live tree has unambiguous job order" "$(assert_job_order >/dev/null 2>&1; echo $?)" "0"

# A directory mixing prefixed and unprefixed configs sorts unpredictably, which
# is the incidental ordering the prefixes exist to end.
MIXDIR="$TMP/mixrepo"
mkdir -p "$MIXDIR/scripts/feed"
: > "$MIXDIR/scripts/feed/10-first.yaml"
: > "$MIXDIR/scripts/feed/later.yaml"
chk "a directory mixing ordered and unordered configs is refused" \
  "$(KICKOFF_LIB_REPO_DIR="$MIXDIR" assert_job_order >/dev/null 2>&1; echo $?)" "1"
rm "$MIXDIR/scripts/feed/later.yaml"
chk "...and is accepted once every config is prefixed" \
  "$(KICKOFF_LIB_REPO_DIR="$MIXDIR" assert_job_order >/dev/null 2>&1; echo $?)" "0"

echo "── the feed site must not resolve inside the engine repo (S4.6) ──────────"

# The catastrophe this prevents: `git -C <subdir>` walks up to the nearest
# repository, so a feed dir inside this checkout means the edition is committed
# to the PUBLIC engine repo and pushed.
chk "a path inside the engine repo is refused" \
  "$(assert_feed_site_outside_engine "$REPO_DIR/src" >/dev/null 2>&1; echo $?)" "1"
chk "the engine repo root itself is refused" \
  "$(assert_feed_site_outside_engine "$REPO_DIR" >/dev/null 2>&1; echo $?)" "1"

REALFEED="$(resolve_feed_site_dir)"
if [ -d "$REALFEED/.git" ]; then
  chk "the real feed checkout is accepted" \
    "$(assert_feed_site_outside_engine "$REALFEED" >/dev/null 2>&1; echo $?)" "0"
else
  ok "(skipped: no feed checkout at $REALFEED)"
fi

# A separate git repo elsewhere is fine.
OTHER="$TMP/other"; mkdir -p "$OTHER"; git -C "$OTHER" init -q 2>/dev/null
chk "an unrelated git repo is accepted" \
  "$(assert_feed_site_outside_engine "$OTHER" >/dev/null 2>&1; echo $?)" "0"

# Layout, so a FEED_SITE_DIR pointed at the wrong clone is caught before an
# edition is written into it and pushed to whatever remote that clone has.
EMPTY="$TMP/emptyclone"; mkdir -p "$EMPTY"
chk "a checkout missing the feed layout is refused" \
  "$(require_feed_site_dir "$EMPTY" >/dev/null 2>&1; echo $?)" "1"
chk "a nonexistent directory is refused" \
  "$(require_feed_site_dir "$TMP/nope" >/dev/null 2>&1; echo $?)" "1"

echo "── the output boundary for the new kind ──────────────────────────────────"

export FEED_SITE_DIR="$TMP/feedsite"
mkdir -p "$FEED_SITE_DIR/src/content/editions"
BND() { assert_output_boundary "$@" >/dev/null 2>&1; echo $?; }

chk "an edition inside the editions directory is allowed" \
  "$(BND feed "$FEED_SITE_DIR/src/content/editions/2026-08-10.json")" "0"
# Narrower than the repo on purpose: a feed job has no business editing the
# site's pages, its checks or its config.
chk "the feed site's own source is out of bounds" \
  "$(BND feed "$FEED_SITE_DIR/src/pages/index.astro")" "1"
chk "the feed site's build scripts are out of bounds" \
  "$(BND feed "$FEED_SITE_DIR/scripts/check-feed.mjs")" "1"
chk "the engine repo is out of bounds for a feed job" \
  "$(BND feed "$REPO_DIR/src/content/ai/2026-08-10.md")" "1"
chk "a .. segment is refused rather than normalised" \
  "$(BND feed "$FEED_SITE_DIR/src/content/editions/../../../pages/x.astro")" "1"
chk "an unknown kind is still refused" "$(BND feeds "/anywhere/at/all.json")" "1"
unset FEED_SITE_DIR

echo "── step: transform, config shape ─────────────────────────────────────────"

. "$REPO_DIR/scripts/lib/run-llm-job.sh"
chk "transform is a known step" "$(is_known_step transform; echo $?)" "0"
chk "fetch is still a known step"  "$(is_known_step fetch; echo $?)" "0"
chk "an invented step is refused"  "$(is_known_step publish; echo $?)" "1"

RUNJOB() {  # CONFIG_BODY -> exit code of run-job.sh against it
  local sandbox="$TMP/rj$RANDOM"
  mkdir -p "$sandbox/scripts/feed" "$sandbox/scripts/logs" "$sandbox/scripts/lib"
  cp "$REPO_DIR"/scripts/lib/*.sh "$sandbox/scripts/lib/"
  cp "$REPO_DIR/scripts/run-job.sh" "$sandbox/scripts/"
  printf '%s\n' "$1" > "$sandbox/scripts/feed/50-probe.yaml"
  (cd "$sandbox" && DIGEST_DATE=2026-08-10 bash scripts/run-job.sh probe) >/dev/null 2>&1
  echo $?
}

chk "a transform declaring a prompt is refused" "$(RUNJOB \
'name: probe
schedule: daily
step: transform
producer: x.py
prompt: scripts/prompts/x.md
output: "/tmp/x.json"')" "1"

chk "a transform declaring no output is refused" "$(RUNJOB \
'name: probe
schedule: daily
step: transform
producer: x.py')" "1"

echo "── a transform that writes nothing is a failure (S10.1) ──────────────────"

# The claude CLI exits 0 whether or not it wrote a file, and so does a Python
# producer that took an early return. Exit code is not evidence of an artifact.
SB="$TMP/tsb"
mkdir -p "$SB/scripts/feed" "$SB/scripts/logs" "$SB/scripts/lib" "$SB/out"
cp "$REPO_DIR"/scripts/lib/*.sh "$SB/scripts/lib/"
cp "$REPO_DIR/scripts/run-job.sh" "$SB/scripts/"
cat > "$SB/scripts/liar.py" <<'PY'
import sys
print("did lots of important work")
sys.exit(0)
PY
cat > "$SB/scripts/honest.py" <<'PY'
import sys
out = sys.argv[sys.argv.index("--out") + 1]
open(out, "w").write('{"ok": true}\n')
PY
mkcfg() { printf 'name: probe\nschedule: daily\nstep: transform\nproducer: %s\noutput: "%s"\n' "$1" "$2" \
  > "$SB/scripts/feed/50-probe.yaml"; }

# The boundary applies to a probe job of kind `feed`, so point FEED_SITE_DIR at
# the sandbox and write where the boundary permits.
export FEED_SITE_DIR="$SB/feedsite"
mkdir -p "$FEED_SITE_DIR/src/content/editions" "$FEED_SITE_DIR/scripts"
: > "$FEED_SITE_DIR/package.json"
git -C "$FEED_SITE_DIR" init -q 2>/dev/null

mkcfg "liar.py --out {{OUTPUT}}" '{{FEED_SITE}}/src/content/editions/{{DATE}}.json'
chk "a producer that exits 0 without writing FAILS" \
  "$( (cd "$SB" && DIGEST_DATE=2026-08-10 bash scripts/run-job.sh probe) >/dev/null 2>&1; echo $?)" "1"

mkcfg "honest.py --out {{OUTPUT}}" '{{FEED_SITE}}/src/content/editions/{{DATE}}.json'
chk "a producer that writes its output succeeds" \
  "$( (cd "$SB" && DIGEST_DATE=2026-08-10 bash scripts/run-job.sh probe) >/dev/null 2>&1; echo $?)" "0"
chk "...and the file is where the config said" \
  "$([ -s "$FEED_SITE_DIR/src/content/editions/2026-08-10.json" ] && echo yes || echo no)" "yes"

# {{OUTPUT}} exists only for this step, and it must be the resolved path.
chk "the producer received the resolved output path" \
  "$(cat "$FEED_SITE_DIR/src/content/editions/2026-08-10.json")" '{"ok": true}'
unset FEED_SITE_DIR

echo "── retry only what is transient (S10.8) ──────────────────────────────────"

T() { printf '%s' "$1" > "$TMP/callout"; is_transient_failure "$TMP/callout"; echo $?; }
chk "an idle timeout is transient"       "$(T 'Error: idle timeout after 120s')" "0"
chk "a connection refused is transient"  "$(T 'connect ECONNREFUSED 127.0.0.1:443')" "0"
chk "a 503 is transient"                 "$(T 'Service Unavailable')" "0"
chk "an overloaded error is transient"   "$(T '{"type":"overloaded_error"}')" "0"
# The one that must never retry. Retrying a refusal buys the same answer twice.
chk "a policy refusal is NOT transient"  "$(T "I can't help with creating exploit code.")" "1"
chk "a validation error is NOT transient" "$(T 'invalid model name')" "1"
chk "unrecognised output is NOT transient" "$(T 'something nobody has seen before')" "1"
chk "empty output is NOT transient"      "$(T '')" "1"

echo "── the toolchain is checked, not discovered (S10.7) ──────────────────────"

NOMODULES="$TMP/nomodules"; mkdir -p "$NOMODULES"
chk "a feed site with no node_modules is refused" \
  "$(assert_feed_toolchain "$NOMODULES" >/dev/null 2>&1; echo $?)" "1"
mkdir -p "$NOMODULES/node_modules"
chk "...and accepted once dependencies are installed" \
  "$(assert_feed_toolchain "$NOMODULES" >/dev/null 2>&1; echo $?)" "0"

echo "── PATH is available to every step, not only the model one (S4.7) ────────"

( PATH=/usr/bin:/bin; ensure_tool_path
  case ":$PATH:" in *":/opt/homebrew/bin:"*) exit 0 ;; *) exit 1 ;; esac )
chk "ensure_tool_path widens a minimal launchd PATH" "$?" "0"
BEFORE="$PATH"; ensure_tool_path; ensure_tool_path
chk "it is idempotent" "$PATH" "$(printf '%s' "$BEFORE")"

echo "── the nightly's phase order (S10.4, S10.5) ─────────────────────────────"

# run-jobs.sh is never executed here — it commits and pushes to public repos.
# Same approach as test-blocklist.sh: assert on the source, by line order,
# because ordering is the property and the script cannot be run to observe it.
RJ="$REPO_DIR/scripts/run-jobs.sh"
line_of() { grep -n -- "$1" "$RJ" | head -1 | cut -d: -f1; }

L_MAIN="$(line_of 'run_configs "${PHASE_MAIN\[@\]}"')"
L_DIGEST="$(line_of 'commit_and_push "$REPO_DIR" "src/content/"')"
L_FEED="$(line_of 'run_configs "${PHASE_FEED\[@\]}"')"
L_PUBLISH="$(line_of 'publish_feed_site "$FEED_SITE_DIR"')"

if [ -z "$L_MAIN" ] || [ -z "$L_DIGEST" ] || [ -z "$L_FEED" ] || [ -z "$L_PUBLISH" ]; then
  bad "could not locate the four phase markers in run-jobs.sh — this assertion needs updating"
else
  # The whole reason the loop was split: by the time a feed job runs, the
  # digests are already committed and pushed, so a feed failure cannot cost
  # the night its digests.
  if [ "$L_MAIN" -lt "$L_DIGEST" ] && [ "$L_DIGEST" -lt "$L_FEED" ]; then
    ok "the digest commit sits between phase 1 and the feed jobs (S10.5)"
  else
    bad "phase order is wrong: main=$L_MAIN digest=$L_DIGEST feed=$L_FEED"
  fi
  if [ "$L_FEED" -lt "$L_PUBLISH" ]; then
    ok "the edition is generated before the site is published"
  else
    bad "publish_feed_site runs before the feed jobs: feed=$L_FEED publish=$L_PUBLISH"
  fi
fi

# The verification chain must precede the commit inside publish_feed_site, for
# the same reason the blocklist does: a quarantined edition is recoverable and
# a pushed one is not.
JC="$REPO_DIR/scripts/lib/job-config.sh"
V="$(grep -n 'npm run verify' "$JC" | head -1 | cut -d: -f1)"
B="$(grep -n 'assert_no_blocked_tree "the built feed site"' "$JC" | head -1 | cut -d: -f1)"
C="$(grep -n 'commit_and_push "$dir" "src/content/editions/"' "$JC" | head -1 | cut -d: -f1)"
if [ -n "$V" ] && [ -n "$B" ] && [ -n "$C" ] && [ "$V" -lt "$B" ] && [ "$B" -lt "$C" ]; then
  ok "verify, then scan the built output, then commit (S10.1, S10.6)"
else
  bad "publish_feed_site order is wrong: verify=$V blocklist=$B commit=$C"
fi

# S10.2 / invariant 3. A push that exits 0 is the client's opinion; the ref is
# the fact.
if grep -q 'ls-remote origin "refs/heads/\$expected"' "$JC"; then
  ok "a push is confirmed against the remote ref, not its exit code (S10.2)"
else
  bad "commit_and_push does not read the remote ref back after pushing"
fi

echo
if [ "$FAIL" = 0 ]; then
  printf "\033[32mPASS\033[0m (%s) — feed publish tests passed\n" "$COUNT"
else
  printf "\033[31mFAIL\033[0m — feed publish tests FAILED (%s assertions run)\n" "$COUNT"
fi
exit $FAIL
