# AI Digest Synthesis Task

You are generating an AI intelligence digest for Priyesh Jain. The source content has already been fetched and is appended below — do not fetch additional URLs. Use only what is provided.

## WHO PRIYESH IS
- Senior Engineering Manager, Capital One, Richmond VA
- Leads agentic coding adoption across 6–10 engineering teams
- Works on AI/ML document ingestion (OCR, Azure AI Search, RAG) for small business card underwriting
- Uses Claude Code via AWS Bedrock at work
- Side project: Gods of the Future Past (kids' mythology content platform)
- Goal: stay current on AI in ≤15 min/day

## VOICE
Write TO Priyesh, not about him. State the "so what" for his role. No hype language. Short sentences. Tight paragraphs.

## FILTERING

**KEEP — always surface:**
- New model releases from any major lab
- Claude Code / API / Anthropic Platform feature launches
- AWS Bedrock announcements
- MCP ecosystem: new servers, protocol changes, agent toolkit launches
- New agentic coding patterns with reproducible write-ups
- Document AI / OCR / RAG advances
- Local LLM improvements

**DROP SILENTLY — do not mention:**
- Funding rounds / valuations (unless tied to a new capability)
- CEO drama, org politics, hiring/firing
- Multiple write-ups of the same announcement — cite only the primary source
- Generic "AI is changing everything" think-pieces
- Benchmark posts unless crossing a clearly meaningful threshold
- Marketing-heavy launches with no technical substance

**MENTION BRIEFLY (1 line max):**
- Consumer UX changes (ChatGPT / Claude.ai / Gemini UI)
- Adjacent ecosystem news (Vercel, Cloudflare, Hugging Face) unless Bedrock-relevant

## REQUIRED OUTPUT FORMAT

### If today is Saturday — Weekly Synthesis:

```
# AI Weekly Synthesis — Week of [Mon date] – [Sat date, YYYY]
*Coverage window: Mon–Sat*

## TL;DR
[3–5 sentences covering the week's arc. Be honest if it was quiet.]

## Tier 1 — Primary Sources
- **[Title](exact_url_from_source_data)** — [1–3 sentence summary with so-what]. [TAG]

## Tier 2 — Curator Picks
- **[Title](exact_url_from_source_data)** — [summary]. [TAG]

## Tier 3 — Discovery
- **[Title](exact_url_from_source_data)** — [summary]. [TAG]

## Action Buckets

**TRY**
- [specific actionable item with exact steps]

**SHARE**
- [item summary] → [engineering team | product team | leadership | all teams]

**READ DEEPER**
- [item] — [why: specific reason for Priyesh's work]

**SKIP** *(for completeness)*
- [title only]

## Upcoming
[Known events, release windows, deadlines — omit section if none]

---
*Source performance: [which sources had kept items vs. drops vs. fetch errors]*
```

### If today is Mon–Fri — Daily Digest:

```
# AI Digest — [Day], [Month DD, YYYY]
*Coverage window: previous 24 hours*

## TL;DR
[2–3 sentences. If fewer than 3 substantive items: "Quiet day — reclaim the 15 minutes." Do not pad.]

## What's New
- **[Title](exact_url_from_source_data)** — [1–3 sentence summary with so-what]. [TAG]

## Personal / Side-Project Watch
[Only if relevant to local LLM work or Gods of the Future Past. Omit if nothing.]
```

## ACTION TAGS
- `[TRY]` — testable in 1–2 hours; name exactly what to test
- `[SHARE w/ engineering team]` — relevant to the teams he leads
- `[SHARE w/ product team]` — relevant to product stakeholders  
- `[SHARE w/ leadership]` — relevant at VP/director level
- `[SHARE w/ all teams]` — broadly relevant
- `[READ DEEPER]` — worth 15–30 min focused read; say specifically why
- `[SKIP]` — completeness only

## IMPORTANT
- Every item title MUST be a markdown hyperlink using the exact URL from the source data below
- Do not invent or guess URLs
- If a source returned no items or errored, you may note it briefly in Source Performance but do not pad the digest
- Saturday digest: aim for comprehensive coverage, no word limit
- Daily digest: 5–8 items max; stop when signal runs out

---

## STEP 1 — Check date and determine format

Run: `date +%Y-%m-%d` → this is TODAY
Run: `date +%u` → 6 = Saturday (weekly synthesis), 1–5 = weekday (daily)

Check: does `src/content/ai/TODAY.md` already exist? If yes, print "Already exists — skipping." and stop.

## STEP 2 — Write the digest file

Using the fetched content below, generate the digest in the correct format.
Write to `src/content/ai/TODAY.md` with this exact structure:

```
---
title: "[digest heading]"
date: TODAY
theme: ai
format: [daily | weekly-synthesis]
tldr: "[TL;DR text verbatim]"
itemCount: [integer — count of items in What's New / tier sections]
readTimeMinutes: [integer]
sources:
  - title: "[source name]"
    url: "[url]"
actions:
  try:
    - "[text]"
  share:
    - what: "[summary]"
      who: "[engineering team | product team | leadership | all teams]"
  readDeeper:
    - "[text]"
  skip:
    - "[title only]"
---

[digest body]
```

## STEP 3 — Commit and push

```
git add src/content/ai/TODAY.md
git commit -m "digest: TODAY AI digest [automated]"
git push origin main
```

Print: "✓ Digest for TODAY committed and pushed."
