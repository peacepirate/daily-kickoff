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
    """
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

def _main(argv=None):
    import argparse, json
    from pathlib import Path
    from feed_pool import read_jsonl, ledger_ids
    from feed_select import shortlist, source_tiers, thin_reason, DAILY_CAP

    ap = argparse.ArgumentParser(description="Build one day's edition")
    ap.add_argument("--state", required=True)
    ap.add_argument("--config", required=True)
    ap.add_argument("--date", required=True)
    ap.add_argument("--out", help="Write JSON here (default: stdout)")
    ap.add_argument("--cap", type=int, default=DAILY_CAP)
    a = ap.parse_args(argv)

    state = Path(a.state)
    today = Date.fromisoformat(a.date)
    sel = shortlist(read_jsonl(state / "pool.jsonl"),
                    ledger_ids(read_jsonl(state / "ledger.jsonl")),
                    today, source_tiers(a.config))

    from feed_select import diversify, FINAL_PER_SOURCE, FINAL_PER_DOMAIN
    chosen, _ = diversify(sel["shortlist"], a.cap, FINAL_PER_SOURCE, FINAL_PER_DOMAIN)
    edition = build_edition(chosen, today,
                            reason=thin_reason(len(chosen), sel["stats"], cap=a.cap))
    edition["unjudged"] = True   # the site renders a banner off this

    text = json.dumps(edition, ensure_ascii=False, indent=2, sort_keys=True)
    if a.out:
        Path(a.out).parent.mkdir(parents=True, exist_ok=True)
        Path(a.out).write_text(text + "\n")
        print(f"{a.date}: {edition['count']} card(s) "
              f"({', '.join(f'{k}={v}' for k, v in edition['rungs'].items() if v)}) -> {a.out}")
        print("NOTE: no model has judged relevance — these are the top of the ranked "
              "shortlist, not a curated seven.")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    raise SystemExit(_main())
