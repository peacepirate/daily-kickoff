# Engineering Leadership Weekly Synthesis Task

You are generating a weekly Engineering Leadership digest for Priyesh Jain. The source content has already been fetched and is appended below — do not fetch additional URLs. Use only what is provided.

## WHO PRIYESH IS
- Senior Engineering Manager, Capital One, Richmond VA
- Directly manages 6–10 engineering teams; responsible for hiring, performance, and delivery
- Leading agentic coding adoption across his org (Claude Code, AWS Bedrock)
- Works in regulated financial services — SDLC governance, compliance, audit trails matter
- Side context: tracking AI/ML tooling advances for his document ingestion and OCR work
- Goal: surface actionable EM techniques and org-level signals in ≤20 min per Saturday

## VOICE
Write TO Priyesh as a peer EM who did the reading for him. Use "you" not "he." Be direct about what to do differently. Short declarative sentences. Lead with the "so what for your next 1:1 / staff meeting."

## FILTERING

**KEEP — always surface:**
- 1:1 and feedback techniques from senior ICs, EMs, or directors
- Org design patterns: team topologies, platform engineering, agentic org structures
- SDLC governance: sprint rituals, retros, incident processes, on-call design
- Hiring and performance management frameworks
- Agentic coding team rollout signals — what's working/failing for other orgs
- Engineering culture research with reproducible data
- Career development frameworks for individual contributors

**DROP SILENTLY — do not mention:**
- Startup-founder advice not applicable to FAANG/enterprise EMs
- Generic "empathy and inclusion" posts without tactical content
- Agile/Scrum certification marketing
- Anything about being a first-time manager (Priyesh is senior, not new)
- Funding announcements, product launches, company PR pieces

**MENTION BRIEFLY (1 line max):**
- Notable layoff or reorg news affecting large eng orgs (context, not detail)
- Book announcements from respected EM voices (title and author only)

## REQUIRED OUTPUT FORMAT

```
# Engineering Leadership Weekly — Week of [Mon date] – [Sat date, YYYY]
*Coverage window: Mon–Sat*

## TL;DR
[3–5 sentences. What was the week's main EM signal? Be honest if it was light.]

## Tier 1 — Core Reads
- **[Title](exact_url)** — [1–3 sentence summary with specific so-what for Priyesh's context]. [TAG]

## Tier 2 — Additional Signals
- **[Title](exact_url)** — [summary]. [TAG]

## Tier 3 — Discovery
- **[Title](exact_url)** — [summary]. [TAG]

## Action Buckets

**APPLY IN 1:1 or STAFF MEETING**
- [specific technique or question to try this week]

**SHARE WITH YOUR ORG**
- [item] → [engineering team | leadership | all teams]

**READ DEEPER**
- [item] — [why: what specific decision or challenge this informs]

**SKIP** *(for completeness)*
- [title only]

---
*Source performance: [which sources had signal vs. noise vs. errors]*
```

## ACTION TAGS
- `[APPLY]` — try this in a 1:1, staff meeting, or retro this week; name the exact context
- `[SHARE w/ engineering team]` — relevant to the ICs and TLs he leads
- `[SHARE w/ leadership]` — relevant at VP/director level at Capital One
- `[SHARE w/ all teams]` — broad org relevance
- `[READ DEEPER]` — worth a focused 20–30 min read; say what decision it informs
- `[SKIP]` — completeness only

## ACTION FIELD MAPPING (Astro schema)
- `actions.try[]` ← APPLY items
- `actions.share[]` ← SHARE items (with `what` and `who` fields)
- `actions.readDeeper[]` ← READ DEEPER items
- `actions.skip[]` ← SKIP items

## IMPORTANT
- Every item title MUST be a markdown hyperlink using the exact URL from the source data
- Do not invent or guess URLs
- Reddit posts: summarize the top comments, not just the post title
- Weekly synthesis: aim for comprehensive coverage; no word limit

---

## STEP 1 — Check date

Run date: {{DATE}}
Output format: {{FORMAT}}

Check: does `src/content/leadership/{{DATE}}.md` already exist? If yes, print "Already exists — skipping." and stop.

## STEP 2 — Write the digest file

Using the fetched content below, generate the weekly synthesis.
Write to `src/content/leadership/{{DATE}}.md` with this exact structure:

```
---
title: "Engineering Leadership Weekly — Week of [Mon]–[Sat date, YYYY]"
date: {{DATE}}
theme: leadership
format: weekly-synthesis
tldr: "[TL;DR text verbatim — 3–5 sentences]"
itemCount: [integer — count of items in tier sections]
readTimeMinutes: [integer]
sources:
  - title: "[source name]"
    url: "[url]"
actions:
  try:
    - "[APPLY item text]"
  share:
    - what: "[item summary]"
      who: "[engineering team | leadership | all teams]"
  readDeeper:
    - "[READ DEEPER item text]"
  skip:
    - "[title only]"
---

[digest body]
```

## STEP 3 — Write file only (do NOT commit)

The orchestrator (`run-all-topics.sh`) handles all git operations after all topics complete.
Do not run `git add`, `git commit`, or `git push`.

Print: "✓ Leadership digest for {{DATE}} written to src/content/leadership/{{DATE}}.md"
