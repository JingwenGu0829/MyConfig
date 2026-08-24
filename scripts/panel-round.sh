#!/usr/bin/env bash
#
# panel-round.sh - Run one panel round: two independent reviewers, in parallel.
#
# Used by the review-pr-panel skill (Fable orchestrates, Claude and Codex review).
# Both engines receive a byte-identical prompt, so any difference in the two
# reviews comes from the model, not the prompt.
#
#   Round 1 - independent review of the PR diff.
#             inputs : <dir>/setup.md, <dir>/diff.patch
#             outputs: <dir>/r1/claude.md, <dir>/r1/codex.md
#
#   Round 2 - blinded cross-examination of the orchestrator's merged review.
#             inputs : <dir>/r1/merged-blind.md, <dir>/diff.patch
#             outputs: <dir>/r2/claude.md, <dir>/r2/codex.md
#
# Usage:
#   panel-round.sh --round 1|2 --pr <n> --dir <artifact-dir> [OPTIONS]
#
# Exit codes:
#   0   every requested engine succeeded
#   2   partial - at least one engine succeeded, at least one failed
#   1   validation error, or every requested engine failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/portable-timeout.sh"

# Plugin root is the parent of scripts/ . Falls back to CLAUDE_PLUGIN_ROOT when set.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
REVIEW_PR_SKILL_FILE="$PLUGIN_ROOT/skills/review-pr/SKILL.md"
ROUND1_TEMPLATE="$PLUGIN_ROOT/templates/panel-round1-reviewer.md"
ROUND2_TEMPLATE="$PLUGIN_ROOT/templates/panel-round2-crosscheck.md"

# ---- Defaults ----
DEFAULT_CLAUDE_MODEL="opus[1m]"
DEFAULT_CLAUDE_EFFORT="xhigh"
DEFAULT_CODEX_MODEL="gpt-5.6-sol"
DEFAULT_CODEX_EFFORT="xhigh"
DEFAULT_TIMEOUT=3600

CLAUDE_MODEL="$DEFAULT_CLAUDE_MODEL"
CLAUDE_EFFORT="$DEFAULT_CLAUDE_EFFORT"
CODEX_MODEL="$DEFAULT_CODEX_MODEL"
CODEX_EFFORT="$DEFAULT_CODEX_EFFORT"
TIMEOUT="$DEFAULT_TIMEOUT"
ENGINES="claude,codex"
ROUND=""
PR_NUMBER=""
DIR=""
REPO=""

# Read-only tool surface for the headless Claude reviewer. Write/Edit and any
# sub-agent tool are excluded outright, so the reviewer cannot mutate the repo.
CLAUDE_TOOLS="Bash,Read,Grep,Glob"
CLAUDE_ALLOWED_TOOLS="Bash(git *),Bash(rg *),Bash(grep *),Bash(ls *),Bash(find *),Bash(head *),Bash(tail *),Bash(wc *),Bash(sed -n *),Read,Grep,Glob"

show_help() {
    cat << 'HELP_EOF'
panel-round.sh - one round of the Claude+Codex review panel, run in parallel

USAGE:
  panel-round.sh --round 1|2 --pr <n> --dir <artifact-dir> [OPTIONS]

REQUIRED:
  --round <1|2>        1 = independent review, 2 = blinded cross-examination
  --pr <n>             PR number (log labels only)
  --dir <path>         Artifact directory, e.g. .review_loop/pr-<n>

OPTIONS:
  --repo <path>          Repo root the reviewers read. Default: git toplevel of --dir
  --engines <list>       Comma-separated subset of claude,codex. Default: claude,codex
                         (use to re-run a single leg after a failure)
  --claude-model <M[:E]> Default: opus[1m]:xhigh
  --codex-model <M[:E]>  Default: gpt-5.6-sol:xhigh
  --timeout <SECONDS>    Per-engine timeout. Default: 3600
  -h, --help             Show this help

INPUTS (must already exist):
  round 1: <dir>/setup.md, <dir>/diff.patch
  round 2: <dir>/r1/merged-blind.md, <dir>/diff.patch

OUTPUTS:
  <dir>/r<N>/claude.md, <dir>/r<N>/codex.md
  <dir>/logs/r<N>-prompt.md         the exact prompt both engines received
  <dir>/logs/r<N>-<engine>.log      engine stderr/session log

EXIT CODES:
  0 all engines ok | 2 partial failure | 1 validation error or total failure
HELP_EOF
    exit 0
}

