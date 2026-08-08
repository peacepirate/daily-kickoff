#!/usr/bin/env python3
"""Parse angle files into records — Epic 4.5, S4.5.6. One parser, three consumers.

    python3 scripts/studio/angles_index.py [--week 2026-W31 | --since 2 | --file PATH]
                                           [--studio-dir DIR] [--json]

`kickoff judge`, the calibration report and Epic 5's `kickoff draft` all read the
angle format. They read it **here**. This project's recurring bug is two readings
of one format drifting apart; a fourth reading must not be written, and the three
consumers above must never re-parse markdown themselves.

Reads only. Nothing under `$STUDIO_DIR` or `src/content/**` is ever opened for
writing.

## The public interface

Constants — the format, in one place each:

    SCORE_FIELDS            ("provability", "consequence", "edge", "readiness")
    SCORE_ABBREV            dimension -> "P" / "C" / "E" / "R"
    V1_FIELD_ORDER          the canonical field order, v1
    V2_FIELD_ORDER          the canonical field order, v2 (derived from SCORE_FIELDS)
    VERDICTS                ("pending", "post", "maybe", "pass")
    DIMENSION_TAGS          ("P", "C", "E", "R", "—")
    BLOCKED / REWORK / DRAFT

Types and errors:

    Angle                   one record; see below
    Split                   (scored, unscored) — see "v1 rows" below
    ParseError              every failure mode in this module raises this

Functions:

    compute_band(scores)        the gate rule; None for an unscored angle
    compute_composite(scores)   P + C + E; None for an unscored angle
    parse_text(text, source=…)  -> [Angle]
    parse_file(path)            -> [Angle]
    available_weeks(studio)     -> ["2026-W31", …] sorted ascending
    load_week(studio, week)     -> [Angle]
    load_weeks(studio, weeks=None, since=None) -> [Angle], file order within week
    split_scored(angles)        -> Split(scored=[…], unscored=[…])
    summarize(angles)           -> counts, including `unscored` as its own number

An `Angle` carries `week`, `id` (`2026-W31/A1`), `n`, `title`, `path`,
`schema_version`, `generated`, `fields` (every labelled field verbatim, by its
canonical name), `evidence`, `scores`, `score_reasons`, `band`, `composite`,
`verdict`, `verdict_dimension`, `verdict_reason`, and the `scored` property.

## Three things this module is emphatic about

**`band` is computed, never read from disk.** No angle file carries a band and
none ever should; a stored band is a second copy of a derived fact, and the two
copies diverge the first time a threshold moves. `compute_band()` implements the
S4.5.6 gate rule and is the only place it exists.

**v1 files parse without raising, yielding `composite is None` and `band is
None`.** They legitimately have no scores: `2026-W31.md` predates the rubric and
must never be back-filled, because a hand-written prediction the model never made
is indistinguishable from a real row forever. A consumer that assumes a composite
exists is the bug this guards against, so the absence is a `None` the type system
makes you handle rather than a `0` that quietly ranks last.

**v1 rows are excludable from every rate, and the module makes that the easy
path.** `Angle.scored` is the discriminator, `split_scored()` does the split, and
`summarize()` reports `unscored` as its own number rather than folding it into a
total. W31 contributes 9 band-less rows against W32's ~3 scored ones: counted
naively the first calibration report is ~75% artefact and looks like a signal.

## Failure modes are loud

Every structural violation raises `ParseError` naming the file, the angle and the
field. This module is deliberately the strictest reader of the format — stricter
than `validate_angles.py` in one respect, in that a line inside an angle body
that is neither a labelled field nor an evidence bullet is an error rather than
being skipped. A silently-truncated `thesis:` reaching Epic 5's drafter is worse
than a run that stops and says which line it could not read.

Design decisions worth knowing before changing anything here:

* **`STUDIO_DIR` is not resolved here.** `resolve_studio_dir()` in
  `scripts/lib/job-config.sh` is the single source of truth; this script takes
  the answer via `--studio-dir` or the `STUDIO_DIR` environment variable and
  refuses to guess. Same policy as `select_corpus.py` (D5).
* **Nothing is imported from `validate_angles.py`.** The validator is the gate
  and this is the reader; they run in different processes for different callers,
  and the constants they share are few and small. The order tables in both derive
  from the same section of the epic plan.
* **`SCORE_FIELDS` is an explicit constant, not a `score ` prefix rule.** A
  prefix whitelist accepts `score vibes: 3 — feels right`, holing the guard by
  the mechanism chosen to make it extensible. Adding a dimension later is a
  one-line edit to that tuple; the field labels and the v2 order derive from it.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import NamedTuple

try:
    import yaml
except ImportError:  # pragma: no cover — matches select_corpus.py's guard
    print("Missing deps. Run: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

PROG = "angles_index"

# ── The format ────────────────────────────────────────────────────────────────

WEEK_RE = re.compile(r"^\d{4}-W\d{2}$")

# Same shapes as validate_angles.py, deliberately re-declared rather than
# imported — see the module docstring. Any change to one is a change to both.
HEADING_RE = re.compile(r"^##\s+A(\d+)\b(.*)$")
ANY_HEADING_RE = re.compile(r"^##\s")
TITLE_RE = re.compile(r"^\s*—\s*(\S.*)$")
FIELD_RE = re.compile(r"^-\s+\*\*([^:*]+):\*\*\s*(.*)$")
NESTED_BULLET_RE = re.compile(r"^\s+-\s+(\S.*)$")

# The four dimensions, in canonical order. Field labels and the v2 field order
# both derive from this tuple; nothing else in this module spells them out.
SCORE_FIELDS = ("provability", "consequence", "edge", "readiness")
SCORE_ABBREV = {"provability": "P", "consequence": "C", "edge": "E", "readiness": "R"}
SCORE_LABELS = tuple("score %s" % dim for dim in SCORE_FIELDS)

SCORE_MIN, SCORE_MAX = 0, 3

# The canonical field order, from the epic plan's table. `verdict` is optional at
# v1 (W31 gets real verdicts and no predictions) and required at v2.
V1_FIELD_ORDER = ("pillar", "altitude", "thesis", "why now", "evidence", "risk", "verdict")
V1_REQUIRED = tuple(f for f in V1_FIELD_ORDER if f != "verdict")
V2_FIELD_ORDER = ("pillar", "altitude", "thesis", "why now", "evidence",
                  "blocker", "prep", "verdict") + SCORE_LABELS
V2_REQUIRED = V2_FIELD_ORDER

SCHEMA_VERSIONS = (1, 2)

VERDICTS = ("pending", "post", "maybe", "pass")
# `—` is none-of-the-above, and doubles as the underfit detector: if it exceeds
# ~20% of reasons over six weeks, a dimension is missing from the rubric.
DIMENSION_TAGS = tuple(SCORE_ABBREV[d] for d in SCORE_FIELDS) + ("—",)
VERDICT_TAG_RE = re.compile(r"^(%s):\s*(.*)$" % "|".join(re.escape(t) for t in DIMENSION_TAGS))

EM_DASH = "—"

# ── Bands ─────────────────────────────────────────────────────────────────────

BLOCKED = "BLOCKED"
REWORK = "REWORK"
DRAFT = "DRAFT"
BANDS = (DRAFT, REWORK, BLOCKED)

# The gate rule. Provability gates rather than sums: an unweighted total lets a
# compelling unpublishable angle outrank a modest publishable one, which is
# exactly the first run's failure. `E >= 2` is the "derivable in one step"
# boundary the model judges reliably; nothing gates at `E >= 3`, the novelty
# boundary, which it does not.
GATE_P = 2
GATE_C = 2
GATE_E = 2

# The three gating dimensions, and separately the three the composite sums. They
# coincide today and are still two constants: one is a rule about what can stop
# an angle, the other is a reporting convenience, and collapsing them would let a
# change to either silently redefine the other.
GATE_FIELDS = ("provability", "consequence", "edge")

# The composite excludes Readiness on purpose: R measures work-to-draft, not
# quality, and adding it would let a cheap angle outrank a strong one. This is
# the `Sum` column of the epic plan's falsification table. It is reported and it
# never sets a band.
COMPOSITE_FIELDS = ("provability", "consequence", "edge")


class ParseError(Exception):
    """A file that cannot be read as angles. Never raised for a v1 file."""


def compute_band(scores):
    """The band for one score set, or None when there are no scores.

    Computed here and nowhere else. No angle file stores a band.
    """
    if not scores:
        return None
    missing = [d for d in GATE_FIELDS if d not in scores]
    if missing:
        raise ParseError("cannot band a partial score set: missing %s" % ", ".join(missing))
    p = scores["provability"]
    c = scores["consequence"]
    e = scores["edge"]
    if p < GATE_P:
        return BLOCKED
    if c < GATE_C or e < GATE_E:
        return REWORK
    return DRAFT


def compute_composite(scores):
    """Unweighted `P + C + E`, or None when there are no scores. Weights are
    Epic 7's, beside `selection.weights`; unweighted until there is data."""
    if not scores:
        return None
    missing = [d for d in COMPOSITE_FIELDS if d not in scores]
    if missing:
        raise ParseError("cannot total a partial score set: missing %s" % ", ".join(missing))
    return sum(scores[d] for d in COMPOSITE_FIELDS)


