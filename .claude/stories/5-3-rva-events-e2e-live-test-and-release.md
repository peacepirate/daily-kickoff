# Story 5.3: RVA Events — E2E Live Test & Release

Status: ready-for-dev

## Story

As Priyesh, I want to run the complete `richmond-events` topic end-to-end and verify the output deploys correctly, so that I can confirm the new feed works autonomously before relying on the Saturday schedule.

## Acceptance Criteria

1. **Given** the project root is the working directory **When** `bash scripts/run-topic.sh richmond-events` is executed **Then** the script runs to completion without a non-zero exit code — Python fetch produces at least 1 item (`URL:` line count > 0) and Claude synthesis completes successfully.

2. **Given** the synthesis step completes **When** `src/content/rva-events/` is inspected **Then** a new file `src/content/rva-events/YYYY-MM-DD.md` (today's date) is present with valid frontmatter matching `digestSchema`: `theme: rva-events`, `format: weekly-synthesis`, a valid ISO date, and non-empty `title` and `tldr` fields.

3. **Given** the new digest file is present **When** `npm run build` is run **Then** the build succeeds with zero TypeScript and Zod errors, the page count is 13 or more (up from 12 with empty collection), and `dist/rva-events/YYYY-MM-DD/index.html` exists in the build output.

4. **Given** the build succeeds **When** the `/rva-events` theme page is inspected (locally via `npm run preview` or in build output) **Then** the digest card shows the correct date, a non-zero item count, and the schedule label "Weekly on Saturdays".

5. **Given** the build passes locally **When** a git commit is created and pushed to the `main` branch of `peacepirate/daily-kickoff` **Then** the GitHub Actions CI/CD pipeline runs and completes with a green status.

6. **Given** the GitHub Actions deploy succeeds **When** `https://peacepirate.github.io/daily-kickoff/rva-events` is loaded in a browser **Then** the "RVA Events" nav item is visible, at least 1 digest entry is displayed, and the page renders without console errors.

## Tasks / Subtasks

- [ ] Pre-run checks (AC: 1)
  - [ ] Confirm working directory is project root: `/Users/priyeshjain/source/daily-kickoff/site`
  - [ ] Confirm Python venv exists: `ls scripts/.venv/bin/python3`
  - [ ] Confirm `claude` CLI is on PATH: `command -v claude`
  - [ ] Confirm prompt file exists: `ls scripts/prompts/richmond-events.md`
  - [ ] Confirm topic config exists: `ls scripts/topics/richmond-events.yaml`

- [ ] Run the full pipeline (AC: 1)
  - [ ] Execute: `bash scripts/run-topic.sh richmond-events`
  - [ ] Verify exit code 0 (no `ERROR:` lines in terminal output)
  - [ ] Confirm item count > 0 in log output (look for `Fetched N items from sources`)

- [ ] Verify generated digest file (AC: 2)
  - [ ] Confirm file exists at `src/content/rva-events/$(date +%Y-%m-%d).md`
  - [ ] Inspect frontmatter: `theme` must be `rva-events` (not `richmond-events`)
  - [ ] Inspect frontmatter: `format` must be `weekly-synthesis`
  - [ ] Inspect frontmatter: `date` must match today's date
  - [ ] Inspect frontmatter: `title` and `tldr` must be non-empty strings
  - [ ] Inspect frontmatter: `itemCount` must be a positive integer
  - [ ] If `theme: richmond-events` appears instead of `theme: rva-events`, fix `scripts/prompts/richmond-events.md` line 138 and re-run

- [ ] Build verification (AC: 3)
  - [ ] Clear Astro content layer cache: `rm -rf node_modules/.astro/data-store.json dist .astro`
  - [ ] Run: `npm run build`
  - [ ] Confirm zero Zod validation errors (no `Expected ... Received` in output)
  - [ ] Confirm page count is 13 or more (look for `N page(s) built` in build output)
  - [ ] Confirm `dist/rva-events/YYYY-MM-DD/index.html` exists

- [ ] Theme page verification (AC: 4)
  - [ ] Run `npm run preview` and open `http://localhost:4321/daily-kickoff/rva-events`
    — OR inspect `dist/rva-events/index.html` directly
  - [ ] Confirm digest card shows correct date
  - [ ] Confirm item count badge is non-zero
  - [ ] Confirm schedule label reads "Weekly on Saturdays"
  - [ ] Confirm "RVA Events" appears in the sidebar nav

- [ ] Git commit and push (AC: 5)
  - [ ] Stage the new digest: `git add src/content/rva-events/YYYY-MM-DD.md`
  - [ ] Check for any other modified files: `git status`
  - [ ] Create commit: `git commit -m "feat: add first rva-events digest YYYY-MM-DD"`
  - [ ] Push to main: `git push origin main`

- [ ] GitHub Actions and live site verification (AC: 5, 6)
  - [ ] Open GitHub Actions tab: `https://github.com/peacepirate/daily-kickoff/actions`
  - [ ] Confirm the deploy workflow triggered on the push
  - [ ] Wait for green checkmark (typically 2–4 minutes)
  - [ ] Open live site: `https://peacepirate.github.io/daily-kickoff/rva-events`
  - [ ] Confirm "RVA Events" nav item is visible
  - [ ] Confirm at least 1 digest entry is shown
  - [ ] Confirm the digest detail page loads: `https://peacepirate.github.io/daily-kickoff/rva-events/YYYY-MM-DD`

## Dev Notes

### Pre-run checklist

Before running the pipeline, verify all of the following from the project root (`/Users/priyeshjain/source/daily-kickoff/site`):

```bash
# Confirm working directory
pwd
# Expected: /Users/priyeshjain/source/daily-kickoff/site

# Confirm Python venv (run-topic.sh auto-creates it if missing, but faster to confirm)
ls scripts/.venv/bin/python3

# Confirm Claude CLI is findable
command -v claude || which claude

# Confirm topic config and prompt
ls scripts/topics/richmond-events.yaml
ls scripts/prompts/richmond-events.md

# Confirm rva-events content dir exists (created by Story 5.1)
ls src/content/rva-events/

# Confirm no stale digest for today already exists
ls src/content/rva-events/$(date +%Y-%m-%d).md 2>/dev/null && echo "ALREADY EXISTS — skip or delete first" || echo "OK — no existing file"
```

If the Python venv does not exist yet, `run-topic.sh` creates it automatically on first run. This takes ~30 seconds due to pip install.

### Running the pipeline

The topic name passed to `run-topic.sh` is `richmond-events` (matching the YAML filename `scripts/topics/richmond-events.yaml`). The Astro output collection is `rva-events` (set by `output_collection: rva-events` in the YAML and by `theme: rva-events` in the synthesis prompt).

```bash
# Run from project root
bash scripts/run-topic.sh richmond-events
```

What this does internally:
1. Detects or creates Python venv at `scripts/.venv/`
2. Detects day of week — sets `--weekly` flag if Saturday (day 6); otherwise fetches last 24 hours
3. Runs `scripts/fetch_sources.py --topic richmond-events [--weekly]` — fetches all 14 sources (3 tier1 RSS + 6 tier2 HTML + 5 tier3 HTML), writes to `scripts/logs/fetched-YYYY-MM-DD-richmond-events.txt`
4. Exits with error if 0 items fetched (counts `URL:` lines)
5. Concatenates the synthesis prompt (`scripts/prompts/richmond-events.md`) with fetched content
6. Calls `claude --dangerously-skip-permissions --print "..."` — Claude writes `src/content/rva-events/YYYY-MM-DD.md`
7. Logs everything to `scripts/logs/YYYY-MM-DD.log`

Expected terminal output (success path):
```
=== run-topic.sh [richmond-events] started ...
Fetching sources for topic: richmond-events (daily — last 24 hours)...
[richmond-events] Fetched N items from sources.
[richmond-events] Synthesizing with Claude (/path/to/claude)...
✓ Richmond Events digest for YYYY-MM-DD written to src/content/rva-events/YYYY-MM-DD.md
=== run-topic.sh [richmond-events] finished ...
```

Note: if today is not Saturday, `--weekly` is NOT passed to fetch_sources.py, so the fetcher uses a 24-hour lookback window. The synthesis prompt's dedup boundary (`TODAY` and `TODAY+1`) still applies correctly. For the initial E2E test, this is acceptable — partial results are fine as long as some events are fetched. If you want a full 30-day window for the first real run, manually add `--weekly` by temporarily editing `run-topic.sh` line 39 or running the fetcher directly:

```bash
scripts/.venv/bin/python3 scripts/fetch_sources.py --topic richmond-events --weekly > /tmp/rva-test.txt
grep -c "^URL:" /tmp/rva-test.txt
```

### Verifying the generated digest file

After the pipeline completes, inspect the output file:

```bash
# Confirm file exists
ls -la src/content/rva-events/$(date +%Y-%m-%d).md

# View the frontmatter (first ~20 lines)
head -25 src/content/rva-events/$(date +%Y-%m-%d).md
```

Required frontmatter checks — every field must pass:

| Field | Required value | Fail action |
|-------|---------------|-------------|
| `theme` | `rva-events` | Fix prompt line 138; re-run |
| `format` | `weekly-synthesis` | Fix prompt; re-run |
| `date` | today's date (YYYY-MM-DD) | Check Claude output for date error |
| `title` | non-empty string | Check synthesis output; Claude may have failed |
| `tldr` | non-empty string | Check synthesis output |
| `itemCount` | positive integer | Acceptable if low; fail if missing/0 |
| `sources` | array (may be empty if no URLs extracted) | Warning only |
| `actions` | object with `try`/`share`/`readDeeper`/`skip` | Must be present; sub-arrays may be empty |

**Critical theme field check:** The synthesis prompt at `scripts/prompts/richmond-events.md` line 138 specifies `theme: rva-events`. If the generated file has `theme: richmond-events` instead, the Astro build will fail with a Zod validation error (`Expected 'rva-events', received 'richmond-events'`). Fix the prompt if needed:

```bash
# Verify prompt line
grep "theme:" scripts/prompts/richmond-events.md
# Expected output: "  theme: rva-events"
```

### Build verification

Before building, clear the Astro content layer cache to ensure the new file is picked up:

```bash
# Clear cache and previous build
rm -rf node_modules/.astro/data-store.json dist .astro

# Run build
npm run build
```

Success indicators:
- No `[ERROR]` lines in build output
- No Zod validation errors (`Expected ... Received`)
- Page count reported as 13 or higher (was 12 with empty `rva-events/` collection)
- Build output includes: `dist/rva-events/YYYY-MM-DD/index.html`

```bash
# Confirm the new route was built
ls dist/rva-events/
# Expected: YYYY-MM-DD/  index.html

ls dist/rva-events/$(date +%Y-%m-%d)/index.html
# Must exist
```

Optional — preview locally before pushing:

```bash
npm run preview
# Opens at http://localhost:4321 (or with /daily-kickoff base path)
# Navigate to: http://localhost:4321/daily-kickoff/rva-events
```

### Deploy and live verification

Once the build passes locally:

```bash
# Stage only the new digest file (do not stage dist/ — it is gitignored)
git add src/content/rva-events/$(date +%Y-%m-%d).md

# Review what is staged
git status
git diff --cached --stat

# Commit
git commit -m "feat: add first rva-events digest $(date +%Y-%m-%d)"

# Push to main (triggers GitHub Actions deploy)
git push origin main
```

Monitoring the deploy:

1. Open: `https://github.com/peacepirate/daily-kickoff/actions`
2. Find the workflow run triggered by the push (name will be the commit message or workflow name)
3. Wait for green checkmark — typically 2–4 minutes for an Astro static site deploy to GitHub Pages

Live site verification checklist:

```
https://peacepirate.github.io/daily-kickoff/rva-events
```

- [ ] "RVA Events" appears in the sidebar nav with entry count > 0
- [ ] Digest card shows with correct date, item count, and "Weekly on Saturdays" schedule label
- [ ] Clicking the digest card navigates to: `https://peacepirate.github.io/daily-kickoff/rva-events/YYYY-MM-DD`
- [ ] Digest detail page renders body content (event listings by week bucket)
- [ ] TL;DR section is non-empty
- [ ] No 404 errors on the page

### Potential failure modes

**1. Zero items fetched from all sources**

Symptom: `ERROR: No content fetched for richmond-events. Check .../fetched-...txt for errors.` / script exits non-zero.

Cause: All 14 sources failed to return event-keyword-matching items (HTML scrape misses, RSS date filter too narrow on a non-Saturday run, or network issue).

Fix: Check `scripts/logs/fetched-YYYY-MM-DD-richmond-events.txt`. If sources returned HTML but no `URL:` lines, the HTML scraper found no matching `article`/`li` tags. Try running with `--weekly` to widen the time window. If network is the issue, retry after a few minutes.

**2. Claude CLI not found**

Symptom: `ERROR: claude CLI not found on PATH.`

Fix: Ensure Claude Code CLI is installed and on PATH. The script prepends `/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$HOME/.local/bin` to PATH. Run `which claude` to confirm location, then add its directory to one of these PATH entries if needed.

**3. Wrong theme value in generated file (`theme: richmond-events`)**

Symptom: `npm run build` fails with Zod error: `Invalid enum value. Expected 'ai' | 'leadership' | ... | 'rva-events', received 'richmond-events'`.

Fix: Open `scripts/prompts/richmond-events.md` and confirm line 138 reads `  theme: rva-events` (not `richmond-events`). If wrong, correct it, delete the bad digest file, and re-run the pipeline.

**4. Digest file already exists for today**

Symptom: The synthesis prompt's Step 1 check (`does src/content/rva-events/TODAY.md already exist?`) causes Claude to print "Already exists — skipping." and stop without writing a file. The script then reports 0 items or a malformed output.

Fix: Delete the existing file and re-run: `rm src/content/rva-events/$(date +%Y-%m-%d).md && bash scripts/run-topic.sh richmond-events`

**5. Stale Astro content layer cache**

Symptom: `npm run build` succeeds but page count is still 12, or the new digest is not reflected in the build output.

Fix: `rm -rf node_modules/.astro/data-store.json dist .astro` then re-run `npm run build`.

**6. GitHub Actions deploy fails**

Symptom: Red X on the Actions workflow run.

Common causes:
- Build fails on CI (Zod error, TypeScript error) — check the CI build log; fix locally and push again
- GitHub Pages deploy permissions — check repo Settings > Pages > Source is set to "GitHub Actions"
- Cache issue on CI — re-run the failed job from the Actions tab

**7. Partial fetch results (some sources return 0 items)**

Symptom: `[WARN]` lines in stderr for individual sources (e.g., a venue site returning a 403 or an empty event list).

Action: This is acceptable as long as total item count > 0. The synthesis prompt handles sparse source data with its sparsity fallback rules (light calendar TL;DR when < 6 RVA events found). Note the failing sources for future investigation but do not block this story on it.

**8. HTML venue scraper returns no events (tier2/tier3)**

Symptom: `### VMFA Events\n*No items fetched*` in the fetched content file.

Cause: The generic `fetch_html` function looks for `article`/`li` elements with class names matching `post|news|article|entry|card|item`. Museum and venue sites often use custom CSS class names that don't match these patterns.

Action: Partial results from tier1 RSS sources are sufficient for synthesis. Log which venues return 0 items in the Completion Notes. This is a known limitation noted in the deferred-work log.

## Dev Agent Record

### Agent Model Used

(leave blank for dev to fill)

### Debug Log References

(leave blank)

### Completion Notes List

(leave blank)

### File List

(leave blank — dev will fill after implementation)

## Change Log

| Date | Change | Author |
|------|--------|--------|
| 2026-05-17 | Story created | claude-sonnet-4-6 |
