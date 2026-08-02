# Daily Kickoff

A personal intelligence digest. ~80 sources are fetched nightly, synthesized by Claude into dated
markdown, and published as a static Astro site.

**Live:** https://peacepirate.github.io/daily-kickoff/

It answers *"what should I know?"* in about 15 minutes a day. Everything is files — no database, no
CMS, no server.

---

## How it works

```
sources → fetch_sources.py → prompt + bundle → claude --print → src/content/<theme>/<date>.md
                                                                          ↓
                                                        git commit + push → GitHub Pages
```

A **job** is three things: a **producer** (what text goes into the prompt), a **prompt**, and an
**output path**. Everything else — scheduling, idempotency, templating, verification, commit,
push — is generic and shared.

| Script | Role |
|---|---|
| `scripts/run-jobs.sh` | orchestrator — globs configs, gates on schedule, isolates failures, commits once |
| `scripts/run-job.sh` | one job — produce bundle → template prompt → invoke Claude → verify |
| `scripts/lib/run-llm-job.sh` | the LLM core; knows nothing about schedules or config |
| `scripts/lib/job-config.sh` | shared config, schedule, and path resolution |
| `scripts/fetch_sources.py` | the network producer (RSS / HTML / releasebot / GitHub trending) |

Job configs are data-only YAML in two directories sharing **one schema**:

```yaml
name:     "AI Intelligence"
schedule: weekdays                    # weekdays | saturday | sunday | daily
producer: fetch_sources.py --topic ai
prompt:   scripts/prompts/ai.md
output:   src/content/ai/{{DATE}}.md
sources:  ...                         # producer-specific
```

- `scripts/topics/*.yaml` — digest jobs (publish to the public site)
- `scripts/generators/*.yaml` — studio jobs (publish to `$STUDIO_DIR`, see below)

Adding a job means adding a YAML file and a prompt. No new shell.

### Current jobs

| Job | Schedule | Output |
|---|---|---|
| `ai` | daily, Mon–Sat | `src/content/ai/` |
| `tech` | daily, Mon–Sat | `src/content/tech/` |
| `leadership` | Saturday | `src/content/leadership/` |
| `richmond-events` | Saturday | `src/content/rva-events/` |

### Schedule

launchd fires **one slot: 06:00, every day.** Each job gates on its own `schedule:`, so Mon–Sat run
digest jobs and Sunday runs generation. The orchestrator holds no day policy at all — and with one
slot per day a `sunday` job cannot fire twice, so no day needs excluding.

06:00 rather than 23:00 so the Saturday weekly synthesis is read and starred a full day before
Sunday's generation run consumes it. A digest dated `D` therefore covers `D−1 06:00 → D 06:00`: the
date matches the morning you read it, not the day the news broke.

```bash
bash scripts/install-schedule.sh              # install / reload
bash scripts/install-schedule.sh --uninstall

sudo pmset repeat wakeorpoweron MTWRFSU 05:50:00   # recommended — see below
pmset -g sched                                     # verify
```

**The Mac is probably asleep at 06:00.** launchd fires a missed calendar job once on wake, so the
run degrades to "whenever you open the lid" rather than being lost. The `pmset` line makes it
deterministic; one wake time covers everything because there is only one slot.

---

## Quirks

Non-obvious things that will bite you. Most were learned the hard way.

**Prompts use `{{DATE}}`, never the word `TODAY`.** Prompts once used the bare word `TODAY` as a
filename placeholder. Claude took it literally, wrote `src/content/<theme>/TODAY.md`, and every
subsequent night found that file and aborted — silently, for 13 nights. Placeholders are now
explicit (`{{DATE}}`, `{{FORMAT}}`, `{{DATE_PLUS_1}}`, `{{DATE_PLUS_30}}`) and `run-llm-job.sh`
**fails closed** on any unsubstituted `{{...}}` or a resurrected bare `TODAY`.

**`weekdays` means Mon–Sat, not Mon–Fri.** A misnomer preserved from the original behavior.

