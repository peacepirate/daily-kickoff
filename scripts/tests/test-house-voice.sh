#!/bin/bash
# E8 — the house voice: prompt pinning (S8.4), the validator (S8.5), the
# both-implementations assertion (S8.6), golden fixtures (S8.7) and the paired
# metrics (S8.8).
#
# No model is called. Every model output here is a fixture, which is the point:
# the expensive half of E8 is one CLI invocation, and everything that decides
# whether its output is publishable is pure and runs in a second.
#
# The assertion that has to land first is at the top — the prompt and the
# validator are two implementations of one rule set, one in English for the
# model and one in regex for the gate, and a suite that only checks the regex
# proves the model was never told. Everything after it is downstream of that.
#
#   bash scripts/tests/test-house-voice.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

"$PYBIN" - "$REPO_DIR" <<'PY'
import json, sys
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "scripts" / "lib"))
import house_voice as hv
import feed_edition as fe

FAIL = 0; COUNT = 0
def ok(m):
    global COUNT; COUNT += 1; print(f"  \033[32mok\033[0m    {m}")
def bad(m):
    global FAIL, COUNT; COUNT += 1; FAIL = 1; print(f"  \033[31mFAIL\033[0m  {m}")
def chk(label, got, want):
    ok(label) if got == want else bad(f"{label} (got {got!r}, wanted {want!r})")

PROMPT = hv.PROMPT_PATH.read_text(encoding="utf-8")
LOW = PROMPT.lower()


print("── S8.6 first: the prompt and the validator name the same rules ──────────")
# A validator rule the prompt never states is a trap: the model is penalised for
# breaking a rule it was never given, every card silently drops to rung 2, and
# the page looks fine. Each reason below is paired with the words in the prompt
# that impose it. This is the differential assertion, and it lands before any
# mutation because the mutations prove nothing without it.
IMPOSED_BY = {
    "too_short":        ["sentences", "characters"],
    "too_long":         ["characters"],
    "first_person":     ["third person only"],
    "second_person":    ["third person only"],
    "hype":             ["no hype"],
    "call_to_action":   ["no calls to action"],
    "markup":           ["no markdown"],
    "url":              ["no urls"],
    "unsourced_number": ["every number"],
    "unsourced_name":   ["every company name"],
    "copied":           ["do not copy"],
    "restates_title":   ["restates it"],
    "empty":            ["omit"],
    "unknown_id":       ["copied exactly"],
}
missing = [r for r in hv.REJECT_REASONS
           if r != "not_a_dict" and
           not all(p in LOW for p in IMPOSED_BY.get(r, ["\x00"]))]
chk("every validator rejection is a rule the prompt actually states", missing, [])
# not_a_dict is structural, not a rule — a non-object in the array is malformed
# JSON, not a summary that broke an instruction.
chk("and every reason is accounted for either way",
    sorted(set(hv.REJECT_REASONS) - set(IMPOSED_BY)), ["not_a_dict"])

# The other half of the same idea: the tag vocabulary is written in three places
# — the prompt, this module, and the edition builder — and a tag the edition
# builder drops is a silent no-op, not an error.
chk("the tag vocabulary agrees between house_voice and feed_edition",
    tuple(hv.TAGS), tuple(fe.TAGS))
hv.assert_tag_vocabularies_agree()
# Calling it and watching it not raise proves nothing — an assertion that can
# never fire passes identically. Drift it on purpose and require the complaint.
_real = fe.TAGS
try:
    fe.TAGS = ("robotics",)
    try:
        hv.assert_tag_vocabularies_agree()
        bad("the drift assertion does not fire when the vocabularies differ")
    except AssertionError:
        ok("the drift assertion fires when the vocabularies differ")
finally:
    fe.TAGS = _real

# Both directions. Checking only that the code's tags reach the prompt misses the
# opposite failure — a tag offered to the model that the edition builder silently
# drops, which reads to a reader as a card that lost its tag for no reason.
import re as _re
_block = _re.search(r"spelled exactly:\n\n((?:    \S.*\n)+)", PROMPT)
offered = tuple(l.strip() for l in _block.group(1).strip().split("\n")) if _block else ()
chk("the prompt offers exactly the tags the code accepts, no more and no fewer",
    offered, tuple(hv.TAGS))


