# Daily Kickoff — agent context

Nightly digest pipeline: sources → `fetch_sources.py` → Claude synthesis → `src/content/<theme>/<date>.md`
→ Astro → GitHub Pages. Read `README.md` for the full model; this file is the short version plus the
things that cause real damage if you get them wrong.

## Orientation — read these, don't grep for them

| Question | File |
|---|---|
| How a job runs | `scripts/run-job.sh` → `scripts/lib/run-llm-job.sh` |
| How jobs are scheduled/committed | `scripts/run-jobs.sh` |
| Config schema, schedule vocabulary, path resolution | `scripts/lib/job-config.sh` |
| What a job *is* | `scripts/topics/*.yaml` (data-only; same schema as `scripts/generators/*.yaml`) |
| Content schema | `src/content.config.ts` |
| Phase 2 plans + epic history | `../../plans/daily-kickoff/content-generation/` |

## Invariants — violating these causes silent, lasting damage

1. **Prompts use `{{DATE}}`, never the bare word `TODAY`.** `TODAY` was once taken literally and
   created `src/content/<theme>/TODAY.md`, which stalled the pipeline for 13 nights. The templating
   guard fails closed on any unsubstituted `{{...}}` or a resurrected `TODAY`.
2. **`src/content/**` is read-only to studio (`generators/`) jobs.** It is both the published site
   and the Phase 2 corpus.
3. **Never wire `cleanup-old-digests.sh` into the nightly run.** Irreversible `rm`; its
   `starred: true` protection has no producer.
4. **Success is `git log origin/main`, never `ls src/content/`.** Local files looked correct for 13
   nights while nothing published.
5. **Don't run `run-jobs.sh` to test.** It commits and pushes to a public repo. Replay a stored
   bundle instead:
   `DIGEST_DATE=<date> BUNDLE_FILE=scripts/logs/fetched-<date>-<job>.txt bash scripts/run-job.sh <job>`
6. **`scripts/logs/` is gitignored and single-machine.** It holds the only offline-backfill bundles.
   Don't delete it.

## Gotchas

- `weekdays` means **Mon–Sat**, not Mon–Fri.
- The `claude` CLI **exits 0 whether or not it wrote a file** — always verify output exists.
- `grep -c` prints `0` *and* exits 1; `$(grep -c … || echo 0)` yields `"0\n0"`. Use `grep -q`.
- `git diff HEAD -- <path>` **cannot see untracked files**. Use `git status --porcelain`.
- `src/content/{local-llm,richmond}/` are retired but intentionally retained, undeclared in
  `content.config.ts`. Not dead files — do not clean up.
- The `ai` job is intermittently API-refused on cyber-safeguard grounds (~18%). A gap is normal.
- Network backfill is impossible — `fetch_sources.py` anchors to `now()` with no upper bound.

## Checks

```bash
bash scripts/preflight.sh     # syntax, placeholders, stray files, build, cleanup dry-run
kickoff doctor                # studio wiring
```

## Conventions

- Comments explain non-obvious *why*, briefly. No narrative, no bug history, no changelog prose in
  code — that belongs in the plan docs.
- Commit messages end with:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`
