# Richmond & Virginia Weekly Synthesis Task

You are generating a weekly Richmond & Virginia digest for Priyesh Jain. The source content has already been fetched and is appended below — do not fetch additional URLs. Use only what is provided.

## WHO PRIYESH IS
- Senior Engineering Manager at Capital One, Richmond VA
- Richmond resident; interested in tech community events, family activities, dining, and local business
- Cares about: RVA tech scene, Capital One–relevant business news, weekend family plans, neighborhood development
- Goal: know what's happening locally in ≤15 min each Saturday morning

## VOICE
Write TO Priyesh like a well-connected Richmond local who did the scanning for him. Conversational tone, brief. Lead with what's actionable this weekend first.

## DISTANCE WEIGHTING RULE

**ALWAYS apply this ordering:**
1. **RVA Zone** (Richmond city, Henrico, Chesterfield, Short Pump) — always lead the digest
2. **VA-Wide Zone** (Virginia statewide) — include only if RVA items < 4, or to fill out context
3. **Sparsity fallback:** If Richmond-specific items total fewer than 4, expand to Virginia-wide items. If fewer than 2 Richmond items exist, lead the TL;DR with "Quiet week locally."

When surfacing Virginia-wide items that are NOT Richmond-specific, prefix with **VA-wide:** in the item summary.

## FILTERING

**KEEP — always surface:**
- Richmond tech events, meetups, startup news (RVAtech, capital One events, local dev community)
- Family-friendly activities and weekend events (parks, festivals, museums, dining openings)
- Local real estate and neighborhood development
- Capital One–relevant Richmond business news
- Restaurant openings, closings, and noteworthy food events
- Arts, culture, and community events in the RVA zone
- Virginia policy and legislation relevant to tech, business, or families

**DROP SILENTLY — do not mention:**
- Crime reports and police blotter items
- Weather forecasts and traffic reports
- Sports scores or game previews (unless a major local sports event)
- National political news with a Richmond dateline but no local angle
- Opinion pieces that are purely partisan
- Press releases with no reader value

**MENTION BRIEFLY (1 line max):**
- Statewide Virginia political news with potential local impact
- Large regional events (Virginia is for Lovers campaign announcements, etc.)

## REQUIRED OUTPUT FORMAT

```
# Richmond & Virginia Weekly — [Month DD, YYYY]
*Coverage window: past week*

## TL;DR
[2–4 sentences. Lead with the weekend's most actionable items. If sparse: "Quiet week locally."]

## This Weekend
- **[Title](exact_url)** — [what it is, when, where, why it's worth attending]. [TAG]

## Local Business & Tech
- **[Title](exact_url)** — [summary with local relevance]. [TAG]

## VA-Wide Signal
[Only include if RVA items were sparse. Prefix each with "VA-wide:". Omit section if not needed.]
- **[Title](exact_url)** — VA-wide: [summary].

## Action Buckets

**ATTEND or BRING FAMILY**
- [event name, date, location, why]

**WATCH** *(local development or policy to track)*
- [item] — [why it matters for Richmond or Capital One context]

**SHARE**
- [item] → [family | colleagues | leadership]

**SKIP** *(for completeness)*
- [title only]

---
*Source performance: [which sources had RVA items vs. VA-wide vs. errors]*
```

## ACTION TAGS
- `[ATTEND]` — specific event to put on the calendar; include date and location
- `[BRING FAMILY]` — family-friendly event for weekend plans
- `[WATCH]` — local development, policy, or business trend worth tracking
- `[SHARE]` — item worth sharing with family or colleagues
- `[SKIP]` — completeness only

## ACTION FIELD MAPPING (Astro schema)
- `actions.try[]` ← ATTEND and BRING FAMILY items
- `actions.share[]` ← SHARE items (with `what` and `who` fields)
- `actions.readDeeper[]` ← WATCH items
- `actions.skip[]` ← SKIP items

## IMPORTANT
- Every item title MUST be a markdown hyperlink using the exact URL from the source data
- Do not invent or guess URLs
- Apply the distance-weighting rule strictly — RVA items always appear before VA-wide
- If a source is an HTML scrape with imprecise dates, note "events listing" in source performance

---

## STEP 1 — Check date

Run: `date +%Y-%m-%d` → this is TODAY
Run: `date +%u` → should be 6 (Saturday)

Check: does `src/content/richmond/TODAY.md` already exist? If yes, print "Already exists — skipping." and stop.

## STEP 2 — Write the digest file

Using the fetched content below, generate the weekly synthesis.
Write to `src/content/richmond/TODAY.md` with this exact structure:

```
---
title: "Richmond & Virginia Weekly — [Month DD, YYYY]"
date: TODAY
theme: richmond
format: weekly-synthesis
tldr: "[TL;DR text verbatim — 2–4 sentences]"
itemCount: [integer — count of items across sections]
readTimeMinutes: [integer]
sources:
  - title: "[source name]"
    url: "[url]"
actions:
  try:
    - "[ATTEND or BRING FAMILY item text]"
  share:
    - what: "[item summary]"
      who: "[family | colleagues | leadership]"
  readDeeper:
    - "[WATCH item text]"
  skip:
    - "[title only]"
---

[digest body]
```

## STEP 3 — Write file only (do NOT commit)

The orchestrator (`run-all-topics.sh`) handles all git operations after all topics complete.
Do not run `git add`, `git commit`, or `git push`.

Print: "✓ Richmond digest for TODAY written to src/content/richmond/TODAY.md"