**Verify success with `git log origin/main`, not `ls src/content/`.** The commit gate used to be
`git diff --quiet HEAD -- src/content/`, which cannot see untracked files — and every new digest is
untracked. It reported "clean" every night and never committed. Local files looked perfect the
whole time. Use `git status --porcelain` if you touch this.

**The `claude` CLI exits 0 whether or not it wrote a file.** Hence explicit output verification
after every synthesis: exists, non-empty, starts with `---`, frontmatter validates. Without it a
no-op run is indistinguishable from success.

**`grep -c` prints `0` *and* exits 1** on no match, so `$(grep -c ... || echo 0)` yields `"0\n0"`
and any `= "0"` test silently never fires. Use `grep -q`.

**`cleanup-old-digests.sh` is deliberately not wired into the nightly run.** It is an irreversible
`rm`, and its `starred: true` frontmatter protection has **no producer** — the site's ★ button
writes per-item keys to browser localStorage and never touches the repo. Run it manually, after a
dry run. Default retention is 365 days.

**`src/content/local-llm/` and `src/content/richmond/` are retired but intentionally kept.** Their
themes are not declared in `src/content.config.ts`, so Astro's content layer ignores them and they
render nothing. They are retained as raw material for the studio corpus. Do not "clean them up."

**The `ai` topic is intermittently refused** by the API on cyber-safeguard grounds (~18% of runs) —
AI news carries exploit-disclosure content. The run fails loudly and writes nothing. Treat a gap as
normal, not as breakage.

**`scripts/logs/` is gitignored and holds the only offline-backfill material.** Each
`fetched-YYYY-MM-DD-<job>.txt` is exactly what the fetcher returned that night. These exist on one
machine only.

---

## Backfill

Network backfill is **not possible** — `fetch_sources.py` anchors its window to `now()` with no
upper bound, so a past-dated fetch would stamp today's news with a historical date.

Offline replay of a stored bundle is legitimate and correctly dated:

```bash
DIGEST_DATE=2026-07-20 \
BUNDLE_FILE=scripts/logs/fetched-2026-07-20-ai.txt \
bash scripts/run-job.sh ai
```

---

## Content

Digests are `src/content/<theme>/YYYY-MM-DD.md` — YAML frontmatter plus a markdown body, validated
against `src/content.config.ts` at build time *and* by the pipeline before commit.

Adding a theme means: a collection in `content.config.ts`, a directory with `.gitkeep`, a prompt, a
topic YAML, and a `Write(...)` entry in `.claude/settings.json`.

---

## Development

```bash
npm install
npm run dev        # localhost:4321
npm run build
npm run preview
```

Pushes to `main` trigger `.github/workflows/deploy.yml` → GitHub Pages.

---

## Relationship to `kickoff-studio`

This repo is a **consumption** system: it answers *"what should I know?"*

A companion private repo, `kickoff-studio`, is the **production** side: it answers *"what should I
say?"*, treating this archive as raw material for drafting posts.

**All code lives here.** `kickoff-studio` is data only — notes, generated drafts, a published
archive, and engagement metrics. It is reached through a `STUDIO_DIR` environment variable, never
by importing code across repos. The split is about data sensitivity, not code ownership.

```bash
kickoff --help     # scripts/studio/kickoff, symlinked to ~/.local/bin
kickoff doctor     # check studio wiring
```

Two invariants matter:

1. **`src/content/` is read-only to studio jobs.** A studio job that writes there corrupts the
   published site and the corpus in one move. `run-job.sh` asserts that any job configured under
   `generators/` resolves its output beneath `$STUDIO_DIR`.
2. **Studio data never enters this repo.** `$STUDIO_DIR` resolves outside it, and the nightly
   `git add` is scoped to `src/content/`.

Planning docs live outside both repos, in `source/plans/daily-kickoff/`.

---

## Custom domain (priyesh.fyi)

When DNS points at GitHub Pages:

1. Remove `base: '/daily-kickoff'` from `astro.config.mjs`
2. Push — all `${B}` prefixes collapse to `/` via `import.meta.env.BASE_URL`
3. `public/CNAME` already contains `priyesh.fyi`
