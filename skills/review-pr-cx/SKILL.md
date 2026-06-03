---
name: review-pr-cx
description: Claude->Codex->Claude cross-checked PR review. Claude reviews a GitHub PR (per the review-pr skill), Codex independently critiques that review for incorrect claims, missed issues, and framing, then Claude reconciles into a single final review. Use when the user wants a Codex cross-checked PR review, invokes $review-pr-cx, or asks to "review this PR with codex double-check". All artifacts are confined to .pr-review/pr-<n>/.
allowed-tools: "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/codex-review-review.sh:*)"
---

# Review PR (Codex cross-checked)

A three-stage PR review that pairs Claude with Codex:

1. **Claude reviews** the PR (using the `review-pr` skill's full methodology).
2. **Codex critiques Claude's review** on three axes: incorrect claims, missed issues, framing.
3. **Claude reconciles** every Codex point -- accept and revise, or reject with a one-line justification -- and writes the single final artifact.

This is the lightweight one-round scheme: one Claude review, one Codex critique, one Claude reconciliation. It is not an iterate-until-agree loop.

## Hard rules

- **Strict artifact location.** Every file this skill produces lives ONLY under `.pr-review/pr-<n>/` in the repository being reviewed, where `<n>` is the PR number. Do not write review artifacts anywhere else (no repo-root `review-*.md`, no scratch notes elsewhere). The final self-check verifies this.
- Inherit all of the `review-pr` skill's rules: generate diffs locally, read full changed files and callers, order findings P0-P4 with HIGH/LOW confidence, watch for over-defensive findings, keep output English-only, do not hard-code personal paths, **do not push or comment to GitHub**, and clean up any temp clone/branch you create.
- Do not use sub-agents. Codex is the only second opinion; it is invoked through the bundled script, not as a Claude sub-agent.
- If the target is ambiguous (no PR URL/number), stop and ask the user for the explicit PR link.

## Workflow

### Stage 0 - Set up the strict artifact directory

1. Parse the target exactly as `review-pr` Step 1 does (owner, repo, PR number `<n>`, title, author, base/head refs, head SHA, change stats).
2. Create the artifact directory at the repo root being reviewed:

   ```bash
   mkdir -p .pr-review/pr-<n>
   ```

3. Offer to add `.pr-review/` to that repo's `.gitignore` if it is a tracked repo and the entry is missing. Do not commit anything.

From here on, `<dir>` means `.pr-review/pr-<n>`.

### Stage 1 - Claude review

Run the **`review-pr`** skill's workflow in full (Prepare Local Evidence -> Gather Codebase Context -> Review Priorities -> Output Format -> Self-Check), with two changes:

- Save the locally generated diff to `<dir>/diff.patch`, for example:

  ```bash
  git diff origin/<base_ref>...HEAD > .pr-review/pr-<n>/diff.patch
  ```

- Write the review to `<dir>/claude-review.md` (instead of repo-root `review-<n>_draft.md`), using the exact `review-pr` Output Format, including the `## Suggested drafted review on Github` section.

Stay on the checked-out PR head after this stage so Codex can read the real post-PR source. Do not clean up the checkout yet.

### Stage 2 - Codex critiques the review

Invoke the bundled wrapper. Codex reads `diff.patch` + `claude-review.md` (and may open changed source files), and writes its critique to `<dir>/codex-critique.md`:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/codex-review-review.sh" \
  --pr <n> \
  --diff .pr-review/pr-<n>/diff.patch \
  --review .pr-review/pr-<n>/claude-review.md \
  --out .pr-review/pr-<n>/codex-critique.md
```

- Default model/effort is `gpt-5.5:high`, 3600s timeout. Pass `--codex-model MODEL:EFFORT` or `--codex-timeout SECONDS` only if the user asked.
- The script prints Codex's critique to stdout and saves it to `--out`. Read it carefully.
- On non-zero exit, report the error to the user (timeout -> suggest a larger `--codex-timeout`; missing `codex` -> point to install). Do not fabricate a critique.

Codex critiques along three axes (full rubric in `templates/codex-critique-rubric.md`):

- **A. Incorrect claim** - a finding Claude raised that is wrong or overstated (false positive / over-defensive).
- **B. Missed issue** - a real problem in the diff Claude failed to flag (false negative), with file:line.
- **C. Framing** - wording / severity / structure that should change, with special attention to the GitHub draft comment section.

### Stage 3 - Claude reconciles into the final artifact

Read `<dir>/codex-critique.md`. For **each** Codex item, decide and act:

- **ACCEPT** - Codex is right. Update the review: drop/downgrade the incorrect claim (A), add the missed finding at the right priority (B), or reword/restructure (C).
- **REJECT** - Codex is wrong or not worth it. Keep Claude's position and record a one-line justification grounded in the code (e.g. "the None branch is unreachable: the only caller passes a tensor"). Do not accept a Codex point just to be agreeable, and do not reject one just to defend the original -- decide on the evidence.

Then write `<dir>/final-review.md` with:

1. The **reconciled review** -- the same `review-pr` Output Format (header, Overall Assessment, Technical Summary, Findings P0-P4, Goal Completeness, AI-Generated Code Signals, Verification, Recommendation, and the updated `## Suggested drafted review on Github`), now reflecting every accepted change.
2. A trailing appendix:

   ```markdown
   ## Codex Cross-Check Log

   | # | Axis | Target | Codex's point | Decision | Rationale |
   |---|------|--------|---------------|----------|-----------|
   | 1 | A | "<finding>" (file:line) | <short> | Accepted / Rejected | <one line> |
   ```

   Include every Codex item, accepted or rejected, so the human can see what the cross-check changed and why.

`final-review.md` is the single deliverable to surface to the user. Point them to it and give a 2-3 line summary of the verdict and what the Codex cross-check changed.

### Stage 4 - Self-check and cleanup

Before finishing, verify:

- All four artifacts exist and live ONLY under `<dir>`: `diff.patch`, `claude-review.md`, `codex-critique.md`, `final-review.md`. Nothing was written outside `<dir>`.
- `final-review.md` findings are ordered P0-P4 with root causes first, each with file:line and a concrete fix.
- Every Codex item appears in the Cross-Check Log with an explicit Accepted/Rejected decision.
- The output is English-only and free of personal/machine-specific paths.
- Any temp clone or scratch branch created for the review is removed; the user's worktree is left as it was found; nothing was pushed or commented to GitHub.

## Artifact layout (reference)

```
.pr-review/pr-<n>/
  diff.patch          # locally generated three-dot diff (evidence)
  claude-review.md    # Stage 1: Claude's review
  codex-critique.md   # Stage 2: Codex's critique on the 3 axes
  final-review.md     # Stage 3: reconciled review + Codex Cross-Check Log  <- deliverable
```
