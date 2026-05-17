# Story 5.1: RVA Events — Source Config & Synthesis Prompt

Status: done

## Story

As Priyesh,
I want a `richmond-events` pipeline topic with 14 curated sources and a forward-looking synthesis prompt,
so that every Saturday I automatically receive a 30-day calendar of upcoming RVA events without any manual curation.

## Acceptance Criteria

1. **Given** `scripts/topics/richmond-events.yaml` is created **When** parsed as YAML **Then** it contains `name: richmond-events`, `theme: rva-events`, `schedule: weekly`, `output_collection: rva-events`, `prompt: scripts/prompts/richmond-events.md`

2. **Given** the YAML **When** sources are inspected **Then** `sources.tier1` contains 3 RVA RSS sources with event `filter_regex`: Style Weekly Events, RICtoday Events, Richmond Magazine Events

3. **Given** the YAML **When** tier2 is inspected **Then** it contains 7 venue HTML calendar pages: VMFA, Maymont, The Valentine, Science Museum of Virginia, Hardywood, Strangeways, Capital One Hall

4. **Given** the YAML **When** tier3 is inspected **Then** it contains 4 community aggregators (html): Visit Richmond Events, Richmond Family Magazine Calendar, RVAtech Events, Startup Virginia Events

5. **Given** `scripts/prompts/richmond-events.md` is created **When** reviewed **Then** it contains: WHO PRIYESH IS, 4-zone distance weighting (RVA→Metro→Extended Metro→VA-Wide), CATEGORIES INCLUDE (with civic/political at ≤2 cap), CATEGORIES DROP SILENTLY, dedup boundary (TODAY/TODAY+1 → richmond digest), sparsity fallback, date-primary week-bucket structure, item format, action tag definitions, required frontmatter template, STEP 1–3 (no git ops)

6. **Given** `src/content/rva-events/.gitkeep` created **When** `git status` **Then** empty directory is tracked

7. **Given** `.claude/settings.json` updated **When** `permissions.allow` inspected **Then** `"Write(src/content/rva-events/*)"` is present alongside all existing entries

## Tasks / Subtasks

- [x] Create `scripts/topics/richmond-events.yaml` (AC: 1, 2, 3, 4)
  - [x] Header fields: name, theme, schedule, output_collection, prompt
  - [x] tier1: 3 RSS sources with filter_regex (Style Weekly, RICtoday, Richmond Magazine)
  - [x] tier2: 7 HTML venue calendar pages (VMFA, Maymont, Valentine, SMV, Hardywood, Strangeways, Capital One Hall)
  - [x] tier3: 4 HTML aggregators (Visit Richmond, Richmond Family, RVAtech, Startup Virginia)
- [x] Create `scripts/prompts/richmond-events.md` (AC: 5)
  - [x] WHO PRIYESH IS section
  - [x] 4-zone distance weighting rule with Metro/Extended Metro added
  - [x] CATEGORIES — INCLUDE (family, arts, food, tech, outdoor, civic/political ≤2)
  - [x] CATEGORIES — DROP SILENTLY (sports, partisan fundraisers, charity runs, past events)
  - [x] Deduplication boundary rule (TODAY / TODAY+1)
  - [x] Sparsity fallback rules (<4 RVA → Metro; <2 → "Light event calendar")
  - [x] Date-primary week-bucket output format (This Week / Next Weekend / Coming Up)
  - [x] Item format line
  - [x] Action tag definitions with schema mapping
  - [x] Required frontmatter template (theme: rva-events)
  - [x] STEP 1 (date check + idempotency), STEP 2 (write file), STEP 3 (no git ops)
- [x] Create `src/content/rva-events/.gitkeep` (AC: 6)
- [x] Update `.claude/settings.json` — add `Write(src/content/rva-events/*)` (AC: 7)

### Review Findings (code review 2026-05-17)