print("── S8.4 prompt pinning: the digest profile block is absent ───────────────")
# The digest prompts open with a block naming a real person, their employer and
# their city, and address the model to write TO them. This prompt was written
# from scratch precisely so that block could never arrive by copy-edit — and the
# feed is an unsigned, unaffiliated product, so a personal profile reaching it
# would be a privacy leak into a public page, not a style slip.
BANNED = ["who priyesh is", "priyesh", "write to priyesh", "senior engineering manager",
          "richmond", "financial-services", "gods of the future past", "bedrock",
          "your role", "side project"]
leaked = [b for b in BANNED if b in LOW]
chk("no digest profile fragment appears in the prompt", leaked, [])

items = [{"id": "aaa111", "title": "OpenAI ships a smaller model",
          "source_name": "The Register", "kind": "article",
          "publisher_summary": "A cheaper tier arrives.",
          "text": "OpenAI released a smaller model on Tuesday, priced 40% below "
                  "the previous tier. The company said the cheaper tier is aimed "
                  "at developers running high volumes of requests, a group that "
                  "had repeatedly told it the old rate was hard to justify. "
                  "Pricing takes effect immediately for new accounts and next "
                  "month for existing ones.",
          "source_text": "OpenAI ships a smaller model\n"
                         "OpenAI released a smaller model on Tuesday, priced 40% "
                         "below the previous tier. The company said the cheaper "
                         "tier is aimed at developers running high volumes of "
                         "requests, a group that had repeatedly told it the old "
                         "rate was hard to justify. Pricing takes effect "
                         "immediately for new accounts and next month for "
                         "existing ones."},
         {"id": "bbb222", "title": "Trends 2026: the human side",
          "source_name": "InfoQ", "kind": "media",
          "publisher_summary": "A podcast panel on how teams are adapting to AI tooling.",
          "text": "InfoQ Homepage Podcasts Culture & Methods",
          "source_text": "Trends 2026: the human side\nA podcast panel on how teams "
                         "are adapting to AI tooling.\n\nInfoQ Homepage Podcasts "
                         "Culture & Methods"}]

assembled = hv.assemble_prompt(items)
chk("the assembled prompt carries no unsubstituted placeholder",
    "{{" in assembled, False)
chk("...and the items really were substituted in", "aaa111" in assembled, True)
# The check above passes on an empty items list too, so this one has to exist.
chk("an item's article text reaches the model", "priced 40% below" in assembled, True)
chk("the kind reaches the model, since it sets the length rule",
    "KIND: media" in assembled, True)
chk("assembling twice gives the same string", assembled, hv.assemble_prompt(items))


print("── S8.5 the validator: the hard prohibitions ─────────────────────────────")
GOOD = ("OpenAI released a smaller model on Tuesday, priced 40% below the tier it "
        "replaces. The company is targeting developers who found the previous "
        "pricing hard to justify for high-volume work.")

def verdict(summary, item=items[0], **kw):
    card = {"id": item["id"], "summary": summary, "tags": []}
    card.update(kw)
    return hv.validate_card(card, item)[1]

chk("a clean summary passes", verdict(GOOD), "ok")
# Checked directly, not through house_summaries: that function looks the item up
# BY the card's id, so the two can never disagree there and this rule would be
# unreachable from every other test in the file.
chk("a card carrying another item's id is refused",
    hv.validate_card({"id": "bbb222", "summary": GOOD, "tags": []}, items[0])[1],
    "unknown_id")

for label, text, reason in [
    ("first person", GOOD.replace("The company is", "We think the company is"), "first_person"),
    ("addressing the reader", GOOD.replace("The company is", "You will find it is"), "second_person"),
    ("hype", GOOD.replace("smaller model", "game-changing model"), "hype"),
    ("a call to action", GOOD + " Read more at the source.", "call_to_action"),
    ("a url", GOOD.replace("Tuesday", "Tuesday (https://openai.com)"), "url"),
    ("html", GOOD.replace("OpenAI", "<b>OpenAI</b>"), "markup"),
    ("markdown link", GOOD.replace("OpenAI", "[OpenAI](https://x.com)"), "markup"),
    ("an empty summary", "", "empty"),
    ("a fragment", "Too short.", "too_short"),
    ("an essay", GOOD + " " + ("Filler that goes on. " * 40), "too_long"),
]:
    chk(f"{label} is refused", verdict(text), reason)

