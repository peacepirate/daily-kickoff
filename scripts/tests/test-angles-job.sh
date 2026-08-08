#!/bin/bash
# Epic 4, S4.6 and S4.7 — scripts/generators/angles.yaml, scripts/prompts/posts/
# angles.md, and the angles-file format the two of them exist to produce.
#
# Three things are checked, none of which needs an LLM call:
#
#   1. the config declares everything run-job.sh requires, its output resolves
#      to the week's file beneath $STUDIO_DIR, and it is refused if it is ever
#      pointed back into src/content/;
#   2. the prompt names the exact path the job verifies — run-job.sh refuses to
#      invoke Claude otherwise — carries no bare TODAY, and carries nothing that
#      identifies the employer, because this repo is public;
#   3. a hand-written angles file that follows the prompt's stated format
#      satisfies the format contract, and every mutation of it that should be
#      rejected is rejected. The contract checker here is deliberately a second
#      implementation: if it and the runner's `schema: angles` validation
#      disagree, one of them is wrong and this suite is where that shows up.
#
# No network, no LLM, no writes outside $TMPDIR, no git writes anywhere.
#
#   bash scripts/tests/test-angles-job.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_DIR/scripts/lib/job-config.sh"
ANGLES="$REPO_DIR/scripts/generators/angles.yaml"
FIXTURES="$REPO_DIR/scripts/tests/fixtures"
FIXTURE="$FIXTURES/angles-valid-2026-W31.md"          # v1, as Epic 4 shipped it
SCORED="$FIXTURES/angles-valid-2026-W32-scored.md"    # v2, as generated
JUDGED="$FIXTURES/angles-judged-2026-W32.md"          # v2, after a human
V1_JUDGED="$FIXTURES/angles-v1-verdicts-2026-W31.md"  # v1 + verdicts at slot 7

PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

FAIL=0
COUNT=0
ok()   { COUNT=$((COUNT + 1)); printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad()  { COUNT=$((COUNT + 1)); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=1; }
skip() { printf "  \033[33mskip\033[0m  %s\n" "$*"; }

if ! "$PYBIN" -c 'import yaml' 2>/dev/null; then
  echo "angles job"
  skip "pyyaml unavailable in $PYBIN — run any kickoff command once to build scripts/.venv"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A studio with the layout require_studio_dir() insists on, plus the one note
# the fixture cites. Never the real studio: it holds employer-adjacent notes.
STUDIO="$WORK/studio"
for d in notes angles drafts published engagement state; do mkdir -p "$STUDIO/$d"; done
cat > "$STUDIO/notes/2026-07.md" <<'EOF'
# Notes — 2026-07

## 2026-07-29T14:03-04:00 #rollout
Three teams stalled at the same place. Not the tooling.
EOF
cat > "$STUDIO/notes/2026-08.md" <<'EOF'
# Notes — 2026-08

## 2026-08-05T09:12-04:00 #pipeline
The local run looked healthy for days while nothing published.
EOF

# A scratch corpus carrying exactly the digests the fixture cites, so citation
# resolution is hermetic rather than coupled to the real archive.
CONTENT="$WORK/content"
for f in leadership/2026-08-01 leadership/2026-07-25 \
         ai/2026-07-31 ai/2026-07-30 ai/2026-07-28 ai/2026-07-27 \
         ai/2026-07-25 ai/2026-07-22 tech/2026-08-01 tech/2026-07-31 \
         leadership/2026-08-08 leadership/2026-08-05 \
         ai/2026-08-07 ai/2026-08-06 ai/2026-08-04 \
         tech/2026-08-07 tech/2026-08-05; do
  mkdir -p "$CONTENT/$(dirname "$f")"
  printf -- '---\ntitle: "t"\ndate: %s\n---\n' "$(basename "$f")" > "$CONTENT/$f.md"
done

iso_week() { date -j -f %Y-%m-%d "$1" +%G-W%V 2>/dev/null || date -d "$1" +%G-W%V; }

# S4.1 is another story. Until it lands, set_tpl_vars knows neither {{WEEK}} nor
# {{STUDIO_DIR}}, and every resolution assertion below would fail for a reason
# that has nothing to do with the two files under test. Supply them locally in
# that case, and say so — so the day S4.1 lands, these silently become the real
# thing rather than staying shimmed forever.
tpl_shim() {  # DATE
  [ -n "${TPL_WEEK:-}" ]       || TPL_WEEK="$(iso_week "$1")"
  [ -n "${TPL_STUDIO_DIR:-}" ] || TPL_STUDIO_DIR="${STUDIO_DIR:-}"
}

S41=1
( . "$LIB" >/dev/null 2>&1
  set_tpl_vars 2026-08-02 sunday
  [ -n "${TPL_WEEK:-}" ] && [ -n "${TPL_STUDIO_DIR:-}" ] ) || S41=0

cfg() {  # KEY [DEFAULT] -> value on stdout
  ( . "$LIB" >/dev/null 2>&1; ensure_venv >/dev/null 2>&1; cfg_get "$ANGLES" "$1" "${2:-}" )
}

echo "generators/angles.yaml — S4.6"

"$PYBIN" -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$ANGLES" 2>/dev/null \
  && ok "angles.yaml is valid YAML" || bad "angles.yaml does not parse"

# run-job.sh exits 1 unless all three are non-empty, before it does anything else.
missing=""
for k in producer prompt output; do
  [ -n "$(cfg "$k")" ] || missing="$missing $k"
done
[ -z "$missing" ] \
  && ok "declares the three keys run-job.sh requires: producer, prompt, output" \
  || bad "run-job.sh would exit 1 — missing:$missing"

v="$(cfg schedule daily)"
[ "$v" = "sunday" ] && ok "schedule: sunday" || bad "schedule is '$v', want sunday"

v="$(cfg output)"
[ "$v" = '$STUDIO_DIR/angles/{{WEEK}}.md' ] \
  && ok "output: is the week's file beneath \$STUDIO_DIR, not the day's" \
  || bad "output: is '$v'"

v="$(cfg model)"
[ "$v" = "claude-opus-5" ] \
  && ok "model: claude-opus-5 — angle generation is the harder reasoning task (S4.4)" \
  || bad "model is '$v'"

v="$(cfg schema)"
[ "$v" = "angles" ] \
  && ok "schema: angles — digest frontmatter validation would fail every run (S4.3)" \
  || bad "schema is '$v'"

v="$(cfg name)"
[ -n "$v" ] && [ "$v" != "None" ] && ok "name: is set ($v)" || bad "name: is '$v'"

PROMPT_REL="$(cfg prompt)"
PROMPT="$REPO_DIR/$PROMPT_REL"
[ -f "$PROMPT" ] \
  && ok "prompt: resolves to a file that exists ($PROMPT_REL)" \
  || bad "prompt: names $PROMPT_REL, which does not exist"

# run-job.sh runs the producer as `"$PYTHON_BIN" scripts/$PRODUCER`, so the path
# is relative to scripts/, not to the repo root.
PRODUCER="$(cfg producer)"
prod_script="${PRODUCER%% *}"
[ -f "$REPO_DIR/scripts/$prod_script" ] \
  && ok "producer's script resolves under scripts/ (scripts/$prod_script)" \
  || bad "run-job.sh would run scripts/$prod_script, which does not exist"

grep -q -- '--job angles' <<<"$PRODUCER" \
  && ok "producer passes --job angles, so select_corpus.py reads this very config" \
  || bad "producer does not pass --job angles: $PRODUCER"

# Without it select_corpus.py falls back to Date.today() and a replayed bundle
# silently drifts from the date of the run it belongs to.
grep -q -- '--date {{DATE}}' <<<"$PRODUCER" \
  && ok "producer pins --date {{DATE}}, so a replay is reproducible" \
  || bad "producer does not pin --date {{DATE}}: $PRODUCER"

# ── The Epic 3 selection block, which S4.6 must not disturb ──────────────────

sel_ok="$("$PYBIN" - "$ANGLES" <<'PY' 2>&1
import sys, yaml
c = yaml.safe_load(open(sys.argv[1])) or {}
s = c.get("selection") or {}
w = (s.get("weights") or {})
want = {
    "lookback_days": 14, "half_life_days": 7,
    "collections": ["leadership", "ai", "tech", "rva-events"],
}
bad = ["selection.%s == %r" % (k, s.get(k)) for k, v in want.items() if s.get(k) != v]
if (w.get("theme") or {}) != {"leadership": 3.0, "ai": 1.0, "tech": 0.6, "rva-events": 0.1}:
    bad.append("weights.theme == %r" % (w.get("theme"),))
for k, v in (("starred", 1.5), ("noted", 2.0), ("done", 0.3)):
    if w.get(k) != v:
        bad.append("weights.%s == %r" % (k, w.get(k)))
print("; ".join(bad) if bad else "OK")
PY
)"
[ "$sel_ok" = "OK" ] \
  && ok "the Epic 3 selection block is unchanged — every weight and collection" \
  || bad "selection block drifted: $sel_ok"

