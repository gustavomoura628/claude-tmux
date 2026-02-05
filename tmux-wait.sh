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
        *) echo "Usage: $0 [-h host] [-s session] [timeout]" >&2; exit 1 ;;
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

# Helper: pipe stdin to a command locally or over SSH
pipe_to() {
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

# Unique tag for this invocation
TAG="$$-$(date +%s)"
BUFFER_NAME="claude-${SESSION}"

# Check if something is already running
if ! is_idle; then
    echo "[ERROR] Pane is busy ($(get_pane_command)). Wait or use a different session." >&2
    exit 1
fi

# Load command into a named tmux buffer (no escaping needed - travels via stdin)
printf '%s' "$CMD" | pipe_to "tmux load-buffer -b $BUFFER_NAME -"

# Execute
if [[ "$CMD" == *$'\n'* ]]; then
    # Multi-line: wrap in heredoc so commands run as a batch
    MARKER="__EOF_${TAG}__"
    run "tmux send-keys -t $SESSION 'bash << '\\''$MARKER'\\''' Enter"
    run "tmux paste-buffer -t $SESSION -b $BUFFER_NAME"
    run "tmux send-keys -t $SESSION Enter '$MARKER' Enter"
else
    # Single-line: just paste and enter
    MARKER="__CMD_${TAG}__"
    run "tmux paste-buffer -t $SESSION -b $BUFFER_NAME"
    run "tmux send-keys -t $SESSION ' #$MARKER' Enter"
fi

# Wait briefly for command to start
sleep 0.3

# Wait for command to complete (pane returns to idle)
if ! wait_for_idle; then
    echo "[TIMEOUT after ${TIMEOUT}s -- command may still be running]" >&2
    exit 1
fi

# Small delay to ensure output is flushed
sleep 0.1

# Capture: find LAST occurrence of marker, take everything after, remove trailing prompt
# tac reverses, awk takes lines until marker (which was after marker in original), tac restores order
run "tmux capture-pane -t $SESSION -p -S -200" | tac | awk -v marker="$MARKER" '
    $0 ~ marker { exit }
    { print }
' | tac | head -n -1
