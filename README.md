# Priyesh — Daily Kickoff

Personal digest archive built with Astro 6 + Tailwind v4. Currently deployed at:
**https://peacepirate.github.io/daily-kickoff/**

---

## Automated digest generation

A macOS launchd agent runs Claude Code at 11pm nightly (Mon–Sat). It fetches Tier 1–3 AI sources, generates the digest, writes the Astro content file, and pushes to main — which auto-deploys the site.

### First-time setup

```bash
bash scripts/install-schedule.sh
```

Registers the launchd agent. Fires every night at 11pm local time. Sundays are skipped automatically.

**Requirements:**
- `claude` CLI installed and authenticated
- Git configured with push access to `peacepirate/daily-kickoff`
- Mac on (or waking from sleep) around 11pm

### Test a manual run

```bash
bash scripts/run-digest.sh
```

Logs are written to `scripts/logs/YYYY-MM-DD.log`.

### Backfill a missed date

Open Claude Code and run:

```
Follow the instructions in scripts/digest-prompt.md but use date 2026-05-15 instead of today.
```

Or set the date in the prompt file's Step 1 and run the script manually.

### Uninstall the schedule

```bash
bash scripts/install-schedule.sh --uninstall
```

---

## Content

Digests live in `src/content/ai/YYYY-MM-DD.md`. Each file has YAML frontmatter (title, date, tldr, action buckets) followed by the markdown body. The Astro site reads these files at build time — no database, no CMS.

To add a digest manually, create a file matching the schema in `src/content.config.ts`.

---

## Development

```bash
npm install        # install dependencies
npm run dev        # local dev server at localhost:4321
npm run build      # build to ./dist/
npm run preview    # preview the build locally
```

---

## Deploy

Pushes to `main` trigger `.github/workflows/deploy.yml`, which builds and deploys to GitHub Pages automatically. No manual steps needed.

---

## Custom domain migration (priyesh.fyi)

When DNS for `priyesh.fyi` is pointed at GitHub Pages:

1. Remove the `base: '/daily-kickoff'` line from `astro.config.mjs`
2. Push to main — all `${B}` prefixes in templates automatically collapse to `/`
3. Verify `public/CNAME` still contains `priyesh.fyi` (it does)

No other template changes needed; `import.meta.env.BASE_URL` becomes `/` once `base` is removed.