# The reasoning is worth more than the numbers; a rewrite that drops it is how
# tuned weights become magic numbers.
c1="leadership is weighted 3x against ai"
c2="Applied once per digest, not once per starred item"
grep -qF "$c1" "$ANGLES" && grep -qF "$c2" "$ANGLES" \
  && ok "the selection block keeps the comments that explain why the weights are these" \
  || bad "a selection comment was dropped"

echo
echo "output resolution and idempotency — S4.6 acceptance"

[ "$S41" = 1 ] || skip "S4.1 ({{WEEK}}, {{STUDIO_DIR}}) has not landed — resolution runs on a local shim"

resolve() {  # DATE -> resolved absolute output path
  ( set -uo pipefail
    export STUDIO_DIR="$STUDIO"
    . "$LIB" >/dev/null 2>&1
    LOG_FILE="$WORK/resolve.log"
    ensure_venv >/dev/null 2>&1
    set_tpl_vars "$1" "$(cfg_get "$ANGLES" schedule daily)"
    tpl_shim "$1"
    resolve_output "$(cfg_get "$ANGLES" output)" )
}

# Sunday 2026-08-02 and Saturday 2026-08-01 are the same ISO week: Sunday's file
# is named for the week that just ended, and holds the Saturday synthesis that
# anchors it. Monday opens the next one.
r_sun="$(resolve 2026-08-02)"
[ "$r_sun" = "$STUDIO/angles/2026-W31.md" ] \
  && ok "Sunday 2026-08-02 resolves to \$STUDIO_DIR/angles/2026-W31.md" \
  || bad "2026-08-02 resolved to $r_sun"

r_sat="$(resolve 2026-08-01)"
[ "$r_sat" = "$r_sun" ] \
  && ok "Saturday 2026-08-01 resolves to the same file — one artifact per ISO week" \
  || bad "2026-08-01 resolved to $r_sat, not $r_sun"

r_mon="$(resolve 2026-08-03)"
[ "$r_mon" = "$STUDIO/angles/2026-W32.md" ] \
  && ok "Monday 2026-08-03 opens the next week's file" || bad "2026-08-03 resolved to $r_mon"

# %G, never %Y: 2027-01-01 belongs to ISO week 2026-W53, and a calendar year
# would name it 2027-W53 — a file for a week that does not exist.
r_ny="$(resolve 2027-01-01)"
[ "$r_ny" = "$STUDIO/angles/2026-W53.md" ] \
  && ok "2027-01-01 resolves to 2026-W53 — the ISO year, not the calendar year" \
  || bad "2027-01-01 resolved to $r_ny"

r_place="$( ( set -uo pipefail
  export STUDIO_DIR="$STUDIO"
  . "$LIB" >/dev/null 2>&1
  LOG_FILE="$WORK/resolve.log"
  ensure_venv >/dev/null 2>&1
  set_tpl_vars 2026-08-02 sunday
  tpl_shim 2026-08-02
  out="$(resolve_output "$(cfg_get "$ANGLES" output)")"
  assert_no_placeholders "$out" "output:" >/dev/null 2>&1 && echo CLEAN || echo LEFTOVER ) )"
