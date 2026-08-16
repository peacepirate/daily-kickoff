#!/bin/bash
# D1 — a malformed edition must not outlive the night that produced it.
#
#   bash scripts/tests/test-feed-quarantine.sh
#
# Astro validates the WHOLE editions collection on every build. Verified by
# experiment before this was written: an edition whose `count` disagrees with
# its `items` fails the build; adding a perfectly valid edition the next night
# fails again, still naming the OLD file; removing only the bad file builds
# clean. Meanwhile `mark_feed_published` is gated on the publish succeeding, so
# every stalled night also leaves the ledger unwritten and the pool re-offering
# the same items.
#
# The properties under test, in order of what they cost when wrong:
#
#   a committed edition is never moved      published output deleted to make a
#                                           build pass
#   the date comes from the validator       the wrong file quarantined, and the
#                                           real culprit left in place
#   Astro's real wording still matches      a guard that stops firing silently
#                                           on an Astro upgrade
#   a non-schema failure moves nothing      a good edition thrown away because
#                                           the contrast checker failed
#
# No network, no npm, no Astro, no writes outside $TMPDIR. quarantine_bad_edition
# is a pure function of (dir, date, verify log), which is why it can be tested
# without building a site.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

FAIL=0
COUNT=0
ok()  { COUNT=$((COUNT+1)); printf "  \033[32mok\033[0m    %s\n" "$1"; }
bad() { COUNT=$((COUNT+1)); FAIL=1; printf "  \033[31mFAIL\033[0m  %s\n" "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }

TMP="$(mktemp -d -t feedquar)"
trap 'rm -rf "$TMP"' EXIT

export KICKOFF_LIB_REPO_DIR="$REPO_DIR"
LOG_FILE="$TMP/log"
. "$REPO_DIR/scripts/lib/job-config.sh"

echo "feed edition quarantine"

# A throwaway feed site: a real git repo, because rule 2 asks git whether an
# edition is tracked and a stub would not answer.
new_site() {  # -> prints the dir
  local d="$TMP/site-$RANDOM"
  mkdir -p "$d/src/content/editions"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" config user.email "test@example.invalid"
  git -C "$d" config user.name  "test"
  printf '{}\n' > "$d/src/content/editions/2026-08-01.json"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -qm "seed" >/dev/null 2>&1
  echo "$d"
}

# The real thing, captured from `npx astro build` against an edition whose
# `count` said 3 and whose `items` held 1. Recorded rather than paraphrased:
# this fixture is the only reason the grep in quarantine_bad_edition can be
# trusted to still match after an Astro upgrade.
astro_error_log() {  # DATE -> writes a verify log
  cat > "$2" <<EOF
> daily-kickoff-feed@0.0.1 verify
> node scripts/check-config.mjs && astro build && node scripts/check-links.mjs

22:49:28 [vite] Re-optimizing dependencies because vite config has changed
22:49:29 [content] Syncing content
[InvalidContentEntryDataError] editions → $1 data does not match collection schema.

  ****: count is 3 but there are 1 items

  Hint:
    See https://docs.astro.build/en/guides/content-collections/ for more information on content schemas.
  Error reference:
    https://docs.astro.build/en/reference/errors/invalid-content-entry-data-error/
  Location:
    /x/src/content/editions/$1.json:0:0
EOF
}

echo "── an untracked malformed edition is moved out of the content glob ───────"

SITE="$(new_site)"
printf '{"count":3}\n' > "$SITE/src/content/editions/2026-08-13.json"
astro_error_log 2026-08-13 "$TMP/v1.log"
quarantine_bad_edition "$SITE" "2026-08-13" "$TMP/v1.log" >/dev/null 2>&1

chk "the edition left src/content/editions/" \
  "$([ -f "$SITE/src/content/editions/2026-08-13.json" ] && echo present || echo gone)" "gone"
chk "...and landed in quarantine/" \
  "$([ -f "$SITE/quarantine/2026-08-13.json" ] && echo present || echo gone)" "present"
# Evaluated out here: a `case` inside $( ) trips the parser on its own `)`.
case "$SITE/quarantine" in
  "$SITE/src/content"*) GLOB_POS=inside ;;
  *)                    GLOB_POS=outside ;;
esac
chk "quarantine/ is outside the Astro content glob" "$GLOB_POS" "outside"
chk "the file's contents survived the move — it is recoverable, not lost" \
  "$(cat "$SITE/quarantine/2026-08-13.json")" '{"count":3}'

echo "── a COMMITTED edition is never moved, even when it is the bad one ───────"

SITE="$(new_site)"
printf '{"count":3}\n' > "$SITE/src/content/editions/2026-08-13.json"
git -C "$SITE" add -A >/dev/null 2>&1
git -C "$SITE" commit -qm "publish 08-13" >/dev/null 2>&1
astro_error_log 2026-08-13 "$TMP/v2.log"
quarantine_bad_edition "$SITE" "2026-08-13" "$TMP/v2.log" >/dev/null 2>&1

chk "a tracked edition stays where it is" \
  "$([ -f "$SITE/src/content/editions/2026-08-13.json" ] && echo present || echo gone)" "present"
chk "...and nothing was written to quarantine/" \
  "$([ -e "$SITE/quarantine/2026-08-13.json" ] && echo present || echo gone)" "gone"

echo "── the date comes from the validator, not from tonight's date ────────────"

# The case the whole design turns on: tonight's edition is fine, an earlier one
# is not. Quarantining "tonight's" would throw away good output and leave the
# real culprit in place, so the build would still fail tomorrow.
SITE="$(new_site)"
printf '{"count":3}\n'      > "$SITE/src/content/editions/2026-08-13.json"
printf '{"count":1,"ok":1}\n' > "$SITE/src/content/editions/2026-08-14.json"
astro_error_log 2026-08-13 "$TMP/v3.log"
quarantine_bad_edition "$SITE" "2026-08-14" "$TMP/v3.log" >/dev/null 2>&1

