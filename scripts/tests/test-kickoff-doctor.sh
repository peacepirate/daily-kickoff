#!/bin/bash
# Regression test for `kickoff doctor`.
#
# doctor is the surface that makes signal staleness visible. If it reports
# healthy while the store is stale, corrupt, or empty, Epic 3 ranks on a picture
# of what mattered to you from weeks ago and nothing says so — which is the
# failure mode this whole epic exists to prevent.
#
# Hermetic: scratch STUDIO_DIR only, no network, never touches the real studio.
#
#   bash scripts/tests/test-kickoff-doctor.sh

set -uo pipefail
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KICKOFF="$REPO_DIR/scripts/studio/kickoff"

FAIL=0
ok()  { printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad() { printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

new_studio() {  # NAME -> path
  local d="$WORK/$1"
  mkdir -p "$d"/{notes,angles,drafts,published,engagement,state}
  echo "$d"
}

# BSD date: offset days from now, in the signals stamp format.
# Note the precision split, which is deliberate and must not be "harmonised"
# without updating both readers: signals stamps carry seconds (the site writes
# exportedAt from a Date), note headers carry only minutes (kickoff note writes
# them from `date '+...%H:%M %z'`). NOTE_HEADER_RE will not match a stamp with
# seconds in it.
stamp_days_ago() { date -j -v"-${1}d" '+%Y-%m-%dT%H:%M:%S%z' | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/'; }

signals_with_age() {  # STUDIO DAYS_AGO
  local s; s="$(stamp_days_ago "$2")"
  cat > "$1/state/signals.json" <<EOF
{ "schema": 2, "mergedAt": "$s",
  "items": { "wl:ai:2026-08-01:try:0": { "starred": true, "seenAt": "$s" },
             "wl:tech:2026-08-01:try:0": { "note": "x", "seenAt": "$s" } } }
EOF
}

run_doctor() { OUT="$(STUDIO_DIR="$1" bash "$KICKOFF" doctor 2>&1)" && RC=0 || RC=$?; }

echo "kickoff doctor"

# 1. Empty studio: no signals at all is a finding, not a clean bill of health.
d="$(new_studio empty)"; run_doctor "$d"
[ "$RC" = 1 ] && grep -q "none yet" <<<"$OUT" \
  && ok "no signals store reports and exits non-zero" || bad "empty: rc=$RC"

# 2. Fresh signals + a resolving note link: clean, exit 0. (F17 — doctor used to
#    always exit 0, so it could never be used in a check script.)
d="$(new_studio fresh)"; signals_with_age "$d" 0
printf '# Notes — 2026-08\n\n## 2026-08-02T10:00-04:00 #x → leadership/2026-08-01\nbody\n' \
  > "$d/notes/2026-08.md"
run_doctor "$d"
[ "$RC" = 0 ] && ok "healthy studio exits 0" || { bad "healthy: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/        /'; }
grep -q "2 key(s), 1 starred, 1 noted" <<<"$OUT" \
  && ok "counts keys, starred and noted separately" || bad "counts wrong"
grep -q "1 file(s), 1 entr(ies)" <<<"$OUT" && ok "counts note entries, not just files" || bad "note count wrong"
grep -q "all resolve" <<<"$OUT" && ok "resolving note link passes" || bad "link check wrong"

# 3. Stale store: the whole point of the command.
d="$(new_studio stale)"; signals_with_age "$d" 9; run_doctor "$d"
[ "$RC" = 1 ] && grep -q "STALE" <<<"$OUT" && ok "9-day-old signals flagged stale (rc 1)" || bad "stale: rc=$RC"

# 4. Threshold is exactly 7, and matches the site's elevation point.
d="$(new_studio day6)"; signals_with_age "$d" 6; run_doctor "$d"
[ "$RC" = 0 ] && ok "6 days is not yet stale" || bad "day6: rc=$RC"
d="$(new_studio day7)"; signals_with_age "$d" 7; run_doctor "$d"
[ "$RC" = 1 ] && ok "7 days is stale — same threshold the site elevates at" || bad "day7: rc=$RC"

# 5. Corrupt store must be named, never silently treated as empty.
d="$(new_studio corrupt)"; echo '{not json' > "$d/state/signals.json"; run_doctor "$d"
[ "$RC" = 1 ] && grep -q "CORRUPT" <<<"$OUT" && ok "corrupt store is reported (rc 1)" || bad "corrupt: rc=$RC"

# 6. A dangling --link gives its digest no ranking boost, silently. Capture
#    deliberately never fails on one, so doctor is where they must surface.
d="$(new_studio dangling)"; signals_with_age "$d" 0
printf '## 2026-08-02T10:00-04:00 → ai/1999-01-01\nbody\n' > "$d/notes/2026-08.md"
run_doctor "$d"
[ "$RC" = 1 ] && grep -q "dangling: ai/1999-01-01" <<<"$OUT" \
  && ok "dangling note link is named (rc 1)" || bad "dangling: rc=$RC"

# 7. notes/.imported/ is archive, not notes. Counting it would inflate the one
#    number that says whether capture is actually happening.
d="$(new_studio imported)"; signals_with_age "$d" 0
mkdir -p "$d/notes/.imported"
printf '## 2026-08-02T10:00-04:00\nreal\n' > "$d/notes/2026-08.md"
printf 'raw import source\n' > "$d/notes/.imported/2026-08-01-phone.md"
run_doctor "$d"
grep -q "1 file(s)" <<<"$OUT" && ok "notes/.imported/ excluded from the note count" \
  || bad "imported archive counted as notes"

# 8. A store whose items carry no seenAt cannot be aged — say so, don't guess.
d="$(new_studio noprov)"
echo '{"schema":2,"items":{"wl:ai:2026-08-01:try:0":{"starred":true}}}' > "$d/state/signals.json"
run_doctor "$d"
[ "$RC" = 1 ] && grep -q "age unknown" <<<"$OUT" \
  && ok "unagable store reports unknown rather than fresh" || bad "noprov: rc=$RC"

echo
[ "$FAIL" = "0" ] && echo "kickoff doctor tests passed" || echo "kickoff doctor tests FAILED"
exit "$FAIL"
