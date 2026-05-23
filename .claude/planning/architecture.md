# Architecture — Daily Kickoff v2: Multi-Topic Digest Pipeline

**Project:** Daily Kickoff — priyesh.fyi  
**Version:** 2.1  
**Date:** 2026-05-17 (updated 2026-05-23 — Epic 5 rva-events + date extraction)

---

## System Overview

```
macOS launchd (11pm nightly)
  └── run-all-topics.sh  [NEW master orchestrator]
        ├── reads scripts/topics/*.yaml  [NEW per-topic configs]
        ├── for each qualifying topic:
        │     ├── run-topic.sh TOPIC  [RENAMED from run-digest.sh]
        │     │     ├── Python venv: fetch_sources.py --topic TOPIC  [UPDATED]
        │     │     │     └── reads scripts/topics/TOPIC.yaml for source list
        │     │     └── Claude CLI: scripts/prompts/TOPIC.md + fetched content
        │     │           └── writes src/content/THEME/YYYY-MM-DD.md
        │     └── (failure isolated; other topics continue)
        └── single: git add src/content/** → commit → push → GitHub Actions deploy
```

---

## Technology Stack

| Layer | Technology | Notes |
|-------|------------|-------|
| Site framework | Astro 6 + Tailwind v4 | Static output, GitHub Pages deploy |
| Content | Astro content collections | Glob loader, shared Zod schema |
| Fetch runtime | Python 3.11+, httpx, feedparser, beautifulsoup4, pyyaml | Isolated venv at `scripts/.venv/` |
| Synthesis | Claude Code CLI (`claude --dangerously-skip-permissions --print`) | Uses subscription, not API key |
| Scheduling | macOS launchd | Permanent agent, fires 11pm daily |
| Deployment | GitHub Actions `deploy.yml` | Triggers on push to main |

---

## Directory Structure (v2)

```
daily-kickoff/site/
├── scripts/
│   ├── topics/                      # Per-topic configs
│   │   ├── ai.yaml
│   │   ├── leadership.yaml
│   │   ├── richmond.yaml
│   │   ├── local-llm.yaml
│   │   └── richmond-events.yaml     # Epic 5 — rva-events forward calendar
│   ├── prompts/                     # Per-topic synthesis prompts
│   │   ├── ai.md
│   │   ├── leadership.md
│   │   ├── richmond.md
│   │   ├── local-llm.md
│   │   └── richmond-events.md       # Epic 5 — week→category format, DATE FIELD RULES
│   ├── fetch_sources.py             # v2.1 — event_mode date extraction (Epic 5)
│   ├── run-topic.sh                 # Reads schedule: from YAML; auto --weekly
│   ├── run-all-topics.sh            # Master orchestrator
│   ├── install-schedule.sh          # Points to run-all-topics.sh
│   ├── digest-prompt.md             # Retained as fallback
│   ├── .venv/                       # Python venv
│   └── logs/                        # Per-run logs
│       ├── YYYY-MM-DD.log
│       └── fetched-YYYY-MM-DD-TOPIC.txt
├── src/
│   ├── content/
│   │   ├── ai/
│   │   ├── leadership/
│   │   ├── richmond/
│   │   ├── local-llm/
│   │   ├── rva-events/              # Epic 5 — forward-looking events calendar
│   │   └── mythology/               # Manual content only (unchanged)
│   ├── content.config.ts            # rva-events collection + enum value added
│   └── pages/
│       ├── index.astro              # rva-events theme card added
│       └── watchlist.astro          # rva-events query added
└── .claude/
    ├── settings.json                # Write(src/content/rva-events/*) added
    └── planning/                    # BMAD planning artifacts (this dir)
```

---

## Topic Config Schema

All topic configs live at `scripts/topics/TOPIC.yaml`. Schema:

```yaml
name: string              # Display name for logging
theme: string             # Astro collection key (ai|leadership|richmond|local-llm|rva-events)
schedule: daily|weekly    # daily=Mon-Sat, weekly=Saturday only
output_collection: string # Maps to src/content/THEME/
prompt: string            # Relative path to synthesis prompt
sources:
  tier1:
    - name: string
      kind: rss|html|github|releasebot
      url: string
      max_items: integer
      filter_regex: string    # optional — filter items by regex match
      filter_cap: integer     # optional — max items after filter
  tier2:
    - name: string
      kind: html
      event_mode: boolean     # optional (default false) — enables date extraction + window filter
      url: string
      max_items: integer
  tier3: [...]               # same structure as tier2
```

**`event_mode` flag (v2.1, Epic 5):** When `true` on an HTML source, `fetch_sources.py` runs `extract_event_date()` on each scraped block. Events outside the 30-day forward window are dropped at fetch time. Confirmed dates emit `DATE: YYYY-MM-DD`; unparseable dates emit `DATE: UNKNOWN`. Only used by the `richmond-events` topic.

---

## fetch_sources.py — Interface Change

**v2:** Accepts `--topic TOPIC` flag. Reads `scripts/topics/TOPIC.yaml` and builds tier lists dynamically.

```python
# v2 invocation:
python3 scripts/fetch_sources.py --topic ai
python3 scripts/fetch_sources.py --topic leadership --weekly
python3 scripts/fetch_sources.py --topic richmond --weekly
python3 scripts/fetch_sources.py --topic local-llm --weekly
python3 scripts/fetch_sources.py --topic richmond-events --weekly
```

**v2.1 additions (Epic 5 — date extraction):**
- `parse_date_text(text) -> Date | None` — 5-pattern date parser (ISO datetime attr, Month DD YYYY, Weekday Month DD YYYY, MM/DD/YYYY, full text scan)
- `extract_event_date(container) -> Date | None` — searches `<time datetime>`, `<time>` text, date-class CSS, `data-date/start` attrs, full text
- `event_mode: bool` parameter on `fetch_html()` — when `True`, extracts date per block; drops events outside `[TODAY+2, TODAY+30]`; emits `DATE: YYYY-MM-DD` or `DATE: UNKNOWN`
- `from __future__ import annotations` — required for Python 3.9 `Type | None` annotation compatibility
- `TODAY`, `EVENT_WINDOW_START`, `EVENT_WINDOW_END` module-level constants

The `filter_regex` and `filter_cap` fields in tier3 source configs replace the hardcoded HN filter in the current script.

---

## run-topic.sh — Interface Change

**Current:** `run-digest.sh` — hardcoded for AI topic only.

**v2:** `run-topic.sh TOPIC` — topic is a positional argument.

Key changes:
- `TOPIC` from `$1` arg
- `CONTENT_FILE` includes topic suffix: `fetched-DATE-TOPIC.txt`
- Prompt path: `scripts/prompts/$TOPIC.md` (not `scripts/digest-prompt.md`)
- `--weekly` flag passed through if today is Saturday OR if `schedule` in config is `weekly`

```bash
# v2 invocations from orchestrator:
bash scripts/run-topic.sh ai
bash scripts/run-topic.sh leadership   # orchestrator only calls this on Saturdays
bash scripts/run-topic.sh richmond
bash scripts/run-topic.sh local-llm
```

---

## run-all-topics.sh — New Orchestrator

