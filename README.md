
## Setup guide (Claude Code plugin)

This repo is a Claude Code **plugin** exposed through a single-plugin **marketplace**. The
plugin manifest is `.claude-plugin/plugin.json`; the marketplace manifest is
`.claude-plugin/marketplace.json`. Claude Code auto-discovers skills under `skills/`,
scripts under `scripts/`, and templates under `templates/`.

### Prerequisites

- **Claude Code** installed and authenticated.
- **Codex CLI** installed and authenticated (needed for `review-pr-cx` and `review-pr-panel`):
  - Install: https://github.com/openai/codex
  - Verify: `codex --version`
  - `review-pr-cx` defaults to `gpt-5.6-sol:high`, `review-pr-panel` to `gpt-5.6-sol:xhigh`;
    make sure your Codex auth can use that model.
- For `review-pr-panel` only: the `claude` binary must be on `PATH`, because the panel dispatches
  its second reviewer as a headless `claude -p` subprocess.

### Install on a new machine / Docker

**Option A - the `/plugin` command (recommended):**

```
/plugin marketplace add JingwenGu0829/MyConfig
/plugin install myconfig@JingwenGu0829
```

**Option B - edit `~/.claude/settings.json` directly** (good for Dockerfiles / provisioning):

```jsonc
{
  "extraKnownMarketplaces": {
    "JingwenGu0829": {
      "source": { "source": "git", "url": "https://github.com/JingwenGu0829/MyConfig.git" }
    }
  },
  "enabledPlugins": {
    "myconfig@JingwenGu0829": true
  }
}
```

Restart Claude Code (or start a new session) after editing settings.

### Verify the install

```
/plugin            # 'myconfig' should be listed and enabled
```

Then check the skills are discoverable -- ask Claude to run `/myconfig:review-pr`,
`/myconfig:review-pr-cx`, or `/myconfig:review-pr-panel`. (Plugin skills are namespaced as
`myconfig:<skill>`.)

The CLI works too, and is scriptable:

```
claude plugin marketplace add JingwenGu0829/MyConfig   # or a local path, e.g. ~/MyConfig
claude plugin install myconfig@JingwenGu0829
claude plugin list
```

A local-path marketplace installs **in place** (`installLocation` is the directory itself), so
edits to the skills take effect in the next session with no re-sync.

### Local / offline install (no GitHub)

Clone anywhere and point the marketplace at the local path:

```
git clone https://github.com/JingwenGu0829/MyConfig.git ~/MyConfig
/plugin marketplace add ~/MyConfig
/plugin install myconfig@JingwenGu0829
```

---

## Usage

### `review-pr` (standalone review)

```
/myconfig:review-pr https://github.com/<owner>/<repo>/pull/<n>
```

Produces an evidence-based review with P0-P4 findings and a ready-to-paste GitHub draft comment.

### `review-pr-cx` (Codex cross-checked review)

```
/myconfig:review-pr-cx https://github.com/<owner>/<repo>/pull/<n>
```

One round, one second opinion. Writes everything under a strict per-PR folder in the repo being
reviewed:

```
.review_loop/pr-<n>/
  setup.md            # Stage 1: setup, checkout, and diff evidence
  diff.patch          # locally generated diff (evidence)
  claude-review.md    # Stage 1: Claude's review
  codex-critique.md   # Stage 2: Codex critiques the review (3 axes)
  final-review.md     # Stage 3: reconciled review + Codex Cross-Check Log  <- the deliverable
```

`final-review.md` is the file to read: it is Claude's review after every Codex point has been
either accepted (and applied) or rejected (with a one-line justification), plus a log table of
those decisions.

Optional flags are passed straight through to Codex:

- `--codex-model MODEL:EFFORT` (default `gpt-5.6-sol:high`)
- `--codex-timeout SECONDS` (default `3600`)

### `review-pr-panel` (two-round, three-model panel)