chk "the edition the validator named was moved" \
  "$([ -f "$SITE/quarantine/2026-08-13.json" ] && echo present || echo gone)" "present"
chk "tonight's healthy edition was left alone" \
  "$([ -f "$SITE/src/content/editions/2026-08-14.json" ] && echo present || echo gone)" "present"
chk "...and was not quarantined" \
  "$([ -e "$SITE/quarantine/2026-08-14.json" ] && echo present || echo gone)" "gone"

echo "── a build failure that names no edition quarantines nothing ─────────────"

SITE="$(new_site)"
printf '{"count":1}\n' > "$SITE/src/content/editions/2026-08-13.json"
cat > "$TMP/v4.log" <<'EOF'
contrast check
  FAIL  muted|surface 4.31 — below the 4.5 floor
contrast check FAILED
EOF
quarantine_bad_edition "$SITE" "2026-08-13" "$TMP/v4.log" >/dev/null 2>&1

chk "a contrast failure leaves the edition in place" \
  "$([ -f "$SITE/src/content/editions/2026-08-13.json" ] && echo present || echo gone)" "present"
chk "...and creates no quarantine directory" \
  "$([ -d "$SITE/quarantine" ] && echo present || echo gone)" "gone"

echo "── multiple malformed editions are all moved ─────────────────────────────"

SITE="$(new_site)"
printf '{"a":1}\n' > "$SITE/src/content/editions/2026-08-13.json"
printf '{"b":1}\n' > "$SITE/src/content/editions/2026-08-15.json"
{ astro_error_log 2026-08-13 /dev/stdout; astro_error_log 2026-08-15 /dev/stdout; } > "$TMP/v5.log" 2>&1
quarantine_bad_edition "$SITE" "2026-08-15" "$TMP/v5.log" >/dev/null 2>&1

chk "first named edition moved"  "$([ -f "$SITE/quarantine/2026-08-13.json" ] && echo y || echo n)" "y"
chk "second named edition moved" "$([ -f "$SITE/quarantine/2026-08-15.json" ] && echo y || echo n)" "y"

echo "── the wiring, through publish_feed_site itself ──────────────────────────"

# quarantine_bad_edition being correct is not the same as it being CALLED with
# the validator's output. D3 in this same batch of work proved the distinction
# the hard way: the unit test stayed green while the one-line wiring that fed it
# was reverted. So this drives the real function, with a package.json whose
# `verify` fails the way Astro fails.
if command -v npm >/dev/null 2>&1; then
  SITE="$(new_site)"
  mkdir -p "$SITE/scripts" "$SITE/node_modules"
  cat > "$SITE/package.json" <<'JSON'
{
  "name": "fake-feed-site",
  "scripts": {
    "verify": "echo '[InvalidContentEntryDataError] editions → 2026-08-13 data does not match collection schema.' && exit 1"
  }
}
JSON
  printf '{"count":3}\n' > "$SITE/src/content/editions/2026-08-13.json"

  publish_feed_site "$SITE" "2026-08-13" >/dev/null 2>&1
  PF_RC=$?

  chk "publish_feed_site reports failure" "$PF_RC" "1"
  chk "...and the malformed edition was moved out of the content glob" \
    "$([ -f "$SITE/src/content/editions/2026-08-13.json" ] && echo present || echo gone)" "gone"
  chk "...into quarantine/" \
    "$([ -f "$SITE/quarantine/2026-08-13.json" ] && echo present || echo gone)" "present"

  # The other half of the contract: a night that verifies cleanly must not
  # quarantine anything. Without this, "always move it" would pass everything
  # above.
  SITE="$(new_site)"
  mkdir -p "$SITE/scripts" "$SITE/node_modules"
  cat > "$SITE/package.json" <<'JSON'
{ "name": "fake-feed-site", "scripts": { "verify": "echo ok" } }
JSON
  printf '{"count":1}\n' > "$SITE/src/content/editions/2026-08-13.json"
  mkdir -p "$SITE/dist"
  publish_feed_site "$SITE" "2026-08-13" >/dev/null 2>&1
  chk "a clean verify leaves the edition in place" \
    "$([ -f "$SITE/src/content/editions/2026-08-13.json" ] && echo present || echo gone)" "present"
  chk "...and creates no quarantine directory" \
    "$([ -d "$SITE/quarantine" ] && echo present || echo gone)" "gone"
else
  printf "  \033[33mskip\033[0m  npm unavailable — publish_feed_site wiring not exercised\n"
fi

echo "── the message the grep depends on is the message Astro prints ───────────"

# If Astro changes this wording, the guard stops firing and nothing else in the
# suite would notice. Asserted against the recorded fixture above, and stated
# here so the failure reads as "Astro changed its error" rather than as a bug.
astro_error_log 2026-08-13 "$TMP/v6.log"
chk "the phrase the extractor anchors on is present" \
  "$(grep -c 'does not match collection schema' "$TMP/v6.log")" "1"
chk "the date is on that same line" \
  "$(grep 'does not match collection schema' "$TMP/v6.log" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')" "2026-08-13"

echo
if [ "$FAIL" -eq 0 ]; then
  printf "\033[32mfeed quarantine ok\033[0m  — %d assertions\n" "$COUNT"
else
  printf "\033[31mfeed quarantine FAILED\033[0m  — %d assertions\n" "$COUNT"
fi
exit "$FAIL"
