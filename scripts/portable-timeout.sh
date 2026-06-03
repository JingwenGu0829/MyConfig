#!/usr/bin/env bash
#
# Portable timeout wrapper for macOS/Linux compatibility.
# Usage: source portable-timeout.sh; run_with_timeout <seconds> <command> [args...]
#
# Priority: gtimeout (Homebrew) > timeout (GNU) > python3 > no timeout
#

# Detect available timeout implementation
detect_timeout_impl() {
    if command -v gtimeout &>/dev/null; then
        echo "gtimeout"
    elif command -v timeout &>/dev/null; then
        if timeout --version &>/dev/null 2>&1; then
            echo "timeout"
        else
            echo "none"
        fi
    elif command -v python3 &>/dev/null; then
        echo "python3"
    elif command -v python &>/dev/null; then
        echo "python"
    else
        echo "none"
    fi
}

TIMEOUT_IMPL=$(detect_timeout_impl)

# Run command with timeout. Args: timeout_seconds command [args...]
# Returns 124 on timeout (matches GNU timeout).
run_with_timeout() {
    local timeout_secs="$1"
    shift
    local cmd=("$@")

    case "$TIMEOUT_IMPL" in
        gtimeout)
            gtimeout "$timeout_secs" "${cmd[@]}"
            return $?
            ;;
        timeout)
            timeout "$timeout_secs" "${cmd[@]}"
            return $?
            ;;
        python3|python)
            "$TIMEOUT_IMPL" -c "
import subprocess
import sys

try:
    result = subprocess.run(sys.argv[1:], timeout=$timeout_secs)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
" "${cmd[@]}"
            return $?
            ;;
        none)
            echo "Warning: No timeout implementation available. Running without timeout." >&2
            "${cmd[@]}"
            return $?
            ;;
    esac
}

export TIMEOUT_IMPL
