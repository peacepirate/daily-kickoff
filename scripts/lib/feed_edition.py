"""One day's edition — the card fallback ladder, and the published shape.

S8.2 (the content schema) and S8.5's ladder. The model half is not here: this
module turns a selected set of pool rows into the exact object the site renders,
and it does so whether or not a house voice ever ran.

**The ladder is per item, never per day.** One summary that fails costs one
card, not the edition. A day-level ladder is the design where a single bad
generation silently downgrades six good cards, and it is the reason this is a
function over items rather than a flag on the edition.

    rung 1  house     a generated summary that passed its quality bar
    rung 2  publisher the publisher's own summary, sanitised
    rung 3  title     the headline alone, honest and deliberately rare
    rung 4  drop      nothing usable — the item does not appear

Rung 1 does not exist until E8. Everything here already works without it, which
is the point: the house voice is an upgrade to card *text*, not a precondition
for having a feed.

Pure stdlib. No clock — `today` is passed in — and no I/O beyond the CLI.
"""
from __future__ import annotations

from datetime import date as Date
from pathlib import Path

try:                                    # normal: scripts/lib is on the path
    from bundle import is_safe_url
except ImportError:                     # imported with only the repo root there
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from bundle import is_safe_url

# The card body has to stand alone next to a headline. Below this a "summary"
# is a fragment, and rung 3 is the more honest answer than a half sentence.
MIN_CARD_SUMMARY = 60

# Rung 3 is honest but must stay rare: a page of bare headlines is a link list,
# which is the product this one exists not to be. Past this many in one edition
# the extras are dropped rather than shown — a cap that CAN bind, unlike the one
# E6 deliberately did not build.
MAX_TITLE_ONLY = 2

# The six fixed tags. A closed vocabulary, so a model that invents a seventh has
# it dropped rather than silently establishing a new one.
TAGS = ("agentic coding", "engineering leadership", "enterprise & governance",
        "models & research", "developer experience", "robotics")

RUNGS = ("house", "publisher", "title", "drop")


def card_rung(row: dict, house: str | None = None,
              min_summary: int = MIN_CARD_SUMMARY) -> tuple[str, str]:
    """Which rung this item lands on, and the body text for it.

    Returns (rung, body). `body` is "" for the title and drop rungs — the
    headline is already on the card, so rung 3 adds no body rather than
    repeating itself.

    A card IS a link, so an unusable url costs the card outright — before the
    ladder, not at the bottom of it. Rung 1 with a `javascript:` href is not a
    better outcome than rung 4; it is the worst outcome there is. This is the
    last gate before the published shape, and it is checked here rather than
    trusted from admission because a pool row can be edited by hand.
    """
    if not is_safe_url(row.get("url")):
        return "drop", ""
    if house and len(house.strip()) >= min_summary:
        return "house", house.strip()
    publisher = (row.get("summary") or "").strip()
    if len(publisher) >= min_summary:
        return "publisher", publisher
    if (row.get("title") or "").strip() and (row.get("url") or "").strip():
        return "title", ""
    return "drop", ""


def build_edition(rows: list[dict], today: Date,
                  house: dict[str, str] | None = None,
                  tags: dict[str, list[str]] | None = None,
                  reason: str = "full",
                  max_title_only: int = MAX_TITLE_ONLY) -> dict:
    """The object the site renders, from selected pool rows.

    `house` and `tags` are keyed by item id and may be empty — that is the
    pre-E8 path and it produces a complete edition, not a degraded one.

    Rung counts are carried on the edition. They are the cheapest available
    signal that the house voice has quietly stopped working: a run of editions
    at rung 2 looks perfectly fine on the page and means the generation failed
    every time.
    """
    house = house or {}
    tags = tags or {}
    items: list[dict] = []
    counts = {r: 0 for r in RUNGS}
    title_only = 0

    for row in rows:
        rid = row.get("id", "")
        rung, body = card_rung(row, house.get(rid))
        if rung == "title":
            if title_only >= max_title_only:
                counts["drop"] += 1
                continue
            title_only += 1
        if rung == "drop":
            counts["drop"] += 1
            continue
        counts[rung] += 1
        items.append({
            "id": rid,
            "title": (row.get("title") or "").strip(),
            "url": (row.get("url") or "").strip(),
            "source": row.get("source", ""),
            "summary": body,
            "rung": rung,
            # Unknown tags are dropped, not passed through. A closed vocabulary
            # that accepts anything is not closed.
            "tags": [t for t in tags.get(rid, []) if t in TAGS],
        })

    return {
        "date": today.isoformat(),
        "count": len(items),
        "reason": reason,
        "rungs": counts,
        "items": items,
    }


