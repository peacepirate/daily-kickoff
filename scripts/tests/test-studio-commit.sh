#!/bin/bash
# Regression test for the studio commit in scripts/run-jobs.sh (S4.5).
#
# The orchestrator makes two path-scoped commits — src/content/ in this repo and
# angles/ in $STUDIO_DIR — and they must never cross. The site repo is public and
# the studio holds employer-adjacent notes, so "scoped" is a confidentiality
# property, not a tidiness one.
#
# Every case runs the REAL scripts/run-jobs.sh against a scratch copy of the
# script tree, a scratch site repo and a scratch studio, all under $TMPDIR. No
# network, no Claude, and nothing outside $TMPDIR is read for writing.
#
#   bash scripts/tests/test-studio-commit.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

FAIL=0
COUNT=0
ok()  { COUNT=$((COUNT + 1)); printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad() { COUNT=$((COUNT + 1)); FAIL=1; printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SUNDAY=2026-08-02
MONDAY=2026-08-03

# ── scaffolding ───────────────────────────────────────────────────────────────

# A scratch site repo carrying the real run-jobs.sh, run-job.sh and lib/. The
# venv is symlinked, not copied: ensure_venv would otherwise pip-install over the
# network on the first case.
new_site() {  # NAME
  local dir="$WORK/$1"
  mkdir -p "$dir/scripts/topics" "$dir/scripts/generators" "$dir/scripts/prompts" "$dir/src/content"
  cp "$REPO_DIR/scripts/run-jobs.sh" "$REPO_DIR/scripts/run-job.sh" "$dir/scripts/"
  cp -R "$REPO_DIR/scripts/lib" "$dir/scripts/"
  ln -s "$REPO_DIR/scripts/.venv" "$dir/scripts/.venv"

  # A parked config so the job loop is a no-op unless a case adds its own.
  # run-jobs.sh resolves output: before it checks the schedule, so `never` still
  # needs a resolvable one.
  cat > "$dir/scripts/generators/parked.yaml" <<'YAML'
name:     "Parked"
schedule: never
output:   $STUDIO_DIR/angles/{{DATE}}.md
YAML

  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
  # scripts/ is scratch scaffolding; keeping it out of the index makes every
  # assertion about a commit's file list unambiguous.
  printf 'scripts/\n' > "$dir/.gitignore"
  printf 'site\n' > "$dir/README.md"
  git -C "$dir" add -A >/dev/null
  git -C "$dir" commit -qm seed
  git init -q --bare "$dir.git"
  git -C "$dir" remote add origin "$dir.git"
  git -C "$dir" push -q -u origin main
  echo "$dir"
}

# A scratch studio in the kickoff-studio layout.
new_studio() {  # NAME [--no-git|--no-remote|--broken-remote|--no-angles]
  local dir="$WORK/$1" mode="${2:-}"
  mkdir -p "$dir"/{notes,drafts,published,engagement,state}
  [ "$mode" = "--no-angles" ] || mkdir -p "$dir/angles"
  if [ "$mode" = "--no-git" ]; then echo "$dir"; return; fi
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
  printf 'studio\n' > "$dir/README.md"
  git -C "$dir" add -A >/dev/null
  git -C "$dir" commit -qm seed
  case "$mode" in
    --no-remote) ;;
    --broken-remote)
      git init -q --bare "$dir.git"
      git -C "$dir" remote add origin "$WORK/never-created.git" ;;
    *)
      git init -q --bare "$dir.git"
      git -C "$dir" remote add origin "$dir.git"
      git -C "$dir" push -q -u origin main ;;
  esac
  echo "$dir"
}

# A generator that actually runs. Its producer decides how the job fails; the
# claude CLI is never reached, so no LLM call is ever made.
add_failing_generator() {  # SITE STUDIO DATE MODE(exit|empty)
  local site="$1" studio="$2" date="$3" mode="$4"
  cat > "$site/scripts/generators/angles.yaml" <<YAML
name:     "Angles"
schedule: sunday
producer: fakeprod.py
prompt:   scripts/prompts/angles.md
output:   \$STUDIO_DIR/angles/{{DATE}}.md
YAML
  if [ "$mode" = "exit" ]; then
    printf 'import sys\nsys.stderr.write("producer blew up\\n")\nsys.exit(1)\n' \
      > "$site/scripts/fakeprod.py"
  else
    printf 'print("no items here")\n' > "$site/scripts/fakeprod.py"
  fi
  # run-job.sh asserts the prompt names the output path it will verify. For a
  # studio output that path is absolute, so it is written per-run.
  printf 'Write the angles file to %s\n' "$studio/angles/$date.md" \
    > "$site/scripts/prompts/angles.md"
}