# ── The record ────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Angle:
    """One angle. `scores`, `band` and `composite` are empty/None at v1."""

    week: str
    n: int
    title: str
    schema_version: int
    fields: dict
    evidence: tuple
    scores: dict
    score_reasons: dict
    band: str | None
    composite: int | None
    verdict: str
    verdict_dimension: str | None
    verdict_reason: str | None
    generated: str = ""
    path: str = ""

    @property
    def id(self) -> str:
        return "%s/A%d" % (self.week, self.n)

    @property
    def scored(self) -> bool:
        """True iff this angle carries model predictions — i.e. iff it may enter
        a rate. False for every v1 row, whose verdict is real but whose
        prediction never existed."""
        return self.band is not None

    def field(self, name: str):
        """One labelled field verbatim, or None. `risk` at v1 and `blocker` at v2
        are different fields and are not merged: only one of them was ever a
        promise about what cannot be published."""
        return self.fields.get(name)

    def as_dict(self) -> dict:
        return {
            "id": self.id,
            "week": self.week,
            "n": self.n,
            "title": self.title,
            "path": self.path,
            "schemaVersion": self.schema_version,
            "generated": self.generated,
            "scored": self.scored,
            "fields": dict(self.fields),
            "evidence": list(self.evidence),
            "scores": dict(self.scores),
            "scoreReasons": dict(self.score_reasons),
            "band": self.band,
            "composite": self.composite,
            "verdict": self.verdict,
            "verdictDimension": self.verdict_dimension,
            "verdictReason": self.verdict_reason,
        }


