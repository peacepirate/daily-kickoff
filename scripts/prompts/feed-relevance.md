# Public feed — which of these are worth running

Choose which items from the list below should appear on a public link feed
today. You are choosing, not writing: no summaries, no rewriting, no commentary.

Everything you need is in the ITEMS block. Do not fetch anything. Do not use
knowledge you have about these stories from anywhere else.

## Who is reading

Engineering leaders, staff engineers and technical founders, skimming once in
the morning. They are deciding one thing per item: is this worth my click.

Choose what a well-read peer would send them, and nothing else.

## What earns a slot

- A concrete change someone can act on or has to know about: a release, an
  incident, a standard, a measured result, a shift in how teams work.
- Substance over novelty. A careful piece from last week beats an empty one
  from this morning.
- Specifics. A named company, a version, a figure, a real finding.

## What does not

- Marketing dressed as news. Vendor announcements whose only content is that a
  vendor announced something.
- Listicles, roundups, "top ten tools", sponsored content, webinar and
  conference promotion whose substance is that an event exists.
- Opinion with nothing behind it. A take is not a development.
- Anything whose title promises more than the item shows.
- Stories with no bearing on building software or leading people who do.

## Seven is a ceiling, never a target

**Return only the items that genuinely earn a slot.** Returning four is a normal
outcome and costs nothing — the page says plainly when a day is thin, and a
short honest day is the entire product. Padding to reach seven is the one
failure that cannot be recovered from, because a reader who finds one worthless
card stops trusting the other six.

Do not reason backwards from the number. Judge each item on its own, then return
those that passed. If that is two, return two. If it is none, return none.

You may return **at most 7**. There is no minimum.

## Order

Return them **best first** — most worth a reader's attention at the top.

That ordering is yours to make and nothing downstream will second-guess it. The
list you are given is in the order code ranked it, which knows about freshness
and source, and nothing about whether a story matters. Do not preserve that
order out of deference to it.

## Output

Return **only** a JSON array of ID strings. No preamble, no explanation, no
markdown fence around it, nothing after it.

```
["<id copied exactly>", "<id copied exactly>"]
```

Rules for the output:

- Every ID must be copied exactly from an item below. An ID that was not offered
  is discarded, so inventing one only costs a slot.
- No duplicates.
- Best first.
- An empty array `[]` is a valid answer and means nothing today earned a slot.
- Nothing but the array.

---

# ITEMS

{{ITEMS}}
