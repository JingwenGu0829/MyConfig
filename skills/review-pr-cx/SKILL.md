---
name: review-pr-cx
description: Claude->Codex->Claude cross-checked PR review. Claude reviews a GitHub PR per the review-pr skill, records setup/diff evidence, Codex audits setup and independently reviews before comparing on incorrect claims, missed issues, and framing, then Claude reconciles into a final review. Use when the user wants a Codex cross-checked PR review, invokes $review-pr-cx, or asks to "review this PR with codex double-check". All artifacts are confined to .review_loop/pr-<n>/.
allowed-tools: "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/codex-review-review.sh:*)"
---

# Review PR (Codex cross-checked)

A one-round PR review workflow that pairs Claude with Codex:

1. **Claude prepares evidence and reviews** the PR using the `review-pr` skill's full methodology.
2. **Codex audits setup, independently reviews, then compares** against Claude's review on three axes: incorrect claims, missed issues, framing.
3. **Claude reconciles** every Codex point -- accept and revise, or reject with a one-line justification -- and writes the single final artifact.

This is not an iterate-until-agree loop. The quality comes from independent work first, then comparison.

## Hard rules

- **Strict artifact location.** Every file this skill produces lives ONLY under `.review_loop/pr-<n>/` in the repository being reviewed, where `<n>` is the PR number. Do not write review artifacts anywhere else (no repo-root `review-*.md`, no `.pr-review/`, no scratch notes elsewhere). The final self-check verifies this.
- Inherit all of the `review-pr` skill's rules: generate diffs locally, read full changed files and callers, order findings P0-P4 with HIGH/LOW confidence, watch for over-defensive findings, keep output English-only, do not hard-code personal paths, **do not push or comment to GitHub**, and clean up any temp clone/branch you create.
- Codex is the only second opinion. Invoke it through the bundled script, not as a Claude sub-agent.
- If the target is ambiguous (no PR URL/number), stop and ask the user for the explicit PR link.

## Workflow

### Stage 0 - Set up the review loop directory

1. Parse the target exactly as `review-pr` Step 1 does (owner, repo, PR number `<n>`, title, author, base/head refs, head SHA, change stats).
2. Create the artifact directory at the repo root being reviewed:

   ```bash
   mkdir -p .review_loop/pr-<n>
   ```

3. If the repo is tracked and `.review_loop/` is not ignored, ask before adding it to `.gitignore`. Do not commit anything.

From here on, `<dir>` means `.review_loop/pr-<n>`.

### Stage 1 - Claude setup and initial review

Run the **`review-pr`** skill's workflow in full (Prepare Local Evidence -> Gather Codebase Context -> Review Priorities -> Output Format -> Self-Check), with these changes:

- Record setup evidence in `<dir>/setup.md` before writing findings. Include:
  - target metadata: owner/repo, PR number, title, author, base ref, head ref, expected head SHA
  - workspace choice: current checkout, worktree, or isolated clone, plus why it was safe
  - exact fetch/checkout commands used, including remotes for fork PRs
  - verification commands and outputs for `git rev-parse HEAD`, expected head SHA match, base ref availability, merge base, and dirty-worktree handling
  - exact local diff command used to create `diff.patch`
  - changed-file and commit summaries used for review
- Save the locally generated diff to `<dir>/diff.patch`, for example:

  ```bash
  git diff origin/<base_ref>...HEAD > .review_loop/pr-<n>/diff.patch
  ```

- Write the initial Claude review to `<dir>/claude-review.md` instead of repo-root `review-<n>_draft.md`, using the exact `review-pr` Output Format, including the `## Suggested drafted review on Github` section.

Do not proceed to Codex until local `HEAD` matches the PR metadata head SHA and `<dir>/setup.md`, `<dir>/diff.patch`, and `<dir>/claude-review.md` all exist. Stay on the checked-out PR head after this stage so Codex can read the real post-PR source. Do not clean up the checkout yet.

### Stage 2 - Codex audits and critiques