class Split(NamedTuple):
    """The v2/v1 partition. `unscored` is never a rate's denominator."""

    scored: list
    unscored: list


def split_scored(angles) -> Split:
    """Separate rows that carry predictions from rows that do not.

    Every rate in the calibration report is computed over `.scored` alone;
    `.unscored` is reported as its own count. Folding the two together is the
    artefact this function exists to make harder than doing it right.
    """
    scored, unscored = [], []
    for angle in angles:
        (scored if angle.scored else unscored).append(angle)
    return Split(scored, unscored)


def summarize(angles) -> dict:
    """Counts a report can print without deriving anything itself.

    `total` is deliberately not a rate denominator anywhere: `scored` is.
    """
    split = split_scored(angles)
    bands = {band: 0 for band in BANDS}
    verdicts = {verdict: 0 for verdict in VERDICTS}
    unscored_verdicts = {verdict: 0 for verdict in VERDICTS}
    for angle in split.scored:
        bands[angle.band] += 1
        verdicts[angle.verdict] = verdicts.get(angle.verdict, 0) + 1
    for angle in split.unscored:
        unscored_verdicts[angle.verdict] = unscored_verdicts.get(angle.verdict, 0) + 1
    return {
        "total": len(angles),
        "scored": len(split.scored),
        "unscored": len(split.unscored),
        "weeks": sorted({a.week for a in angles}),
        "scored_weeks": sorted({a.week for a in split.scored}),
        "unscored_weeks": sorted({a.week for a in split.unscored}),
        "bands": bands,
        "verdicts": verdicts,
        "unscored_verdicts": unscored_verdicts,
    }


# ── Parsing ───────────────────────────────────────────────────────────────────


def _split_frontmatter(lines: list, source: str) -> tuple:
    if not lines or lines[0].strip() != "---":
        raise ParseError("%s: no opening frontmatter delimiter" % source)
    end = None
    for i, line in enumerate(lines[1:], 1):
        if line.strip() == "---":
            end = i
            break
    if end is None:
        raise ParseError("%s: unterminated frontmatter" % source)
    try:
        fm = yaml.safe_load("\n".join(lines[1:end])) or {}
    except yaml.YAMLError as exc:
        raise ParseError("%s: frontmatter is not valid YAML: %s" % (source, exc))
    if not isinstance(fm, dict):
        raise ParseError("%s: frontmatter is not a mapping" % source)
    return fm, end


