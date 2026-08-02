#!/bin/bash
# Regression test for the watchlist localStorage key schema.
#
# Keys were `wl:<date>:<type>:<i>` — no theme — because entry.id is just the
# date (theme is a separate route param). ai and tech both publish daily, so an
# ai item and a tech item at the same index collided every weekday. Stars are
# the ranking signal Epic 3 consumes, and they are browser-local and
# unrecoverable, so the schema gets a test rather than a code review.
#
# Asserts against the BUILT html, which is the ground truth the browser sees.
#
#   bash scripts/tests/test-watchlist-keys.sh

set -uo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)"

FAIL=0
ok()  { printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad() { printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=1; }

echo "watchlist key schema"

if [ ! -f dist/index.html ]; then
  npx astro build >/tmp/wl-keys-build.log 2>&1 \
    || { bad "astro build failed — see /tmp/wl-keys-build.log"; exit 1; }
fi

python3 - <<'PY'
import re, sys, pathlib

html = pathlib.Path("dist/index.html").read_text()
# One capture per rendered row: its key and the theme the row declares.
rows = re.findall(
    r'<div class="watchlist-item"\s+data-wl-id="([^"]+)"[^>]*?data-theme-id="([^"]+)"',
    html,
)
themes = {"ai", "leadership", "rva-events", "tech"}   # mirrors src/content.config.ts
fails = []

def check(cond, msg):
    print(("  \033[32mok\033[0m    " if cond else "  \033[31mFAIL\033[0m  ") + msg)
    if not cond:
        fails.append(msg)

check(len(rows) > 0, f"found {len(rows)} rendered watchlist rows")

# The defect itself: two rows must never share a key.
dupes = {k for k, _ in rows if [x for x, _ in rows].count(k) > 1}
check(not dupes, f"every rendered key is unique ({len(set(k for k, _ in rows))} keys)"
                 + (f" — collisions: {sorted(dupes)[:3]}" if dupes else ""))

bad_shape = [k for k, _ in rows if len(k.split(":")) != 5]
check(not bad_shape, "every key is wl:<theme>:<date>:<type>:<i> (5 parts)"
                     + (f" — got {bad_shape[:3]}" if bad_shape else ""))

bad_theme = [k for k, _ in rows if k.split(":")[1] not in themes]
check(not bad_theme, "key theme is a declared collection"
                     + (f" — got {bad_theme[:3]}" if bad_theme else ""))

bad_date = [k for k, _ in rows if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", k.split(":")[2])]
check(not bad_date, "key date is ISO YYYY-MM-DD at parts[2]"
                    + (f" — got {bad_date[:3]}" if bad_date else ""))

# If these ever disagree the row would read another theme's state.
mismatch = [k for k, t in rows if k.split(":")[1] != t]
check(not mismatch, "key theme matches the row's data-theme-id"
                    + (f" — got {mismatch[:3]}" if mismatch else ""))

sys.exit(1 if fails else 0)
PY
[ $? = 0 ] || FAIL=1

# Consumers of the key space must agree with the schema above. These are greps,
# not behaviour tests, but each guards a silent failure: auto-archive reading
# the wrong part stops archiving with no symptom, and the other two miscount or
# cross-contaminate themes.
grep -q "parts.length < 5" src/pages/index.astro \
  && grep -q "parts\[2\]" src/pages/index.astro \
  && ok "auto-archive reads the date at parts[2] behind a 5-part guard" \
  || bad "auto-archive still assumes the pre-theme key layout"

grep -q "key.split(':').length !== 5" src/layouts/Layout.astro \
  && ok "sidebar count ignores wl:meta:* and retained legacy keys" \
  || bad "sidebar count would double-count legacy keys and wl:meta:key-schema"

grep -q 'wl:${theme}:${slug}:' src/pages/\[theme\]/\[slug\].astro \
  && ok "mark-all-read is scoped to one theme" \
  || bad "mark-all-read would mark other themes' items for the same date done"

echo
[ "$FAIL" = "0" ] && echo "watchlist key tests passed" || echo "watchlist key tests FAILED"
exit "$FAIL"
