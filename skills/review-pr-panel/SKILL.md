---
name: review-pr-panel
description: Two-round, three-model panel PR review. The session model orchestrates: it prepares the evidence, dispatches two independent reviews in parallel (headless Claude via `claude -p`, Codex via `codex exec`), merges them into one verified review, sends a blinded copy back to both reviewers for cross-examination, then writes a final report marking every finding as consensus, majority, or disputed. Use when the user invokes $review-pr-panel, asks for a panel/multi-model PR review, or asks to "review this PR with Claude and Codex and see where they agree". All artifacts are confined to .review_loop/pr-<n>/.
allowed-tools: "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/panel-round.sh:*)"
---

# Review PR (model panel)

A two-round review panel. You are the orchestrator, not a reviewer.

```
Stage 1  you: setup.md + diff.patch (shared evidence, one checkout)
Stage 2  claude -p  ─┐ independent, parallel, blind to each other
         codex exec ─┘ -> r1/claude.md, r1/codex.md
Stage 3  you: verify both against the code -> r1/merged.md (+ blinded copy)
Stage 4  claude -p  ─┐ cross-examine the blinded merge
         codex exec ─┘ -> r2/claude.md, r2/codex.md
Stage 5  you: final-review.md with the agreement matrix
```

The value comes from three things: both reviewers see the *same* evidence and the *same*
rubric, so differences are model differences and not prompt differences; round 2 is blinded,
so agreement is not self-recognition; and nothing reaches the final review that you have not
checked against the code yourself.

Designed to be driven from a Fable session with Opus and Codex as the reviewers. It runs
from any session model - if you are already running Opus, tell the user the Claude leg is
redundant and offer `--claude-model sonnet` or another reviewer.

## Hard rules

- **You are the judge, not a third reviewer.** Do not write your own review before reading
  theirs - anchoring on your own findings is exactly what this scheme is meant to avoid. You
  read the diff during setup, and you verify claims during synthesis. That is your role.
- **No finding survives synthesis unverified.** Before a finding enters `merged.md`, open the
  cited `file:line` and confirm the behavior yourself. A merged review is otherwise just a
  confident average of two models' mistakes.
- **Evidence beats votes.** A finding both reviewers reject still stands if you can point at
  the code that proves it; mark it `DISPUTED-UPHELD`. A finding both accept still falls if you
  cannot find the code path. Vote counts order the report; they do not decide truth.
- **Never fabricate reviewer output.** If a leg fails, report the failure and continue with a
  degraded panel, clearly labeled.
- **Strict artifact location.** Everything lives under `.review_loop/pr-<n>/` in the repo being
  reviewed. No repo-root `review-*.md`, no `.pr-review/`, no scratch notes elsewhere.
- Inherit all of `review-pr`'s rules: generate diffs locally, read full files and callers,
  P0-P4 with HIGH/LOW confidence, watch for over-defensive findings, English only, no
  hard-coded personal paths, **do not push or comment to GitHub**, clean up temp clones.
- Reviewers are invoked only through `panel-round.sh`. Do not use Claude sub-agents for the
  review legs - the point is process isolation from your context.
- If the target is ambiguous (no PR URL/number), stop and ask for the explicit PR link.

## Workflow

### Stage 0 - Set up the panel directory

1. Parse the target exactly as `review-pr` Step 1 does (owner, repo, PR number `<n>`, title,
   author, base/head refs, head SHA, change stats).
2. `mkdir -p .review_loop/pr-<n>` at the root of the repo being reviewed.
3. If the repo is tracked and `.review_loop/` is not ignored, ask before adding it to
   `.gitignore`. Do not commit anything.

From here, `<dir>` means `.review_loop/pr-<n>`.

### Stage 1 - Shared evidence

Run `review-pr`'s **Prepare Local Evidence** and **Gather Codebase Context** steps. Both
reviewers will work from what you produce here, so an error at this stage poisons the whole
panel.

