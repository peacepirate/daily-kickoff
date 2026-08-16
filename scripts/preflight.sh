#!/bin/bash
# Pre-commit checks for the digest pipeline. Read-only: no network, no git writes.
#
#   bash scripts/preflight.sh

set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

FAIL=0
ok()   { printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad()  { printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=1; }

echo "shell syntax"
for s in scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh scripts/studio/kickoff; do
  [ -f "$s" ] || continue
  bash -n "$s" 2>/dev/null && ok "$s" || bad "$s"
done

echo "unit tests (scratch repos only — no network, no git writes here)"
for t in scripts/tests/test-*.sh; do
  [ -f "$t" ] || continue
  if out="$(bash "$t" 2>&1)"; then ok "$(basename "$t")"
  else bad "$(basename "$t")"; printf '%s\n' "$out" | sed 's/^/        /'; fi
done

echo "job configs"
# The producer names the config it reads, and nothing ever checked that the name
# resolved. scripts/topics/feed.yaml became scripts/feed/10-feed.yaml, the
# producer line kept saying `--topic feed`, and the pool fetch failed the next
# morning — while the edition job carried on publishing from a pool that had
# silently stopped growing. Both halves of that are this project's recurring
# shape: a rename with nothing holding the two ends together, and a failure that
# still looks like output.
#
# Every job kind is walked, not just topics/. That is the other half of why the
# rename went unnoticed — the loop below this one reads scripts/topics/*.yaml
# alone, so the feed configs were on no preflight list at all.
#
# Parsed with yaml rather than grep because a producer may be a folded scalar
# (20-edition.yaml is), and `grep '^producer:'` returns ">-" for those.
PY_BIN="scripts/.venv/bin/python3"
if [ ! -x "$PY_BIN" ]; then
  bad "scripts/.venv missing — cannot check producer configs"
else
  while IFS= read -r line; do
    case "$line" in
      OK\ *)  ok   "${line#OK }"  ;;
      BAD\ *) bad  "${line#BAD }" ;;
    esac
  done < <("$PY_BIN" - <<'PY'
import glob, os, re, sys, yaml

for cfg in sorted(glob.glob("scripts/topics/*.yaml")
                  + glob.glob("scripts/feed/*.yaml")
                  + glob.glob("scripts/generators/*.yaml")):
    job = os.path.basename(cfg)[:-5]
    try:
        producer = (yaml.safe_load(open(cfg)) or {}).get("producer") or ""
    except Exception as ex:
        print(f"BAD {job} config does not parse: {ex}")
        continue
    if not producer:
        print(f"BAD {job} declares no producer")
        continue

    m = re.search(r"--config[=\s]+(\S+)", producer)
    if m:
        target = m.group(1)
        print((f"OK {job} producer reads {target}") if os.path.isfile(target)
              else f"BAD {job} producer names a config that does not exist: {target}")
        continue

    m = re.search(r"--topic[=\s]+(\S+)", producer)
    if m:
        target = f"scripts/topics/{m.group(1)}.yaml"
        print((f"OK {job} producer resolves --topic {m.group(1)}") if os.path.isfile(target)
              else f"BAD {job} producer says --topic {m.group(1)} but {target} does not exist")
        continue

    print(f"OK {job} producer takes no config argument ({producer.split()[0]})")
PY
  )
fi

echo "prompts"
if grep -rlE '(^|[^A-Za-z_])TODAY([^A-Za-z_]|$)' scripts/prompts/ >/dev/null 2>&1; then
  bad "bare TODAY token: $(grep -rlE '(^|[^A-Za-z_])TODAY([^A-Za-z_]|$)' scripts/prompts/ | tr '\n' ' ')"
else
  ok "no bare TODAY tokens"
fi
for cfg in scripts/topics/*.yaml; do
  [ -f "$cfg" ] || continue
  job="$(basename "$cfg" .yaml)"
  # A fetch-step config has no prompt and no output, so there is no prompt-names-
  # its-own-output pairing to check. Reported rather than silently skipped: a
  # config that vanishes from a preflight list is a config nobody notices is
  # unchecked.
  if [ "$(grep -E '^step:' "$cfg" | head -1 | sed 's/^step: *//')" = "fetch" ]; then
    ok "$job is step: fetch — no prompt or output to pair"
    continue
  fi
  out="$(grep -E '^output:' "$cfg" | head -1 | sed 's/^output: *//')"
  dir="$(dirname "$out")"
  p="$(grep -E '^prompt:' "$cfg" | head -1 | sed 's/^prompt: *//')"
  if [ -f "$p" ] && grep -q "$dir/" "$p"; then ok "$job prompt writes to $dir/"
  else bad "$job prompt does not name $dir/ (prompt: $p)"; fi
done

echo "content"
stray="$(find src/content -name 'TODAY.md' 2>/dev/null)"
[ -z "$stray" ] && ok "no TODAY.md files" || bad "stray: $stray"
for d in src/content/*/; do
  case "$(basename "$d")" in local-llm|richmond) continue ;; esac   # retired, intentionally kept
  [ -f "$d/.gitkeep" ] && ok "$(basename "$d") has .gitkeep" || bad "$(basename "$d") missing .gitkeep"
done

echo "cleanup dry-run (must delete nothing)"
n="$(bash scripts/cleanup-old-digests.sh 2>/dev/null | grep -cE '^WOULD DELETE' || true)"
[ "$n" = "0" ] && ok "0 digests would be deleted" || bad "$n digests would be deleted"

echo "build"
if npx astro build >/tmp/preflight-build.log 2>&1; then
  ok "$(grep -oE '[0-9]+ page\(s\) built' /tmp/preflight-build.log | tail -1)"
  grep -qiE 'warn' /tmp/preflight-build.log && bad "build emitted warnings" || ok "no warnings"
else
  bad "astro build failed — see /tmp/preflight-build.log"
fi

echo
[ "$FAIL" = "0" ] && echo "preflight passed" || echo "preflight FAILED"
exit "$FAIL"
