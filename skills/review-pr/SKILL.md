---
name: review-pr
description: Review GitHub pull requests and local code diffs with a rigorous engineering review workflow. Use when the user explicitly invokes $review-pr, asks Codex to review a GitHub PR URL, requests a refresh of a previous PR review, or asks for a structured code review of a branch/diff. The skill emphasizes local diff generation, full-file and caller context, prioritized P0-P4 findings, reuse and abstraction checks, and English-only review output.
---

# Review PR

Use this skill to produce a standalone engineering review of a GitHub pull request, branch, or local diff. The review should be evidence-based, ordered by severity, and written entirely in English.

Default stance: review as a senior engineer for performance-sensitive systems code. Adapt to the repository's actual domain, but keep the same standards for correctness, performance, maintainability, style, and process. 

## Core Rules

- Generate PR diffs locally after fetching the current PR head. Do not rely on GitHub patch or diff endpoints for code review evidence.
- Read full changed files and relevant surrounding code, not only diff hunks.
- Inspect sibling implementations, shared utilities, tests, and callers before recommending new abstractions.
- Treat additional user instructions after the PR URL or diff request as highest-priority review focus.
- Do not use sub-agents unless the user explicitly asks for parallel review across multiple PRs or diffs.
- Preserve local user work. If checkout would disturb a dirty or unrelated worktree, use a separate clone or worktree.
- Keep all review prose in English.
- Do not hard-code personal paths, account names, or machine-specific directories. Use the current workspace or an explicit user-provided path if exists when saving artifacts.
- Don't push anything to remote. Don't touch anything related to Github (such as push or comment)

## Workflow

### 1. Parse The Target

Identify the review target from the user request:

- GitHub PR URL: `https://github.com/{owner}/{repo}/pull/{number}`

collect:

- repository owner and name
- PR number, title, author, body, base ref, head ref, head repository, head SHA
- changed file count, additions, deletions
- existing review comments or prior local review artifact when refreshing

If the target is ambiguous without including a github pr link, stop and ask user for the explicit link.

### 2. Prepare Local Evidence

For GitHub PRs:

1. Locate a safe local checkout for `{owner}/{repo}`. Prefer the current repository only if its remote matches the target and switching branches will not disturb user work.
2. If needed, create an isolated clone under a temporary review directory.
3. Fetch the base ref from the base repository.
4. Fetch the PR head from the correct remote:
   - Same-repository PR: fetch `head.ref` from `origin` or the base remote.
   - Fork PR: add or update a remote for the fork, then fetch `head.ref` from that remote.
5. Check out a scratch branch such as `review/pr-{number}` or a detached head at the fetched PR SHA.
6. Verify local `HEAD` equals the PR metadata `head.sha` before reviewing.
7. Generate the diff locally with a three-dot comparison against the fetched base, for example:

```bash
git diff origin/{base_ref}...HEAD
git log --oneline origin/{base_ref}..HEAD
```

For local diffs:

- Use the user-specified range when provided.
- Otherwise inspect staged and unstaged changes with `git diff --cached` and `git diff`.
- Record the exact commands used so the review is reproducible.

### 3. Gather Codebase Context

Before writing findings, inspect enough context to understand the change:

- Read each changed file in full when practical.
- Read direct callers, tests, fixtures, configuration, and public API surfaces touched by the change.
- Search for sibling or parallel files with similar responsibilities.
- Search for existing helpers, utilities, constants, or abstractions that the PR duplicates.
- Check whether Python code invokes Python scripts via subprocess where an importable API already exists.
- Check whether tests cover the changed contract, not just implementation details.
- For performance-sensitive paths, identify hot loops, GPU or accelerator synchronization points, network or disk I/O, lock scope, and allocation behavior.

Carry this context into the findings. Do not recommend broad refactors without first proving the existing patterns and call sites justify them.

## Review Priorities

Order findings by priority: P0, P1, P2, P3, then P4. Within the same priority, put root-cause issues before derived issues. Mark a root-cause item when later findings depend on it.

For each review process, try to after px, mark, by your confidence that it is a HIGH/LOW issue. For example, if you are 100% sure that it's a P1 issue then mark it as P1-HIGH. If you are not sure, or it's a issue that might not be blocking but still worth to point out, mark it as Px-LOW.

