#!/bin/bash
# The relevance pass — Reconciliation 6's middle third.
#
# The property this suite exists to hold is not "the judge picks well" — nothing
# offline can test that. It is the one underneath:
#
#   `unjudged` is false if and only if a model actually judged.
#
# Both feeds filter on that flag and the page renders a banner off it, and a
# feed item cannot be recalled once delivered. A flag that drifts loose from the
# thing it describes either puts unvetted content permanently into subscribers'
# readers or hides every real edition from all of them.
#
# So the flag is asserted through `feed_edition._main` itself, with a stubbed
# model, across every branch that can set it. Asserting it on the parser alone
# would leave the wiring — which is where it is actually decided — untested.
#
# The second property is degradation: a model that refuses, times out, returns
# garbage or is not installed must cost the day its curation and never its
# publish.
#
# No network, no LLM, no writes outside $TMPDIR, no git writes anywhere.
#
#   bash scripts/tests/test-feed-judge.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PYBIN="$REPO_DIR/scripts/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3)"

# NO TEST IN THIS FILE MAY REACH A REAL MODEL. Most stub call_model outright,
# but one case exercises house_call's own missing-binary path and therefore runs
# the real function. find_claude honours this variable over PATH, so pointing it
# at nothing makes that case fail instantly instead of discovering the installed
# CLI and spending money on a live call with a 300-second timeout. Set for the
# whole suite rather than around that one case, because the next person to add a
# test here should not have to know this.
export KICKOFF_CLAUDE_BIN=/nonexistent/claude

if ! "$PYBIN" -c 'import yaml' 2>/dev/null; then
  printf "  \033[33mskip\033[0m  pyyaml unavailable in %s — run any kickoff command once\n" "$PYBIN"
  exit 0
fi

"$PYBIN" - "$REPO_DIR" <<'PY'
import sys, json, io, tempfile, contextlib
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "scripts" / "lib"))
import feed_judge as fj
import feed_select as fs
import feed_edition as fe
import house_call

FAIL = 0
COUNT = 0
def ok(m):
    global COUNT; COUNT += 1; print(f"  \033[32mok\033[0m    {m}")
def bad(m):
    global FAIL, COUNT; COUNT += 1; FAIL = 1; print(f"  \033[31mFAIL\033[0m  {m}")
def chk(label, got, want):
    ok(label) if got == want else bad(f"{label} (got {got!r}, wanted {want!r})")