[ "$r_place" = "CLEAN" ] \
  && ok "the resolved path carries no unsubstituted placeholder" \
  || bad "resolved output still holds a placeholder"

# src/content/** is read-only to generators — it is both the published site and
# this job's own corpus.
boundary() {  # OUTPUT_TEMPLATE -> ACCEPT | REJECT
  ( set -uo pipefail
    export STUDIO_DIR="$STUDIO"
    . "$LIB" >/dev/null 2>&1
    LOG_FILE="$WORK/boundary.log"
    ensure_venv >/dev/null 2>&1
    set_tpl_vars 2026-08-02 sunday
    tpl_shim 2026-08-02
    out="$(resolve_output "$1")"
    assert_output_boundary generators "$out" >/dev/null 2>&1 && echo ACCEPT || echo REJECT )
}

[ "$(boundary "$(cfg output)")" = "ACCEPT" ] \
  && ok "angles.yaml's own output passes assert_output_boundary" \
  || bad "the real output: is rejected by the boundary check"

[ "$(boundary 'src/content/leadership/{{WEEK}}.md')" = "REJECT" ] \
  && ok "an output: pointing into src/content/ is rejected before the job runs" \
  || bad "a generator writing into src/content/ was accepted"

[ "$(boundary '$STUDIO_DIR/../escape/{{WEEK}}.md')" = "REJECT" ] \
  && ok "an output: climbing out of \$STUDIO_DIR is rejected too" \
  || bad "an output escaping the studio was accepted"

# run-jobs.sh's idempotency gate, replayed: `[ -s "$OUTPUT_FILE" ]`. Nothing
# here is week-aware, which is the point — the generalization from {{DATE}} to
# {{WEEK}} needs no special case.
: > "$r_sun"
[ ! -s "$r_sun" ] && ok "an empty output file does not block the job (the -s guard)" \
  || bad "the -s guard is not what run-jobs.sh applies"
printf 'x' > "$r_sun"
[ -s "$r_sun" ] && ok "once the week's file has content, the Sunday run skips" \
  || bad "idempotency guard did not see the week's file"
[ -s "$(resolve 2026-08-01)" ] \
  && ok "and a Saturday re-run skips on the same file, without a special case" \
  || bad "Saturday would regenerate the week's angles"
[ ! -s "$(resolve 2026-08-09)" ] \
  && ok "the following week is a different file, so the next run is not skipped" \
  || bad "the next week collided with this one"
rm -f "$r_sun"

echo
echo "prompts/posts/angles.md — S4.7"

# run-job.sh refuses to invoke Claude unless the rendered prompt names the exact
# path the job verifies. A prompt naming anything else is a silent, permanent
# skip loop: Claude writes one path, the runner checks another.
grep -qF '{{STUDIO_DIR}}/angles/{{WEEK}}.md' "$PROMPT" \
  && ok "the prompt names {{STUDIO_DIR}}/angles/{{WEEK}}.md" \
  || bad "the prompt does not name the output path"

named="$( ( set -uo pipefail
  export STUDIO_DIR="$STUDIO"
  . "$LIB" >/dev/null 2>&1
  LOG_FILE="$WORK/prompt.log"
  ensure_venv >/dev/null 2>&1
  set_tpl_vars 2026-08-02 sunday
  tpl_shim 2026-08-02
  out="$(resolve_output "$(cfg_get "$ANGLES" output)")"
  # Here-string, not a pipe: grep -q exits on first match and the writer dies of
  # SIGPIPE under pipefail. Exactly what run-job.sh:86 does, for the same reason.
  grep -qF "${out#$REPO_DIR/}" <<<"$(render_placeholders "$(cat "$PROMPT")")" \
    && echo MATCH || echo MISMATCH ) )"
[ "$named" = "MATCH" ] \
  && ok "run-job.sh's prompt/output assert passes against the rendered prompt" \
  || bad "the rendered prompt does not name the rendered output path"

# The 13-night outage: a literal TODAY was taken as a filename and produced
# src/content/<theme>/TODAY.md.
grep -qE '(^|[^A-Za-z_])TODAY([^A-Za-z_]|$)' "$PROMPT" \
  && bad "the prompt carries a bare TODAY token" \
  || ok "no bare TODAY token"

# Every {{PLACEHOLDER}} must be one set_tpl_vars actually renders, or
# assert_no_placeholders fails the job after the producer has already run.
left="$( ( set -uo pipefail
  export STUDIO_DIR="$STUDIO"
  . "$LIB" >/dev/null 2>&1
  LOG_FILE="$WORK/prompt.log"
  ensure_venv >/dev/null 2>&1
  set_tpl_vars 2026-08-02 sunday
  tpl_shim 2026-08-02
  render_placeholders "$(cat "$PROMPT")" | grep -oE '\{\{[A-Z_0-9]+\}\}' | sort -u | tr '\n' ' ' ) )"
[ -z "$left" ] \
  && ok "every {{PLACEHOLDER}} in the prompt is one the runner renders" \
  || bad "unrenderable placeholders in the prompt: $left"

# This repo is public. The employer's name is not hardcoded here either — it is
# read out of an existing prompt at run time, so the denylist cannot itself leak
# it. If that extraction ever fails this assertion fails loudly rather than
# passing on an empty denylist.
EMPLOYER="$(sed -n 's/^- Senior Engineering Manager, \([^,]*\),.*$/\1/p' \
            "$REPO_DIR/scripts/prompts/ai.md" | head -1)"
if [ -z "$EMPLOYER" ]; then
  bad "could not derive the employer denylist from scripts/prompts/ai.md — check by hand"
else
  squashed="$(tr -d ' ' <<<"$EMPLOYER")"
  if grep -qiF "$EMPLOYER" "$PROMPT" || grep -qiF "$squashed" "$PROMPT" \
     || grep -qiF "$EMPLOYER" "$ANGLES" || grep -qiF "$squashed" "$ANGLES"; then
    bad "the employer is named in the angles prompt or config — this repo is public"
  else
    ok "neither the prompt nor the config names the employer"
  fi
  grep -qF "a large regulated enterprise" "$PROMPT" \
    && ok "the prompt supplies the neutral phrasing to use instead" \
    || bad "the prompt does not tell the model what to write instead of the employer's name"
