---
stepsCompleted: ["step-01-validate-prerequisites", "step-02-design-epics", "step-03-create-stories", "step-04-final-validation"]
inputDocuments:
  - ".claude/planning/prd.md"
  - ".claude/planning/architecture.md"
  - ".claude/planning/project-context.md"
  - ".claude/plans/daily-kickoff/daily-kickkoff-generator-routine/RICHMOND_EVENTS_PROPOSAL.md"
---

# Daily Kickoff — Multi-Topic Digest Pipeline - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for the Daily Kickoff v2 multi-topic pipeline, decomposing requirements from the PRD and Architecture into implementable developer stories.

---

## Requirements Inventory

### Functional Requirements

FR1: The pipeline must support per-topic YAML configuration files at `scripts/topics/TOPIC.yaml`. Each config file fully defines that topic's sources, schedule, output collection, and prompt path. Adding a new topic must require only adding a YAML config file — no Python code changes.

FR2: Each topic YAML config must include: `name`, `theme`, `schedule` (daily|weekly), `output_collection`, `prompt`, tiered source lists (`sources.tier1[]`, `tier2[]`, `tier3[]`), and per-source: `name`, `kind`, `url`, `max_items`, optional `filter_regex`, `filter_cap`.

FR3: `fetch_sources.py` must accept a `--topic TOPIC` argument and dynamically load sources from `scripts/topics/TOPIC.yaml`. All existing fetch functions remain unchanged.

FR4: The AI topic must run every day Mon–Sat from `scripts/topics/ai.yaml` with the existing 14 sources migrated from hardcoded Python lists.

FR5: The Leadership topic must run on Saturdays only. Sources: LeadDev, Will Larson, Charity Majors, Pragmatic Engineer, Lara Hogan, First Round Review, Manager Tools, HN (EM-filtered, cap 3), r/ExperiencedDevs, r/Engineering_Manager.

FR6: The Richmond topic must run on Saturdays only with distance-weighted sources: Richmond BizSense, Richmond Magazine, Style Weekly, RICtoday, Richmond Times-Dispatch, Small Richmond, WRIC, Virginia Mercury, Virginia Business, Visit Richmond HTML, Richmond Family Magazine HTML, RVAtech HTML.

FR7: The Local LLM topic must run on Saturdays only. Sources: r/LocalLLaMA, Ollama releases, llama.cpp releases, Open WebUI releases, Simon Willison (filtered), HuggingFace Blog (filtered), LM Studio HTML, GitHub Trending Python, HN (local-filtered, cap 3).

FR8: A master orchestrator `run-all-topics.sh` must discover all `scripts/topics/*.yaml` configs, determine which qualify per schedule and current day, run each via `run-topic.sh TOPIC` sequentially, then perform a single `git add / commit / push`.

FR9: Before running any topic, the orchestrator must check if `src/content/THEME/YYYY-MM-DD.md` already exists. If it does, skip with a log message.

FR10: No topics run on Sundays (day-of-week = 7). The orchestrator enforces this globally.

FR11: Each topic must have a dedicated synthesis prompt at `scripts/prompts/TOPIC.md`. The existing `digest-prompt.md` content moves to `scripts/prompts/ai.md`. New prompts are created for leadership, richmond, and local-llm.

FR12: Each prompt must instruct Claude to: check date, check if output file exists (idempotency), generate digest with Astro frontmatter, write to `src/content/THEME/DATE.md`. Claude does NOT commit — the orchestrator handles git.

FR13: If one topic's fetch or synthesis fails, the orchestrator must log the error, continue processing remaining topics, and include all successfully generated content in the final git commit.

FR14: The Astro site must add a `local-llm` content collection: update `src/content.config.ts` (add to theme enum + define collection), create `src/content/local-llm/` directory, update `src/pages/index.astro` (add theme card, include in allEntries for Watchlist/cadence), update `src/pages/watchlist.astro` (add getCollection + allEntries).

FR15: The `.claude/settings.json` allow list must add: `Write(src/content/richmond/*)`, `Write(src/content/leadership/*)`, `Write(src/content/local-llm/*)`.

FR16: The macOS launchd plist installed by `install-schedule.sh` must point to `run-all-topics.sh` instead of `run-digest.sh`.

FR17: The Python venv creation step must install `pyyaml` alongside `httpx feedparser beautifulsoup4`.

### NonFunctional Requirements

NFR1: Full Saturday run (4 topics) must complete within 15 minutes. Daily AI-only run must complete within 5 minutes.

NFR2: The pipeline must run entirely unattended with zero interactive prompts. `--dangerously-skip-permissions` and `.claude/settings.json` pre-approvals must cover all required operations.

NFR3: All generated markdown files must pass Astro content collection schema validation on `npm run build`.

NFR4: Running the pipeline twice in the same day must produce identical output — second run skips all topics because output files already exist.

NFR5: The existing `run-digest.sh` and `digest-prompt.md` must remain functional as a fallback.

NFR6: The existing Astro `digestSchema` must remain unchanged. New topic prompts map action semantics to existing `try[]`, `share[]`, `readDeeper[]`, `skip[]` fields — no structural schema changes in v2.

### Additional Requirements

- **No starter template** — enhancement of an existing running project; every story must verify AI digest regression-free.
- **pyyaml dependency** — add to venv install in `run-topic.sh` alongside existing deps.
- **Subshell isolation** — each `run-topic.sh TOPIC` call runs in a subshell `(bash run-topic.sh TOPIC)` so failure in one topic does not exit the orchestrator.
- **Git operations** — handled exclusively by `run-all-topics.sh`; never by `run-topic.sh` or synthesis prompts.
- **Log file naming** — fetched content files: `fetched-YYYY-MM-DD-TOPIC.txt`.
- **Backward compatibility** — `run-digest.sh` and `digest-prompt.md` must not be deleted or broken.

### UX Design Requirements

Not applicable — no UX design specification. Site changes are additive (~15 lines across 2 files + 1 new directory) following existing Astro patterns exactly.

### FR Coverage Map

| FR | Epic | Story |
|----|------|-------|
| FR1, FR2 | 1 | 1.1 — ai.yaml schema + all 14 sources |
| FR3, FR17 | 1 | 1.2 — fetch_sources.py --topic flag + pyyaml |
| FR4 | 1 | 1.1 + 1.2 — AI sources in yaml + script reads them |
| FR8, FR9, FR10, FR13 | 1 | 1.4 — run-all-topics.sh orchestrator |
| FR11, FR12 (ai) | 1 | 1.3 — scripts/prompts/ai.md + run-topic.sh |
| FR16 | 1 | 1.5 — install-schedule.sh update |
| FR5, FR11/12 (leadership) | 2 | 2.1 — leadership config + prompt |
| FR6, FR11/12 (richmond) | 2 | 2.2 — richmond config + prompt |
| FR7, FR11/12 (local-llm) | 3 | 3.1 — local-llm config + prompt |
| FR14 | 3 | 3.2 + 3.3 — Astro collection + site pages |
| FR15 | 4 | 4.1 — .claude/settings.json |
| NFR1–NFR6 | 4 | 4.2 — E2E live test validates all NFRs |
| FR-E01–FR-E13 | 5 | 5.1–5.3 — Richmond Events pipeline + site wiring + E2E test |