ID = lambda c: c * 12
def row(c, source="Source A", title="A headline about a release"):
    return {"id": ID(c), "title": title, "source": source,
            "url": f"https://{source.replace(' ','').lower()}.example/{c}",
            # Sized off the real constant, not off a number that looked long
            # enough: the substance gate moved to 120 once and would silently
            # turn every case below into an empty-pool test if it moved again.
            "summary": "A publisher blurb. " + "Long enough to clear the substance gate. "
                       * (1 + fs.MIN_SUMMARY_SELECT // 40),
            "first_seen": "2026-08-09", "date": "2026-08-09"}

ROWS = [row("a"), row("b", "Source B"), row("c", "Source C")]
reply = lambda text, note="ok": (lambda prompt: (text, note))

print("── the prompt, this module and feed_select must agree ────────────────────")

try:
    fj.assert_prompt_contract()
    ok("the real prompt satisfies its contract")
except AssertionError as exc:
    bad(f"the real prompt fails its own contract: {exc}")

real = fj.PROMPT_PATH.read_text(encoding="utf-8")
for label, mutated in [
    ("a renamed {{ITEMS}} placeholder is caught", real.replace("{{ITEMS}}", "{{CARDS}}")),
    ("a prompt that stops asking for JSON is caught", real.replace("JSON array", "list")),
    ("a cap that drifts from the code is caught", real.replace("at most 7", "at most 10")),
    # `\**` is optional on both sides, so a naive pattern matches the 7 inside
    # 70 and blesses a prompt asking for ten times the ceiling.
    ("a cap of 70 does not satisfy a cap of 7", real.replace("at most 7", "at most 70")),
]:
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "feed-relevance.md"
        p.write_text(mutated, encoding="utf-8")
        saved, fj.PROMPT_PATH = fj.PROMPT_PATH, p
        try:
            fj.assert_prompt_contract(); bad(label)
        except AssertionError:
            ok(label)
        finally:
            fj.PROMPT_PATH = saved

# The constant is restated from feed_select and the docstring claims it is
# asserted. This is that assertion.
saved_cap, fs.DAILY_CAP = fs.DAILY_CAP, 5
try:
    fj.assert_prompt_contract(); bad("CAP drifting from feed_select.DAILY_CAP is caught")
except AssertionError:
    ok("CAP drifting from feed_select.DAILY_CAP is caught")
finally:
    fs.DAILY_CAP = saved_cap

prompt = fj.assemble_prompt(ROWS)
chk("every item reaches the prompt", all(ID(c) in prompt for c in "abc"), True)
chk("no placeholder survives assembly", "{{ITEMS}}" in prompt, False)
chk("urls are not shown to the judge", "https://" in fj.render_items(ROWS), False)
chk("an empty publisher summary omits the label",
    "PUBLISHER SUMMARY" in fj.render_items([{"id": ID("a"), "title": "T",
                                             "source": "S", "summary": ""}]), False)

print("── an array inside an object is only an answer if the key says so ────────")

# THE MOST DANGEROUS INPUT THIS MODULE CAN RECEIVE. A model showing its working
# publishes the items it threw out, as its curated selection, with every id real
# so the veto passes all of them.
#
# Both shapes it arrives in, and they resolve differently on purpose. With a
# `selected` key the model HAS answered — it selected nothing — so this is an
# understood, empty verdict and an honest empty day. With only a `rejected` key
# there is no answer present at all, and reading the rejects would be the
# catastrophe. Neither may ever return the rejected ids.
chk("rejects alongside an empty selection are an empty verdict, not a selection",
    fj.parse_verdict('{"rejected":["aaaaaaaaaaaa","bbbbbbbbbbbb"],"selected":[]}'),
    ([], True))
chk("a bare rejected-items list is not a verdict at all",
    fj.parse_verdict('{"rejected":["aaaaaaaaaaaa","bbbbbbbbbbbb"]}'), ([], False))
chk("...nor when it arrives inside a fence",
    fj.parse_verdict('```json\n{"rejected":["aaaaaaaaaaaa"]}\n```'), ([], False))
chk("...nor with any other unaffirmative key",
    fj.parse_verdict('{"excluded":["aaaaaaaaaaaa"]}'), ([], False))
chk("an affirmative key IS read",
    fj.parse_verdict('{"selected":["aaaaaaaaaaaa"]}'), ([ID("a")], True))
chk("...and so is `ids`", fj.parse_ids('{"ids":["aaaaaaaaaaaa"]}'), [ID("a")])

print("── parsing whatever the model actually printed ───────────────────────────")

chk("a bare array", fj.parse_ids('["aaaaaaaaaaaa"]'), [ID("a")])
chk("a fenced array", fj.parse_ids('```json\n["aaaaaaaaaaaa"]\n```'), [ID("a")])
chk("an UPPERCASE fence", fj.parse_ids('```JSON\n["aaaaaaaaaaaa"]\n```'), [ID("a")])
chk("a line of preamble", fj.parse_ids('Here you go:\n["aaaaaaaaaaaa"]'), [ID("a")])
chk("objects carrying an id", fj.parse_ids('[{"id":"aaaaaaaaaaaa"}]'), [ID("a")])
chk("order is preserved — it is the model's ranking",
    fj.parse_ids('["cccccccccccc","aaaaaaaaaaaa","bbbbbbbbbbbb"]'), [ID("c"), ID("a"), ID("b")])
chk("a malformed id is dropped, the good ones kept",
    fj.parse_ids('["not-an-id","aaaaaaaaaaaa","AAAAAAAAAAAA",""]'), [ID("a")])
chk("prose instead of json", fj.parse_ids("I can't help with that."), [])
chk("an empty string", fj.parse_ids(""), [])

# A model that restates the format before answering. Taking only the FIRST
# array loses the real verdict to the example.
chk("an example array before the real one does not win",
    fj.parse_ids('Format:\n```\n["<id>"]\n```\nAnswer:\n["aaaaaaaaaaaa"]'), [ID("a")])
# Without string-awareness the scan closes on the ] inside the quoted value and
# the whole array fails to parse.
chk("a ] inside a string does not truncate the array",
    fj.parse_ids('Answer: ["aaaaaaaaaaaa", "b]d"]'), [ID("a")])

print("── an empty verdict is NOT the same as a failure ─────────────────────────")

# The distinction is the whole reason parse_verdict returns two values.
# Collapsing it either publishes nothing on a model outage, or marks a garbled
# night judged.
chk("a deliberate [] is an empty verdict", fj.judge(ROWS, reply("[]"))[1], "empty")
chk("...fenced", fj.judge(ROWS, reply("```json\n[]\n```"))[1], "empty")
chk("...wrapped in prose", fj.judge(ROWS, reply("None of these earned a slot.\n[]"))[1], "empty")
chk("...as an affirmative key", fj.judge(ROWS, reply('{"selected":[]}'))[1], "empty")
chk("a refusal is not an empty verdict",
    fj.judge(ROWS, reply("", "claude exited 1"))[1], "claude exited 1")
chk("a timeout is not an empty verdict",
    fj.judge(ROWS, reply("", "timed out after 300s"))[1], "timed out after 300s")
chk("prose that parsed to nothing is not an empty verdict",
    fj.judge(ROWS, reply("I picked none of them."))[1], "no usable ids in the model output")

# house_call hands back stdout even on a non-zero exit, because a partial stream
# can still hold usable summaries. That trade is wrong here: a refusal whose
# text happens to contain an array would publish as a curated selection.
chk("ids inside a non-ok runner note are refused",
    fj.judge(ROWS, reply('I will not do that. ["aaaaaaaaaaaa"]', "claude exited 1")),
    ([], "claude exited 1"))

print("── it never raises ───────────────────────────────────────────────────────")

def boom(prompt):
    raise RuntimeError("the subprocess layer exploded")
ids, note = fj.judge(ROWS, boom)
chk("a runner that raises returns instead", ids, [])
chk("...and the note names the exception", note.startswith("RuntimeError:"), True)
chk("no rows at all is handled", fj.judge([], reply('["aaaaaaaaaaaa"]')), ([], "nothing to judge"))

print("── unjudged, asserted through the real CLI ───────────────────────────────")

# A synthetic pool rather than the committed one: the real pool ages out under
# the 14-day staleness bound, and a suite that starts skipping in a fortnight is
# a suite nobody notices has stopped.
#
# Ten items across five sources, two each, and the size is load-bearing. With
# fewer than `cap` eligible items every thin day is a POOL-thin day —
# thin_reason reports the first stage that bound the count, so a five-item pool
# makes the veto invisible no matter what the veto does. `a` and `d` share a
# source so the strict per-source cap has something to bite on.
POOL = [row("a"), row("d", "Source A"),
        row("b", "Source B"), row("2", "Source B"),
        row("c", "Source C"), row("3", "Source C"),
        row("e", "Source D"), row("f", "Source D"),
        row("0", "Source E"), row("1", "Source E")]

def drive(*args, model_reply=None, model_note="ok"):
    """Run feed_edition._main with a stubbed model. Returns the edition dict."""
    saved = house_call.call_model
    if model_reply is not None:
        house_call.call_model = lambda p, m=None, timeout=None: (model_reply, model_note)
    try:
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "pool.jsonl").write_text("\n".join(json.dumps(r) for r in POOL) + "\n")
            (d / "ledger.jsonl").write_text("")
            (d / "cfg.yaml").write_text(
                "sources:\n  tier1:\n    - name: Source A\n    - name: Source B\n"
                "  tier2:\n    - name: Source C\n    - name: Source D\n"
                "    - name: Source E\n")
            out = d / "edition.json"
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
                rc = fe._main(["--state", str(d), "--config", str(d / "cfg.yaml"),
                               "--date", "2026-08-09", "--out", str(out), *args])
            return json.loads(out.read_text()), rc, buf.getvalue()
    finally:
        house_call.call_model = saved