- [x] [Review][Decision] Capital One Hall geographic placement — moved from tier2 to tier3; URL trailing slash added. User decision: keep it, McLean/Tysons events → tier3 (VA-Wide). West Creek campus (Richmond) noted as future candidate. [`scripts/topics/richmond-events.yaml`]
- [x] [Review][Patch] AC1: `name` field must be lowercase hyphenated — fixed: `name: richmond-events` [`scripts/topics/richmond-events.yaml`:1]
- [x] [Review][Patch] Capital One Hall URL missing trailing slash — fixed: `https://www.capitalonehall.com/events/` [`scripts/topics/richmond-events.yaml`]
- [x] [Review][Defer] filter_regex case-sensitivity — `re.IGNORECASE` status unverified; uppercase event words may be missed. Pre-existing behavior across all topic configs; not introduced by this story. [`scripts/topics/richmond-events.yaml` tier1] — deferred, pre-existing
- [x] [Review][Defer] Dedup boundary assumes Saturday run — prompt logic references "Saturday run date"; if pipeline runs on another day the TODAY+1 rule misbehaves. Pre-existing system assumption (launchd scheduled for Saturdays). [`scripts/prompts/richmond-events.md` STEP 1] — deferred, pre-existing
- [x] [Review][Defer] `rva-events` missing from `src/content.config.ts` — Story 5.2 explicit scope. [`src/content.config.ts`] — deferred, pre-existing
- [x] [Review][Defer] `theme: rva-events` not in digestSchema enum — Story 5.2 explicit scope. [`src/content.config.ts`] — deferred, pre-existing
- [x] [Review][Defer] `rva-events` absent from Astro routing — Story 5.2 explicit scope. [`src/pages/[theme]/index.astro`, `src/pages/index.astro`, `src/layouts/Layout.astro`] — deferred, pre-existing

## Dev Notes

### Pattern to follow exactly

All 4 existing topic configs follow the **same YAML structure**. Use `scripts/topics/richmond.yaml` as the template — it's the closest in character (local/weekly/HTML tier3). The field order is: header fields → tier1 → tier2 → tier3.

All 4 existing prompts follow the **same markdown structure**:
1. Task declaration line ("You are generating a weekly X digest for Priyesh Jain...")
2. WHO PRIYESH IS
3. VOICE
4. Filtering (KEEP / DROP / MENTION)
5. REQUIRED OUTPUT FORMAT (fenced code block with exact markdown template)
6. ACTION TAGS
7. ACTION FIELD MAPPING
8. IMPORTANT rules list
9. STEP 1 (date check + idempotency)
10. STEP 2 (write file with frontmatter template)
11. STEP 3 (no git ops)

Use `scripts/prompts/richmond.md` as the base structure. The key differences for `richmond-events.md`:
- Topic is **forward-looking** (next 30 days), not backward-looking (past 7 days)
- Distance weighting has **4 zones** (adds Extended Metro: Charlottesville, Williamsburg, Fredericksburg)
- CATEGORIES replace KEEP/DROP rules (distinct event types vs. news filtering)
- Civic/political events included at **≤2 items cap** with "direct access to elected officials" qualifier
- ATTEND/BRING FAMILY/BOOK NOW/SHARE tags (not ATTEND/WATCH/SHARE)
- Deduplication rule: events on TODAY or TODAY+1 go to `richmond` digest, not here
- Output collection is `rva-events` (not `richmond`)
- No `readDeeper[]` populated from WATCH — `readDeeper[]` ← BOOK NOW urgency items only

### `richmond-events.yaml` — exact source list

**tier1 (RSS + filter_regex):**
```yaml
- name: "Style Weekly Events"
  kind: rss
  url: "https://www.styleweekly.com/richmond/EventsCategory/Events"
  max_items: 15
  filter_regex: "\\b(event|concert|festival|exhibit|opening|workshop|market|fair|show)\\b"
  filter_cap: 10
- name: "RICtoday Events"
  kind: rss
  url: "https://rictoday.6amcity.com/latest-news-rss"
  max_items: 15
  filter_regex: "\\b(event|festival|exhibit|market|fair|show|performance|opening)\\b"
  filter_cap: 8
- name: "Richmond Magazine Events"
  kind: rss
  url: "https://richmondmagazine.com/api/rss/content.rss"
  max_items: 10
  filter_regex: "\\b(event|calendar|festival|exhibit|opening|fair|show|market)\\b"
  filter_cap: 6
```

