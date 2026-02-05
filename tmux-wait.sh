#!/usr/bin/env bash
# tmux-wait.sh -- Send a command to a tmux session, wait for it to finish.
#
# Usage: ./tmux-wait.sh [options] <command> [timeout_seconds]
#
# Options (or environment variables):
#   -h HOST     SSH host, omit for local (env: TMUX_REMOTE_HOST)
#   -s SESSION  tmux session name (env: TMUX_REMOTE_SESSION)
#
# Examples:
#   ./tmux-wait.sh -s mysession 'make build'              # local
#   ./tmux-wait.sh -h user@server -s mysession 'ls' 30    # remote
#   TMUX_REMOTE_SESSION=dev ./tmux-wait.sh 'npm test'     # env vars

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

CMD="${1:?Usage: $0 [-h host] [-s session] <command> [timeout]}"
TIMEOUT="${2:-120}"
POLL_INTERVAL=2

# Helper: run a command locally or over SSH depending on HOST
run() {
    if [ -n "$HOST" ]; then
        ssh "$HOST" "$1"
    else
        bash -c "$1"
    fi
}

# Generate unique markers
TAG="$$-$(date +%s)"
START_MARKER="TMUX_START_${TAG}"
END_MARKER="TMUX_END_${TAG}"

# Start marker (no-op), then command chained with echo end marker.
# The echo only produces output after the command finishes.
run "tmux send-keys -t $SESSION ': $START_MARKER' Enter"
sleep 0.3
run "tmux send-keys -t $SESSION '($CMD); echo $END_MARKER' Enter"

# Poll for end marker as its own line (not as part of the typed command line)
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))

    full_output=$(run "tmux capture-pane -t $SESSION -p -S -500")

    # The end marker appears twice: once in the command line (typed), once as echo output.
    # The echo output is on its own line. Check for 2+ occurrences.
    match_count=$(echo "$full_output" | grep -cF -- "$END_MARKER" || true)
    if [ "$match_count" -ge 2 ]; then
        # Extract from start marker onward, skip the start marker line and the command line,
        # then stop before the standalone end marker (second occurrence)
        echo "$full_output" | sed -n "/$START_MARKER/,\$p" | tail -n +3 | sed "/^${END_MARKER}\$/,\$d"
        exit 0
    fi
done

# Timeout -- print whatever we have after the start marker
echo "[TIMEOUT after ${TIMEOUT}s -- command may still be running]" >&2
echo "$full_output" | sed -n "/$START_MARKER/,\$p" | tail -n +2
exit 1
