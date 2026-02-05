#!/usr/bin/env bash
# tmux-wait.sh -- Send a command to a tmux session, wait for it to finish.
#
# Usage: ./tmux-wait.sh [options] [timeout_seconds] << 'EOF'
#        command here
#        EOF
#
# Options (or environment variables):
#   -h HOST     SSH host, omit for local (env: TMUX_REMOTE_HOST)
#   -s SESSION  tmux session name (env: TMUX_REMOTE_SESSION)
#
# Command is read from stdin (heredoc). This avoids shell escaping issues.
#
# Examples:
#   ./tmux-wait.sh -s mysession << 'EOF'
#   make build
#   EOF
#
#   ./tmux-wait.sh -h user@server -s mysession 30 << 'EOF'
#   if ! false; then echo "works"; fi
#   EOF

set -euo pipefail

# Parse options
OPT_HOST=""
OPT_SESSION=""
while getopts "h:s:" opt; do
    case $opt in
        h) OPT_HOST="$OPTARG" ;;
        s) OPT_SESSION="$OPTARG" ;;
        *) echo "Usage: $0 [-h host] [-s session] <command> [timeout]" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

HOST="${OPT_HOST:-${TMUX_REMOTE_HOST:-}}"
SESSION="${OPT_SESSION:-${TMUX_REMOTE_SESSION:?'Set -s SESSION or TMUX_REMOTE_SESSION'}}"

# Read command from stdin (heredoc)
CMD=$(cat)
TIMEOUT="${1:-120}"
POLL_INTERVAL=1

[ -z "$CMD" ] && { echo "Error: no command provided via stdin" >&2; exit 1; }

# Helper: run a command locally or over SSH depending on HOST
run() {
    if [ -n "$HOST" ]; then
        ssh "$HOST" "$1"
    else
        bash -c "$1"
    fi
}

# Check what's currently running in the pane
get_pane_command() {
    run "tmux display-message -p -t $SESSION '#{pane_current_command}'"
}

# Check if pane is idle (shell prompt)
is_idle() {
    local cmd
    cmd=$(get_pane_command)
    [[ "$cmd" == "bash" || "$cmd" == "zsh" || "$cmd" == "sh" || "$cmd" == "fish" ]]
}

# Wait for pane to become idle
wait_for_idle() {
    local elapsed=0
    while [ "$elapsed" -lt "$TIMEOUT" ]; do
        if is_idle; then
            return 0
        fi
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    return 1
}

# Generate unique marker
TAG="$$-$(date +%s)"
START_MARKER="TMUX_CMD_${TAG}"

# Check if something is already running
if ! is_idle; then
    echo "[ERROR] Pane is busy ($(get_pane_command)). Wait or use a different session." >&2
    exit 1
fi

# Base64 encode command to avoid escaping hell through SSH -> tmux
CMD_B64=$(printf '%s\n' "$CMD" | base64 -w0)
run "tmux send-keys -t $SESSION 'CMD=\$(echo $CMD_B64 | base64 -d); printf \"\\033[1;36m>>> \\$ \\033[0m%s\\n\" \"\$CMD\"; printf \"\\033[30;40m%s\\033[0m\\n\" \"$START_MARKER\"; eval \"\$CMD\"' Enter"

# Wait briefly for command to start (pane_current_command to change from shell)
sleep 0.3

# Wait for command to complete (pane returns to idle)
if ! wait_for_idle; then
    echo "[TIMEOUT after ${TIMEOUT}s -- command may still be running]" >&2
    # Still try to capture what we have
    run "tmux capture-pane -t $SESSION -p -S -500" | sed -n "/^${START_MARKER}$/,\$p" | tail -n +2 | tac | awk '/[^[:space:]]/{p=1} p' | tac | sed '$ d'
    exit 1
fi

# Small delay to ensure output is flushed
sleep 0.1

# Capture output from marker to end, excluding the marker line and final prompt
# Pipeline: find marker to end | skip marker | strip trailing blanks | remove prompt line
run "tmux capture-pane -t $SESSION -p -S -500" | sed -n "/^${START_MARKER}$/,\$p" | tail -n +2 | tac | awk '/[^[:space:]]/{p=1} p' | tac | sed '$ d'