ed, rc, _ = drive()
chk("without --judge the edition is unjudged", ed["unjudged"], True)
chk("...and still publishes the ranked top", ed["count"] > 0, True)
chk("...and exits clean", rc, 0)

ed, _, log = drive("--judge", model_reply='["cccccccccccc","bbbbbbbbbbbb"]')
chk("a real verdict clears unjudged", ed["unjudged"], False)
chk("...and publishes exactly what the model chose, in its order",
    [i["id"] for i in ed["items"]], [ID("c"), ID("b")])

# Kills the mutation `veto(...)` -> `diversify(...)`: diversify would return the
# top of the shortlist, ignoring both the model's order and its choices.
ed, _, log = drive("--judge", model_reply='["aaaaaaaaaaaa","dddddddddddd","bbbbbbbbbbbb"]')
chk("the veto cuts a second item from one source", [i["id"] for i in ed["items"]],
    [ID("a"), ID("b")])
chk("...and the day is labelled as vetoed", ed["reason"], "vetoed_thin")
chk("...and it is still judged", ed["unjudged"], False)

ed, _, log = drive("--judge", model_reply="[]")
chk("an empty verdict is judged", ed["unjudged"], False)
chk("...and publishes an empty day", ed["count"], 0)

# ID_RE proves an id is well SHAPED and nothing more. A model that mangles a hex
# character per id returns a plausible set that exists nowhere.
ed, _, log = drive("--judge", model_reply='["0123456789ab","fedcba987654"]')
chk("a fully hallucinated set is NOT judged", ed["unjudged"], True)
chk("...and falls back to the ranked top rather than publishing nothing",
    ed["count"] > 0, True)
