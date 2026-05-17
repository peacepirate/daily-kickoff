# Deferred Work

## Deferred from: code review of 5-2-rva-events-astro-site-wiring (2026-05-17)

- **Non-null assertion fragility** — `themeLabels[theme]!` and `scheduleLabels[theme]!` in `[theme]/index.astro` and `[theme]/[slug].astro` silently return `undefined` if a theme is ever missing. Pre-existing pattern across all 5 existing themes; consider a typed lookup helper when adding a 7th theme.
- **Hardcoded theme arrays across 6 files** — Adding any future theme requires updates in `content.config.ts`, `Layout.astro`, `index.astro`, `watchlist.astro`, `[theme]/index.astro`, `[theme]/[slug].astro`. No single source of truth. Pre-existing; worth centralizing when theme count reaches 8+.
- **`allEntries` spread duplicated** — `index.astro` and `watchlist.astro` both manually spread all theme entries with hardcoded `themeId`/`themeLabel` mappings. Pre-existing; a shared helper would prevent label drift.
- **Slug extraction assumes `.md`/`.mdx` extension** — `entry.id.replace(/\.(md|mdx)$/, '')` pattern is shared across all pages. Pre-existing; only breaks with non-standard content file extensions.
- **`mark-all-read` trailing slash handling** — Uses `split('/').at(-1)` to extract slug; fails silently if URL has trailing slash. Pre-existing; affects all theme digest pages.
- **No cross-collection theme/folder validation** — A digest file in `src/content/rva-events/` can declare `theme: ai` and pass schema validation. Pre-existing system-wide; not enforceable without a custom Zod refinement or CI check.

## Deferred from: code review of 5-1-rva-events-source-config-and-synthesis-prompt (2026-05-17)

- **filter_regex case-sensitivity** — `re.IGNORECASE` status unverified across fetch_sources.py; uppercase event words may be missed in tier1 RSS filter. Pre-existing behavior across all topic configs.
- **Dedup boundary assumes Saturday run** — prompt logic in richmond-events.md references "Saturday run date"; if pipeline runs on another day the TODAY+1 dedup rule misbehaves. Pre-existing system-wide assumption (launchd scheduled for Saturdays).
- **`rva-events` missing from `src/content.config.ts`** — Astro content collection not registered; addressed in Story 5.2.
- **`theme: rva-events` not in digestSchema enum** — Zod schema validation will reject generated files until 5.2 adds the enum value.
- **`rva-events` absent from Astro routing** — `[theme]/index.astro` getStaticPaths, `index.astro` getCollection, and `Layout.astro` themeNav all need updating; addressed in Story 5.2.