def _schema_version(fm: dict, source: str) -> int:
    raw = fm.get("schemaVersion")
    if raw is None or raw == "":
        return 1  # absent means legacy, and legacy means no scores
    if isinstance(raw, bool) or not isinstance(raw, int):
        raise ParseError("%s: schemaVersion must be one of %s, got %r"
                         % (source, ", ".join(str(v) for v in SCHEMA_VERSIONS), raw))
    if raw not in SCHEMA_VERSIONS:
        raise ParseError("%s: schemaVersion must be one of %s, got %r"
                         % (source, ", ".join(str(v) for v in SCHEMA_VERSIONS), raw))
    return raw


def _split_angles(lines: list, start: int, source: str) -> list:
    """[{n, tail, heading, body}] — body runs to the next `## `."""
    angles, current = [], None
    for line in lines[start:]:
        match = HEADING_RE.match(line)
        if match:
            if current is not None:
                angles.append(current)
            current = {"n": int(match.group(1)), "tail": match.group(2),
                       "heading": line.rstrip(), "body": []}
        elif ANY_HEADING_RE.match(line):
            raise ParseError("%s: %r is not a '## A<n>' heading — content outside "
                             "any angle cannot be attributed to one" % (source, line.rstrip()))
        elif current is not None:
            current["body"].append(line)
        elif line.strip():
            raise ParseError("%s: content before the first angle: %r" % (source, line.rstrip()))
    if current is not None:
        angles.append(current)
    if not angles:
        raise ParseError("%s: no '## A<n>' angle headings found" % source)
    for i, angle in enumerate(angles, 1):
        if angle["n"] != i:
            raise ParseError("%s: angle headings must number sequentially from 1: "
                             "expected '## A%d', got %r" % (source, i, angle["heading"]))
    return angles


def _read_fields(angle: dict, label: str, source: str) -> tuple:
    """(fields dict, observed order, evidence bullets).

    A line that is neither a labelled field nor an evidence bullet is an error.
    See "Failure modes are loud" in the module docstring.
    """
    fields, order, evidence = {}, [], []
    last = None
    for line in angle["body"]:
        match = FIELD_RE.match(line)
        if match:
            name = " ".join(match.group(1).split()).lower()
            if name in fields:
                raise ParseError("%s: %s has two '%s' fields" % (source, label, name))
            fields[name] = match.group(2).strip()
            order.append(name)
            last = name
            continue
        bullet = NESTED_BULLET_RE.match(line)
        if bullet:
            if last != "evidence":
                raise ParseError("%s: %s has a nested bullet under '%s' — only "
                                 "'evidence' takes a nested list: %r"
                                 % (source, label, last or "no field", line.rstrip()))
            evidence.append(bullet.group(1).strip())
            continue
        if line.strip():
            raise ParseError("%s: %s has a line that is neither a '- **field:**' nor an "
                             "evidence bullet — every field is one line: %r"
                             % (source, label, line.rstrip()))
    return fields, order, evidence


def _check_shape(order: list, fields: dict, schema_version: int,
                 label: str, source: str) -> None:
    canonical = V1_FIELD_ORDER if schema_version == 1 else V2_FIELD_ORDER
    required = V1_REQUIRED if schema_version == 1 else V2_REQUIRED

    unknown = [name for name in order if name not in canonical]
    if unknown:
        # Named individually, because the near miss is a score field in a v1
        # file or a fifth dimension nobody agreed to add.
        raise ParseError("%s: %s has unrecognised field(s) at schemaVersion %d: %s"
                         % (source, label, schema_version, ", ".join(repr(u) for u in unknown)))

    missing = [name for name in required if name not in fields]
    if missing:
        raise ParseError("%s: %s is missing required field(s): %s"
                         % (source, label, ", ".join(missing)))

    expected = [name for name in canonical if name in fields]
    if order != expected:
        raise ParseError("%s: %s has its fields out of canonical order — expected %s, got %s"
                         % (source, label, " · ".join(expected), " · ".join(order)))


