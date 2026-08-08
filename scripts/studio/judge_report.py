#!/usr/bin/env python3
"""Judge status, the week table and the calibration report — S4.5.7, S4.5.8.

    python3 scripts/studio/judge_report.py --week 2026-W32   # the angle table
    python3 scripts/studio/judge_report.py --since 2         # the calibration report
    python3 scripts/studio/judge_report.py --status          # every week's judged state
    python3 scripts/studio/judge_report.py --doctor          # one `kickoff doctor` line
                                          [--studio-dir DIR]

Reads only. `kickoff judge` owns the commit; nothing here writes anything, so a
report can never be the reason a week's verdicts change.

Exit codes are the interface `kickoff` dispatches on:

    0   printed, nothing outstanding
    1   printed, and there is a finding — the latest week is unjudged
    2   could not read the studio or the arguments

**Every angle file is read through `angles_index`, never re-parsed here.** This
project's recurring bug is two readings of one format drifting apart, and this
module is the second of that parser's three consumers. It imports `Angle`,
`load_weeks`, `split_scored`, `summarize` and the band constants; it owns no
grammar of its own.

Three things the epic is emphatic about, implemented here:

**The week table prints in file order (A1…An) with the band as a column.** Never
sorted by band or composite. Presentation order anchors the human — that is the
stated reason `verdict:` sits above the score fields — so a composite that set
the reading order would be selecting, which the design forbids. File order costs
nothing and makes the claim true.

**v1 rows are counted separately and enter no rate.** `split_scored()` is the
discriminator. W31 contributes 9 band-less rows against W32's handful of scored
ones; counted naively the first calibration report is ~75% artefact and looks
like a signal. Their verdicts are real, so they are reported — as their own
count, beside every rate and inside none.

**Spread is printed per dimension, never in aggregate.** A model asked for
spread supplies it where it costs nothing — E and R do not gate at their upper
boundary — while pinning P and C at 3 and putting the whole set in DRAFT.
Aggregate spread looks healthy while the compression that matters is invisible.

A `maybe`/`pass` with no dimension tag is a **warning, never an error**. The tag
is the highest-leverage element in the epic and it is written by a human: a rule
that fails the week on a missing one teaches the human to stop writing reasons,
which is the only free-text signal the loop collects.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from angles_index import (  # noqa: E402
    BANDS, BLOCKED, DRAFT, REWORK, SCORE_ABBREV, SCORE_FIELDS, SCORE_MAX,
    SCORE_MIN, VERDICTS, ParseError, available_weeks, load_weeks, split_scored,
    summarize,
)

PROG = "judge_report"

PENDING = "pending"
JUDGED = tuple(v for v in VERDICTS if v != PENDING)

# The two shapes of disagreement worth tuning a prompt on: the band promised a
# draftable angle and the human passed, or the band blocked one the human would
# post anyway. Everything else is agreement or an unjudged row.
FALSE_POSITIVE = (DRAFT, "pass")
FALSE_NEGATIVE_BANDS = (BLOCKED, REWORK)

# doctor's label column, so this line sits under `signals` and `note links`
# without either side hard-coding the other's width.
DOCTOR_LABEL = "verdicts"
DOCTOR_WIDTH = 13

# The compression watch names these two specifically (S4.5.11). E and R can
# spread freely because neither gates at its upper boundary, so a collapse there
# is far weaker evidence.
COMPRESSION_WATCH = ("provability", "consequence")


class ReportError(Exception):
    """Anything that should exit 2 rather than print a half report."""


# ── The judged state of a week ────────────────────────────────────────────────


def week_state(angles: list) -> dict:
    """One week's judging progress.

    A v2 week is judged when no DRAFT-band angle is still `pending` — S4.5.9
    asks for the DRAFT band in full and for exceptions only below it, so a
    pending REWORK row is the design working rather than work outstanding.

    A v1 week has no bands to scope the ask, so it counts as judged once any
    verdict has been recorded. W31 is the only such week that will ever exist.
    """
    split = split_scored(angles)
    draft = [a for a in split.scored if a.band == DRAFT]
    draft_pending = [a for a in draft if a.verdict == PENDING]
    recorded = [a for a in angles if a.verdict != PENDING]
    if split.scored:
        judged = not draft_pending
    else:
        judged = bool(recorded)
    return {
        "week": angles[0].week if angles else "",
        "total": len(angles),
        "scored": len(split.scored),
        "unscored": len(split.unscored),
        "draft": len(draft),
        "draft_pending": [a.id for a in draft_pending],
        "recorded": len(recorded),
        "judged": judged,
    }


def by_week(angles: list) -> list:
    """[(week, [angles])] ascending, file order preserved within a week."""
    order, groups = [], {}
    for angle in angles:
        if angle.week not in groups:
            groups[angle.week] = []
            order.append(angle.week)
        groups[angle.week].append(angle)
    return [(week, groups[week]) for week in sorted(order)]


def tag_warnings(angles: list) -> list:
    """A `maybe`/`pass` with no dimension tag. Warnings, never errors."""
    tags = " ".join("%s:" % SCORE_ABBREV[d] for d in SCORE_FIELDS)
    return ["%s verdict '%s' has no dimension tag (%s or —:) — the tag is the "
            "tuning signal, and without it this row cannot say which dimension "
            "decided it" % (a.id, a.verdict, tags)
            for a in angles
            if a.verdict in ("maybe", "pass") and not a.verdict_dimension]


# ── Rendering ─────────────────────────────────────────────────────────────────


def _rows(rows: list, out, indent: str = "  ", left=(0,)) -> None:
    """Print a table of equal-length rows, columns right-sized. `left` names the
    columns holding text; every other column is a count and is right-aligned."""
    if not rows:
        return
    width = [max(len(str(r[i])) for r in rows) for i in range(len(rows[0]))]
    for row in rows:
        cells = []
        for i, cell in enumerate(row):
            cell = str(cell)
            cells.append(cell.ljust(width[i]) if i in left else cell.rjust(width[i]))
        out.write("%s%s\n" % (indent, "  ".join(cells).rstrip()))


def render_week(angles: list, out) -> list:
    """The angle table for one week, in FILE ORDER. Returns the warnings."""
    state = week_state(angles)
    version = "v2 — scored" if state["scored"] else "v1 — verdicts only, no predictions"
    out.write("%s — %d angle(s) · %s\n\n" % (state["week"], state["total"], version))

    rows = [("angle", "band", "sum", "verdict", "tag", "title")]
    for angle in angles:
        rows.append((
            "A%d" % angle.n,
            angle.band or "—",
            "—" if angle.composite is None else angle.composite,
            angle.verdict,
            angle.verdict_dimension or "",
            angle.title,
        ))
    _rows(rows, out, left=(0, 1, 3, 4, 5))

    counts = summarize(angles)
    out.write("\n")
    if state["scored"]:
        out.write("  bands     %s\n"
                  % " · ".join("%s %d" % (b, counts["bands"][b]) for b in BANDS))
    verdicts = counts["verdicts"] if state["scored"] else counts["unscored_verdicts"]
    out.write("  verdicts  %s\n" % " · ".join("%s %d" % (v, verdicts.get(v, 0))
                                              for v in VERDICTS))
    if state["draft_pending"]:
        out.write("  %d DRAFT angle(s) still pending: %s\n"
                  % (len(state["draft_pending"]), ", ".join(state["draft_pending"])))

    warnings = tag_warnings(angles)
    if warnings:
        out.write("\n")
        for warning in warnings:
            out.write("  WARN: %s\n" % warning)
    return warnings


def render_status(studio, angles: list, out) -> bool:
    """Every week's judged state. Returns True when the latest week is judged."""
    out.write("angles in %s\n\n" % (Path(studio) / "angles"))
    rows = [("week", "angles", "scored", "DRAFT", "recorded", "state")]
    states = []
    for week, group in by_week(angles):
        state = week_state(group)
        states.append(state)
        rows.append((
            week,
            state["total"],
            state["scored"] or "—",
            state["draft"] if state["scored"] else "—",
            state["recorded"],
            "judged" if state["judged"] else "UNJUDGED",
        ))
    _rows(rows, out, left=(0, 5))

    latest = states[-1]
    out.write("\n")
    if latest["judged"]:
        out.write("%s (latest) is judged.\n" % latest["week"])
        return True
    if latest["draft_pending"]:
        out.write("%s (latest): %d of %d DRAFT angle(s) still 'pending' (%s)\n"
                  % (latest["week"], len(latest["draft_pending"]), latest["draft"],
                     ", ".join(latest["draft_pending"])))
    else:
        out.write("%s (latest): no verdict recorded on any angle\n" % latest["week"])
    out.write("Record verdicts in the file, then: kickoff judge %s\n" % latest["week"])
    return False