NOTE: a lot of times agent claim P1 problem which are actually over-defensive. When you are flagging any P1 issue, potentially any P1 AND P2 issue, think: for the issue that we are claiming: does the code fail at some situation that does not actually exist?  If you feel like the finding is a defensive claim, either mark it as LOW or take it as a non-issue.

Every actionable finding should also include:

- file and line reference
- affected runtime path or caller behavior
- concrete failure mode or maintenance cost
- explanation of why the severity is appropriate
- actionable fix

Avoid:

- style-only nitpicks that do not matter
- vague requests such as "make this cleaner"
- findings based only on diff hunk context when the full file changes the interpretation
- speculative performance claims without identifying the hot path or scale
- recommending new abstractions before checking existing patterns

### ONE WORD BEFORE START
- IMPORTANT: It's Okay to not have a issue, or only flag out a few issue -- that does not make you turn in a bad job. On the other hand, since quality of the PR can vary a ton, so trust your intellegence and the guideline of this skill, instead of a KPI of number of issue you have to raise. The only metric of doing a good job is only the quality of the issue, not number.

### P0: Correctness

Flag issues that can produce wrong behavior, data corruption, hangs, crashes, security problems, or unbounded resource growth.

Review for:

IMPORTANT: 
- broad `try/except` blocks that swallow programmer errors or hide broken invariants  Try to look at every new try/except introduced. Are they silent fallbacks that is sawllowing errors in an unessecary way? Silent fallback is making future debug much harder. Let code fail naturally.
- Also, uneedingly broad data contract is a common place to cause silent fallback to happen. For example, if the data contract is only pytorch tensor, then accepting NONE could cause a lot of issue in readability and correctness.

Also:
- race conditions, deadlocks, unsafe shared state, and undocumented thread-safety contracts
- resource leaks for files, sockets, processes, CUDA streams, temporary directories, and network sessions
- unbounded caches, append-only buffers in long-running paths, and missing eviction policies
- off-by-one errors, dtype and shape mismatches, invalid device placement, and broken batching assumptions
- validation in the wrong layer: public boundaries should validate; internal helpers should not defensively mask invalid state
- incomplete state-space handling, especially chained independent branches where explicit `if` / `elif` / `else` case analysis is needed

### P1: Performance

Flag issues that can materially hurt latency, throughput, memory, or scalability.

Some notable signs are: 

- `.item()`, `.cpu()`, `.numpy()`, or `.tolist()` in inference or training hot paths
- avoidable host-device synchronization
- Python loops over tensor-sized data where vectorized or fused operations are expected
- I/O or GPU work while holding locks
- unnecessary subprocess startup, model reloads, repeated compilation, or repeated expensive initialization
- avoidable allocation churn in tight loops


### P2: Maintainability&Style

Flag issues that make the code harder to change safely. Note that when you are reviewing for P2 issue, always keep in mind that the repo you are reviewing is always a human-AI collaborating workspace. As a result, lots of boilerplate code, and over-chatty comment, and more, is increasing burden for both future human and AI to maintain.

Review for:

- duplicated logic longer than about five meaningful lines
- new helpers that duplicate existing utilities
- over-engineered layers, wrappers, registries, or modules that do not pay for their complexity
- files that are too large to navigate and functions that combine unrelated responsibilities
- poor public names, vague names, inconsistent naming pairs, or booleans without `is_`, `has_`, `should_`, or `can_`
- magic constants that should be named
- import cycles, wildcard imports, or heavy imports on common startup paths
- Over-chatty comments

Follow this mental model and routine when you are thinking about P2 issue:

   1. **Preserve Functionality**: Never change what the code does - only how it does it. All original features, outputs, and behaviors must remain intact.

   2. **Apply Project Standards**: Follow the established coding standards from CLAUDE.md including:

      - Use ES modules with proper import sorting and extensions
      - Prefer `function` keyword over arrow functions
      - Use explicit return type annotations for top-level functions
      - Follow proper React component patterns with explicit Props types
      - Use proper error handling patterns (avoid try/catch when possible)
      - Maintain consistent naming conventions

   3. **Enhance Clarity**: Simplify code structure by:

      - Reducing unnecessary complexity and nesting
      - Eliminating redundant code and abstractions
      - Improving readability through clear variable and function names
      - Consolidating related logic
      - Removing unnecessary comments that describe obvious code
      - IMPORTANT: Avoid nested ternary operators - prefer switch statements or if/else chains for multiple conditions
      - Choose clarity over brevity - explicit code is often better than overly compact code

   4. **Maintain Balance**: Avoid over-simplification that could:

      - Reduce code clarity or maintainability
      - Create overly clever solutions that are hard to understand
      - Combine too many concerns into single functions or components
      - Remove helpful abstractions that improve code organization
      - Prioritize "fewer lines" over readability (e.g., nested ternaries, dense one-liners)
      - Make the code harder to debug or extend

   5. **Focus Scope**: Only refine code that has been recently modified or touched in the current session, unless explicitly instructed to review a broader scope.

   Propose the issue which could be changed by:

   1. Identify the recently modified code section 
   2. Analyze for opportunities to improve elegance and consistency
   3. Apply project-specific best practices and coding standards
   4. Ensure all functionality remains unchanged
   5. Verify the refined code is simpler and more maintainable
   6. Document only significant changes that affect understanding