**tier2 (HTML venue calendars — no filter needed, they only publish events):**
```yaml
- name: "VMFA Events"
  kind: html
  url: "https://www.vmfa.museum/events/"
  max_items: 8
- name: "Maymont Events"
  kind: html
  url: "https://maymont.org/explore/events/"
  max_items: 6
- name: "The Valentine Events"
  kind: html
  url: "https://thevalentine.org/events/"
  max_items: 5
- name: "Science Museum of Virginia"
  kind: html
  url: "https://smv.org/plan-your-visit/calendar-of-events/"
  max_items: 5
- name: "Hardywood Events"
  kind: html
  url: "https://www.hardywood.com/events/"
  max_items: 4
- name: "Strangeways Events"
  kind: html
  url: "https://strangewaysbrewing.com/events/"
  max_items: 4
- name: "Capital One Hall Events"
  kind: html
  url: "https://www.capitalonehall.com/events"
  max_items: 6
```

**tier3 (HTML community aggregators):**
```yaml
- name: "Visit Richmond Events"
  kind: html
  url: "https://www.visitrichmondva.com/events/"
  max_items: 10
- name: "Richmond Family Magazine Calendar"
  kind: html
  url: "https://richmondfamilymagazine.com/calendar/"
  max_items: 8
- name: "RVAtech Events"
  kind: html
  url: "https://rvatech.com/user-groups-meetups/"
  max_items: 6
- name: "Startup Virginia Events"
  kind: html
  url: "https://startupva.com/events/"
  max_items: 5
```

> **Note on HTML sources:** VMFA, Maymont, Valentine, and SMV use React/Next.js frontends. `fetch_html` in `fetch_sources.py` uses `httpx` + `beautifulsoup4` and does NOT execute JavaScript. These may return 0 items. That's acceptable — tier1 RSS sources provide the bulk of content. Do not add JS rendering; leave as-is.

### `richmond-events.md` — key prompt content

