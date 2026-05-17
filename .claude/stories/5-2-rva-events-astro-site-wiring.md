# Story 5.2: RVA Events — Astro Site Wiring

Status: done

## Story

As a developer,
I want the `rva-events` collection registered in the Astro site with nav entry, theme card, and watchlist support,
so that Richmond Events digests are visible and accessible on priyesh.fyi alongside the other four feeds.

## Acceptance Criteria

1. **Given** `src/content.config.ts` is updated **When** the file is inspected **Then** the theme enum contains `'rva-events'` alongside the existing 5 values: `z.enum(['ai', 'leadership', 'local-llm', 'mythology', 'richmond', 'rva-events'])` **And** a new collection `'rva-events'` is defined with `glob({ pattern: '**/*.{md,mdx}', base: './src/content/rva-events' })` and `schema: digestSchema`

2. **Given** `src/layouts/Layout.astro` is updated **When** the nav sidebar renders **Then** "RVA Events" appears as the last nav item in the Themes section with correct href (`${B}rva-events`) **And** the entry count badge shows the number of `rva-events` collection entries (0 when empty) **And** `activeTheme === 'rva-events'` correctly highlights the nav item

3. **Given** `src/pages/index.astro` is updated **When** the dashboard home page is built **Then** an "RVA Events" theme card appears with `id: 'rva-events'`, `label: 'RVA Events'`, and `emptyNote: 'Upcoming events in Richmond — family activities, tech meetups, arts & dining.'` **And** rva-events `try[]` and `readDeeper[]` items appear in the Watchlist section of the dashboard

4. **Given** `src/pages/watchlist.astro` is updated **When** the watchlist page is built **Then** rva-events action items appear with source labeled `"RVA Events · [date]"` **And** done/snooze localStorage state works for rva-events items (same `wl:` key pattern as other topics)

5. **Given** `src/pages/[theme]/index.astro` is updated **When** `getStaticPaths` is inspected **Then** `{ params: { theme: 'rva-events' } }` is present in the returned array **And** `themeLabels['rva-events']` is `'Richmond Events'` **And** `scheduleLabels['rva-events']` is `'Weekly on Saturdays'`

6. **Given** `src/pages/[theme]/[slug].astro` is updated **When** `getStaticPaths` is inspected **Then** `'rva-events'` is present in the `themes` const array **And** `themeLabels['rva-events']` is `'Richmond Events'`

7. **Given** `npm run build` is run with an empty `src/content/rva-events/` directory **When** the build completes **Then** it succeeds with zero TypeScript or Zod errors **And** the `/rva-events` route is present in the build output

## Tasks / Subtasks

- [x] Update `src/content.config.ts` (AC: 1)
  - [x] Add `'rva-events'` to the theme enum in `digestSchema` (line 7 — append to existing 5 values)
  - [x] Add `'rva-events'` collection definition after the `'local-llm'` entry (same glob+schema pattern)

- [x] Update `src/layouts/Layout.astro` (AC: 2)
  - [x] Add `'rva-events'` to `Props.activeTheme` type union (line 13 — insert before `'watchlist'`)
  - [x] Add `getCollection('rva-events')` to `Promise.all` and destructure as `rvaEventsEntries` (lines 18–24)
  - [x] Add `'rva-events': rvaEventsEntries.length` to `themeCounts` object
  - [x] Add `{ id: 'rva-events', label: 'RVA Events', count: themeCounts['rva-events'] }` as last entry in `themeNav`

- [x] Update `src/pages/index.astro` (AC: 3)
  - [x] Add `getCollection('rva-events')` to `Promise.all` and destructure as `rvaEventsEntries` (lines 7–13)
  - [x] Add rva-events theme card as last entry in `themeCards` array (after local-llm card)
  - [x] Add `...rvaEventsEntries.map(e => ({ ...e, themeId: 'rva-events', themeLabel: 'RVA Events' }))` as last spread in `allEntries`

