---
name: slop-cleaner
description: Audit a directory of code for AI-generated "slop" — style and maintainability problems like silent fallbacks, over-broad contracts, reinvented utilities, over-engineered abstractions, chatty comments, and defensive dead code — and produce a prioritized, actionable cleanup plan. Use when the user invokes $slop-cleaner or points you at a directory and asks for a style/maintainability report or cleanup suggestions. No git required: the user gives a path, you give a report.
---

# Slop Cleaner

Audit a directory the user hands you and produce a report of concrete, actionable cleanup suggestions. The target is "slop": code that runs but is hard to read, hard to change, and hard to trust — the residue of unreviewed AI generation and copy-paste.

This skill does **not** need git. There is no PR, no diff, no branch. The user gives a directory path; you read the code, spot the slop, and hand back a prioritized plan. Do not modify code unless the user explicitly asks — default output is a report.

## Core Rules

- Take the directory path from the user. If none is given, ask for one explicit path.
- Read whole files, not fragments. A finding judged from a snippet is often wrong once you see the full file and its callers.
- Before calling something duplicated or reinventable, search the directory (and obvious shared/util locations) for the existing helper. Prove it exists.
- Match the report to the code's own conventions. "Slop" is relative to the surrounding style — flag what breaks the local pattern, not what breaks your personal taste.
- Stay concrete. Every suggestion gets a `file:line`, a reason it costs the team, and a specific fix. No vague "make this cleaner."
- It is fine to find little. A short, high-signal report beats a padded one. The metric is the quality of each finding, never the count.
- Don't touch git, don't push, don't comment on anything remote. Save the report as a local artifact only.

## How To Spot Slop

This is the heart of the skill. Read for these patterns. They cluster — one file with chatty comments usually also has defensive dead code and a reinvented helper.

### Silent fallbacks and swallowed errors

The most damaging slop, because it hides bugs instead of merely annoying readers.

- **Broad `try/except` (or `try/catch`) that swallows.** Look at every one. Does it catch a wide class and then log-and-continue, return a default, or `pass`? That converts a loud, debuggable failure into a silent wrong result. Code should fail naturally at the point of breakage. Flag any catch that masks programmer error or a broken invariant.
- **Over-broad data contracts.** A function whose real contract is "a tensor" but that accepts `None`, then guards `if x is None: return ...`. The `None` path usually can't happen on the real call sites — it's defensive padding that adds a branch, a test surface, and a lie about the contract. Narrow the type, delete the guard.
- **Validation in the wrong layer.** Public boundaries should validate inputs; internal helpers should trust them. An internal helper that re-checks and silently corrects invalid state is masking a caller bug.

### Defensive code for cases that can't happen

AI loves to handle the impossible. For each defensive branch ask: **does the code actually fail in a situation that exists?** If the guarded state is unreachable given the real callers, the branch is dead weight — it bloats the function and implies a contract that isn't real. Mark these as removable. (When unsure whether a case is reachable, say so and mark the finding low-confidence rather than asserting.)

### Reinvented and duplicated logic

- Duplicated blocks longer than ~5 meaningful lines — pull into one helper.
- New helpers that duplicate an existing utility. Search first, then flag with a pointer to the one that already exists.
- A Python script shelling out via `subprocess` to another Python script when an importable API is right there.

### Over-engineering that doesn't pay

Wrappers, registries, factories, base classes, and indirection layers introduced for a single concrete use. If there's one implementation behind the abstraction, the abstraction is slop. Flag layers that cost more to read than the thing they wrap.

### Comments that earn nothing

- Comments restating what the code obviously does (`# increment i` over `i += 1`).
- Narration left over from generation (`# First, we...`, `# Now let's...`).
- Commented-out code.
  Good comments explain *why* or warn of a non-obvious gotcha; chatty comments add maintenance burden for every future human and AI reader. Flag them for deletion, keep the rare load-bearing one.