split_model_effort() {
    # $1 = "MODEL[:EFFORT]", $2 = default effort. Sets SPLIT_MODEL / SPLIT_EFFORT.
    if [[ "$1" == *:* ]]; then
        SPLIT_MODEL="${1%%:*}"
        SPLIT_EFFORT="${1#*:}"
    else
        SPLIT_MODEL="$1"
        SPLIT_EFFORT="$2"
    fi
}

# ---- Parse args ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)   show_help ;;
        --round)     ROUND="${2:-}"; shift 2 ;;
        --pr)        PR_NUMBER="${2:-}"; shift 2 ;;
        --dir)       DIR="${2:-}"; shift 2 ;;
        --repo)      REPO="${2:-}"; shift 2 ;;
        --engines)   ENGINES="${2:-}"; shift 2 ;;
        --timeout)   TIMEOUT="${2:-}"; shift 2 ;;
        --claude-model)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --claude-model requires a MODEL[:EFFORT] argument" >&2
                exit 1
            fi
            split_model_effort "$2" "$DEFAULT_CLAUDE_EFFORT"
            CLAUDE_MODEL="$SPLIT_MODEL"; CLAUDE_EFFORT="$SPLIT_EFFORT"
            shift 2
            ;;
        --codex-model)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --codex-model requires a MODEL[:EFFORT] argument" >&2
                exit 1
            fi
            split_model_effort "$2" "$DEFAULT_CODEX_EFFORT"
            CODEX_MODEL="$SPLIT_MODEL"; CODEX_EFFORT="$SPLIT_EFFORT"
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
for pair in "--round:$ROUND" "--pr:$PR_NUMBER" "--dir:$DIR"; do
    flag="${pair%%:*}"; val="${pair#*:}"
    if [[ -z "$val" ]]; then
        echo "Error: missing required argument $flag (use --help)" >&2
        exit 1
    fi
done

if [[ "$ROUND" != "1" && "$ROUND" != "2" ]]; then
    echo "Error: --round must be 1 or 2, got: $ROUND" >&2
    exit 1
fi
if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "Error: --timeout must be a positive integer (seconds), got: $TIMEOUT" >&2
    exit 1
fi
# Claude model aliases may carry a context suffix such as opus[1m]. Inside the bracket
# expression ']' must lead and '-' must trail to be read as literals.
if [[ ! "$CLAUDE_MODEL" =~ ^[]A-Za-z0-9._[-]+$ ]]; then
    echo "Error: Claude model contains invalid characters: $CLAUDE_MODEL" >&2
    exit 1
fi
if [[ ! "$CODEX_MODEL" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Error: Codex model contains invalid characters: $CODEX_MODEL" >&2
    exit 1
fi
for effort in "$CLAUDE_EFFORT" "$CODEX_EFFORT"; do
    if [[ ! "$effort" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Error: effort contains invalid characters: $effort" >&2
        exit 1
    fi
done
if [[ ! -d "$DIR" ]]; then
    echo "Error: artifact directory not found: $DIR" >&2
    exit 1
fi

RUN_CLAUDE=false
RUN_CODEX=false
IFS=',' read -r -a ENGINE_LIST <<< "$ENGINES"
for engine in "${ENGINE_LIST[@]}"; do
    case "$engine" in
        claude) RUN_CLAUDE=true ;;
        codex)  RUN_CODEX=true ;;
        "")     ;;
        *)
            echo "Error: unknown engine '$engine' (expected claude and/or codex)" >&2
            exit 1
            ;;
    esac
done
if [[ "$RUN_CLAUDE" == false && "$RUN_CODEX" == false ]]; then
    echo "Error: --engines selected no engines" >&2
    exit 1
fi
if [[ "$RUN_CLAUDE" == true ]] && ! command -v claude &>/dev/null; then
    echo "Error: 'claude' command is not installed or not in PATH" >&2
    exit 1
fi
if [[ "$RUN_CODEX" == true ]] && ! command -v codex &>/dev/null; then
    echo "Error: 'codex' command is not installed or not in PATH" >&2
    echo "Install Codex CLI: https://github.com/openai/codex" >&2
    exit 1
fi

