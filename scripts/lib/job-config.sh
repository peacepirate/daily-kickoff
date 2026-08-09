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

find_job_config() {  # JOB -> config path on stdout
  local dir
  for dir in topics generators; do
    if [ -f "$KICKOFF_LIB_REPO_DIR/scripts/$dir/$1.yaml" ]; then
      echo "$KICKOFF_LIB_REPO_DIR/scripts/$dir/$1.yaml"
      return 0
    fi
  done
  return 1
}

job_config_files() {
  local dir file
  for dir in topics generators; do
    for file in "$KICKOFF_LIB_REPO_DIR/scripts/$dir"/*.yaml; do
      if [ -f "$file" ]; then echo "$file"; fi
    done
  done
  return 0
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
      note "Push OK."
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

# What a job of each kind is allowed to write.
#
# This used to read `[ "$1" = "generators" ] || return 0` — fail-OPEN for every
# other kind, so a topic job was unconstrained and any future kind would inherit
# no boundary at all while looking checked. A guard whose default is "allowed" is
# the failure class this project keeps rediscovering, so the default here refuses.
assert_output_boundary() {  # KIND OUTPUT_PATH
  case "$1" in
    topics|generators) ;;
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
  esac
}
