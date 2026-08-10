#!/usr/bin/env python3
"""Build the ranked corpus bundle for a generator job (Epic 3, S3.2–S3.5).

    python3 scripts/studio/select_corpus.py --job angles [--date YYYY-MM-DD]

Reads the digest archive, the field notes and the watchlist signal export, ranks
them, and prints one bundle to stdout in the producer wire format shared with
`fetch_sources.py`. It is a producer in exactly the sense `run-job.sh` means:
text on stdout, every record a `format_item` block. Nothing here knows what an
angle is.

Three sections, one format:

    ## YOUR NOTES     the thing nobody else can write, so it reads first
    ## YOUR SIGNAL    starred / done / noted action items, with provenance
    ## CORPUS         digests, ranked

Reads only. Nothing under `src/content/**` is ever opened for writing — it is
both the published site and this epic's corpus.

Design decisions worth knowing before changing anything here:

* **`STUDIO_DIR` is not resolved here.** `resolve_studio_dir()` in
  `scripts/lib/job-config.sh` is the single source of truth; this script takes
  the answer via `--studio-dir` or the `STUDIO_DIR` environment variable and
  refuses to guess. (D5)
* **Determinism is a hard requirement, not a nicety.** Two runs over an
  unchanged corpus must be byte-identical, so an Epic 4 prompt change can be
  A/B tested against a fixed bundle. Every ordering therefore ends in a key that
  is *total* — never a float score alone, and never filesystem iteration order.
* **A gap is never an error.** The `ai` topic is API-refused on cyber-safeguard
  grounds in roughly 18% of runs; a missing day is weather. Gaps are named in
  the coverage header. The one error case is every declared collection empty,
  because an empty bundle produces confident garbage.
* **Coverage is counted per the producing job's `schedule:`, never per day**,
  and the collection→schedule map is built by resolving each config's `output:`
  path. `topics/richmond-events.yaml` writes to `src/content/rva-events/`, so
  assuming the filename matches the directory is right three times out of four.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import date as Date, datetime, timedelta
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - matches fetch_sources.py's guard
    print("Missing deps. Run: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

# scripts/lib carries the shared wire format. Put it on the path rather than
# making scripts/ a package, so a producer at any depth imports it the same way
# and no invocation depends on the caller's cwd. Same mechanism as
# fetch_sources.py, one directory deeper.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
from bundle import format_item  # noqa: E402  — needs the path line above

# ── Constants that mirror something else, and must be kept in step ────────────

# D4. Mirrors `site` + `base` in astro.config.mjs; the digest route is
# src/pages/[theme]/[slug].astro, whose slug is the file stem. A base-path change
# that is not reflected here would emit dead links into every future bundle, so
# scripts/tests/test-select-corpus.sh asserts these two against astro.config.mjs.
SITE = "https://priyesh.fyi"
BASE = "/daily-kickoff/"

# Verbatim from NOTE_HEADER_RE in scripts/studio/kickoff — writer and reader
# cannot be allowed to drift. Anchored to the ISO-8601 stamp rather than a bare
# '## ' because note bodies are stored verbatim and may hold their own headings.
NOTE_HEADER_RE = re.compile(
    r"^## ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}[-+][0-9]{2}:[0-9]{2})(.*)$"
)

# The schema-2 key shape, enforced identically at import in `kickoff signals`.
SIGNAL_KEY_RE = re.compile(r"^wl:([^:]+):(\d{4}-\d{2}-\d{2}):([^:]+):(\d+)$")

# THE TYPE TOKEN TRAP: the key's <type> is `read`, the frontmatter field is
# `readDeeper`. They are not the same string, and the site writes the short one
# (src/pages/index.astro). `skip` items get no watchlist key at all, so signals
# never reference them. Any other token is an unknown key shape.
SIGNAL_TYPE_FIELD = {"try": "try", "share": "share", "read": "readDeeper"}
SIGNAL_TYPE_ORDER = {"try": 0, "share": 1, "read": 2}

# The schedule vocabulary of job_scheduled_today() in scripts/lib/job-config.sh,
# as ISO weekdays (1=Mon … 7=Sun). `weekdays` is Mon–Sat, NOT Mon–Fri: digest
# sources are quiet on Sunday, and this project's docs call it out as a gotcha.
# `never` is Epic 3's addition, for a config that exists only to satisfy the
# orchestrator until Epic 4 turns the job on.
SCHEDULE_WEEKDAYS = {
    "daily": frozenset({1, 2, 3, 4, 5, 6, 7}),
    "weekdays": frozenset({1, 2, 3, 4, 5, 6}),
    "saturday": frozenset({6}),
    "sunday": frozenset({7}),
    "never": frozenset(),
}

# How many missing dates a coverage entry names before it summarises. A gap list
# long enough to wrap is not read, and a silently truncated one reads as full
# coverage — so when it truncates it says so, in the header, with the count.
MAX_NAMED_GAPS = 3

# The job kinds, in resolution order: a config is `scripts/<kind>/<job>.yaml`.
# Mirrors the `for dir in topics generators` loops in find_job_config() and
# job_config_files() in scripts/lib/job-config.sh, and must be edited with them.
#
# A closed list rather than a glob of directories under scripts/ holding *.yaml.
# Discovery reads as the safer option and is not: it would promote any directory
# that happens to acquire a config — a scratch copy, a vendored tree — into a job
# kind with no boundary declared for it, which is the failure class
# assert_output_boundary() in job-config.sh exists to refuse. A named vocabulary
# is also what makes the omission visible: a kind listed here whose directory
# does not exist is inert, so listing one costs nothing, while omitting one costs
# a collection its schedule.
JOB_KINDS = ("topics", "generators", "feed")

PROG = "select_corpus"


def warn(msg: str) -> None:
    print("%s: WARN: %s" % (PROG, msg), file=sys.stderr)


def die(msg: str):
    print("%s: ERROR: %s" % (PROG, msg), file=sys.stderr)
    sys.exit(1)


def digest_url(theme: str, slug: str) -> str:
    """The digest's public URL. `slug` is the file stem, which is what the site
    routes on — not the frontmatter `date`, which can disagree with it."""
    return "%s%s%s/%s" % (SITE, BASE, theme, slug)


# ── Config ────────────────────────────────────────────────────────────────────


def find_job_config(repo: Path, job: str) -> Path:
    """Mirrors find_job_config() in job-config.sh: JOB_KINDS order, one schema.
    Naming every path searched on failure matters — the near miss is a job
    defined under a different kind."""
    searched = []
    for kind in JOB_KINDS:
        path = repo / "scripts" / kind / ("%s.yaml" % job)
        searched.append(str(path))
        if path.is_file():
            return path
    die("no config for job '%s'. Looked in:\n  %s" % (job, "\n  ".join(searched)))


def load_yaml(path: Path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def collection_schedules(repo: Path) -> dict:
    """collection directory -> (schedule, config path).

    Built by resolving each job config's `output:` path, never by assuming the
    config filename matches the directory it writes to. `richmond-events.yaml`
    writes `src/content/rva-events/`; three of the four topics do match, which is
    exactly what makes the assumption ship.

    Every kind in JOB_KINDS is walked. A kind left out does not raise here — it
    removes the collection from the map, and coverage_entry() then reports the
    collection as `N/? (no job writes …)`, which is a plausible line to read.
    """
    out = {}
    content_re = re.compile(r"(?:^|/)src/content/([^/]+)/")
    for kind in JOB_KINDS:
        directory = repo / "scripts" / kind
        if not directory.is_dir():
            continue
        # sorted(): the map must not depend on filesystem iteration order, or a
        # duplicate-output warning could differ between two runs.
        for path in sorted(directory.glob("*.yaml")):
            try:
                cfg = load_yaml(path) or {}
            except yaml.YAMLError as exc:
                warn("%s is not valid YAML (%s) — its collection has no schedule" % (path, exc))
                continue
            if not isinstance(cfg, dict):
                continue
            match = content_re.search(str(cfg.get("output") or ""))
            if not match:
                continue  # generators write beneath $STUDIO_DIR, not the corpus
            name = match.group(1)
            if name in out:
                warn("both %s and %s write to src/content/%s/ — keeping %s"
                     % (out[name][1].name, path.name, name, out[name][1].name))
                continue
            out[name] = (str(cfg.get("schedule") or ""), path)
    return out


# ── Frontmatter ───────────────────────────────────────────────────────────────


def parse_frontmatter(path: Path):
    """The YAML block between the first two `---` fences, or None.

    Hand-rolling a line parser here would be wrong: these files carry multi-line
    scalars, nested maps and lists. A malformed file is a warning and a skip —
    one bad digest must never cost the whole bundle.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        warn("cannot read %s (%s) — skipped" % (path, exc))
        return None
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        warn("%s has no opening frontmatter delimiter — skipped" % path)
        return None
    end = None
    for i, line in enumerate(lines[1:], 1):
        if line.strip() == "---":
            end = i
            break
    if end is None:
        warn("%s has unterminated frontmatter — skipped" % path)
        return None
    try:
        fm = yaml.safe_load("\n".join(lines[1:end]))
    except yaml.YAMLError as exc:
        warn("%s frontmatter is not valid YAML (%s) — skipped" % (path, exc))
        return None
    if not isinstance(fm, dict):
        warn("%s frontmatter is not a mapping — skipped" % path)
        return None
    return fm