for f in "$REVIEW_PR_SKILL_FILE" "$ROUND1_TEMPLATE" "$ROUND2_TEMPLATE"; do
    if [[ ! -f "$f" ]]; then
        echo "Error: required plugin file not found: $f" >&2
        echo "  (expected under \$CLAUDE_PLUGIN_ROOT or ../ relative to scripts/)" >&2
        exit 1
    fi
done

# ---- Resolve paths ----
abspath() { (cd "$(dirname "$1")" && printf '%s/%s' "$(pwd)" "$(basename "$1")"); }
DIR_ABS="$(cd "$DIR" && pwd)"
DIFF_ABS="$DIR_ABS/diff.patch"
SETUP_ABS="$DIR_ABS/setup.md"
MERGED_ABS="$DIR_ABS/r1/merged-blind.md"

if [[ ! -f "$DIFF_ABS" ]]; then
    echo "Error: diff not found: $DIFF_ABS" >&2
    exit 1
fi
if [[ "$ROUND" == "1" && ! -f "$SETUP_ABS" ]]; then
    echo "Error: setup evidence not found: $SETUP_ABS" >&2
    exit 1
fi
if [[ "$ROUND" == "2" && ! -f "$MERGED_ABS" ]]; then
    echo "Error: blinded merged review not found: $MERGED_ABS" >&2
    echo "  (round 2 needs the provenance-stripped synthesis from round 1)" >&2
    exit 1
fi

# Reviewers read the repo checked out at the PR head, not just the diff.
if [[ -z "$REPO" ]]; then
    if ! REPO="$(git -C "$DIR_ABS" rev-parse --show-toplevel 2>/dev/null)"; then
        REPO="$(cd "$DIR_ABS/../.." 2>/dev/null && pwd)" || REPO="$(pwd)"
    fi
fi
if [[ ! -d "$REPO" ]]; then
    echo "Error: repo root not found: $REPO" >&2
    exit 1
fi
REPO="$(cd "$REPO" && pwd)"

OUT_DIR="$DIR_ABS/r$ROUND"
LOG_DIR="$DIR_ABS/logs"
mkdir -p "$OUT_DIR" "$LOG_DIR"
PROMPT_FILE="$LOG_DIR/r$ROUND-prompt.md"

# ---- Build the prompt (identical for both engines) ----
if [[ "$ROUND" == "1" ]]; then
    TEMPLATE_BODY="$(cat "$ROUND1_TEMPLATE")"
    INPUT_POINTERS="- Setup evidence (how the diff was produced): ${SETUP_ABS}
- PR diff, locally generated and authoritative: ${DIFF_ABS}
- Repository checked out at the PR head: ${REPO}"
else
    TEMPLATE_BODY="$(cat "$ROUND2_TEMPLATE")"
    INPUT_POINTERS="- Merged panel review to cross-examine: ${MERGED_ABS}
- PR diff, locally generated and authoritative: ${DIFF_ABS}
- Repository checked out at the PR head: ${REPO}"
fi

PROMPT="$TEMPLATE_BODY

---

## Review-pr rubric

Apply this methodology, including its P0-P4 and HIGH/LOW severity discipline:

BEGIN REVIEW-PR SKILL
$(cat "$REVIEW_PR_SKILL_FILE")
END REVIEW-PR SKILL

---

## Inputs for this run (PR #${PR_NUMBER}, round ${ROUND})

Read these from disk before writing anything:

${INPUT_POINTERS}

Open any changed source file, its callers, and its tests for full context. Do not
modify any file. Do not access the network or GitHub. Do not spawn sub-agents or
delegate any part of this review. Output only the document defined by the schema
above, and nothing else."

printf '%s\n' "$PROMPT" > "$PROMPT_FILE"

# ---- Engine runners ----
# Each writes its raw answer to <out>.raw, then a stamped copy to <out>.

run_claude() {
    local out="$OUT_DIR/claude.md"
    local log="$LOG_DIR/r$ROUND-claude.log"
    local rc=0

    (
        cd "$REPO" || exit 1
        printf '%s' "$PROMPT" | run_with_timeout "$TIMEOUT" claude -p \
            --model "$CLAUDE_MODEL" \
            --effort "$CLAUDE_EFFORT" \
            --permission-mode dontAsk \
            --disable-slash-commands \
            --add-dir "$DIR_ABS" \
            --tools "$CLAUDE_TOOLS" \
            --allowedTools "$CLAUDE_ALLOWED_TOOLS"
    ) > "$out.raw" 2> "$log" || rc=$?

    finalize_output "$out" "claude" "$CLAUDE_MODEL:$CLAUDE_EFFORT" "$rc" "$log"
}