- [x] Update `src/pages/watchlist.astro` (AC: 4)
  - [x] Add `getCollection('rva-events')` to `Promise.all` and destructure as `rvaEventsEntries` (lines 7–13)
  - [x] Add `...rvaEventsEntries.map(e => ({ ...e, themeId: 'rva-events', themeLabel: 'RVA Events' }))` as last spread in `allEntries`

- [x] Update `src/pages/[theme]/index.astro` (AC: 5)
  - [x] Add `{ params: { theme: 'rva-events' } }` as last entry in `getStaticPaths()` return array
  - [x] Add `'rva-events'` to the type assertion: `Astro.params as { theme: '...' | 'rva-events' }`
  - [x] Add `'rva-events': 'Richmond Events'` to `themeLabels`
  - [x] Add `'rva-events': 'Weekly on Saturdays'` to `scheduleLabels`

- [x] Update `src/pages/[theme]/[slug].astro` (AC: 6)
  - [x] Add `'rva-events'` to `themes` const array
  - [x] Add `'rva-events': 'Richmond Events'` to `themeLabels`

- [x] Verify build and test with dummy file (AC: 7)
  - [x] Run `npm run build` — must succeed with no errors
  - [x] Create `src/content/rva-events/2026-01-01.md` with valid frontmatter (theme: rva-events), run `npm run build`, confirm `/rva-events/2026-01-01` route builds and nav shows count: 1 and `active` class
  - [x] Delete the dummy file, run `npm run build` again to confirm empty collection is valid (12 pages, `/rva-events/index.html` present)

## Dev Notes

### Exact diffs for each file

All 6 changes are **purely additive**. Do not modify any existing entries. Follow the exact same pattern as `local-llm` (most recently added in Stories 3.2/3.3).

---

#### 1. `src/content.config.ts`

**Line 7 — current:**
```ts
theme: z.enum(['ai', 'leadership', 'local-llm', 'mythology', 'richmond']),
```
**Change to:**
```ts
theme: z.enum(['ai', 'leadership', 'local-llm', 'mythology', 'richmond', 'rva-events']),
```

**After `'local-llm'` collection (after line 47 `}),`) — add:**
```ts
  'rva-events': defineCollection({
    loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/rva-events' }),
    schema: digestSchema,
  }),
```

---

#### 2. `src/layouts/Layout.astro`

**Line 13 — current Props `activeTheme` type:**
```ts
  activeTheme?: 'ai' | 'leadership' | 'local-llm' | 'mythology' | 'richmond' | 'watchlist' | 'preferences';
```
**Change to:**
```ts
  activeTheme?: 'ai' | 'leadership' | 'local-llm' | 'mythology' | 'richmond' | 'rva-events' | 'watchlist' | 'preferences';
```

**Lines 18–24 — current Promise.all:**
```ts
const [aiEntries, leadershipEntries, localLlmEntries, mythologyEntries, richmondEntries] = await Promise.all([
  getCollection('ai'),
  getCollection('leadership'),
  getCollection('local-llm'),
  getCollection('mythology'),
  getCollection('richmond'),
]);
```
**Change to:**
```ts
const [aiEntries, leadershipEntries, localLlmEntries, mythologyEntries, richmondEntries, rvaEventsEntries] = await Promise.all([
  getCollection('ai'),
  getCollection('leadership'),
  getCollection('local-llm'),
  getCollection('mythology'),
  getCollection('richmond'),
  getCollection('rva-events'),
]);
```

**Lines 26–32 — current `themeCounts`:**
```ts
const themeCounts = {
  ai: aiEntries.length,
  leadership: leadershipEntries.length,
  'local-llm': localLlmEntries.length,
  mythology: mythologyEntries.length,
  richmond: richmondEntries.length,
};
```
**Change to:**
```ts
const themeCounts = {
  ai: aiEntries.length,
  leadership: leadershipEntries.length,
  'local-llm': localLlmEntries.length,
  mythology: mythologyEntries.length,
  richmond: richmondEntries.length,
  'rva-events': rvaEventsEntries.length,
};
```