print("── ...and the one that matters: no fact absent from the source ───────────")
chk("a number the source never printed is refused",
    verdict(GOOD.replace("40%", "63%")), "unsourced_number")
chk("a company the source never mentioned is refused",
    verdict(GOOD.replace("OpenAI released", "Anthropic released")), "unsourced_name")
# The rule must not fire on facts that ARE sourced, or every card drops to rung 2
# and the failure is invisible.
chk("a sourced number passes", verdict(GOOD), "ok")
chk("a name from the headline alone passes",
    verdict("Coverage of the smaller model OpenAI shipped this week, with the "
            "pricing change set out and some context on which developers it is "
            "aimed at and why the tier existed."), "ok")
chk("a bare year is not treated as an unsourced number",
    verdict(GOOD.replace("on Tuesday", "in 2026")), "ok")
# Grammar capitalises the first word of a sentence, so the obvious rule is to
# skip it — and that exempts the worst case there is, a card that opens
# "Anthropic released..." about an article that never mentions Anthropic. The
# rule deliberately fails toward strictness instead.
chk("an invented name is caught even at the start of a sentence",
    verdict("Anthropic released a smaller model on Tuesday, priced 40% below the "
            "tier it replaces. The pricing is aimed at developers running high "
            "volumes, who found the earlier rate hard to justify."),
    "unsourced_name")
# Both of these are real rejections from the first live run against seven real
# articles, and only one of them was the rule being right.
COMPOUND = ("An {}-backed price change of 40% lands on Tuesday, putting the "
            "smaller tier under what the one before it charged, and aiming "
            "squarely at the heaviest users.")
chk("a sourced name inside a hyphenated compound passes",
    verdict(COMPOUND.format("OpenAI")), "ok")
chk("...but an invented name inside a compound is still refused",
    verdict(COMPOUND.format("Anthropic")), "unsourced_name")
# Every capitalised segment has to be sourced, not merely one of them: a
# compound pairing a real name with an invented one is the case where "any"
# and "all" part company, and it is the one that puts the wrong company on a
# public page.
chk("...and one sourced half does not vouch for the other",
    verdict(COMPOUND.format("OpenAI-Anthropic")), "unsourced_name")
# The other live rejection was "Mars" where the article said "Martian". The
# validator cannot know those are the same thing, so the prompt has to.
chk("the prompt tells the model to spell names as the source spells them",
    "spell every name the way the source spells it" in LOW, True)

chk("a common noun opening a sentence is not treated as a name",
    verdict("Pricing drops 40% on the tier OpenAI replaced this week. Developers "
            "running high volumes were the group the earlier rate could not "
            "serve, and the change is aimed squarely at them."), "ok")

print("── originality: a reworded lift is not a house summary ───────────────────")
# Two rules, and each needs a fixture the other cannot catch, or one of them is
# dead code that nothing would notice.
#
# This one is a fourteen-word lift dropped into otherwise original prose. Only
# 31% of its five-word windows are borrowed, under the shingle cap — so the
# longest-run rule is the only thing standing between it and the page.
LIFT = ("Under a change announced this week, the cheaper tier is aimed at developers "
        "running high volumes of requests, a group whose complaints about cost had "
        "grown loud enough for the pricing team to notice at last.")
chk("a long verbatim chunk inside original prose is refused", verdict(LIFT), "copied")
# A version string is one word to a reader. Counting "1.0.0" as three handed
# every borrowed version two free words of apparent overlap, which inflated the
# run measurement around exactly the phrases that are hardest to reword.
chk("a dotted version number counts as one word",
    hv._words("Agent Plugins 1.0.0 shipped"), ["agent", "plugins", "1.0.0", "shipped"])