Write `<dir>/setup.md` with:

- target metadata: owner/repo, PR number, title, author, base ref, head ref, expected head SHA
- workspace choice - current checkout, worktree, or isolated clone - and why it was safe
- exact fetch/checkout commands, including remotes for fork PRs
- verification output for `git rev-parse HEAD`, expected head SHA match, base ref availability,
  merge base, and dirty-worktree handling
- the exact local diff command used
- changed-file and commit summaries

Save the diff to `<dir>/diff.patch`:

```bash
git diff origin/<base_ref>...HEAD > .review_loop/pr-<n>/diff.patch
```

Read the changed files yourself now. You cannot adjudicate in Stage 3 on a diff you have not
read. Do not write a review.

Do not proceed until local `HEAD` matches the PR head SHA and both `setup.md` and `diff.patch`
exist. **Stay on the checked-out PR head for the rest of the workflow** - both rounds read the
live source. Do not clean up the checkout until Stage 6.

### Stage 2 - Round 1: two independent reviews

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/panel-round.sh" \
  --round 1 --pr <n> --dir .review_loop/pr-<n>
```

Both engines run in parallel on a byte-identical prompt and write `<dir>/r1/claude.md` and
`<dir>/r1/codex.md`. Defaults are `opus[1m]:xhigh` and `gpt-5.6-sol:xhigh`, 3600s each. Pass
`--claude-model`, `--codex-model`, or `--timeout` only if the user asked.

Exit codes: `0` both succeeded, `2` one leg failed (panel is degraded - continue, and record it
in the final report), `1` validation error or both failed (stop and report to the user; a
timeout suggests re-running that leg with `--engines <name> --timeout <2x>`).

Read both reviews in full.

If either review opens with `## Setup Concerns` and the concern is real, fix the setup,
regenerate `setup.md` and `diff.patch`, and re-run Stage 2. Do not merge reviews built on bad
evidence.

### Stage 3 - Synthesis

For every finding in either review, open the cited `file:line` and decide: does this hold?
Then write `<dir>/r1/merged.md`.

Findings get stable ids `F1..Fn`, ordered P0-P4 with root causes before derived issues. Use the
`review-pr` finding format plus a provenance line:

```markdown
### F3 [P1-HIGH] Host-device sync inside the decode loop

**File:** `python/sglang/srt/foo.py:214`

<behavior, why it is wrong, which caller reaches it, downstream effect>

**Fix:** <smallest concrete fix>

**Panel:** claude=P1-HIGH | codex=P2-LOW | verified at foo.py:214 (orchestrator)
```

When the reviewers disagree on severity, record both and state which one the code supports.
When only one reviewer raised it, say so - one-source findings are not weaker by default, they
just have not been cross-checked yet, which is what round 2 is for.

Then a dropped list, ids `D1..Dm`, for everything you cut:

```markdown
## Dropped

### D1 - "Missing None check on the cache handle" (`foo.py:88`)

Reason: the only two callers construct the handle unconditionally; the None branch is
unreachable. Over-defensive.
```

Every finding either enters `F` or `D`. Silently dropping a reviewer's finding defeats the
cross-check - round 2 audits your cuts.

Finally, write `<dir>/r1/merged-blind.md`: the same document with every `**Panel:**` line and
every other attribution removed, ids intact. **Verify it leaks no provenance** - no model
names, no "claude", no "codex", no "one reviewer said". This copy is what round 2 sees; if it
leaks, agreement in round 2 means nothing.

### Stage 4 - Round 2: blinded cross-examination

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/panel-round.sh" \
  --round 2 --pr <n> --dir .review_loop/pr-<n>
