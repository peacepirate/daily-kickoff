# PRD — Daily Kickoff v2: Multi-Topic Digest Pipeline

**Project:** Daily Kickoff — priyesh.fyi  
**Version:** 2.0  
**Owner:** Priyesh Jain, Senior Engineering Manager, a large regulated enterprise  
**Date:** 2026-05-17

---

## Product Overview

Daily Kickoff is a personal AI-curated digest site (Astro 6 + Tailwind v4, GitHub Pages). v1 generates a daily AI news digest. v2 expands the pipeline to four topics, each with its own source configuration, synthesis prompt, and Astro content collection.

**Core value proposition:** Stay current on AI, Engineering Leadership, Richmond local news, and Local LLM ecosystem in ≤15 min/day per topic — with zero manual curation effort after setup.

---

## User Context

- **User:** Priyesh Jain, Senior Engineering Manager at a large regulated financial-services company, Richmond VA
- **Manages:** 6–10 engineering teams using Claude Code / AWS Bedrock
- **Work focus:** AI/ML document ingestion (OCR, Azure AI Search, RAG) for card underwriting
- **Side project:** Gods of the Future Past (kids' mythology platform; needs local LLM inference)
- **Goal:** Daily 15-min signal scan Mon–Sat; weekly synthesis on Saturdays

---

## Functional Requirements

### FR1: Config-Driven Source System
The pipeline must support per-topic YAML configuration files at `scripts/topics/TOPIC.yaml`. Each config file fully defines that topic's sources, schedule, output collection, and prompt path. Adding a new topic must require only adding a YAML config file — no Python code changes.

### FR2: Topic Config Schema
Each topic YAML config must include:
- `name` — display name
- `theme` — Astro content collection key (e.g., `ai`, `leadership`, `richmond`, `local-llm`)
- `schedule` — `daily` or `weekly` (weekly = Saturday only)
- `output_collection` — path under `src/content/`
- `prompt` — path to topic synthesis prompt markdown file
- `sources.tier1[]`, `sources.tier2[]`, `sources.tier3[]` — source entries
- Each source entry: `name`, `kind` (rss|html|github|releasebot), `url`, `max_items`
- Optional per-source: `filter_regex`, `filter_cap` for filtered sources like HN

### FR3: Updated fetch_sources.py
`fetch_sources.py` must accept a `--topic TOPIC` argument and dynamically load sources from the corresponding `scripts/topics/TOPIC.yaml`. Existing fetch functions (fetch_rss, fetch_html, fetch_releasebot, fetch_github_trending) must remain unchanged.

### FR4: AI Topic — Daily
The AI topic must run every day Mon–Sat, fetching from: releasebot.io (Claude Code, Anthropic, OpenAI), AWS ML Blog RSS, Google AI Blog RSS, DeepMind HTML, Mistral HTML, DeepSeek HTML, Simon Willison Atom, Import AI RSS, Latent Space RSS, The Batch HTML, Hacker News RSS (AI-filtered, cap 3), GitHub Trending.

### FR5: Leadership Topic — Weekly (Saturday)
The Leadership topic must run on Saturdays only. Sources: LeadDev RSS, Will Larson RSS, Charity Majors RSS, The Pragmatic Engineer RSS, Lara Hogan RSS, First Round Review RSS, Manager Tools RSS, HN (EM-filtered, cap 3), r/ExperiencedDevs RSS, r/Engineering_Manager RSS.

### FR6: Richmond Topic — Weekly (Saturday)
The Richmond topic must run on Saturdays only with distance-weighted sources. Sources: Richmond BizSense RSS, Richmond Magazine RSS, Style Weekly RSS, RICtoday RSS, Richmond Times-Dispatch RSS, Small Richmond RSS, WRIC RSS, Virginia Mercury RSS, Virginia Business RSS, Visit Richmond HTML, Richmond Family Magazine HTML, RVAtech HTML.

### FR7: Local LLM Topic — Weekly (Saturday)
The Local LLM topic must run on Saturdays only. Sources: r/LocalLLaMA RSS, Ollama GitHub releases Atom, llama.cpp GitHub releases Atom, Open WebUI GitHub releases Atom, Simon Willison RSS (local-filtered), HuggingFace Blog RSS (filtered), LM Studio HTML, GitHub Trending Python HTML, HN RSS (local-filtered, cap 3). This topic populates `src/content/local-llm/`.

### FR8: Master Orchestrator Script
A script `run-all-topics.sh` must discover all `scripts/topics/*.yaml` configs, determine which topics should run based on their schedule and the current day of the week, run each qualifying topic sequentially via `run-topic.sh TOPIC`, then perform a single `git add / commit / push` for all generated content.

### FR9: Idempotency
Before running a topic, the orchestrator must check whether `src/content/THEME/YYYY-MM-DD.md` already exists for today. If it exists, skip that topic with a log message.

### FR10: Sunday Skip
No topics run on Sundays (day-of-week = 7). The orchestrator must enforce this globally regardless of per-topic schedule.

### FR11: Per-Topic Synthesis Prompts
Each topic must have a dedicated synthesis prompt markdown file at `scripts/prompts/TOPIC.md`. The AI prompt moves from `scripts/digest-prompt.md` to `scripts/prompts/ai.md`. New prompts must be created for leadership, richmond, and local-llm.

### FR12: Per-Topic Prompts — Output Format
Each prompt must instruct Claude to: (a) check the current date and determine daily vs. weekly-synthesis format, (b) check if the output file already exists (idempotency check), (c) generate the digest in the correct format with Astro frontmatter, (d) write to `src/content/THEME/YYYY-MM-DD.md`, (e) NOT commit (the orchestrator handles that).

### FR13: Failure Isolation
If one topic's fetch or synthesis fails, the orchestrator must log the error, mark that topic as failed, and continue processing remaining topics. The final git commit must include all successfully generated content regardless of per-topic failures.

### FR14: Local LLM — New Astro Collection
The site must add a `local-llm` content collection: update `src/content.config.ts` to add `local-llm` to the theme enum and define the collection, create the `src/content/local-llm/` directory, update `src/pages/index.astro` to add a Local LLM theme card and include local-llm entries in Watchlist and cadence tracking, update `src/pages/watchlist.astro` similarly.

### FR15: Updated .claude/settings.json
The `.claude/settings.json` permissions allow list must include `Write(src/content/richmond/*)` and `Write(src/content/leadership/*)` and `Write(src/content/local-llm/*)` in addition to the existing `Write(src/content/ai/*)`.

### FR16: Updated launchd Plist
The macOS launchd plist installed by `install-schedule.sh` must point to `run-all-topics.sh` (replacing the current `run-digest.sh`).

### FR17: pyyaml Dependency
The Python venv creation step in `run-topic.sh` (or the orchestrator) must install `pyyaml` alongside `httpx feedparser beautifulsoup4`.

---

## Non-Functional Requirements

### NFR1: Performance
Full Saturday run (4 topics: AI, Leadership, Richmond, Local LLM) must complete within 15 minutes. Daily run (AI only) must complete within 5 minutes.

### NFR2: Unattended Operation
The pipeline must run with zero interactive prompts. No password dialogs, no permission grants, no confirmation steps. The `--dangerously-skip-permissions` Claude CLI flag and `.claude/settings.json` pre-approvals must cover all required operations.

### NFR3: Valid Astro Content
All generated markdown files must pass Astro content collection validation on `npm run build`. Required frontmatter fields: `title`, `date`, `theme`, `format`, `tldr`, `itemCount`, `readTimeMinutes`, `sources`, `actions`.

### NFR4: Idempotency
Running the pipeline twice in the same day must produce identical output (second run skips all topics because output files already exist). Re-running after a failure must only re-run failed topics.

### NFR5: Backward Compatibility
The existing `run-digest.sh` and `digest-prompt.md` files must remain functional as a fallback. New files are additive.

### NFR6: No Schema Changes
The existing Astro `digestSchema` must remain unchanged. New topic prompts map their action tags into the existing `try[]`, `share[]`, `readDeeper[]`, `skip[]` fields semantically (no structural schema changes required for v2).

---

## Out of Scope (v2)

- Mythology topic automation (manual content only)
- Richmond topic daily cadence (weekly only)
- Cross-topic deduplication logic
- Topic-specific Zod schema extensions
- Email/notification delivery of digests
- Public-facing syndication (RSS feed for the site)
