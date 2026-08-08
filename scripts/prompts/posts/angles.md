# Weekly Angle Generation Task

You are generating candidate **content angles** for Priyesh Jain — not posts. The source content has already been fetched and is appended below — do not fetch additional URLs. Use only what is provided.

## WHO PRIYESH IS
- Senior Engineering Manager at a large, heavily regulated financial-services enterprise
- Directly leads 6–10 engineering teams; accountable for hiring, performance and delivery
- Running agentic-coding adoption across those teams — rollout, governance, review load, trust
- **His organization is a follower, not a frontier adopter.** It is deliberately behind the rollouts the source material describes. His experience is real, but it does not corroborate frontier claims — and an angle that needs it to is an angle he cannot post
- Builds in public: this pipeline (Daily Kickoff), the studio behind it, and other side projects
- Publishes on LinkedIn and X, text-first, ~2 posts a week
- Audience: engineering leaders — his own leadership chain at Director+ and peer EMs elsewhere

## WHAT AN ANGLE IS
An angle is a *reason to write*, captured tightly enough that drafting becomes mechanical: a thesis someone could disagree with, a reason it is worth saying this week, and the evidence that makes it his to say.

You produce 6–10 candidates. A human reads them on Sunday and drafts 2–3. So breadth of genuinely different ideas beats polish on any one of them. **Do not write posts.** No hooks, no openings, no closing lines, no hashtags.

Each heading number is a stable id: `A1` in week `{{WEEK}}` is addressed as `{{WEEK}}/A1` when it is drafted. Number sequentially from A1 with no gaps.

## THE THESIS EVERYTHING SERVES
**AI adoption is a change-management problem, not a tooling problem.**

Every angle should be a specific, falsifiable expression of that belief — or an honest challenge to it, from evidence. An angle that is really just "a new model / tool / benchmark shipped" is the failure mode. That is a news summary, and the digest already wrote it.

## THE FOUR PILLARS
Every angle declares exactly one, by number:

1. **Agentic coding at enterprise scale** — what actually happens when coding agents are rolled out across roughly ten teams inside a large regulated enterprise. Legitimate, and the hardest pillar to make publishable: most of what is interesting here rests on detail that cannot leave the building. Expect its angles to score low on provability, and do not reach for it to fill the set.
2. **Engineering leadership in the AI era** — review throughput as the new bottleneck, trust calibration, hiring, what the career ladder becomes. Direct Director+ resonance. **This is the anchor pillar**: expect roughly half the angles here, and never zero.
3. **Build in public** — the Daily Kickoff pipeline itself and the other side projects. Proof-of-work: what was built, what broke, what it cost, what it taught.
4. **The adoption gap** — why most AI pilots stall. The bridge pillar: told at enterprise scale it earns credibility, and the same argument generalizes downward later.

Spread the set across pillars. Eight angles that are all pillar 1 is one angle with eight titles.

## ALTITUDE
`altitude: enterprise` on **every** angle, without exception.

A second altitude — small-business — exists in the wider plan and is **out of bounds in this window.** It is gated behind an unresolved employer-policy question and three months of enterprise-altitude publishing that has not happened yet. An angle pitched at small-business owners is not a useful find; it is a defect in this output and it will be discarded. Do not reach for it, and do not hedge an angle toward it.

Enterprise altitude means peer to peer, measured, evidence-led. No call to action. No selling. Nothing that reads as a service offer. Report from inside the work.

## THE DIFFERENTIATOR — inference, not access

The competition writes engineering leadership in general. What distinguishes an angle here is never a claim to have seen something the reader has not — it is a reading of public material the reader has not done. The edge is analytical: the second-order consequence pulled out of two items published in the open, the category a problem gets refiled under, the number a source reported without noticing what it implied.

**Nothing may rest on privileged access.** No internal metric, no internal process, no internal outcome, no rollout detail, and nothing else that is not already public. An angle whose force comes from "he saw something you did not" is not a strong angle — it is an unpublishable one, and the strongest-sounding of them are the most expensive to discover late.

Apply two tests to every candidate before you keep it. They are the two scored dimensions that gate hardest, and they pull in different directions on purpose:

> **The provability test.** If you deleted every sentence only someone inside the author's organization could write, would the thesis still stand?

If it would not, that is not a reason to hide the angle. Name exactly what is missing in `blocker:` and score `provability` at 1 or 0.

> **The edge test.** Could a smart person with the same feed reach this thesis in one step — without combining two items, and without changing the category the problem sits in?

If they could, sharpen it until they could not, or cut it. Prefer the angle that costs something to say — a claim that could turn out wrong, a tension two sources leave unresolved — over the angle that restates what one source already said.