### Richmond Events FR Inventory (Epic 5)

FR-E01: A 30-day forward window must be applied from the Saturday run date. Events occurring in the past must never appear in the digest. Events occurring on TODAY or TODAY+1 belong in the `richmond` news digest, not `rva-events`.

FR-E02: Sources and synthesis must apply distance weighting in priority order: (1) RVA — Richmond city proper + Henrico, Chesterfield, Midlothian; (2) Metro — Hanover, Colonial Heights, Petersburg, Hopewell; (3) Extended Metro — Charlottesville, Williamsburg, Fredericksburg (≤60 min drive + exceptional events only); (4) VA-Wide — only if Capital One community or major RVA tech significance, noting distance explicitly.

FR-E03: In-scope event categories: family/kids, arts/culture, food/dining events, tech meetups, outdoor/parks, community festivals, civic/political events with direct access to elected officials (hackathons, listening sessions, public forums) — capped at 1–2 items per digest.

FR-E04: Out-of-scope (drop silently): sports scores/schedules, pure partisan fundraisers (campaign rallies, party galas), generic charity 5Ks with no community draw, events outside the distance zones, past events.

FR-E05: Sparsity fallback: if RVA events total < 4, expand to Metro zone; if < 2 RVA events, lead TL;DR with "Light event calendar" and pull in Extended Metro exceptional events; if < 2 of any zone, note "Quiet month for events" and output VA-wide tech/Capital One items if any.

FR-E06: The `richmond-events` topic must run on Saturdays only (`schedule: weekly`). The orchestrator's existing weekly schedule logic handles this automatically.

FR-E07: ~~Output must be structured chronologically within week buckets (This Week, Next Weekend, Coming Up weeks 3–4) — NOT organized by event category.~~ → **REVISED (delivered):** Output is organized Week 1–4 buckets first, then category sub-sections within each week (Family/Kids, Arts/Culture, Food/Dining, Tech/Professional, Outdoor/Parks, Civic), then chronologically within each category. Week 1 starts the Monday after the run date (TODAY+2).

FR-E08: A separate Astro content collection `rva-events` must be created, distinct from the existing `richmond` collection. The nav label is "RVA Events".

FR-E09: The existing `digestSchema` must be used unchanged. Action semantics: `try[]` ← ATTEND / BRING FAMILY items; `share[]` ← SHARE items (`{what, who}` shape, `who` = "team" or "family"); `readDeeper[]` ← BOOK NOW urgency items; `skip[]` ← SKIP items.

FR-E10: Deduplication boundary: events occurring on the Saturday run date (TODAY) or Sunday (TODAY+1) belong in the `richmond` news digest and must be excluded from `rva-events`.

FR-E11: `scripts/topics/richmond-events.yaml` must define 14 sources across 3 tiers: tier1 (3 RVA RSS feeds with event `filter_regex`), tier2 (7 venue HTML calendars: VMFA, Maymont, The Valentine, SMV, Hardywood, Strangeways, Capital One Hall), tier3 (4 community aggregators: Visit Richmond, Richmond Family, RVAtech, Startup Virginia).

FR-E12: Six Astro files must be updated to wire the `rva-events` collection into the site: `src/content.config.ts`, `src/layouts/Layout.astro`, `src/pages/index.astro`, `src/pages/watchlist.astro`, `src/pages/[theme]/index.astro`, `src/pages/[theme]/[slug].astro`.

FR-E13: `scripts/prompts/richmond-events.md` must contain: WHO PRIYESH IS context, distance weighting rules, category include/exclude rules (with civic/political at ≤2 cap), sparsity fallback rules, date-primary chronological output structure, item format (`**[Name](url)** — what | Day Mon DD, TIME | Venue, Neighborhood | cost | why. [TAG]`), action tag definitions, required frontmatter template, and STEP 1–3 (no git operations).

---

## Epic List

### Epic 1: AI Digest Config-Driven — Zero Regression
Refactor the existing AI pipeline to be fully config-driven. After this epic, the AI digest runs identically to v1 AND the pipeline accepts new topics via YAML file alone — no Python code changes required.
**FRs covered:** FR1, FR2, FR3, FR4, FR8, FR9, FR10, FR11 (ai.md), FR12 (ai), FR13, FR16, FR17

### Epic 2: Weekend Briefing — Leadership + Richmond Live
Add Leadership and Richmond topic configs and synthesis prompts. After this epic, every Saturday Priyesh automatically receives Engineering Leadership and Richmond & Virginia digests alongside the daily AI digest.
**FRs covered:** FR5, FR6, FR11 (leadership + richmond), FR12 (leadership + richmond)

### Epic 3: Full Dashboard — Local LLM Digest + Site Complete
Add the Local LLM topic and wire it into the Astro site. After this epic, all four topic feeds have theme cards, watchlist entries, and cadence tracking on priyesh.fyi.
**FRs covered:** FR7, FR11 (local-llm), FR12 (local-llm), FR14

### Epic 4: Autonomous Release
Update permissions, reinstall the schedule, and run the full E2E live test. After this epic, the system runs autonomously every night with zero manual intervention required.
**FRs covered:** FR15, NFR1–NFR6

### Epic 5: RVA Events — Forward-Looking Event Calendar
Add a new `rva-events` topic that publishes a weekly 30-day forward event calendar for Richmond, VA — family activities, tech meetups, arts/dining, and civic events with direct access to city leadership. After this epic, Priyesh receives a Saturday digest of upcoming RVA events alongside the existing news/professional feeds.
**FRs covered:** FR-E01 through FR-E13

---

## Epic 1: AI Digest Config-Driven — Zero Regression

**Goal:** Extract the hardcoded AI source list into `scripts/topics/ai.yaml`, update `fetch_sources.py` to read sources from YAML, create a parameterized `run-topic.sh TOPIC`, build the `run-all-topics.sh` orchestrator, and move the synthesis prompt to `scripts/prompts/ai.md`. Every story must leave the AI digest working. After this epic the full extensibility infrastructure exists.

### Story 1.1: Create AI Topic YAML Config and Migrate Prompt

As a developer,
I want the AI sources defined in `scripts/topics/ai.yaml` and the synthesis prompt at `scripts/prompts/ai.md`,
So that AI topic configuration is data-driven and no Python code needs changing to modify sources.

**Acceptance Criteria:**

**Given** `scripts/topics/ai.yaml` is created
**When** the file is parsed as YAML
**Then** it contains `name: "AI Intelligence"`, `theme: ai`, `schedule: daily`, `output_collection: ai`, `prompt: scripts/prompts/ai.md`
**And** `sources.tier1` contains 8 entries: Claude Code Releases (releasebot), Anthropic Releases (releasebot), OpenAI Releases (releasebot), AWS ML Blog (rss), Google AI Blog (rss), DeepMind Blog (html), Mistral News (html), DeepSeek (html)
**And** `sources.tier2` contains 4 entries: Simon Willison (rss), Import AI (rss), Latent Space (rss), The Batch (html)
**And** `sources.tier3` contains 2 entries: Hacker News (rss, filter_regex for AI terms, filter_cap: 3), GitHub Trending (github)
**And** every source entry has `name`, `kind`, `url`, `max_items`

