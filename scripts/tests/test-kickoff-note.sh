#!/bin/bash
# Regression test for `kickoff note` — S2.3 capture and S2.4 the import port.
#
# The notes file is the half of the Phase 2 corpus that cannot be regenerated
# from anywhere, so every path that touches it gets a deterministic test rather
# than a nightly dice roll. Runs entirely in scratch studios: no network, no
# Claude, no Python, nothing touched outside $TMPDIR.
#
#   bash scripts/tests/test-kickoff-note.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KICKOFF="$REPO_DIR/scripts/studio/kickoff"

# Sourcing defines the helpers without dispatching, which is how the reader
# regex below stays the same one the writer used. It also turns on `set -e`.
. "$KICKOFF"
set +e

FAIL=0
ok()  { printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad() { printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=1; }

WORK="$(mktemp -d)"
# Test 12 makes a notes file read-only on purpose; rm -rf alone would leave it.
trap 'chmod -R u+w "$WORK" >/dev/null 2>&1; rm -rf "$WORK"' EXIT

MONTH="$(date +%Y-%m)"

# A scratch studio with the real layout, on `main`, with a bare origin it can
# actually push to. Seeded: commit_and_push resolves HEAD with `rev-parse`,
# which cannot name an unborn branch.
new_studio() {  # NAME
  local dir="$WORK/$1" d
  for d in notes angles drafts published engagement state; do mkdir -p "$dir/$d"; done
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
  touch "$dir/notes/.gitkeep"
  git -C "$dir" add -A >/dev/null
  git -C "$dir" commit -qm seed
  git init -q --bare "$dir.git"
  git -C "$dir" remote add origin "$dir.git"
  git -C "$dir" push -q -u origin main
  echo "$dir"
}

notes_file() { echo "$1/notes/$MONTH.md"; }
commits_in() { git -C "$1" rev-list --count HEAD; }

# `grep -c` prints 0 *and* exits 1; `|| true` keeps the count and drops the
# status. (`|| echo 0` would yield "0\n0".)
entries_in() { grep -cE "$NOTE_HEADER_RE" "$1" || true; }

# Never $(...): the studio path and the exit code are both wanted.
run_note() {  # STUDIO ARGS...
  local studio="$1"; shift
  STUDIO_DIR="$studio" bash "$KICKOFF" note "$@" >"$WORK/out.txt" 2>&1
  RC=$?
  OUT="$(cat "$WORK/out.txt")"
}

echo "kickoff note"

# 1. Absent month file -> created with the heading and exactly one entry.
d="$(new_studio create)"
run_note "$d" "Three teams stalled at the same place." --tag adoption,review-bottleneck --link leadership/2026-08-01
f="$(notes_file "$d")"
[ "$RC" = 0 ] && [ "$(head -1 "$f")" = "# Notes — $MONTH" ] && [ "$(entries_in "$f")" = 1 ] \
  && ok "creates the month file with a heading and one entry" \
  || bad "create: rc=$RC head='$(head -1 "$f" 2>&1)' entries=$(entries_in "$f" 2>/dev/null)"

# The header must carry the stamp, both tags and the link, in that order.
grep -qE "$NOTE_HEADER_RE" <<<"$(grep '^## ' "$f")" \
  && grep -q '#adoption #review-bottleneck → leadership/2026-08-01$' <<<"$(grep '^## ' "$f")" \
  && ok "header carries stamp, tags and link" || bad "header wrong: $(grep '^## ' "$f")"
[ "$(sed -n '4p' "$f")" = "Three teams stalled at the same place." ] \
  && ok "body follows the header verbatim" || bad "body wrong: $(sed -n '4p' "$f")"

# 2. Append, never rewrite: the first entry must survive byte for byte.
cp "$f" "$WORK/before.md"
run_note "$d" "second note"
[ "$RC" = 0 ] && [ "$(entries_in "$f")" = 2 ] \
  && ok "second note is appended (2 entries)" || bad "append: rc=$RC entries=$(entries_in "$f")"
head -c "$(wc -c < "$WORK/before.md" | tr -d ' ')" "$f" | cmp -s - "$WORK/before.md" \
  && ok "prior content is byte-identical — appended, not rewritten" || bad "file was rewritten"
[ "$(grep -c '^# Notes' "$f")" = 1 ] \
  && ok "heading is written once" || bad "heading duplicated"

# 3. A dangling --link warns, names near matches, and still writes the note.
d="$(new_studio dangling)"
run_note "$d" "linked to nothing" --link ai/1999-01-02
f="$(notes_file "$d")"
[ "$RC" = 0 ] && [ "$(entries_in "$f")" = 1 ] && grep -q '→ ai/1999-01-02$' "$f" \
  && ok "dangling link still writes the note" || bad "dangling: rc=$RC entries=$(entries_in "$f" 2>/dev/null)"
grep -q 'names no digest' <<<"$OUT" && ok "dangling link warns" || bad "no warning: $OUT"
grep -q 'near matches:.*ai/' <<<"$OUT" \
  && ok "warning lists near matches" || bad "no near matches: $OUT"

# 4. A studio that does not resolve -> the exact fix commands, and nothing written.
run_note "$WORK/absent" "must not be captured"
[ "$RC" != 0 ] && [ ! -e "$WORK/absent" ] \
  && ok "missing studio errors and writes nothing" || bad "missing studio: rc=$RC"
grep -q 'git clone git@github.com:peacepirate/kickoff-studio.git' <<<"$OUT" \
  && grep -q 'export STUDIO_DIR=' <<<"$OUT" \
  && ok "error names the exact fix commands" || bad "fix commands missing: $OUT"

# A directory that exists but is not a studio must fail the same way.
mkdir -p "$WORK/halfstudio/notes"
run_note "$WORK/halfstudio" "must not be captured"
[ "$RC" != 0 ] && [ ! -e "$WORK/halfstudio/notes/$MONTH.md" ] \
  && grep -q 'missing required directories' <<<"$OUT" \
  && ok "incomplete studio errors and writes nothing" || bad "incomplete studio: rc=$RC"

# 5. No Python on the capture path — the 10-second bar depends on it.
#    A PATH shim catches anything resolved by name; the xtrace also catches an
#    absolute venv path, which no shim can intercept. The real scripts/.venv is
#    never touched.
d="$(new_studio venvless)"   # not "nopython": the path itself lands in the trace
mkdir -p "$WORK/shim"
for p in python python3; do
  printf '#!/bin/sh\ntouch "%s/python-was-called"\nexit 1\n' "$WORK" > "$WORK/shim/$p"
  chmod +x "$WORK/shim/$p"
done
STUDIO_DIR="$d" PATH="$WORK/shim:$PATH" bash -x "$KICKOFF" note "no interpreter here" \
  >"$WORK/out.txt" 2>"$WORK/trace.txt"
RC=$?
[ "$RC" = 0 ] && [ ! -e "$WORK/python-was-called" ] && ! grep -qi 'python' "$WORK/trace.txt" \
  && ok "capture never invokes Python" \
  || bad "python: rc=$RC shim=$([ -e "$WORK/python-was-called" ] && echo hit || echo clean) trace=$(grep -im1 python "$WORK/trace.txt")"

# 6. One commit, scoped to notes/.
d="$(new_studio committed)"; before="$(commits_in "$d")"
run_note "$d" "committed note"
files="$(git -C "$d" show --name-only --format= HEAD | tr '\n' ' ')"
[ "$RC" = 0 ] && [ "$(commits_in "$d")" = $((before + 1)) ] \
  && ok "capture makes exactly one commit" || bad "commit: rc=$RC $before -> $(commits_in "$d")"
grep -q "notes/$MONTH.md" <<<"$files" && [ -z "$(tr ' ' '\n' <<<"$files" | grep -v '^notes/' | grep -v '^$')" ] \
  && ok "commit contains only notes/" || bad "commit leaked: [$files]"
[ "$(git -C "$d" rev-parse main)" = "$(git -C "$d" rev-parse origin/main)" ] \
  && ok "pushed to origin/main" || bad "not pushed"

# 7. stdin, with a multi-line body that must survive verbatim.
d="$(new_studio stdin)"; f="$(notes_file "$d")"
payload='first line
  indented second
third'
printf '%s\n' "$payload" | STUDIO_DIR="$d" bash "$KICKOFF" note - --tag stdin >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && [ "$(entries_in "$f")" = 1 ] \
  && ok "stdin capture writes one entry" || bad "stdin: rc=$RC entries=$(entries_in "$f" 2>/dev/null)"
[ "$(sed -n '4,6p' "$f")" = "$payload" ] \
  && ok "multi-line body survives verbatim" || bad "body mangled: [$(sed -n '4,6p' "$f")]"

# 8. A body that looks like markup must not corrupt parsing: '## ' lines are not
#    headers (no stamp), and '#hash' in the body is not a tag.
d="$(new_studio markup)"; f="$(notes_file "$d")"
body='## Not a header
Some #hash in the body → not/a-link
### deeper'
printf '%s\n' "$body" | STUDIO_DIR="$d" bash "$KICKOFF" note - --tag real >/dev/null 2>&1
[ "$(entries_in "$f")" = 1 ] \
  && ok "'## ' in the body is not read as an entry header" || bad "entries=$(entries_in "$f")"
[ "$(sed -n '4,6p' "$f")" = "$body" ] \
  && ok "markup body stored verbatim" || bad "markup body mangled: [$(sed -n '4,6p' "$f")]"
hdr="$(grep -E "$NOTE_HEADER_RE" "$f")"
[ "$(grep -c '#' <<<"$hdr")" = 1 ] && grep -q '#real$' <<<"$hdr" \
  && ok "tags come only from the header" || bad "tag parsing leaked: $hdr"

# 9. --import: three blank-line-separated blocks become three entries.
d="$(new_studio import)"; f="$(notes_file "$d")"
src="$WORK/from-phone.txt"
printf 'block one\n\nblock two\nstill two\n\n\nblock three\n' > "$src"
before="$(commits_in "$d")"
run_note "$d" --import "$src"
[ "$RC" = 0 ] && [ "$(entries_in "$f")" = 3 ] \
  && ok "3 blocks import as 3 entries" || bad "import: rc=$RC entries=$(entries_in "$f" 2>/dev/null) out=$OUT"
grep -q '^still two$' "$f" && ok "a multi-line block stays one entry" || bad "block two split"

# 10. The source file is moved, so a re-import is impossible.
[ ! -e "$src" ] && ok "source file is removed from its original path" || bad "source file left behind"
moved="$(ls "$d/notes/.imported" 2>/dev/null | tr '\n' ' ')"
grep -q 'from-phone.txt' <<<"$moved" \
  && ok "raw original retained in notes/.imported/ ($moved)" || bad ".imported/: [$moved]"

# 11. One commit for the whole import, not one per block.
[ "$(commits_in "$d")" = $((before + 1)) ] \
  && ok "one commit for the whole import" || bad "import commits: $before -> $(commits_in "$d")"

# Entries are stamped at import time — today — never inferred from the file.
[ "$(grep -cE "^## $(date +%Y-%m-%d)T" "$f")" = 3 ] \
  && ok "imported entries are stamped at import time" || bad "import timestamps not today"

# 12. An import that fails partway leaves the source file exactly where it was.
d="$(new_studio importfail)"; f="$(notes_file "$d")"
src="$WORK/unimportable.txt"
printf 'one\n\ntwo\n' > "$src"
printf '# Notes — %s\n' "$MONTH" > "$f"
chmod a-w "$f"
run_note "$d" --import "$src"
chmod u+w "$f"
[ "$RC" != 0 ] && [ -f "$src" ] \
  && ok "failed import leaves the source file in place" || bad "failed import: rc=$RC src=$([ -f "$src" ] && echo kept || echo LOST)"
[ ! -d "$d/notes/.imported" ] && [ "$(entries_in "$f")" = 0 ] \
  && ok "failed import writes nothing and archives nothing" \
  || bad "failed import left state: entries=$(entries_in "$f") imported=$([ -d "$d/notes/.imported" ] && echo yes || echo no)"

# A file with no blocks is not an import — and must not be swallowed.
d="$(new_studio importempty)"
src="$WORK/blank.txt"; printf '\n  \n\n' > "$src"
run_note "$d" --import "$src"
[ "$RC" != 0 ] && [ -f "$src" ] && [ ! -e "$(notes_file "$d")" ] \
  && ok "empty import errors and keeps the source file" || bad "empty import: rc=$RC"

echo
[ "$FAIL" = "0" ] && echo "kickoff note tests passed" || echo "kickoff note tests FAILED"
exit "$FAIL"