def as_iso_date(value):
    """`yaml.safe_load` yields a real `date` for an unquoted YAML date and a
    `str` for a quoted one. Both shapes occur in the corpus."""
    if isinstance(value, datetime):
        return value.date().isoformat()
    if isinstance(value, Date):
        return value.isoformat()
    if isinstance(value, str) and re.match(r"^\d{4}-\d{2}-\d{2}", value.strip()):
        return value.strip()[:10]
    return None


def read_collection(content_dir: Path, theme: str, start: Date, end: Date) -> list:
    """Every digest of one collection whose file stem falls in the window.

    Windowing on the file stem, not the frontmatter date: the stem is the
    identity the site routes on and the watchlist keys on, so it is the only
    thing that can be matched against a signal key.
    """
    directory = content_dir / theme
    if not directory.is_dir():
        return []
    records = []
    for path in sorted(directory.glob("*.md")):
        slug = path.stem
        try:
            slug_date = Date.fromisoformat(slug)
        except ValueError:
            continue  # not a dated digest; the collection holds nothing else
        if not (start <= slug_date <= end):
            continue
        fm = parse_frontmatter(path)
        if fm is None:
            continue
        missing = [k for k in ("title", "date", "tldr") if not fm.get(k)]
        if missing:
            warn("%s is missing required frontmatter field(s): %s — skipped"
                 % (path, ", ".join(missing)))
            continue
        fm_date = as_iso_date(fm.get("date"))
        if fm_date is None:
            warn("%s frontmatter date is not a date: %r — skipped" % (path, fm.get("date")))
            continue
        actions = fm.get("actions")
        records.append({
            "theme": theme,
            "slug": slug,
            "slug_date": slug_date,
            "date": fm_date,
            "title": str(fm["title"]),
            "summary": str(fm["tldr"]),
            "url": digest_url(theme, slug),
            "actions": actions if isinstance(actions, dict) else {},
        })
    return records