def render_doctor(studio, angles: list, out) -> bool:
    """One `kickoff doctor` line, plus continuation lines on a finding."""
    label = DOCTOR_LABEL.ljust(DOCTOR_WIDTH)
    pad = " " * DOCTOR_WIDTH
    if not angles:
        # Not a finding. Nothing has generated a week yet, and an always-red
        # gate on an empty studio is worse than no gate.
        out.write("%sno angle files yet — written by the Sunday generator\n" % label)
        return True
    latest = week_state(by_week(angles)[-1][1])
    if latest["judged"]:
        out.write("%s%s judged, %d verdict(s) recorded  OK\n"
                  % (label, latest["week"], latest["recorded"]))
        return True
    if latest["draft_pending"]:
        out.write("%s%s UNJUDGED — %d of %d DRAFT angle(s) still 'pending'\n"
                  % (label, latest["week"], len(latest["draft_pending"]), latest["draft"]))
    else:
        out.write("%s%s UNJUDGED — no verdict recorded on any angle\n"
                  % (label, latest["week"]))
    out.write("%sthe verdict is the only calibration label this loop collects\n" % pad)
    out.write("%srun: kickoff judge %s\n" % (pad, latest["week"]))
    return False


# ── The calibration report ────────────────────────────────────────────────────


def band_verdict_counts(scored: list) -> dict:
    """{band: {verdict: n}} over scored rows only."""
    table = {band: {verdict: 0 for verdict in VERDICTS} for band in BANDS}
    for angle in scored:
        table[angle.band][angle.verdict] = table[angle.band].get(angle.verdict, 0) + 1
    return table


