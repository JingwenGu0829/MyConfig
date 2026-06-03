#!/usr/bin/env bash
#
# codex-review-review.sh - Have Codex critique Claude's PR review.
#
# Stage 2 of the review-pr-cx (Claude -> Codex -> Claude) scheme.
# Codex reads Claude's setup evidence, the locally-generated diff, and Claude's
# review. It audits setup, independently reviews with the review-pr rubric, then
# critiques the review on three axes (incorrect claim / missed issue / framing).
# This is a one-shot consultation modeled on humanize's ask-codex.sh -- no state,
# no hooks.
#
# Usage:
#   codex-review-review.sh --pr <n> --setup <path> --diff <path> \
#                          --review <path> --out <path> \
#                          [--codex-model MODEL:EFFORT] [--codex-timeout SECONDS]
#
# Output:
#   --out : Codex's critique (markdown). Also echoed to stdout for Claude to read.
#   stderr: status/debug info.
#
# Exit codes:
#   0   success (critique in --out and on stdout)
#   1   validation error (missing codex/args/files, invalid flags)
#   124 timeout
#   *   codex process error (reported with stderr tail)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/portable-timeout.sh"

# Plugin root is the parent of scripts/ . Falls back to CLAUDE_PLUGIN_ROOT when set.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RUBRIC_FILE="$PLUGIN_ROOT/templates/codex-critique-rubric.md"
REVIEW_PR_SKILL_FILE="$PLUGIN_ROOT/skills/review-pr/SKILL.md"

# ---- Defaults ----
DEFAULT_CODEX_MODEL="gpt-5.5"
DEFAULT_CODEX_EFFORT="high"
DEFAULT_CODEX_TIMEOUT=3600

CODEX_MODEL="$DEFAULT_CODEX_MODEL"
CODEX_EFFORT="$DEFAULT_CODEX_EFFORT"
CODEX_TIMEOUT="$DEFAULT_CODEX_TIMEOUT"
PR_NUMBER=""
SETUP_FILE=""
DIFF_FILE=""
REVIEW_FILE=""
OUT_FILE=""

show_help() {
    cat << 'HELP_EOF'
codex-review-review.sh - Codex critiques Claude's PR review (Stage 2 of review-pr-cx)

USAGE:
  codex-review-review.sh --pr <n> --setup <path> --diff <path> --review <path> --out <path> [OPTIONS]

REQUIRED:
  --pr <n>             PR number (used only for log labels)
  --setup <path>       Setup evidence (e.g. .review_loop/pr-<n>/setup.md)
  --diff <path>        Locally-generated PR diff (e.g. .review_loop/pr-<n>/diff.patch)
  --review <path>      Claude's review (e.g. .review_loop/pr-<n>/claude-review.md)
  --out <path>         Where to write Codex's critique (e.g. .review_loop/pr-<n>/codex-critique.md)

OPTIONS:
  --codex-model <MODEL:EFFORT>   Default: gpt-5.5:high
  --codex-timeout <SECONDS>      Default: 3600
  -h, --help                     Show this help

ENVIRONMENT:
  HUMANIZE_CODEX_BYPASS_SANDBOX  "true"/"1" -> use --dangerously-bypass-approvals-and-sandbox
                                 instead of --full-auto (dangerous; only if codex sandbox blocks file reads)
HELP_EOF
    exit 0
}

# ---- Parse args ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help ;;
        --pr)            PR_NUMBER="${2:-}"; shift 2 ;;
        --setup)         SETUP_FILE="${2:-}"; shift 2 ;;
        --diff)          DIFF_FILE="${2:-}"; shift 2 ;;
        --review)        REVIEW_FILE="${2:-}"; shift 2 ;;
        --out)           OUT_FILE="${2:-}"; shift 2 ;;
        --codex-timeout) CODEX_TIMEOUT="${2:-}"; shift 2 ;;
        --codex-model)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --codex-model requires a MODEL:EFFORT argument" >&2
                exit 1
            fi
            if [[ "$2" == *:* ]]; then
                CODEX_MODEL="${2%%:*}"
                CODEX_EFFORT="${2#*:}"
            else
                CODEX_MODEL="$2"
                CODEX_EFFORT="$DEFAULT_CODEX_EFFORT"
            fi
            shift 2
            ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
        *)
            echo "Error: Unexpected positional argument: $1" >&2
            exit 1
            ;;
    esac
done

# ---- Validate ----
if ! command -v codex &>/dev/null; then
    echo "Error: 'codex' command is not installed or not in PATH" >&2
    echo "Install Codex CLI: https://github.com/openai/codex" >&2
    exit 1
fi

for pair in "--pr:$PR_NUMBER" "--setup:$SETUP_FILE" "--diff:$DIFF_FILE" "--review:$REVIEW_FILE" "--out:$OUT_FILE"; do
    flag="${pair%%:*}"; val="${pair#*:}"
    if [[ -z "$val" ]]; then
        echo "Error: missing required argument $flag (use --help)" >&2
        exit 1
    fi
done