angle_file() {  # STUDIO [NAME]
  mkdir -p "$1/angles"
  printf -- '---\nweek: 2026-W31\n---\n\n## A1 — an angle\n' > "$1/angles/${2:-2026-W31.md}"
}

digest_file() {  # SITE
  mkdir -p "$1/src/content/ai"
  printf -- '---\ntheme: ai\n---\n\nbody\n' > "$1/src/content/ai/2026-08-02.md"
}

commits_in()   { git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }
head_files()   { git -C "$1" show --name-only --format= HEAD 2>/dev/null | tr '\n' ' '; }
porcelain()    { git -C "$1" status --porcelain -- "${2:-}" 2>/dev/null; }
synced()       { [ "$(git -C "$1" rev-parse main 2>/dev/null)" \
                   = "$(git -C "$1" rev-parse origin/main 2>/dev/null)" ]; }

# run-jobs.sh in a subshell with a scratch STUDIO_DIR. Output is captured to a
# file rather than $(...) so nothing about the run leaks into this shell.
run_jobs() {  # SITE STUDIO DATE
  ( export STUDIO_DIR="$2" DIGEST_DATE="$3"
    unset LOG_FILE
    bash "$1/scripts/run-jobs.sh" ) >"$WORK/run.txt" 2>&1 && RJ_RC=0 || RJ_RC=$?
  RJ_OUT="$(cat "$WORK/run.txt")"
}

echo "run-jobs.sh studio commit"

# ── 1. AC1: the angles artifact is committed, and only it ─────────────────────
site="$(new_site s1)"; studio="$(new_studio st1)"
angle_file "$studio"
site_before="$(commits_in "$site")"; studio_before="$(commits_in "$studio")"
run_jobs "$site" "$studio" "$SUNDAY"

[ "$RJ_RC" = 0 ] && ok "AC1: run exits 0" || bad "AC1: rc=$RJ_RC — $RJ_OUT"
[ "$(commits_in "$studio")" = $((studio_before + 1)) ] \
  && ok "AC1: studio gains exactly one commit" \
  || bad "AC1: studio commits $studio_before -> $(commits_in "$studio")"
[ "$(head_files "$studio")" = "angles/2026-W31.md " ] \
  && ok "AC1: that commit contains only angles/" \
  || bad "AC1: studio commit files = [$(head_files "$studio")]"
[ -z "$(porcelain "$site" src/content/)" ] \
  && ok "AC1: site src/content/ is clean afterwards" \
  || bad "AC1: site src/content/ dirty: [$(porcelain "$site" src/content/)]"
[ "$(commits_in "$site")" = "$site_before" ] \
  && ok "AC1: site repo gains no commit" \
  || bad "AC1: site commits $site_before -> $(commits_in "$site")"
{ synced "$studio" && grep -q "angles/2026-W31.md" \
    <<<"$(git -C "$studio.git" show --name-only --format= main 2>/dev/null)"; } \
  && ok "AC1: the angle commit reaches origin/main" \
  || bad "AC1: not pushed — remote main = [$(git -C "$studio.git" show --name-only --format= main 2>/dev/null | tr '\n' ' ')]"
[ "$(git -C "$studio" log -1 --format=%s)" = "angles: $SUNDAY [automated]" ] \
  && ok "AC1: the commit is marked [automated] and dated" \
  || bad "AC1: subject = [$(git -C "$studio" log -1 --format=%s)]"

# ── 2. angles/ is generator territory; the hand-edited dirs are not ───────────
site="$(new_site s2)"; studio="$(new_studio st2)"
angle_file "$studio"
printf 'half-written post\n' > "$studio/drafts/wip.md"
printf '# 2026-08-01\nprivate note\n' > "$studio/notes/2026-08.md"
printf 'shipped\n' > "$studio/published/old.md"
run_jobs "$site" "$studio" "$SUNDAY"