# ── CLI ──────────────────────────────────────────────────────────────────────
#
# Builds an edition straight from the pool, taking the top of the ranked
# shortlist. That is NOT the product: relevance is the model's job and this
# takes the first N by tier and freshness instead. It exists so the site can be
# built and read before E8 lands, and it prints that caveat rather than letting
# a preview be mistaken for a judged edition.

def _house_pass(rows: list[dict], model: str | None,
                runner=None, fetcher=None) -> tuple[dict, dict, list[str]]:
    """Fetch, generate, validate — E8's whole loop, wrapped so it cannot cost a night.

    Returns (summaries by id, tags by id, lines to log). `runner` and `fetcher`
    are injected by the test suite; nothing here touches the network when they
    are supplied.

    The entire body is inside one try. Every step of it is optional by design:
    the edition this returns nothing for is the edition the feed published every
    night before E8 existed, at the publisher's own words. An exception escaping
    here would instead cost the whole run, which is a strictly worse trade than
    the thing it is protecting.
    """
    try:
        import article_fetch
        import house_voice
        import house_call

        house_voice.assert_tag_vocabularies_agree()
        fetch = fetcher or (lambda u: article_fetch.fetch_article(u))
        fetched = {}
        kinds: dict[str, int] = {}
        for row in rows:
            url = (row.get("url") or "").strip()
            text, kind, reason = fetch(url)
            fetched[url] = (text, kind, reason)
            key = kind if reason == "ok" else reason
            kinds[key] = kinds.get(key, 0) + 1

        items = house_voice.build_input(rows, fetched)
        lines = [f"house: fetched {len(rows)} url(s) — "
                 f"{', '.join(f'{k}={v}' for k, v in sorted(kinds.items()))}"]
        if not items:
            lines.append("house: nothing fetched cleanly — every card falls to the "
                         "publisher's own summary.")
            return {}, {}, lines

        prompt = house_voice.assemble_prompt(items)
        call = runner or (lambda p: house_call.call_model(
            p, model or house_call.DEFAULT_MODEL))
        output, note = call(prompt)
        if note != "ok":
            lines.append(f"house: model call — {note}")

        summaries, tags, counts, rejects = house_voice.house_summaries(items, output)
        lines.append(f"house: {len(summaries)}/{len(items)} summary(ies) accepted"
                     + (f" — rejected: {', '.join(f'{k}={v}' for k, v in sorted(counts.items()))}"
                        if counts else ""))
        # The text, not only the reason. A genuine lift and a rule that has begun
        # over-firing produce the identical count line, and only one of them
        # wants fixing — this is the difference between the two.
        for reason, text in rejects:
            lines.append(f"house: rejected ({reason}) {text[:160]!r}")
        # Reported every run, not on request. The cheapest way to satisfy "no
        # fact absent from the source" is to write no facts, and a card with no
        # figures and no names passes every hard rule while being worth nothing.
        # Nothing in the loop can catch that — the model is single-shot with no
        # retry — so the number has to be in front of whoever next edits the
        # prompt. See S8.8.
        m = house_voice.metrics(summaries, items)
        lines.append(f"house: specificity — numbers {m['number_rate']} "
                     f"(of {m['number_eligible']}), names {m['name_rate']} "
                     f"(of {m['name_eligible']}), mean {m['mean_length']} chars")
        return summaries, tags, lines
    except Exception as exc:                            # noqa: BLE001
        return {}, {}, [f"house: skipped ({type(exc).__name__}: {exc}) — "
                        "publishing at the publisher's own words."]