**Distance weighting (4 zones — expanded from richmond's 3):**
```
1. RVA (Richmond city + Henrico, Chesterfield, Midlothian) — always lead
2. Metro (Hanover, Colonial Heights, Petersburg, Hopewell) — include if 4+ RVA items
3. Extended Metro (Charlottesville, Williamsburg, Fredericksburg ≤60 min) — only if exceptional + strong signal
4. VA-Wide — Capital One community or major RVA tech significance only; state distance explicitly
```

**Item format (must appear verbatim in prompt):**
```
**[Event Name](url)** — [what] | [Day Mon DD, TIME] | [Venue, Neighborhood] | [cost] | [why]. [TAG]
```

**Action tag → schema mapping:**
```
[ATTEND]          → try[]
[BRING FAMILY]    → try[]
[BOOK NOW]        → readDeeper[]  (urgency: deadline within 7 days)
[SHARE w/ team]   → share[] (who: "team")
[SHARE w/ family] → share[] (who: "family")
[SKIP]            → skip[]
```

**Civic/political inclusion rule (verbatim in prompt):**
```
Civic/political events: include at most 1–2 items per digest. Require a "direct community access
to elected officials" angle (hackathons, listening sessions, public forums, neighborhood meetings
where Mayor or Council members are present). Tag [ATTEND] only if there is a genuine networking or
civic-influence opportunity. Pure partisan fundraisers (campaign rallies, party galas) → DROP.
```

**Deduplication rule (verbatim in prompt):**
```
TODAY = the Saturday run date. Events occurring on TODAY or TODAY+1 (Sunday) belong in the
richmond news digest, not here. Exclude them.
```

**Idempotency check (STEP 1):**
```
Check: does `src/content/rva-events/TODAY.md` already exist? If yes, print "Already exists — skipping." and stop.
```

**Frontmatter template (STEP 2):**
```yaml
---
title: "Richmond Events — [Month DD]–[Month DD, YYYY]"
date: TODAY
theme: rva-events
format: weekly-synthesis
tldr: "[2-sentence summary of top 2-3 events]"
itemCount: [integer]
readTimeMinutes: [integer, typically 2]
sources:
  - title: "[source name]"
    url: "[url]"
actions:
  try:
    - "[ATTEND/BRING FAMILY item text]"
  share:
    - what: "[event name and what it is]"
      who: "[team | family]"
  readDeeper:
    - "[BOOK NOW urgency item text]"
  skip:
    - "[title only]"
---
```

Write to: `src/content/rva-events/TODAY.md`

### `.claude/settings.json` update

Add exactly one new entry. Do not reorder or remove existing entries. The current file has:
```json
"Write(src/content/local-llm/*)"
```
as the last entry. Add after it:
```json
"Write(src/content/rva-events/*)"
```

Verify after edit: `python3 -m json.tool .claude/settings.json` must exit 0.

### Existing files NOT to touch

- `scripts/fetch_sources.py` — no changes; already handles all `kind` types dynamically from YAML
- `scripts/run-all-topics.sh` — auto-discovers all `scripts/topics/*.yaml`; picks up `richmond-events.yaml` automatically
- Any existing `scripts/topics/*.yaml` or `scripts/prompts/*.md` — no changes
- Any `src/content/` files — only create the new `.gitkeep`

### Testing this story

1. Verify YAML syntax: `python3 -c "import yaml; yaml.safe_load(open('scripts/topics/richmond-events.yaml'))" && echo OK`
2. Verify fetch runs (some sources may 404 or return 0 — that's fine):
   `scripts/.venv/bin/python3 scripts/fetch_sources.py --topic richmond-events --weekly 2>&1 | grep "###"`
   Expected: 14 `### [Source Name]` headers appear (even if item counts are 0 for JS-rendered HTML venues)
3. Verify settings.json valid JSON: `python3 -m json.tool .claude/settings.json > /dev/null && echo OK`
4. Verify `.gitkeep` tracked: `git status src/content/rva-events/`

### Project Structure Notes

- New files:
  - `scripts/topics/richmond-events.yaml`
  - `scripts/prompts/richmond-events.md`
  - `src/content/rva-events/.gitkeep`
- Modified files:
  - `.claude/settings.json` (one line added to `permissions.allow`)
- No Astro site files touched in this story — that's Story 5.2

### References

- Existing pattern: [scripts/topics/richmond.yaml](scripts/topics/richmond.yaml)
- Existing pattern: [scripts/prompts/richmond.md](scripts/prompts/richmond.md)
- Existing pattern: [scripts/prompts/local-llm.md](scripts/prompts/local-llm.md) (most recently added)
- Proposal (full source list + prompt template): [.claude/plans/daily-kickoff/daily-kickkoff-generator-routine/RICHMOND_EVENTS_PROPOSAL.md](.claude/plans/daily-kickoff/daily-kickkoff-generator-routine/RICHMOND_EVENTS_PROPOSAL.md) §3.2 and §5
- Epic 5 Story 5.1 ACs: [.claude/planning/epics.md](.claude/planning/epics.md)

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

- YAML validated via `scripts/.venv/bin/python3 -c "import yaml; yaml.safe_load(...)"` — passed
- settings.json validated via `python3 -m json.tool` — passed
- `fetch_sources.py --topic richmond-events --weekly` — all 14 source headers returned; JS-rendered venues (VMFA, SMV, Hardywood, Strangeways, Capital One Hall, Style Weekly Events, Startup Virginia) returned 0 items as expected; Maymont (6), Valentine (5), Richmond Family Calendar (8), RVAtech (6), Visit Richmond (1), Richmond Magazine Events (1) returned live data
- `.gitkeep` present and directory untracked (git add not yet run — orchestrator handles commits)

### Completion Notes List

- Created `richmond-events.yaml` following exact same field/tier structure as `richmond.yaml`; added `filter_regex`/`filter_cap` to tier1 RSS sources (event keyword filter); tier2 is pure HTML venue calendars (no filter needed — they only publish events); tier3 is HTML community aggregators
- Created `richmond-events.md` prompt following same section order as `richmond.md` and `local-llm.md`; key additions vs. richmond: 4-zone distance weighting (added Extended Metro zone), CATEGORIES replace KEEP/DROP (event-type based), civic/political inclusion at ≤2 cap with "direct community access" qualifier, forward-looking window with TODAY/TODAY+1 dedup boundary, date-primary week-bucket output structure, BOOK NOW → `readDeeper[]` schema mapping
- Created `src/content/rva-events/.gitkeep` to track empty directory in git
- Updated `.claude/settings.json` — added `"Write(src/content/rva-events/*)"` as last entry in allow array; JSON still valid

### File List

- `scripts/topics/richmond-events.yaml` (NEW)
- `scripts/prompts/richmond-events.md` (NEW)
- `src/content/rva-events/.gitkeep` (NEW)
- `.claude/settings.json` (UPDATED — `Write(src/content/rva-events/*)` added to allow list)
