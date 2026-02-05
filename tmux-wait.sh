#!/usr/bin/env bash
# tmux-wait.sh -- Send a command to a tmux session, wait for it to finish.
# Output streams as it appears, with final capture when command completes.

set -euo pipefail

OPT_HOST=""
OPT_SESSION=""
OPT_TRUNCATE=""
OPT_CONTINUE=0
# Handle -t and -c with optional arguments (getopts can't do this natively)
args=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -t)
            if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                OPT_TRUNCATE="$2"
                shift 2
            else
                OPT_TRUNCATE="3000"
                shift
            fi
            ;;
        -c)
            OPT_CONTINUE=1
            shift
            ;;
        *) args+=("$1"); shift ;;
    esac
done
set -- "${args[@]}"

while getopts "h:s:" opt; do
    case $opt in
        h) OPT_HOST="$OPTARG" ;;
        s) OPT_SESSION="$OPTARG" ;;
        *) echo "Usage: $0 [-h host] [-s session] [-t [chars]] [-c] [timeout]" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

HOST="${OPT_HOST:-${TMUX_REMOTE_HOST:-}}"
SESSION="${OPT_SESSION:-${TMUX_REMOTE_SESSION:?'Set -s SESSION or TMUX_REMOTE_SESSION'}}"
TIMEOUT="${1:-30}"

if [ "$OPT_CONTINUE" -eq 1 ]; then
    CMD=""
else
    CMD=$(cat)
    [ -z "$CMD" ] && { echo "Error: no command provided via stdin" >&2; exit 1; }
fi

# Truncation: -t N limits output to N/2 chars at start + N/2 at end
TRUNCATE_TOTAL="${OPT_TRUNCATE:-0}"
TRUNCATE_HALF=$((TRUNCATE_TOTAL / 2))

run() {
    if [ -n "$HOST" ]; then ssh "$HOST" "$1"; else bash -c "$1"; fi
}

pipe_to() {
    if [ -n "$HOST" ]; then ssh "$HOST" "$1"; else bash -c "$1"; fi
}

DELIM="__SNAPSHOT_${$}_$$__"