## FILTERING

**KEEP — the shapes that work:**
- A second-order consequence nobody is discussing yet: the tool shipped, so what breaks downstream in review, hiring, on-call or governance
- A tension between two things in the bundle that cannot both be true
- A claim from the corpus that his own experience contradicts, or confirms harder than the source dared
- A concrete mechanism: what specifically changes in a team's week, not that "things change"
- A number worth arguing with — from the corpus, or a public one his experience calls into question
- A build-in-public artifact: something in this pipeline that generalizes to how anyone should ship

**DROP — do not offer these:**
- Tool round-ups, model comparisons, release recaps
- Prediction pieces with no mechanism ("by 2027, agents will…")
- Anything whose evidence is one vendor's blog post about its own product
- Advice with no cost: takes nobody would argue with ("communication matters")
- An angle whose thesis *is* a claim about the author's own organization — delete the insider sentences and nothing is left standing (see the `provability` anchors below)
- Anything at small-business altitude

## HOW TO READ THE SOURCE MATERIAL

The content below opens with three header lines, then three sections:

```
# CORPUS <start> → <end>     the window this material covers
# coverage: …                what was actually available, with gaps named
# signals:  …                how fresh the starred / noted signal is

## YOUR NOTES     his own captured notes, in his words
## YOUR SIGNAL    items he starred, noted or marked done on the site
## CORPUS         published digests, ranked best-first
```

**Notes and signal outrank the corpus.** They are the only material here that nobody else has. One note is worth more than five digest summaries: build angles on the notes first, and let the corpus supply the peg and the links.

**Both are often empty.** `(none)` under `## YOUR NOTES` or `## YOUR SIGNAL` is normal and not an error. When they are empty, work from the corpus alone — still 6 to 10 angles, but expect them to lean on tensions and second-order consequences in the corpus rather than on lived detail. **Never invent a note, a conversation, a metric, a rollout detail or an anecdote to fill the gap.** A fabricated personal detail is the worst failure available to you here, because it reads as the most credible part of the post.

**The corpus is ranked, best-first.** Later items are not worthless, but an angle that can only be supported from the bottom of the list is usually a weak angle.

## EVIDENCE AND CITATIONS — mechanical, and checked

Every angle carries an `evidence:` list of **at least one** bullet. Each bullet takes one of two forms:

```
  - `[<theme>/<YYYY-MM-DD>]` what it shows, in your own words — <the item's URL from the bundle>
  - `[note <YYYY-MM-DD>]` what he observed
```

- `<theme>` and `<YYYY-MM-DD>` come from the item's `URL:` and `DATE:` lines. An item with `URL: https://priyesh.fyi/daily-kickoff/leadership/2026-08-01` and `DATE: 2026-08-01` is cited `` `[leadership/2026-08-01]` ``.
- A `[note …]` date is the date on that note's heading under `## YOUR NOTES`.
- The citation token is always wrapped in backticks.

Hard rules. An automated validator reads the file after you write it:

- **Cite only what is in the bundle.** Every citation is resolved against files on disk. One that does not resolve fails the run, quarantines the file, and nothing is published.
- **Never invent a date, and never adjust one** — not to make a peg fresher, not to fill a gap, not because a date looks about right. Copy it.
- **Cite the digest, not the articles inside it.** Outbound links quoted in a digest summary are not citable items.
- If an angle cannot be supported by at least one real citation, **drop the angle.** Six well-evidenced angles beat ten with one invented reference.

## COVERAGE — state what you could not see
Copy the `# coverage:` line from the bundle **verbatim** into `corpusCoverage`, gaps and all. Do not tidy it, do not drop the `(gap …)` parentheses, do not recompute the counts.

The gaps matter more than the counts. A missing day is weather, not an error — but an angle whose why-now sits inside a gap is standing on ground you could not see. Say that in the angle's `prep:` rather than writing around it.

## BLOCKER AND PREP — two fields, because they answer two different questions

`blocker:` predicts whether an angle can be published at all. `prep:` predicts how much work it needs. They drive different decisions, so they are separate fields and neither may carry the other's content.

**`blocker:` — what cannot be published.** Either the literal `none`, or one sentence naming *specifically* what the sharp version of this angle needs and cannot have. Anything not already public — internal metrics, team or project names, unreleased plans, vendor contracts, named colleagues, customer data, incident detail — cannot be published, and an angle that collapses without it must say so:

```
- **blocker:** the sharp version rests on internal rollout numbers — only a weakened version survives on public proxies
```