### P3: Process/Tests

Flag process gaps that reduce review confidence.

Review for:

- missing unit, integration, regression, or benchmark tests for changed behavior
- tests without deterministic seeds where randomness affects results
- tests that assert internal state instead of externally visible contracts

Also, if the pr includes a change in core runtime logic of a model/framework, especially an optimizatoin, and the pr body/comment does not provide a benchmark, expose it as a P4 issue.


## Output Format

Use this structure for a saved artifact, save it in your working git repo as review-<pr_number>_draft.md

```markdown
# PR #{number}: {title}

> Repository: {owner}/{repo}
> Author: {author}
> Branch: {head_ref} -> {base_ref}
> Head: {head_sha}
> Reviewed: {date}
> Changed files: {changed_files} | +{additions} / -{deletions}

## Overall Assessment

State whether the PR is ready to merge, needs changes, or should be rejected. Summarize the main risk in one or two paragraphs.

## Technical Summary

Explain what the PR changes, which architecture or runtime path it touches, and the relevant technical invariants.

## Findings

### [P0-BLOCKER] Short finding title

**File:** `path/to/file.py:123`

Explain the concrete code behavior, why it is wrong, what user or runtime path reaches it, and the downstream effect.

**Fix:** Describe the smallest concrete fix. Include a code suggestion only when it is precise and useful.

## Goal Completeness

Assess whether the implementation fully achieves the stated PR goal and identify missed edge cases.

## AI-Generated Code Signals

Note any signs of unreviewed generated code, such as generic boilerplate, impossible defensive cases, broad exception swallowing, excessive abstraction, or style mismatch. If none are visible, say so.

## Verification

List commands run, tests inspected, tests missing, and any commands that could not be run.

## Recommendation

Final rating: Approve / Request Changes / Reject

1. Highest-priority action.
2. Next action.

## Suggested drafted review on Github
In this section, try to reframe your word to a way that human, as repo mainainter can paste the review to the pr with minimal human effort in reviewing and changing wording. Note that this part's wording should be friendly, warm, and soft. For example, for some issue where code needs to be changed, you can say 'maybe we should change...' or 'shall we change ... for better?' and wording like this.

Basically this section's format should be:

a summarizing paragraph, don't restate what's done in this pr, just a general verdict. Most of the time it should be 'Generally it's a good direction/good pr/good thoughts', but 'I have some suggestions maybe you can consider applying'. But to make it more natural don't copy and paste the example I provided, just understand what I'm saying and start warm.

### Code_snippet_1 
<File Name> <Line from-to> (here you should state the code snippet to highlight for the github comment)
Here you start to state the actual issue, still as instructed above, structure your phrasing here a bit warmer-- but not too warm and strange, just warmer than a formal academic paper. Example: Do you think we should xxx? Since xxx. It will make xxx. I would suggest you to fix by xxx. Thanks!

### Code_snippet_2
And until the issue you spotted finishes.
Note that in these writeups don't mention anything about P0 or high/low, just use natural and concise language.

```

## Self-Check

Before finalizing:

- Findings are ordered P0 through P4.
- Root causes precede derived issues.
- Each finding has file:line evidence and a concrete fix.
- Full changed files and relevant callers/tests were inspected.
- Reuse and abstraction claims are backed by sibling or utility searches.
- The output is English-only.
- No personal directories, account names, or machine-specific paths appear in the review or skill behavior unless the user explicitly supplied them for this task.
- Delete the additioanl directory/folder/file you created for review, aside from the review doc you created.