# Atomic snapshot: returns PROCS, LINES, and full pane output in one SSH call
# This avoids race conditions between checking state and capturing output
snapshot() {
    run "
        TTY=\$(tmux display-message -p -t $SESSION '#{pane_tty}' | sed 's|/dev/||')
        PROCS=\$(ps --tty \$TTY --forest -o pid 2>/dev/null | wc -l)
        HIST=\$(tmux display-message -p -t $SESSION '#{history_size}')
        CURSOR=\$(tmux display-message -p -t $SESSION '#{cursor_y}')
        echo \"PROCS=\$PROCS\"
        echo \"LINES=\$((HIST + CURSOR))\"
        echo \"$DELIM\"
        tmux capture-pane -t $SESSION -p -S -\$HIST
    "
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

if [ "$OPT_CONTINUE" -eq 1 ]; then
    # Continue mode: pick up streaming from current position minus 5 lines for context
    CURRENT=$(count_lines)
    LINES_BEFORE=$((CURRENT > 5 ? CURRENT - 5 : 0))
    SKIP_LINES=0
else
    is_idle || { echo "[ERROR] Pane is busy" >&2; exit 1; }

    LINES_BEFORE=$(count_lines)

    printf '%s' "$CMD" | pipe_to "tmux load-buffer -b $BUFFER_NAME -"

    if [[ "$CMD" == *$'\n'* ]]; then
        # Multi-line: wrap in heredoc
        CMD_LINES=$(echo "$CMD" | wc -l)
        # During streaming: continuation lines in TOTAL_NEW
        # After idle: continuation lines still in TOTAL_NEW (they don't move to history like single-line command)
        SKIP_LINES=$((CMD_LINES + 1))  # continuation prompts + EOF
        run "tmux send-keys -t $SESSION 'bash << '\\''EOF'\\''' Enter"
        run "tmux paste-buffer -t $SESSION -b $BUFFER_NAME"
        run "tmux send-keys -t $SESSION Enter 'EOF' Enter"
    else
        # Single-line: SKIP varies based on timing
        # During streaming: command line is in TOTAL_NEW (SKIP=1)
        # After idle: command line scrolls to history, not in TOTAL_NEW (SKIP=0)
        SKIP_LINES_STREAMING=1
        SKIP_LINES_IDLE=0
        run "tmux paste-buffer -t $SESSION -b $BUFFER_NAME"
        run "tmux send-keys -t $SESSION Enter"
    fi

    sleep 0.3
fi

# Stream output while waiting for completion
ELAPSED=0
PRINTED_LINES=0
PRINTED_CHARS=0
TRUNCATED=0

while true; do
    # Atomic snapshot: get state + output in one call
    SNAP=$(snapshot)

    # Parse header
    PROCS=$(echo "$SNAP" | grep '^PROCS=' | cut -d= -f2)
    LINES_NOW=$(echo "$SNAP" | grep '^LINES=' | cut -d= -f2)

    # Extract output (everything after delimiter)
    OUTPUT=$(echo "$SNAP" | sed -n "/$DELIM/,\$p" | tail -n +2)

    # Calculate new output lines
    TOTAL_NEW=$((LINES_NOW - LINES_BEFORE))

    # Check if idle (procs=2 means just header + shell)
    IDLE=0
    [ "$PROCS" -eq 2 ] && IDLE=1

    # For single-line, SKIP varies based on idle state
    if [ -n "${SKIP_LINES_STREAMING:-}" ]; then
        SKIP=$([[ "$IDLE" -eq 0 ]] && echo "$SKIP_LINES_STREAMING" || echo "$SKIP_LINES_IDLE")
    else
        SKIP=$SKIP_LINES
    fi

    if [ "$TOTAL_NEW" -gt "$SKIP" ] && [ "$TRUNCATED" -eq 0 ]; then
        # New lines = total - skip_command_lines - prompt (only subtract prompt if idle)
        OUTPUT_LINES=$((TOTAL_NEW - SKIP - IDLE))

        # Print only lines we haven't printed yet
        if [ "$OUTPUT_LINES" -gt "$PRINTED_LINES" ]; then
            # Extract lines PRINTED_LINES+1 through OUTPUT_LINES
            # tail -n TOTAL_NEW: get new lines since LINES_BEFORE
            # tail -n +(SKIP+1): skip command/heredoc lines
            # head -n OUTPUT_LINES: exclude prompt if idle
            # tail -n +(PRINTED_LINES+1): skip already-printed lines
            NEW_OUTPUT=$(echo "$OUTPUT" | tail -n "$TOTAL_NEW" | tail -n "+$((SKIP + 1))" | head -n "$OUTPUT_LINES" | tail -n "+$((PRINTED_LINES + 1))")

            if [ "$TRUNCATE_HALF" -gt 0 ]; then
                # Truncation mode: limit chars
                REMAINING=$((TRUNCATE_HALF - PRINTED_CHARS))
                if [ "$REMAINING" -le 0 ]; then
                    # Already at limit, don't print
                    :
                elif [ "${#NEW_OUTPUT}" -le "$REMAINING" ]; then
                    # Fits within limit
                    printf '%s\n' "$NEW_OUTPUT"
                    PRINTED_CHARS=$((PRINTED_CHARS + ${#NEW_OUTPUT} + 1))
                else
                    # Would exceed limit - print partial and truncate
                    printf '%s' "$NEW_OUTPUT" | head -c "$REMAINING"
                    echo ""
                    echo "[...truncated...]"
                    TRUNCATED=1
                fi
            else
                # No truncation - print everything
                printf '%s\n' "$NEW_OUTPUT"
            fi
            PRINTED_LINES=$OUTPUT_LINES
        fi
    fi

    if [ "$IDLE" -eq 1 ]; then
        # Process exited - but output may still be flushing. One more capture after brief delay.
        sleep 0.1
        SNAP=$(snapshot)
        LINES_NOW=$(echo "$SNAP" | grep '^LINES=' | cut -d= -f2)
        OUTPUT=$(echo "$SNAP" | sed -n "/$DELIM/,\$p" | tail -n +2)
        TOTAL_NEW=$((LINES_NOW - LINES_BEFORE))
        # Use idle SKIP value
        if [ -n "${SKIP_LINES_IDLE:-}" ]; then
            SKIP=$SKIP_LINES_IDLE
        else
            SKIP=$SKIP_LINES
        fi
        OUTPUT_LINES=$((TOTAL_NEW - SKIP - 1))

        if [ "$TRUNCATE_HALF" -gt 0 ]; then
            # Truncation mode: print last N/2 chars
            FULL_OUTPUT=$(echo "$OUTPUT" | tail -n "$TOTAL_NEW" | tail -n "+$((SKIP + 1))" | head -n "$OUTPUT_LINES")
            if [ "$TRUNCATED" -eq 1 ]; then
                # We truncated earlier, print tail
                printf '%s' "$FULL_OUTPUT" | tail -c "$TRUNCATE_HALF"
                echo ""
            elif [ "${#FULL_OUTPUT}" -gt "$TRUNCATE_TOTAL" ]; then
                # Output grew past limit since last check
                echo "[...truncated...]"
                printf '%s' "$FULL_OUTPUT" | tail -c "$TRUNCATE_HALF"
                echo ""
            else
                # Didn't hit the limit, print any remaining
                if [ "$OUTPUT_LINES" -gt "$PRINTED_LINES" ]; then
                    echo "$OUTPUT" | tail -n "$TOTAL_NEW" | tail -n "+$((SKIP + 1))" | head -n "$OUTPUT_LINES" | tail -n "+$((PRINTED_LINES + 1))"
                fi
            fi
        else
            # No truncation
            if [ "$OUTPUT_LINES" -gt "$PRINTED_LINES" ]; then
                echo "$OUTPUT" | tail -n "$TOTAL_NEW" | tail -n "+$((SKIP + 1))" | head -n "$OUTPUT_LINES" | tail -n "+$((PRINTED_LINES + 1))"
            fi
        fi
        break
    fi

    sleep 0.5
    ELAPSED=$((ELAPSED + 1))
    [ "$ELAPSED" -gt "$((TIMEOUT * 2))" ] && { echo "[TIMEOUT]" >&2; exit 1; }
done