def disagreements(scored: list) -> list:
    """Every DRAFT judged `pass` and every BLOCKED/REWORK judged `post`.

    The prompt-tuning input, and the reason the dimension tag exists: a row here
    without a tag says the band was wrong and cannot say which dimension made it
    wrong, which are opposite repairs.
    """
    out = []
    for angle in scored:
        if (angle.band, angle.verdict) == FALSE_POSITIVE:
            kind = "band said DRAFT"
        elif angle.band in FALSE_NEGATIVE_BANDS and angle.verdict == "post":
            kind = "band said %s" % angle.band
        else:
            continue
        out.append({
            "id": angle.id,
            "band": angle.band,
            "verdict": angle.verdict,
            "kind": kind,
            "tag": angle.verdict_dimension or "(no tag)",
            "reason": angle.verdict_reason or "(no reason recorded)",
            "title": angle.title,
        })
    return out


def dimension_stats(scored: list, unscored: list) -> dict:
    """Per dimension: the score distribution, its spread, and the verdicts tagged
    to it. Spread lives here — per dimension — and is never totalled."""
    stats = {}
    for dim in SCORE_FIELDS:
        values = [a.scores[dim] for a in scored if dim in a.scores]
        abbrev = SCORE_ABBREV[dim]
        stats[dim] = {
            "abbrev": abbrev,
            "n": len(values),
            "dist": {v: values.count(v) for v in range(SCORE_MIN, SCORE_MAX + 1)},
            "spread": (max(values) - min(values)) if values else None,
            "mean": (sum(values) / float(len(values))) if values else None,
            "tagged": sum(1 for a in scored if a.verdict_dimension == abbrev),
            "tagged_unscored": sum(1 for a in unscored if a.verdict_dimension == abbrev),
        }
    return stats