files="$(head_files "$studio")"
grep -q "angles/2026-W31.md" <<<"$files" \
  && ok "scoping: the angle is committed" || bad "scoping: angle missing from [$files]"
{ ! grep -qE "drafts/|notes/|published/" <<<"$files"; } \
  && ok "scoping: drafts/, notes/ and published/ are NOT swept in" \
  || bad "scoping: hand-edited files leaked: [$files]"
[ -n "$(porcelain "$studio" drafts/)" ] \
  && ok "scoping: the dirty draft is left uncommitted" \
  || bad "scoping: drafts/ was consumed"
[ -n "$(porcelain "$studio" notes/)" ] \
  && ok "scoping: the untracked note is left uncommitted" \
  || bad "scoping: notes/ was consumed"

# ── 3. Two commits, never crossed ─────────────────────────────────────────────
site="$(new_site s3)"; studio="$(new_studio st3)"
angle_file "$studio"; digest_file "$site"
run_jobs "$site" "$studio" "$SUNDAY"

sfiles="$(head_files "$site")"; dfiles="$(head_files "$studio")"
{ grep -q "src/content/ai/2026-08-02.md" <<<"$sfiles" && ! grep -q "angles/" <<<"$sfiles"; } \
  && ok "crossing: the site commit holds only src/content/" \
  || bad "crossing: site commit = [$sfiles]"
{ grep -q "angles/2026-W31.md" <<<"$dfiles" && ! grep -q "src/content" <<<"$dfiles"; } \
  && ok "crossing: the studio commit holds only angles/" \
  || bad "crossing: studio commit = [$dfiles]"
[ "$RJ_RC" = 0 ] && ok "crossing: both commits succeed (rc 0)" || bad "crossing: rc=$RJ_RC"

# ── 4. AC2: a failed generator commits nothing, anywhere ──────────────────────
site="$(new_site s4)"; studio="$(new_studio st4)"
add_failing_generator "$site" "$studio" "$SUNDAY" exit
site_before="$(commits_in "$site")"; studio_before="$(commits_in "$studio")"
run_jobs "$site" "$studio" "$SUNDAY"

grep -q "producer failed" <<<"$RJ_OUT" \
  && ok "AC2: the generator really did run and fail" \
  || bad "AC2: generator never ran — $RJ_OUT"
[ "$(commits_in "$studio")" = "$studio_before" ] \
  && ok "AC2: nothing committed to the studio" \
  || bad "AC2: studio commits $studio_before -> $(commits_in "$studio")"
[ "$(commits_in "$site")" = "$site_before" ] \
  && ok "AC2: nothing committed to the site repo" \
  || bad "AC2: site commits $site_before -> $(commits_in "$site")"
[ -z "$(ls -A "$studio/angles")" ] \
  && ok "AC2: angles/ is left empty" || bad "AC2: angles/ holds $(ls -A "$studio/angles")"
[ "$RJ_RC" = 1 ] && ok "AC2: the run exits non-zero" || bad "AC2: rc=$RJ_RC"

# ── 5. A failed generator blocks neither publish path ─────────────────────────
#     The studio work happens after the job loop, so it must not be skipped just
#     because a job failed — the run still has a stranded commit to push.
site="$(new_site s5)"; studio="$(new_studio st5)"
add_failing_generator "$site" "$studio" "$SUNDAY" empty
digest_file "$site"
angle_file "$studio"
git -C "$studio" add -A >/dev/null; git -C "$studio" commit -qm "angles: earlier [automated]"
studio_before="$(commits_in "$studio")"
run_jobs "$site" "$studio" "$SUNDAY"

grep -q "src/content/ai/2026-08-02.md" <<<"$(head_files "$site")" \
  && ok "isolation: the digest still publishes when the generator fails" \
  || bad "isolation: site commit = [$(head_files "$site")]"
[ "$(commits_in "$studio")" = "$studio_before" ] \
  && ok "isolation: the studio invents no commit for the failed job" \
  || bad "isolation: studio commits $studio_before -> $(commits_in "$studio")"