**Lines 34–40 — current `themeNav`:**
```ts
const themeNav = [
  { id: 'ai',         label: 'AI Intelligence',    count: themeCounts.ai },
  { id: 'leadership', label: 'Eng Leadership',      count: themeCounts.leadership },
  { id: 'mythology',  label: 'Mythology Research',  count: themeCounts.mythology },
  { id: 'richmond',   label: 'Richmond & Family',   count: themeCounts.richmond },
  { id: 'local-llm',  label: 'Local LLM',           count: themeCounts['local-llm'] },
];
```
**Change to:**
```ts
const themeNav = [
  { id: 'ai',          label: 'AI Intelligence',    count: themeCounts.ai },
  { id: 'leadership',  label: 'Eng Leadership',      count: themeCounts.leadership },
  { id: 'mythology',   label: 'Mythology Research',  count: themeCounts.mythology },
  { id: 'richmond',    label: 'Richmond & Family',   count: themeCounts.richmond },
  { id: 'local-llm',   label: 'Local LLM',           count: themeCounts['local-llm'] },
  { id: 'rva-events',  label: 'RVA Events',          count: themeCounts['rva-events'] },
];
```

---

#### 3. `src/pages/index.astro`

**Lines 7–13 — current Promise.all:**
```ts
const [aiEntries, leadershipEntries, localLlmEntries, mythologyEntries, richmondEntries] = await Promise.all([
  getCollection('ai'),
  getCollection('leadership'),
  getCollection('local-llm'),
  getCollection('mythology'),
  getCollection('richmond'),
]);
```
**Change to:**
```ts
const [aiEntries, leadershipEntries, localLlmEntries, mythologyEntries, richmondEntries, rvaEventsEntries] = await Promise.all([
  getCollection('ai'),
  getCollection('leadership'),
  getCollection('local-llm'),
  getCollection('mythology'),
  getCollection('richmond'),
  getCollection('rva-events'),
]);
```

**After the `local-llm` themeCard entry (after line 55 `},`) — add:**
```ts
  {
    id: 'rva-events',
    label: 'RVA Events',
    latest: latestEntry(rvaEventsEntries),
    emptyNote: 'Upcoming events in Richmond — family activities, tech meetups, arts & dining.',
    count: rvaEventsEntries.length,
  },
```

**Lines 66–72 — current `allEntries` spread:**
```ts
const allEntries = [
  ...aiEntries.map(e => ({ ...e, themeId: 'ai', themeLabel: 'AI Intelligence' })),
  ...leadershipEntries.map(e => ({ ...e, themeId: 'leadership', themeLabel: 'Eng Leadership' })),
  ...mythologyEntries.map(e => ({ ...e, themeId: 'mythology', themeLabel: 'Mythology' })),
  ...richmondEntries.map(e => ({ ...e, themeId: 'richmond', themeLabel: 'Richmond & Family' })),
  ...localLlmEntries.map(e => ({ ...e, themeId: 'local-llm', themeLabel: 'Local LLM' })),
].sort((a, b) => b.data.date.getTime() - a.data.date.getTime());
```
**Change to:**
```ts
const allEntries = [
  ...aiEntries.map(e => ({ ...e, themeId: 'ai', themeLabel: 'AI Intelligence' })),
  ...leadershipEntries.map(e => ({ ...e, themeId: 'leadership', themeLabel: 'Eng Leadership' })),
  ...mythologyEntries.map(e => ({ ...e, themeId: 'mythology', themeLabel: 'Mythology' })),
  ...richmondEntries.map(e => ({ ...e, themeId: 'richmond', themeLabel: 'Richmond & Family' })),
  ...localLlmEntries.map(e => ({ ...e, themeId: 'local-llm', themeLabel: 'Local LLM' })),
  ...rvaEventsEntries.map(e => ({ ...e, themeId: 'rva-events', themeLabel: 'RVA Events' })),
].sort((a, b) => b.data.date.getTime() - a.data.date.getTime());
```