**Given** `scripts/prompts/ai.md` is created
**When** its content is compared to the existing `scripts/digest-prompt.md`
**Then** the WHO PRIYESH IS, VOICE, FILTERING, OUTPUT FORMAT, ACTION TAGS, and STEP 1–3 sections are identical or functionally equivalent
**And** Step 3 (commit) in `prompts/ai.md` instructs Claude to write the file only — NOT to git add/commit/push (that's the orchestrator's job)

**Given** `scripts/digest-prompt.md` still exists
**When** the file is checked
**Then** it is unchanged (backward compatibility preserved)

**Dev Notes:**
- Source list reference: see `scripts/fetch_sources.py` TIER1/TIER2/TIER3 variables for exact current source list to migrate
- The `digest-prompt.md` Step 3 currently says `git add → commit → push`. In `prompts/ai.md`, change Step 3 to only `Write to src/content/ai/DATE.md` — git operations move to the orchestrator in Story 1.4
- YAML format reference: see `scripts/topics/ai.yaml` in `.claude/planning/architecture.md` Appendix A for the full expected YAML structure
- Do NOT modify `fetch_sources.py` in this story — that's Story 1.2

---

### Story 1.2: Update fetch_sources.py for Config-Driven Sources

As a developer,
I want `fetch_sources.py` to accept `--topic TOPIC` and load sources from the corresponding YAML config,
So that a single script serves all topics without duplicating fetch logic.

**Acceptance Criteria:**

**Given** `scripts/topics/ai.yaml` exists and pyyaml is installed in the venv
**When** `$VENV/bin/python3 scripts/fetch_sources.py --topic ai` is run
**Then** it produces output with `### [Source Name] — N items` headers for all 14 sources
**And** total item count is ≥ 30
**And** output format is identical to the current hardcoded version

**Given** a topic YAML has a source with `filter_regex: "foo|bar"` and `filter_cap: 3`
**When** `fetch_sources.py` processes that source
**Then** only items whose title or summary matches the regex are included
**And** the result is capped at 3 items maximum

**Given** `--weekly` flag is passed alongside `--topic ai`
**When** `fetch_sources.py --topic ai --weekly` runs
**Then** the 7-day lookback window is applied (existing `IS_WEEKLY` behavior)

**Given** a missing or invalid topic name is passed (e.g. `--topic nonexistent`)
**When** the script runs
**Then** it exits with a clear error message referencing the missing config file

**Given** the venv creation block in `run-topic.sh` (or its future equivalent)
**When** the venv is created or re-used
**Then** `pyyaml` is listed in the pip install command alongside `httpx feedparser beautifulsoup4`

**Dev Notes:**
- Modify only `main()` and argument parsing — all `fetch_rss()`, `fetch_html()`, `fetch_releasebot()`, `fetch_github_trending()` functions stay untouched
- Replace `IS_WEEKLY = "--weekly" in sys.argv` with `argparse`; keep `--weekly` flag behavior identical
- Build tier lists dynamically from `config["sources"].get("tier1", [])` etc.
- The `filter_regex` and `filter_cap` fields on a source entry replace the current hardcoded HN filter block in `main()`
- Test by running: `scripts/.venv/bin/python3 scripts/fetch_sources.py --topic ai 2>&1 | grep "###"` — should show all 14 source headers
- pyyaml install: modify the pip install line in `run-digest.sh` (or create `run-topic.sh` in Story 1.3 with the updated install)

---

### Story 1.3: Create run-topic.sh (Parameterized Single-Topic Runner)

As a developer,
I want a `run-topic.sh TOPIC` script that runs any single topic end-to-end,
So that each topic can be tested independently and the orchestrator has a clean primitive to call.

**Acceptance Criteria:**

**Given** `scripts/run-topic.sh ai` is invoked directly
**When** it runs end-to-end on a weekday
**Then** it creates the venv with pyyaml if not present
**And** fetches sources via `fetch_sources.py --topic ai` writing to `fetched-DATE-ai.txt`
**And** synthesizes via `scripts/prompts/ai.md` (not `digest-prompt.md`)
**And** a file `src/content/ai/YYYY-MM-DD.md` is written with valid Astro frontmatter
**And** logs are appended to `scripts/logs/YYYY-MM-DD.log`
**And** no git operations are performed

