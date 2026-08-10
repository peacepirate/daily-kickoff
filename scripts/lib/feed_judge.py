"""The relevance pass — the model half of Reconciliation 6.

The execution plan split selection three ways:

    code decides eligibility and ordering        feed_select.eligible/rank/diversify
    the model judges topical relevance           this module
    code has the final veto                      feed_select.veto

**Pure, like house_voice.py and for the same reason.** No network, no clock, no
subprocess. The caller supplies a `runner`; `house_call.call_model` is the one
in production. That keeps the suite hermetic and keeps the decision about what
is publishable in a file that can be tested without spending money.

**Judged on titles and publisher blurbs, not on article text.** The house pass
fetches full articles for the seven that were chosen. Fetching all twenty to
choose from would be triple the requests to inform a decision a human makes off
a headline and two lines.

**It never raises.** Every failure returns no ids and a note, and the caller
falls back to code's own ranking with `unjudged` left true — the
refusal-degradation property the plan calls its most consequential structural
choice. A model outage costs the day its curation and its feed, never its
publish.

**The output is read strictly, and that asymmetry is deliberate.** house_voice
parses leniently because the worst case there is one card falling to the
publisher's own words. Here the worst case is publishing items the model
explicitly rejected, marked as its curated selection, into feeds that cannot
recall them. So an ambiguous verdict is treated as no verdict.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

PROMPT_PATH = Path(__file__).resolve().parent.parent / "prompts" / "feed-relevance.md"

# Restated from feed_select.DAILY_CAP so the prompt can be checked against a
# number. `assert_prompt_contract` asserts the two are equal — without that this
# is just a second copy waiting to disagree, which is what the tag vocabulary
# taught this codebase twice already.
CAP = 7

# The id format the pool guarantees: sha256(normalised url)[:12].
ID_RE = re.compile(r"^[0-9a-f]{12}$")

# An array inside an object is only a selection if the key says so.
#
# The failure this prevents: a model that answers
# `{"rejected": ["…","…"], "selected": []}` — showing its working, which is a
# thoroughly reasonable thing for a model to do. A scan that takes the first
# array it finds publishes the rejects as the selection, and every id is real,
# so the veto passes all of them and the edition is marked judged. Reading an
# object's array without checking its key is the single most dangerous thing
# this module could do.
AFFIRMATIVE_KEYS = ("ids", "selected", "selection", "chosen", "items", "picks", "result")


def render_items(rows: list[dict]) -> str:
    """The ITEMS block, exactly as the model sees it.

    Same shape as house_voice.render_items — ID first, one labelled field per
    line, `----` between items — because two prompts in one pipeline that format
    items differently is a difference someone has to hold in their head for no
    reason.

    No url. It is the one field that invites judging a story by its domain
    rather than by what it says, and PUBLICATION already names the source.
    """
    blocks = []
    for row in rows:
        parts = [
            f"ID: {row.get('id', '')}",
            f"TITLE: {row.get('title', '')}",
            f"PUBLICATION: {row.get('source', '')}",
        ]
        summary = (row.get("summary") or "").strip()
        if summary:
            parts.append(f"PUBLISHER SUMMARY: {summary}")
        blocks.append("\n".join(parts))
    return "\n\n----\n\n".join(blocks)


def assemble_prompt(rows: list[dict], prompt_path: Path | None = None) -> str:
    """The prompt file with the items substituted in — the whole model input.

    Assembled rather than concatenated by the caller so the *assembled result*
    is what the pinning suite checks: a prompt built from parts that are each
    correct can still be wrong once joined.
    """
    text = (prompt_path or PROMPT_PATH).read_text(encoding="utf-8")
    return text.replace("{{ITEMS}}", render_items(rows))


# ── output ───────────────────────────────────────────────────────────────────

def _ids_from(entries: list) -> list[str]:
    """Well-formed ids out of a parsed array, order preserved.

    Order is the model's relevance ranking and the only thing it produces that
    code has no substitute for. Duplicates are left in — `veto` dedupes and
    records it, and silently collapsing them here would hide a model that is
    padding.
    """
    ids = []
    for entry in entries:
        if isinstance(entry, str):
            value = entry.strip()
        elif isinstance(entry, dict):
            # The shape the *other* prompt in this pipeline asks for. One
            # editing session away from being what arrives here.
            value = str(entry.get("id", "")).strip()
        else:
            continue
        if ID_RE.match(value):
            ids.append(value)
    return ids


def _strip_fences(text: str) -> str:
    """Markdown fences removed. Case-insensitive: ```JSON happens."""
    return re.sub(r"```[a-z]*", "", text, flags=re.I).strip()


