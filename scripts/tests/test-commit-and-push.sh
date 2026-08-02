#!/bin/bash
# Regression test for commit_and_push (scripts/lib/job-config.sh).
#
# It is the only commit-and-push logic in the project and it guards the path
# that silently published nothing for 13 nights, so it gets a deterministic
# test rather than a nightly dice roll. Runs entirely in scratch repos: no
# network, no Claude, nothing touched outside $TMPDIR.
#
#   bash scripts/tests/test-commit-and-push.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO_DIR/scripts/lib/job-config.sh"

FAIL=0
ok()  { printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad() { printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A scratch repo on `main` with a bare origin it can actually push to.
new_repo() {  # NAME [--no-remote]
  local dir="$WORK/$1"
  mkdir -p "$dir/src/content" "$dir/other"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
  echo seed > "$dir/seed.txt"
  git -C "$dir" add -A >/dev/null
  git -C "$dir" commit -qm seed
  if [ "${2:-}" != "--no-remote" ]; then
    git init -q --bare "$dir.git"
    git -C "$dir" remote add origin "$dir.git"
    git -C "$dir" push -q -u origin main
  fi
  echo "$dir"
}

commits_in() { git -C "$1" rev-list --count HEAD; }

# Redirect to a file rather than $(...): command substitution runs the function
# in a subshell, where its COMMIT_PUSH_FAIL assignment would never reach us.
run_cap() {
  COMMIT_PUSH_FAIL=""
  "$@" >"$WORK/out.txt" 2>&1 && CP_RC=0 || CP_RC=$?
  CP_OUT="$(cat "$WORK/out.txt")"
}

echo "commit_and_push"

# 1. Nothing to commit under the pathspec -> rc 2, no new commit.
d="$(new_repo nothing)"; before="$(commits_in "$d")"
run_cap commit_and_push "$d" "src/content/" "msg"
[ "$CP_RC" = 2 ] && [ "$(commits_in "$d")" = "$before" ] \
  && ok "clean tree returns 2 and commits nothing" \
  || bad "clean tree: rc=$CP_RC commits $before -> $(commits_in "$d")"
grep -q "No new content to commit." <<<"$CP_OUT" \
  && ok "clean tree keeps the existing log line" || bad "clean tree log line changed"

# 2. New untracked content -> rc 0, committed AND pushed.
#    `git diff HEAD` cannot see untracked files; this is the 13-night bug.
d="$(new_repo untracked)"; before="$(commits_in "$d")"
echo x > "$d/src/content/2026-08-02.md"
run_cap commit_and_push "$d" "src/content/" "digest: 2026-08-02 [automated]"
[ "$CP_RC" = 0 ] && [ "$(commits_in "$d")" = $((before + 1)) ] \
  && ok "untracked file is committed (rc 0)" || bad "untracked: rc=$CP_RC"
[ "$(git -C "$d" rev-parse main)" = "$(git -C "$d" rev-parse origin/main)" ] \
  && ok "pushed to origin/main" || bad "not pushed"

# 3. Pathspec scoping — files outside it must not be swept in.
d="$(new_repo scoping)"
echo in  > "$d/src/content/a.md"
echo out > "$d/other/b.md"
run_cap commit_and_push "$d" "src/content/" "msg"
files="$(git -C "$d" show --name-only --format= HEAD | tr '\n' ' ')"
[ "$CP_RC" = 0 ] && grep -q "src/content/a.md" <<<"$files" && ! grep -q "other/b.md" <<<"$files" \
  && ok "commit is scoped to the pathspec" || bad "scoping leaked: [$files]"
[ -n "$(git -C "$d" status --porcelain -- other/)" ] \
  && ok "out-of-scope file left uncommitted" || bad "out-of-scope file was committed"

# 4. Off the expected branch -> rc 1, tagged, and NOTHING committed.
#    `push origin HEAD:main` from another branch pushes the wrong branch to main.
d="$(new_repo offbranch)"; git -C "$d" checkout -qb feature
echo x > "$d/src/content/a.md"; before="$(commits_in "$d")"
run_cap commit_and_push "$d" "src/content/" "msg"
[ "$CP_RC" = 1 ] && [ "$COMMIT_PUSH_FAIL" = "commit(branch=feature)" ] \
  && [ "$(commits_in "$d")" = "$before" ] \
  && ok "off-main refuses to commit or push (rc 1)" \
  || bad "off-main: rc=$CP_RC tag='$COMMIT_PUSH_FAIL' commits $before -> $(commits_in "$d")"

# 5. A repo with no remote -> commit locally, warn, still succeed.
#    A note must never be lost to git configuration.
d="$(new_repo noremote --no-remote)"; before="$(commits_in "$d")"
echo x > "$d/src/content/a.md"
run_cap commit_and_push "$d" "src/content/" "msg"
[ "$CP_RC" = 0 ] && [ "$(commits_in "$d")" = $((before + 1)) ] \
  && grep -q "no remote" <<<"$CP_OUT" \
  && ok "no remote commits locally and warns (rc 0)" || bad "no remote: rc=$CP_RC"

# 6. Not a git repo at all -> reported clearly, no crash. The return code it
#    maps to is asserted in case 12; here we only care that it is legible.
mkdir -p "$WORK/plain/src/content"; echo x > "$WORK/plain/src/content/a.md"
run_cap commit_and_push "$WORK/plain" "src/content/" "msg"
grep -q "not a git repository" <<<"$CP_OUT" \
  && ok "non-repo says so plainly" || bad "non-repo message missing: rc=$CP_RC"

# 7. Push fails -> rc 1 tagged 'push', and the commit SURVIVES for the retry.
d="$(new_repo pushfail)"; git -C "$d" remote set-url origin "$WORK/does-not-exist.git"
echo x > "$d/src/content/a.md"; before="$(commits_in "$d")"
run_cap commit_and_push "$d" "src/content/" "msg"
[ "$CP_RC" = 1 ] && [ "$COMMIT_PUSH_FAIL" = "push" ] \
  && [ "$(commits_in "$d")" = $((before + 1)) ] \
  && ok "push failure keeps the commit for retry (rc 1)" \
  || bad "push failure: rc=$CP_RC tag='$COMMIT_PUSH_FAIL'"

# 8. Clean tree with an unpushed commit still pushes — the retry path.
d="$(new_repo retry)"
echo x > "$d/src/content/a.md"; git -C "$d" add -A >/dev/null; git -C "$d" commit -qm "earlier"
run_cap commit_and_push "$d" "src/content/" "msg"
[ "$CP_RC" = 2 ] && [ "$(git -C "$d" rev-parse main)" = "$(git -C "$d" rev-parse origin/main)" ] \
  && ok "unpushed commit is retried on a clean tree" || bad "retry path: rc=$CP_RC"

# 9. Must work with LOG_FILE unset — the kickoff CLI has no log file, and
#    log() would die on the unbound variable under `set -u`.
d="$(new_repo nologfile)"; echo x > "$d/src/content/a.md"
( unset LOG_FILE; set -u; commit_and_push "$d" "src/content/" "msg" >/dev/null 2>&1 )
[ $? = 0 ] && ok "works with LOG_FILE unset (kickoff path)" || bad "fails with LOG_FILE unset"

# 10. Unborn branch — a studio made with `git init` has no commits yet, and
#     rev-parse --abbrev-ref HEAD fails there. Must still commit.
d="$WORK/unborn"; mkdir -p "$d/notes"; git -C "$d" init -q -b main
git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
echo x > "$d/notes/2026-08.md"
run_cap commit_and_push "$d" "notes/" "note: first"
[ "$CP_RC" = 0 ] && [ "$(commits_in "$d")" = 1 ] \
  && ok "unborn branch still commits (rc 0)" \
  || bad "unborn branch: rc=$CP_RC tag='$COMMIT_PUSH_FAIL'"

# 11. Detached HEAD must be refused — it is not the expected branch.
d="$(new_repo detached)"; git -C "$d" checkout -q --detach HEAD
echo x > "$d/src/content/a.md"; before="$(commits_in "$d")"
run_cap commit_and_push "$d" "src/content/" "msg"
[ "$CP_RC" = 1 ] && [ "$(commits_in "$d")" = "$before" ] \
  && ok "detached HEAD refuses to commit (rc 1)" \
  || bad "detached HEAD: rc=$CP_RC tag='$COMMIT_PUSH_FAIL'"

# 12. Not a repo is a FAILURE, not "nothing to commit". Folding it into rc 2
#     made the orchestrator exit 0 for a repo that cannot publish at all.
mkdir -p "$WORK/plain2/src/content"; echo x > "$WORK/plain2/src/content/a.md"
run_cap commit_and_push "$WORK/plain2" "src/content/" "msg"
[ "$CP_RC" = 1 ] && [ "$COMMIT_PUSH_FAIL" = "norepo" ] \
  && ok "non-repo fails (rc 1), so the orchestrator exits non-zero" \
  || bad "non-repo: rc=$CP_RC tag='$COMMIT_PUSH_FAIL'"

# 13. A conflicted merge must be refused: `add -A` would mark it resolved and
#     the automated message would conclude it, publishing conflict markers.
d="$(new_repo merging)"
git -C "$d" checkout -q -b side
echo side > "$d/src/content/conflict.md"; git -C "$d" add -A >/dev/null; git -C "$d" commit -qm side
git -C "$d" checkout -q main
# git does not track empty directories, so checking out main removed src/content
# along with the file that was the only thing in it.
mkdir -p "$d/src/content"
echo main > "$d/src/content/conflict.md"; git -C "$d" add -A >/dev/null; git -C "$d" commit -qm main
git -C "$d" merge side >/dev/null 2>&1
before="$(commits_in "$d")"
run_cap commit_and_push "$d" "src/content/" "msg"
[ "$CP_RC" = 1 ] && [ "$(commits_in "$d")" = "$before" ] \
  && ok "conflicted merge is refused, nothing committed (rc 1)" \
  || bad "mid-merge: rc=$CP_RC commits $before -> $(commits_in "$d")"
grep -q "<<<<<<<" "$d/src/content/conflict.md" \
  && ok "conflict markers left in the tree, not published" || bad "conflict was concluded"
git -C "$d" merge --abort 2>/dev/null || true

# 14. A file staged by hand OUTSIDE the pathspec must not ride along. The old
#     test only proved untracked files are excluded, which cannot fail — an
#     untracked file is never in the index.
d="$(new_repo staged)"
echo in > "$d/src/content/a.md"
echo out > "$d/other/secret.txt"
git -C "$d" add -- other/secret.txt >/dev/null      # pre-staged, deliberately
run_cap commit_and_push "$d" "src/content/" "msg"
files="$(git -C "$d" show --name-only --format= HEAD | tr '\n' ' ')"
[ "$CP_RC" = 0 ] && grep -q "src/content/a.md" <<<"$files" && ! grep -q "secret.txt" <<<"$files" \
  && ok "pre-staged out-of-scope file is NOT committed" || bad "staged leak: [$files]"
[ -n "$(git -C "$d" diff --cached --name-only)" ] \
  && ok "the out-of-scope file is left staged, untouched" || bad "staged file was consumed"

# 15. A remote with no tracking branch must still push. `@{u}` is unresolvable
#     there, and the old `|| echo 0` read that as "nothing to push" — commit
#     locally forever, rc 0, no warning.
d="$WORK/noupstream"; mkdir -p "$d/src/content"
git -C "$d" init -q -b main; git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
echo seed > "$d/seed.txt"; git -C "$d" add -A >/dev/null; git -C "$d" commit -qm seed
git init -q --bare "$d.git"; git -C "$d" remote add origin "$d.git"   # note: no -u
echo x > "$d/src/content/a.md"
run_cap commit_and_push "$d" "src/content/" "msg"
[ "$CP_RC" = 0 ] && [ -n "$(git -C "$d.git" rev-parse --verify --quiet main || true)" ] \
  && ok "remote without a tracking branch is still pushed" \
  || bad "no-upstream: rc=$CP_RC, remote main=$(git -C "$d.git" rev-parse --verify --quiet main || echo NONE)"

echo
[ "$FAIL" = "0" ] && echo "commit_and_push tests passed" || echo "commit_and_push tests FAILED"
exit "$FAIL"
