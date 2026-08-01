# Tech & Gadgets Daily Digest Task

You are generating a daily Tech & Gadgets digest for Priyesh Jain. The source content has already been fetched and is appended below — do not fetch additional URLs. Use only what is provided.

## WHO PRIYESH IS
- Senior Engineering Manager, Capital One, Richmond VA
- Runs a smart home (Home Assistant, Matter/Thread, Zigbee) — practical automation, not tinkering for its own sake
- Uses Apple hardware ecosystem (Mac, iPhone); follows Android for competitive context
- Interested in EVs and the broader electric mobility transition
- Evaluates productivity tools through the lens of a manager leading 6–10 engineering teams
- Goal: know what matters in consumer tech in ≤10 min/day; skip launch hype, surface durable signal

## VOICE
Write TO Priyesh directly. Lead with practical relevance: does this affect something he owns, is deciding to buy, or is adopting at work? One sentence "so what." No unboxing hype. Short paragraphs.

## FILTERING

**KEEP — always surface:**
- Home Assistant releases, Matter/Thread spec updates, Zigbee/Z-Wave ecosystem changes
- Apple hardware announcements (Mac, iPhone, iPad, AirPods, Apple Watch) and iOS/macOS features
- EV range, charging infrastructure, or software updates for mainstream models
- Productivity tools with a clear time-saving use case for knowledge workers or managers
- Lab-tested reviews from RTINGS, Wirecutter, Car and Driver, DC Rainmaker
- Emerging hardware capabilities 12–24 months from mainstream (Hackaday, IEEE Spectrum)
- Price drops or "right time to buy" signals on major product categories

**DROP SILENTLY — do not mention:**
- Carrier deals and wireless plan changes
- Rumor posts with no new information (e.g. "iPhone 17 may have a new button")
- Unboxing videos and influencer first-looks with no test data
- Launch coverage that duplicates what's already in the digest from another source
- Gaming hardware and gaming-specific peripherals
- Smartwatch/fitness tracker reviews unless sensor accuracy data is cited

**MENTION BRIEFLY (1 line max):**
- Samsung/Google Pixel announcements (context, not detail — Priyesh is Apple-primary)
- Motor1 items that duplicate InsideEVs (cite InsideEVs as primary, drop Motor1)
- Notable software updates for apps he likely uses (Bear, Raycast, 1Password, Notion)

## REQUIRED OUTPUT FORMAT

### If today is Saturday — Weekly Synthesis:

```
# Tech & Gadgets Weekly — Week of [Mon date] – [Sat date, YYYY]
*Coverage window: Mon–Sat*

## TL;DR
[3–5 sentences. What was the week's main signal across consumer tech? Be honest if it was quiet.]

## Tier 1 — Top Stories
- **[Title](exact_url_from_source_data)** — [1–3 sentence summary with so-what]. [TAG]

## Tier 2 — Category Signals
- **[Title](exact_url_from_source_data)** — [summary]. [TAG]

## Tier 3 — Discovery
- **[Title](exact_url_from_source_data)** — [summary]. [TAG]

## Action Buckets

**BUY / DON'T BUY**
- [specific product decision with brief rationale]

**SHARE**
- [item summary] → [engineering team | leadership | all teams]

**READ DEEPER**
- [item] — [why: what decision or purchase this informs]

**SKIP** *(for completeness)*
- [title only]

---
*Source performance: [which sources had signal vs. noise vs. errors]*
```

### If today is Mon–Fri — Daily Digest:

```
# Tech & Gadgets — [Day], [Month DD, YYYY]
*Coverage window: previous 24 hours*

## TL;DR
[2–3 sentences. If fewer than 3 substantive items: "Quiet day — nothing urgent." Do not pad.]

## What's New
- **[Title](exact_url_from_source_data)** — [1–3 sentence summary with so-what]. [TAG]

## Smart Home Watch
[Only if there are Home Assistant, Matter, Zigbee, or smart home items. Omit if nothing.]
```

## ACTION TAGS
- `[BUY NOW]` — a specific "right time to buy" signal with rationale
- `[WAIT]` — product cycle signal suggesting holding off on a purchase
- `[SHARE w/ engineering team]` — productivity tool relevant to his ICs
- `[SHARE w/ leadership]` — relevant at VP/director level
- `[READ DEEPER]` — worth a focused 15–20 min read; say what decision it informs
- `[SKIP]` — completeness only

## ACTION FIELD MAPPING (Astro schema)
- `actions.try[]` ← BUY NOW / WAIT items
- `actions.share[]` ← SHARE items (with `what` and `who` fields)
- `actions.readDeeper[]` ← READ DEEPER items
- `actions.skip[]` ← SKIP items

## IMPORTANT
- Every item title MUST be a markdown hyperlink using the exact URL from the source data
- Do not invent or guess URLs
- Motor1 and InsideEVs often cover the same story — cite InsideEVs only
- If a source returned no items or errored, note it briefly in Source Performance
- Daily digest: 5–8 items max; stop when signal runs out
- Saturday synthesis: aim for comprehensive coverage; no word limit

---

## STEP 1 — Check date and determine format

Run date: {{DATE}}
Output format: {{FORMAT}}

Check: does `src/content/tech/{{DATE}}.md` already exist? If yes, print "Already exists — skipping." and stop.

## STEP 2 — Write the digest file

Using the fetched content below, generate the digest in the correct format.
Write to `src/content/tech/{{DATE}}.md` with this exact structure:

```
---
title: "[digest heading]"
date: {{DATE}}
theme: tech
format: {{FORMAT}}
tldr: "[TL;DR text verbatim]"
itemCount: [integer — count of items in What's New / tier sections]
readTimeMinutes: [integer]
sources:
  - title: "[source name]"
    url: "[url]"
actions:
  try:
    - "[BUY NOW or WAIT item text]"
  share:
    - what: "[summary]"
      who: "[engineering team | leadership | all teams]"
  readDeeper:
    - "[text]"
  skip:
    - "[title only]"
---

[digest body]
```

## STEP 3 — Write file only (do NOT commit)

The orchestrator (`run-all-topics.sh`) handles all git operations after all topics complete.
Your job ends when the file is written. Do not run `git add`, `git commit`, or `git push`.

Print: "✓ Tech & Gadgets digest for {{DATE}} written to src/content/tech/{{DATE}}.md"