```
/myconfig:review-pr-panel https://github.com/<owner>/<repo>/pull/<n>
```

Best started from a **Fable** session: Fable orchestrates, Opus and Codex review. Round 1 is two
independent reviews of the same evidence; round 2 sends a **blinded** merge back to both for
cross-examination; the report marks every finding consensus, majority, or disputed.

```
.review_loop/pr-<n>/
  setup.md, diff.patch   # Stage 1: shared evidence, one checkout
  r1/claude.md           # Stage 2: independent review (headless `claude -p`)
  r1/codex.md            # Stage 2: independent review (`codex exec`)
  r1/merged.md           # Stage 3: verified synthesis, ids F1..Fn / D1..Dm
  r1/merged-blind.md     # Stage 3: provenance-stripped copy sent to round 2
  r2/claude.md           # Stage 4: cross-examination verdicts
  r2/codex.md            # Stage 4: cross-examination verdicts
  final-review.md        # Stage 5: agreement matrix + reconciled review  <- the deliverable
  logs/                  # exact prompts + engine session logs
```

Both reviewers get a byte-identical prompt, so divergence is a model difference rather than a
prompt difference. Rounds are driven by `scripts/panel-round.sh`, which runs the two engines in
parallel and tolerates one leg failing (exit `2` = degraded panel, reported as such):

```bash
scripts/panel-round.sh --round 1 --pr <n> --dir .review_loop/pr-<n> \
  [--engines claude,codex] [--claude-model opus[1m]:xhigh] \
  [--codex-model gpt-5.6-sol:xhigh] [--timeout 3600]
```

Budget roughly four heavy model passes per PR, plus orchestration.

`.review_loop/` is review output, not source -- add it to the reviewed repo's `.gitignore`
(the skills offer to do this for you).

---

## Repository layout

```
MyConfig/
  .claude-plugin/
    plugin.json            # plugin manifest (name: myconfig)
    marketplace.json       # marketplace manifest (name: JingwenGu0829)
  skills/
    review-pr/SKILL.md        # the rubric every review workflow inherits
    review-pr-cx/SKILL.md
    review-pr-panel/SKILL.md
    slop-cleaner/SKILL.md
    benchmark-sweeper/SKILL.md
  scripts/
    codex-review-review.sh # review-pr-cx Stage 2 wrapper around `codex exec`
    panel-round.sh         # review-pr-panel: one round, both engines, in parallel
    portable-timeout.sh    # mac/linux timeout helper
  templates/
    codex-critique-rubric.md      # the 3-axis critique prompt Codex receives (cx)
    panel-round1-reviewer.md      # independent-review prompt (panel round 1)
    panel-round2-crosscheck.md    # blinded cross-examination prompt (panel round 2)
```

## Design notes

- `review-pr` is the single source of rubric truth. `review-pr-cx` and `review-pr-panel` both
  inline it into every model they dispatch, so the standard does not drift between workflows.
- `review-pr-cx` is deliberately lightweight: one Bash wrapper around `codex exec` (modeled on
  humanize's `ask-codex`), no Stop hooks and no state machine. One round only:
  Claude -> Codex -> Claude. Reach for it when you want a fast second opinion.
- `review-pr-panel` is the expensive one: two rounds, two reviewers, blinded cross-examination,
  and an orchestrator that verifies every surviving finding against the code. Reach for it when
  you care more about knowing what the models *disagree* on than about turnaround time.
- Neither dispatches reviewers as Claude sub-agents. Separate processes mean the second opinion
  does not inherit the orchestrator's context, which is the entire point of asking twice.
- The Codex step needs no network or GitHub access -- it reads the locally generated diff and
  Claude's review from disk, consistent with `review-pr`'s "don't touch the remote" rule.
- Bumping the version: update it in both `.claude-plugin/plugin.json` and
  `.claude-plugin/marketplace.json` (keep them in sync), format `X.Y.Z`.
