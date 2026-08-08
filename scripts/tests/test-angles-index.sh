#!/bin/bash
# Regression test for scripts/studio/angles_index.py — Epic 4.5, S4.5.6.
#
# The module is the only parser of the angle format outside the validator, and
# three consumers depend on it (`kickoff judge`, the calibration report, Epic 5's
# `kickoff draft`). So this suite exercises three things above all others:
#
#   1. THE BAND RULE, at every boundary and exhaustively over all 256 score
#      combinations, against an independently-phrased reimplementation. The band
#      is computed, never read from disk, and a `<` that should be `<=` silently
#      reclassifies a whole week.
#   2. v1 files parse without raising, yielding band and composite of None.
#   3. v1 rows stay separable from v2 rows, so nine band-less rows can never be
#      folded into a rate computed over three scored ones.
#
# Everything is built fresh in $TMPDIR. The real studio is never read or written;
# the real repo is only read, and only for the committed fixtures the validator
# already owns. No network, no LLM.
#
#   bash scripts/tests/test-angles-index.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MODDIR="$REPO_DIR/scripts/studio"

PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

FAIL=0
COUNT=0
ok()   { COUNT=$((COUNT + 1)); printf "  \033[32mok\033[0m    %s\n" "$*"; }
bad()  { COUNT=$((COUNT + 1)); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=1; }
skip() { printf "  \033[33mskip\033[0m  %s\n" "$*"; }

echo "angles_index"

# The module imports pyyaml. On a clone where scripts/.venv has not been built
# there is nothing to test against and no way to build one without the network.
if ! "$PYBIN" -c 'import yaml' 2>/dev/null; then
  skip "pyyaml unavailable in $PYBIN — run any kickoff command once to build scripts/.venv"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export MODDIR

# ── Drivers ───────────────────────────────────────────────────────────────────

# Expressions are evaluated against the real module, so what is under test is
# the shipped parser rather than a stand-in. ParseError is reported on stdout
# with exit 3, which is what makes "raises, and names the right thing" testable
# in one helper instead of two.
cat > "$WORK/drive.py" <<'PYEOF'
import os
import sys

sys.path.insert(0, os.environ["MODDIR"])
from angles_index import *  # noqa: F401,F403
import angles_index as A  # noqa: F401

try:
    print(eval(sys.argv[1]))
except ParseError as exc:  # noqa: F405
    print("ParseError: %s" % exc)
    sys.exit(3)
PYEOF

eval_py() { "$PYBIN" "$WORK/drive.py" "$1" 2>"$WORK/err.txt"; }

check_eval() {  # NAME EXPECTED EXPR
  local got
  got="$(eval_py "$3")"
  if [ "$got" = "$2" ]; then ok "$1"
  else bad "$1 — want [$2], got [$got] $(head -c 300 "$WORK/err.txt" | tr '\n' ' ')"; fi
}

check_raises() {  # NAME SUBSTRING EXPR
  local got status
  got="$(eval_py "$3")"; status=$?
  if [ "$status" != "3" ]; then
    bad "$1 — expected ParseError, got status $status: [$got] $(head -c 200 "$WORK/err.txt" | tr '\n' ' ')"
  elif grep -qF -- "$2" <<<"$got"; then ok "$1"
  else bad "$1 — raised, but the message does not name '$2': [$got]"; fi
}

# ── Fixture builders ──────────────────────────────────────────────────────────
#
# One angle per file is fine here. The 6–10 count is the validator's rule, not
# the parser's: the parser reads whatever validated, and duplicating the count
# check would be a second reading of the same rule.

v2_head() {  # WEEK COUNT
  cat <<EOF
---
week: $1
generated: 2026-08-09
corpusCoverage: "leadership 2/2"
angleCount: $2
schemaVersion: 2
---
EOF
}

v1_head() {  # WEEK COUNT
  cat <<EOF
---
week: $1
generated: 2026-08-02
corpusCoverage: "leadership 2/2"
angleCount: $2
---
EOF
}

