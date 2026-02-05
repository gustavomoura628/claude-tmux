#!/usr/bin/env bash
# tmux-wait.sh -- Send a command to a tmux session, wait for it to finish.
# Output is captured and printed when command completes.

set -euo pipefail

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
CMD=$(cat)
TIMEOUT="${1:-120}"

[ -z "$CMD" ] && { echo "Error: no command provided via stdin" >&2; exit 1; }

run() {
    if [ -n "$HOST" ]; then ssh "$HOST" "$1"; else bash -c "$1"; fi
}

pipe_to() {
    if [ -n "$HOST" ]; then ssh "$HOST" "$1"; else bash -c "$1"; fi
}

is_idle() {
    local procs
    procs=$(run "ps --tty \$(tmux display-message -p -t $SESSION '#{pane_tty}' | sed 's|/dev/||') --forest -o pid 2>/dev/null | wc -l")
    [ "$procs" -eq 2 ]
}

count_lines() {
    run "tmux display-message -p -t $SESSION '#{history_size} #{cursor_y}'" | awk '{print $1 + $2}'
}

BUFFER_NAME="claude-${SESSION}"

is_idle || { echo "[ERROR] Pane is busy" >&2; exit 1; }

LINES_BEFORE=$(count_lines)

printf '%s' "$CMD" | pipe_to "tmux load-buffer -b $BUFFER_NAME -"

SKIP_LINES=0
if [[ "$CMD" == *$'\n'* ]]; then
    # Heredoc input: command lines + EOF line
    SKIP_LINES=$(( $(echo "$CMD" | wc -l) + 1 ))
    run "tmux send-keys -t $SESSION 'bash << '\\''EOF'\\''' Enter"
    run "tmux paste-buffer -t $SESSION -b $BUFFER_NAME"
    run "tmux send-keys -t $SESSION Enter 'EOF' Enter"
else
    run "tmux paste-buffer -t $SESSION -b $BUFFER_NAME"
    run "tmux send-keys -t $SESSION Enter"
fi

sleep 0.3

# Wait for completion
ELAPSED=0
while ! is_idle; do
    sleep 0.5
    ELAPSED=$((ELAPSED + 1))
    [ "$ELAPSED" -gt "$((TIMEOUT * 2))" ] && { echo "[TIMEOUT]" >&2; exit 1; }
done

sleep 0.1

# Capture output
LINES_AFTER=$(count_lines)
TOTAL_NEW=$((LINES_AFTER - LINES_BEFORE))

if [ "$TOTAL_NEW" -gt "$SKIP_LINES" ]; then
    OUTPUT_LINES=$((TOTAL_NEW - SKIP_LINES - 1))  # -1 for prompt
    if [ "$OUTPUT_LINES" -gt 0 ]; then
        HIST=$(run "tmux display-message -p -t $SESSION '#{history_size}'")
        run "tmux capture-pane -t $SESSION -p -S -$HIST" | tail -n "$((OUTPUT_LINES + 1))" | head -n "$OUTPUT_LINES"
    fi
fi