fi

# The strategy the prompt exists to encode. Each of these is a decision from the
# parent plan that a rewrite could quietly drop.
strat_fail=""
check_says() {  # LABEL PATTERN
  grep -qiF "$2" "$PROMPT" || strat_fail="$strat_fail
        missing: $1"
}
# check_says is a substring grep, so it cannot tell a rule that was replaced from
# one that was merely added beside its predecessor. The vantage-point test could
# only be passed by having a rollout of one's own, and it is the diagnosed cause
# of five unpostable angles in the first real week; the two tests that replace it
# are contradicted by it, so its absence is asserted rather than assumed.
check_says_not() {  # LABEL PATTERN
  grep -qiF "$2" "$PROMPT" && strat_fail="$strat_fail
        still present: $1"
}
check_says "the thesis"            "change-management problem, not a tooling problem"
check_says "pillar 1"              "Agentic coding at enterprise scale"
check_says "pillar 2"              "Engineering leadership in the AI era"
check_says "pillar 3"              "Build in public"
check_says "pillar 4"              "The adoption gap"
check_says "the anchor pillar"     "anchor pillar"
check_says "enterprise altitude"   "altitude: enterprise"
check_says "the smb gate"          "out of bounds"
check_says_not "the vantage-point test" "no rollout of their own"
check_says "the provability test"  "would the thesis still stand"
check_says "the edge test"         "reach this thesis in one step"
check_says "nothing rests on access" "Nothing may rest on privileged access"
check_says "coverage is copied"    "verbatim"
check_says "no invented dates"     "Never invent a date"
check_says "the 6-10 range"        "6 to 10 angles"
check_says "score honestly"        "never withhold an angle because of the number"
check_says "spread is a standard"  "no spread in \`provability\` or \`consequence\`"
check_says "the model never judges" "verdict:** pending"
for dim in provability consequence edge readiness; do
  check_says "the $dim anchors" "score $dim:"
done
[ -z "$strat_fail" ] \
  && ok "the prompt still encodes the thesis, four pillars, altitude gate and anti-fabrication rules" \
  || bad "the prompt lost part of its strategy:$strat_fail"

echo
echo "the angles file format contract"

CHECK="$WORK/check_angles.py"
cat > "$CHECK" <<'PY'
"""A second implementation of the angles-file contract, written from the epic
brief rather than from the runner, so a disagreement between the two is visible.

    check_angles.py FILE --content-dir DIR --studio-dir DIR [--angle-only] [--judged]

Prints one problem per line and exits 1, or prints OK and exits 0.
"""
import argparse
import os
import re
import sys

import yaml

HEADING = re.compile(r"^## A(\d+) — (\S.*)$")
OTHER_HEADING = re.compile(r"^## ")
FIELD = re.compile(r"^- \*\*([a-z ]+):\*\*[ ]?(.*)$")
NESTED = re.compile(r"^(\s+)- (\S.*)$")
CITE = re.compile(r"`\[([^\]]+)\]`")
BARE_CITE = re.compile(r"(?<!`)\[((?:[a-z0-9-]+/|note )\d{4}-\d{2}-\d{2})\](?!`)")
THEME_CITE = re.compile(r"^([a-z0-9-]+)/(\d{4}-\d{2}-\d{2})$")
NOTE_CITE = re.compile(r"^note (\d{4}-\d{2}-\d{2})$")
WEEK = re.compile(r"^\d{4}-W\d{2}$")
SCORE = re.compile(r"^([0-3])\s+—\s+(\S.*)$")
VERDICT = re.compile(r"^(\S+)(?:\s+—\s+(.*))?$")

BASE = ["pillar", "altitude", "thesis", "why now", "evidence"]
DIMENSIONS = ["provability", "consequence", "edge", "readiness"]
SCORES = ["score " + d for d in DIMENSIONS]
ORDER = {1: BASE + ["risk", "verdict"], 2: BASE + ["blocker", "prep", "verdict"] + SCORES}
NEEDED = {1: BASE + ["risk"], 2: BASE + ["blocker", "prep", "verdict"] + SCORES}
VERDICTS = ["pending", "post", "maybe", "pass"]
TAGS = ["P:", "C:", "E:", "R:", "—:"]

ap = argparse.ArgumentParser()
ap.add_argument("path")
ap.add_argument("--content-dir", required=True)
ap.add_argument("--studio-dir", required=True)
ap.add_argument("--angle-only", action="store_true")
ap.add_argument("--judged", action="store_true")
args = ap.parse_args()

text = open(args.path, encoding="utf-8").read()
lines = text.split("\n")
problems = []


def split_angles(body_lines):
    """-> [(n, title, [field lines])], plus any stray line outside an angle."""
    angles, stray, cur = [], [], None
    for line in body_lines:
        m = HEADING.match(line)
        if m:
            cur = (int(m.group(1)), m.group(2), [])
            angles.append(cur)
        elif OTHER_HEADING.match(line):
            cur = None
            stray.append(line)
        elif cur is not None:
            cur[2].append(line)
        elif line.strip():
            stray.append(line)
    return angles, stray


def check_cites(where, blob, require_one):
    """Resolve every citation in `blob`. Every model-written field is passed here;
    `verdict:` never is — a human's verdict reason may mention a digest in prose."""
    tokens = CITE.findall(blob)
    for bare in BARE_CITE.findall(blob):
        problems.append("%s: citation [%s] is missing its backticks" % (where, bare))
    if require_one and not tokens:
        problems.append("%s: evidence bullet carries no `[citation]`: %s"
                        % (where, blob[:60]))
    for tok in tokens:
        m = THEME_CITE.match(tok)
        if m:
            path = os.path.join(args.content_dir, m.group(1), m.group(2) + ".md")
            if not os.path.isfile(path):
                problems.append("%s: citation [%s] does not resolve (%s)"
                                % (where, tok, path))
            continue
        m = NOTE_CITE.match(tok)
        if m:
            day = m.group(1)
            path = os.path.join(args.studio_dir, "notes", day[:7] + ".md")
            if not os.path.isfile(path):
                problems.append("%s: note citation [%s] has no month file (%s)"
                                % (where, tok, path))
            elif not re.search(r"^## %s T?" % re.escape(day).replace(" ", ""),
                               open(path, encoding="utf-8").read().replace(
                                   day + "T", day + " T"),
                               re.M):
                problems.append("%s: no note headed %s in %s" % (where, day, path))
            continue
        problems.append("%s: malformed citation token [%s]" % (where, tok))