Invoke the bundled wrapper. Codex reads `setup.md`, `diff.patch`, `claude-review.md`, and the `review-pr` skill rubric. It must audit setup first, independently review the diff second, then compare with Claude and write its critique to `<dir>/codex-critique.md`:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/codex-review-review.sh" \
  --pr <n> \
  --setup .review_loop/pr-<n>/setup.md \
  --diff .review_loop/pr-<n>/diff.patch \
  --review .review_loop/pr-<n>/claude-review.md \
  --out .review_loop/pr-<n>/codex-critique.md
```

- Default model/effort is `gpt-5.6-sol:high`, 3600s timeout. Pass `--codex-model MODEL:EFFORT` or `--codex-timeout SECONDS` only if the user asked.
- The script prints Codex's critique to stdout and saves it to `--out`. Read it carefully.
- On non-zero exit, report the error to the user (timeout -> suggest a larger `--codex-timeout`; missing `codex` -> point to install). Do not fabricate a critique.

Codex reports:

- **Setup audit** - whether Claude cloned/fetched/checked out/generated the local diff correctly, and whether the evidence is sufficient.
- **A. Incorrect claim** - a finding Claude raised that is wrong or overstated (false positive / over-defensive).
- **B. Missed issue** - a real problem in the diff Claude failed to flag (false negative), with file:line.
- **C. Framing** - wording / severity / structure that should change, with special attention to the GitHub draft comment section.

### Stage 3 - Claude reconciles into the final artifact

Read `<dir>/codex-critique.md`.

If Codex marks setup as `fail` and the failure is real, stop using the current initial review: fix the local setup, regenerate `<dir>/setup.md`, `<dir>/diff.patch`, and `<dir>/claude-review.md`, then rerun Codex. Do not reconcile a review based on bad evidence.

For **each** Codex item under A/B/C, decide and act:

- **ACCEPT** - Codex is right. Update the review: drop/downgrade the incorrect claim (A), add the missed finding at the right priority (B), or reword/restructure (C).
- **REJECT** - Codex is wrong or not worth it. Keep Claude's position and record a one-line justification grounded in the code (e.g. "the None branch is unreachable: the only caller passes a tensor"). Do not accept a Codex point just to be agreeable, and do not reject one just to defend the original -- decide on the evidence.

Then write `<dir>/final-review.md` with:

1. The **reconciled review** -- the same `review-pr` Output Format (header, Overall Assessment, Technical Summary, Findings P0-P4, Goal Completeness, AI-Generated Code Signals, Verification, Recommendation, and the updated `## Suggested drafted review on Github`), now reflecting every accepted change.
2. A trailing appendix:

   ```markdown
   ## Codex Cross-Check Log

   | # | Axis | Target | Codex's point | Decision | Rationale |
   |---|------|--------|---------------|----------|-----------|
   | 1 | Setup | setup.md | <short> | Accepted / Rejected | <one line> |
   | 2 | A | "<finding>" (file:line) | <short> | Accepted / Rejected | <one line> |
   ```

   Include every substantive Codex setup warning/failure and every A/B/C item, accepted or rejected, so the human can see what the cross-check changed and why.

`final-review.md` is the single deliverable to surface to the user. Point them to it and give a 2-3 line summary of the verdict and what the Codex cross-check changed.

### Stage 4 - Self-check and cleanup

Before finishing, verify:

- All five core artifacts exist and live ONLY under `<dir>`: `setup.md`, `diff.patch`, `claude-review.md`, `codex-critique.md`, `final-review.md`. Nothing was written outside `<dir>`.
- No repo-root `review-*.md`, `.pr-review/`, or scratch review notes were created.
- `final-review.md` findings are ordered P0-P4 with root causes first, each with file:line and a concrete fix.
- Every substantive Codex setup warning/failure and every A/B/C item appears in the Cross-Check Log with an explicit Accepted/Rejected decision.
- The output is English-only and free of personal/machine-specific paths.
- Any temp clone or scratch branch created for the review is removed; the user's worktree is left as it was found; nothing was pushed or commented to GitHub.

## Artifact layout (reference)

```
.review_loop/pr-<n>/
  setup.md            # Stage 1: setup, checkout, and diff evidence
  diff.patch          # Stage 1: locally generated three-dot diff
  claude-review.md    # Stage 1: Claude's initial review
  codex-critique.md   # Stage 2: Codex setup audit + A/B/C critique
  final-review.md     # Stage 3: reconciled review + Codex Cross-Check Log
```