def render_report(angles: list, out) -> None:
    split = split_scored(angles)
    counts = summarize(angles)

    out.write("calibration report\n")
    out.write("window    %s (%d week(s) with files)\n"
              % (", ".join(counts["weeks"]), len(counts["weeks"])))
    out.write("rows      %d total · %d scored (v2) · %d unscored (v1)\n"
              % (counts["total"], counts["scored"], counts["unscored"]))
    if counts["unscored"]:
        # Named every time, not only when it looks odd. A v1 row's verdict is
        # real and its prediction never existed; folding the two together is the
        # artefact this line exists to keep visible.
        out.write("          v1 weeks %s carry verdicts and no predictions — counted "
                  "here, and in no rate below\n" % ", ".join(counts["unscored_weeks"]))
        out.write("          v1 verdicts: %s\n"
                  % " · ".join("%s %d" % (v, counts["unscored_verdicts"].get(v, 0))
                               for v in VERDICTS))

    # Warned about, never fatal, and warned about here as well as in the week
    # table: this report is the one path that reads weeks nobody is re-judging,
    # so an untagged verdict recorded months ago surfaces nowhere else.
    warnings = tag_warnings(angles)
    for warning in warnings:
        out.write("WARN: %s\n" % warning)
    out.write("\n")

    _section_bands(split.scored, out)
    _section_disagreements(split.scored, out)
    _section_dimensions(split.scored, split.unscored, out)


def _section_bands(scored: list, out) -> None:
    out.write("1. Verdicts by band — scored rows only\n\n")
    if not scored:
        out.write("  no scored rows in this window — nothing to count\n\n")
        return
    table = band_verdict_counts(scored)
    rows = [("band", "n") + VERDICTS + ("judged",)]
    for band in BANDS:
        counts = table[band]
        total = sum(counts.values())
        judged = sum(counts[v] for v in JUDGED)
        rows.append((band, total) + tuple(counts[v] for v in VERDICTS) + (judged,))
    _rows(rows, out)

    # DRAFT-band precision, over judged DRAFT rows alone. Deliberately the only
    # rate printed: S4.5.9 collects the DRAFT band in full and everything below
    # it opportunistically, so a below-band rate would be recall computed over a
    # denominator nobody sampled.
    draft = table[DRAFT]
    judged_draft = sum(draft[v] for v in JUDGED)
    out.write("\n")
    if judged_draft:
        out.write("  DRAFT precision  %d/%d judged DRAFT row(s) posted (%.0f%%)\n"
                  % (draft["post"], judged_draft, 100.0 * draft["post"] / judged_draft))
    else:
        out.write("  DRAFT precision  no judged DRAFT rows yet\n")
    out.write("  Below DRAFT only exceptions are recorded, so those rows measure "
              "nothing on their own.\n\n")


def _section_disagreements(scored: list, out) -> None:
    out.write("2. Disagreements — the prompt-tuning input\n\n")
    rows = disagreements(scored)
    if not rows:
        out.write("  none: no DRAFT angle was passed and no BLOCKED/REWORK angle "
                  "was posted\n\n")
        return
    for row in rows:
        out.write("  %-14s %-8s judged %-5s  %s\n"
                  % (row["id"], row["band"], row["verdict"], row["title"]))
        out.write("  %-14s tag %-5s %s\n" % ("", row["tag"], row["reason"]))
    untagged = sum(1 for r in rows if r["tag"] == "(no tag)")
    if untagged:
        out.write("\n  %d disagreement(s) carry no dimension tag — those rows say the "
                  "band was wrong\n  and cannot say which dimension made it wrong.\n" % untagged)
    out.write("\n")


