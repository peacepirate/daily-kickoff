#!/bin/bash
# Regression test for `kickoff signals` — S2.7, the browser -> filesystem bridge.
#
# signals.json is a merge target that can only lose data silently: a wrong
# merge rule deletes stars that exist nowhere else, and nothing about the file
# afterwards looks wrong. So every branch of the merge gets a deterministic
# test. Runs entirely in scratch studios with a scratch $HOME: no network, no
# Claude, nothing touched outside $TMPDIR.
#
#   bash scripts/tests/test-kickoff-signals.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KICKOFF="$REPO_DIR/scripts/studio/kickoff"

PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

FAIL=0
ok()  { printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad() { printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Seeded and on `main`, with a bare origin it can actually push to.
new_studio() {  # NAME
  local dir="$WORK/$1" d
  for d in notes angles drafts published engagement state; do mkdir -p "$dir/$d"; done
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
  touch "$dir/state/.gitkeep"
  git -C "$dir" add -A >/dev/null
  git -C "$dir" commit -qm seed
  git init -q --bare "$dir.git"
  git -C "$dir" remote add origin "$dir.git"
  git -C "$dir" push -q -u origin main
  echo "$dir"
}

# A scratch $HOME so ~/Downloads is ours, and a scratch cwd so the second
# search location holds nothing either. Both are reset per case.
fresh_env() {
  rm -rf "$WORK/home" "$WORK/cwd"
  mkdir -p "$WORK/home/Downloads" "$WORK/cwd"
}

sig_of()     { echo "$1/state/signals.json"; }
commits_in() { git -C "$1" rev-list --count HEAD; }

# exportedAt fixtures are RELATIVE to now. `kickoff signals` refuses a stamp in
# the future, so absolute ones turn this suite red the moment the calendar
# passes them — which is exactly what happened to the first version of this file.
ago() { date -j -v"-${1}d" "+%Y-%m-%dT${2:-08:00:00}%z" | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/'; }
ago_date() { date -j -v"-${1}d" '+%Y-%m-%d'; }
T7="$(ago 7)"; T6="$(ago 6 09:12:00)"; T5="$(ago 5 10:00:00)"; T5B="$(ago 5)"
T3="$(ago 3)"; T2="$(ago 2)"; T1="$(ago 1)"; D1="$(ago_date 1)"; D4="$(ago_date 4)"

# Item keys only need the valid 5-part shape; their date is an identifier, not a
# time, so fixed past dates keep them stable. The import validates shape and
# rejects junk, so bare labels like "k" cannot be used here.
KA="wl:ai:2026-01-10:try:0"; KB="wl:ai:2026-01-11:try:0"; KC="wl:ai:2026-01-12:try:0"

# Unquoted heredoc on purpose — the fields are meant to expand. No backticks in
# any of the fixtures, so nothing else goes live.
write_export() {  # PATH EXPORTED_AT SCHEMA ITEMS_JSON
  cat > "$1" <<EOF
{ "schema": $3, "exportedAt": "$2", "items": $4 }
EOF
}

jget() {  # FILE PYTHON_EXPR over the loaded dict `d`
  "$PYBIN" -c 'import json, sys
d = json.load(open(sys.argv[1]))
print(eval(sys.argv[2]))' "$1" "$2" 2>&1
}

run_signals() {  # STUDIO [ARGS...]
  local studio="$1"; shift
  ( cd "$WORK/cwd" && HOME="$WORK/home" STUDIO_DIR="$studio" bash "$KICKOFF" signals "$@" ) \
    >"$WORK/out.txt" 2>&1
  RC=$?
  OUT="$(cat "$WORK/out.txt")"
}

echo "kickoff signals"

# 1. First import creates the store, stamped with the export's own exportedAt.
fresh_env; d="$(new_studio create)"; s="$(sig_of "$d")"
write_export "$WORK/home/Downloads/kickoff-signals-2026-08-02.json" "$T6" 2 \
  '{ "wl:ai:2026-08-01:try:0": { "starred": true, "status": "done" } }'
run_signals "$d"
[ "$RC" = 0 ] && [ -f "$s" ] && [ "$(jget "$s" 'd["schema"]')" = 2 ] \
  && ok "first import creates signals.json" || bad "create: rc=$RC out=$OUT"
[ "$(jget "$s" 'd["items"]["wl:ai:2026-08-01:try:0"]["seenAt"]')" = "$T6" ] \
  && ok "each item carries seenAt from the export" || bad "seenAt missing: $(jget "$s" 'd["items"]')"
grep -q '1 new, 0 updated, 0 retained' <<<"$OUT" \
  && ok "reports new / updated / retained" || bad "report line: $OUT"
grep -q 'day(s) old' <<<"$OUT" && ok "reports export age in days" || bad "no age: $OUT"

# 2. A newer exportedAt wins, and untouched keys survive the merge.
write_export "$WORK/cwd/kickoff-signals-2026-08-03.json" "$T5" 2 \
  '{ "wl:ai:2026-08-01:try:0": { "starred": false, "status": "archived" },
     "wl:tech:2026-08-02:try:1": { "starred": true } }'
run_signals "$d" "$WORK/cwd/kickoff-signals-2026-08-03.json"
[ "$RC" = 0 ] && [ "$(jget "$s" 'd["items"]["wl:ai:2026-08-01:try:0"]["status"]')" = archived ] \
  && ok "newer exportedAt overwrites the held value" || bad "newer: rc=$RC out=$OUT"
grep -q '1 new, 1 updated, 0 retained' <<<"$OUT" \
  && ok "counts one new and one updated" || bad "counts: $OUT"

# 3. An OLDER export must not overwrite what is already held.
write_export "$WORK/cwd/kickoff-signals-2026-08-01.json" "$T7" 2 \
  '{ "wl:ai:2026-08-01:try:0": { "starred": true, "status": "stale" } }'
run_signals "$d" "$WORK/cwd/kickoff-signals-2026-08-01.json"
[ "$RC" = 0 ] && [ "$(jget "$s" 'd["items"]["wl:ai:2026-08-01:try:0"]["status"]')" = archived ] \
  && ok "older exportedAt does not overwrite" || bad "older won: $(jget "$s" 'd["items"]')"
grep -q '0 new, 0 updated, 2 retained' <<<"$OUT" \
  && ok "an all-stale import retains everything" || bad "retain counts: $OUT"

# 4. A key the import never mentions is retained. Absence means "another
#    browser", never "unstarred".
[ "$(jget "$s" 'd["items"]["wl:tech:2026-08-02:try:1"]["starred"]')" = True ] \
  && ok "keys absent from the import survive" || bad "absent key lost: $(jget "$s" 'd["items"]')"

# 5. ISO-8601 with offsets orders by instant, not by string. 09:00-04:00 is
#    13:00Z — LATER than 12:00+00:00, yet it sorts EARLIER as text. A
#    lexicographic merge gets both of the next two cases backwards.
LATER_INSTANT="$(ago 4 09:00:00)"    # 13:00Z, sorts low
EARLIER_INSTANT="${D4}T12:00:00+00:00"  # 12:00Z, sorts high

fresh_env; d="$(new_studio offsets_a)"; s="$(sig_of "$d")"
write_export "$WORK/cwd/a1.json" "$LATER_INSTANT"   2 "{ \"$KA\": { \"status\": \"later\" } }"
write_export "$WORK/cwd/a2.json" "$EARLIER_INSTANT" 2 "{ \"$KA\": { \"status\": \"earlier\" } }"
run_signals "$d" "$WORK/cwd/a1.json"
run_signals "$d" "$WORK/cwd/a2.json"
[ "$(jget "$s" "d['items']['$KA']['status']")" = later ] \
  && ok "a string-greater but instant-older export does not overwrite" \
  || bad "offset order: got $(jget "$s" "d['items']['$KA']")"

fresh_env; d="$(new_studio offsets_b)"; s="$(sig_of "$d")"
write_export "$WORK/cwd/b1.json" "$EARLIER_INSTANT" 2 "{ \"$KA\": { \"status\": \"earlier\" } }"
write_export "$WORK/cwd/b2.json" "$LATER_INSTANT"   2 "{ \"$KA\": { \"status\": \"later\" } }"
run_signals "$d" "$WORK/cwd/b1.json"
run_signals "$d" "$WORK/cwd/b2.json"
[ "$(jget "$s" "d['items']['$KA']['status']")" = later ] \
  && ok "a string-lesser but instant-newer export does overwrite" \
  || bad "offset order (reverse): got $(jget "$s" "d['items']['$KA']")"

# 6. Newest of several in a Downloads-like directory, by mtime.
fresh_env; d="$(new_studio newest)"; s="$(sig_of "$d")"
write_export "$WORK/home/Downloads/kickoff-signals-2026-08-01.json" "$T7" 2 "{ \"$KA\": {} }"
write_export "$WORK/home/Downloads/kickoff-signals-2026-08-05.json" "$T3" 2 "{ \"$KC\": {} }"
write_export "$WORK/home/Downloads/kickoff-signals-2026-08-03.json" "$T5B" 2 "{ \"$KB\": {} }"
touch -t 202608010800 "$WORK/home/Downloads/kickoff-signals-2026-08-01.json"
touch -t 202608030800 "$WORK/home/Downloads/kickoff-signals-2026-08-03.json"
touch -t 202608050800 "$WORK/home/Downloads/kickoff-signals-2026-08-05.json"
run_signals "$d"
[ "$RC" = 0 ] && [ "$(jget "$s" 'sorted(d["items"])')" = "['$KC']" ] \
  && ok "picks the newest export in ~/Downloads" || bad "newest: rc=$RC items=$(jget "$s" 'sorted(d["items"])')"
[ -f "$WORK/home/Downloads/kickoff-signals-2026-08-01.json" ] \
  && [ -f "$WORK/home/Downloads/kickoff-signals-2026-08-03.json" ] \
  && ok "the exports it did not take are left alone" || bad "other exports disturbed"

# 7. The source is moved out of the way, and exactly one commit is made.
fresh_env; d="$(new_studio moved)"; s="$(sig_of "$d")"
src="$WORK/home/Downloads/kickoff-signals-2026-08-06.json"
write_export "$src" "$T2" 2 '{ "wl:ai:2026-08-06:try:0": { "starred": true } }'
before="$(commits_in "$d")"
run_signals "$d"
[ "$RC" = 0 ] && [ ! -e "$src" ] && ok "source is removed from its original path" || bad "source not moved"
moved="$(ls "$d/state/.imported" 2>/dev/null | tr '\n' ' ')"
grep -q 'kickoff-signals-2026-08-06.json' <<<"$moved" \
  && ok "raw export retained in state/.imported/ ($moved)" || bad ".imported: [$moved]"
[ "$(commits_in "$d")" = $((before + 1)) ] \
  && ok "exactly one commit" || bad "commits: $before -> $(commits_in "$d")"
files="$(git -C "$d" show --name-only --format= HEAD | tr '\n' ' ')"
[ -z "$(tr ' ' '\n' <<<"$files" | grep -v '^state/' | grep -v '^$')" ] \
  && ok "commit contains only state/" || bad "commit leaked: [$files]"
[ "$(git -C "$d" rev-parse main)" = "$(git -C "$d" rev-parse origin/main)" ] \
  && ok "pushed to origin/main" || bad "not pushed"

# 8. Nothing to import -> error naming every location searched, and no store.
#    An empty snapshot that looks healthy is the failure this epic prevents.
fresh_env; d="$(new_studio noexport)"; s="$(sig_of "$d")"
run_signals "$d"
[ "$RC" != 0 ] && [ ! -e "$s" ] \
  && ok "no export found errors and writes nothing" || bad "noexport: rc=$RC"
grep -q "$WORK/home/Downloads" <<<"$OUT" && grep -q "$WORK/cwd" <<<"$OUT" \
  && ok "error names every location searched" || bad "locations not named: $OUT"

# An explicit path that does not exist fails the same way.
run_signals "$d" "$WORK/cwd/absent.json"
[ "$RC" != 0 ] && [ ! -e "$s" ] && grep -q 'no such export' <<<"$OUT" \
  && ok "a named export that is missing errors and writes nothing" || bad "explicit missing: rc=$RC"

# 9. Malformed JSON leaves the store byte-identical and the source in place.
fresh_env; d="$(new_studio malformed)"; s="$(sig_of "$d")"
write_export "$WORK/cwd/good.json" "$T2" 2 '{ "wl:ai:2026-08-06:try:0": { "starred": true } }'
run_signals "$d" "$WORK/cwd/good.json"
cp "$s" "$WORK/before.json"
before="$(commits_in "$d")"
printf '{ "schema": 2, "exportedAt": "$T1", "items": { oops\n' > "$WORK/cwd/bad.json"
run_signals "$d" "$WORK/cwd/bad.json"
[ "$RC" != 0 ] && cmp -s "$s" "$WORK/before.json" \
  && ok "malformed JSON leaves signals.json byte-identical" || bad "malformed: rc=$RC store changed"
[ -f "$WORK/cwd/bad.json" ] && [ "$(commits_in "$d")" = "$before" ] \
  && ok "malformed JSON is not moved and makes no commit" || bad "malformed side effects"
grep -q 'not valid JSON' <<<"$OUT" && ok "malformed JSON is named as such" || bad "message: $OUT"

# 10. A schema this build does not speak is rejected, naming what it found.
write_export "$WORK/cwd/schema1.json" "$T1" 1 "{ \"$KA\": {} }"
run_signals "$d" "$WORK/cwd/schema1.json"
[ "$RC" != 0 ] && cmp -s "$s" "$WORK/before.json" \
  && ok "wrong schema rejected, store untouched" || bad "schema: rc=$RC"
grep -q 'declares schema 1' <<<"$OUT" && grep -q 'expected 2' <<<"$OUT" \
  && ok "rejection names the schema it found" || bad "schema message: $OUT"

# 11. An export carrying nothing is refused rather than written through.
write_export "$WORK/cwd/empty.json" "$T1" 2 '{}'
run_signals "$d" "$WORK/cwd/empty.json"
[ "$RC" != 0 ] && cmp -s "$s" "$WORK/before.json" && [ -f "$WORK/cwd/empty.json" ] \
  && ok "a zero-item export is refused, not written through" || bad "empty export: rc=$RC"

# 12. A stamp with no offset cannot be ordered, so it is refused up front.
write_export "$WORK/cwd/naive.json" "${D1}T08:00:00" 2 "{ \"$KA\": {} }"
run_signals "$d" "$WORK/cwd/naive.json"
[ "$RC" != 0 ] && cmp -s "$s" "$WORK/before.json" && grep -q 'no UTC offset' <<<"$OUT" \
  && ok "an exportedAt with no offset is refused" || bad "naive stamp: rc=$RC out=$OUT"

# 13. A first import into a studio that already holds a corrupt store must not
#     paper over it.
fresh_env; d="$(new_studio corruptstore)"; s="$(sig_of "$d")"
printf 'not json at all\n' > "$s"
write_export "$WORK/cwd/ok.json" "$T1" 2 "{ \"$KA\": { \"starred\": true } }"
run_signals "$d" "$WORK/cwd/ok.json"
[ "$RC" != 0 ] && [ "$(cat "$s")" = "not json at all" ] && [ -f "$WORK/cwd/ok.json" ] \
  && ok "a corrupt store is reported, never merged over" || bad "corrupt store: rc=$RC"

echo
[ "$FAIL" = "0" ] && echo "kickoff signals tests passed" || echo "kickoff signals tests FAILED"
exit "$FAIL"
