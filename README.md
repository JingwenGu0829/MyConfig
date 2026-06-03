
## Setup guide (Claude Code plugin)

This repo is a Claude Code **plugin** exposed through a single-plugin **marketplace**. The
plugin manifest is `.claude-plugin/plugin.json`; the marketplace manifest is
`.claude-plugin/marketplace.json`. Claude Code auto-discovers skills under `skills/`,
scripts under `scripts/`, and templates under `templates/`.

### Prerequisites

- **Claude Code** installed and authenticated.
- **Codex CLI** installed and authenticated (only needed for `review-pr-cx`):
  - Install: https://github.com/openai/codex
  - Verify: `codex --version`
  - `review-pr-cx` defaults to model `gpt-5.5` at `high` effort; make sure your Codex auth can use it.

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

Then check the skills are discoverable -- ask Claude to run `/myconfig:review-pr` or
`/myconfig:review-pr-cx`. (Plugin skills are namespaced as `myconfig:<skill>`.)

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

Runs three stages and writes everything under a strict per-PR folder in the repo being reviewed:

```
.pr-review/pr-<n>/
  diff.patch          # locally generated diff (evidence)
  claude-review.md    # Stage 1: Claude's review
  codex-critique.md   # Stage 2: Codex critiques the review (3 axes)
  final-review.md     # Stage 3: reconciled review + Codex Cross-Check Log  <- the deliverable
```

`final-review.md` is the file to read: it is Claude's review after every Codex point has been
either accepted (and applied) or rejected (with a one-line justification), plus a log table of
those decisions.

Optional flags are passed straight through to Codex:

- `--codex-model MODEL:EFFORT` (default `gpt-5.5:high`)
- `--codex-timeout SECONDS` (default `3600`)

`.pr-review/` is review output, not source -- add it to the reviewed repo's `.gitignore`
(the skill offers to do this for you).

---

## Repository layout

```
MyConfig/
  .claude-plugin/
    plugin.json            # plugin manifest (name: myconfig)
    marketplace.json       # marketplace manifest (name: JingwenGu0829)
  skills/
    review-pr/SKILL.md
    review-pr-cx/SKILL.md
    slop-cleaner/SKILL.md
    benchmark-sweeper/SKILL.md
  scripts/
    codex-review-review.sh # Stage 2 wrapper around `codex exec` (one-shot, no state)
    portable-timeout.sh    # mac/linux timeout helper
  templates/
    codex-critique-rubric.md  # the 3-axis critique prompt Codex receives
```

## Design notes

- `review-pr-cx` is deliberately lightweight: one Bash wrapper around `codex exec` (modeled on
  humanize's `ask-codex`), no Stop hooks and no state machine. One round only:
  Claude -> Codex -> Claude.
- The Codex step needs no network or GitHub access -- it reads the locally generated diff and
  Claude's review from disk, consistent with `review-pr`'s "don't touch the remote" rule.
- Bumping the version: update it in both `.claude-plugin/plugin.json` and
  `.claude-plugin/marketplace.json` (keep them in sync), format `X.Y.Z`.
