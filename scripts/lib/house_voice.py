"""E8 — the house voice: model-written card summaries, and the rules they must pass.

Four separable pieces, deliberately, because three of them are pure and the
fourth is the only one that costs money or needs a network:

    build_input      pool rows + fetched article text -> the ITEMS block
    assemble_prompt  the prompt file + that block -> exactly what the model sees
    parse_output     model stdout -> a list of card dicts
    validate_card    one card + its source text -> (ok, reason)

Everything except the model call itself is testable offline, and the test suite
exercises all of it with no network and no spend.

**The ladder is per item.** A card that fails validation falls to the publisher's
own summary; it does not take the edition with it, and it does not take the other
six cards with it. A total parse failure costs every card its top rung and the
edition still publishes at rung 2. That degradation is the design, not a bug — it
is why the feed worked before E8 existed.

**The dangerous rule, and why it ships with a metric.** "No fact absent from the
source" is enforceable: numbers and proper nouns in the summary must appear in
the source. But the cheapest way to satisfy a rule about facts is to write no
facts — a summary with no figures and no names cannot contain a wrong one, and it
also cannot be worth reading. So `metrics()` reports specificity from the first
run, before anyone starts tuning the prompt against the validator. See S8.8 in
plans/daily-kickoff/public-feed/2026-08-08-execution-plan.md.

Pure stdlib. No clock, no network, no I/O except reading the prompt file.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

PROMPT_PATH = Path(__file__).resolve().parent.parent / "prompts" / "feed-house-voice.md"

# The card body has to stand alone next to a headline and under a link. These are
# the validator's bounds, and they are wider than the prompt asks for on purpose:
# the prompt states the target, the validator catches the failure. A validator
# set to the prompt's exact numbers rejects good cards for being one sentence
# long, and every rejection is a silent downgrade to rung 2.
LEN_BOUNDS = {
    "article": (140, 520),
    # A video or podcast page gets one or two lines — the owner's rule. The floor
    # is low because "what it is and what it covers" genuinely fits in 70
    # characters, and the ceiling is low because anything longer is the model
    # narrating a video it has not watched.
    "media": (60, 300),
}

# The closed tag vocabulary. Duplicated from feed_edition.TAGS deliberately —
# see assert_tag_vocabularies_agree() at the bottom, which fails if they drift.
TAGS = ("agentic coding", "engineering leadership", "enterprise & governance",
        "models & research", "developer experience", "robotics")

# Every way a card can be refused. Closed, so a new failure has to be named
# rather than folded into "other", and so the nightly log can count reasons.
REJECT_REASONS = (
    "not_a_dict", "unknown_id", "empty", "too_short", "too_long",
    "first_person", "second_person", "hype", "call_to_action", "markup",
    "url", "unsourced_number", "unsourced_name", "copied", "restates_title",
)

_FIRST_PERSON_RE = re.compile(
    r"\b(?:I|I'm|I've|we|we're|we've|our|ours|us|let's)\b", re.I)

# "you" in the reader-addressing sense. The feed has no relationship with the
# reader and must not pretend to one.
_SECOND_PERSON_RE = re.compile(r"\b(?:you|your|yours|you're|you'll|you've)\b", re.I)

_HYPE_RE = re.compile(
    r"\b(?:game[- ]?chang(?:er|ing)|revolutionary|revolutionis\w+|revolutioniz\w+"
    r"|must[- ]read|must[- ]see|ground[- ]?breaking|cutting[- ]edge|state[- ]of[- ]the[- ]art"
    r"|seismic|paradigm shift|the future of|unprecedented|mind[- ]blowing"
    r"|blazing[- ]?fast|supercharg\w+|unleash\w*|delve into)\b", re.I)

_CTA_RE = re.compile(
    r"\b(?:read (?:more|on|the full)|click here|check (?:it|this) out|find out more"
    r"|learn more|don'?t miss|sign up|subscribe|watch now|listen now|full story)\b", re.I)

_MARKUP_RE = re.compile(r"<[a-zA-Z/!][^>]*>|\[[^\]]+\]\([^)]*\)|(?:^|\s)[*_]{2}\S")

_URL_RE = re.compile(r"https?://|www\.\S+\.\w{2,}")

# A number the reader can check: 12, 3.5, 1,200, 40%, $2B, GPT-5. Bare years are
# excluded — "in 2026" is calendar context, not a claim, and a source that talks
# about this year without printing the digits is common.
_NUMBER_RE = re.compile(r"\d[\d,]*(?:\.\d+)?%?")

# A named actor: a capitalised token of three or more characters, or a run of
# them. Deliberately crude — this is a containment check against the source, not
# a named-entity recogniser, and a false positive costs one card its top rung
# while a false negative lets an invented company name through.
_NAME_RE = re.compile(r"\b[A-Z][A-Za-z0-9]*(?:[.\-+][A-Za-z0-9]+)*\b")

# Capitalised words that are not names: sentence openers, weekdays, months, and
# the generic nouns that open a sentence in this register. Checking these against
# the source would reject correct cards for using the word "The".
#
# **Sentence-initial words are checked like any other**, and that is a deliberate
# reversal. Skipping them is the obvious way to avoid false positives — grammar
# capitalises the first word, so it carries no signal — but it exempts the single
# most dangerous case there is: a summary that opens "Anthropic released…" about
# an article that never mentions Anthropic. A card naming the wrong company on a
# public page is the worst outcome in this system; a card that falls to the
# publisher's own summary is a mild one. So the rule fails toward strictness.
#
# The cost is real and is paid in silence: a good summary opening with a common
# noun the source happens not to use is refused. That is what this list is for,
# and what the nightly `unsourced_name` count is for — a rule over-firing shows
# up there as a rising number, which is the only place it can show up at all.
_NOT_A_NAME = frozenset("""
a an and as at but by for from in into is it its of on or the this that these
those to with within without over under after before during while when where
why how what which who whom whose than then there here they them their he she
his her we you i us our your not no nor so yet if because although though
however meanwhile instead rather also even only just still since despite amid
according following across among between beyond about against
both each every all most many some several few more fewer other another none
one two three first second third next last later early earlier recent
new news now today yesterday tomorrow week weeks month months year years day days
monday tuesday wednesday thursday friday saturday sunday
january february march april may june july august september october november december
ai ml api apis cli sdk llm llms open source data model models team teams
company companies developer developers engineer engineers user users
adoption analysts article articles benchmark benchmarks coverage cost costs
customers demand development engineering enterprise enterprises episode
global growth guide hiring industry interview investment large leaders
managers panel platform platforms podcast post posts price prices pricing
productivity report reports research researchers results revenue security
series small software study support survey talk tools traffic training usage
vendors video work workers
attendees demand executives figures organisers organizers panelists
participants sessions speakers sponsors
""".split())

# The last group above came from the live rejection log, not from imagination —
# "Panelists include Rodney Brooks" cost a real card its house summary on
# 2026-08-09. That is how this list is meant to grow: a word earns its place by
# showing up in an `unsourced_name` rejection whose text is plainly fine, which
# is exactly why the rejected text is logged alongside the reason.

# Contiguous identical wording longer than this is a lift, not a coincidence.
# Twelve words is roughly a full clause; product names and terms of art do not
# reach it.
_MAX_VERBATIM_RUN = 12

# Share of the summary's word-shingles that may also appear in the source.
#
# The shingle length is 5, not 8, and the reason is arithmetic rather than taste.
# At 8 the rule was dead code: exceeding 40% overlap on 8-grams requires runs of
# thirteen or more identical words, and `_MAX_VERBATIM_RUN` already refuses at
# twelve, so the shingle check could never be the rule that fired. At 5 it covers
# the case the run rule cannot see — a lift reworded every seven or eight words,
# where no single run is long but almost the whole summary is borrowed.
_SHINGLE = 5
_MAX_SHINGLE_OVERLAP = 0.35


# ── input ────────────────────────────────────────────────────────────────────

def build_input(rows: list[dict], fetched: dict[str, tuple[str, str, str]]) -> list[dict]:
    """The per-item source material, one entry per item worth asking about.

    `fetched` is keyed by url and holds (text, kind, reason) from
    article_fetch.fetch_article.

    **An item whose fetch produced nothing is not included.** Asking the model to
    summarise a publisher's blurb yields a paraphrase of a paraphrase: original
    prose, so the quotation exposure is gone, but no information the reader did
    not already have — and thin input is exactly where a model invents a detail
    to fill the space. The card falls to rung 2 instead, which shows the reader
    the publisher's own words. That is a better outcome than a confident
    paragraph about a page nobody read.

    **A media item gets the publisher's blurb as well as the page text**, and
    that is not a detail. A podcast or video page often has no prose at all — its
    first two paragraphs can be breadcrumb navigation ("Homepage Podcasts Culture
    & Methods") — while the RSS blurb describes the episode properly. Without the
    blurb the one-line media summary would be written from navigation furniture.
    """
    items = []
    for row in rows:
        url = (row.get("url") or "").strip()
        text, kind, reason = fetched.get(url, ("", "", "no_fetch"))
        if reason != "ok" or not kind:
            continue
        blurb = (row.get("summary") or "").strip()
        # Blurb first for media: it is usually the better material there, and the
        # scraped text is whatever the page had left over.
        source = (f"{blurb}\n\n{text}" if kind == "media" else f"{text}\n\n{blurb}").strip()
        items.append({
            "id": row.get("id", ""),
            "title": (row.get("title") or "").strip(),
            "source_name": row.get("source", ""),
            "kind": kind,
            "publisher_summary": blurb,
            "text": text,
            # What the validator checks facts against. It includes the title and
            # the publisher's blurb, not only the scraped body: a headline names
            # the company, and rejecting a card for naming it would be absurd.
            "source_text": f"{row.get('title', '')}\n{source}",
        })
    return items


def render_items(items: list[dict]) -> str:
    """The ITEMS block, exactly as the model sees it."""
    blocks = []
    for it in items:
        parts = [f"ID: {it['id']}",
                 f"KIND: {it['kind']}",
                 f"TITLE: {it['title']}",
                 f"PUBLICATION: {it['source_name']}"]
        if it["publisher_summary"]:
            parts.append(f"PUBLISHER SUMMARY: {it['publisher_summary']}")
        if it["text"]:
            parts.append(f"ARTICLE TEXT:\n{it['text']}")
        blocks.append("\n".join(parts))
    return "\n\n----\n\n".join(blocks)


def assemble_prompt(items: list[dict], prompt_path: Path | None = None) -> str:
    """The prompt file with the items substituted in — the whole model input.

    Assembled rather than concatenated by the caller so the *assembled result*
    is what the pinning suite checks. A prompt built from parts that are each
    correct can still be wrong once joined, and the join is where the digest's
    personal profile block would arrive if anyone ever reached for it.
    """
    text = (prompt_path or PROMPT_PATH).read_text(encoding="utf-8")
    return text.replace("{{ITEMS}}", render_items(items))


# ── output ───────────────────────────────────────────────────────────────────

def parse_output(text: str) -> list[dict]:
    """The JSON array out of whatever the model printed. Never raises.

    The prompt asks for bare JSON and nothing else. This tolerates a fence and a
    line of preamble anyway, because the cost of being strict is losing seven
    good summaries to a "Here is the JSON:" line.
    """
    if not text:
        return []
    fenced = re.search(r"```(?:json)?\s*(.+?)```", text, re.S)
    candidates = []
    if fenced:
        candidates.append(fenced.group(1))
    start = text.find("[")
    if start != -1:
        # Balanced scan, not a greedy regex: a summary containing "]" would
        # truncate the array at the wrong place.
        depth, in_str, esc = 0, False, False
        for i in range(start, len(text)):
            ch = text[i]
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
                    candidates.append(text[start:i + 1])
                    break
    for cand in candidates:
        try:
            data = json.loads(cand)
        except (ValueError, TypeError):
            continue
        if isinstance(data, list):
            return [d for d in data if isinstance(d, dict)]
    return []


# ── validation ───────────────────────────────────────────────────────────────

def _words(s: str) -> list[str]:
    """Words, with a dotted version number counted as one of them.

    "Agent Plugins 1.0.0" is three words to a reader and was five to the naive
    split, which handed every borrowed version string two free words of apparent
    overlap and inflated the longest-run measurement around it. The dot only
    joins when a digit or letter follows it immediately, so a sentence boundary —
    "the tier. The company" — still separates.
    """
    return re.findall(r"[a-z0-9]+(?:\.[a-z0-9]+)+|[a-z0-9]+", s.lower())


def _numbers(s: str) -> set[str]:
    out = set()
    for m in _NUMBER_RE.finditer(s):
        tok = m.group(0).replace(",", "")
        # A bare four-digit year is calendar context, not a sourced claim.
        if re.fullmatch(r"(?:19|20)\d{2}", tok):
            continue
        out.add(tok.rstrip("%"))
    return out


def _names(s: str) -> set[str]:
    out = set()
    for m in _NAME_RE.finditer(s):
        tok = m.group(0)
        if len(tok) < 3 or tok.lower() in _NOT_A_NAME:
            continue
        out.add(tok)
    return out


def _name_is_sourced(name: str, src_names: set[str], src_lower: str) -> bool:
    """Whether the source vouches for this name.

    The compound arm is not a loophole, it is a bug fix. `_NAME_RE` joins a name
    to a hyphenated suffix — "Vercel-initiated" — and that whole string appears in
    no article, so a correctly-sourced company was being refused for the shape of
    the adjective attached to it. Measured on a real run: two of seven cards lost
    their house summary this way, and one of the two was this.

    Splitting is safe because the digits travel separately: "GPT-5" against a
    source that only says "GPT-4" passes this check on "GPT" and is then refused
    by the number rule, which is the layer that owns that distinction.
    """
    low = name.lower()
    if low in src_names or low in src_lower:
        return True
    caps = [p for p in re.split(r"[.\-+]", name) if p[:1].isupper() and len(p) >= 3]
    return bool(caps) and all(p.lower() in src_names or p.lower() in src_lower
                              for p in caps)


def _verbatim_run(summary: str, source: str) -> int:
    """Longest run of consecutive words the summary shares with the source."""
    sw, src = _words(summary), " " + " ".join(_words(source)) + " "
    best = 0
    for i in range(len(sw)):
        for j in range(i + best + 1, len(sw) + 1):
            if f" {' '.join(sw[i:j])} " in src:
                best = j - i
            else:
                break
    return best


def _shingle_overlap(summary: str, source: str, n: int = _SHINGLE) -> float:
    sw, srcw = _words(summary), _words(source)
    if len(sw) < n:
        return 0.0
    shingles = {" ".join(sw[i:i + n]) for i in range(len(sw) - n + 1)}
    src = {" ".join(srcw[i:i + n]) for i in range(max(0, len(srcw) - n + 1))}
    return len(shingles & src) / len(shingles)


def validate_card(card: dict, item: dict) -> tuple[bool, str]:
    """(ok, reason). `reason` is "ok" on success, else a member of REJECT_REASONS.

    Every rejection is a downgrade to the publisher's own summary, never a
    dropped item and never a failed edition.
    """
    if not isinstance(card, dict):
        return False, "not_a_dict"
    if card.get("id") != item.get("id"):
        return False, "unknown_id"

    summary = (card.get("summary") or "").strip()
    if not summary:
        return False, "empty"

    lo, hi = LEN_BOUNDS.get(item.get("kind", "article"), LEN_BOUNDS["article"])
    if len(summary) < lo:
        return False, "too_short"
    if len(summary) > hi:
        return False, "too_long"

    if _MARKUP_RE.search(summary):
        return False, "markup"
    if _URL_RE.search(summary):
        return False, "url"
    if _FIRST_PERSON_RE.search(summary):
        return False, "first_person"
    if _SECOND_PERSON_RE.search(summary):
        return False, "second_person"
    if _HYPE_RE.search(summary):
        return False, "hype"
    if _CTA_RE.search(summary):
        return False, "call_to_action"

    source = item.get("source_text", "")

    # The rule that matters. Checked on both halves of "a fact": the figures and
    # the actors. A number the source never printed is an invented number, and a
    # company the source never mentioned is an invented company — which is the
    # worse of the two, because it is the one that gets a card about the wrong
    # organisation onto a public page.
    src_numbers = _numbers(source)
    for num in _numbers(summary):
        if num not in src_numbers:
            return False, "unsourced_number"
    src_names = {n.lower() for n in _names(source)}
    src_lower = source.lower()
    for name in _names(summary):
        if not _name_is_sourced(name, src_names, src_lower):
            return False, "unsourced_name"

    # Original prose is the point. A reworded lift keeps the quotation exposure
    # the house voice exists to remove, and it does it while claiming not to.
    if _verbatim_run(summary, source) > _MAX_VERBATIM_RUN:
        return False, "copied"
    if _shingle_overlap(summary, source) > _MAX_SHINGLE_OVERLAP:
        return False, "copied"

    # A summary that opens by reprinting the headline wastes the only line the
    # card has — the headline is already on the card, directly above it.
    #
    # Verbatim containment, and only that. The first version of this rule refused
    # a summary that added three or fewer words to the title's vocabulary, which
    # sounds stricter and was in fact unreachable: the length floor above runs
    # first, and no 140-character summary adds three new words. It could never
    # have fired. Detecting a *paraphrase* of the headline is not something this
    # function can do at all — that is what the specificity metrics are for.
    title = " ".join(_words(item.get("title", "")))
    if len(title.split()) >= 4 and title in " ".join(_words(summary)):
        return False, "restates_title"

    return True, "ok"


def house_summaries(items: list[dict], model_output: str) -> tuple[dict[str, str],
                                                                  dict[str, list[str]],
                                                                  dict[str, int],
                                                                  list[tuple[str, str]]]:
    """(summaries by id, tags by id, rejection counts by reason, rejected samples).

    The counts are returned rather than logged so the caller decides where they
    go. A run where every card was rejected looks identical on the page to a run
    where the model was never called, and these counts are the only thing that
    tells them apart.

    `rejects` carries the text as well as the reason, and that is not a debugging
    nicety. "copied=1" in a log tells the owner nothing about whether the rule
    was right — a genuine lift and an over-firing rule produce the identical
    line, and only one of them wants fixing.
    """
    by_id = {it["id"]: it for it in items}
    cards = parse_output(model_output)
    summaries: dict[str, str] = {}
    tags: dict[str, list[str]] = {}
    counts: dict[str, int] = {}
    rejects: list[tuple[str, str]] = []

    for card in cards:
        item = by_id.get(card.get("id")) if isinstance(card, dict) else None
        if item is None:
            counts["unknown_id"] = counts.get("unknown_id", 0) + 1
            continue
        ok, reason = validate_card(card, item)
        if not ok:
            counts[reason] = counts.get(reason, 0) + 1
            rejects.append((reason, (card.get("summary") or "").strip()))
            continue
        summaries[item["id"]] = card["summary"].strip()
        raw = card.get("tags") or []
        tags[item["id"]] = [t for t in raw if isinstance(t, str) and t in TAGS][:2]

    # Silence is a result. An item the model omitted is a deliberate outcome the
    # prompt asks for, and it must be counted, not inferred from a subtraction
    # nobody performs.
    omitted = len(items) - len({c.get("id") for c in cards if isinstance(c, dict)}
                               & set(by_id))
    if omitted > 0:
        counts["omitted"] = omitted
    return summaries, tags, counts, rejects


# ── S8.8: the paired metrics ─────────────────────────────────────────────────

def metrics(summaries: dict[str, str], items: list[dict]) -> dict:
    """Specificity, measured from the first run rather than after the first
    disappointment.

    Every hard rule here has a cheapest evasion, and for "no fact absent from the
    source" the evasion is to write no facts at all. A card reading "The article
    discusses recent developments in enterprise software" passes every rule in
    `validate_card` and is worth nothing. Nothing in the loop can catch that —
    the model is single-shot with no retry, so the Goodhart pressure runs through
    a human tuning the prompt against a dashboard. The dashboard therefore has to
    exist before the first tuning edit.

    `number_rate` and `name_rate` are measured only over items whose source
    actually contained numbers or names, so a day of number-free essays does not
    read as a regression.
    """
    by_id = {it["id"]: it for it in items}
    n = len(summaries)
    num_eligible = num_carried = name_eligible = name_carried = 0
    lengths = []
    for iid, summary in summaries.items():
        item = by_id.get(iid)
        if item is None:
            continue
        lengths.append(len(summary))
        if _numbers(item.get("source_text", "")):
            num_eligible += 1
            if _numbers(summary):
                num_carried += 1
        if _names(item.get("source_text", "")):
            name_eligible += 1
            if _names(summary):
                name_carried += 1
    return {
        "cards": n,
        "mean_length": round(sum(lengths) / len(lengths)) if lengths else 0,
        "number_rate": round(num_carried / num_eligible, 3) if num_eligible else None,
        "name_rate": round(name_carried / name_eligible, 3) if name_eligible else None,
        "number_eligible": num_eligible,
        "name_eligible": name_eligible,
    }


def assert_tag_vocabularies_agree() -> None:
    """The tag list lives here and in feed_edition, and a card tagged with a word
    the edition builder drops is a silent no-op. Two copies that must agree, with
    something that fails when they do not.
    """
    from feed_edition import TAGS as EDITION_TAGS
    if tuple(TAGS) != tuple(EDITION_TAGS):
        raise AssertionError(
            f"tag vocabularies have drifted: house_voice {TAGS} vs "
            f"feed_edition {EDITION_TAGS}")