### Naming and constants

- Vague or misleading names; inconsistent naming pairs (`fetch`/`getData` for the same idea).
- Booleans that aren't `is_`/`has_`/`should_`/`can_`.
- Magic numbers and strings that should be named constants.

### Structure

- Files too large to navigate; functions that fuse unrelated responsibilities — flag the seam where they should split.
- Nested ternaries and dense one-liners that trade readability for line count — prefer explicit `if`/`elif`/`else`.
- Import smells: cycles, wildcard imports, heavy imports on a hot startup path.

### Two questions to keep yourself honest

1. **Is this real?** Before flagging, confirm the full file and the callers actually support the claim. Many "issues" dissolve once you see the whole picture.
2. **Would fixing it change behavior?** A cleanup must preserve what the code *does*. If a "cleanup" alters outputs or behavior, it's a refactor proposal, not slop removal — call it out as such.

## Workflow

1. **Scope.** Confirm the directory. Get a feel for size, language, and layout. If it's large, note which subtrees you focused on so coverage is honest — don't silently sample and imply you read everything.
2. **Learn the local style.** Skim a few representative files and any `CLAUDE.md`, `README`, or lint config. This sets the baseline you measure "slop" against.
3. **Read for the patterns above.** Go file by file for the hot spots. Keep a running list; note where the same smell repeats so you can suggest one systemic fix instead of N scattered ones.
4. **Verify each finding.** Open the full file and the callers. Drop anything that doesn't survive. Search for existing utilities before claiming duplication.
5. **Prioritize and write the report.**

## Prioritizing

Order suggestions so the user fixes the highest-leverage slop first:

- **P0 — Risky:** silent fallbacks, swallowed errors, over-broad contracts that can hide real bugs. These can mask correctness problems, so they lead.
- **P1 — Maintainability:** reinvented/duplicated logic, over-engineered abstractions, oversized functions/files. High effort-to-change cost.
- **P2 — Readability:** chatty/dead comments, naming, magic constants, nested ternaries. Cheap, high-volume cleanups.

Tag each finding with a confidence: HIGH when you're certain and have seen the full context, LOW when it's a judgment call or you couldn't fully confirm reachability. Group repeated smells into a single systemic suggestion where it helps.

## Output Format

Save as `slop-report-<dirname>.md` in the workspace (or a user-specified path). Keep prose tight.

```markdown
# Slop Report: <directory>

> Scanned: <paths / subtrees actually read>
> Date: <date>
> Files reviewed: <n>

## Summary

One short paragraph: overall health of the directory and the 2-3 themes that dominate the slop here. Lead warm and honest — say plainly if it's in good shape.

## Cleanup Plan

Ordered, actionable. Each item:

### [P0-HIGH] Short title
**Where:** `path/to/file.py:120-138` (and N similar sites: ...)
What the slop is and the concrete cost it imposes (harder debugging, hidden bug, extra surface to maintain).
**Fix:** The smallest specific change. A short code suggestion only when it's precise and useful.

### [P1-LOW] ...

## Systemic Notes

Patterns that recur across many files and deserve one pass rather than scattered edits (e.g. "chatty generation comments throughout `handlers/` — strip in one sweep").

## What's Clean

Briefly, what's already good — so the user knows it was looked at and shouldn't be touched.
```

## Self-Check

Before finalizing:

- Suggestions are ordered P0 → P2 with a confidence tag each.
- Every finding has `file:line`, a real cost, and a concrete fix.
- Each finding was verified against the full file and callers; duplication/reinvention claims are backed by an actual search.
- No behavior-changing "refactors" are mislabeled as slop removal.
- Coverage is stated honestly; sampled subtrees are named, not implied as complete.
- The report measures against the code's own conventions, not personal taste.
- No code was modified (unless the user asked); nothing was committed, pushed, or sent remote.
- No personal paths or machine-specific directories appear unless the user supplied them.