chk("...and a sentence boundary still separates",
    hv._words("the tier. The company"), ["the", "tier", "the", "company"])
chk("...and the shingle rule alone would have missed it",
    hv._shingle_overlap(LIFT, items[0]["source_text"]) <= hv._MAX_SHINGLE_OVERLAP, True)
# Two separate rules, and this fixture is what proves the second one is not dead
# code. Its longest borrowed run is nine words — under the run rule's limit of
# twelve, so that rule cannot fire — while 40% of its five-word windows come
# straight from the source. A lift reworded every eight words is invisible to a
# longest-run check and is exactly what the shingle overlap exists to catch.
REWORDED = ("OpenAI released a smaller model on Tuesday, priced 40% under the "
            "previous tier, and the company said the cheaper tier is aimed toward "
            "developers running high volumes of requests, a group which had "
            "repeatedly told it the rate was hard to justify.")
chk("a lift reworded every few words is also refused", verdict(REWORDED), "copied")
chk("...and the longest-run rule alone would have missed it",
    hv._verbatim_run(REWORDED, items[0]["source_text"]) <= hv._MAX_VERBATIM_RUN, True)
chk("but ordinary shared wording is not",
    verdict("A cheaper tier landed this week. Pricing sits 40% under what OpenAI "
            "charged before, aimed at teams whose volume made the old rate hard "
            "to justify at all."), "ok")
chk("restating the headline is refused",
    verdict("OpenAI ships a smaller model. A smaller model ships, from OpenAI, "
            "and OpenAI ships a model that is smaller than the model OpenAI "
            "shipped before this smaller model shipped."), "restates_title")

print("── media items get their own length rule ─────────────────────────────────")
MEDIA = ("A podcast panel on how engineering teams are adapting their practices to "
         "AI tooling, from InfoQ's Culture and Methods track.")
chk("a two-line media summary passes", verdict(MEDIA, items[1]), "ok")
chk("the same length would be too short for an article",
    hv.LEN_BOUNDS["media"][0] < hv.LEN_BOUNDS["article"][0], True)
chk("a media summary that runs long is refused",
    verdict(MEDIA + " " + ("More narration of a video nobody watched. " * 8), items[1]),
    "too_long")
# The reason build_input exists in the shape it does: without the blurb, this
# item's only text is breadcrumb navigation.
chk("a media item's source text leads with the publisher blurb",
    items[1]["source_text"].index("podcast panel") <
    items[1]["source_text"].index("Homepage"), True)


print("── build_input: what the model is and is not asked about ─────────────────")
rows = [{"id": "aaa111", "url": "https://a.com/1", "title": "T1", "source": "S1",
         "summary": "Publisher blurb one, long enough to be a card body on its own."},
        {"id": "bbb222", "url": "https://b.com/2", "title": "T2", "source": "S2",
         "summary": "Publisher blurb two, also long enough to stand alone here."},
        {"id": "ccc333", "url": "https://c.com/3", "title": "T3", "source": "S3",
         "summary": "Publisher blurb three."}]
fetched = {"https://a.com/1": ("Real article prose about a thing.", "article", "ok"),
           # A real podcast page: the first two paragraphs are breadcrumbs.
           "https://b.com/2": ("Homepage Podcasts Culture and Methods", "media", "ok"),
           "https://c.com/3": ("", "", "too_thin")}
built = hv.build_input(rows, fetched)
chk("an item with no fetched text is not sent to the model",
    [b["id"] for b in built], ["aaa111", "bbb222"])
chk("an unfetched url is treated as no fetch at all",
    [b["id"] for b in hv.build_input(rows, {})], [])
# The fix this whole ordering exists for. A podcast page's opening paragraphs are
# navigation furniture — "Homepage Podcasts Culture and Methods" — while the RSS
# blurb describes the episode properly. Put the page text first and the one-line
# media summary gets written from breadcrumbs.
media = built[1]["source_text"]
chk("a media item's source leads with the publisher blurb, not the page text",
    media.index("Publisher blurb two") < media.index("Homepage"), True)
chk("...and an article's leads with the article",
    built[0]["source_text"].index("Real article prose") <
    built[0]["source_text"].index("Publisher blurb one"), True)


