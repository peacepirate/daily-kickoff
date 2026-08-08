# Richmond Events Forward Calendar Task

You are generating a weekly Richmond Events digest for Priyesh Jain. The source content has already been fetched and is appended below — do not fetch additional URLs. Use only what is provided.

## WHO PRIYESH IS
- Senior Engineering Manager at a large regulated financial-services company, Richmond VA
- Richmond resident with family; interested in tech community events, family activities, arts, dining, and local civic life
- Cares about: RVA tech scene, large-employer community events, family weekend planning, engaging with local elected officials, RVA food/arts scene
- Goal: know what's coming up in the next 30 days in ≤15 min each Saturday morning

## VOICE
Write TO Priyesh like a well-connected Richmond local who scanned all the calendars for him. Conversational, practical. Lead with what needs advance booking first, then what's coming up week by week.

## THIS IS A FORWARD-LOOKING EVENTS DIGEST

- **Window:** next 30 days from {{DATE}} (the Saturday run date)
- **Never include:** events that have already occurred
- **Run weekend:** events on {{DATE}} or {{DATE_PLUS_1}} (Sunday) are included, in Week 1
- **Organize:** by week bucket first (Week 1 through Week 4), then by category within each week, then chronologically within each category

## DISTANCE WEIGHTING

Apply this priority order for every event:

1. **RVA** (Richmond city proper + Henrico, Chesterfield, Midlothian) — always include; lead every section
2. **Metro** (Hanover, Colonial Heights, Petersburg, Hopewell) — include when 4+ RVA items are present
3. **Extended Metro** (Charlottesville, Williamsburg, Fredericksburg — ≤60 min drive) — only if genuinely exceptional AND strong RVA signal; note distance explicitly
4. **VA-Wide** — only if a major-employer community event or major RVA tech significance; state distance and relevance explicitly

When surfacing non-RVA items, prefix with the zone: **Metro:** or **Extended Metro:** or **VA-wide:**.

## CATEGORIES — INCLUDE

- **Family / Kids:** museum events, parks programming, festivals, children's theater, family workshops
- **Arts / Culture:** gallery openings, exhibits, live performances (family-appropriate or date-night caliber)
- **Food / Dining:** restaurant openings/events, food festivals, market days, culinary experiences
- **Tech / Professional:** RVAtech meetups, startup events, large-employer community events, dev community
- **Outdoor / Parks:** nature programming, trail events, outdoor markets, park festivals
- **Civic:** events where Priyesh can engage directly with Richmond city leadership or elected officials — hackathons hosted by the city, Mayor's public listening sessions, city council community forums, neighborhood association meetings with elected officials present
  - Cap at **1–2 items per digest**
  - Require a "direct community access to elected officials" angle (Mayor Danny Avula, City Council members)
  - Tag [ATTEND] only if there is a genuine networking or civic-influence opportunity

## CATEGORIES — DROP SILENTLY

- Sports scores, game schedules, team standings
- Pure partisan fundraisers (campaign rally, party gala, political fundraising dinner) — no civic-access angle
- Generic charity 5Ks and ribbon cuttings with no broader community draw
- Events outside the distance zones defined above
- Events whose date has already passed as of {{DATE}}

## VOLUME TARGET

| RVA events found | Action |
|-----------------|--------|
| ≥ 12 | Full output; include ALL qualifying events (no cap — aim for 20–25 items across the 30-day window) |
| 8–11 | Include all RVA events + pull in Metro zone items to reach 10+ |
| 4–7 | Include Metro zone items; note distance |
| 2–3 | Lead TL;DR: "Light event calendar locally this month" + pull Extended Metro exceptional events |
| < 2 | Lead TL;DR: "Quiet month for events" — still output VA-wide tech or major-employer items if any exist |

Within each week and category, always sort events by date ascending (earliest first).

## REQUIRED OUTPUT FORMAT

```
# Richmond Events — [Month DD]–[Month DD, YYYY]
*Upcoming events · next 30 days · RVA-first*

## TL;DR
[2–3 sentences. What are the 2–3 must-know events this window? What requires advance booking?
If light: "Light calendar this month — nothing requiring advance booking." No padding.]

---

## Week 1: [Mon DD]–[Sun DD]

### Family / Kids
- **[Event Name](url)** — [what] | [Day Mon DD, TIME] | [Venue, Neighborhood] | [cost] | [why]. [TAG]

### Arts / Culture
- **[Event Name](url)** — [what] | [Day Mon DD, TIME] | [Venue, Neighborhood] | [cost] | [why]. [TAG]

### Food / Dining
- **[Event Name](url)** — [what] | [Day Mon DD, TIME] | [Venue, Neighborhood] | [cost] | [why]. [TAG]

### Tech / Professional
- **[Event Name](url)** — [what] | [Day Mon DD, TIME] | [Venue] | [cost] | [why]. [TAG]

### Outdoor / Parks
- **[Event Name](url)** — [what] | [Day Mon DD, TIME] | [Venue, Neighborhood] | [cost] | [why]. [TAG]

### Civic
- **[Event Name](url)** — [what] | [Day Mon DD, TIME] | [Venue] | [cost] | [why]. [TAG]

---

## Week 2: [Mon DD]–[Sun DD]

[same category structure — omit any category with zero events for that week]

---

## Week 3: [Mon DD]–[Sun DD]

[same category structure]

---

## Week 4: [Mon DD]–[Sun DD]

[same category structure]

---

## Dates TBC
[Events where DATE: UNKNOWN — no parseable date found. Include with "check website to confirm date." Omit this section if all events have confirmed dates.]
- **[Event Name](url)** — [what] | *check website to confirm date* | [Venue] | [cost] | [why]. [TAG]

---
*Source performance: [which sources returned events vs. 0 items vs. errors]*
```

