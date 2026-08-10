#!/bin/bash
# Wave 1, S4.1 and S4.5 — the `fetch` job step, and the output boundary.
#
# Two changes are checked here.
#
# S4.5: `step: fetch` runs the producer and stops. No prompt, no model call, no
# output file. Both runner tiers previously rejected a config that omitted
# prompt: or output:, which made a fetch-only source pool inexpressible — and
# that pool is the launch gate for the public feed.
#
# S4.1: assert_output_boundary used to read `[ "$1" = "generators" ] || return 0`
# — fail-OPEN for every other kind. A topic job was unconstrained, and any new
# kind would inherit no boundary at all while appearing checked. A guard whose
# default is "allowed" is this project's recurring failure class, so the default
# now refuses and each kind states its own root.
#
# No network, no LLM, no writes outside $TMPDIR, no git writes anywhere.
#
#   bash scripts/tests/test-fetch-step.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_DIR/scripts/lib/job-config.sh"
PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

FAIL=0
COUNT=0
ok()  { COUNT=$((COUNT + 1)); printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad() { COUNT=$((COUNT + 1)); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=1; }
chk() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (exit $2, wanted $3)"; }

echo "── the step vocabulary ───────────────────────────────────────────────────"
step_known() { ( . "$LIB" >/dev/null 2>&1; is_known_step "$1" ) >/dev/null 2>&1; }
step_known llm;      chk "'llm' is a known step"    $? 0
step_known fetch;    chk "'fetch' is a known step"  $? 0
step_known publish;  chk "an unknown step is rejected, not assumed"  $? 1
step_known "";       chk "an empty step is rejected"                 $? 1

echo "── the output boundary fails closed ──────────────────────────────────────"
bnd() { ( . "$LIB" >/dev/null 2>&1; STUDIO_DIR="/tmp/fake-studio" assert_output_boundary "$1" "$2" ) >/dev/null 2>&1; }

bnd topics "$REPO_DIR/src/content/ai/2026-08-08.md"
chk "a topic writing into src/content/ is allowed" $? 0
bnd topics "$REPO_DIR/scripts/logs/sneaky.md"
chk "a topic writing outside src/content/ is refused" $? 1
bnd topics "/etc/passwd"
chk "a topic writing to an absolute path elsewhere is refused" $? 1

bnd generators "/tmp/fake-studio/angles/2026-W32.md"
chk "a generator writing into the studio is allowed" $? 0
bnd generators "$REPO_DIR/src/content/ai/x.md"
chk "a generator writing into the public repo is refused" $? 1
bnd generators "/tmp/fake-studio/../daily-kickoff/site/src/content/ai/x.md"
chk "a '..' segment is refused rather than normalised" $? 1

# The fix itself. Before this, any kind but 'generators' returned 0 — so this
# case passed, and so would every future job kind.
bnd feeds "/anywhere/at/all.md"
chk "an unknown job kind is REFUSED, not waved through" $? 1
bnd "" "/anywhere/at/all.md"
chk "an empty job kind is refused" $? 1

echo "── run-job.sh enforces the fetch contract ────────────────────────────────"
# Asserted by reading the file: exercising it needs a config inside the real
# scripts/topics/, and the producer would hit the network.
RJ="$REPO_DIR/scripts/run-job.sh"
grep -q 'is_known_step' "$RJ" \
  && ok "run-job.sh validates the step against the vocabulary" \
  || bad "run-job.sh does not validate step:"
grep -q 'it must declare neither prompt: nor output:' "$RJ" \
  && ok "run-job.sh refuses a fetch config that declares prompt: or output:" \
  || bad "run-job.sh accepts a fetch config with a prompt or output"
grep -q 'step: fetch and must declare producer:' "$RJ" \
  && ok "run-job.sh requires producer: on a fetch config" \
  || bad "run-job.sh does not require producer: on a fetch config"

echo "── run-jobs.sh still gates fetch jobs on their schedule ──────────────────"
RJS="$REPO_DIR/scripts/run-jobs.sh"
sched_line="$(grep -n 'job_scheduled_today' "$RJS" | head -1 | cut -d: -f1)"
fetch_line="$(grep -n 'step: fetch)' "$RJS" | head -1 | cut -d: -f1)"
if [ -z "$sched_line" ] || [ -z "$fetch_line" ]; then
  bad "could not locate the schedule gate or the fetch branch in run-jobs.sh"
elif [ "$sched_line" -lt "$fetch_line" ]; then
  ok "the fetch branch sits after the schedule gate (line $fetch_line after $sched_line)"
else
  bad "the fetch branch runs BEFORE the schedule gate — a fetch job would ignore schedule:"
fi

echo "── feed.yaml is a valid fetch config ─────────────────────────────────────"
# Resolved through find_job_config rather than hard-coded, so moving the
# config between job kinds cannot silently skip this whole section.
FEED="$(KICKOFF_LIB_REPO_DIR="$REPO_DIR"; . "$REPO_DIR/scripts/lib/job-config.sh" >/dev/null 2>&1; find_job_config feed)"
if [ ! -f "$FEED" ]; then
  bad "the feed pool config is missing (find_job_config feed found nothing)"
else
  "$PYBIN" - "$FEED" <<'PY' && ok "feed.yaml: step fetch, no prompt, no output, sources present" \
                            || bad "feed.yaml failed its own contract — see above"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d.get("step") == "fetch", f"step is {d.get('step')!r}, expected 'fetch'"
assert "prompt" not in d, "a fetch config must not declare prompt:"
assert "output" not in d, "a fetch config must not declare output:"
assert d.get("schedule") in ("daily", "weekdays", "saturday", "sunday"), \
    f"unknown schedule {d.get('schedule')!r}"
n = sum(len(v) for v in d["sources"].values())
assert n >= 20, f"only {n} sources — the pool exists to be large"
urls = [s["url"] for v in d["sources"].values() for s in v]
assert len(urls) == len(set(urls)), "a url is listed twice"
kinds = {s.get("kind") for v in d["sources"].values() for s in v}
assert kinds == {"rss"}, f"non-rss kinds present: {kinds - {'rss'}} — the pool was measured on rss only"
PY
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf "\033[32mPASS\033[0m (%d) — fetch step tests passed\n" "$COUNT"
else
  printf "\033[31mFAIL\033[0m — fetch step tests FAILED (%d assertions run)\n" "$COUNT"
fi
exit "$FAIL"