---

#### 4. `src/pages/watchlist.astro`

**Same pattern as index.astro for both Promise.all and allEntries.**

**Lines 7–13 — current Promise.all:** (identical to index.astro current — same change applies)
Add `rvaEventsEntries` to destructure and `getCollection('rva-events')` to the call.

**Lines 24–30 — current `allEntries` spread:**
```ts
const allEntries = [
  ...aiEntries.map(e => ({ ...e, themeId: 'ai', themeLabel: 'AI Intelligence' })),
  ...leadershipEntries.map(e => ({ ...e, themeId: 'leadership', themeLabel: 'Eng Leadership' })),
  ...mythologyEntries.map(e => ({ ...e, themeId: 'mythology', themeLabel: 'Mythology' })),
  ...richmondEntries.map(e => ({ ...e, themeId: 'richmond', themeLabel: 'Richmond & Family' })),
  ...localLlmEntries.map(e => ({ ...e, themeId: 'local-llm', themeLabel: 'Local LLM' })),
].sort((a, b) => b.data.date.getTime() - a.data.date.getTime());
```
**Change to:** (add `rvaEventsEntries` line before `.sort(`)
```ts
const allEntries = [
  ...aiEntries.map(e => ({ ...e, themeId: 'ai', themeLabel: 'AI Intelligence' })),
  ...leadershipEntries.map(e => ({ ...e, themeId: 'leadership', themeLabel: 'Eng Leadership' })),
  ...mythologyEntries.map(e => ({ ...e, themeId: 'mythology', themeLabel: 'Mythology' })),
  ...richmondEntries.map(e => ({ ...e, themeId: 'richmond', themeLabel: 'Richmond & Family' })),
  ...localLlmEntries.map(e => ({ ...e, themeId: 'local-llm', themeLabel: 'Local LLM' })),
  ...rvaEventsEntries.map(e => ({ ...e, themeId: 'rva-events', themeLabel: 'RVA Events' })),
].sort((a, b) => b.data.date.getTime() - a.data.date.getTime());
```

---

#### 5. `src/pages/[theme]/index.astro`

**Lines 8–14 — current `getStaticPaths` return:**
```ts
  return [
    { params: { theme: 'ai' } },
    { params: { theme: 'leadership' } },
    { params: { theme: 'local-llm' } },
    { params: { theme: 'mythology' } },
    { params: { theme: 'richmond' } },
  ];
```
**Change to:**
```ts
  return [
    { params: { theme: 'ai' } },
    { params: { theme: 'leadership' } },
    { params: { theme: 'local-llm' } },
    { params: { theme: 'mythology' } },
    { params: { theme: 'richmond' } },
    { params: { theme: 'rva-events' } },
  ];
```

**Line 17 — current type assertion:**
```ts
const { theme } = Astro.params as { theme: 'ai' | 'leadership' | 'local-llm' | 'mythology' | 'richmond' };
```
**Change to:**
```ts
const { theme } = Astro.params as { theme: 'ai' | 'leadership' | 'local-llm' | 'mythology' | 'richmond' | 'rva-events' };
```

**Lines 19–25 — current `themeLabels`:**
```ts
const themeLabels: Record<string, string> = {
  ai:         'AI Intelligence',
  leadership: 'Engineering Leadership',
  'local-llm': 'Local LLM',
  mythology:  'Mythology Research',
  richmond:   'Richmond & Family',
};
```
**Change to:**
```ts
const themeLabels: Record<string, string> = {
  ai:           'AI Intelligence',
  leadership:   'Engineering Leadership',
  'local-llm':  'Local LLM',
  mythology:    'Mythology Research',
  richmond:     'Richmond & Family',
  'rva-events': 'Richmond Events',
};
```