def check_verdict(where, value):
    m = VERDICT.match(value)
    if not m:
        problems.append("%s: verdict must be '<verdict>' or '<verdict> — <reason>'"
                        % where)
        return
    word, reason = m.group(1), (m.group(2) or "").strip()
    if word not in VERDICTS:
        problems.append("%s: verdict %r is not one of %s"
                        % (where, word, "|".join(VERDICTS)))
        return
    if not args.judged:
        if value != "pending":
            problems.append("%s: verdict %r — a generated file may only say 'pending'"
                            % (where, value))
        return
    # A missing reason or dimension tag is a warning in `kickoff judge`, never a
    # rejection here: the field is human-written, and refusing the commit costs
    # more signal than the tag carries.


def check_angle(n, title, body, version):
    where = "A%s" % n
    canonical, needed = ORDER[version], NEEDED[version]
    seen, order = {}, []
    i = 0
    while i < len(body):
        m = FIELD.match(body[i])
        if m:
            name, value = m.group(1), m.group(2)
            order.append(name)
            nested = []
            j = i + 1
            while j < len(body) and NESTED.match(body[j]):
                nested.append(NESTED.match(body[j]))
                j += 1
            seen[name] = (value, nested)
            i = j
            continue
        if body[i].strip():
            problems.append("%s: line is neither a '- **field:**' nor an evidence "
                            "bullet — every field is one line: %r"
                            % (where, body[i].rstrip()))
        i += 1

    for name, (_value, nested) in seen.items():
        if nested and name != "evidence":
            problems.append("%s: has a nested bullet under %r — only 'evidence' takes "
                            "a nested list" % (where, name))

    for f in needed:
        if f not in seen:
            problems.append("%s: missing required field %r" % (where, f))
    for f in order:
        if f in canonical:
            continue
        if f in SCORES:
            problems.append("%s: field %r requires schemaVersion 2" % (where, f))
        elif f == "risk":
            problems.append("%s: field 'risk' — schemaVersion 2 uses 'blocker'/'prep'"
                            % where)
        else:
            problems.append("%s: unknown field %r" % (where, f))
    ranked = [f for f in order if f in canonical]
    if ranked != [f for f in canonical if f in ranked]:
        problems.append("%s: fields out of order: %s" % (where, ", ".join(ranked)))

    for f in needed:
        if f == "evidence":
            continue
        if f in seen and not seen[f][0].strip():
            problems.append("%s: %s is empty" % (where, f))

    if version == 2:
        for f in SCORES:
            if f in seen and seen[f][0].strip() and not SCORE.match(seen[f][0].strip()):
                problems.append("%s: %s must be '<0-3> — <justification>', got %r"
                                % (where, f, seen[f][0].strip()))

    if "verdict" in seen and seen["verdict"][0].strip():
        check_verdict(where, seen["verdict"][0].strip())

    # Every field the model writes is scanned; only the human's `verdict:` is
    # exempt. An allowlist of `why now:` and `evidence:` would quietly stop
    # checking a citation invented in `thesis:`, `blocker:` or `prep:`.
    for name, (value, _nested) in seen.items():
        if name in ("verdict", "evidence"):
            continue
        if value.strip():
            check_cites(where, value, False)

    if "evidence" in seen:
        value, nested = seen["evidence"]
        if value.strip():
            problems.append("%s: evidence must be a nested list, not inline text" % where)
        if not nested:
            problems.append("%s: evidence has no bullets (at least one is required)" % where)
        for m in nested:
            if m.group(1) != "  ":
                problems.append("%s: evidence bullet must be indented exactly 2 spaces: %s"
                                % (where, m.group(0).rstrip()))
            check_cites(where, m.group(2), True)

    if "altitude" in seen and seen["altitude"][0].strip() != "enterprise":
        problems.append("%s: altitude is %r, and only 'enterprise' is in scope"
                        % (where, seen["altitude"][0].strip()))
    if "pillar" in seen:
        p = seen["pillar"][0].strip()
        if not re.match(r"^[1-4]\b", p):
            problems.append("%s: pillar must open with a digit 1-4, got %r" % (where, p))
    if not title.strip():
        problems.append("%s: heading has no title" % where)


if args.angle_only:
    angles, _ = split_angles(lines)
    if len(angles) != 1:
        problems.append("expected exactly one angle, found %d" % len(angles))
    for n, title, body in angles:
        # No frontmatter to dispatch on: a lone angle is v2 if it carries any
        # field only v2 has. Keeps the prompt's worked example checkable across
        # the migration without the extractor having to know which side it is on.
        names = [FIELD.match(x).group(1) for x in body if FIELD.match(x)]
        check_angle(n, title, body,
                    2 if [x for x in names if x in SCORES + ["blocker", "prep"]] else 1)