v2_angle() {  # N P C E R [VERDICT]
  cat <<EOF

## A$1 — Title $1
- **pillar:** 2 — Engineering leadership in the AI era
- **altitude:** enterprise
- **thesis:** thesis $1
- **why now:** why now $1
- **evidence:**
  - \`[leadership/2026-08-01]\` evidence for angle $1
- **blocker:** none
- **prep:** one verification pass against the primary source
- **verdict:** ${6:-pending}
- **score provability:** $2 — every load-bearing item is a public digest
- **score consequence:** $3 — names the metric class and the removal
- **score edge:** $4 — combines two feed items
- **score readiness:** $5 — drafts from the angle as written
EOF
}

v1_angle() {  # N [VERDICT-LINE-OR-EMPTY]
  cat <<EOF

## A$1 — Title $1
- **pillar:** 2 — Engineering leadership in the AI era
- **altitude:** enterprise
- **thesis:** thesis $1
- **why now:** why now $1
- **evidence:**
  - \`[leadership/2026-08-01]\` evidence for angle $1
- **risk:** the sharp version wants internal numbers
EOF
  [ -n "${2:-}" ] && printf -- '- **verdict:** %s\n' "$2"
  return 0
}

v2_file() {  # PATH WEEK P C E R [VERDICT]
  { v2_head "$2" 1; v2_angle 1 "$3" "$4" "$5" "$6" "${7:-pending}"; } > "$1"
}

# ── 1. The band rule ──────────────────────────────────────────────────────────
#
# The gate: BLOCKED if P<=1; REWORK if P>=2 and (C<=1 or E<=1); DRAFT if P>=2
# and C>=2 and E>=2.

echo "  band rule — exhaustive"

cat > "$WORK/bandtable.py" <<'PYEOF'
import os
import sys

sys.path.insert(0, os.environ["MODDIR"])
from angles_index import BLOCKED, DRAFT, REWORK, compute_band, compute_composite


def independent(p, c, e):
    """Phrased by membership rather than comparison, so a `<` that should be
    `<=` in the module cannot be reproduced by the same slip here."""
    if p in (0, 1):
        return BLOCKED
    if (c in (0, 1)) or (e in (0, 1)):
        return REWORK
    return DRAFT


mismatch = []
counts = {BLOCKED: 0, REWORK: 0, DRAFT: 0}
r_sensitive = []
for p in range(4):
    for c in range(4):
        for e in range(4):
            seen = set()
            for r in range(4):
                scores = {"provability": p, "consequence": c, "edge": e, "readiness": r}
                got = compute_band(scores)
                seen.add(got)
                if got != independent(p, c, e):
                    mismatch.append((p, c, e, r, got, independent(p, c, e)))
                if compute_composite(scores) != p + c + e:
                    mismatch.append((p, c, e, r, "composite", compute_composite(scores)))
            if len(seen) != 1:
                r_sensitive.append((p, c, e, sorted(seen)))
            counts[independent(p, c, e)] += 1

print("mismatch=%d" % len(mismatch))
print("r_sensitive=%d" % len(r_sensitive))
print("blocked=%d rework=%d draft=%d" % (counts[BLOCKED], counts[REWORK], counts[DRAFT]))
if mismatch:
    print("first=%r" % (mismatch[0],), file=sys.stderr)
PYEOF

TABLE="$("$PYBIN" "$WORK/bandtable.py" 2>"$WORK/table-err.txt")"
if grep -qF 'mismatch=0' <<<"$TABLE"; then ok "all 256 P/C/E/R combinations match the independent rule"
else bad "band rule disagrees with the independent rule: $TABLE $(cat "$WORK/table-err.txt")"; fi
if grep -qF 'r_sensitive=0' <<<"$TABLE"; then ok "Readiness never moves the band (64 P/C/E sets × 4 R values)"
else bad "Readiness changed a band: $TABLE"; fi
# 32 = P in {0,1}; 8 = P,C,E all in {2,3}; 24 = the rest above the P gate.
if grep -qF 'blocked=32 rework=24 draft=8' <<<"$TABLE"; then ok "band population over P/C/E is 32 BLOCKED / 24 REWORK / 8 DRAFT"
else bad "unexpected band population: $TABLE"; fi

echo "  band rule — boundaries, end to end through parse_file()"

check_band() {  # P C E R EXPECTED
  local f="$WORK/band-$1$2$3$4.md"
  v2_file "$f" 2026-W40 "$1" "$2" "$3" "$4"
  local got; got="$(eval_py "parse_file('$f')[0].band")"
  if [ "$got" = "$5" ]; then ok "P$1 C$2 E$3 R$4 → $5"
  else bad "P$1 C$2 E$3 R$4 → want $5, got [$got] $(head -c 200 "$WORK/err.txt" | tr '\n' ' ')"; fi
}

# P boundary, with C and E clear: the flip is at P 1→2.
check_band 0 3 3 1 BLOCKED
check_band 1 3 3 1 BLOCKED
check_band 2 3 3 1 DRAFT
check_band 3 3 3 1 DRAFT
# P boundary with C and E floored: still flips at P 1→2, into REWORK not DRAFT.
check_band 1 0 0 0 BLOCKED
check_band 2 0 0 0 REWORK
# C boundary above the P gate: flips at C 1→2.
check_band 3 0 3 3 REWORK
check_band 3 1 3 3 REWORK
check_band 3 2 3 3 DRAFT
check_band 3 3 3 3 DRAFT
check_band 2 1 2 0 REWORK
check_band 2 2 2 0 DRAFT
# E boundary — the newest gate and the least exercised. Flips at E 1→2, at every
# combination of P and C that clears their own gates, and nothing gates at E 2→3.
check_band 3 3 0 3 REWORK
check_band 3 3 1 3 REWORK
check_band 3 3 2 3 DRAFT
check_band 3 3 3 3 DRAFT
check_band 2 2 1 0 REWORK
check_band 2 2 2 0 DRAFT
check_band 2 3 1 2 REWORK
check_band 2 3 2 2 DRAFT
check_band 3 2 1 1 REWORK
check_band 3 2 2 1 DRAFT
# The P gate dominates E: a perfect Edge score below the P gate is still BLOCKED.
check_band 1 3 1 3 BLOCKED
check_band 1 3 2 3 BLOCKED
check_band 1 3 3 3 BLOCKED
# The C gate is not rescued by E: E clearing its gate does not lift a low C.
check_band 3 1 2 3 REWORK
check_band 3 1 3 3 REWORK

echo "  band rule — the plan's falsification table"

check_row() {  # LABEL P C E R BAND SUM
  local f="$WORK/fals-$1.md"
  v2_file "$f" 2026-W40 "$2" "$3" "$4" "$5"
  local got; got="$(eval_py "'%s %s' % (parse_file('$f')[0].band, parse_file('$f')[0].composite)")"
  if [ "$got" = "$6 $7" ]; then ok "$1 → $6 (composite $7)"
  else bad "$1 → want [$6 $7], got [$got]"; fi
}
check_row A2 3 3 3 1 DRAFT 9
check_row A9 2 3 3 1 DRAFT 8
check_row A5 2 2 2 2 DRAFT 6
check_row A7 3 1 3 1 REWORK 7
check_row A8 1 3 3 2 BLOCKED 7
check_row A1 1 3 2 1 BLOCKED 6
check_row A4 1 3 2 2 BLOCKED 6
check_row A6 1 2 2 1 BLOCKED 5
check_row A3 1 2 1 1 BLOCKED 4
# The constructed counter-example that motivated the E gate: a release recap that
# would land in DRAFT and rank third without it.
check_row A10 3 3 1 3 REWORK 7

echo "  band is computed, never read from disk"
BANDFIELD="$WORK/bandfield.md"
{ v2_head 2026-W40 1
  v2_angle 1 3 3 3 3
  printf -- '- **band:** DRAFT\n'
} > "$BANDFIELD"
check_raises "a 'band' field on an angle is rejected as unrecognised" "unrecognised field" \
  "parse_file('$BANDFIELD')"

# ── 2. v1 files parse, and yield None ─────────────────────────────────────────

echo "  v1 — parses without raising, band and composite are None"

V1="$WORK/2026-W31.md"
{ v1_head 2026-W31 2; v1_angle 1; v1_angle 2; } > "$V1"

check_eval "a v1 file parses into records" "2" "len(parse_file('$V1'))"
check_eval "v1 band is None" "None" "parse_file('$V1')[0].band"
check_eval "v1 composite is None" "None" "parse_file('$V1')[0].composite"
check_eval "v1 scores are empty" "{}" "parse_file('$V1')[0].scores"
check_eval "v1 schema_version is 1 when schemaVersion is absent" "1" \
  "parse_file('$V1')[0].schema_version"
check_eval "v1 rows report scored=False" "False" "parse_file('$V1')[0].scored"
check_eval "v1 verdict defaults to pending" "pending" "parse_file('$V1')[0].verdict"
check_eval "the id is <week>/A<n>" "2026-W31/A1" "parse_file('$V1')[0].id"
check_eval "the v1 'risk' field is preserved verbatim" "True" \
  "parse_file('$V1')[0].field('risk').startswith('the sharp version')"
check_eval "evidence bullets are parsed" "1" "len(parse_file('$V1')[0].evidence)"

# The committed v1 fixture, so this parser and the shipped fixture cannot drift
# apart silently. Read-only, from the site repo — never from the studio.
FIXTURE="$REPO_DIR/scripts/tests/fixtures/angles-valid-2026-W31.md"
if [ -f "$FIXTURE" ]; then
  check_eval "the committed v1 fixture parses" "8" "len(parse_file('$FIXTURE'))"
  check_eval "every fixture row is band-less" "True" \
    "all(a.band is None and a.composite is None and not a.scored for a in parse_file('$FIXTURE'))"
else
  skip "fixtures/angles-valid-2026-W31.md is absent"
fi

echo "  v1 — verdicts are legal, predictions are not"

V1V="$WORK/2026-W32.md"
{ v1_head 2026-W32 1; v1_angle 1 "pass — C: nothing a reader owns actually changes"; } > "$V1V"
check_eval "a v1 verdict at slot 7 parses" "pass" "parse_file('$V1V')[0].verdict"
check_eval "its dimension tag is read" "C" "parse_file('$V1V')[0].verdict_dimension"
check_eval "it is still unscored" "False" "parse_file('$V1V')[0].scored"

V1S="$WORK/v1-scored.md"
{ v1_head 2026-W33 1; v1_angle 1
  printf -- '- **score provability:** 3 — smuggled in\n'
} > "$V1S"
check_raises "a score field in a v1 file is rejected" "score provability" "parse_file('$V1S')"

V1B="$WORK/v1-blocker.md"
{ v1_head 2026-W33 1
  cat <<'EOF'

## A1 — Title 1
- **pillar:** 2 — Engineering leadership in the AI era
- **altitude:** enterprise
- **thesis:** thesis
- **why now:** why now
- **evidence:**
  - `[leadership/2026-08-01]` evidence
- **blocker:** none
- **prep:** verify
EOF
} > "$V1B"
check_raises "blocker/prep in a v1 file are rejected" "unrecognised field" "parse_file('$V1B')"

# ── 3. v2 shape — the loud failure modes ──────────────────────────────────────

echo "  v2 — scores"

V2="$WORK/2026-W34.md"
v2_file "$V2" 2026-W34 3 2 2 1
check_eval "a v2 file yields all four scores" \
  "{'provability': 3, 'consequence': 2, 'edge': 2, 'readiness': 1}" \
  "parse_file('$V2')[0].scores"
check_eval "score justifications are kept as telemetry" "True" \
  "parse_file('$V2')[0].score_reasons['edge'].startswith('combines two')"
check_eval "v2 rows report scored=True" "True" "parse_file('$V2')[0].scored"
check_eval "composite excludes Readiness" "7" "parse_file('$V2')[0].composite"

bad_score() {  # NAME VALUE SUBSTRING
  local f="$WORK/badscore.md"
  { v2_head 2026-W34 1
    cat <<EOF

## A1 — Title 1
- **pillar:** 2 — Engineering leadership in the AI era
- **altitude:** enterprise
- **thesis:** thesis
- **why now:** why now
- **evidence:**
  - \`[leadership/2026-08-01]\` evidence
- **blocker:** none
- **prep:** verify
- **verdict:** pending
- **score provability:** $2
- **score consequence:** 2 — because
- **score edge:** 2 — because
- **score readiness:** 2 — because
EOF
  } > "$f"
  check_raises "$1" "$3" "parse_file('$f')"
}
bad_score "score 4 is rejected"    "4 — because"    "integer 0-3"
bad_score "score -1 is rejected"   "-1 — because"   "integer 0-3"
bad_score "score 2.5 is rejected"  "2.5 — because"  "integer 0-3"
bad_score "score 'high' is rejected" "high — because" "integer 0-3"
bad_score "a score with no justification is rejected" "3" "justification"
bad_score "a score with an empty justification is rejected" "3 — " "empty justification"

V2MISS="$WORK/v2-missing.md"
{ v2_head 2026-W34 1
  cat <<'EOF'

## A1 — Title 1
- **pillar:** 2 — Engineering leadership in the AI era
- **altitude:** enterprise
- **thesis:** thesis
- **why now:** why now
- **evidence:**
  - `[leadership/2026-08-01]` evidence
- **blocker:** none
- **prep:** verify
- **verdict:** pending
- **score provability:** 3 — because
- **score consequence:** 2 — because
- **score readiness:** 2 — because
EOF
} > "$V2MISS"
check_raises "a v2 angle missing one dimension is rejected" "score edge" "parse_file('$V2MISS')"

V2VIBES="$WORK/v2-vibes.md"
{ v2_head 2026-W34 1; v2_angle 1 3 3 3 3
  printf -- '- **score vibes:** 3 — feels right\n'
} > "$V2VIBES"
check_raises "'score vibes' is rejected as an unknown field, not accepted by a prefix rule" \
  "score vibes" "parse_file('$V2VIBES')"

echo "  v2 — field order, duplicates and strays"

V2ORDER="$WORK/v2-order.md"
{ v2_head 2026-W34 1
  cat <<'EOF'

## A1 — Title 1
- **pillar:** 2 — Engineering leadership in the AI era
- **altitude:** enterprise
- **thesis:** thesis
- **why now:** why now
- **evidence:**
  - `[leadership/2026-08-01]` evidence
- **blocker:** none
- **prep:** verify
- **score provability:** 3 — because
- **score consequence:** 2 — because
- **score edge:** 2 — because
- **score readiness:** 2 — because
- **verdict:** pending
EOF
} > "$V2ORDER"
check_raises "verdict below the score fields is rejected — it sits above them" \
  "out of canonical order" "parse_file('$V2ORDER')"

V2RISK="$WORK/v2-risk.md"
{ v2_head 2026-W34 1; v2_angle 1 3 3 3 3
  printf -- '- **risk:** the old single field\n'
} > "$V2RISK"
check_raises "'risk' in a v2 file is rejected" "risk" "parse_file('$V2RISK')"

V2DUP="$WORK/v2-dup.md"
{ v2_head 2026-W34 1; v2_angle 1 3 3 3 3
  printf -- '- **prep:** a second one\n'
} > "$V2DUP"
check_raises "a duplicated field is rejected" "two 'prep' fields" "parse_file('$V2DUP')"

V2CONT="$WORK/v2-cont.md"
{ v2_head 2026-W34 1
  cat <<'EOF'

## A1 — Title 1
- **pillar:** 2 — Engineering leadership in the AI era
- **altitude:** enterprise
- **thesis:** a thesis that wrapped
  onto a second line and lost half of itself
- **why now:** why now
- **evidence:**
  - `[leadership/2026-08-01]` evidence
- **blocker:** none
- **prep:** verify
- **verdict:** pending
- **score provability:** 3 — because
- **score consequence:** 2 — because
- **score edge:** 2 — because
- **score readiness:** 2 — because
EOF
} > "$V2CONT"
check_raises "a wrapped field is rejected rather than silently truncated" \
  "every field is one line" "parse_file('$V2CONT')"

V2NEST="$WORK/v2-nest.md"
{ v2_head 2026-W34 1
  cat <<'EOF'

## A1 — Title 1
- **pillar:** 2 — Engineering leadership in the AI era
- **altitude:** enterprise
- **thesis:** thesis
- **why now:** why now
- **evidence:**
  - `[leadership/2026-08-01]` evidence
- **blocker:** none
  - a nested bullet that belongs to nothing
- **prep:** verify
- **verdict:** pending
- **score provability:** 3 — because
- **score consequence:** 2 — because
- **score edge:** 2 — because
- **score readiness:** 2 — because
EOF
} > "$V2NEST"
check_raises "a nested bullet outside evidence is rejected" "only 'evidence' takes a nested list" \
  "parse_file('$V2NEST')"

V2NOEV="$WORK/v2-noev.md"
{ v2_head 2026-W34 1
  cat <<'EOF'

## A1 — Title 1
- **pillar:** 2 — Engineering leadership in the AI era
- **altitude:** enterprise
- **thesis:** thesis
- **why now:** why now
- **evidence:**
- **blocker:** none
- **prep:** verify
- **verdict:** pending
- **score provability:** 3 — because
- **score consequence:** 2 — because
- **score edge:** 2 — because
- **score readiness:** 2 — because
EOF
} > "$V2NOEV"
check_raises "evidence with no nested bullets is rejected" "no nested bullets" "parse_file('$V2NOEV')"

echo "  frontmatter"

for version in 3 0 '"2"' true; do
  f="$WORK/schema-ver.md"
  { printf -- '---\nweek: 2026-W34\ngenerated: 2026-08-09\ncorpusCoverage: "x"\nangleCount: 1\nschemaVersion: %s\n---\n' "$version"
    v2_angle 1 3 3 3 3; } > "$f"
  check_raises "schemaVersion $version is rejected" "schemaVersion must be one of" "parse_file('$f')"
done

MISWEEK="$WORK/2026-W35.md"
v2_file "$MISWEEK" 2026-W34 3 3 3 3
check_raises "a frontmatter week disagreeing with the filename is rejected" \
  "but the file is named" "parse_file('$MISWEEK')"

BADWEEK="$WORK/badweek.md"
{ printf -- '---\nweek: August\ngenerated: 2026-08-09\ncorpusCoverage: "x"\nangleCount: 1\nschemaVersion: 2\n---\n'
  v2_angle 1 3 3 3 3; } > "$BADWEEK"
check_raises "a malformed week is rejected" "must match YYYY-Www" "parse_file('$BADWEEK')"

SEQ="$WORK/seq.md"
{ v2_head 2026-W34 2; v2_angle 1 3 3 3 3; v2_angle 3 3 3 3 3; } > "$SEQ"
check_raises "non-sequential angle headings are rejected" "number sequentially" "parse_file('$SEQ')"

OUTSIDE="$WORK/outside.md"
{ v2_head 2026-W34 1; v2_angle 1 3 3 3 3; printf -- '\n## Notes\nsomething\n'; } > "$OUTSIDE"
check_raises "a non-angle heading is rejected" "not a '## A<n>' heading" "parse_file('$OUTSIDE')"

# ── 4. Verdicts ───────────────────────────────────────────────────────────────

echo "  verdicts"

verdict_file() {  # LINE -> path
  local f="$WORK/verdict.md"
  v2_file "$f" 2026-W34 3 3 3 3 "$1"
  echo "$f"
}

VF="$(verdict_file 'pending')"
check_eval "pending carries no dimension and no reason" "pending None None" \
  "'%s %s %s' % (parse_file('$VF')[0].verdict, parse_file('$VF')[0].verdict_dimension, parse_file('$VF')[0].verdict_reason)"

VF="$(verdict_file 'post — the arithmetic framing is the whole post')"
check_eval "post keeps its reason" "post" "parse_file('$VF')[0].verdict"
check_eval "post needs no dimension tag" "None" "parse_file('$VF')[0].verdict_dimension"
check_eval "post's reason is kept" "the arithmetic framing is the whole post" \
  "parse_file('$VF')[0].verdict_reason"

VF="$(verdict_file 'pass — C: nothing a reader owns actually changes')"
check_eval "pass with a C tag" "pass C nothing a reader owns actually changes" \
  "'%s %s %s' % (parse_file('$VF')[0].verdict, parse_file('$VF')[0].verdict_dimension, parse_file('$VF')[0].verdict_reason)"

VF="$(verdict_file 'maybe — E: derivable in one step from the release notes')"
check_eval "maybe with an E tag" "E" "parse_file('$VF')[0].verdict_dimension"

VF="$(verdict_file 'maybe — —: none of the four dimensions covers it')"
check_eval "the none-of-the-above tag is read, not treated as prose" "—" \
  "parse_file('$VF')[0].verdict_dimension"
check_eval "and its reason survives the tag" "none of the four dimensions covers it" \
  "parse_file('$VF')[0].verdict_reason"

# A missing tag is a warning `kickoff judge` prints, never a parse failure. A
# mechanical rule punishing an honest human field teaches the human to stop
# writing the field, and the reason is the only free-text signal the loop has.
VF="$(verdict_file 'pass — nothing changes')"
check_eval "an untagged pass parses rather than raising" "pass" "parse_file('$VF')[0].verdict"
check_eval "and reports no dimension, so judge can warn" "None" \
  "parse_file('$VF')[0].verdict_dimension"
check_eval "while keeping the reason" "nothing changes" "parse_file('$VF')[0].verdict_reason"

# The citation guard belongs to the validator and is scoped to evidence and why
# now. A human writing a bracketed slug in a verdict reason must not lose a week.
VF="$(verdict_file 'pass — E: the [leadership/2026-08-01] framing is already stale')"
check_eval "an un-backticked citation in a verdict reason parses cleanly" \
  "the [leadership/2026-08-01] framing is already stale" "parse_file('$VF')[0].verdict_reason"

VF="$(verdict_file 'yes')"
check_raises "an out-of-vocabulary verdict is rejected" "must be one of" "parse_file('$VF')"

# ── 5. Mixed windows — v1 must stay out of every rate ─────────────────────────

echo "  mixed window — v1 rows are counted apart"

STUDIO="$WORK/studio"
mkdir -p "$STUDIO/angles"
{ v1_head 2026-W31 9
  for n in 1 2 3 4 5 6 7 8 9; do v1_angle "$n" "pass — P: cannot be published"; done
} > "$STUDIO/angles/2026-W31.md"
{ v2_head 2026-W32 3
  v2_angle 1 3 3 3 1 'post — the whole post'
  v2_angle 2 3 3 1 3 'pass — E: one step from the release notes'
  v2_angle 3 1 3 3 2 'pending'
} > "$STUDIO/angles/2026-W32.md"

check_eval "available_weeks lists both, ascending" "['2026-W31', '2026-W32']" \
  "available_weeks('$STUDIO')"
check_eval "the window loads 12 rows" "12" "len(load_weeks('$STUDIO'))"
check_eval "split_scored puts the 3 v2 rows in scored" "3" \
  "len(split_scored(load_weeks('$STUDIO')).scored)"
check_eval "and the 9 v1 rows in unscored" "9" \
  "len(split_scored(load_weeks('$STUDIO')).unscored)"
check_eval "summarize reports unscored as its own number" "9" \
  "summarize(load_weeks('$STUDIO'))['unscored']"
check_eval "summarize's scored count is the rate denominator" "3" \
  "summarize(load_weeks('$STUDIO'))['scored']"
check_eval "band counts are over scored rows only" "3" \
  "sum(summarize(load_weeks('$STUDIO'))['bands'].values())"
check_eval "unscored weeks are named separately" "['2026-W31']" \
  "summarize(load_weeks('$STUDIO'))['unscored_weeks']"
check_eval "no unscored row ever carries a band" "True" \
  "all(a.band is None for a in split_scored(load_weeks('$STUDIO')).unscored)"
# The artefact this guards against: 9 band-less v1 rows folded into a rate over
# 3 v2 rows reads as ~75% agreement and looks like a signal.
check_eval "a naive total is not the scored count" "True" \
  "len(load_weeks('$STUDIO')) != summarize(load_weeks('$STUDIO'))['scored']"

check_eval "load ordering is oldest week first, file order within a week" "True" \
  "[a.id for a in load_weeks('$STUDIO')] == ['2026-W31/A%d' % n for n in range(1, 10)] + ['2026-W32/A%d' % n for n in range(1, 4)]"
check_eval "since counts weeks that have files, not calendar weeks" "['2026-W32']" \
  "sorted({a.week for a in load_weeks('$STUDIO', since=1)})"
check_eval "since=1 loads only the newest week" "3" "len(load_weeks('$STUDIO', since=1))"
check_eval "since=2 loads both" "12" "len(load_weeks('$STUDIO', since=2))"
check_raises "since=0 is rejected" "1 or more" "load_weeks('$STUDIO', since=0)"
check_raises "weeks and since together are rejected" "not both" \
  "load_weeks('$STUDIO', weeks=['2026-W31'], since=1)"
check_raises "a missing week is named, with its path" "no angles file for 2026-W40" \
  "load_week('$STUDIO', '2026-W40')"

# ── 6. Cross-implementation — the validator's own fixtures ────────────────────
#
# Two readings of one format drifting apart is this project's recurring bug, and
# these fixtures are the validator's side of the contract. Every one is guarded
# on existence: they belong to S4.5.2/S4.5.3/S4.5.5 and this suite must not turn
# red because one was renamed. A missing fixture is a skip, never a failure.

echo "  cross-implementation — the validator's fixtures parse identically here"

FIX2="$REPO_DIR/scripts/tests/fixtures/angles-valid-2026-W32-scored.md"
if [ -f "$FIX2" ]; then
  check_eval "the v2 fixture is fully scored" "True" \
    "all(a.scored and len(a.scores) == 4 for a in parse_file('$FIX2'))"
  check_eval "and every verdict in it is pending, as generated" "True" \
    "all(a.verdict == 'pending' for a in parse_file('$FIX2'))"
  check_eval "its bands come out of the gate rule, not the file" "True" \
    "all(a.band == compute_band(a.scores) for a in parse_file('$FIX2'))"
else
  skip "fixtures/angles-valid-2026-W32-scored.md is absent (S4.5.2)"
fi

FIXJ="$REPO_DIR/scripts/tests/fixtures/angles-judged-2026-W32.md"
if [ -f "$FIXJ" ]; then
  check_eval "the judged fixture parses with real verdicts" "True" \
    "all(a.verdict in VERDICTS for a in parse_file('$FIXJ'))"
  check_eval "every maybe/pass in it carries a dimension tag" "True" \
    "all(a.verdict_dimension in DIMENSION_TAGS for a in parse_file('$FIXJ') if a.verdict in ('maybe', 'pass'))"
else
  skip "fixtures/angles-judged-2026-W32.md is absent (S4.5.3)"
fi

FIXV1="$REPO_DIR/scripts/tests/fixtures/angles-v1-verdicts-2026-W31.md"
if [ -f "$FIXV1" ]; then
  check_eval "the v1-with-verdicts fixture yields verdicts and no predictions" "True" \
    "all(not a.scored and a.band is None for a in parse_file('$FIXV1'))"
  check_eval "and at least one of its verdicts is a real judgement" "True" \
    "any(a.verdict != 'pending' for a in parse_file('$FIXV1'))"
else
  skip "fixtures/angles-v1-verdicts-2026-W31.md is absent (S4.5.5)"
fi

# ── 7. CLI ────────────────────────────────────────────────────────────────────

echo "  CLI"

run_cli() {  # ARGS...
  ( unset STUDIO_DIR; cd "$WORK" && "$PYBIN" "$MODDIR/angles_index.py" "$@" ) \
    >"$WORK/out.txt" 2>"$WORK/cli-err.txt"
}

run_cli --studio-dir "$STUDIO"
if [ $? = 0 ] && grep -qF '12 angle(s) · 3 scored (v2) · 9 unscored' <"$WORK/out.txt"; then
  ok "the CLI footer names the unscored count separately"
else
  bad "CLI footer: $(cat "$WORK/out.txt" "$WORK/cli-err.txt")"
fi
if grep -qF 'excluded from every rate' <"$WORK/out.txt"; then
  ok "and says what the unscored rows are excluded from"
else bad "CLI footer does not say the v1 rows are excluded from rates"; fi

run_cli --studio-dir "$STUDIO" --since 1 --json
if [ $? = 0 ] && "$PYBIN" - "$WORK/out.txt" <<'PYEOF'
import json
import sys

rows = json.load(open(sys.argv[1]))
assert len(rows) == 3, rows
assert [r["band"] for r in rows] == ["DRAFT", "REWORK", "BLOCKED"], rows
assert all(r["scored"] for r in rows)
assert rows[0]["composite"] == 9, rows[0]
assert rows[1]["verdictDimension"] == "E", rows[1]
PYEOF
then ok "--json emits band, composite, scored and the dimension tag"
else bad "--json: $(head -c 400 "$WORK/out.txt") $(cat "$WORK/cli-err.txt")"; fi

run_cli
if [ $? != 0 ] && grep -qF 'resolve_studio_dir()' <"$WORK/cli-err.txt"; then
  ok "with no STUDIO_DIR it refuses to guess and names where the answer lives"
else bad "expected the D5 refusal, got: $(cat "$WORK/cli-err.txt")"; fi

run_cli --studio-dir "$STUDIO" --week 2026-W31 --since 1
if [ $? != 0 ] && grep -qF 'mutually exclusive' <"$WORK/cli-err.txt"; then
  ok "--week and --since together are refused"
else bad "expected mutual exclusion, got: $(cat "$WORK/cli-err.txt")"; fi

run_cli --file "$V2CONT"
if [ $? != 0 ] && grep -qF 'angles_index: ERROR' <"$WORK/cli-err.txt"; then
  ok "a parse failure exits non-zero with a PROG-prefixed message"
else bad "expected a prefixed error, got: $(cat "$WORK/cli-err.txt")"; fi

# ── 8. Reads only ─────────────────────────────────────────────────────────────

echo "  reads only"

before="$(find "$STUDIO" -type f -exec shasum {} \; | sort)"
run_cli --studio-dir "$STUDIO" >/dev/null 2>&1
run_cli --studio-dir "$STUDIO" --json >/dev/null 2>&1
after="$(find "$STUDIO" -type f -exec shasum {} \; | sort)"
[ "$before" = "$after" ] && ok "the studio is byte-identical after two full runs" \
  || bad "the studio changed under a read-only module"

echo
if [ "$FAIL" = "0" ]; then echo "  $COUNT assertion(s), all passed"
else echo "  $COUNT assertion(s), FAILURES above"; fi
exit "$FAIL"