```bash
#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOPICS_DIR="$REPO_DIR/scripts/topics"
VENV="$REPO_DIR/scripts/.venv"
DAY_OF_WEEK=$(date +%u)   # 1=Mon...6=Sat...7=Sun
DATE=$(date +%Y-%m-%d)
LOG_FILE="$REPO_DIR/scripts/logs/$DATE.log"

log() { echo "$*" | tee -a "$LOG_FILE"; }
log "=== run-all-topics started $(date) ==="

# Global Sunday skip
if [ "$DAY_OF_WEEK" = "7" ]; then
  log "Sunday — no topics run"; exit 0
fi

COMMITTED=0
FAILED_TOPICS=""

for config in "$TOPICS_DIR"/*.yaml; do
    TOPIC=$(basename "$config" .yaml)
    SCHEDULE=$("$VENV/bin/python3" -c "import yaml; c=yaml.safe_load(open('$config')); print(c.get('schedule','daily'))")
    THEME=$("$VENV/bin/python3" -c "import yaml; c=yaml.safe_load(open('$config')); print(c.get('theme','$TOPIC'))")

    # Weekly topics: only run on Saturday
    if [ "$SCHEDULE" = "weekly" ] && [ "$DAY_OF_WEEK" != "6" ]; then
        log "Weekday — skipping weekly topic: $TOPIC"; continue
    fi

    # Idempotency check
    if [ -f "$REPO_DIR/src/content/$THEME/$DATE.md" ]; then
        log "$TOPIC: output exists — skipping"; continue
    fi

    log "--- Running topic: $TOPIC ---"
    (bash "$REPO_DIR/scripts/run-topic.sh" "$TOPIC") \
        && COMMITTED=$((COMMITTED+1)) \
        || { log "WARN: $TOPIC failed"; FAILED_TOPICS="$FAILED_TOPICS $TOPIC"; }
done

# Single commit for all successful topics
if git -C "$REPO_DIR" diff --quiet HEAD -- src/content/; then
    log "No new content to commit."
else
    git -C "$REPO_DIR" add src/content/
    git -C "$REPO_DIR" commit -m "digest: $DATE [automated]"
    git -C "$REPO_DIR" push origin main
    log "Pushed $COMMITTED topic(s)."
fi

[ -n "$FAILED_TOPICS" ] && log "FAILED topics:$FAILED_TOPICS"
log "=== run-all-topics finished $(date) ==="
```

---

## Synthesis Prompt Interface

Each prompt file at `scripts/prompts/TOPIC.md` receives:

```
[prompt file contents]
---
# FETCHED SOURCE CONTENT
[output of fetch_sources.py for that topic]
```

The prompt instructs Claude to:
1. Check date (`date +%Y-%m-%d`, `date +%u`)
2. Check if `src/content/THEME/DATE.md` already exists → if yes, print "Already exists" and stop
3. Generate digest with correct Astro frontmatter + markdown body
4. Write to `src/content/THEME/DATE.md` using file write (not git commit)

**Claude does NOT commit.** The orchestrator handles git operations after all topics run.

---

## Astro Site Changes

### content.config.ts

The `digestSchema` remains unchanged across all topics.

```typescript
// Current enum (includes Epic 5):
theme: z.enum(['ai', 'leadership', 'local-llm', 'mythology', 'richmond', 'rva-events'])

// rva-events collection (added Epic 5):
'rva-events': defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/rva-events' }),
  schema: digestSchema,
}),
```

### index.astro

Both `local-llm` (v2) and `rva-events` (Epic 5) theme cards follow the same pattern:

```typescript
const rvaEventsEntries = await getCollection('rva-events');
// Added to themeCards array:
{
  id: 'rva-events',
  label: 'RVA Events',
  latest: latestEntry(rvaEventsEntries),
  emptyNote: 'Upcoming events in Richmond — family activities, tech meetups, arts & dining.',
  count: rvaEventsEntries.length,
}
```

### watchlist.astro

Same pattern — `getCollection('rva-events')` added and included in `allEntries`.

---

## .claude/settings.json

```json
{
  "permissions": {
    "allow": [
      "WebFetch(*)",
      "Bash(date *)",
      "Bash(ls src/content/**)",
      "Bash(git add src/content/**)",
      "Bash(git commit *)",
      "Bash(git push origin main)",
      "Bash(git status)",
      "Write(src/content/ai/*)",
      "Write(src/content/leadership/*)",
      "Write(src/content/richmond/*)",
      "Write(src/content/local-llm/*)",
      "Write(src/content/rva-events/*)"
    ]
  }
}
```