def _read_scores(fields: dict, schema_version: int, label: str, source: str) -> tuple:
    """(scores, reasons). Empty at v1 — the shape check has already rejected a
    score field in a v1 file, so there is nothing to read."""
    if schema_version == 1:
        return {}, {}
    scores, reasons = {}, {}
    for dim, key in zip(SCORE_FIELDS, SCORE_LABELS):
        raw = fields[key]  # presence guaranteed by _check_shape
        head, sep, reason = raw.partition(EM_DASH)
        value = head.strip()
        if not sep:
            raise ParseError("%s: %s '%s' has no ' %s <justification>': %r"
                             % (source, label, key, EM_DASH, raw))
        reason = reason.strip()
        if not reason:
            raise ParseError("%s: %s '%s' has an empty justification" % (source, label, key))
        if not re.match(r"^\d+$", value):
            raise ParseError("%s: %s '%s' must be an integer %d-%d, got %r"
                             % (source, label, key, SCORE_MIN, SCORE_MAX, value))
        number = int(value)
        if not SCORE_MIN <= number <= SCORE_MAX:
            raise ParseError("%s: %s '%s' must be an integer %d-%d, got %r"
                             % (source, label, key, SCORE_MIN, SCORE_MAX, value))
        scores[dim] = number
        reasons[dim] = reason
    return scores, reasons


def _read_verdict(fields: dict, label: str, source: str) -> tuple:
    """(verdict, dimension, reason).

    A `maybe`/`pass` with no dimension tag parses — it does not raise. The tag is
    required by the contract, but a missing one is a warning `kickoff judge`
    prints, not a reason to refuse to read the week. A rule that punishes an
    honest human field teaches the human to stop writing the field.
    """
    raw = fields.get("verdict")
    if raw is None:
        return "pending", None, None  # v1, where verdict is optional
    head, sep, tail = raw.partition(EM_DASH)
    verdict = head.strip().lower()
    if verdict not in VERDICTS:
        raise ParseError("%s: %s 'verdict' must be one of %s, got %r"
                         % (source, label, " | ".join(VERDICTS), head.strip()))
    if not sep:
        return verdict, None, None
    reason = tail.strip()
    if not reason:
        return verdict, None, None
    match = VERDICT_TAG_RE.match(reason)
    if match:
        return verdict, match.group(1), match.group(2).strip()
    return verdict, None, reason


def parse_text(text: str, source: str = "<text>", path: str = "") -> list:
    """Every angle in one file's text, in file order. Raises ParseError."""
    lines = text.split("\n")
    fm, end = _split_frontmatter(lines, source)

    week = fm.get("week")
    if not (isinstance(week, str) and WEEK_RE.match(week)):
        raise ParseError("%s: frontmatter 'week' must match YYYY-Www, got %r" % (source, week))
    schema_version = _schema_version(fm, source)
    generated = str(fm.get("generated") or "")

    out = []
    for angle in _split_angles(lines, end + 1, source):
        label = "A%d" % angle["n"]
        title_match = TITLE_RE.match(angle["tail"])
        if not title_match:
            raise ParseError("%s: %s heading has no ' %s <title>': %r"
                             % (source, label, EM_DASH, angle["heading"]))
        fields, order, evidence = _read_fields(angle, label, source)
        _check_shape(order, fields, schema_version, label, source)
        if not evidence:
            raise ParseError("%s: %s 'evidence' has no nested bullets" % (source, label))
        scores, reasons = _read_scores(fields, schema_version, label, source)
        verdict, dimension, reason = _read_verdict(fields, label, source)
        out.append(Angle(
            week=week,
            n=angle["n"],
            title=title_match.group(1).strip(),
            schema_version=schema_version,
            fields=fields,
            evidence=tuple(evidence),
            scores=scores,
            score_reasons=reasons,
            band=compute_band(scores),
            composite=compute_composite(scores),
            verdict=verdict,
            verdict_dimension=dimension,
            verdict_reason=reason,
            generated=generated,
            path=path,
        ))
    return out


def parse_file(path) -> list:
    """Every angle in one file. The frontmatter `week` must agree with the file
    stem where the stem names a week — the id is built from `week`, and a
    disagreement silently files a week's rows under the wrong label forever."""
    path = Path(path)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ParseError("cannot read %s (%s)" % (path, exc))
    angles = parse_text(text, source=str(path), path=str(path))
    if WEEK_RE.match(path.stem) and angles and angles[0].week != path.stem:
        raise ParseError("%s: frontmatter week is %r but the file is named %r"
                         % (path, angles[0].week, path.stem))
    return angles