**Given** `scripts/run-topic.sh leadership` is invoked with no --weekly flag on a weekday
**When** it runs
**Then** it proceeds to fetch and synthesize (schedule enforcement is the orchestrator's job, not run-topic.sh)

**Given** `scripts/run-digest.sh` still exists after this story
**When** `bash scripts/run-digest.sh` is run
**Then** it still works correctly (either unchanged, or updated to delegate to `run-topic.sh ai`)

**Given** `fetch_sources.py` returns 0 items (all sources fail)
**When** `run-topic.sh` checks the item count
**Then** it exits with an error logged: "ERROR: No content fetched" and no Claude invocation occurs

**Dev Notes:**
- Base this on `run-digest.sh` — it already has venv setup, PATH export, Claude binary detection, logging
- Key changes from `run-digest.sh`: (1) `TOPIC=$1` positional arg, (2) `CONTENT_FILE` uses topic suffix `fetched-DATE-$TOPIC.txt`, (3) prompt path is `scripts/prompts/$TOPIC.md`, (4) remove the `git add/commit/push` block entirely — orchestrator handles this, (5) add pyyaml to pip install line
- The `--weekly` detection: pass `$WEEKLY_FLAG` through if today is Saturday OR allow caller to pass it explicitly. Keep `DAY_OF_WEEK=$(date +%u)` for the Saturday check
- Backward compat: either leave `run-digest.sh` untouched, OR have it call `run-topic.sh ai` and re-add the git operations. Former is simpler.
- Test: `bash scripts/run-topic.sh ai` — should produce `src/content/ai/$(date +%Y-%m-%d).md`

---

### Story 1.4: Create run-all-topics.sh Master Orchestrator

As Priyesh,
I want a single script that automatically runs all configured topics per their schedules each night,
So that one launchd invocation handles all topics with one git commit and correct schedule enforcement.

**Acceptance Criteria:**

**Given** it is a weekday (Mon–Fri, `date +%u` = 1–5) and `run-all-topics.sh` is run
**When** it discovers `topics/ai.yaml` (schedule: daily) and `topics/leadership.yaml` (schedule: weekly)
**Then** only the AI topic runs
**And** leadership is skipped with log: "Weekday — skipping weekly topic: leadership"

**Given** it is Saturday (`date +%u` = 6) and all 4 topic configs exist
**When** `run-all-topics.sh` runs
**Then** all 4 topics run sequentially: ai → leadership → richmond → local-llm
**And** a single `git commit -m "digest: YYYY-MM-DD [automated]"` is made containing all 4 content files
**And** the commit is pushed to origin main

**Given** it is Sunday (`date +%u` = 7)
**When** `run-all-topics.sh` runs
**Then** it logs "Sunday — no topics run" and exits 0 immediately

**Given** `src/content/ai/2026-05-17.md` already exists and today is 2026-05-17
**When** `run-all-topics.sh` runs
**Then** the AI topic is skipped with log: "ai: output exists — skipping"
**And** other qualifying topics still run if their output files don't exist

**Given** the leadership fetch fails with an error during a Saturday run
**When** `run-all-topics.sh` continues
**Then** AI, Richmond, and Local LLM topics still run and their files are committed
**And** the final log line includes: "FAILED topics: leadership"

**Given** no topics generate new content (all skipped or failed)
**When** `run-all-topics.sh` completes
**Then** no git commit is made and log shows: "No new content to commit"

**Dev Notes:**
- Use `scripts/.venv/bin/python3 -c "import yaml; ..."` to read THEME and SCHEDULE from each YAML config (venv already has pyyaml after Story 1.2)
- Topic discovery: `for config in "$TOPICS_DIR"/*.yaml` — processes in filesystem order (alphabetical: ai, leadership, local-llm, richmond)
- Subshell isolation: `(bash "$REPO_DIR/scripts/run-topic.sh" "$TOPIC")` — parentheses create subshell so `set -e` failure doesn't kill the orchestrator
- Failure tracking: use `FAILED_TOPICS=""` accumulator; append `"$FAILED_TOPICS $TOPIC"` on subshell exit code != 0
- Git diff check before commit: `git -C "$REPO_DIR" diff --quiet HEAD -- src/content/` — only commit if there are changes
- Full orchestrator template: see architecture.md section "run-all-topics.sh — New Orchestrator" for the reference implementation

---

### Story 1.5: Update install-schedule.sh to Point to run-all-topics.sh

As Priyesh,
I want the launchd schedule to invoke `run-all-topics.sh` instead of `run-digest.sh`,
So that the nightly automation handles all topics from tonight forward.

**Acceptance Criteria:**

**Given** `bash scripts/install-schedule.sh` is run
**When** the plist file is written to `~/Library/LaunchAgents/`
**Then** the `ProgramArguments` array in the plist references `run-all-topics.sh`
**And** it does NOT reference `run-digest.sh`

**Given** the plist is loaded via `launchctl load -w`
**When** `launchctl list | grep priyesh` is run
**Then** the agent appears as registered with a non-null last exit code field

**Given** `bash scripts/install-schedule.sh --uninstall` is run
**When** it completes
**Then** the plist is unloaded and the file is removed from `~/Library/LaunchAgents/`

**Given** the existing launchd agent was previously installed pointing to `run-digest.sh`
**When** `install-schedule.sh` is run again
**Then** the old agent is unloaded before the new one is installed (idempotent reinstall)

**Dev Notes:**
- `install-schedule.sh` currently generates a plist with `run-digest.sh` in the `ProgramArguments`. Change that one reference to `run-all-topics.sh`
- The `--uninstall` path, plist name, timing (Hour=23, Minute=0), and all other plist fields stay unchanged
- To reinstall safely: the script should `launchctl unload` the existing plist if it exists before writing the new one
- Test: after running install-schedule.sh, `cat ~/Library/LaunchAgents/fyi.priyesh.daily-digest.plist | grep ProgramArguments -A3` should show `run-all-topics.sh`

---

## Epic 2: Weekend Briefing — Leadership + Richmond Live

**Goal:** Add Leadership and Richmond topic configs and synthesis prompts. Both topics use existing Astro collections (no site changes needed). After this epic, every Saturday run produces three digests: AI (daily), Leadership (weekly), Richmond (weekly).

### Story 2.1: Leadership Topic Config and Synthesis Prompt

As Priyesh,
I want a weekly Leadership digest sourced from EM-focused publications,
So that I get actionable engineering management signal in ≤20 min every Saturday morning.

**Acceptance Criteria:**

**Given** `scripts/topics/leadership.yaml` is created
**When** parsed as YAML
**Then** it contains `theme: leadership`, `schedule: weekly`, `output_collection: leadership`, `prompt: scripts/prompts/leadership.md`
**And** `sources.tier1` includes at minimum: LeadDev (`https://leaddev.com/feed/`, rss), Will Larson (`https://lethain.com/feeds.xml`, rss), Charity Majors (`https://charity.wtf/feed/`, rss)
**And** `sources.tier2` includes: The Pragmatic Engineer, Lara Hogan, First Round Review, Manager Tools (all rss)
**And** `sources.tier3` includes Hacker News (rss) with `filter_regex` containing EM keywords and `filter_cap: 3`, plus r/ExperiencedDevs (rss), r/Engineering_Manager (rss)

**Given** `bash scripts/run-topic.sh leadership` is run (simulating Saturday with `--weekly` if needed)
**When** it completes successfully
**Then** `src/content/leadership/YYYY-MM-DD.md` exists with valid Astro frontmatter
**And** frontmatter `theme` is `leadership`, `format` is `weekly-synthesis`
**And** `actions.try[]` is non-empty and contains APPLY-style items (1:1 or staff meeting techniques)
**And** `actions.share[]` items have `who` from: "engineering team", "leadership", "all teams"
**And** `itemCount` is ≥ 3

**Given** `scripts/prompts/leadership.md` is reviewed
**When** its content is checked
**Then** it contains: WHO PRIYESH IS section with EM/Capital One context, KEEP rules (EM techniques, agentic org, SDLC governance, hiring), DROP rules (startup founder advice, generic empathy content), action tag definitions for APPLY IN 1:1 and BRING TO STAFF MEETING, weekly-synthesis output format section
**And** Step 2 (Write file) targets `src/content/leadership/DATE.md`
**And** Step 3 instructs Claude to write file only — no git operations

**Dev Notes:**
- Model this prompt on `scripts/prompts/ai.md` — same structure (WHO PRIYESH IS, VOICE, FILTERING, OUTPUT FORMAT, ACTION TAGS, STEP 1–3) but with leadership-specific content
- KEEP/DROP/MENTION rules: reference the Leadership section of `.claude/plans/daily-kickoff/daily-kickkoff-generator-routine/PROPOSAL.md` §2.2 for exact rules and rationale
- Action tag mapping to schema fields: `try[]` = APPLY items, `share[]` = SHARE items, `readDeeper[]` = READ DEEPER, `skip[]` = SKIP
- HN filter keywords: `engineering manager|EM|1:1|staff meeting|team lead|agentic|SDLC|sprint|retro|hiring|performance review|org design|skip.?level`
- Test by checking `npm run build` succeeds after the file is generated (schema validation)

---

### Story 2.2: Richmond Topic Config and Synthesis Prompt

As Priyesh,
I want a weekly Richmond & Virginia digest sourced from local news and events feeds,
So that I know what's happening locally for weekend planning and professional networking.

**Acceptance Criteria:**

**Given** `scripts/topics/richmond.yaml` is created
**When** parsed as YAML
**Then** it contains `theme: richmond`, `schedule: weekly`, `output_collection: richmond`, `prompt: scripts/prompts/richmond.md`
**And** `sources.tier1` (RVA zone) includes: Richmond BizSense (`https://richmondbizsense.com/feed`, rss), Richmond Magazine (`https://richmondmagazine.com/api/rss/content.rss`, rss), Style Weekly (`https://www.styleweekly.com/feed`, rss), RICtoday (`https://rictoday.6amcity.com/latest-news-rss`, rss)
**And** `sources.tier2` includes: Richmond Times-Dispatch, Small Richmond, WRIC (rss sources), Virginia Mercury, Virginia Business (VA zone, rss)
**And** `sources.tier3` includes: Visit Richmond VA (html), Richmond Family Magazine (html), RVAtech Events (html)

**Given** `bash scripts/run-topic.sh richmond` is run (with `--weekly`)
**When** it completes
**Then** `src/content/richmond/YYYY-MM-DD.md` exists with valid Astro frontmatter
**And** `theme` is `richmond`, `format` is `weekly-synthesis`
**And** `actions.try[]` contains ATTEND or BRING FAMILY items
**And** `actions.readDeeper[]` contains WATCH items for local development/policy

**Given** `scripts/prompts/richmond.md` is reviewed
**When** its content is checked
**Then** it contains: distance-weighting rule (Richmond city/Henrico/Chesterfield always first; VA-wide only if RVA items < 4), sparsity fallback rule, KEEP rules (tech events, family activities, dining, development, Capital One–relevant business news), DROP rules (crime, weather, sports, national politics with Richmond dateline), ATTEND/BRING FAMILY/WATCH/SHARE action tag definitions
**And** targets `src/content/richmond/DATE.md` with no git operations

**Dev Notes:**
- KEEP/DROP rules: reference PROPOSAL.md §2.4 Richmond section for exact rules
- Sparsity rule verbatim: "If Richmond-specific items total fewer than 4, expand to include Virginia-wide items. If fewer than 2 Richmond items exist, lead TL;DR with 'Quiet week locally.'"
- Distance zone labeling: prompt should ask Claude to note zone in item summaries when surfacing Virginia-wide items ("VA-wide:" prefix)
- The Visit Richmond VA, Richmond Family Magazine, and RVAtech sources are HTML — the `fetch_html` function handles them; no custom scrapers needed
- Test: run `fetch_sources.py --topic richmond --weekly` and verify ≥ 5 items are returned from Richmond-specific sources

---

## Epic 3: Full Dashboard — Local LLM Digest + Site Complete

**Goal:** Add the Local LLM topic and wire it into the Astro site. After this epic all four topics show on the dashboard, and priyesh.fyi is feature-complete for v2.

### Story 3.1: Local LLM Topic Config and Synthesis Prompt

As Priyesh,
I want a weekly Local LLM digest covering the local inference stack and Gods of the Future Past tooling,
So that I track the consumer-hardware LLM ecosystem relevant to my side project without cloud token spend.

**Acceptance Criteria:**

**Given** `scripts/topics/local-llm.yaml` is created
**When** parsed as YAML
**Then** it contains `theme: local-llm`, `schedule: weekly`, `output_collection: local-llm`, `prompt: scripts/prompts/local-llm.md`
**And** `sources.tier1` includes: r/LocalLLaMA (`https://www.reddit.com/r/LocalLLaMA.rss`, rss, filter_cap: 5), Ollama releases (`https://github.com/ollama/ollama/releases.atom`, rss), llama.cpp releases (`https://github.com/ggerganov/llama.cpp/releases.atom`, rss), Open WebUI releases (`https://github.com/open-webui/open-webui/releases.atom`, rss)
**And** `sources.tier2` includes: Simon Willison (rss, filter_regex for local LLM terms), HuggingFace Blog (rss, filter_regex), LM Studio (`https://lmstudio.ai/blog`, html)
**And** `sources.tier3` includes: GitHub Trending Python (`https://github.com/trending/python?since=weekly`, html), Hacker News (rss, filter_regex for local LLM terms, filter_cap: 3)

**Given** `bash scripts/run-topic.sh local-llm` is run (with `--weekly`)
**When** it completes
**Then** `src/content/local-llm/YYYY-MM-DD.md` exists with valid Astro frontmatter
**And** `theme` is `local-llm`, `format` is `weekly-synthesis`
**And** `actions.try[]` contains BUILD THIS WEEKEND, BENCHMARK, or UPGRADE items
**And** `actions.share[]` is empty (personal topic — nothing to share with teams)

**Given** `scripts/prompts/local-llm.md` is reviewed
**Then** it contains: Gods of the Future Past context (local inference for mythology content), hardware context (96GB Mac), KEEP rules (Ollama/llama.cpp/Open WebUI releases, quantization advances, consumer hardware benchmarks, local RAG patterns), DROP rules (cloud-only releases, training guides, academic papers without runnable implementation), BUILD THIS WEEKEND/BENCHMARK/UPGRADE action tag definitions
**And** `actions.share[]` note: "Leave share[] empty for this topic — these are personal actions, not team-share items"

**Dev Notes:**
- Local LLM filter regex (for Simon, HuggingFace, HN): `\b(local.?llm|llama\.cpp|ollama|gguf|ggml|lm.?studio|open.?webui|mlx|quantiz|consumer.?gpu|96GB|apple.?silicon|inference.?speed|tokens.?per.?second)\b`
- The r/LocalLLaMA feed is RSS but Reddit RSS returns 25 items — use filter_cap: 5 to keep top 5 hot posts
- GitHub Trending Python page is HTML — fetch_html handles it; the existing github-trending fetcher targets AI repos, so the local-llm config uses the python-filtered trending URL instead
- Note in prompt: "If no local-llm items exist (all sources failed), print 'No local LLM signal this week' and skip file creation"
- Test: `fetch_sources.py --topic local-llm --weekly 2>&1 | grep "###"` — should show all 9 source headers

---

### Story 3.2: Add local-llm Astro Content Collection

As a developer,
I want `src/content/local-llm/` recognized as an Astro content collection,
So that local-llm digest files are schema-validated and available to site pages.

**Acceptance Criteria:**

**Given** `src/content.config.ts` is updated and `src/content/local-llm/` directory exists
**When** `npm run build` is run with an empty `local-llm/` directory
**Then** the build succeeds with no TypeScript or Zod schema errors

**Given** `src/content.config.ts` is updated
**When** the theme enum is inspected
**Then** it contains exactly: `z.enum(['ai', 'leadership', 'local-llm', 'mythology', 'richmond'])`

**Given** a test file `src/content/local-llm/test.md` is added with valid digestSchema frontmatter
**When** `npm run build` is run
**Then** the build succeeds and the file is included in the Astro content collection

**Given** `src/content/local-llm/` does not yet contain any digest files
**When** `npm run build` is run
**Then** the build still succeeds (empty collection is valid)

**Dev Notes:**
- Only two changes to `src/content.config.ts`: (1) add `'local-llm'` to the theme enum string array, (2) add the collection definition following the exact same pattern as the other 4 collections
- Create `src/content/local-llm/.gitkeep` so the empty directory is tracked in git
- Run `npm run build` after changes to confirm — the existing Zod `digestSchema` is reused unchanged
- Reference: see architecture.md §"content.config.ts" for the exact TypeScript snippet to add

---

### Story 3.3: Add Local LLM Theme Card to index.astro and watchlist.astro

As Priyesh,
I want the Local LLM topic visible on my dashboard with a theme card, watchlist entries, and cadence tracking,
So that local-llm digests are displayed alongside AI, Leadership, and Richmond on priyesh.fyi.

**Acceptance Criteria:**

**Given** `src/pages/index.astro` is updated
**When** the home page is built
**Then** a "Local LLM" theme card appears in the `themeCards` array with `id: 'local-llm'`, `label: 'Local LLM'`, and `emptyNote: 'Local inference stack updates and Gods project tooling.'`
**And** when a local-llm digest exists, the card shows the latest entry's tldr (truncated to 130 chars), date, and format
**And** local-llm `try[]`, `share[]`, `readDeeper[]` action items appear in the Watchlist section
**And** local-llm digest dates appear in the 21-day cadence dots

**Given** `src/pages/watchlist.astro` is updated
**When** the watchlist page is built
**Then** local-llm action items appear with `source` labeled `"Local LLM · [date]"`
**And** done/snooze state works for local-llm items (same localStorage key pattern as other topics)

**Given** `npm run build` is run after both files are updated
**Then** the build succeeds with no errors

**Given** `src/content/local-llm/` is empty
**When** the home page builds
**Then** the Local LLM theme card shows the empty-state note with `count: 0 digests`

**Dev Notes:**
- `index.astro` changes: (1) add `const localLlmEntries = await getCollection('local-llm');` alongside the other getCollection calls, (2) add the themeCards entry, (3) add `...localLlmEntries.map(e => ({ ...e, themeId: 'local-llm', themeLabel: 'Local LLM' }))` to the `allEntries` spread
- `watchlist.astro` changes: same pattern — add getCollection call and spread into allEntries
- Reference: see architecture.md §"index.astro" for exact TypeScript snippets
- The `[theme]/index.astro` and `[theme]/[slug].astro` dynamic routes automatically handle the new theme value — no changes needed there
- Test: add a dummy `src/content/local-llm/2026-01-01.md` with valid frontmatter, run `npm run build`, check the build output includes the local-llm route

---

## Epic 4: Autonomous Release

**Goal:** Lock in permissions, reinstall the schedule, and validate the complete system via a live E2E test. After this epic the system requires zero manual intervention.

### Story 4.1: Update .claude/settings.json Permissions

As Priyesh,
I want Claude pre-authorized to write to all four content collections,
So that the nightly synthesis runs without permission prompts for leadership, richmond, and local-llm.

**Acceptance Criteria:**

**Given** `.claude/settings.json` is updated
**When** the `permissions.allow` array is inspected
**Then** it contains all of the following entries:
  - `"Write(src/content/ai/*)"`
  - `"Write(src/content/leadership/*)"`
  - `"Write(src/content/richmond/*)"`
  - `"Write(src/content/local-llm/*)"`
**And** all existing permissions are unchanged: `WebFetch(*)`, `Bash(date *)`, `Bash(ls src/content/**)`, `Bash(git add src/content/**)`, `Bash(git commit *)`, `Bash(git push origin main)`, `Bash(git status)`

**Dev Notes:**
- File is at `daily-kickoff/site/.claude/settings.json`
- Add exactly 3 new `Write` entries to the existing allow array; do not reorder or remove existing entries
- Verify by running `cat .claude/settings.json | python3 -m json.tool` to confirm valid JSON after edit

---

### Story 4.2: End-to-End Live Test — All Four Topics

As Priyesh,
I want to run the complete Saturday pipeline manually and verify all four digests generate, commit, and deploy,
So that I can confirm autonomous operation before relying on the nightly schedule.

**Acceptance Criteria:**

**Given** all Epics 1–3 stories are complete and `run-all-topics.sh` is run on a Saturday (or with Saturday simulation)
**When** the run completes
**Then** four files exist: `src/content/ai/DATE.md`, `src/content/leadership/DATE.md`, `src/content/richmond/DATE.md`, `src/content/local-llm/DATE.md`
**And** each file has a valid Astro frontmatter block with all required fields: `title`, `date`, `theme`, `format`, `tldr`, `itemCount`, `readTimeMinutes`, `sources`, `actions`
**And** `npm run build` succeeds after the files are written
**And** a single git commit containing all four files is pushed to origin main
**And** the GitHub Actions deploy workflow completes with a green check
**And** the deployed site at priyesh.fyi shows all four theme cards with content

**Given** the total wall-clock time from script start to git push
**When** measured
**Then** it is ≤ 15 minutes (NFR1)

**Given** `run-all-topics.sh` is run a second time on the same day immediately after
**When** it completes
**Then** all four topics log "output exists — skipping"
**And** no new git commit is made
**And** the script exits 0 (NFR4)

**Dev Notes:**
- To simulate Saturday on a weekday for testing: temporarily edit the `DAY_OF_WEEK` check in `run-all-topics.sh` to hardcode `6`, or run each topic manually: `bash scripts/run-topic.sh leadership` etc.
- Validate frontmatter: `python3 -c "import yaml; f=open('src/content/leadership/DATE.md'); content=f.read(); fm=content.split('---')[1]; yaml.safe_load(fm); print('OK')"`
- GitHub Actions: check at `https://github.com/peacepirate/daily-kickoff/actions` — the `deploy.yml` workflow should trigger and turn green within ~3 minutes of push
- If any topic generates a file with invalid frontmatter, `npm run build` will fail with a Zod validation error — use that output to identify the issue
- Document timing results in the story's Dev Agent Record for future reference

---

### Story 4.3: Reinstall launchd Schedule and Validate Autonomous Operation

As Priyesh,
I want the launchd agent reinstalled pointing to `run-all-topics.sh` and confirmed working,
So that all four topics run automatically every night without any manual action.

**Acceptance Criteria:**

**Given** `bash scripts/install-schedule.sh` is run after Story 1.5 is complete
**When** `launchctl list | grep priyesh` is run
**Then** the agent `fyi.priyesh.daily-digest` appears as registered

**Given** the installed plist is inspected via `cat ~/Library/LaunchAgents/fyi.priyesh.daily-digest.plist`
**When** the `ProgramArguments` array is checked
**Then** it contains `run-all-topics.sh` and does NOT contain `run-digest.sh`

**Given** the launchd agent fires at 11pm on a weekday
**When** `scripts/logs/YYYY-MM-DD.log` is checked the next morning
**Then** it shows a successful AI digest run with no FAILED topics line

**Given** the launchd agent fires at 11pm on a Saturday
**When** the log is checked Sunday morning
**Then** it shows all four topics ran successfully and a single commit was pushed

**Dev Notes:**
- Run: `bash scripts/install-schedule.sh --uninstall && bash scripts/install-schedule.sh`
- Verify registration: `launchctl list | grep priyesh` — should show the agent with PID or last-exit 0
- The log file path is `scripts/logs/$(date +%Y-%m-%d).log` — check it the morning after the first autonomous run
- If the agent fires but fails: check `scripts/logs/DATE.log` for errors; common issues are PATH not including claude binary or git credentials not configured
- After a successful autonomous weekday run, Story 4.3 is complete — the system is in production

---

## Epic 5: RVA Events — Forward-Looking Event Calendar

**Goal:** Add a new `rva-events` pipeline topic and Astro collection delivering a weekly 30-day forward calendar of Richmond-area events. After this epic, Priyesh automatically receives a Saturday digest of upcoming events — family activities, tech meetups, arts/dining, and civic events — organized chronologically by week and distance zone, as a distinct feed from the Richmond news digest.

### Story 5.1: RVA Events — Source Config & Synthesis Prompt

As Priyesh,
I want a `richmond-events` pipeline topic with 14 curated sources and a forward-looking synthesis prompt,
So that every Saturday I automatically receive a 30-day calendar of upcoming RVA events without any manual curation.

**Acceptance Criteria:**

**Given** `scripts/topics/richmond-events.yaml` is created
**When** parsed as YAML
**Then** it contains `name: richmond-events`, `theme: rva-events`, `schedule: weekly`, `output_collection: rva-events`, `prompt: scripts/prompts/richmond-events.md`
**And** `sources.tier1` includes 3 RVA RSS sources each with an event-focused `filter_regex`: Style Weekly Events, RICtoday Events, Richmond Magazine Events
**And** `sources.tier2` includes 7 venue HTML calendar pages: VMFA, Maymont, The Valentine, Science Museum of Virginia, Hardywood, Strangeways, Capital One Hall
**And** `sources.tier3` includes 4 community aggregators: Visit Richmond Events (html), Richmond Family Magazine Calendar (html), RVAtech Events (html), Startup Virginia Events (html)
**And** every source entry has `name`, `kind`, `url`, `max_items`

**Given** `scripts/prompts/richmond-events.md` is created
**When** its content is reviewed
**Then** it contains a WHO PRIYESH IS section with Richmond/family/tech/Capital One context
**And** it contains the 4-zone distance weighting rule (RVA → Metro → Extended Metro → VA-Wide) with explicit priority order
**And** it contains CATEGORIES — INCLUDE list: family/kids, arts/culture, food/dining, tech/professional, outdoor/parks, civic/political (at ≤2 items cap with "direct access to elected officials" qualifier)
**And** it contains CATEGORIES — DROP SILENTLY list: sports, pure partisan fundraisers, generic charity runs, out-of-zone events, past events
**And** it contains the deduplication rule: events on TODAY or TODAY+1 belong in `richmond` digest, not here
**And** it contains sparsity fallback rules (<4 RVA → expand to Metro; <2 → lead with "Light event calendar")
**And** it specifies date-primary chronological output with week buckets: "This Week", "Next Weekend", "Coming Up"
**And** it specifies item format: `**[Event Name](url)** — what | Day Mon DD, TIME | Venue, Neighborhood | cost | why. [TAG]`
**And** it defines action tags: [ATTEND] → `try[]`, [BRING FAMILY] → `try[]`, [BOOK NOW] → `readDeeper[]`, [SHARE w/ team] → `share[]` (who: "team"), [SHARE w/ family] → `share[]` (who: "family"), [SKIP] → `skip[]`
**And** it includes a required frontmatter template with all `digestSchema` fields and `theme: rva-events`
**And** STEP 3 instructs Claude to write the file only — no git operations

**Given** `src/content/rva-events/.gitkeep` is created
**When** `git status` is checked
**Then** the empty directory is tracked by git

**Given** `.claude/settings.json` is updated
**When** the `permissions.allow` array is inspected
**Then** it contains `"Write(src/content/rva-events/*)"` alongside existing entries

**Dev Notes:**
- YAML source structure: follow exact same pattern as `scripts/topics/richmond.yaml` — same tier structure, same field names
- The tier1 `filter_regex` for event filtering: `\b(event|concert|festival|exhibit|opening|workshop|market|fair|show|performance)\b` — adjust per-source as needed
- Tier2 venue pages are pure HTML event calendars — set `kind: html`, no filter needed (they only publish events)
- No Eventbrite: removed public RSS in 2023; Visit Richmond and Richmond Family already aggregate from Eventbrite
- Prompt distance weighting verbatim zones: RVA (Richmond city + Henrico, Chesterfield, Midlothian) — always; Metro (Hanover, Colonial Heights, Petersburg, Hopewell) — include if 4+ RVA; Extended Metro (Charlottesville, Williamsburg, Fredericksburg) — only ≤60 min AND exceptional; VA-Wide — Capital One/RVA tech only, state distance explicitly
- Civic/political rule: cap at 1–2 items; require "direct community access to elected officials" justification; [ATTEND] only if genuine networking or civic-influence angle exists
- Test: `scripts/.venv/bin/python3 scripts/fetch_sources.py --topic richmond-events --weekly 2>&1 | grep "###"` — should show all 14 source headers (some HTML sources may return 0 items if pages are JS-rendered — that's expected; the test is that headers appear)
- Reference: RICHMOND_EVENTS_PROPOSAL.md §3.2 for full YAML, §5 for complete prompt template

---

### Story 5.2: RVA Events — Astro Site Wiring

As a developer,
I want the `rva-events` collection registered in the Astro site with nav entry, theme card, and watchlist support,
So that Richmond Events digests are visible and accessible on priyesh.fyi alongside the other four feeds.

**Acceptance Criteria:**

**Given** `src/content.config.ts` is updated
**When** the file is inspected
**Then** the theme enum contains `'rva-events'` alongside the existing 5 values: `z.enum(['ai', 'leadership', 'local-llm', 'mythology', 'richmond', 'rva-events'])`
**And** a new collection is defined: `'rva-events': defineCollection({ loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/rva-events' }), schema: digestSchema })`

**Given** `src/layouts/Layout.astro` is updated
**When** the nav sidebar renders
**Then** "RVA Events" appears as a nav item in the Themes section with correct href (`${B}rva-events`)
**And** the entry count badge shows the number of `rva-events` collection entries (0 when empty)
**And** `activeTheme === 'rva-events'` correctly highlights the nav item

**Given** `src/pages/index.astro` is updated
**When** the dashboard home page is built
**Then** an "RVA Events" theme card appears with `id: 'rva-events'`, label, and `emptyNote: 'Upcoming events in Richmond — family activities, tech meetups, arts & dining.'`
**And** when entries exist, the card shows the latest entry's `tldr` and date
**And** rva-events `try[]` and `readDeeper[]` items appear in the Watchlist section of the dashboard

**Given** `src/pages/watchlist.astro` is updated
**When** the watchlist page is built
**Then** rva-events action items appear with source labeled `"RVA Events · [date]"`
**And** done/snooze localStorage state works for rva-events items (same key pattern as other topics)

**Given** `src/pages/[theme]/index.astro` is updated
**When** `getStaticPaths` is inspected
**Then** `{ params: { theme: 'rva-events' } }` is present in the returned array
**And** `themeLabels['rva-events']` is `'Richmond Events'`
**And** `scheduleLabels['rva-events']` is `'Weekly on Saturdays'`

**Given** `src/pages/[theme]/[slug].astro` is updated
**When** `getStaticPaths` is inspected
**Then** `'rva-events'` is present in the `themes` const array
**And** `themeLabels['rva-events']` is `'Richmond Events'`

**Given** `npm run build` is run with an empty `src/content/rva-events/` directory
**When** the build completes
**Then** it succeeds with zero TypeScript or Zod errors
**And** the `/rva-events` route is present in the build output

**Dev Notes:**
- All 6 file changes follow the exact same pattern used to add `local-llm` in Stories 3.2 and 3.3 — diff those stories for the template
- `content.config.ts`: two changes only — add to enum, add collection. `digestSchema` is reused unchanged.
- `Layout.astro`: add `getCollection('rva-events')` to the existing `Promise.all`, destructure as `rvaEventsEntries`, add `'rva-events': rvaEventsEntries.length` to `themeCounts`, add `{ id: 'rva-events', label: 'RVA Events', count: themeCounts['rva-events'] }` to `themeNav`
- `[theme]/index.astro` type cast: update the `as { theme: '...' }` assertion to include `'rva-events'`
- Test: add a dummy `src/content/rva-events/2026-01-01.md` with valid `digestSchema` frontmatter (theme: rva-events), run `npm run build`, confirm the `/rva-events/2026-01-01` route is built and nav shows count: 1, then delete the dummy file

---

### Story 5.3: RVA Events — E2E Live Test & Release

As Priyesh,
I want to run the complete `richmond-events` topic end-to-end and verify the output deploys correctly,
So that I can confirm the new feed works autonomously before relying on the Saturday schedule.

**Acceptance Criteria:**

**Given** Stories 5.1 and 5.2 are complete and `bash scripts/run-topic.sh richmond-events` is run with `--weekly` flag
**When** the run completes successfully
**Then** `src/content/rva-events/YYYY-MM-DD.md` exists

**Given** the generated file is inspected
**When** its frontmatter is parsed
**Then** it contains all required `digestSchema` fields: `title`, `date`, `theme: rva-events`, `format: weekly-synthesis`, `tldr`, `itemCount`, `readTimeMinutes`, `sources`, `actions`
**And** `actions.try[]` contains at least 1 event item (ATTEND or BRING FAMILY)
**And** `actions.skip[]` may be empty (acceptable if all items are high-signal)
**And** all event dates in the body are in the future relative to the run date (no past events)

**Given** `npm run build` is run after the file is generated
**When** it completes
**Then** the build succeeds with no Zod schema validation errors
**And** the `/rva-events/YYYY-MM-DD` route is present in the build output

**Given** the file is committed and pushed to origin main
**When** the GitHub Actions `deploy.yml` workflow completes
**Then** the deployed site at `https://peacepirate.github.io/daily-kickoff/rva-events` shows the new RVA Events page
**And** the "RVA Events" nav item appears in the sidebar with count: 1

**Given** `run-topic.sh richmond-events` is run a second time on the same date
**When** it completes
**Then** no duplicate file is created (idempotency — orchestrator skips existing output)

**Given** `run-all-topics.sh` is run on a Saturday
**When** it discovers `scripts/topics/richmond-events.yaml` (schedule: weekly)
**Then** it includes `richmond-events` in the Saturday run alongside leadership, richmond, and local-llm
**And** the single git commit contains `src/content/rva-events/DATE.md` alongside the other topic files

**Dev Notes:**
- Run manually: `bash scripts/run-topic.sh richmond-events` — on a non-Saturday, the orchestrator would skip it (weekly); bypass for testing by invoking `run-topic.sh` directly (it doesn't enforce schedule — that's the orchestrator's job)
- `run-topic.sh` reads `schedule:` from YAML automatically and passes `--weekly` for `schedule: weekly` topics — no manual flag needed
- HTML source reliability: tier2 venue pages (VMFA, Maymont, etc.) use React/Next.js. If `fetch_html` returns 0 items for a source, that's expected — The Valentine and RSS tier1 sources are the most reliable
- Validate frontmatter quickly: `python3 -c "import yaml; f=open('src/content/rva-events/$(date +%Y-%m-%d).md'); content=f.read(); fm=content.split('---')[1]; yaml.safe_load(fm); print('OK')"`
- Saturday orchestrator integration: `run-all-topics.sh` auto-discovers all `scripts/topics/*.yaml` — `richmond-events.yaml` will be picked up automatically; no orchestrator changes needed

---

## Epic 5 Post-Launch Addendum (2026-05-23)

### Status: All stories done; date extraction fix shipped

**Stories 5.1, 5.2, 5.3:** Complete and deployed. Site live at `https://peacepirate.github.io/daily-kickoff/rva-events`.

### Bug Fixed: Stale Events Appearing as Upcoming

**Observed (2026-05-22 digest):** "Techsters Middle School Girls Coding Camp" and "RFM Summer Camp Expo" appeared in Week 3/Week 4 with inferred future dates. Clicking through showed both events had already occurred.

**Root cause:** `fetch_html()` hardcoded `"date": "recent"` for every HTML item. `print_item()` suppressed this field in output. Claude received title + URL only — zero temporal signal — and inferred dates from event names semantically ("Summer Camp" → assume June–August).

**Fix (2026-05-23):**

1. `fetch_sources.py` — added HTML event date extraction:
   - `parse_date_text()` — 5-pattern date parser
   - `extract_event_date()` — cascades through `<time datetime>`, `<time>` text, date-class CSS, `data-*` attrs, full text
   - `event_mode: bool` on `fetch_html()` — extracts date, drops outside `[TODAY+2, TODAY+30]`, emits `DATE: YYYY-MM-DD` or `DATE: UNKNOWN`
   - `from __future__ import annotations` for Python 3.9 compatibility

2. `richmond-events.yaml` — `event_mode: true` added to all 11 HTML sources

3. `richmond-events.md` — `## DATE FIELD RULES` section added; `## Dates TBC` output section added; Claude forbidden from inferring dates

**Result:** Verified in `2026-05-23.md` — The Valentine's 5 events have confirmed dates (`DATE: 2026-05-25` through `2026-05-30`); Techsters/RFM correctly appear in "Dates TBC" with "check website to confirm date."

### FR-E14 (added post-launch)

FR-E14: `fetch_sources.py` must extract actual event dates from HTML content for `event_mode: true` sources, mathematically validate them against a `[TODAY+2, TODAY+30]` forward window, and emit `DATE: YYYY-MM-DD` (confirmed) or `DATE: UNKNOWN` (unparseable). Events outside the window must be silently dropped. Claude must never infer or guess event dates — items with `DATE: UNKNOWN` go to a `## Dates TBC` section only.
