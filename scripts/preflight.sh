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
for s in scripts/*.sh scripts/lib/*.sh scripts/studio/kickoff; do
  [ -f "$s" ] || continue
  bash -n "$s" 2>/dev/null && ok "$s" || bad "$s"
done

echo "prompts"
if grep -rlE '(^|[^A-Za-z_])TODAY([^A-Za-z_]|$)' scripts/prompts/ >/dev/null 2>&1; then
  bad "bare TODAY token: $(grep -rlE '(^|[^A-Za-z_])TODAY([^A-Za-z_]|$)' scripts/prompts/ | tr '\n' ' ')"
else
  ok "no bare TODAY tokens"
fi
for cfg in scripts/topics/*.yaml; do
  [ -f "$cfg" ] || continue
  job="$(basename "$cfg" .yaml)"
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