if [[ ! "$CODEX_TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "Error: --codex-timeout must be a positive integer (seconds), got: $CODEX_TIMEOUT" >&2
    exit 1
fi
if [[ ! "$CODEX_MODEL" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Error: Codex model contains invalid characters: $CODEX_MODEL" >&2
    exit 1
fi
if [[ ! "$CODEX_EFFORT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Codex effort contains invalid characters: $CODEX_EFFORT" >&2
    exit 1
fi
if [[ ! -f "$SETUP_FILE" ]]; then
    echo "Error: setup file not found: $SETUP_FILE" >&2
    exit 1
fi
if [[ ! -f "$DIFF_FILE" ]]; then
    echo "Error: diff file not found: $DIFF_FILE" >&2
    exit 1
fi
if [[ ! -f "$REVIEW_FILE" ]]; then
    echo "Error: review file not found: $REVIEW_FILE" >&2
    exit 1
fi
if [[ ! -f "$RUBRIC_FILE" ]]; then
    echo "Error: rubric template not found: $RUBRIC_FILE" >&2
    echo "  (expected under \$CLAUDE_PLUGIN_ROOT/templates/ or ../templates/)" >&2
    exit 1
fi
if [[ ! -f "$REVIEW_PR_SKILL_FILE" ]]; then
    echo "Error: review-pr skill not found: $REVIEW_PR_SKILL_FILE" >&2
    echo "  (expected under \$CLAUDE_PLUGIN_ROOT/skills/review-pr/SKILL.md or ../skills/review-pr/SKILL.md)" >&2
    exit 1
fi

# ---- Resolve absolute paths so codex (run with -C <root>) can find them ----
abspath() { (cd "$(dirname "$1")" && printf '%s/%s' "$(pwd)" "$(basename "$1")"); }
SETUP_ABS="$(abspath "$SETUP_FILE")"
DIFF_ABS="$(abspath "$DIFF_FILE")"
REVIEW_ABS="$(abspath "$REVIEW_FILE")"
mkdir -p "$(dirname "$OUT_FILE")"
OUT_ABS="$(abspath "$OUT_FILE")"

# Working dir for codex: the repo root containing the diff (so it can read changed files too).
ARTIFACT_DIR="$(dirname "$DIFF_ABS")"
if CODEX_CWD="$(git -C "$ARTIFACT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
    :
elif CODEX_CWD="$(cd "$ARTIFACT_DIR/../.." 2>/dev/null && pwd)"; then
    :
else
    CODEX_CWD="$(pwd)"
fi

# ---- Build prompt: Codex rubric + review-pr rubric + concrete file pointers ----
PROMPT="$(cat "$RUBRIC_FILE")

---

## Review-pr rubric Claude was asked to follow

Codex must use this same methodology for its independent review pass:

BEGIN REVIEW-PR SKILL
$(cat "$REVIEW_PR_SKILL_FILE")
END REVIEW-PR SKILL

---

## Inputs for this run (PR #${PR_NUMBER})

You are running with the repository checked out at the PR head. Read these files from
disk before writing the critique:

- Setup evidence from Claude: ${SETUP_ABS}
- PR diff (locally generated, authoritative evidence): ${DIFF_ABS}
- Claude's review to critique: ${REVIEW_ABS}

First audit setup, then independently review the diff/source using the review-pr rubric,
then compare with Claude on the three axes. You may also open any changed source file
referenced in the diff for full context. Do not modify any file. Do not access the
network or GitHub. Output only the critique in the schema defined above."

# ---- Build codex command (same pattern as ask-codex.sh) ----
CODEX_EXEC_ARGS=("-m" "$CODEX_MODEL")
if [[ -n "$CODEX_EFFORT" ]]; then
    CODEX_EXEC_ARGS+=("-c" "model_reasoning_effort=${CODEX_EFFORT}")
fi
CODEX_AUTO_FLAG="--full-auto"
if [[ "${HUMANIZE_CODEX_BYPASS_SANDBOX:-}" == "true" ]] || [[ "${HUMANIZE_CODEX_BYPASS_SANDBOX:-}" == "1" ]]; then
    CODEX_AUTO_FLAG="--dangerously-bypass-approvals-and-sandbox"
fi
CODEX_EXEC_ARGS+=("$CODEX_AUTO_FLAG" "-C" "$CODEX_CWD")

echo "codex-review-review: pr=#${PR_NUMBER} model=${CODEX_MODEL} effort=${CODEX_EFFORT} timeout=${CODEX_TIMEOUT}s" >&2
echo "codex-review-review: cwd=${CODEX_CWD}" >&2
echo "codex-review-review: running codex exec..." >&2

# ---- Run ----
CODEX_EXIT_CODE=0
printf '%s' "$PROMPT" | run_with_timeout "$CODEX_TIMEOUT" codex exec "${CODEX_EXEC_ARGS[@]}" - \
    > "$OUT_ABS" 2> "${OUT_ABS}.log" || CODEX_EXIT_CODE=$?

if [[ $CODEX_EXIT_CODE -eq 124 ]]; then
    echo "Error: Codex timed out after ${CODEX_TIMEOUT}s. Retry with --codex-timeout $((CODEX_TIMEOUT * 2))" >&2
    exit 124
fi
if [[ $CODEX_EXIT_CODE -ne 0 ]]; then
    echo "Error: Codex exited with code $CODEX_EXIT_CODE" >&2
    if [[ -s "${OUT_ABS}.log" ]]; then
        echo "Codex stderr (last 20 lines):" >&2
        tail -20 "${OUT_ABS}.log" >&2
    fi
    exit "$CODEX_EXIT_CODE"
fi
if [[ ! -s "$OUT_ABS" ]]; then
    echo "Error: Codex returned an empty critique" >&2
    if [[ -s "${OUT_ABS}.log" ]]; then
        echo "Codex stderr (last 20 lines):" >&2
        tail -20 "${OUT_ABS}.log" >&2
    fi
    exit 1
fi

# Clean up the stderr log on success to keep the artifact dir tidy.
rm -f "${OUT_ABS}.log"

echo "codex-review-review: critique saved to ${OUT_FILE}" >&2
cat "$OUT_ABS"
