#!/bin/bash
# Job configuration, scheduling and path resolution — shared by run-job.sh,
# run-jobs.sh and the kickoff CLI. `topics/` and `generators/` use one schema.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-llm-job.sh"

KICKOFF_STUDIO_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/kickoff/config"

note() { if [ -n "${LOG_FILE:-}" ]; then log "$*"; else echo "$*" >&2; fi; }

resolve_studio_dir() {
  if [ -n "${STUDIO_DIR:-}" ]; then
    echo "$STUDIO_DIR"; return
  fi
  if [ -f "$KICKOFF_STUDIO_CONFIG" ]; then
    local from_config
    from_config=$(grep -E '^STUDIO_DIR=' "$KICKOFF_STUDIO_CONFIG" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"'' || true)
    if [ -n "$from_config" ]; then echo "${from_config/#\~/$HOME}"; return; fi
  fi
  echo "$(cd "$KICKOFF_LIB_REPO_DIR/../.." && pwd)/kickoff-studio"
}

# Never auto-create. An empty studio looks healthy and silently yields empty
# corpus bundles.
require_studio_dir() {
  local dir="${1:-${STUDIO_DIR:-}}"
  if [ ! -d "$dir" ]; then
    note "ERROR: STUDIO_DIR does not exist: $dir"
    note ""
    note "Fix one of:"
    note "  git clone git@github.com:peacepirate/kickoff-studio.git \"$dir\""
    note "  export STUDIO_DIR=/path/to/kickoff-studio"
    note "  echo 'STUDIO_DIR=/path/to/kickoff-studio' >> $KICKOFF_STUDIO_CONFIG"
    return 1
  fi
  local missing="" d
  for d in notes angles drafts published engagement state; do
    [ -d "$dir/$d" ] || missing="$missing $d"
  done
  if [ -n "$missing" ]; then
    note "ERROR: $dir is missing required directories:$missing"
    note "       Is this the right studio? Expected the kickoff-studio layout."
    return 1
  fi
}

# THE JOB KINDS, in the order they run. One definition; everything else derives.
#
# A kind is a directory under scripts/, and the order here is the order the
# nightly executes. That order is load-bearing rather than alphabetical
# coincidence: `feed` runs last because its edition is built from a pool the
# fetch fills, and because the digest commit is deliberately in front of it, so
# a feed failure cannot cost the night its digests (S10.4/S10.5).
#
# A closed list rather than "any directory holding yaml", matching how the tag
# vocabulary and the step list are written. Discovery would silently enrol a
# scratch directory somebody left behind, and assert_output_boundary would then
# have no boundary to apply to it.
JOB_KINDS="topics generators feed"

# `20-edition.yaml` -> `edition`.
#
# The numeric prefix orders the file and is not part of the job's name, so
# `run-job.sh edition` keeps working and — the reason this matters — the record
# sidecars stay `records-<date>-feed.jsonl`. feed_gate.py globs for exactly that
# name, so renaming the pool job would silently orphan the soak measurement
# that is currently mid-flight.
job_name_of() {  # CONFIG_PATH -> job name
  local stem; stem="$(basename "$1" .yaml)"
  printf '%s' "${stem#[0-9][0-9]-}"
}

# THE FEED SITE — a third repo, resolved the way the studio already is.
#
# Same three-step precedence as resolve_studio_dir, and the same division of
# labour: this computes a string and never validates, so it cannot fail on a
# machine that has no feed checkout. require_feed_site_dir is what refuses.
resolve_feed_site_dir() {
  if [ -n "${FEED_SITE_DIR:-}" ]; then
    echo "$FEED_SITE_DIR"; return
  fi
  if [ -f "$KICKOFF_STUDIO_CONFIG" ]; then
    local from_config
    from_config=$(grep -E '^FEED_SITE_DIR=' "$KICKOFF_STUDIO_CONFIG" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"'' || true)
    if [ -n "$from_config" ]; then echo "${from_config/#\~/$HOME}"; return; fi
  fi
  echo "$(cd "$KICKOFF_LIB_REPO_DIR/../.." && pwd)/daily-kickoff-feed"
}

# Never auto-create, for the reason require_studio_dir gives: an empty checkout
# looks healthy and silently produces nothing.
#
# The layout check is not decoration. A FEED_SITE_DIR pointed at the wrong
# clone would have an edition written into it, committed, and pushed to
# whatever remote that clone has — under an "[automated]" message.
require_feed_site_dir() {
  local dir="${1:-${FEED_SITE_DIR:-}}"
  if [ ! -d "$dir" ]; then
    note "ERROR: FEED_SITE_DIR does not exist: $dir"
    note ""
    note "Fix one of:"
    note "  git clone git@github.com:peacepirate/daily-kickoff-feed.git \"$dir\""
    note "  export FEED_SITE_DIR=/path/to/daily-kickoff-feed"
    note "  echo 'FEED_SITE_DIR=/path/to/daily-kickoff-feed' >> $KICKOFF_STUDIO_CONFIG"
    return 1
  fi
  local missing="" d
  for d in src/content/editions scripts package.json; do
    [ -e "$dir/$d" ] || missing="$missing $d"
  done
  if [ -n "$missing" ]; then
    note "ERROR: $dir is missing:$missing"
    note "       Is this the right checkout? Expected the daily-kickoff-feed layout."
    return 1
  fi
  assert_feed_site_outside_engine "$dir"
}

# S4.6 — the feed site must not resolve inside this repo.
#
# `git -C <subdir>` walks up to the nearest repository, so a FEED_SITE_DIR
# misconfigured to somewhere inside this checkout would have the edition
# committed to the PUBLIC engine repo under a "feed:" message, and pushed. The
# studio has the same guard, but only at commit time; this one refuses at
# resolution, before anything is written.
#
# Both sides go through git so both are normalised. $KICKOFF_LIB_REPO_DIR comes
# from `pwd`, which on macOS keeps /var/..., while rev-parse resolves it to
# /private/var/... — comparing the raw strings silently never matches, which is
# the shape of a guard that reports success forever.
assert_feed_site_outside_engine() {  # DIR
  local theirs ours
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || {
    note "WARN: $1 is not a git repository — an edition written there stays unversioned."
    return 0
  }
  theirs="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null || echo feed)"
  ours="$(git -C "$KICKOFF_LIB_REPO_DIR" rev-parse --show-toplevel 2>/dev/null || echo engine)"
  if [ "$theirs" = "$ours" ]; then
    note "ERROR: FEED_SITE_DIR ($1) resolves inside the engine repo ($ours)."
    note "       Refusing: an edition written there would be committed and pushed to a public repo."
    return 1
  fi
}

find_job_config() {  # JOB -> config path on stdout
  local file
  while IFS= read -r file; do
    [ "$(job_name_of "$file")" = "$1" ] && { printf '%s\n' "$file"; return 0; }
  done < <(job_config_files)
  return 1
}

job_config_files() {  # every config, in run order
  local dir file
  for dir in $JOB_KINDS; do
    for file in "$KICKOFF_LIB_REPO_DIR/scripts/$dir"/*.yaml; do
      if [ -f "$file" ]; then echo "$file"; fi
    done
  done
  return 0
}

# S4.4 — ordering is declared, not inherited from the ambient locale.
#
# Within a kind the glob sorts lexicographically, which is fine for four
# independent topics and wrong the moment two configs must run in sequence:
# the pool fetch has to fill before the edition reads it, and `edition` sorts
# before `pool`. A numeric prefix fixes that, but only if it is applied to
# every file in the directory — one unprefixed config sorts by its bare name
# and lands wherever the alphabet puts it, which is the incidental ordering
# this exists to end.
#
# So the rule is all-or-nothing per directory, and it is checked rather than
# documented.
assert_job_order() {
  local dir file stem prefixed=0 bare="" rc=0
  for dir in $JOB_KINDS; do
    prefixed=0; bare=""
    for file in "$KICKOFF_LIB_REPO_DIR/scripts/$dir"/*.yaml; do
      [ -f "$file" ] || continue
      stem="$(basename "$file" .yaml)"
      case "$stem" in
        [0-9][0-9]-*) prefixed=$((prefixed + 1)) ;;
        *) bare="$bare $stem" ;;
      esac
    done
    if [ "$prefixed" -gt 0 ] && [ -n "$bare" ]; then
      log "ERROR: scripts/$dir mixes ordered and unordered configs."
      log "       Prefixed: $prefixed. Unprefixed:$bare"
      log "       Give every config in an ordered directory an NN- prefix, or none of them."
      rc=1
    fi
  done
  return $rc
}

list_jobs() {
  local file
  job_config_files | while IFS= read -r file; do
    printf '%s ' "$(basename "$file" .yaml)"
  done
}

cfg_get() {  # CONFIG KEY [DEFAULT]
  "$PYTHON_BIN" -c 'import sys, yaml; c = yaml.safe_load(open(sys.argv[1])) or {}; print(c.get(sys.argv[2], sys.argv[3]))' \
    "$1" "$2" "${3:-}"
}

day_of_week() { date -j -f %Y-%m-%d "$1" +%u 2>/dev/null || date -d "$1" +%u; }  # 1=Mon … 7=Sun

# %G, never %Y: the ISO week-numbering year diverges from the calendar year at
# every turn of the year. 2027-01-01 is 2026-W53, and %Y would name it 2027-W53
# — a week that does not exist, and a filename that would collide the following
# December.
iso_week() { date -j -f %Y-%m-%d "$1" +%G-W%V 2>/dev/null || date -d "$1" +%G-W%V; }

# Saturday-scheduled jobs always take the full window; daily jobs take it on
# Saturdays as a catchup for the week.
weekly_window() {  # DATE SCHEDULE
  [ "$2" = "saturday" ] || [ "$(day_of_week "$1")" = "6" ]
}

set_tpl_vars() {  # DATE SCHEDULE — the placeholder vocabulary
  TPL_DATE="$1"
  TPL_DATE_PLUS_1="$(date_offset "$1" 1)"
  TPL_DATE_PLUS_30="$(date_offset "$1" 30)"
  # ISO weeks start Monday, so Saturday and Sunday of the same weekend share a
  # week: a Sunday generator names the week that just ended, and its corpus
  # holds the Saturday synthesis that anchors it.
  TPL_WEEK="$(iso_week "$1")"
  # Always set, so there is one code path rather than one per job kind. This is
  # inert for topics: resolve_studio_dir only computes a string — existence is
  # require_studio_dir's job — so it cannot fail on a machine with no studio.
  TPL_STUDIO_DIR="${STUDIO_DIR:-$(resolve_studio_dir)}"
  # Same reasoning as the studio: always set, one code path, and inert for the
  # kinds that never mention it because resolving is only string arithmetic.
  TPL_FEED_SITE="${FEED_SITE_DIR:-$(resolve_feed_site_dir)}"
  TPL_FEED_STATE="$(feed_state_dir)"
  # `--weekly` is a fetch_sources.py flag, so the config that wants it asks for
  # it by name. The runner appending it to every producer handed select_corpus.py
  # an argument it cannot parse.
  if weekly_window "$1" "$2"; then
    TPL_FORMAT="weekly-synthesis"
    TPL_WEEKLY_FLAG="--weekly"
  else
    TPL_FORMAT="daily"
    TPL_WEEKLY_FLAG=""
  fi
}

job_scheduled_today() {  # SCHEDULE DAY_OF_WEEK -> 0 run, 1 skip, 2 unknown vocabulary
  case "$1" in
    daily)    return 0 ;;
    weekdays) [ "$2" != "7" ] ;;   # Mon–Sat; digest sources are quiet on Sunday
    saturday) [ "$2" = "6" ] ;;
    sunday)   [ "$2" = "7" ] ;;
    # A config that exists for its settings, not to run — generators/angles.yaml
    # until Epic 4 turns it on. Without this word the orchestrator would mark it
    # FAILED and exit 1 every night; deleting the config instead would leave
    # select_corpus.py with nothing to read.
    never)    return 1 ;;
    *)        return 2 ;;
  esac
}

# Never log from here — callers capture stdout.
resolve_output() {  # OUTPUT_TEMPLATE -> absolute path
  local tpl="$1" path studio
  studio="${STUDIO_DIR:-$(resolve_studio_dir)}"
  # Both spellings. `${STUDIO_DIR}` is the form a shell author reaches for when
  # the path continues without a separator, and left unsubstituted it resolved
  # to a literal directory named '${STUDIO_DIR}' inside the repo — output
  # written to a path nobody would look at. Brace form first: it is the longer
  # match, and the bare pattern cannot match inside it.
  tpl="${tpl//\$\{STUDIO_DIR\}/$studio}"
  tpl="${tpl//\$STUDIO_DIR/$studio}"
  path="$(render_placeholders "$tpl")"
  case "$path" in
    /*) ;;
    *)  path="$KICKOFF_LIB_REPO_DIR/$path" ;;
  esac
  printf '%s' "$path"
}

# The project's only commit-and-push logic, so there is exactly one copy of it.
# The site repo and $STUDIO_DIR both need every guard here; a second copy is the
# drift class that produced the original theme bug.
#
#   commit_and_push REPO_DIR PATHSPEC MESSAGE [EXPECTED_BRANCH]
#   -> 0 committed · 2 nothing to commit · 1 failed (COMMIT_PUSH_FAIL holds a tag)
#
# Call it in the current shell. COMMIT_PUSH_FAIL is a global out-parameter, so
# `$(commit_and_push ...)` would discard the tag in the subshell.
#
# Each guard was earned:
#   - branch check, because `push origin HEAD:main` from another branch pushes
#     the wrong branch to main, and off-main runs must not commit at all;
#   - `status --porcelain`, never `git diff HEAD`, which cannot see untracked
#     files — and every new digest and note is untracked;
#   - push split from commit, so a push failure leaves the commit intact and the
#     next run retries it.
#
# Uses note(), not log(): the kickoff CLI has no LOG_FILE, and log() would die
# on the unbound variable under `set -u`.
commit_and_push() {  # REPO_DIR PATHSPEC MESSAGE [EXPECTED_BRANCH]
  local repo="$1" pathspec="$2" message="$3" expected="${4:-main}"
  COMMIT_PUSH_FAIL=""

  # rc 1, not 2: pre-extraction this path produced FAILED_JOBS and a non-zero
  # exit from the orchestrator. Folding it into "nothing to commit" made
  # `launchctl list` show success for a repo that cannot publish at all — the
  # 13-night failure shape. Callers that can survive it (the CLI, where the note
  # is already on disk) downgrade it themselves.
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    note "ERROR: $repo is not a git repository — committed nothing, no history kept."
    COMMIT_PUSH_FAIL="norepo"
    return 1
  fi

  # A conflicted merge leaves the branch guard satisfied, so without this
  # `git add -A` would mark the conflict resolved and the automated message
  # would conclude someone else's merge — publishing conflict markers.
  local gitdir
  gitdir="$(git -C "$repo" rev-parse --git-dir 2>/dev/null)"
  case "$repo/$gitdir" in /*) ;; *) gitdir="$repo/$gitdir" ;; esac
  if [ -e "$gitdir/MERGE_HEAD" ] || [ -e "$gitdir/CHERRY_PICK_HEAD" ] \
     || [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ]; then
    note "ERROR: $repo has a merge, cherry-pick or rebase in progress — refusing to commit."
    note "       Finish or abort it by hand; an automated commit would conclude it silently."
    COMMIT_PUSH_FAIL="commit(in-progress)"
    return 1
  fi

  # symbolic-ref first: it resolves an unborn branch, where rev-parse fails and
  # would report "unknown" — so a studio created with `git init` rather than
  # `git clone` would never commit anything. rev-parse is the fallback, and on a
  # detached HEAD it yields "HEAD", which correctly fails the check below.
  local branch
  branch="$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null \
            || git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null \
            || echo unknown)"
  if [ "$branch" != "$expected" ]; then
    note "ERROR: $repo is on branch '$branch', not $expected — refusing to commit or push."
    COMMIT_PUSH_FAIL="commit(branch=$branch)"
    return 1
  fi

  local committed=0
  if [ -n "$(git -C "$repo" status --porcelain -- "$pathspec")" ]; then
    # An unchecked `add` fails silently: both callers invoke this inside an
    # && / || list, which disables `set -e` for the whole function body.
    if ! git -C "$repo" add -A -- "$pathspec"; then
      note "ERROR: git add failed in $repo (index.lock held by another process?)."
      COMMIT_PUSH_FAIL="add"
      return 1
    fi
    # `commit -- "$pathspec"`, not a bare commit: a bare commit writes the whole
    # index, so anything staged by hand outside the pathspec rides along. The
    # public-repo mitigation this whole epic rests on is that the commit is
    # scoped, and `add -A -- pathspec` alone does not make it so.
    if git -C "$repo" commit -m "$message" -- "$pathspec" >/dev/null; then
      committed=1
    else
      note "ERROR: commit failed in $repo."
      COMMIT_PUSH_FAIL="commit"
      return 1
    fi
  else
    note "No new content to commit."
  fi

  # A studio clone may legitimately have no remote. That is a warning, never a
  # failure — a note must not be lost to git configuration.
  if [ -z "$(git -C "$repo" remote 2>/dev/null)" ]; then
    [ "$committed" = 1 ] && note "WARN: $repo has no remote — commit is local only."
    [ "$committed" = 1 ] && return 0 || return 2
  fi

  # Without a tracking branch `@{u}` is unresolvable, and the old `|| echo 0`
  # turned that into "nothing to push" — so a studio made with `git init` +
  # `git remote add` committed forever and never published, silently, rc 0.
  # That is the exact shape of invariant 4 ("success is `git log origin/main`").
  # Fall back to the remote-tracking ref, and if there is none either, push
  # anyway: the destination is known regardless of what git can count.
  local unpushed push_out base=""
  if git -C "$repo" rev-parse --verify --quiet '@{u}' >/dev/null 2>&1; then
    base='@{u}'
  elif git -C "$repo" rev-parse --verify --quiet "origin/$expected" >/dev/null 2>&1; then
    base="origin/$expected"
  fi
  if [ -n "$base" ]; then
    unpushed=$(git -C "$repo" rev-list --count "$base..HEAD" 2>/dev/null || echo "0")
  else
    unpushed="?"
    note "WARN: $repo has a remote but no tracking branch — pushing without a count."
  fi
  if [ "$unpushed" != "0" ]; then
    note "Pushing $unpushed unpushed commit(s) from $repo..."
    if push_out=$(git -C "$repo" push origin "HEAD:$expected" 2>&1); then
      [ -n "$push_out" ] && note "$push_out"
      # S10.2 / invariant 3 — success is the remote ref moving.
      #
      # `git push` exiting 0 is the local client's opinion. This asks the remote
      # what it now holds. The two disagree in exactly the cases that matter and
      # are hardest to see: a push that resolved to a different branch, a
      # server-side hook that accepted and discarded, a stale credential helper
      # serving a cached success. Thirteen nights were lost to a local state
      # that looked correct, so the check is the ref, not the exit code.
      local remote_sha head_sha
      remote_sha=$(git -C "$repo" ls-remote origin "refs/heads/$expected" 2>/dev/null | cut -f1)
      head_sha=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo "")
      if [ -z "$remote_sha" ]; then
        # Unreachable remote after a successful push is odd rather than fatal;
        # the commit is safe locally and the next run retries the push.
        note "WARN: pushed, but could not read origin/$expected back to confirm it moved."
      elif [ "$remote_sha" != "$head_sha" ]; then
        note "ERROR: push reported success but origin/$expected is $remote_sha, not $head_sha."
        note "       Nothing published. Do not trust the exit code here."
        COMMIT_PUSH_FAIL="push-not-at-remote"
        return 1
      else
        note "Push OK — origin/$expected is at $head_sha."
      fi
    else
      [ -n "$push_out" ] && note "$push_out"
      note "ERROR: push failed — $unpushed commit(s) remain local in $repo. Will retry next run."
      COMMIT_PUSH_FAIL="push"
      return 1
    fi
  fi

  [ "$committed" = 1 ] && return 0 || return 2
}

# Phase 2 reads the digest corpus; it must never write to it.
# ── Blocklist ────────────────────────────────────────────────────────────────
# Strings that must never reach this repo or anything it publishes. The list
# itself lives in the private studio; see state/blocklist.txt there for why.
#
# Everything here fails closed. An unreadable or empty list is an error, because
# the alternative — an empty denylist — passes every string in the world and
# looks exactly like success.

resolve_blocklist_file() {
  echo "${KICKOFF_BLOCKLIST:-$(resolve_studio_dir)/state/blocklist.txt}"
}

# One term per line, comments and blanks stripped. Non-zero if the list cannot
# be read or contains no terms.
blocklist_terms() {
  local file out
  file="$(resolve_blocklist_file)"
  [ -r "$file" ] || return 1
  out="$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$file" \
         | grep -v '^$')" || true
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# assert_no_blocked LABEL FILE...
#
# Never prints the matched term — a guard that echoes what it caught writes the
# leak into the log it was protecting. The message names the file and points at
# the list.
assert_no_blocked() {  # LABEL FILE...
  local label="$1"; shift
  local terms term squashed f rc=0
  if ! terms="$(blocklist_terms)"; then
    log "ERROR: blocklist is missing, unreadable or empty: $(resolve_blocklist_file)"
    return 1
  fi
  while IFS= read -r term; do
    [ -n "$term" ] || continue
    squashed="$(tr -d ' ' <<<"$term")"
    for f in "$@"; do
      [ -e "$f" ] || continue
      if grep -qiF -- "$term" "$f" \
         || { [ "$squashed" != "$term" ] && grep -qiF -- "$squashed" "$f"; }; then
        log "ERROR: $label contains a blocked term — see $(resolve_blocklist_file): $f"
        rc=1
      fi
    done
  done <<<"$terms"
  return $rc
}

# ── The feed pool ────────────────────────────────────────────────────────────
#
# The candidate pool and the published ledger, written by the fetch step and
# committed to this repo. The path is defined once, here: a config opts in with
# `ingest: pool` and never names a directory of its own, so no config can aim a
# nightly writer at some other part of a public repo, and run-jobs.sh commits
# exactly the path run-job.sh wrote.
#
# Not under scripts/logs/, which is gitignored and single-machine. A ledger that
# does not survive a fresh clone is not a ledger — the feed would republish
# everything it has ever published on the first machine that lost it.

FEED_STATE_REL="scripts/feed-state"

# FEED_STATE_DIR overrides only for tests, the same way KICKOFF_BLOCKLIST does.
# Nothing in the nightly path sets it.
feed_state_dir() { echo "${FEED_STATE_DIR:-$KICKOFF_LIB_REPO_DIR/$FEED_STATE_REL}"; }

# ingest_applies — 0 to ingest, 1 to skip.
#
# A separate function so the decision can be executed by a test. Asserting that
# run-job.sh merely *contains* the skip is the vacuity this project has already
# paid for: replacing the condition with `if false` leaves every log line in
# place and the assertion still passes.
#
# A replay is dated by the run replaying it, while the sidecar it would ingest
# was written on the night the bundle was fetched. Ingesting under today's date
# would stamp `first_seen` wrong and restart the staleness clock — the same
# resurrection the ledger tombstones exist to close, arriving through the front
# door. Replays exist to test the digest; the pool is fed by the real fetch, or
# by feed_pool.py invoked directly with the date the sidecar belongs to.
ingest_applies() { [ -z "${BUNDLE_FILE:-}" ]; }

# ingest_feed_records DATE RECORDS_FILE
#
# Fold one night's record sidecar into the pool, then prune it. Fails closed on
# a missing sidecar and on an unreadable blocklist.
#
# The blocklist check here does NOT carry the safety property on its own —
# feed_pool.py refuses an unreadable or empty list as well, and that is the
# check that would still be there if this one were deleted. What this one adds
# is a legible refusal instead of a Python traceback at 06:00, and a refusal
# that happens before the state directory is created, so a machine with no
# studio does not accumulate empty feed-state directories it will then try to
# commit.
#
# Neither is redundant with the pre-commit tree scan in run-jobs.sh. Admission
# is the cheap place to keep a term out; once it is in pool.jsonl the tree scan
# refuses to commit the feed state *every* night until someone edits the file.
ingest_feed_records() {  # DATE RECORDS_FILE
  local date="$1" records="$2" state blocklist
  state="$(feed_state_dir)"
  blocklist="$(resolve_blocklist_file)"

  if [ ! -f "$records" ]; then
    log "ERROR: no record sidecar at $records — nothing to ingest."
    log "       The producer writes it; a fetch that produced a bundle should have one."
    return 1
  fi
  if ! blocklist_terms >/dev/null 2>&1; then
    log "ERROR: blocklist is missing, unreadable or empty: $blocklist"
    log "       Refusing to ingest — the pool is committed to a public repo."
    return 1
  fi

  mkdir -p "$state"
  local out rc=0
  out="$("$PYTHON_BIN" "$KICKOFF_LIB_REPO_DIR/scripts/lib/feed_pool.py" ingest \
         --records "$records" --state "$state" --date "$date" --blocklist "$blocklist" 2>&1)" || rc=$?
  [ -n "$out" ] && log "$out"
  return "$rc"
}

# The write side of the ledger — the other half of ingest_feed_records.
#
# Selection excludes everything the ledger names (feed_edition.py, via
# ledger_ids). Nothing wrote the ledger until this existed, so that exclusion
# set was permanently empty and the pool offered the same top-ranked items every
# night: 2026-08-09 and 2026-08-11 shipped three of the same items.
#
# CALLED ONLY AFTER publish_feed_site RETURNS 0, which means the edition is
# confirmed at the remote and not merely written. Marking any earlier retires
# items on a night whose verify or push then failed, and nothing returns them to
# the pool. `publish_feed_site` already fails closed before its commit for the
# same reason: a quarantined edition is recoverable, a retired item is not.
#
# Return code 2 from publish_feed_site — nothing to commit — must NOT reach
# here. It means an earlier run already committed this edition, and that run
# already marked it. The command is idempotent regardless, but relying on that
# would make the ordering rule invisible to whoever reads this next.
mark_feed_published() {  # DATE EDITION_FILE
  local date="$1" edition="$2" state
  state="$(feed_state_dir)"

  if [ ! -f "$edition" ]; then
    log "ERROR: no edition at $edition — cannot mark it published."
    return 1
  fi

  mkdir -p "$state"
  local out rc=0
  out="$("$PYTHON_BIN" "$KICKOFF_LIB_REPO_DIR/scripts/lib/feed_pool.py" publish \
         --edition "$edition" --state "$state" --date "$date" 2>&1)" || rc=$?
  [ -n "$out" ] && log "$out"
  return "$rc"
}

# ── Failure visibility ───────────────────────────────────────────────────────
#
# A failed nightly run is otherwise invisible. The dated log is gitignored and
# never leaves the machine, launchd surfaces only an exit code nobody reads, and
# every serious failure this project has had looked exactly like a quiet night.
#
# Two channels, because each misses differently. The notification is immediate
# and easy to miss at 06:00; the marker file is durable and only seen if
# something reads it, which `kickoff doctor` does.

FAILURE_MARKER_NAME="LAST-RUN-FAILED"

notify_desktop() {  # TITLE MESSAGE
  command -v osascript >/dev/null 2>&1 || return 0
  # Strip quotes and backslashes rather than escaping them: this string is built
  # from job names and is not worth an AppleScript injection surface.
  local title msg
  title="$(printf '%s' "$1" | tr -d '"\\')"
  msg="$(printf '%s' "$2" | tr -d '"\\')"
  osascript -e "display notification \"$msg\" with title \"$title\"" >/dev/null 2>&1 || true
}

# mark_run_failed LOG_DIR SUMMARY   — durable, read by `kickoff doctor`
mark_run_failed() {  # LOG_DIR SUMMARY
  [ -d "$1" ] || return 0
  printf '%s\n%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$2" > "$1/$FAILURE_MARKER_NAME" 2>/dev/null || true
}

clear_run_failed() {  # LOG_DIR
  rm -f "$1/$FAILURE_MARKER_NAME" 2>/dev/null || true
}

# assert_no_blocked_tree LABEL DIR...
#
# Recursive form of assert_no_blocked, for gating a whole content directory
# before it is committed. Same fail-closed semantics, same refusal to echo the
# term: it names the files, which is what you need to fix it, and not the string,
# which is what you are trying not to write down.
assert_no_blocked_tree() {  # LABEL DIR...
  local label="$1"; shift
  local terms term squashed d hits rc=0
  if ! terms="$(blocklist_terms)"; then
    log "ERROR: blocklist is missing, unreadable or empty: $(resolve_blocklist_file)"
    return 1
  fi
  while IFS= read -r term; do
    [ -n "$term" ] || continue
    squashed="$(tr -d ' ' <<<"$term")"
    for d in "$@"; do
      [ -e "$d" ] || continue
      hits="$(grep -rliF -- "$term" "$d" 2>/dev/null || true)"
      if [ "$squashed" != "$term" ]; then
        hits="$hits
$(grep -rliF -- "$squashed" "$d" 2>/dev/null || true)"
      fi
      hits="$(printf '%s\n' "$hits" | grep -v '^$' | sort -u || true)"
      if [ -n "$hits" ]; then
        log "ERROR: $label contains a blocked term — see $(resolve_blocklist_file):"
        printf '%s\n' "$hits" | head -10 | while IFS= read -r f; do log "         $f"; done
        rc=1
      fi
    done
  done <<<"$terms"
  return $rc
}

# S10.7 — the feed site's toolchain, checked before the build rather than
# discovered by it.
#
# launchd starts with a minimal PATH. A missing node at 06:00 would fail the
# highest-value gate in the pipeline every single night while every manual run
# from a terminal succeeded, which is the hardest class of failure to see.
# `npm ci` is deliberately not run here: an unattended job that installs
# dependencies is an unattended job that can pull a new one.
assert_feed_toolchain() {  # DIR
  ensure_tool_path
  local missing=""
  command -v node >/dev/null 2>&1 || missing="$missing node"
  command -v npm  >/dev/null 2>&1 || missing="$missing npm"
  [ -d "$1/node_modules" ]        || missing="$missing node_modules"
  if [ -n "$missing" ]; then
    log "ERROR: the feed site cannot be built — missing:$missing"
    log "       PATH=$PATH"
    [ -d "$1/node_modules" ] || log "       Run: (cd $1 && npm ci)"
    return 1
  fi
}

# S10.1/S10.6 — verify, then scan what was built, then commit. In that order.
#
# `npm run verify` is the site's own chain minus the human review gate: config,
# build, links, budget, feed/advertisement consistency. The review gate is
# deliberately NOT run here. It answers "has a person read this", which is a
# question about deploying, not about whether tonight's edition is structurally
# sound — and during the gated month it would refuse every night, leaving the
# edition uncommitted on one laptop. The gate still stands between the edition
# and readers: `npm run build` runs it, and nothing deploys without it.
#
# The blocklist scan runs against dist/, not against source. The build is the
# last place a name can still be caught, and it is the only place that sees the
# house voice's prose rendered as a reader will receive it. Fails closed, and
# before the commit: a quarantined edition is recoverable, a pushed one is not.
publish_feed_site() {  # DIR DATE
  local dir="$1" date="$2" rc
  require_feed_site_dir "$dir" || return 1
  assert_feed_toolchain "$dir" || return 1

  log "Verifying the feed site build ..."
  ( cd "$dir" && npm run verify ) >>"${LOG_FILE:-/dev/null}" 2>&1 && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "ERROR: the feed site failed to build (npm run verify exited $rc). Nothing committed."
    log "       The edition is on disk at $dir/src/content/editions/$date.json and untouched."
    return 1
  fi

  if ! assert_no_blocked_tree "the built feed site" "$dir/dist"; then
    log "ERROR: refusing to commit the feed site. The build is on disk and untouched."
    return 1
  fi

  commit_and_push "$dir" "src/content/editions/" "edition: $date [automated]" && return 0 || rc=$?
  [ "$rc" = 2 ] && return 2
  return 1
}

# What a job of each kind is allowed to write.
#
# This used to read `[ "$1" = "generators" ] || return 0` — fail-OPEN for every
# other kind, so a topic job was unconstrained and any future kind would inherit
# no boundary at all while looking checked. A guard whose default is "allowed" is
# the failure class this project keeps rediscovering, so the default here refuses.
assert_output_boundary() {  # KIND OUTPUT_PATH
  case "$1" in
    topics|generators|feed) ;;
    *)
      log "ERROR: unknown job kind '$1' — refusing to guess where it may write."
      log "       Add it to assert_output_boundary with its own boundary first."
      return 1 ;;
  esac

  # A `..` segment defeats the prefix tests below by pure string arithmetic:
  # "$STUDIO_DIR/../daily-kickoff/site/src/content/ai/x.md" starts with
  # "$STUDIO_DIR/" and still lands in the public repo — the one place this
  # whole boundary exists to keep studio content out of. Refuse the segment
  # rather than normalize, because the path need not exist yet and BSD has no
  # `readlink -f`.
  case "/$2/" in
    */../*)
      log "ERROR: $1 output must not contain a '..' segment: $2"
      return 1 ;;
  esac

  local root
  case "$1" in
    generators)
      root="${STUDIO_DIR:-$(resolve_studio_dir)}"
      root="${root%/}/"
      if [ "${2#$root}" = "$2" ]; then
        log "ERROR: generator output must resolve beneath \$STUDIO_DIR ($root), got: $2"
        return 1
      fi ;;
    topics)
      # Topic output is the published site. Previously unchecked; all four
      # existing topics already satisfy it.
      root="${KICKOFF_LIB_REPO_DIR%/}/src/content/"
      if [ "${2#$root}" = "$2" ]; then
        log "ERROR: topic output must resolve beneath src/content/ ($root), got: $2"
        return 1
      fi ;;
    feed)
      # Narrower than the other two on purpose. The studio bound is a whole
      # checkout and the topic bound is a whole content tree; a feed job writes
      # one edition JSON and nothing else, so the boundary is the editions
      # directory rather than the repo. A feed job has no business editing the
      # site's pages, its checks, or its config — and this is the only thing
      # standing between a template mistake and a nightly writer aimed at them.
      root="${FEED_SITE_DIR:-$(resolve_feed_site_dir)}"
      root="${root%/}/src/content/editions/"
      if [ "${2#$root}" = "$2" ]; then
        log "ERROR: feed output must resolve beneath the feed site's editions directory ($root), got: $2"
        return 1
      fi ;;
  esac
}