def _main(argv=None):
    import argparse, json, sys
    from feed_pool import read_jsonl, ledger_ids
    from feed_select import shortlist, source_tiers, thin_reason, DAILY_CAP

    ap = argparse.ArgumentParser(description="Build one day's edition")
    ap.add_argument("--state", required=True)
    ap.add_argument("--config", required=True)
    ap.add_argument("--date", required=True)
    ap.add_argument("--out", help="Write JSON here (default: stdout)")
    ap.add_argument("--cap", type=int, default=DAILY_CAP)
    # Off by default, and network is the whole reason. Every other path in this
    # module is offline and reproducible; turning that off silently would make a
    # replay depend on what the internet was doing at the time. The nightly job
    # passes it explicitly when E8 wires publication — see the fail-open
    # argument at the top of scripts/lib/link_check.py.
    ap.add_argument("--check-links", action="store_true",
                    help="HEAD the selected urls and drop only proven-dead ones (network)")
    # Also off by default, and for a second reason on top of the network: this is
    # the only flag in the pipeline that spends money. It has to be asked for.
    ap.add_argument("--house", action="store_true",
                    help="Fetch the chosen articles and write house summaries (network, model)")
    # Off by default for the same two reasons as --house: network, and money.
    # Unlike --house it also changes *which* items publish, so it is the one
    # flag whose absence is visible to the reader — the page says Preview and
    # the feeds carry nothing.
    ap.add_argument("--judge", action="store_true",
                    help="Have the model choose which shortlisted items run (network, model)")
    ap.add_argument("--model", default=None, help="Model for --judge and --house")
    a = ap.parse_args(argv)

    state = Path(a.state)
    today = Date.fromisoformat(a.date)
    sel = shortlist(read_jsonl(state / "pool.jsonl"),
                    ledger_ids(read_jsonl(state / "ledger.jsonl")),
                    today, source_tiers(a.config))

    from feed_select import diversify, veto, FINAL_PER_SOURCE, FINAL_PER_DOMAIN

    # THE RELEVANCE PASS — Reconciliation 6's middle third.
    #
    # Without it, `chosen` is the top of code's ranking, which knows about
    # freshness, source tier and concentration and nothing whatever about
    # whether a story matters. That is an honest shortlist and a poor edition,
    # which is precisely what `unjudged: true` told the reader, and why both
    # feeds filtered it out.
    #
    # Three outcomes, and the difference between the second and third is the
    # whole reason `judge` returns a note rather than just a list:
    #
    #   ids returned   the model chose. veto() cuts anything ineligible, order
    #                  preserved, and the edition is judged.
    #   "empty"        the model read them and said none earned a slot. That is
    #                  a real verdict and a real empty day — the product's whole
    #                  claim is that the count follows what was published. It is
    #                  JUDGED, and it publishes empty.
    #   anything else  refusal, timeout, garbage, no CLI. Fall back to code's
    #                  ranking and stay unjudged. The night still publishes; it
    #                  publishes the pre-E8 product and says so on the page.
    #
    # That last branch is the refusal-degradation property the plan calls its
    # most consequential structural choice. A model outage costs the day its
    # curation and its place in the feed, never its publish.
    judged, vetoed = False, None
    if a.judge:
        # Imports inside the guard, matching _house_pass. An ImportError or a
        # syntax error in feed_judge must cost the day its curation, not the
        # night its publish.
        try:
            import feed_judge
            import house_call
            feed_judge.assert_prompt_contract()
            ids, judge_note = feed_judge.judge(
                sel["shortlist"],
                lambda p: house_call.call_model(p, a.model or house_call.DEFAULT_MODEL))
        except Exception as exc:                            # noqa: BLE001
            ids, judge_note = [], f"{type(exc).__name__}: {exc}"

        kept, dropped = ([], None)
        if ids:
            kept, dropped = veto(ids, sel["shortlist"], a.cap,
                                 FINAL_PER_SOURCE, FINAL_PER_DOMAIN)

        if kept:
            chosen, vetoed, judged = kept, dropped, True
            lost = {k: len(v) for k, v in dropped.items() if v}
            print(f"judge: {len(ids)} returned, {len(chosen)} kept"
                  + (f" — vetoed: {', '.join(f'{k}={v}' for k, v in sorted(lost.items()))}"
                     if lost else ""), file=sys.stderr)
        elif ids:
            # Every id the model returned was ineligible. Not a thin day — a
            # verdict about items that are not on offer, which is what a
            # hallucinated set looks like: `ID_RE` proves an id is well shaped
            # and nothing more. Treated as no verdict rather than as an empty
            # one, because "the model chose nothing" and "nothing the model
            # chose exists" are different facts and only one of them should
            # reach a subscriber marked judged.
            chosen, _ = diversify(sel["shortlist"], a.cap,
                                  FINAL_PER_SOURCE, FINAL_PER_DOMAIN)
            print(f"judge: all {len(ids)} returned id(s) were vetoed — none was on "
                  f"the shortlist or all breached the caps. Treating as no verdict "
                  f"and publishing the top of the ranked shortlist, unjudged.",
                  file=sys.stderr)
        elif judge_note == "empty":
            chosen, judged = [], True
            print("judge: the model read the shortlist and chose nothing. "
                  "Publishing an empty day.", file=sys.stderr)
        else:
            chosen, _ = diversify(sel["shortlist"], a.cap,
                                  FINAL_PER_SOURCE, FINAL_PER_DOMAIN)
            print(f"judge: skipped ({judge_note}) — publishing the top of the "
                  f"ranked shortlist, unjudged.", file=sys.stderr)
    else:
        chosen, _ = diversify(sel["shortlist"], a.cap,
                              FINAL_PER_SOURCE, FINAL_PER_DOMAIN)

    if a.check_links:
        # Wrapped whole. A link checker that can raise is a link checker that
        # can cost a night's publish, which is a worse outcome than the dead
        # link it exists to catch.
        try:
            import link_check
            verdicts = link_check.check_urls([r.get("url", "") for r in chosen],
                                             client=link_check.httpx_client())
            for line in link_check.report_lines(verdicts):
                print(line, file=sys.stderr)
            chosen, dropped, note = link_check.filter_dead(chosen, verdicts)
            if note == "inconclusive":
                print("NOTE: every selected link looked dead — not believed, nothing dropped.",
                      file=sys.stderr)
            for row in dropped:
                print(f"dropped (dead link): {row.get('url','')}", file=sys.stderr)
        except Exception as exc:
            print(f"NOTE: link check skipped ({type(exc).__name__}: {exc}) — publishing anyway.",
                  file=sys.stderr)

    house, tags, notes = ({}, {}, [])
    if a.house:
        house, tags, notes = _house_pass(chosen, a.model)
        for line in notes:
            print(line, file=sys.stderr)

    edition = build_edition(chosen, today, house=house, tags=tags,
                            reason=thin_reason(len(chosen), sel["stats"],
                                               dropped=vetoed, cap=a.cap))

    # The site renders the Preview banner off this and both feeds filter on it,
    # so it is the one field here that decides what reaches a subscriber — and a
    # feed item cannot be recalled. It answers exactly one question: did a model
    # judge these.
    #
    # What is deliberately NOT allowed to clear it: --house succeeding. A model
    # writing seven summaries has read seven articles and chosen nothing, and
    # the banner's own words — "the top of a ranked shortlist, not a chosen
    # seven" — would still be true. Conflating writing with judging is the cheap
    # way to empty this flag of meaning.
    edition["unjudged"] = not judged

    text = json.dumps(edition, ensure_ascii=False, indent=2, sort_keys=True)
    if a.out:
        Path(a.out).parent.mkdir(parents=True, exist_ok=True)
        Path(a.out).write_text(text + "\n")
        print(f"{a.date}: {edition['count']} card(s) "
              f"({', '.join(f'{k}={v}' for k, v in edition['rungs'].items() if v)}) -> {a.out}")
        # The operator's copy of what the reader will be told, read off the same
        # flag the page reads rather than off an assumption about which pass ran.
        if edition["unjudged"]:
            print("NOTE: no model has judged relevance — these are the top of the ranked "
                  "shortlist, not a curated seven. The page shows a Preview banner and "
                  "the feeds will not carry this edition.")
        else:
            print(f"judged: a model chose these {edition['count']} from "
                  f"{len(sel['shortlist'])} shortlisted. No Preview banner; the feeds "
                  f"will carry it once it is reviewed.")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    raise SystemExit(_main())
