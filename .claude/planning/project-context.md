# Project Context — Daily Kickoff (priyesh.fyi)

## What This Project Is
A personal AI-curated digest site. Astro 6 + Tailwind v4, deployed to GitHub Pages at priyesh.fyi. Content is auto-generated nightly via a macOS launchd job that runs Python (source fetching) + Claude Code CLI (synthesis).

## Owner
Priyesh Jain — Senior Engineering Manager, a large regulated financial-services company, Richmond VA. Leads agentic coding adoption across 6–10 engineering teams. Works on AI/ML document ingestion (OCR, Azure AI Search, RAG) for small business card underwriting. Uses Claude Code via AWS Bedrock at work. Side project: Gods of the Future Past (kids' mythology content platform using local LLM inference).

## Tech Stack
- Site: Astro 6, Tailwind v4, TypeScript, MDX
- Content: Astro content collections with glob loader, shared Zod `digestSchema`
- Fetching: Python 3.11+, httpx, feedparser, beautifulsoup4, pyyaml — isolated venv at `scripts/.venv/`
- Synthesis: Claude Code CLI (`claude --dangerously-skip-permissions --print`)
- Scheduling: macOS launchd (11pm nightly)
- Deploy: GitHub Actions `deploy.yml` triggers on push to main → GitHub Pages

## Content Collections
- `src/content/ai/` — daily AI news digests (Mon–Sat)
- `src/content/leadership/` — weekly EM/leadership synthesis (Saturdays)
- `src/content/richmond/` — weekly Richmond & Virginia local news (Saturdays)
- `src/content/local-llm/` — weekly local LLM ecosystem updates (Saturdays) [NEW in v2]
- `src/content/mythology/` — manual research notes (Gods of the Future Past)

## Shared Frontmatter Schema (digestSchema)
All collections use the same Zod schema:
```yaml
title: string
date: date
theme: enum[ai, leadership, local-llm, mythology, richmond]
format: enum[daily, weekly-synthesis]
tldr: string
itemCount: number
readTimeMinutes: number
sources: [{title, url}]
actions:
  try: string[]
  share: [{what, who}]
  readDeeper: string[]
  skip: string[]
```

## Key Constraints
- No Anthropic API key — uses Claude Code subscription via CLI
- No schema changes in v2 — synthesis prompts map topic-specific actions to existing fields
- Pipeline must run unattended with zero interactive prompts
- Single git commit per nightly run covering all topics
- Failure in one topic must not block other topics from committing

## Coding Standards
- Python: standard library + explicitly installed deps only; no framework overhead
- Shell: `set -euo pipefail`; quote all variables; avoid `source ~/.zshrc` (breaks bash)
- TypeScript: follow existing Astro patterns in the codebase; no new abstractions
- YAML: topic configs are data-only — no executable logic
- Tests: bash scripts are tested by dry-run execution; Python fetcher by manual invocation