```

Both reviewers receive `merged-blind.md` plus the diff and the checked-out source, and return
a verdict for every `F` and `D` id, plus anything the panel missed. Same exit-code handling as
Stage 2. If a reviewer omits an id, treat it as a failed cross-check for that id, not as
agreement.

### Stage 5 - Final report

Resolve each id:

| Both reviewers | Your call | Status |
|---|---|---|
| agree / amend | apply amendments | `CONSENSUS` |
| one agrees, one disagrees | adjudicate on the code | `MAJORITY` (record the dissent) |
| both disagree, you can prove it | keep, with the proof | `DISPUTED-UPHELD` |
| both disagree, you cannot | drop | `WITHDRAWN` |
| `restore` on a `D` id, you verified it | add as a finding | `RESTORED` |
| new in round 2, you verified it | add as a finding | `LATE-ADD` (one round of scrutiny only) |

Severity conflicts resolve the same way: the code decides, and the disagreement itself is
signal worth showing the human.

Write `<dir>/final-review.md`:

1. A header block naming the panel - orchestrator model, both reviewer models, round count,
   and any degraded leg.
2. **`## Panel Verdict`** - counts by status and the one-line bottom line.
3. **`## Agreement Matrix`**:

   ```markdown
   | ID | Finding | Severity | Claude R2 | Codex R2 | Status |
   |----|---------|----------|-----------|----------|--------|
   | F1 | <short> | P0-HIGH  | agree     | amend    | CONSENSUS |
   | D2 | <short> | -        | restore   | keep     | RESTORED  |
   ```

4. The reconciled review in `review-pr` Output Format - Overall Assessment, Technical Summary,
   Findings (P0-P4, each carrying its status and any dissent in one line), Goal Completeness,
   AI-Generated Code Signals, Verification, Recommendation.
5. **`## Needs Your Judgment`** - every `DISPUTED-UPHELD` item with each model's position, so
   the human can break the tie.
6. **`## Suggested drafted review on Github`** - per `review-pr`'s tone guidance. Include
   `CONSENSUS`, adjudicated `MAJORITY`, and verified `RESTORED`/`LATE-ADD` items only. Keep
   `DISPUTED-UPHELD` and `WITHDRAWN` out of the paste-ready comment.
7. **`## Panel Log`** - `WITHDRAWN` items with the reason they died, and any leg that failed.

`final-review.md` is the single deliverable. Point the user to it and give a 2-3 line summary:
the verdict, how much the panel agreed, and what changed between round 1 and the final.

### Stage 6 - Self-check and cleanup

- All artifacts exist and live ONLY under `<dir>`: `setup.md`, `diff.patch`, `r1/claude.md`,
  `r1/codex.md`, `r1/merged.md`, `r1/merged-blind.md`, `r2/claude.md`, `r2/codex.md`,
  `final-review.md`, `logs/`.
- `merged-blind.md` contains no attribution.
- Every `F` and `D` id appears in the Agreement Matrix with a status.
- Every finding in `final-review.md` has `file:line`, a concrete fix, and a status.
- Findings are ordered P0-P4 with root causes first.
- Output is English-only and free of personal or machine-specific paths.
- Any temp clone or scratch branch is removed; the user's worktree is as it was found; nothing
  was pushed or commented to GitHub.

## Artifact layout (reference)

```
.review_loop/pr-<n>/
  setup.md               # Stage 1: setup, checkout, and diff evidence
  diff.patch             # Stage 1: locally generated three-dot diff
  r1/
    claude.md            # Stage 2: independent review (headless Claude)
    codex.md             # Stage 2: independent review (Codex)
    merged.md            # Stage 3: verified synthesis, ids F1..Fn / D1..Dm
    merged-blind.md      # Stage 3: provenance-stripped copy sent to round 2
  r2/
    claude.md            # Stage 4: cross-examination verdicts
    codex.md             # Stage 4: cross-examination verdicts
  final-review.md        # Stage 5: agreement matrix + reconciled review  <- deliverable
  logs/
    r<N>-prompt.md       # exact prompt both engines received
    r<N>-<engine>.log    # engine session log
```
