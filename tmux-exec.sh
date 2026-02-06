#!/usr/bin/env bash
# tmux-exec.sh -- Send a command to a tmux session, wait for it to finish.
# Output streams as it appears, with final capture when command completes.

set -eu

OPT_HOST=""
OPT_SESSION=""
OPT_TRUNCATE="2000"
OPT_CONTINUE=0
OPT_PEEK=""
# Handle -t, -T, -c, -p with optional arguments (getopts can't do this natively)
args=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -t)
            if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                OPT_TRUNCATE="$2"
                shift 2
            else
                OPT_TRUNCATE="2000"
                shift
            fi
            ;;
        -T)
            OPT_TRUNCATE="0"
            shift
            ;;
        -c)
            OPT_CONTINUE=1
            shift
            ;;
        -p)
            if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                OPT_PEEK="$2"
                shift 2
            else
                OPT_PEEK="2000"
                shift
            fi
            ;;
        *) args+=("$1"); shift ;;
    esac
done
set -- "${args[@]}"

while getopts "h:s:" opt; do
    case $opt in
        h) OPT_HOST="$OPTARG" ;;
        s) OPT_SESSION="$OPTARG" ;;
        *) echo "Usage: $0 [-h host] [-s session] [-t [chars]] [-T] [-c] [-p [chars]] [timeout]" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

HOST="${OPT_HOST:-${TMUX_REMOTE_HOST:-}}"
SESSION="${OPT_SESSION:-${TMUX_REMOTE_SESSION:?'Set -s SESSION or TMUX_REMOTE_SESSION'}}"
TIMEOUT="${1:-30}"

if [ -n "$OPT_PEEK" ]; then
    CMD=""
elif [ "$OPT_CONTINUE" -eq 1 ]; then
    CMD=""
else
    CMD=$(cat)
    [ -z "$CMD" ] && { echo "Error: no command provided via stdin" >&2; exit 1; }
fi

# Truncation: default 2000 chars (1000 head + 1000 tail). -t N for custom, -T to disable.
TRUNCATE_TOTAL="${OPT_TRUNCATE}"
TRUNCATE_HALF=$((TRUNCATE_TOTAL / 2))

run() {
    if [ -n "$HOST" ]; then ssh "$HOST" "$1"; else bash -c "$1"; fi
}

pipe_to() {
    if [ -n "$HOST" ]; then ssh "$HOST" "$1"; else bash -c "$1"; fi
}

# Peek mode: grab last N chars from the pane and exit. No command, no marker.
if [ -n "$OPT_PEEK" ]; then
    CAPTURE=$(run "tmux capture-pane -t $SESSION -p -J -S -")
    if [ -z "$CAPTURE" ]; then
        exit 0
    fi
    echo "${CAPTURE: -$OPT_PEEK}"
    exit 0
fi

SNAP_DELIM="__SNAPSHOT_${$}_$$__"

# Marker appended as a comment to the command line. Greppable in capture-pane
# output but invisible to execution. Survives tmux scrollback eviction.
MARKER="__TMUX_MARKER__"