run_codex() {
    local out="$OUT_DIR/codex.md"
    local log="$LOG_DIR/r$ROUND-codex.log"
    local rc=0

    printf '%s' "$PROMPT" | run_with_timeout "$TIMEOUT" codex exec \
        -m "$CODEX_MODEL" \
        -c model_reasoning_effort="$CODEX_EFFORT" \
        --sandbox read-only \
        -C "$REPO" \
        -o "$out.raw" \
        - > "$log" 2>&1 || rc=$?

    finalize_output "$out" "codex" "$CODEX_MODEL:$CODEX_EFFORT" "$rc" "$log"
}

# finalize_output <out> <engine> <model:effort> <exit_code> <log>
# Stamps provenance onto the raw answer and returns the engine's effective status.
finalize_output() {
    local out="$1" engine="$2" model="$3" rc="$4" log="$5"

    if [[ "$rc" -eq 0 && ! -s "$out.raw" ]]; then
        echo "Error: $engine returned an empty document" >&2
        rc=1
    fi
    if [[ "$rc" -ne 0 ]]; then
        rm -f "$out.raw"
        return "$rc"
    fi

    {
        printf '<!-- panel: engine=%s model=%s round=%s pr=%s -->\n\n' \
            "$engine" "$model" "$ROUND" "$PR_NUMBER"
        cat "$out.raw"
    } > "$out"
    rm -f "$out.raw"
    return 0
}

# ---- Run both engines in parallel ----
echo "panel-round: round=$ROUND pr=#$PR_NUMBER engines=$ENGINES timeout=${TIMEOUT}s" >&2
echo "panel-round: repo=$REPO" >&2
echo "panel-round: prompt=$PROMPT_FILE" >&2

CLAUDE_PID=""
CODEX_PID=""
CLAUDE_RC=0
CODEX_RC=0

if [[ "$RUN_CLAUDE" == true ]]; then
    echo "panel-round: launching claude ($CLAUDE_MODEL:$CLAUDE_EFFORT)..." >&2
    run_claude & CLAUDE_PID=$!
fi
if [[ "$RUN_CODEX" == true ]]; then
    echo "panel-round: launching codex ($CODEX_MODEL:$CODEX_EFFORT)..." >&2
    run_codex & CODEX_PID=$!
fi

[[ -n "$CLAUDE_PID" ]] && { wait "$CLAUDE_PID" || CLAUDE_RC=$?; }
[[ -n "$CODEX_PID" ]]  && { wait "$CODEX_PID"  || CODEX_RC=$?; }

# ---- Report ----
OK_COUNT=0
FAIL_COUNT=0

report_engine() {
    # Separate assignments: a single `local` expands all its words before assigning any,
    # so `out` would be built from a stale `engine`.
    local engine="$1"
    local rc="$2"
    local out="$OUT_DIR/$engine.md"
    local log="$LOG_DIR/r$ROUND-$engine.log"
    if [[ "$rc" -eq 0 ]]; then
        OK_COUNT=$((OK_COUNT + 1))
        echo "panel-round:   $engine -> $out ($(wc -l < "$out" | tr -d ' ') lines)" >&2
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        if [[ "$rc" -eq 124 ]]; then
            echo "panel-round:   $engine FAILED: timed out after ${TIMEOUT}s (retry with --engines $engine --timeout $((TIMEOUT * 2)))" >&2
        else
            echo "panel-round:   $engine FAILED: exit $rc" >&2
        fi
        if [[ -s "$log" ]]; then
            echo "panel-round:   $engine log tail:" >&2
            tail -10 "$log" >&2
        fi
    fi
}

[[ "$RUN_CLAUDE" == true ]] && report_engine "claude" "$CLAUDE_RC"
[[ "$RUN_CODEX" == true ]]  && report_engine "codex" "$CODEX_RC"

if [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo "panel-round: status=ok" >&2
    exit 0
fi
if [[ "$OK_COUNT" -gt 0 ]]; then
    echo "panel-round: status=partial ($OK_COUNT ok, $FAIL_COUNT failed) - the panel is degraded, say so in the report" >&2
    exit 2
fi
echo "panel-round: status=failed (no reviewer produced a document)" >&2
exit 1