else:
    if lines[0].strip() != "---":
        problems.append("no opening frontmatter delimiter")
        end = None
    else:
        end = next((i for i, l in enumerate(lines[1:], 1) if l.strip() == "---"), None)
        if end is None:
            problems.append("unterminated frontmatter")

    if end is not None:
        try:
            fm = yaml.safe_load("\n".join(lines[1:end])) or {}
        except yaml.YAMLError as exc:
            fm = {}
            problems.append("frontmatter is not valid YAML: %s" % exc)
        if not isinstance(fm, dict):
            fm = {}
            problems.append("frontmatter is not a mapping")

        for key in ("week", "generated", "corpusCoverage", "angleCount"):
            if fm.get(key) in (None, "", []):
                problems.append("missing required field: %s" % key)

        week = fm.get("week")
        if week is not None and not WEEK.match(str(week)):
            problems.append("week %r does not match YYYY-Www" % (week,))
        gen = fm.get("generated")
        if gen is not None and not re.match(r"^\d{4}-\d{2}-\d{2}$", str(gen)):
            problems.append("generated %r is not a YYYY-MM-DD date" % (gen,))

        raw = fm.get("schemaVersion")
        version = 1 if raw is None else raw
        if isinstance(version, bool) or version not in (1, 2):
            problems.append("schemaVersion must be 1 or 2, got %r" % (raw,))
            version = None

        angles, stray = split_angles(lines[end + 1:])
        if stray:
            problems.append("content outside any angle: %s" % stray[0][:60])

        count = fm.get("angleCount")
        if isinstance(count, bool) or not isinstance(count, int):
            problems.append("angleCount must be an integer, got %r" % (count,))
        elif count != len(angles):
            problems.append("angleCount is %d but there are %d '## A' headings"
                            % (count, len(angles)))

        if not 6 <= len(angles) <= 10:
            problems.append("%d angles — the range is 6 to 10" % len(angles))

        for i, (n, _t, _b) in enumerate(angles, 1):
            if n != i:
                problems.append("angle %d is numbered A%d — numbering must run 1..n"
                                % (i, n))
                break

        if version is not None:
            for n, title, body in angles:
                check_angle(n, title, body, version)

if problems:
    print("\n".join(problems))
    sys.exit(1)
print("OK")
PY

# Set to --judged around the cases that read a file a human has already judged.
# Both implementations must be given the same mode, or the differential compares
# two different contracts.
MODE=""

run_check() {  # FILE [EXTRA_ARGS...] -> prints problems
  local f="$1"; shift
  "$PYBIN" "$CHECK" "$f" --content-dir "$CONTENT" --studio-dir "$STUDIO" \
    ${MODE:+$MODE} "$@" 2>&1
}

# The shipped validator — the one scripts/lib/run-llm-job.sh actually invokes.
run_shipped() {  # FILE -> prints problems, or nothing on success
  "$PYBIN" "$REPO_DIR/scripts/lib/validate_angles.py" "$1" \
    --content-dir "$CONTENT" --studio-dir "$STUDIO" ${MODE:+$MODE} 2>&1
}

# The differential. check_angles.py above is a second, independent reading of the
# contract — but a second implementation proves nothing unless both are run and
# compared. Asserting only against the copy would leave the shipped validator
# completely untested while looking like thorough coverage.
#
# Wording is not compared — two independent implementations are expected to word
# a problem differently. *Which rule fired* is: agreeing on accept/reject alone
# lets a file that breaks two rules be rejected by each implementation for a
# different one, which reads as agreement and hides a real divergence.
DIFF_FAIL=""
CHECK_OUT=""
SHIPPED_OUT=""
agree() {  # LABEL FILE — leaves each implementation's output in CHECK_OUT/SHIPPED_OUT
  local a b
  CHECK_OUT="$(run_check "$2")" && a=accept || a=reject
  SHIPPED_OUT="$(run_shipped "$2")" && b=accept || b=reject
  [ "$a" = "$b" ] || DIFF_FAIL="$DIFF_FAIL
        $1: contract copy says $a, scripts/lib/validate_angles.py says $b"
}

[ -f "$FIXTURE" ] && ok "the round-trip fixture exists" || bad "fixture missing: $FIXTURE"

agree "the valid fixture" "$FIXTURE"
out="$(run_check "$FIXTURE")"
[ "$out" = "OK" ] \
  && ok "a hand-written angles file in the prompt's stated format satisfies the contract" \
  || bad "the fixture fails the contract: $out"