def _balanced_arrays(text: str) -> list[str]:
    """Every balanced top-level `[...]` span, in order.

    All of them, not the first. Taking only the first loses a real verdict to a
    model that writes "see item [3] below" — or, more likely here, restates the
    output format in a fenced example before answering.

    String-aware, so a `]` inside a quoted value cannot close the array early.
    """
    spans, i = [], 0
    while True:
        start = text.find("[", i)
        if start == -1:
            return spans
        depth, in_str, esc, end = 0, False, False, -1
        for j in range(start, len(text)):
            ch = text[j]
            if in_str:
                if esc:
                    esc = False
                elif ch == "\\":
                    esc = True
                elif ch == '"':
                    in_str = False
                continue
            if ch == '"':
                in_str = True
            elif ch == "[":
                depth += 1
            elif ch == "]":
                depth -= 1
                if depth == 0:
                    end = j
                    break
        if end == -1:
            return spans
        spans.append(text[start:end + 1])
        i = end + 1


def parse_verdict(text: str) -> tuple[list[str], bool]:
    """(ids, understood). Never raises.

    `understood` is the load-bearing half and the reason this does not simply
    return a list. An empty verdict — the model read the shortlist and chose
    nothing — is a real, honest, publishable answer. Unparseable output is a
    failure that must fall back to code's ranking. Both produce zero ids, and
    collapsing them either publishes nothing on a model outage or marks a
    garbled night judged.
    """
    if not text:
        return [], False

    stripped = _strip_fences(text)

    # 1. The whole reply as JSON. The prompt asks for exactly this.
    for candidate in (stripped, text.strip()):
        try:
            data = json.loads(candidate)
        except (ValueError, TypeError):
            continue
        if isinstance(data, list):
            return _ids_from(data), True
        if isinstance(data, dict):
            for key in AFFIRMATIVE_KEYS:
                if isinstance(data.get(key), list):
                    return _ids_from(data[key]), True
            # An object with no affirmative key. Refused here rather than
            # falling through to the scan below, which would happily read
            # `{"rejected": [...]}` as the answer. See AFFIRMATIVE_KEYS.
            return [], False
        break

    # 2. An array embedded in prose. Tolerated because the cost of refusing a
    #    "Here is the JSON:" line is a whole night's curation, and every id is
    #    still checked against the real shortlist by the veto afterwards.
    saw_array = False
    for span in _balanced_arrays(stripped):
        try:
            data = json.loads(span)
        except (ValueError, TypeError):
            continue
        if not isinstance(data, list):
            continue
        saw_array = True
        ids = _ids_from(data)
        if ids:
            return ids, True
    return [], saw_array


def parse_ids(text: str) -> list[str]:
    """The ids alone, for callers that do not need the verdict distinction."""
    return parse_verdict(text)[0]


def judge(rows: list[dict], runner, prompt_path: Path | None = None
          ) -> tuple[list[str], str]:
    """(ids, note). `note` is "ok", "empty", or why the pass produced nothing.

    `runner` takes the assembled prompt and returns (output, note) — the
    house_call.call_model signature. Injected so the suite never touches a
    subprocess.

    **A runner note other than "ok" is fatal here, even when ids parsed.**
    house_call returns stdout on a non-zero exit because a partial stream can
    still hold usable summaries. That trade is wrong for this pass: a refusal
    whose text happens to contain an array would otherwise publish as a curated
    selection. Falling back costs a night's curation; getting this wrong costs
    an unrecallable delivery.
    """
    if not rows:
        return [], "nothing to judge"
    try:
        output, note = runner(assemble_prompt(rows, prompt_path))
    except Exception as exc:                                # noqa: BLE001
        return [], f"{type(exc).__name__}: {exc}"

    if note != "ok":
        return [], note

    ids, understood = parse_verdict(output)
    if ids:
        return ids, "ok"
    if understood:
        return [], "empty"
    return [], "no usable ids in the model output"


def assert_prompt_contract() -> None:
    """The prompt, this module and feed_select all have to agree.

    Four ways the pairing breaks while still looking fine to a reader:

      - `{{ITEMS}}` renamed, so every call is made against a prompt with no
        items in it and the model answers from nothing.
      - The output contract losing the word JSON, after which nothing parses and
        the pass degrades to unjudged in perfect silence.
      - The ceiling in the prose drifting from this module's.
      - This module's ceiling drifting from feed_select.DAILY_CAP, which is the
        authority the veto actually enforces. Asserted by lazy import, the same
        way house_voice.assert_tag_vocabularies_agree does it, because a
        restated constant with nothing checking it is the drift class this
        codebase has already paid for twice.
    """
    text = PROMPT_PATH.read_text(encoding="utf-8")
    problems = []
    if "{{ITEMS}}" not in text:
        problems.append("the prompt has no {{ITEMS}} placeholder")
    if "JSON array" not in text:
        problems.append("the prompt does not ask for a JSON array")
    # Tolerant of markdown emphasis, strict about the number: the trailing
    # (?!\d) is what stops "at most 70" satisfying a cap of 7.
    if not re.search(rf"at most\s+\**{CAP}\**(?!\d)", text):
        problems.append(f"the prompt does not state the cap of {CAP}")

    import feed_select
    if CAP != feed_select.DAILY_CAP:
        problems.append(
            f"CAP is {CAP} but feed_select.DAILY_CAP is {feed_select.DAILY_CAP} — "
            f"the prompt would tell the model a ceiling the veto does not enforce")

    if problems:
        raise AssertionError("feed-relevance.md: " + "; ".join(problems))