---

## Key Architectural Decisions

### Decision 1: Per-topic YAML vs. single config file
**Chosen:** Per-topic YAML at `scripts/topics/TOPIC.yaml`  
**Reason:** Independent editability; adding a topic = one new file, zero code changes; failure in one config doesn't affect others.

### Decision 2: Single orchestrator vs. one launchd job per topic
**Chosen:** Single orchestrator `run-all-topics.sh`, single launchd plist  
**Reason:** Simpler install/uninstall; one log file per day; topics share a single git commit = one deploy trigger; easier to add topics.

### Decision 3: Schema unchanged for v2
**Chosen:** No Astro schema changes; synthesis prompts map action semantics to existing fields  
**Reason:** Zero migration risk; Watchlist and cadence tracker continue working unchanged; topic-specific action labels are a v3 concern when/if visual differentiation is needed.

### Decision 4: Claude does not commit; orchestrator commits
**Chosen:** Each prompt writes the content file only; `run-all-topics.sh` does the single git add/commit/push  
**Reason:** Prevents race conditions (two topics committing simultaneously); single deploy trigger; easier to retry failed topics before committing.

---

## Testing Approach

### Unit-level: Fetcher config loading
- Test that `fetch_sources.py --topic ai` loads `topics/ai.yaml` correctly
- Test that `--topic leadership` loads `topics/leadership.yaml` and applies filter_regex/filter_cap

### Integration: Per-topic dry run
```bash
bash scripts/run-topic.sh ai        # verify ai digest generates
bash scripts/run-topic.sh leadership  # verify leadership digest (Saturday only — pass --weekly flag in test)
bash scripts/run-topic.sh richmond
bash scripts/run-topic.sh local-llm
```

### E2E: Full Saturday orchestration
```bash
bash scripts/run-all-topics.sh   # on a Saturday, verify all 4 topics generate
```

### Site build validation
```bash
npm run build   # must succeed with no Astro schema errors
```

### Idempotency test
Run the pipeline twice on the same day — second run must log "output exists — skipping" for all topics and make no git changes.

---

## Date Extraction Architecture (v2.1 — Epic 5)

Applies only to HTML sources with `event_mode: true`. Used exclusively by `richmond-events` topic.

```
fetch_html(event_mode=True)
    │
    ├─ for each scraped block:
    │    extract_event_date(block)
    │      ├─ 1. <time datetime="..."> attrs     (highest confidence)
    │      ├─ 2. <time> tag text content
    │      ├─ 3. elements with date-class CSS     (event-date, tribe-event, etc.)
    │      ├─ 4. data-date / data-start attrs
    │      └─ 5. full container text scan         (lowest confidence)
    │
    ├─ date = None  →  ev_date_str = "UNKNOWN"   → include (placed in "Dates TBC" by Claude)
    ├─ date < TODAY+2  →  drop silently           (past, or today/tomorrow — belongs in richmond news)
    ├─ date > TODAY+30 →  drop silently           (outside 30-day window)
    └─ date in [TODAY+2, TODAY+30]  →  ev_date_str = "YYYY-MM-DD"  → include in output
```

`print_item()` emits uppercase `DATE:` label for confirmed/UNKNOWN dates. Claude's `## DATE FIELD RULES` prompt section governs placement: confirmed dates → week buckets; UNKNOWN → `## Dates TBC` section; Claude may never infer or guess dates.

**Why this matters:** Without `event_mode`, `fetch_html()` hardcoded `"date": "recent"` for all HTML items. Claude received zero temporal signal and inferred event dates semantically from names — causing historically-named events (e.g., "Summer Camp Expo") to appear as upcoming when they had already occurred. The fix was shipped 2026-05-23.