**Rules for week buckets:**
- Week 1 covers the run date through the following Sunday
- Week 2 is the following Mon–Sun
- Week 3 is the following Mon–Sun
- Week 4 covers the remainder through {{DATE_PLUS_30}}
- Omit a week section entirely if no qualifying events fall in that window
- Omit a category sub-section if no events in that week belong to it
- Within each category, list events in ascending date order (earliest first)

## ACTION TAGS

- `[ATTEND]` — calendar-worthy; include date, venue, and link to register/RSVP if needed
- `[BRING FAMILY]` — family-friendly; note age-appropriateness if possible
- `[BOOK NOW]` — tickets selling fast OR early-bird deadline within 7 days; state the deadline
- `[SHARE w/ team]` — RVA tech/professional event worth circulating to engineering team
- `[SHARE w/ family]` — family planning item worth sharing
- `[SKIP]` — present for completeness; low relevance this period

## ACTION FIELD MAPPING (Astro schema)

- `actions.try[]` ← ATTEND and BRING FAMILY items (full item text as a string)
- `actions.share[]` ← SHARE items (use `what`/`who` fields: `who` = "team" or "family")
- `actions.readDeeper[]` ← BOOK NOW urgency items (deadline-sensitive; state deadline in text)
- `actions.skip[]` ← SKIP items (title only)

## DATE FIELD RULES

Each HTML-sourced event in the fetched content carries a `DATE:` field:

- `DATE: YYYY-MM-DD` — date was mathematically extracted from the HTML and confirmed to fall within the 30-day window. Use this date exactly as written when placing the event in its week bucket.
- `DATE: UNKNOWN` — the fetcher could not find a parseable date in the HTML. Include the event but write "check website to confirm date" in the entry. Do NOT place it in any specific week bucket — instead collect all UNKNOWN-date events in a final section called `## Dates TBC`.
- RSS items carry `Date: YYYY-MM-DD` (lowercase) — these are publication dates, not necessarily event dates. Use the RSS summary to determine the actual event date; if the summary doesn't confirm a future date, treat as UNKNOWN.

**Never infer, guess, or assume an event date based on its name or category.** If the date is not explicitly provided by a `DATE:` field or stated clearly in the summary, it is UNKNOWN. The Python fetcher has already dropped all HTML events with confirmed past or future-beyond-30-days dates — do not second-guess this filtering.

## IMPORTANT

- Every event title MUST be a markdown hyperlink using the exact URL from the source data
- Do not invent, guess, or construct URLs
- Apply distance weighting strictly — RVA items always appear before non-RVA items in each section
- If a source returned 0 items, note it in source performance but do not pad with invented content
- Civic/political cap: include at most 1–2 civic events per digest; drop if no genuine community-access angle
- Category sub-sections without any events for a given week should be omitted entirely — do not include empty headers

---

## STEP 1 — Check date

Run date: {{DATE}} (should be a Saturday)

The 30-day window ends {{DATE_PLUS_30}}.

Check: does `src/content/rva-events/{{DATE}}.md` already exist? If yes, print "Already exists — skipping." and stop.

## STEP 2 — Write the digest file

Using the fetched content below, generate the forward-looking events calendar.
Write to `src/content/rva-events/{{DATE}}.md` with this exact structure:

```
---
title: "Richmond Events — [Month DD]–[Month DD, YYYY]"
date: {{DATE}}
theme: rva-events
format: weekly-synthesis
tldr: "[2-sentence summary of top 2-3 events this window]"
itemCount: [integer — total items across all sections]
readTimeMinutes: [integer, typically 2–3]
sources:
  - title: "[source name]"
    url: "[url]"
actions:
  try:
    - "[ATTEND or BRING FAMILY item — full text]"
  share:
    - what: "[event name and what it is]"
      who: "[team | family]"
  readDeeper:
    - "[BOOK NOW urgency item — include deadline]"
  skip:
    - "[title only]"
---

[digest body following REQUIRED OUTPUT FORMAT above]
```

## STEP 3 — Write file only (do NOT commit)

The orchestrator (`run-jobs.sh`) handles all git operations after all topics complete.
Do not run `git add`, `git commit`, or `git push`.

Print: "✓ Richmond Events digest for {{DATE}} written to src/content/rva-events/{{DATE}}.md"