# ── Notes ─────────────────────────────────────────────────────────────────────


def unescape_body_line(line: str) -> str:
    """Undo note_escape_body(): a body line shaped like an entry header was
    written with one leading backslash, so that it could not parse as a second
    entry carrying forged tags and a forged link into this file."""
    if line.startswith("\\") and NOTE_HEADER_RE.match(line[1:]):
        return line[1:]
    return line


def parse_notes_file(path: Path) -> list:
    """Every entry in one `notes/YYYY-MM.md`, in file order.

    `index` is the 1-based position in the file over *all* entries, in-window or
    not — it is half of the synthetic `note://` URL, and notes are append-only,
    so it is stable across runs. Numbering only the in-window entries would
    renumber every note each time the window moved.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        warn("cannot read %s (%s)" % (path, exc))
        return []
    entries = []
    current = None
    for line in text.split("\n"):
        match = NOTE_HEADER_RE.match(line)
        if match:
            if current is not None:
                entries.append(current)
            stamp, tail = match.group(1), match.group(2)
            link = None
            link_match = re.search(r"→\s*(\S+)\s*$", tail)
            if link_match:
                link = link_match.group(1)
                tail = tail[: link_match.start()]
            current = {
                "stamp": stamp,
                # Note stamps are MINUTE precision (T14:31-04:00) while signal
                # stamps are SECOND precision (T14:31:07-04:00). Taking the date
                # off the front works for both and needs neither parser.
                "date": stamp[:10],
                "tags": ["#" + t for t in re.findall(r"#(\S+)", tail)],
                "link": link,
                "body": [],
                "month": path.stem,
                "index": len(entries) + 1,
            }
        elif current is not None:
            current["body"].append(unescape_body_line(line))
    if current is not None:
        entries.append(current)
    return entries


def months_in_window(start: Date, end: Date) -> list:
    """Every `YYYY-MM` the window touches. A 14-day window crosses a month
    boundary about half the time, and reading only one file would silently drop
    half the notes."""
    months, cursor = [], Date(start.year, start.month, 1)
    last = Date(end.year, end.month, 1)
    while cursor <= last:
        months.append("%04d-%02d" % (cursor.year, cursor.month))
        cursor = Date(cursor.year + (cursor.month // 12), cursor.month % 12 + 1, 1)
    return months


def load_notes(studio: Path, start: Date, end: Date) -> list:
    notes = []
    for month in months_in_window(start, end):
        path = studio / "notes" / ("%s.md" % month)
        if path.is_file():
            notes.extend(parse_notes_file(path))
    # In-window only, and sorted by a total key: two notes can share a stamp
    # (`note --import` timestamps every block of one file identically), so the
    # stamp alone is not an ordering.
    notes = [n for n in notes if start.isoformat() <= n["date"] <= end.isoformat()]
    notes.sort(key=lambda n: (n["stamp"], n["month"], n["index"]))
    return notes


def note_record(note: dict, content_dir: Path, collections: list) -> dict:
    """One note as a wire-format record.

    D3: `format_item` always emits a `URL:` line and `run-job.sh` validates a
    bundle on `^URL:`, but a note has no URL. A note that links a real digest
    borrows its URL; otherwise it gets `note://<YYYY-MM>#<n>` — stable across
    runs, greppable, and obviously not a real link.

    Blank lines are dropped from the body: a blank line is what separates two
    items in the wire format, so one left inside a body would split the note
    into two malformed records.
    """
    body = [line.rstrip() for line in note["body"]]
    body = [line for line in body if line.strip()]
    url = None
    if note["link"]:
        theme, _, slug = note["link"].partition("/")
        if theme in collections and (content_dir / theme / ("%s.md" % slug)).is_file():
            url = digest_url(theme, slug)
        else:
            warn("note %s links %s, which names no digest in a declared collection "
                 "— no ranking boost" % (note["stamp"], note["link"]))
    if url is None:
        url = "note://%s#%d" % (note["month"], note["index"])
    title = body[0] if body else "Note %s" % note["stamp"]
    summary_lines = ([" ".join(note["tags"])] if note["tags"] else []) + body[1:]
    return {
        "source": "note",
        "title": title,
        "url": url,
        "date": note["date"],
        "summary": "\n".join(summary_lines),
    }


# ── Signals ───────────────────────────────────────────────────────────────────


def load_signals(studio: Path) -> tuple:
    """(items, status) where status is 'ok', 'absent' or a corruption reason.

    Absent and corrupt both mean the same thing to ranking — zero boosts — but
    they must never be silently equivalent to *present*. The header says which
    one happened; there is no pretence that the signal was consulted.
    """
    path = studio / "state" / "signals.json"
    if not path.is_file():
        return {}, "absent"
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (ValueError, OSError) as exc:
        warn("%s is unreadable (%s) — treating every signal as absent" % (path, exc))
        return {}, "unreadable: %s" % exc
    if not isinstance(doc, dict) or not isinstance(doc.get("items"), dict):
        warn("%s is not a signals store (no 'items' object) — treating every signal as absent" % path)
        return {}, "not a signals store"
    return doc["items"], "ok"


def signal_text(digest: dict, type_token: str, index: int, key: str):
    """Resolve a signal key to the text the site displayed.

    The export carries state, never text, so provenance has to be recovered from
    the digest itself. `share` entries are `{what, who}` objects, rendered
    `"<what> → <who>"` to match src/pages/index.astro.
    """
    field = SIGNAL_TYPE_FIELD.get(type_token)
    if field is None:
        warn("signal %s has unknown type '%s' (expected try|share|read) — skipped"
             % (key, type_token))
        return None
    items = digest["actions"].get(field)
    if not isinstance(items, list) or index >= len(items):
        warn("signal %s points past actions.%s (%d item(s)) — the digest was edited "
             "after it was starred; skipped"
             % (key, field, len(items) if isinstance(items, list) else 0))
        return None
    item = items[index]
    if isinstance(item, dict):
        return "%s → %s" % (item.get("what", ""), item.get("who", ""))
    return str(item)


def read_signals(items: dict, digests: dict, start: Date, end: Date) -> tuple:
    """(records, boosts, stats) — the YOUR SIGNAL section, the per-digest flags,
    and the counts the header reports.

    Only keys whose date falls in the window are rendered: a star from six
    months ago sitting beside a corpus that does not contain its digest is
    unexplainable to a reader and to a model. Out-of-window keys are skipped in
    silence — they are ordinary, not a fault.

    `stats` is counted here rather than re-derived in the header, because the two
    must not be able to disagree: the header once reported total stars beside a
    rendered-record count, so `4 starred (3 rendered in window)` read as
    "3 of your 4 stars are here" when only 2 were.
    """
    records, boosts = [], {}
    stats = {"starred_total": 0, "starred_in_window": 0}
    for key in sorted(items):
        value = items[key]
        if not isinstance(value, dict):
            warn("signal %s is a %s, expected an object — skipped" % (key, type(value).__name__))
            continue
        if value.get("starred"):
            stats["starred_total"] += 1
        match = SIGNAL_KEY_RE.match(key)
        if not match:
            warn("signal key %r is not wl:<theme>:<date>:<type>:<index> — skipped" % key)
            continue
        theme, slug, type_token, index = match.group(1), match.group(2), match.group(3), int(match.group(4))
        try:
            slug_date = Date.fromisoformat(slug)
        except ValueError:
            warn("signal key %r carries an impossible date — skipped" % key)
            continue
        if not (start <= slug_date <= end):
            continue
        starred = bool(value.get("starred"))
        if starred:
            stats["starred_in_window"] += 1
        done = value.get("status") == "done"
        user_note = value.get("note") or ""
        flags = boosts.setdefault((theme, slug), {"starred": False, "done": False})
        flags["starred"] = flags["starred"] or starred
        flags["done"] = flags["done"] or done
        # snoozed and archived are deliberate *negative* signal; rendering them
        # under "YOUR SIGNAL" would invert what they mean.
        if not (starred or done or user_note):
            continue
        digest = digests.get((theme, slug))
        if digest is None:
            warn("signal %s names no digest at src/content/%s/%s.md — deleted, or "
                 "malformed frontmatter; skipped" % (key, theme, slug))
            continue
        text = signal_text(digest, type_token, index, key)
        if text is None:
            continue
        marks = [m for m, on in (("starred", starred), ("done", done)) if on]
        provenance = "%s/%s %s #%d" % (theme, slug, type_token.upper(), index)
        summary = " · ".join(marks + [provenance])
        if user_note:
            summary += " — %s" % user_note
        records.append({
            "sort": (-slug_date.toordinal(), theme, SIGNAL_TYPE_ORDER.get(type_token, 9), index),
            "source": theme,
            "title": text,
            "url": digest["url"],
            "date": slug,
            "summary": summary,
        })
    records.sort(key=lambda r: r["sort"])
    stats["shown"] = len(records)
    return records, boosts, stats


# ── Ranking ───────────────────────────────────────────────────────────────────


def check_theme_weights(collections: list, weights: dict) -> None:
    """Warn when `collections:` and `weights.theme:` disagree.

    A collection with no theme weight scores 0.0 and sinks to the bottom of the
    bundle in silence — while the coverage header still reports it fully covered.
    Mistyping `leadership` drops the anchor topic from first place to below
    `rva-events` (weight 0.1) with nothing on stderr, which inverts this epic's
    central requirement. The config is *expected* to be hand-tuned over the first
    quarter, so an editing typo is the likely case, not the exotic one; both
    directions are checked, because a typo shows up as one missing entry and one
    orphan.
    """
    theme_weights = weights.get("theme") or {}
    for theme in collections:
        if theme not in theme_weights:
            warn("selection.collections lists '%s' but weights.theme has no entry for it "
                 "— it scores 0.0 and ranks last. Add a weight, or drop the collection."
                 % theme)
    for name in sorted(theme_weights):
        if name not in collections:
            warn("weights.theme names '%s', which is not in selection.collections — "
                 "that weight has no effect (typo?)" % name)


def rank(digests: list, weights: dict, half_life: float, end: Date,
         starred_set: set, done_set: set, noted_set: set) -> list:
    """score = theme_weight × 0.5 ** (age_days / half_life) × (1 + starred + noted + done)

    Each boost applies **once per digest**, however many of its action items
    carry the signal. Per-item would make score scale with `itemCount`, so a long
    mediocre digest would outrank a short excellent one purely by length — and
    the formula's `1 + starred + noted + done` shape reads as a set of flags, not
    a sum over items. Simplest rule that cannot be gamed by verbosity.

    The sort key is total and ends in `url`, which is unique per file. Ordering
    must never rest on the float score alone, nor on directory iteration order:
    a fixed bundle is what makes an Epic 4 prompt change A/B-testable.
    """
    theme_weights = weights.get("theme") or {}
    ranked = []
    for d in digests:
        key = (d["theme"], d["slug"])
        boost = 1.0
        for name, member in (("starred", key in starred_set),
                             ("noted", key in noted_set),
                             ("done", key in done_set)):
            if member:
                boost += float(weights.get(name) or 0.0)
        age = (end - d["slug_date"]).days
        decay = 0.5 ** (age / half_life) if half_life else 1.0
        d["score"] = float(theme_weights.get(d["theme"], 0.0)) * decay * boost
        ranked.append(d)
    ranked.sort(key=lambda d: (-d["score"], d["theme"], -d["slug_date"].toordinal(), d["url"]))
    return ranked


# ── Coverage ──────────────────────────────────────────────────────────────────


def coverage_entry(theme: str, found: set, schedules: dict, start: Date, end: Date) -> str:
    """`ai 11/12 (gap 2026-08-01)` — expected counted from the producing job's
    schedule, never from the day count. A Saturday collection reported against 14
    days shows a permanent 12-day gap, and a header that is always wrong is a
    header nobody reads.

    The numerator counts only digests landing on a *scheduled* day, because the
    denominator only counts scheduled days. Counting every digest against a
    scheduled denominator lets an off-schedule file fill a quota it does not
    satisfy: `src/content/leadership/` really does hold a Friday, a Wednesday and
    a Sunday digest against a `saturday` schedule, which printed the
    self-contradicting `leadership 2/2 (gap 2026-07-18)` — full coverage claimed
    in the same breath as a named gap. Off-schedule digests are real content, so
    they are reported, not discarded.
    """
    entry = schedules.get(theme)
    if entry is None:
        return "%s %d/? (no job writes src/content/%s/)" % (theme, len(found), theme)
    schedule, config = entry
    weekdays = SCHEDULE_WEEKDAYS.get(schedule)
    if weekdays is None:
        return "%s %d/? (unknown schedule '%s' in %s)" % (theme, len(found), schedule, config.name)
    expected, day = [], start
    while day <= end:
        if day.isoweekday() in weekdays:
            expected.append(day)
        day += timedelta(days=1)
    expected_iso = [d.isoformat() for d in expected]
    on_schedule = [d for d in expected_iso if d in found]
    gaps = [d for d in expected_iso if d not in found]
    text = "%s %d/%d" % (theme, len(on_schedule), len(expected))
    if gaps:
        shown = gaps[:MAX_NAMED_GAPS]
        # Say when the list is truncated. A silently shortened gap list reads as
        # full coverage, which is worse than no list at all.
        more = "" if len(gaps) == len(shown) else " +%d more" % (len(gaps) - len(shown))
        text += " (gap %s%s)" % (", ".join(shown), more)
    off_schedule = len(found) - len(on_schedule)
    if off_schedule:
        text += " +%d off-schedule" % off_schedule
    return text


def signals_header(status: str, items: dict, stats: dict, notes: int, end: Date) -> str:
    """The one place the bundle states what it could and could not see, so every
    number here must be comparable to the one beside it. `starred` and
    `in window` share a denominator; `shown` is reported separately because it
    counts records, not stars — a `done` item with no star is shown, and a star
    whose action index no longer exists is not."""
    if status != "ok":
        return "# signals:  none (%s) · %d notes in window" % (status, notes)
    newest = None
    for value in items.values():
        stamp = value.get("seenAt") if isinstance(value, dict) else None
        if not isinstance(stamp, str):
            continue
        text = stamp.strip()
        if text[-1:] in ("Z", "z"):
            text = text[:-1] + "+00:00"
        if len(text) >= 5 and text[-5] in "+-" and text[-4:].isdigit():
            text = text[:-2] + ":" + text[-2:]
        try:
            parsed = datetime.fromisoformat(text)
        except ValueError:
            continue
        # By INSTANT, never by string: ISO-8601 stamps with differing offsets do
        # not sort by time, so 09:00-04:00 is later than 12:00+00:00 yet sorts
        # earlier as text.
        if parsed.tzinfo is not None and (newest is None or parsed > newest):
            newest = parsed
    if newest is None:
        exported = "exported ? (no usable seenAt)"
    else:
        # Age is measured from --date, not from wall-clock now: the bundle has to
        # be byte-reproducible, and a clock in the header would break that on the
        # first re-run.
        exported = "exported %s (%dd old)" % (newest.date().isoformat(),
                                              (end - newest.date()).days)
    return "# signals:  %s · %d of %d starred in window · %d shown · %d notes in window" % (
        exported, stats["starred_in_window"], stats["starred_total"], stats["shown"], notes)


# ── Bundle ────────────────────────────────────────────────────────────────────


def section(name: str, records: list) -> str:
    """A section with no records still prints its header and an explicit
    `(none)`. A vanished section is indistinguishable from a bug, and on a fresh
    studio both notes and signals are genuinely empty."""
    out = ["## %s" % name, ""]
    if not records:
        out.append("(none)")
        out.append("")
        return "\n".join(out) + "\n"
    for record in records:
        out.append(format_item(record["source"], record["title"], record["url"],
                               record["date"], record["summary"]).rstrip("\n"))
        out.append("")
    return "\n".join(out) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Build a ranked corpus bundle")
    parser.add_argument("--job", required=True,
                        help="Job name (must match scripts/{%s}/JOB.yaml)"
                             % ",".join(JOB_KINDS))
    parser.add_argument("--date", default=None,
                        help="Window end, YYYY-MM-DD (default: today)")
    parser.add_argument("--studio-dir", default=None,
                        help="Studio path. Defaults to $STUDIO_DIR; never resolved here (D5)")
    parser.add_argument("--repo-dir", default=None,
                        help="Repo root for config and corpus lookup. A test seam — "
                             "production never passes it")
    args = parser.parse_args()

    repo = Path(args.repo_dir).resolve() if args.repo_dir \
        else Path(__file__).resolve().parent.parent.parent

    if args.date:
        try:
            end = Date.fromisoformat(args.date)
        except ValueError:
            die("--date must be YYYY-MM-DD, got: %s" % args.date)
    else:
        end = Date.today()

    studio_raw = args.studio_dir or os.environ.get("STUDIO_DIR") or ""
    if not studio_raw:
        die("STUDIO_DIR is not set. It is resolved by resolve_studio_dir() in "
            "scripts/lib/job-config.sh — run this through `kickoff corpus`, or "
            "pass --studio-dir. Guessing it here would risk reading the wrong studio.")
    studio = Path(studio_raw)
    if not studio.is_dir():
        warn("STUDIO_DIR does not exist: %s — no notes and no signals" % studio)

    config_path = find_job_config(repo, args.job)
    config = load_yaml(config_path) or {}
    selection = config.get("selection")
    if not isinstance(selection, dict):
        die("%s declares no `selection:` block — nothing to select" % config_path)
    collections = [str(c) for c in (selection.get("collections") or [])]
    if not collections:
        die("%s declares no `selection.collections:` — nothing to select" % config_path)
    lookback = int(selection.get("lookback_days") or 14)
    half_life = float(selection.get("half_life_days") or 7)
    weights = selection.get("weights") if isinstance(selection.get("weights"), dict) else {}
    check_theme_weights(collections, weights)

    # Inclusive both ends: lookback_days: 14 ending 2026-08-02 is 2026-07-20 →
    # 2026-08-02, which is 14 days, not 15.
    start = end - timedelta(days=lookback - 1)

    content_dir = repo / "src" / "content"
    digests, found_by_theme = [], {}
    for theme in collections:
        records = read_collection(content_dir, theme, start, end)
        digests.extend(records)
        found_by_theme[theme] = {r["slug"] for r in records}

    if not digests:
        die("no digests in %s → %s for any of: %s\n"
            "       looked under %s\n"
            "       an empty bundle produces confident garbage, so this is fatal "
            "where a gap is not."
            % (start.isoformat(), end.isoformat(), ", ".join(collections), content_dir))

    by_key = {(d["theme"], d["slug"]): d for d in digests}

    notes = load_notes(studio, start, end)
    note_records = [note_record(n, content_dir, collections) for n in notes]
    noted_set = set()
    for note in notes:
        if note["link"]:
            theme, _, slug = note["link"].partition("/")
            if (theme, slug) in by_key:
                noted_set.add((theme, slug))

    items, status = load_signals(studio)
    signal_records, boosts, signal_stats = read_signals(items, by_key, start, end)
    starred_set = {k for k, v in boosts.items() if v["starred"]}
    done_set = {k for k, v in boosts.items() if v["done"]}

    ranked = rank(digests, weights, half_life, end, starred_set, done_set, noted_set)

    schedules = collection_schedules(repo)
    coverage = " · ".join(coverage_entry(t, found_by_theme[t], schedules, start, end)
                          for t in collections)

    out = sys.stdout
    out.write("# CORPUS %s → %s\n" % (start.isoformat(), end.isoformat()))
    out.write("# coverage: %s\n" % coverage)
    out.write("%s\n\n" % signals_header(status, items, signal_stats, len(notes), end))
    out.write(section("YOUR NOTES", note_records))
    out.write("\n")
    out.write(section("YOUR SIGNAL", signal_records))
    out.write("\n")
    out.write(section("CORPUS", [
        {"source": d["theme"], "title": d["title"], "url": d["url"],
         "date": d["date"], "summary": d["summary"]} for d in ranked]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