# ── Loading a studio ──────────────────────────────────────────────────────────


def angles_dir(studio) -> Path:
    return Path(studio) / "angles"


def available_weeks(studio) -> list:
    """Every week with a file, ascending. `YYYY-Www` sorts chronologically as
    text, which is why the format was chosen; nothing here parses a date."""
    directory = angles_dir(studio)
    if not directory.is_dir():
        return []
    return sorted(p.stem for p in directory.glob("*.md") if WEEK_RE.match(p.stem))


def load_week(studio, week: str) -> list:
    if not WEEK_RE.match(week):
        raise ParseError("week must match YYYY-Www, got %r" % (week,))
    path = angles_dir(studio) / ("%s.md" % week)
    if not path.is_file():
        raise ParseError("no angles file for %s at %s" % (week, path))
    return parse_file(path)


def load_weeks(studio, weeks=None, since=None) -> list:
    """Angles from a set of weeks, oldest week first, file order within a week.

    `since=n` means the most recent `n` weeks that *have files*, never the last
    `n` calendar weeks: a skipped Sunday must not silently shrink the window a
    report claims to cover.
    """
    if weeks is not None and since is not None:
        raise ParseError("pass weeks or since, not both")
    if weeks is None:
        weeks = available_weeks(studio)
        if since is not None:
            if since < 1:
                raise ParseError("--since must be 1 or more, got %r" % (since,))
            weeks = weeks[-since:]
    out = []
    for week in sorted(weeks):
        out.extend(load_week(studio, week))
    return out


# ── CLI ───────────────────────────────────────────────────────────────────────


def die(msg: str):
    print("%s: ERROR: %s" % (PROG, msg), file=sys.stderr)
    sys.exit(1)


def _render(angles: list, out) -> None:
    counts = summarize(angles)
    width = max([len(a.id) for a in angles] + [2])
    for angle in angles:
        band = angle.band or "—"
        composite = "%d" % angle.composite if angle.composite is not None else "—"
        tag = angle.verdict_dimension or "—"
        out.write("%-*s  %-7s  %2s  %-7s  %-1s  %s\n"
                  % (width, angle.id, band, composite, angle.verdict, tag, angle.title))
    out.write("\n")
    out.write("%d angle(s) · %d scored (v2) · %d unscored (v1 — verdicts only, "
              "excluded from every rate)\n"
              % (counts["total"], counts["scored"], counts["unscored"]))
    if counts["scored"]:
        out.write("bands: %s\n" % " · ".join("%s %d" % (b, counts["bands"][b]) for b in BANDS))


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Parse angle files into records (one parser, three consumers)")
    ap.add_argument("--week", action="append", default=[],
                    help="ISO week to load, e.g. 2026-W31. Repeatable")
    ap.add_argument("--since", type=int, default=None,
                    help="The most recent N weeks that have files")
    ap.add_argument("--file", action="append", default=[],
                    help="Parse this path directly, bypassing $STUDIO_DIR. A test seam")
    ap.add_argument("--studio-dir", default=None,
                    help="Studio path. Defaults to $STUDIO_DIR; never resolved here (D5)")
    ap.add_argument("--json", action="store_true", help="Emit records as JSON")
    args = ap.parse_args()

    if args.week and args.since is not None:
        die("--week and --since are mutually exclusive")

    try:
        if args.file:
            angles = []
            for path in args.file:
                angles.extend(parse_file(path))
        else:
            studio_raw = args.studio_dir or os.environ.get("STUDIO_DIR") or ""
            if not studio_raw:
                die("STUDIO_DIR is not set. It is resolved by resolve_studio_dir() in "
                    "scripts/lib/job-config.sh — run this through `kickoff`, or pass "
                    "--studio-dir. Guessing it here would risk reading the wrong studio.")
            studio = Path(studio_raw)
            if not studio.is_dir():
                die("STUDIO_DIR does not exist: %s" % studio)
            angles = load_weeks(studio, weeks=args.week or None, since=args.since)
    except ParseError as exc:
        die(str(exc))

    if not angles:
        die("no angles found — nothing to report on")

    if args.json:
        json.dump([a.as_dict() for a in angles], sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
    else:
        _render(angles, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