synced "$studio" \
  && ok "isolation: a stranded studio commit is still pushed after a job failure" \
  || bad "isolation: stranded commit not pushed"

# ── 6. AC3: an unpushed studio commit is retried on a day with no generator ───
#     This is the case a "only commit if a generator ran tonight" gate breaks:
#     six days a week nothing runs, and the stranded commit never leaves.
site="$(new_site s6)"; studio="$(new_studio st6 --broken-remote)"
angle_file "$studio"
git -C "$studio" add -A >/dev/null; git -C "$studio" commit -qm "angles: earlier [automated]"
git -C "$studio" remote set-url origin "$studio.git"   # the remote is back
studio_before="$(commits_in "$studio")"
run_jobs "$site" "$studio" "$MONDAY"

[ "$(commits_in "$studio")" = "$studio_before" ] \
  && ok "AC3: no new commit is invented on a clean tree" \
  || bad "AC3: studio commits $studio_before -> $(commits_in "$studio")"
[ -n "$(git -C "$studio.git" rev-parse --verify --quiet main || true)" ] \
  && ok "AC3: the stranded commit is pushed on a Monday, with no generator" \
  || bad "AC3: nothing reached the remote"
[ "$RJ_RC" = 0 ] && ok "AC3: the retry run exits 0" || bad "AC3: rc=$RJ_RC — $RJ_OUT"

# ── 7. A failed push keeps the commit, and the next run publishes it ──────────
site="$(new_site s7)"; studio="$(new_studio st7 --broken-remote)"
angle_file "$studio"
studio_before="$(commits_in "$studio")"
run_jobs "$site" "$studio" "$SUNDAY"

[ "$(commits_in "$studio")" = $((studio_before + 1)) ] \
  && ok "push-fail: the commit survives the failed push" \
  || bad "push-fail: studio commits $studio_before -> $(commits_in "$studio")"
[ "$RJ_RC" = 1 ] && grep -q "studio" <<<"$RJ_OUT" \
  && ok "push-fail: the run exits 1 and names the studio" \
  || bad "push-fail: rc=$RJ_RC, output did not name the studio"
grep -qE "FAILED jobs:.*studio-push" <<<"$RJ_OUT" \
  && ok "push-fail: the FAILED list carries the studio-push tag" \
  || bad "push-fail: FAILED list = [$(grep 'FAILED jobs' <<<"$RJ_OUT")]"

git -C "$studio" remote set-url origin "$studio.git"
studio_before="$(commits_in "$studio")"
run_jobs "$site" "$studio" "$MONDAY"
{ [ "$(commits_in "$studio")" = "$studio_before" ] && synced "$studio"; } \
  && ok "push-fail: the next run pushes it without re-committing" \
  || bad "push-fail: retry left studio at $(commits_in "$studio") commits, synced=$?"

# ── 8. No studio at all — the digest must still publish ───────────────────────
site="$(new_site s8)"
digest_file "$site"
run_jobs "$site" "$WORK/there-is-no-studio-here" "$SUNDAY"

[ "$RJ_RC" = 0 ] \
  && ok "no-studio: the run still exits 0" || bad "no-studio: rc=$RJ_RC — $RJ_OUT"
grep -q "there-is-no-studio-here" <<<"$RJ_OUT" \
  && ok "no-studio: the log names the studio it could not find" \
  || bad "no-studio: silent — [$RJ_OUT]"
grep -q "src/content/ai/2026-08-02.md" <<<"$(head_files "$site")" \
  && ok "no-studio: the digest is committed anyway" \
  || bad "no-studio: site commit = [$(head_files "$site")]"

# ── 9. A studio that is not a git repo — loud, but not fatal ──────────────────
site="$(new_site s9)"; studio="$(new_studio st9 --no-git)"
angle_file "$studio"; digest_file "$site"
run_jobs "$site" "$studio" "$SUNDAY"

[ "$RJ_RC" = 0 ] \
  && ok "non-repo: the run still exits 0" || bad "non-repo: rc=$RJ_RC — $RJ_OUT"
grep -qi "not a git repos" <<<"$RJ_OUT" \
  && ok "non-repo: the log says so plainly" || bad "non-repo: silent — [$RJ_OUT]"
