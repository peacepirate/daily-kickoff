# Architecture — Daily Kickoff v2: Multi-Topic Digest Pipeline

**Project:** Daily Kickoff — priyesh.fyi  
**Version:** 2.0  
**Date:** 2026-05-17

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
│   ├── topics/                      # NEW — per-topic configs
│   │   ├── ai.yaml
│   │   ├── leadership.yaml
│   │   ├── richmond.yaml
│   │   └── local-llm.yaml
│   ├── prompts/                     # NEW — per-topic synthesis prompts
│   │   ├── ai.md                    # MOVED from digest-prompt.md
│   │   ├── leadership.md            # NEW
│   │   ├── richmond.md              # NEW
│   │   └── local-llm.md             # NEW
│   ├── fetch_sources.py             # UPDATED — reads topic config
│   ├── run-topic.sh                 # RENAMED from run-digest.sh
│   ├── run-all-topics.sh            # NEW — master orchestrator
│   ├── install-schedule.sh          # UPDATED — points to run-all-topics.sh
│   ├── digest-prompt.md             # RETAINED as fallback
│   ├── .venv/                       # Python venv (unchanged)
│   └── logs/                        # Per-run logs
│       ├── YYYY-MM-DD.log
│       └── fetched-YYYY-MM-DD-TOPIC.txt  # RENAMED — topic suffix
├── src/
│   ├── content/
│   │   ├── ai/                      # Unchanged
│   │   ├── leadership/              # Was empty, now populated
│   │   ├── richmond/                # Was empty, now populated
│   │   ├── local-llm/               # NEW directory
│   │   └── mythology/               # Manual content only (unchanged)
│   ├── content.config.ts            # UPDATED — add local-llm collection
│   └── pages/
│       ├── index.astro              # UPDATED — add local-llm theme card
│       └── watchlist.astro         # UPDATED — add local-llm entries
└── .claude/
    ├── settings.json                # UPDATED — add new Write permissions
    └── planning/                    # BMAD planning artifacts (this dir)
```

---

## Topic Config Schema

All topic configs live at `scripts/topics/TOPIC.yaml`. Schema:

```yaml
name: string              # Display name for logging
theme: string             # Astro collection key (ai|leadership|richmond|local-llm)
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
  tier2: [...]               # same structure
  tier3: [...]               # same structure
```

---

## fetch_sources.py — Interface Change

**Current:** Hardcoded TIER1/TIER2/TIER3 lists inside the script.

**v2:** Accepts `--topic TOPIC` flag. Reads `scripts/topics/TOPIC.yaml` and builds tier lists dynamically.

```python
# v2 invocation:
python3 scripts/fetch_sources.py --topic ai
python3 scripts/fetch_sources.py --topic leadership --weekly
python3 scripts/fetch_sources.py --topic richmond --weekly
python3 scripts/fetch_sources.py --topic local-llm --weekly
```

Internal changes only in `main()` — all existing `fetch_rss()`, `fetch_html()`, `fetch_releasebot()`, `fetch_github_trending()` functions are unchanged.

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

Add `local-llm` to the theme enum and define its collection. The `digestSchema` remains unchanged.

```typescript
// Updated enum:
theme: z.enum(['ai', 'leadership', 'local-llm', 'mythology', 'richmond'])

// New collection:
'local-llm': defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/local-llm' }),
  schema: digestSchema,
}),
```

### index.astro

Add `getCollection('local-llm')` and a theme card entry:

```typescript
const localLlmEntries = await getCollection('local-llm');
// Add to themeCards array:
{
  id: 'local-llm',
  label: 'Local LLM',
  latest: latestEntry(localLlmEntries),
  emptyNote: 'Local inference stack updates and Gods project tooling.',
  count: localLlmEntries.length,
}
// Add to allEntries:
...localLlmEntries.map(e => ({ ...e, themeId: 'local-llm', themeLabel: 'Local LLM' })),
```

### watchlist.astro

Same pattern as index.astro — add `getCollection('local-llm')` and include in `allEntries`.

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
      "Write(src/content/local-llm/*)"
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