**Lines 27–33 — current `scheduleLabels`:**
```ts
const scheduleLabels: Record<string, string> = {
  ai:         'Daily Mon–Sat',
  leadership: 'Weekly on Saturdays',
  'local-llm': 'Weekly on Saturdays',
  mythology:  'Manual',
  richmond:   'Weekly on Saturdays',
};
```
**Change to:**
```ts
const scheduleLabels: Record<string, string> = {
  ai:           'Daily Mon–Sat',
  leadership:   'Weekly on Saturdays',
  'local-llm':  'Weekly on Saturdays',
  mythology:    'Manual',
  richmond:     'Weekly on Saturdays',
  'rva-events': 'Weekly on Saturdays',
};
```

---

#### 6. `src/pages/[theme]/[slug].astro`

**Line 7 — current `themes` const:**
```ts
  const themes = ['ai', 'leadership', 'local-llm', 'mythology', 'richmond'] as const;
```
**Change to:**
```ts
  const themes = ['ai', 'leadership', 'local-llm', 'mythology', 'richmond', 'rva-events'] as const;
```

**Lines 24–30 — current `themeLabels`:**
```ts
const themeLabels: Record<string, string> = {
  ai:          'AI Intelligence',
  leadership:  'Engineering Leadership',
  'local-llm': 'Local LLM',
  mythology:   'Mythology Research',
  richmond:    'Richmond & Family',
};
```
**Change to:**
```ts
const themeLabels: Record<string, string> = {
  ai:           'AI Intelligence',
  leadership:   'Engineering Leadership',
  'local-llm':  'Local LLM',
  mythology:    'Mythology Research',
  richmond:     'Richmond & Family',
  'rva-events': 'Richmond Events',
};
```

---

### Critical constraints

- **Do NOT change `digestSchema`** — it is shared across all collections; `rva-events` reuses it unchanged (NFR6)
- **Do NOT touch `scripts/`** — pipeline config and prompts are Story 5.1 (done)
- **Do NOT modify existing theme entries** — only append `rva-events`; existing nav order, counts, routes must be preserved
- **`src/content/rva-events/.gitkeep`** was created in Story 5.1 — do not recreate it
- **`npm run build` must pass** both with empty `rva-events/` (normal case) and with 1+ digest files (post-Story 5.3)
- **`getStaticPaths` in `[theme]/[slug].astro`** iterates themes and calls `getCollection(theme)` — adding `'rva-events'` to the array is sufficient; no other changes needed in that file's logic

### Dummy file frontmatter (for build test)

```yaml
---
title: "Richmond Events — Jan 01–Jan 31, 2026"
date: 2026-01-01
theme: rva-events
format: weekly-synthesis
tldr: "Test digest for build validation."
itemCount: 1
readTimeMinutes: 1
sources:
  - title: "Test Source"
    url: "https://visitrichmondva.com/events/"
actions:
  try:
    - "Test ATTEND event"
  share: []
  readDeeper: []
  skip: []
---

Test content.
```

### Project Structure Notes

- All 6 files are in `src/` — no changes to `scripts/` or any other directory
- The `rva-events` collection follows the exact same pattern as `local-llm` (last added)
- `Layout.astro` is the **single source of truth** for the sidebar nav — it drives count badges across all pages; it must include `rva-events` in both `themeCounts` and `themeNav`
- The `[theme]/index.astro` `getCollection(theme)` call at line 38 uses the `theme` Astro.params value directly — this automatically works once `rva-events` is in `content.config.ts` and `getStaticPaths`

### References

- Previous story: [5-1-rva-events-source-config-and-synthesis-prompt.md](5-1-rva-events-source-config-and-synthesis-prompt.md) — Story 5.1 done; rva-events/ dir + gitkeep already exist
- Pattern source: Stories 3.2 (collection) + 3.3 (site pages) — the local-llm precedent these changes mirror exactly
- Deferred from Story 5.1 review: all 3 HIGH edge-case findings (content.config.ts, schema, routing) are resolved by this story
- Epic FR coverage: FR-E08 (separate Astro collection), FR-E09 (digestSchema reuse), FR-E12 (6 file updates)

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