# The worked example inside the prompt is what the model imitates most closely.
# If it drifts from the contract, so does the output.
"$PYBIN" - "$PROMPT" > "$WORK/example.md" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^(## A1 — Review became the bottleneck.*?)^```", text, re.M | re.S)
sys.stdout.write(m.group(1) if m else "")
PY
if [ -s "$WORK/example.md" ]; then
  out="$(run_check "$WORK/example.md" --angle-only)"
  [ "$out" = "OK" ] \
    && ok "the prompt's own worked example satisfies the per-angle contract" \
    || bad "the prompt teaches a shape the contract rejects: $out"
else
  bad "could not extract the prompt's worked example — has it been renamed?"
fi

# ── The checker must reject what it claims to reject ─────────────────────────
#
# A contract checker nobody has mutated is a checker that passes everything.
# Each case below breaks the fixture in one way and must be caught.

judge_mutant() {  # LABEL FILE EXPECTED_IN_COPY EXPECTED_IN_SHIPPED
  agree "$1" "$2"
  if [ "$CHECK_OUT" = "OK" ]; then
    bad "mutation '$1' was accepted by the contract copy"
  elif ! grep -qF "$3" <<<"$CHECK_OUT"; then
    bad "mutation '$1' — the contract copy rejected for the wrong reason: $CHECK_OUT"
  elif [ -z "$SHIPPED_OUT" ]; then
    bad "mutation '$1' was accepted by scripts/lib/validate_angles.py"
  elif ! grep -qF "$4" <<<"$SHIPPED_OUT"; then
    bad "mutation '$1' — validate_angles.py rejected for the wrong reason: $SHIPPED_OUT"
  else
    ok "rejected: $1"
  fi
}

mutate_on() {  # BASE LABEL SED_EXPR EXPECTED_IN_COPY EXPECTED_IN_SHIPPED
  local f="$WORK/mutant.md"
  sed "$3" "$1" > "$f"
  if [ "$(cat "$f")" = "$(cat "$1")" ]; then
    bad "mutation '$2' changed nothing — the sed no longer matches"
    return
  fi
  judge_mutant "$2" "$f" "$4" "$5"
}

mutate() {  # LABEL SED_EXPR EXPECTED_IN_COPY EXPECTED_IN_SHIPPED
  mutate_on "$FIXTURE" "$@"
}

mutate "a citation that does not resolve on disk" \
  's|\[leadership/2026-08-01\]|[leadership/2026-06-13]|' \
  "does not resolve" "does not resolve"
mutate "an invented note date" \
  's|\[note 2026-07-29\]|[note 2026-07-28]|' \
  "no note headed 2026-07-28" "no note dated 2026-07-28"
mutate "a malformed citation token" \
  's|`\[ai/2026-07-27\]`|`[ai 2026-07-27]`|' \
  "malformed citation token" "is neither \`[<theme>/<YYYY-MM-DD>]\`"
mutate "angleCount disagreeing with the headings" \
  's|^angleCount: 8$|angleCount: 7|' \
  "angleCount is 7 but there are 8" "angleCount is 7 but the file has 8"
mutate "a week that is not an ISO week" \
  's|^week: 2026-W31$|week: 2026-08-02|' \
  "does not match YYYY-Www" "week must match YYYY-Www"
mutate "a missing frontmatter field" 's|^corpusCoverage: .*$||' \
  "missing required field: corpusCoverage" "missing required field: corpusCoverage"
mutate "a dropped required field" 's|^- \*\*risk:\*\* the sharpest.*$||' \
  "missing required field 'risk'" "is missing the 'risk' field"
mutate "an angle with no evidence bullets" \
  's|^  - `\[leadership/2026-08-01\]` a direct warning.*$||' \
  "evidence has no bullets" "has no nested bullets"
mutate "evidence inlined instead of nested" \
  's|^- \*\*evidence:\*\*$|- **evidence:** the leadership weekly|' \
  "must be a nested list" "must be a nested list"
mutate "an smb-altitude angle" \
  's|^- \*\*altitude:\*\* enterprise$|- **altitude:** smb|' \
  "only 'enterprise' is in scope" "only enterprise is in scope"
mutate "a pillar outside 1-4" \
  's|^- \*\*pillar:\*\* 2 — Engineering|- **pillar:** 5 — Engineering|' \
  "pillar must open with a digit" "must open with a digit 1-4"
mutate "a gap in the angle numbering" 's|^## A2 —|## A3 —|' \
  "numbering must run 1..n" "must number sequentially from 1"
mutate "a fifth angle dropped, taking the set below six" \
  '/^## A[5678] /,$d' "the range is 6 to 10" "expected 6-10 angles"
mutate "an empty thesis" \
  's|^- \*\*thesis:\*\* Agentic coding moves.*$|- **thesis:**|' \
  "thesis is empty" "has an empty 'thesis' field"
mutate "prose smuggled in outside an angle" \
  's|^## A1 — Review|Some preamble.\n\n## A1 — Review|' \
  "content outside any angle" "content outside any angle"

# ── The assertion that keeps the differential honest ─────────────────────────
#
# Agreeing on accept/reject is not agreement. This file breaks two rules at once
# — an evidence bullet indented 3 spaces, carrying a citation that also does not
# resolve — and each implementation is required to name the *same* one. Without
# this, a later mutation aimed at one rule can be rejected by both for a
# different rule and still report success.
mutate "two broken rules at once, both implementations naming the same one" \
  's|^  - `\[leadership/2026-08-01\]` a direct warning|   - `[leadership/2026-06-13]` a direct warning|' \
  "evidence bullet must be indented exactly 2 spaces" \
  "evidence bullet must be indented exactly 2 spaces"

mutate "an unrecognised field" \
  's|^- \*\*risk:\*\* the sharpest|- **vibe:** the sharpest|' \
  "unknown field 'vibe'" "unrecognised field: 'vibe'"
# Structural mutations sed cannot express without portability contortions. The
# expression runs against `lines`; whatever it leaves there is the mutant.
mutate_lines() {  # BASE LABEL PY_EXPR EXPECTED_IN_COPY EXPECTED_IN_SHIPPED
  local f="$WORK/mutant.md"
  "$PYBIN" - "$1" "$3" > "$f" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
exec(sys.argv[2])
sys.stdout.write("\n".join(lines))
PY
  if [ "$(cat "$f")" = "$(cat "$1")" ]; then
    bad "mutation '$2' changed nothing"
    return
  fi
  judge_mutant "$2" "$f" "$4" "$5"
}

mutate_lines "$FIXTURE" "fields in a non-canonical order" \
  'i = lines.index("- **altitude:** enterprise"); lines[i:i+2] = [lines[i+1], lines[i]]' \
  "fields out of order" "fields are out of order"
mutate_lines "$FIXTURE" "a '## Notes' heading after the last angle" \
  'lines += ["", "## Notes", "a thought that faces none of the checks above"]' \
  "content outside any angle" "content outside any angle"

echo
echo "schemaVersion 2 — scores, blocker/prep and verdict"

agree "the v2 scored fixture" "$SCORED"
[ "$CHECK_OUT" = "OK" ] && [ -z "$SHIPPED_OUT" ] \
  && ok "a v2 file with four scores and every verdict 'pending' is valid by default" \
  || bad "the v2 fixture fails: copy=$CHECK_OUT shipped=$SHIPPED_OUT"

sv() { mutate_on "$SCORED" "$@"; }

sv "a score above the range" \
  's|^- \*\*score provability:\*\* 3 — every load-bearing|- **score provability:** 4 — every load-bearing|' \
  "score provability must be" "'score provability' must be"
sv "a negative score" \
  's|^- \*\*score provability:\*\* 3 — every load-bearing|- **score provability:** -1 — every load-bearing|' \
  "score provability must be" "'score provability' must be"
sv "a fractional score" \
  's|^- \*\*score provability:\*\* 3 — every load-bearing|- **score provability:** 2.5 — every load-bearing|' \
  "score provability must be" "'score provability' must be"
sv "a word where a score belongs" \
  's|^- \*\*score provability:\*\* 3 — every load-bearing|- **score provability:** high — every load-bearing|' \
  "score provability must be" "'score provability' must be"
sv "a score with no justification clause" \
  's|^- \*\*score provability:\*\* 3 — every load-bearing.*$|- **score provability:** 3|' \
  "score provability must be" "'score provability' must be"
sv "a v2 angle missing one dimension" \
  's|^- \*\*score edge:\*\* 3 — reframes a measurement.*$||' \
  "missing required field 'score edge'" "is missing the 'score edge' field"

# The whole reason SCORE_FIELDS is an explicit four-name constant. A `score `
# prefix whitelist accepts this line: it clears the unknown-field guard because
# it looks like a score, and clears the four-required guard because all four are
# still present.
sv "a fifth, invented score dimension" \
  's|^- \*\*score readiness:\*\* 1 — needs a proposed|- **score vibes:** 3 — feels right\n- **score readiness:** 1 — needs a proposed|' \
  "unknown field 'score vibes'" "unrecognised field: 'score vibes'"

sv "risk: surviving into a v2 file" \
  's|^- \*\*blocker:\*\* none$|- **risk:** none|' \
  "schemaVersion 2 uses 'blocker'/'prep'" "schemaVersion 2 replaces it with 'blocker' and 'prep'"
sv "a v2 angle with no blocker:" \
  's|^- \*\*blocker:\*\* none$||' \
  "missing required field 'blocker'" "is missing the 'blocker' field"
sv "a v2 angle with no prep:" \
  's|^- \*\*prep:\*\* needs a proposed replacement metric.*$||' \
  "missing required field 'prep'" "is missing the 'prep' field"

# The model commits to scores; it does not get to record the human's decision.
sv "the model writing a verdict of its own" \
  's|^- \*\*verdict:\*\* pending$|- **verdict:** post — this one is obviously good|' \
  "may only say 'pending'" "may only carry 'pending'"
sv "a verdict outside the vocabulary" \
  's|^- \*\*verdict:\*\* pending$|- **verdict:** yes|' \
  "is not one of pending|post|maybe|pass" "it must be one of pending | post | maybe | pass"
sv "schemaVersion 3" 's|^schemaVersion: 2$|schemaVersion: 3|' \
  "schemaVersion must be 1 or 2" "schemaVersion must be 1 or 2"
sv "a v2 file declaring itself v1" 's|^schemaVersion: 2$|schemaVersion: 1|' \
  "requires schemaVersion 2" "score fields require schemaVersion: 2"

echo
echo "--judged — the human's half of the contract"

MODE="--judged"

agree "the judged v2 fixture" "$JUDGED"
[ "$CHECK_OUT" = "OK" ] && [ -z "$SHIPPED_OUT" ] \
  && ok "a judged v2 file with tagged maybe/pass reasons is valid under --judged" \
  || bad "the judged fixture fails: copy=$CHECK_OUT shipped=$SHIPPED_OUT"

# A5's reason carries an un-backticked [leadership/2026-06-13] — a token that is
# both malformed and unresolvable. Punishing an honest verdict reason with a
# mechanical rule teaches the human to stop writing reasons, and the reason is
# the only free-text signal the calibration loop has.
grep -qF 'pass — P: the [leadership/2026-06-13] framing is stale' "$JUDGED" \
  && ok "the judged fixture really does carry a bare, unresolvable citation in a verdict reason" \
  || bad "the judged fixture no longer exercises the citation-scoping rule"

# The tag is warned about by `kickoff judge`, never rejected here. Enforce hard
# on what the model writes; warn on what the human writes — refusing to commit a
# whole week's verdicts over one missing letter makes deleting the reason the
# cheapest way out, and the reason is the only free-text signal there is.
sed 's|^- \*\*verdict:\*\* pass — C: nothing a reader owns.*$|- **verdict:** pass — nothing a reader owns actually changes|' \
  "$JUDGED" > "$WORK/untagged.md"
agree "a maybe/pass verdict with no dimension tag" "$WORK/untagged.md"
[ "$CHECK_OUT" = "OK" ] && [ -z "$SHIPPED_OUT" ] \
  && ok "an untagged verdict reason validates — the tag is a warning, not a gate" \
  || bad "an untagged verdict reason was rejected: copy=$CHECK_OUT shipped=$SHIPPED_OUT"

# Structural, version-independent, and the reason angles_index.py cannot be the
# stricter of the two: a wrapped field that validates here reaches Epic 5's
# parser as a truncated value, after the run has committed and pushed.
mutate_on "$JUDGED" "a wrapped field — a body line that is neither a field nor a bullet" \
  's|^- \*\*altitude:\*\* enterprise$|- **altitude:** enterprise\
  and this continuation line belongs to no field|' \
  "neither a" "neither a"
mutate_on "$JUDGED" "a nested bullet under a field that does not take one" \
  's|^- \*\*altitude:\*\* enterprise$|- **altitude:** enterprise\
  - a bullet under the wrong field|' \
  "nested bullet under" "nested bullet under"
mutate_on "$JUDGED" "a verdict outside the vocabulary, under --judged too" \
  's|^- \*\*verdict:\*\* post — the arithmetic.*$|- **verdict:** yes|' \
  "is not one of pending|post|maybe|pass" "it must be one of pending | post | maybe | pass"

agree "the v1 fixture with verdicts at slot 7" "$V1_JUDGED"
[ "$CHECK_OUT" = "OK" ] && [ -z "$SHIPPED_OUT" ] \
  && ok "2026-W31 plus verdict lines validates under --judged, scores and all absent" \
  || bad "the v1+verdicts fixture fails: copy=$CHECK_OUT shipped=$SHIPPED_OUT"

mutate_on "$V1_JUDGED" "a score field smuggled into a v1 file" \
  's|^- \*\*verdict:\*\* post — the team-variance.*$|&\n- **score provability:** 3 — public throughout|' \
  "requires schemaVersion 2" "score fields require schemaVersion: 2"

MODE=""

agree "the v1 fixture with verdicts, read in default mode" "$V1_JUDGED"
[ "$CHECK_OUT" != "OK" ] && [ -n "$SHIPPED_OUT" ] \
  && ok "and the same file is rejected without --judged — the generator may not write verdicts" \
  || bad "a judged file passed the generator's own strict reading"

[ -z "$DIFF_FAIL" ] \
  && ok "the shipped validator and this independent contract copy agree on every case" \
  || bad "the two implementations disagree — one of them is wrong:$DIFF_FAIL"

echo
if [ "$FAIL" = "0" ]; then
  echo "PASS ($COUNT) — angles job tests passed"
else
  echo "FAIL — angles job tests FAILED ($COUNT assertions run)"
fi
exit "$FAIL"