print("── parse_output: whatever the model actually prints ──────────────────────")
ARR = '[{"id": "aaa111", "summary": "s", "tags": []}]'
chk("bare json parses", len(hv.parse_output(ARR)), 1)
chk("a fenced block parses", len(hv.parse_output(f"```json\n{ARR}\n```")), 1)
chk("preamble is tolerated", len(hv.parse_output(f"Here is the JSON:\n{ARR}")), 1)
chk("trailing chatter is tolerated", len(hv.parse_output(f"{ARR}\nHope that helps!")), 1)
# A greedy regex would truncate at the "]" inside the string.
chk("a bracket inside a summary does not truncate the array",
    len(hv.parse_output('[{"id":"a","summary":"see [1] for detail"},{"id":"b"}]')), 2)
chk("garbage yields nothing rather than raising", hv.parse_output("not json at all"), [])
chk("empty output yields nothing", hv.parse_output(""), [])
chk("a json object rather than an array yields nothing", hv.parse_output('{"id":"a"}'), [])


print("── S8.7 golden fixtures: whole runs, end to end ──────────────────────────")

def run(output):
    return hv.house_summaries(items, output)

# clean — both items accepted
clean = json.dumps([
    {"id": "aaa111", "summary": GOOD, "tags": ["models & research"]},
    {"id": "bbb222", "summary": MEDIA, "tags": ["engineering leadership"]}])
s, t, c, rej = run(clean)
chk("clean run: both cards accepted", sorted(s), ["aaa111", "bbb222"])
chk("clean run: no rejections", c, {})
chk("clean run: tags survive", t["aaa111"], ["models & research"])

# mixed ladder — one good, one invented number
mixed = json.dumps([
    {"id": "aaa111", "summary": GOOD, "tags": []},
    {"id": "bbb222", "summary": MEDIA.replace("A podcast panel", "A 12-part podcast panel"),
     "tags": []}])
s, t, c, rej = run(mixed)
chk("mixed run: only the sound card survives", list(s), ["aaa111"])
chk("mixed run: the reason is recorded", c, {"unsourced_number": 1})
# A count alone is unactionable. "copied=1" reads identically whether the model
# lifted a paragraph or the rule has started over-firing on ordinary prose, and
# only one of those wants fixing.
chk("mixed run: the rejected text is carried, not just the count",
    rej, [("unsourced_number", MEDIA.replace("A podcast panel", "A 12-part podcast panel"))])

# omission — the prompt explicitly permits it, so it must be counted, not inferred
s, t, c, rej = run(json.dumps([{"id": "aaa111", "summary": GOOD, "tags": []}]))
chk("omitted items are counted", c.get("omitted"), 1)
chk("...and the omitted card simply is not there", list(s), ["aaa111"])

# refusal / total garbage — the edition still has to survive this
s, t, c, rej = run("I cannot help with that request.")
chk("a refusal costs every card its top rung and nothing else", s, {})
chk("...and build_edition still produces a full edition from it",
    fe.build_edition([{"id": "aaa111", "url": "https://a.com/1", "title": "T1",
                       "source": "S1", "summary": "A publisher summary long enough "
                       "to carry the card on its own without any help."}],
                     __import__("datetime").date(2026, 8, 9), house=s)["rungs"],
    {"house": 0, "publisher": 1, "title": 0, "drop": 0})

# adversarial — a hallucinated id, an invented tag, and a non-object
adversarial = json.dumps([
    {"id": "zzz999", "summary": GOOD, "tags": []},
    {"id": "aaa111", "summary": GOOD, "tags": ["models & research", "crypto", "web3"]},
    "just a string"])
s, t, c, rej = run(adversarial)
chk("a hallucinated id is rejected, not written into the edition", "zzz999" in s, False)
chk("...and counted", c.get("unknown_id"), 1)
chk("an invented tag is dropped and the real one kept", t["aaa111"], ["models & research"])
chk("a non-object in the array does not raise", "aaa111" in s, True)


