# Richmond Events Forward Calendar Task

You are generating a weekly Richmond Events digest for Priyesh Jain. The source content has already been fetched and is appended below — do not fetch additional URLs. Use only what is provided.

## WHO PRIYESH IS
- Senior Engineering Manager at Capital One, Richmond VA
- Richmond resident with family; interested in tech community events, family activities, arts, dining, and local civic life
- Cares about: RVA tech scene, Capital One community, family weekend planning, engaging with local elected officials, RVA food/arts scene
- Goal: know what's coming up in the next 30 days in ≤15 min each Saturday morning

## VOICE
Write TO Priyesh like a well-connected Richmond local who scanned all the calendars for him. Conversational, practical. Lead with what needs advance booking first, then what's coming up by week.

## THIS IS A FORWARD-LOOKING EVENTS DIGEST

- **Window:** next 30 days from TODAY (the Saturday run date)
- **Never include:** events that have already occurred
- **Deduplication boundary:** events occurring on TODAY or TODAY+1 (Sunday) belong in the Richmond news digest — exclude them here
- **Organize:** chronologically by week bucket — not by category

## DISTANCE WEIGHTING

Apply this priority order for every event:

1. **RVA** (Richmond city proper + Henrico, Chesterfield, Midlothian) — always include; lead every section
2. **Metro** (Hanover, Colonial Heights, Petersburg, Hopewell) — include when 4+ RVA items are present
3. **Extended Metro** (Charlottesville, Williamsburg, Fredericksburg — ≤60 min drive) — only if genuinely exceptional AND strong RVA signal; note distance explicitly
4. **VA-Wide** — only if Capital One community event or major RVA tech significance; state distance and relevance explicitly

When surfacing non-RVA items, prefix with the zone: **Metro:** or **Extended Metro:** or **VA-wide:**.

## CATEGORIES — INCLUDE

- **Family / kids:** museum events, parks programming, festivals, children's theater, family workshops
- **Arts / culture:** gallery openings, exhibits, live performances (family-appropriate or date-night caliber)
- **Food / dining:** restaurant openings/events, food festivals, market days, culinary experiences
- **Tech / professional:** RVAtech meetups, startup events, Capital One community events, dev community
- **Outdoor / parks:** nature programming, trail events, outdoor markets, park festivals
- **Civic / political:** events where Priyesh can engage directly with Richmond city leadership or elected officials — hackathons hosted by the city, Mayor's public listening sessions, city council community forums, neighborhood association meetings with elected officials present
  - Cap at **1–2 items per digest**
  - Require a "direct community access to elected officials" angle (Mayor Danny Avula, City Council members)
  - Tag [ATTEND] only if there is a genuine networking or civic-influence opportunity

## CATEGORIES — DROP SILENTLY

- Sports scores, game schedules, team standings
- Pure partisan fundraisers (campaign rally, party gala, political fundraising dinner) — no civic-access angle
- Generic charity 5Ks and ribbon cuttings with no broader community draw
- Events outside the distance zones defined above
- Events whose date has already passed as of TODAY
- Events occurring TODAY or TODAY+1 (belongs in richmond news digest)

## SPARSITY FALLBACK

| RVA events found | Action |
|-----------------|--------|
| ≥ 6 | Normal output; trim to 10–12 best items across week buckets |
| 4–5 | Include Metro zone items; note distance |
| 2–3 | Lead TL;DR: "Light event calendar locally this month" + pull Extended Metro exceptional events |
| < 2 | Lead TL;DR: "Quiet month for events" — still output VA-wide tech/Capital One items if any exist |

## REQUIRED OUTPUT FORMAT

```
# Richmond Events — [Month DD]–[Month DD, YYYY]
*Upcoming events · next 30 days · RVA-first*

## TL;DR
[2–3 sentences. What are the 2–3 must-know events this window? What requires advance booking?
If light: "Light calendar this month — nothing requiring advance booking." No padding.]

## This Week ([Mon DD]–[Fri DD])
- **[Event Name](url)** — [what] | [Day Mon DD, TIME] | [Venue, Neighborhood] | [cost] | [why]. [TAG]

## This Weekend ([Sat DD]–[Sun DD])
- **[Event Name](url)** — [what] | [Day Mon DD, TIME] | [Venue, Neighborhood] | [cost] | [why]. [TAG]

## Next Weekend ([Sat DD]–[Sun DD])
- **[Event Name](url)** — [what] | [Day Mon DD, TIME] | [Venue, Neighborhood] | [cost] | [why]. [TAG]

## Coming Up ([Month DD] – [Month DD])
[Group remaining weeks loosely; omit sub-headers if sparse]
- **[Event Name](url)** — [what] | [Day Mon DD, TIME] | [Venue, Neighborhood] | [cost] | [why]. [TAG]

## Tech & Professional
[RVAtech meetups, Capital One events, Startup Virginia, civic events. Omit section if empty.]
- **[Event Name](url)** — [what] | [Day Mon DD, TIME] | [Venue] | [cost] | [why]. [TAG]

---
*Source performance: [which sources returned events vs. 0 items vs. errors]*
```

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

## IMPORTANT

- Every event title MUST be a markdown hyperlink using the exact URL from the source data
- Do not invent, guess, or construct URLs
- Apply distance weighting strictly — RVA items always appear before non-RVA items in each section
- HTML venue sources (VMFA, Maymont, etc.) may return imprecise or missing event times — note "check website for times" in those cases
- If a source returned 0 items, note it in source performance but do not pad with invented content
- Civic/political cap: include at most 1–2 civic events per digest; drop if no genuine community-access angle

---

## STEP 1 — Check date

Run: `date +%Y-%m-%d` → this is TODAY
Run: `date +%u` → should be 6 (Saturday)

Calculate the 30-day window end: TODAY + 30 days.

Check: does `src/content/rva-events/TODAY.md` already exist? If yes, print "Already exists — skipping." and stop.

## STEP 2 — Write the digest file

Using the fetched content below, generate the forward-looking events calendar.
Write to `src/content/rva-events/TODAY.md` with this exact structure:

```
---
title: "Richmond Events — [Month DD]–[Month DD, YYYY]"
date: TODAY
theme: rva-events
format: weekly-synthesis
tldr: "[2-sentence summary of top 2-3 events this window]"
itemCount: [integer — total items across all sections]
readTimeMinutes: [integer, typically 2]
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

The orchestrator (`run-all-topics.sh`) handles all git operations after all topics complete.
Do not run `git add`, `git commit`, or `git push`.

Print: "✓ Richmond Events digest for TODAY written to src/content/rva-events/TODAY.md"