chk("...and says so in the log", "all 2 returned id(s) were vetoed" in log, True)

for label, kwargs in [
    ("a refusal", dict(model_reply="", model_note="claude exited 1")),
    ("a timeout", dict(model_reply="", model_note="timed out after 300s")),
    ("garbage", dict(model_reply="I cannot help with that.")),
    ("a rejected-items object", dict(model_reply='{"rejected":["aaaaaaaaaaaa"]}')),
]:
    ed, _, _ = drive("--judge", **kwargs)
    chk(f"{label} leaves the edition unjudged", ed["unjudged"], True)
    chk(f"...and {label} still publishes the night", ed["count"] > 0, True)

# The one that would be silent: no model binary at all. Deliberately NOT
# stubbed — the thing under test is house_call's own error path, not a stub's.
# Safe because the suite exports KICKOFF_CLAUDE_BIN at nothing; see the note at
# the top of this file.
import os
assert os.environ.get("KICKOFF_CLAUDE_BIN") == "/nonexistent/claude", \
    "the no-CLI case would make a real, billable model call"
ed, _, log = drive("--judge")
chk("a missing model CLI leaves the edition unjudged", ed["unjudged"], True)
chk("...and still publishes the night", ed["count"] > 0, True)

print("── the thin-day vocabulary the veto unlocks ──────────────────────────────")

stats = {"eligible": 20, "chosen": 20, "pool": 40}
chk("a vetoed-down day names the veto",
    fs.thin_reason(2, stats, dropped={"source_capped": [ID("d")]}, cap=7), "vetoed_thin")
chk("a day the model simply cut short names the model",
    fs.thin_reason(2, stats, dropped={"source_capped": []}, cap=7), "model_thin")
chk("a full day is still full",
    fs.thin_reason(7, stats, dropped={"source_capped": [ID("d")]}, cap=7), "full")

print()
if FAIL == 0:
    print(f"\033[32mPASS\033[0m ({COUNT}) — relevance pass tests passed")
else:
    print(f"\033[31mFAIL\033[0m — relevance pass tests FAILED ({COUNT} assertions run)")
sys.exit(FAIL)
PY