print("── S8.8 the paired metrics ───────────────────────────────────────────────")
# The cheapest way to satisfy "no fact absent from the source" is to write no
# facts. That summary passes every rule above and is worth nothing, so
# specificity is reported from the first run, before anyone tunes the prompt.
s, _, _, _ = run(clean)
m = hv.metrics(s, items)
chk("metrics count the cards", m["cards"], 2)
chk("number retention is reported", m["number_rate"], 1.0)
chk("name retention is reported", m["name_rate"], 1.0)

VAGUE = ("The piece discusses recent developments and considers what they might "
         "mean for teams working in this space over the period ahead. It sets out "
         "the background and weighs up where things may go from here.")
s2, _, c2, _ = run(json.dumps([{"id": "aaa111", "summary": VAGUE, "tags": []}]))
chk("the evasive summary passes every hard rule", list(s2), ["aaa111"])
chk("...and the metric is what catches it", hv.metrics(s2, items)["number_rate"], 0.0)
chk("...on names too", hv.metrics(s2, items)["name_rate"], 0.0)
chk("a source with no numbers reports None, not a false regression",
    hv.metrics({"bbb222": MEDIA}, items)["number_rate"], None)

print("── the wiring: _house_pass cannot cost a night ───────────────────────────")
# Everything below is stubbed — no network, no model, no spend. What is under
# test is the wrapper, not the rules: whatever goes wrong inside it, the caller
# gets a dict it can build an edition from.
WROWS = [{"id": "aaa111", "url": "https://a.com/1", "title": items[0]["title"],
          "source": "The Register", "summary": "A cheaper tier arrives for developers."}]

def fetch_ok(url):
    return (items[0]["text"], "article", "ok")

def runner_ok(prompt):
    return json.dumps([{"id": "aaa111", "summary": GOOD, "tags": ["models & research"]}]), "ok"

h, t, notes = fe._house_pass(WROWS, None, runner=runner_ok, fetcher=fetch_ok)
chk("a clean pass returns the summary", list(h), ["aaa111"])
chk("...and the tags", t["aaa111"], ["models & research"])
chk("...and reports specificity every run, not on request",
    any("specificity" in n for n in notes), True)
chk("...and the edition lands on rung 1",
    fe.build_edition(WROWS, __import__("datetime").date(2026, 8, 9),
                     house=h, tags=t)["rungs"]["house"], 1)

for label, kw in [
    ("the fetch raises", {"fetcher": lambda u: (_ for _ in ()).throw(RuntimeError("boom")),
                          "runner": runner_ok}),
    ("the model raises", {"fetcher": fetch_ok,
                          "runner": lambda p: (_ for _ in ()).throw(RuntimeError("boom"))}),
    ("the model refuses", {"fetcher": fetch_ok, "runner": lambda p: ("I cannot help", "ok")}),
    ("the model returns nothing", {"fetcher": fetch_ok, "runner": lambda p: ("", "timed out")}),
    ("nothing fetches", {"fetcher": lambda u: ("", "", "too_thin"), "runner": runner_ok}),
]:
    h2, t2, n2 = fe._house_pass(WROWS, None, **kw)
    if h2 != {} or t2 != {} or not n2:
        bad(f"{label}: expected an empty result and a logged note, got {h2!r} / {n2!r}")
        break
else:
    ok("every failure path returns empty and says so, rather than raising")

# The point of all of it: a failed house pass is last night's product, not a
# broken one.
h3, t3, _ = fe._house_pass(WROWS, None, fetcher=fetch_ok, runner=lambda p: ("", "timed out"))
chk("a failed house pass still yields a full edition at rung 2",
    fe.build_edition(WROWS + [{"id": "b", "url": "https://b.com/2", "title": "T",
                               "source": "S", "summary": "Another publisher summary, "
                               "long enough to carry its own card here."}],
                     __import__("datetime").date(2026, 8, 9), house=h3)["rungs"],
    {"house": 0, "publisher": 1, "title": 1, "drop": 0})

print()
if FAIL == 0:
    print(f"\033[32mPASS\033[0m ({COUNT}) — house voice tests passed")
else:
    print(f"\033[31mFAIL\033[0m — house voice tests FAILED ({COUNT} assertions run)")
sys.exit(FAIL)
PY