`blocker: none` means every load-bearing element of the thesis is already public. It is an honest and common answer. But **never write `none` to make an angle look cleaner, and never soften a real blocker into `prep:`** — a named blocker costs the angle nothing that hiding it would not cost more, later and more expensively. Nothing rejects an angle for having one.

**`prep:` — the craft half.** What a reviewer must do before drafting: a verification pass against a primary source, a proposed alternative the angle is missing, a number to go find, a drift to avoid, a live story that may move under the draft, a claim standing in a coverage gap. One line, specific. "None" is rarely true here and never useful.

**Never name the employer, a colleague, a customer or a vendor under contract anywhere in your output.** Write "a large regulated enterprise", "one of the teams", "a vendor". This file is reviewed by a human before anything is published, but it is written by a machine and read in a hurry — do not put a name in it that would have to be caught later.

## SCORING — four numbers you commit to

Every angle carries four scores, each an integer `0`–`3` followed by ` — ` and one clause of justification. You are recording a prediction; a human records the outcome separately, on the same angle, later. The whole point is that the two can be compared afterwards — which is worth nothing unless the numbers are honest at the moment you write them.

**Score honestly, and never withhold an angle because of the number you would have to give it.** Do not round a score up so an angle reads as postable, do not re-score a set so it looks consistent, and do not delete a written angle to keep a low score out of the file. An angle scored 1 and labelled as such is useful. An angle scored 3 that should have been 1 is exactly the failure this exists to catch.

**A week's scores with no spread in `provability` or `consequence` is itself a defect.** If every angle comes out `provability: 3, consequence: 3`, the scores have stopped carrying information, and the set needs re-reading rather than re-writing. No automated check enforces this — it is a standard you hold yourself to, and the human reading on Sunday will see it immediately.

### `score provability:` — how much of the thesis survives without insider material

Delete every sentence only someone inside the author's organization could write. Score what is left.

| | |
|---|---|
| 0 | No claim remains. The thesis *is* an assertion about the author's organization. |
| 1 | A weakened version survives and is publishable, but the sharp version needs material that cannot be disclosed. `blocker:` names that material. |
| 2 | Every load-bearing element is public and cited, but one source carries the argument and its framing is unverified or contested. |
| 3 | Every load-bearing element is public and cited, and no single item is load-bearing alone. Remove any one citation and the thesis stands. |

### `score consequence:` — what a reader changes on Monday

"Reader" means the declared audience — his leadership chain at Director+ and peer engineering managers — not any reader.

| | |
|---|---|
| 0 | The reader agrees and changes nothing. The claim is about the world, not about anything they operate. |
| 1 | The reader gains a name for something they already do. No artifact changes. |
| 2 | The reader would go *look at* something they own — a metric, a control, a job description — to check whether the claim applies. |
| 3 | The angle names the artifact **and** the change. A reader who agrees has a specific edit for their next planning cycle. |

### `score edge:` — inference over public material, or access to what the reader lacks

| | |
|---|---|
| 0 | Interesting only if you believe the author saw something you did not. Its force is positional. |
| 1 | Restates what one source already says. A reader of the same feed gets there in one step. |
| 2 | Combines two or more feed items into something neither says alone. |
| 3 | **Reframes** — changes the category the reader files the problem under — and holds with zero private information. |

### `score readiness:` — work between this angle and a publishable draft

Higher means less work. Readiness is not quality: an angle that drafts straight through is cheaper, not better, and this is the one dimension that decides nothing.

| | |
|---|---|
| 0 | Cannot be drafted this week. Blocked on something outside the author's control. |
| 1 | Needs a substantive addition the angle does not contain: a proposed alternative, a worked example, a number to go find. |
| 2 | Needs one verification pass against a primary source, then drafts straight through. |
| 3 | Drafts from the angle as written. |

## VERDICT — always exactly `pending`

Write `- **verdict:** pending` on every angle. Never anything else, and never a reason attached to it.

`verdict:` is the human's field, not yours: they overwrite it on Sunday with what they decided and why, and that decision is the only independent measurement of whether your scores were right. A generated file carrying any other verdict is rejected by the validator and the run fails.

## REQUIRED OUTPUT FORMAT

Exactly this shape. The frontmatter block first, then one `## A<n>` section per angle, and nothing else:

```
---
week: {{WEEK}}
generated: {{DATE}}
corpusCoverage: "<the # coverage: line from the bundle, verbatim>"
angleCount: <integer — must equal the number of ## A headings below>
schemaVersion: 2
---

## A1 — <short, specific, arguable title>
- **pillar:** <1–4> — <the pillar's name>
- **altitude:** enterprise
- **thesis:** <one sentence; arguable and falsifiable — someone could hold the opposite view>
- **why now:** <what in this week's material makes it timely, with the link that pegs it>
- **evidence:**
  - `[<theme>/<YYYY-MM-DD>]` <what it shows, in your words> — <URL from the bundle>
  - `[note <YYYY-MM-DD>]` <what he observed>
- **blocker:** none | <one sentence naming what specifically cannot be published>
- **prep:** <what a reviewer must do before drafting>
- **verdict:** pending
- **score provability:** <0-3> — <one clause>
- **score consequence:** <0-3> — <one clause>
- **score edge:** <0-3> — <one clause>
- **score readiness:** <0-3> — <one clause>

## A2 — <…>
- **pillar:** …
```

A filled angle, for register and density only — **do not copy its content or its citations**, they are not in your bundle:

```
## A1 — Review became the bottleneck, and nobody owned it
- **pillar:** 2 — Engineering leadership in the AI era
- **altitude:** enterprise
- **thesis:** Agentic coding moves the constraint from writing code to reviewing it, and most orgs have no owner, no budget and no metric for review capacity.
- **why now:** Two pieces this week land on the same point from opposite directions — collaboration erosion, and productivity gains landing near 10% rather than 10x.
- **evidence:**
  - `[leadership/2026-08-01]` coding agents erode team collaboration, paired with a 10%-not-10x reality check — https://priyesh.fyi/daily-kickoff/leadership/2026-08-01
- **blocker:** none
- **prep:** verify the 10% figure against the primary source rather than the digest summary
- **verdict:** pending
- **score provability:** 2 — every load-bearing element is public and cited, but one digest carries the argument
- **score consequence:** 2 — a reader would go look at whether anyone owns review capacity
- **score edge:** 2 — combines two findings in one digest into a claim neither makes alone
- **score readiness:** 2 — one verification pass against the primary source, then it drafts
```

## IMPORTANT — hard requirements

A file that breaks any of these is rejected by an automated validator, quarantined, and the run fails. They are not stylistic.

- **6 to 10 angles.** Fewer than 6 fails. More than 10 fails. If the material only supports 6, write 6.
- **Headings are `## A<n> — <title>`**, `<n>` sequential from 1 with no gaps, no duplicates, and an em dash separating number from title.
- **`angleCount` in the frontmatter equals the number of `## A<n>` headings.** Count them; do not estimate.
- **`week:` is exactly `{{WEEK}}`** and **`generated:` is exactly `{{DATE}}`**. Do not compute your own week number.
- **`schemaVersion: 2` in the frontmatter.** Omitting it declares the file legacy, and every score field is then rejected.
- **All twelve fields on every angle**, in this order, with these exact bold labels: `pillar`, `altitude`, `thesis`, `why now`, `evidence`, `blocker`, `prep`, `verdict`, `score provability`, `score consequence`, `score edge`, `score readiness`. No extra fields, none omitted, none renamed, none reordered — the order is checked, and `risk:` is no longer a field.
- **Every `score <dim>:` is a single digit `0`–`3`, then ` — `, then a non-empty justification clause.** No decimals, no words, no missing clause.
- **`verdict:` is exactly `pending`** on every angle. Any other value fails the run.
- **`evidence:` is a nested list of at least one bullet**, indented two spaces beneath it. Never inline text on the `evidence:` line itself.
- **`altitude:` is `enterprise`** on every angle.
- **`pillar:` is a single digit 1–4** followed by that pillar's name.
- Write the file directly. Do not wrap it in a code fence, and do not add any heading, preamble or commentary outside the frontmatter and the `## A<n>` sections.

---

## STEP 1 — Check the output file

Run date: {{DATE}}
Week: {{WEEK}}

Check: does `{{STUDIO_DIR}}/angles/{{WEEK}}.md` already exist? If yes, print "Already exists — skipping." and stop.

## STEP 2 — Write the angles file

Using the source content below, write `{{STUDIO_DIR}}/angles/{{WEEK}}.md` in the format above.

Work in this order: read the notes and signal first and mine them for what only he can say; read the corpus for pegs, tensions and links; draft more candidates than you need; sharpen or cut the ones that fail the edge test; drop the ones you cannot cite; then score everything that remains, low scores included.

## STEP 3 — Write the file only (do NOT commit)

The orchestrator (`run-jobs.sh`) handles all git operations. Do not run `git add`, `git commit` or `git push`. Do not write anywhere else — in particular, never under `src/content/`, which is the published site and this job's own corpus.

Print: "✓ Weekly angles for {{WEEK}} written to {{STUDIO_DIR}}/angles/{{WEEK}}.md"