# Atomic snapshot: captures pane, extracts output after marker (skip_top applied),
# and returns IDLE status. All filtering runs on the remote side to minimize transfer.
# Returns: IDLE=0/1, then delimiter, then extracted command output.
snapshot() {
    run "
        PANE_PID=\$(tmux display-message -p -t $SESSION '#{pane_pid}')
        IDLE=0
        pgrep --parent \$PANE_PID >/dev/null 2>&1 || IDLE=1
        CAPTURE=\$(tmux capture-pane -t $SESSION -p -J -S -)
        MARKER_LINE=\$(echo \"\$CAPTURE\" | grep -n '$MARKER' | tail -1 | cut -d: -f1)
        echo \"IDLE=\$IDLE\"
        echo \"$SNAP_DELIM\"
        if [ -n \"\$MARKER_LINE\" ]; then
            echo \"\$CAPTURE\" | tail -n +\$((MARKER_LINE + 1 + $SKIP_TOP))
        fi
    "
}

BUFFER_NAME="claude-${SESSION}"

if [ "$OPT_CONTINUE" -eq 1 ]; then
    # Continue mode: reuse the marker from the original command.
    # Do an initial snapshot to figure out current output size, then
    # set PRINTED_LINES to start from 5 lines back for context.
    SKIP_TOP=0
    INIT_SNAP=$(snapshot)
    INIT_CMD_OUTPUT=$(echo "$INIT_SNAP" | sed -n "/$SNAP_DELIM/,\$p" | tail -n +2)
    if [ -n "$INIT_CMD_OUTPUT" ]; then
        INIT_LINES=$(echo "$INIT_CMD_OUTPUT" | wc -l)
        CONTINUE_START=$((INIT_LINES > 5 ? INIT_LINES - 5 : 0))
    else
        CONTINUE_START=0
    fi
else
    if [[ "$CMD" == *$'\n'* ]]; then
        # Multi-line: idle check + load buffer + heredoc with marker, one SSH call
        CMD_LINES=$(echo "$CMD" | wc -l)
        SKIP_TOP=$((CMD_LINES + 1))  # continuation prompts + TMUX_EOF line
        printf '%s' "$CMD" | pipe_to "
            PANE_PID=\$(tmux display-message -p -t $SESSION '#{pane_pid}')
            pgrep --parent \$PANE_PID >/dev/null 2>&1 && exit 1
            tmux load-buffer -b $BUFFER_NAME -
            tmux send-keys -t $SESSION 'bash << '\\''TMUX_EOF'\\'' #$MARKER' Enter
            tmux paste-buffer -t $SESSION -b $BUFFER_NAME
            tmux send-keys -t $SESSION Enter 'TMUX_EOF' Enter
        " || { echo "[ERROR] Pane is busy" >&2; exit 1; }
    else
        # Single-line: idle check + load buffer + paste + marker, one SSH call
        SKIP_TOP=0
        printf '%s' "$CMD" | pipe_to "
            PANE_PID=\$(tmux display-message -p -t $SESSION '#{pane_pid}')
            pgrep --parent \$PANE_PID >/dev/null 2>&1 && exit 1
            tmux load-buffer -b $BUFFER_NAME -
            tmux paste-buffer -t $SESSION -b $BUFFER_NAME
            tmux send-keys -t $SESSION ' #$MARKER' Enter
        " || { echo "[ERROR] Pane is busy" >&2; exit 1; }
    fi

    sleep 0.3
fi

# Stream output while waiting for completion
ELAPSED=0
PRINTED_LINES=${CONTINUE_START:-0}
PRINTED_CHARS=0
TRUNCATED=0

while true; do
    SNAP=$(snapshot)

    IDLE=$(echo "$SNAP" | grep -m1 '^IDLE=' | cut -d= -f2)
    # Output after marker (skip_top already applied on remote side)
    CMD_OUTPUT=$(echo "$SNAP" | sed -n "/$SNAP_DELIM/,\$p" | tail -n +2)
    # Remove prompt line if idle
    if [ "$IDLE" -eq 1 ] && [ -n "$CMD_OUTPUT" ]; then
        CMD_OUTPUT=$(echo "$CMD_OUTPUT" | sed '$d')
    fi

    if [ -n "$CMD_OUTPUT" ] && [ "$TRUNCATED" -eq 0 ]; then
        OUTPUT_LINES=$(echo "$CMD_OUTPUT" | wc -l)

        if [ "$OUTPUT_LINES" -gt "$PRINTED_LINES" ]; then
            NEW_OUTPUT=$(echo "$CMD_OUTPUT" | tail -n "+$((PRINTED_LINES + 1))")

            if [ "$TRUNCATE_HALF" -gt 0 ]; then
                REMAINING=$((TRUNCATE_HALF - PRINTED_CHARS))
                if [ "$REMAINING" -le 0 ]; then
                    :
                elif [ "${#NEW_OUTPUT}" -le "$REMAINING" ]; then
                    printf '%s\n' "$NEW_OUTPUT"
                    PRINTED_CHARS=$((PRINTED_CHARS + ${#NEW_OUTPUT} + 1))
                else
                    echo "${NEW_OUTPUT:0:$REMAINING}"
                    echo "[...truncated...]"
                    TRUNCATED=1
                fi
            else
                printf '%s\n' "$NEW_OUTPUT"
            fi
            PRINTED_LINES=$OUTPUT_LINES
        fi
    fi

    if [ "$IDLE" -eq 1 ]; then
        # Trailing capture: output may still be flushing
        sleep 0.1
        SNAP=$(snapshot)
        CMD_OUTPUT=$(echo "$SNAP" | sed -n "/$SNAP_DELIM/,\$p" | tail -n +2)
        # Remove prompt line (idle)
        if [ -n "$CMD_OUTPUT" ]; then
            CMD_OUTPUT=$(echo "$CMD_OUTPUT" | sed '$d')
        fi

        if [ "$TRUNCATE_HALF" -gt 0 ]; then
            if [ -n "$CMD_OUTPUT" ]; then
                if [ "$TRUNCATED" -eq 1 ]; then
                    echo "${CMD_OUTPUT: -$TRUNCATE_HALF}"
                elif [ "${#CMD_OUTPUT}" -gt "$TRUNCATE_TOTAL" ]; then
                    echo "[...truncated...]"
                    echo "${CMD_OUTPUT: -$TRUNCATE_HALF}"
                else
                    OUTPUT_LINES=$(echo "$CMD_OUTPUT" | wc -l)
                    if [ "$OUTPUT_LINES" -gt "$PRINTED_LINES" ]; then
                        echo "$CMD_OUTPUT" | tail -n "+$((PRINTED_LINES + 1))"
                    fi
                fi
            fi
        else
            if [ -n "$CMD_OUTPUT" ]; then
                OUTPUT_LINES=$(echo "$CMD_OUTPUT" | wc -l)
                if [ "$OUTPUT_LINES" -gt "$PRINTED_LINES" ]; then
                    echo "$CMD_OUTPUT" | tail -n "+$((PRINTED_LINES + 1))"
                fi
            fi
        fi
        break
    fi

    sleep 0.5
    ELAPSED=$((ELAPSED + 1))
    if [ "$ELAPSED" -gt "$((TIMEOUT * 2))" ]; then
        # On timeout with truncation, print the tail end of what we have so far
        if [ "$TRUNCATE_HALF" -gt 0 ] && [ "$TRUNCATED" -eq 1 ]; then
            SNAP=$(snapshot)
            FULL_OUTPUT=$(echo "$SNAP" | sed -n "/$SNAP_DELIM/,\$p" | tail -n +2)
            if [ -n "$FULL_OUTPUT" ]; then
                echo "${FULL_OUTPUT: -$TRUNCATE_HALF}"
            fi
        fi
        echo "[TIMEOUT after ${TIMEOUT}s]"
        exit 0
    fi
done
