#!/usr/bin/env python3
"""Validate a generated angles file — Epic 4, S4.3 (shape) and S4.8 (citations).

    python3 scripts/lib/validate_angles.py FILE [--repo-dir DIR] [--studio-dir DIR]

Exits 0 silently, or prints every problem on one `; `-joined line to stderr and
exits 1. Called by validate_frontmatter() in scripts/lib/run-llm-job.sh for a job
declaring `schema: angles`; that caller quarantines the file and fails the run.

Extracted to its own module rather than inlined as a heredoc, the way
scripts/lib/bundle.py was: this has enough branches to need its own tests, and a
heredoc cannot be run on its own.

Every problem is reported, not just the first, and every failing citation is
named in full. A validator that says "a citation failed" makes the operator diff
eight angles by hand.

The contract (Epic 4):

    ---
    week: 2026-W31
    generated: 2026-08-02
    corpusCoverage: "leadership 2/2 · ai 11/12 (gap 2026-07-29)"
    angleCount: 8
    ---

    ## A1 — Review became the bottleneck, and nobody owned it
    - **pillar:** 2 — Engineering leadership in the AI era
    - **altitude:** enterprise
    - **thesis:** one sentence, arguable, falsifiable
    - **why now:** the peg, with a link
    - **evidence:**
      - `[leadership/2026-08-01]` AI-coding agents kill collaboration — https://…
      - `[note 2026-07-29]` three teams stalled at the same place
    - **risk:** touches internal specifics

Seven required things per angle: the heading title, and the six labelled fields.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from datetime import date as Date
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover — matches select_corpus.py's guard
    print("Missing deps. Run: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

REPO_DIR = Path(__file__).resolve().parent.parent.parent

# The note file format has exactly one reader and one writer, and this is
# neither: `scripts/studio/select_corpus.py` already parses `notes/YYYY-MM.md`,
# and `scripts/studio/kickoff` writes it. A second copy of that header regex is
# the drift class this project has been bitten by, so import the parser across
# directories instead of re-deriving the format here. The module has no import
# side effects beyond putting scripts/lib on sys.path.
sys.path.insert(0, str(REPO_DIR / "scripts" / "studio"))
from select_corpus import months_in_window, parse_notes_file  # noqa: E402

WEEK_RE = re.compile(r"^\d{4}-W\d{2}$")

# The deliverable is "6–10 candidates, of which a human would genuinely post 3".
# Enforced rather than merely requested, because scripts/prompts/posts/angles.md
# states it to the model as a hard rule — a prompt that claims a validator will
# reject something it silently accepts trains the next reader to disbelieve the
# rest of it. A run outside the range is recoverable: the file is quarantined
# into scripts/logs/ rather than deleted, and the job can be re-run the same day.
MIN_ANGLES = 6
MAX_ANGLES = 10

# Counting keys on `## A<n>` alone, so angleCount and the sequence check still
# work on a heading whose separator or title is malformed — those are reported
# as their own problems rather than making the angle invisible.
HEADING_RE = re.compile(r"^##\s+A(\d+)\b(.*)$")
ANY_HEADING_RE = re.compile(r"^##\s")
TITLE_RE = re.compile(r"^\s*—\s*\S")

FIELD_RE = re.compile(r"^-\s+\*\*([^:*]+):\*\*\s*(.*)$")
NESTED_BULLET_RE = re.compile(r"^\s+-\s+\S")
REQUIRED_FIELDS = ("pillar", "altitude", "thesis", "why now", "evidence", "risk")

# Months 1-3 are enterprise altitude only. The small-business surface is gated
# behind an unresolved employer-policy question, so an `smb` angle is not a
# stylistic slip — it is the one output here with a compliance cost.
ALLOWED_ALTITUDES = ("enterprise",)
PILLAR_RE = re.compile(r"^[1-4](\s|$)")

# Citations are always inside backticks, so prose mentioning a bracket is not a
# citation and a citation cannot hide in a URL.
CITATION_RE = re.compile(r"`\[([^\]`]*)\]`")
NOTE_CITE_RE = re.compile(r"^note\s+(\d{4}-\d{2}-\d{2})$")
DIGEST_CITE_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)/(\d{4}-\d{2}-\d{2})$")

# The same tokens *without* their backticks. Requiring backticks and then only
# checking what has them is a guard that fails open: a model that drops the
# backticks gets its evidence waved through unverified, which is the one thing
# S4.8 exists to prevent. Shaped like a citation is treated as a citation, and a
# missing backtick is reported as its own problem rather than silently excusing
# the reference.
BARE_CITE_RE = re.compile(
    r"(?<![`\w])\[((?:note\s+\d{4}-\d{2}-\d{2})"
    r"|(?:[A-Za-z0-9][A-Za-z0-9._-]*/\d{4}-\d{2}-\d{2}))\](?!`)")


def split_frontmatter(lines: list) -> tuple:
    """(frontmatter dict, index of the closing delimiter, problem-or-None)."""
    if not lines or lines[0].strip() != "---":
        return {}, -1, "no opening frontmatter delimiter"
    end = None
    for i, line in enumerate(lines[1:], 1):
        if line.strip() == "---":
            end = i
            break
    if end is None:
        return {}, -1, "unterminated frontmatter"
    try:
        fm = yaml.safe_load("\n".join(lines[1:end])) or {}
    except yaml.YAMLError as exc:
        return {}, end, "frontmatter is not valid YAML: %s" % exc
    if not isinstance(fm, dict):
        return {}, end, "frontmatter is not a mapping"
    return fm, end, None


def check_frontmatter(fm: dict, heading_count: int) -> list:
    problems = []
    week = fm.get("week")
    if week in (None, "", []):
        problems.append("missing required field: week")
    elif not (isinstance(week, str) and WEEK_RE.match(week)):
        problems.append("week must match YYYY-Www, got %r" % (week,))
    for key in ("generated", "corpusCoverage"):
        if fm.get(key) in (None, "", []):
            problems.append("missing required field: %s" % key)

    count = fm.get("angleCount")
    if count is None or count == "":
        problems.append("missing required field: angleCount")
    elif isinstance(count, bool) or not isinstance(count, int):
        problems.append("angleCount must be a positive integer, got %r" % (count,))
    elif count < 1:
        problems.append("angleCount must be a positive integer, got %r" % (count,))
    elif count != heading_count:
        problems.append("angleCount is %d but the file has %d '## A<n>' heading(s)"
                        % (count, heading_count))

    # Against the headings, not against angleCount: a file claiming 8 while
    # carrying 3 must report the count mismatch above and the shortfall here,
    # rather than being judged on the number it asserted about itself.
    if heading_count and not MIN_ANGLES <= heading_count <= MAX_ANGLES:
        problems.append("expected %d-%d angles, got %d"
                        % (MIN_ANGLES, MAX_ANGLES, heading_count))
    return problems


def parse_angles(lines: list, start: int) -> tuple:
    """([{n, title_tail, body lines}], problems). Body runs to the next `## `."""
    angles, problems, stray = [], [], []
    current = None
    for line in lines[start:]:
        match = HEADING_RE.match(line)
        if match:
            if current is not None:
                angles.append(current)
            current = {"n": int(match.group(1)), "tail": match.group(2),
                       "heading": line.rstrip(), "body": []}
        elif ANY_HEADING_RE.match(line):
            if current is not None:
                angles.append(current)
            current = None
            problems.append("content outside any angle: %r is not a '## A<n>' heading"
                            % line.rstrip())
        elif current is not None:
            current["body"].append(line)
        elif line.strip():
            # Preamble, commentary, or a stray code fence. The prompt forbids
            # anything outside the frontmatter and the angle sections, and prose
            # here is the one place a claim can appear carrying no citation and
            # so facing none of the checks below.
            stray.append(line.rstrip())
    if current is not None:
        angles.append(current)

    if stray:
        problems.append("content outside any angle section: %s"
                        % "; ".join(repr(x) for x in stray[:3]))
    for i, angle in enumerate(angles, 1):
        if angle["n"] != i:
            problems.append("angle headings must number sequentially from 1: "
                            "expected '## A%d', got %r" % (i, angle["heading"]))
    return angles, problems


def check_angle_fields(angle: dict) -> list:
    problems = []
    label = "A%d" % angle["n"]
    if not TITLE_RE.match(angle["tail"]):
        problems.append("%s heading has no '— <title>': %r" % (label, angle["heading"]))

    seen = {}
    order = []
    for idx, line in enumerate(angle["body"]):
        match = FIELD_RE.match(line)
        if match:
            name = match.group(1).strip().lower()
            seen[name] = (idx, match.group(2).strip())
            order.append(name)
    for field in REQUIRED_FIELDS:
        if field not in seen:
            problems.append("%s is missing the '%s' field" % (label, field))
        elif field != "evidence" and not seen[field][1]:
            problems.append("%s has an empty '%s' field" % (label, field))

    if "pillar" in seen and seen["pillar"][1] and not PILLAR_RE.match(seen["pillar"][1]):
        problems.append("%s 'pillar' must open with a digit 1-4, got %r"
                        % (label, seen["pillar"][1]))
    if "altitude" in seen and seen["altitude"][1] \
            and seen["altitude"][1] not in ALLOWED_ALTITUDES:
        problems.append("%s 'altitude' is %r — only %s is in scope while Epic 8 is gated"
                        % (label, seen["altitude"][1], " or ".join(ALLOWED_ALTITUDES)))

    if "evidence" in seen:
        if seen["evidence"][1]:
            problems.append("%s 'evidence' has text on its own line (%r) — it must be a "
                            "nested list beneath it" % (label, seen["evidence"][1]))
        idx = seen["evidence"][0]
        bullets = 0
        evidence_lines = []
        # A blank stops the list rather than being skipped over. The contract
        # puts the bullets immediately beneath `evidence:`, and Epic 5 has to
        # parse these files — tolerating a gap here means tolerating it there.
        for line in angle["body"][idx + 1:]:
            if NESTED_BULLET_RE.match(line):
                bullets += 1
                evidence_lines.append(line)
            else:
                break
        if bullets == 0:
            problems.append("%s 'evidence' has no nested bullets" % label)
        elif not CITATION_RE.search("\n".join(evidence_lines)):
            # Checking citations only where they appear would let an angle opt
            # out of the guard by citing nothing at all. An angle's whole value
            # is that its evidence is real and yours, so evidence with no
            # resolvable reference is not evidence.
            problems.append("%s 'evidence' carries no `[theme/date]` or "
                            "`[note date]` citation" % label)
    return problems


def resolve_note(studio: Path, day: str) -> bool:
    """A note headed `day` in studio/notes/<YYYY-MM>.md. months_in_window over a
    single day yields exactly that month, so the file layout is not restated."""
    iso = Date(int(day[0:4]), int(day[5:7]), int(day[8:10]))
    for month in months_in_window(iso, iso):
        path = studio / "notes" / ("%s.md" % month)
        if not path.is_file():
            continue
        for entry in parse_notes_file(path):
            if entry["date"] == day:
                return True
    return False


def check_citations(text: str, content_dir: Path, studio) -> list:
    """S4.8. The cheapest anti-fabrication guard there is: an angle citing a
    digest that does not exist is worse than no angle, because it reads as
    credible."""
    problems, seen = [], set()

    # Reported, not quietly validated: the shape is the contract, and a file
    # that drifts off it once will drift further. Naming it keeps the prompt
    # honest instead of teaching the validator to accept two spellings.
    for match in BARE_CITE_RE.finditer(text):
        problems.append("citation [%s] is missing its backticks — write "
                        "`[%s]`" % (match.group(1), match.group(1)))

    for match in CITATION_RE.finditer(text):
        token = match.group(1).strip()
        if token in seen:
            continue
        seen.add(token)

        note = NOTE_CITE_RE.match(token)
        if note:
            if studio is None:
                problems.append("citation `[%s]` cannot be checked: STUDIO_DIR is not set"
                                % token)
            elif not resolve_note(studio, note.group(1)):
                problems.append("citation `[%s]` does not resolve: no note dated %s in %s"
                                % (token, note.group(1), studio / "notes"))
            continue

        digest = DIGEST_CITE_RE.match(token)
        if digest:
            path = content_dir / digest.group(1) / ("%s.md" % digest.group(2))
            if not path.is_file():
                problems.append("citation `[%s]` does not resolve: no file at %s"
                                % (token, path))
            continue

        problems.append("citation `[%s]` is neither `[<theme>/<YYYY-MM-DD>]` nor "
                        "`[note <YYYY-MM-DD>]`" % token)
    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description="Validate a generated angles file.")
    ap.add_argument("path")
    ap.add_argument("--repo-dir", default=str(REPO_DIR),
                    help="Site repo root, for resolving [<theme>/<date>] citations")
    ap.add_argument("--content-dir", default=None,
                    help="Digest collections root, overriding <repo-dir>/src/content. "
                         "A test seam: it lets a suite point this validator at a "
                         "fixture corpus, so the shipped validator is what gets "
                         "exercised rather than a stand-in. Production never passes it")
    ap.add_argument("--studio-dir", default=os.environ.get("STUDIO_DIR") or "",
                    help="Studio path, for resolving [note <date>] citations. "
                         "Defaults to $STUDIO_DIR; never resolved here (D5)")
    args = ap.parse_args()

    try:
        text = Path(args.path).read_text(encoding="utf-8")
    except OSError as exc:
        print("cannot read %s (%s)" % (args.path, exc), file=sys.stderr)
        return 1
    lines = text.split("\n")

    fm, end, fm_problem = split_frontmatter(lines)
    if fm_problem and end < 0:
        print(fm_problem, file=sys.stderr)
        return 1

    angles, problems = parse_angles(lines, end + 1)
    if fm_problem:
        problems.insert(0, fm_problem)
    else:
        problems = check_frontmatter(fm, len(angles)) + problems
    for angle in angles:
        problems += check_angle_fields(angle)
    if not angles:
        problems.append("no '## A<n>' angle headings found")

    studio = Path(args.studio_dir) if args.studio_dir else None
    content_dir = Path(args.content_dir) if args.content_dir \
        else Path(args.repo_dir) / "src" / "content"
    problems += check_citations(text, content_dir, studio)

    if problems:
        print("; ".join(problems), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