def _section_dimensions(scored: list, unscored: list, out) -> None:
    out.write("3. Per dimension — distribution, spread, and verdicts tagged to it\n\n")
    if not scored:
        out.write("  no scored rows in this window — no distribution to report\n\n")
        return
    stats = dimension_stats(scored, unscored)
    rows = [("dim", "n") + tuple(str(v) for v in range(SCORE_MIN, SCORE_MAX + 1))
            + ("spread", "mean", "tagged", "name")]
    for dim in SCORE_FIELDS:
        s = stats[dim]
        rows.append(
            (s["abbrev"], s["n"])
            + tuple(s["dist"][v] for v in range(SCORE_MIN, SCORE_MAX + 1))
            + ("—" if s["spread"] is None else s["spread"],
               "—" if s["mean"] is None else "%.1f" % s["mean"],
               s["tagged"], dim))
    _rows(rows, out, left=(0, len(rows[0]) - 1))
    out.write("\n  Spread is per dimension and is never totalled: a model asked for "
              "spread supplies\n  it where it costs nothing, and an aggregate figure "
              "hides exactly that.\n")

    flat = [d for d in SCORE_FIELDS if stats[d]["spread"] == 0]
    if flat:
        out.write("\n")
        for dim in flat:
            s = stats[dim]
            value = next(v for v, n in s["dist"].items() if n)
            out.write("  COMPRESSED: %s (%s) has spread 0 — every scored angle in this "
                      "window is %d.\n" % (s["abbrev"], dim, value))
        watched = [d for d in flat if d in COMPRESSION_WATCH]
        if watched:
            out.write("  %s gate%s, so a collapsed spread there is the compression this "
                      "loop watches\n  for. It is a prompt-tuning finding, not a run "
                      "failure.\n"
                      % (" and ".join(SCORE_ABBREV[d] for d in watched),
                         "" if len(watched) > 1 else "s"))
        else:
            out.write("  Neither gates at its upper boundary, so this is weaker evidence "
                      "than a collapse in\n  P or C would be.\n")

    tagged_unscored = sum(stats[d]["tagged_unscored"] for d in SCORE_FIELDS)
    if tagged_unscored:
        out.write("\n  v1 rows carry %d tagged verdict(s), counted separately and in no "
                  "column above:\n  %s\n"
                  % (tagged_unscored,
                     " · ".join("%s %d" % (stats[d]["abbrev"], stats[d]["tagged_unscored"])
                                for d in SCORE_FIELDS)))
    out.write("\n")


# ── CLI ───────────────────────────────────────────────────────────────────────


def die(msg: str) -> int:
    print("%s: ERROR: %s" % (PROG, msg), file=sys.stderr)
    return 2


def resolve_studio(raw: str):
    if not raw:
        raise ReportError(
            "STUDIO_DIR is not set. It is resolved by resolve_studio_dir() in "
            "scripts/lib/job-config.sh — run this through `kickoff`, or pass "
            "--studio-dir. Guessing it here would risk reading the wrong studio.")
    studio = Path(raw)
    if not studio.is_dir():
        raise ReportError("STUDIO_DIR does not exist: %s" % studio)
    return studio


def main() -> int:
    ap = argparse.ArgumentParser(description="Judge status and the calibration report")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--week", help="Print one week's angle table, in file order")
    mode.add_argument("--since", type=int, help="Calibration report over the most "
                                                "recent N weeks that have files")
    mode.add_argument("--status", action="store_true",
                      help="Every week's judged state; exit 1 if the latest is unjudged")
    mode.add_argument("--doctor", action="store_true",
                      help="One `kickoff doctor` line; exit 1 if the latest is unjudged")
    ap.add_argument("--studio-dir", default=None,
                    help="Studio path. Defaults to $STUDIO_DIR; never resolved here (D5)")
    args = ap.parse_args()

    try:
        studio = resolve_studio(args.studio_dir or os.environ.get("STUDIO_DIR") or "")
        if args.week:
            angles = load_weeks(studio, weeks=[args.week])
        elif args.since is not None:
            angles = load_weeks(studio, since=args.since)
        else:
            angles = load_weeks(studio) if available_weeks(studio) else []
    except (ParseError, ReportError) as exc:
        if args.doctor:
            # doctor calls this for one line among a dozen. An unreadable week
            # must still arrive as that line and as a finding — a bare traceback
            # in the middle of a health report reads as tooling trouble rather
            # than as the week nobody can judge.
            sys.stdout.write("%s%s\n" % (DOCTOR_LABEL.ljust(DOCTOR_WIDTH), exc))
            sys.stdout.write("%sno week can be judged until this file parses\n"
                             % (" " * DOCTOR_WIDTH))
            return 1
        return die(str(exc))

    out = sys.stdout
    if args.doctor:
        return 0 if render_doctor(studio, angles, out) else 1
    if args.status:
        if not angles:
            out.write("no angle files in %s yet — the Sunday generator writes them.\n"
                      % (Path(studio) / "angles"))
            return 0
        return 0 if render_status(studio, angles, out) else 1
    if not angles:
        return die("no angles found — nothing to report on")
    if args.week:
        render_week(angles, out)
        return 0
    render_report(angles, out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