- `npm run build` (empty rva-events): 12 pages, `/rva-events/index.html` present, zero Zod errors — PASS
- `npm run build` (with dummy 2026-01-01.md, theme: rva-events): 13 pages, `/rva-events/2026-01-01/index.html` built, nav active class confirmed in rendered HTML — PASS
- `npm run build` (post-dummy-delete, cleared node_modules/.astro/data-store.json): 12 pages, clean — PASS
- Note: Astro content layer caches in `node_modules/.astro/data-store.json`; must clear this + `dist` + `.astro` for truly clean builds during testing

### Completion Notes List

- Updated all 6 Astro files following exact same additive pattern as `local-llm` (Stories 3.2/3.3)
- `digestSchema` unchanged — `rva-events` reuses it as-is per NFR6
- `content.config.ts`: added `'rva-events'` to theme enum and added collection definition
- `Layout.astro`: added `rva-events` to Props type, Promise.all, themeCounts, themeNav
- `index.astro` + `watchlist.astro`: same Promise.all + allEntries spread pattern
- `[theme]/index.astro`: added to getStaticPaths, type assertion, themeLabels, scheduleLabels
- `[theme]/[slug].astro`: added to themes const array and themeLabels
- Verified rendered HTML: nav shows "RVA Events" with correct `active` class and count badge

### File List

- `src/content.config.ts` (UPDATED)
- `src/layouts/Layout.astro` (UPDATED)
- `src/pages/index.astro` (UPDATED)
- `src/pages/watchlist.astro` (UPDATED)
- `src/pages/[theme]/index.astro` (UPDATED)
- `src/pages/[theme]/[slug].astro` (UPDATED)

## Senior Developer Review (AI)

**Review Date:** 2026-05-17
**Reviewer:** claude-sonnet-4-6 (bmad-code-review)
**Outcome:** ✅ APPROVED — Clean review, zero patches required

### Summary

All 7 ACs: PASS. All 6 file changes verified correct and additive-only. Zero regressions to existing themes.

### Findings

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| 1 | info | `src/content/rva-events/` directory existence not verified in diff | DISMISSED — directory created by Story 5.1 gitkeep; confirmed present |
| 2 | info | Nav label "RVA Events" vs page title "Richmond Events" inconsistency | DISMISSED — intentional per spec: AC2 specifies "RVA Events" for nav, AC5 specifies "Richmond Events" for themeLabels |
| 3 | info | themeCards/allEntries ordering not sorted to match themeNav order | DISMISSED — ordering is orthogonal; both work correctly without alignment |
| 4 | low | Non-null assertion fragility (`themeLabels[theme]!`) | DEFERRED → deferred-work.md (pre-existing across all 5 existing themes) |
| 5 | low | Hardcoded theme arrays across 6 files (no single source of truth) | DEFERRED → deferred-work.md (pre-existing; worth centralizing at 8+ themes) |
| 6 | low | `allEntries` spread duplicated in index.astro and watchlist.astro | DEFERRED → deferred-work.md (pre-existing pattern) |
| 7 | low | Slug extraction assumes `.md`/`.mdx` extension | DEFERRED → deferred-work.md (pre-existing pattern) |
| 8 | low | `mark-all-read` trailing slash handling fragile | DEFERRED → deferred-work.md (pre-existing; Story 5.2 did not introduce) |
| 9 | low | No cross-collection theme/folder validation | DEFERRED → deferred-work.md (pre-existing system-wide) |

### Action Items

- [ ] (none — all findings dismissed or deferred; no patches required)

## Change Log

| Date | Change | Author |
|------|--------|--------|
| 2026-05-17 | Implemented all 6 Astro file updates; all 3 build validations passed | claude-sonnet-4-6 |
| 2026-05-17 | Code review completed — clean approval, 0 patches, 6 deferred to deferred-work.md | claude-sonnet-4-6 |