grep -q "src/content/ai/2026-08-02.md" <<<"$(head_files "$site")" \
  && ok "non-repo: the digest is committed anyway" \
  || bad "non-repo: site commit = [$(head_files "$site")]"
[ -f "$studio/angles/2026-W31.md" ] \
  && ok "non-repo: the generated angle is left on disk" || bad "non-repo: angle lost"

# ── 10. A studio parked off main — refused, reported, digest unaffected ───────
site="$(new_site s10)"; studio="$(new_studio st10)"
git -C "$studio" checkout -qb wip
angle_file "$studio"; digest_file "$site"
studio_before="$(commits_in "$studio")"
run_jobs "$site" "$studio" "$SUNDAY"

[ "$(commits_in "$studio")" = "$studio_before" ] \
  && ok "off-main: nothing is committed to the studio" \
  || bad "off-main: studio commits $studio_before -> $(commits_in "$studio")"
{ [ "$RJ_RC" = 1 ] && grep -qF 'studio-commit(branch=wip)' <<<"$RJ_OUT"; } \
  && ok "off-main: the run exits 1 and the FAILED list names branch and repo" \
  || bad "off-main: rc=$RJ_RC, FAILED = [$(grep 'FAILED jobs' <<<"$RJ_OUT")]"
grep -q "src/content/ai/2026-08-02.md" <<<"$(head_files "$site")" \
  && ok "off-main: the digest still publishes" \
  || bad "off-main: site commit = [$(head_files "$site")]"
[ -f "$studio/angles/2026-W31.md" ] \
  && ok "off-main: the generated angle is left on disk" || bad "off-main: angle lost"

# ── 11. A studio with no angles/ directory — no crash, nothing to do ──────────
site="$(new_site s11)"; studio="$(new_studio st11 --no-angles)"
studio_before="$(commits_in "$studio")"
run_jobs "$site" "$studio" "$MONDAY"

[ "$RJ_RC" = 0 ] && [ "$(commits_in "$studio")" = "$studio_before" ] \
  && ok "no-angles-dir: nothing to do, exits 0" \
  || bad "no-angles-dir: rc=$RJ_RC commits $studio_before -> $(commits_in "$studio")"

# ── 12. A studio with no remote — commit locally, warn, do not fail the run ───
site="$(new_site s12)"; studio="$(new_studio st12 --no-remote)"
angle_file "$studio"
studio_before="$(commits_in "$studio")"
run_jobs "$site" "$studio" "$SUNDAY"

[ "$(commits_in "$studio")" = $((studio_before + 1)) ] \
  && ok "no-remote: the angle is committed locally" \
  || bad "no-remote: studio commits $studio_before -> $(commits_in "$studio")"
{ [ "$RJ_RC" = 0 ] && grep -q "no remote" <<<"$RJ_OUT"; } \
  && ok "no-remote: warned, but the run still exits 0" \
  || bad "no-remote: rc=$RJ_RC, output = [$RJ_OUT]"

# ── 13. A studio resolving inside the site repo must never be committed ───────
#      The site repo is public. `git -C <subdir>` finds the *site* repo, so
#      without a guard the studio call would commit private content to it.
site="$(new_site s13)"
mkdir -p "$site/inside-studio"/{notes,angles,drafts,published,engagement,state}
printf -- '---\nweek: 2026-W31\n---\n' > "$site/inside-studio/angles/2026-W31.md"
site_before="$(commits_in "$site")"
run_jobs "$site" "$site/inside-studio" "$SUNDAY"

{ ! grep -q "angles/" <<<"$(head_files "$site")"; } \
  && ok "inside-repo: no studio content reaches the site repo" \
  || bad "inside-repo: site commit = [$(head_files "$site")]"
[ "$RJ_RC" != 0 ] && grep -qi "inside" <<<"$RJ_OUT" \
  && ok "inside-repo: refused loudly, not silently" \
  || bad "inside-repo: rc=$RJ_RC, output = [$RJ_OUT]"

echo
echo "$COUNT assertions"
[ "$FAIL" = "0" ] && echo "studio commit tests passed" || echo "studio commit tests FAILED"
exit "$FAIL"
