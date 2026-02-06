#!/usr/bin/env bash
# tmux-wait.sh -- Send a command to a tmux session, wait for it to finish.
# Output streams as it appears, with final capture when command completes.

set -eu

OPT_HOST=""
OPT_SESSION=""
OPT_TRUNCATE="2000"
OPT_CONTINUE=0
# Handle -t, -T, and -c with optional arguments (getopts can't do this natively)
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
        *) args+=("$1"); shift ;;
    esac
done
set -- "${args[@]}"

while getopts "h:s:" opt; do
    case $opt in
        h) OPT_HOST="$OPTARG" ;;
        s) OPT_SESSION="$OPTARG" ;;
        *) echo "Usage: $0 [-h host] [-s session] [-t [chars]] [-T] [-c] [timeout]" >&2; exit 1 ;;
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

# Truncation: default 2000 chars (1000 head + 1000 tail). -t N for custom, -T to disable.
TRUNCATE_TOTAL="${OPT_TRUNCATE}"
TRUNCATE_HALF=$((TRUNCATE_TOTAL / 2))

run() {
    if [ -n "$HOST" ]; then ssh "$HOST" "$1"; else bash -c "$1"; fi
}

pipe_to() {
    if [ -n "$HOST" ]; then ssh "$HOST" "$1"; else bash -c "$1"; fi
}

SNAP_DELIM="__SNAPSHOT_${$}_$$__"

# Marker appended as a comment to the command line. Greppable in capture-pane
# output but invisible to execution. Survives tmux scrollback eviction.
MARKER="__TMUX_MARKER_${RANDOM}${RANDOM}__"

# Atomic snapshot: returns PROCS and full pane output in one SSH call
snapshot() {
    run "
        TTY=\$(tmux display-message -p -t $SESSION '#{pane_tty}' | sed 's|/dev/||')
        PROCS=\$(ps --tty \$TTY --forest -o pid 2>/dev/null | wc -l)
        HIST=\$(tmux display-message -p -t $SESSION '#{history_size}')
        CAPTURE=\$(tmux capture-pane -t $SESSION -p -J -S -\$HIST)
        echo \"PROCS=\$PROCS\"
        echo \"$SNAP_DELIM\"
        echo \"\$CAPTURE\"
    "
}

is_idle() {
    local procs
    procs=$(run "ps --tty \$(tmux display-message -p -t $SESSION '#{pane_tty}' | sed 's|/dev/||') --forest -o pid 2>/dev/null | wc -l")
    [ "$procs" -eq 2 ]
}

# Extract command output from a snapshot.
# Finds the marker comment in the command line, takes everything after it,
# skips heredoc body (skip_top) and prompt line if idle (skip_bottom).
extract_output() {
    local output="$1" skip_top="$2" skip_bottom="$3"
    local after_marker
    after_marker=$(echo "$output" | sed -n "/$MARKER/,\$p" | tail -n +2)
    if [ -z "$after_marker" ]; then
        return
    fi
    local total
    total=$(echo "$after_marker" | wc -l)
    local content_lines=$((total - skip_top - skip_bottom))
    if [ "$content_lines" -le 0 ]; then
        return
    fi
    echo "$after_marker" | tail -n "+$((skip_top + 1))" | head -n "$content_lines"
}

BUFFER_NAME="claude-${SESSION}"

if [ "$OPT_CONTINUE" -eq 1 ]; then
    # Continue mode: no marker, use line-count fallback
    MARKER=""
    CONTINUE_PRINTED=0
else
    is_idle || { echo "[ERROR] Pane is busy" >&2; exit 1; }

    printf '%s' "$CMD" | pipe_to "tmux load-buffer -b $BUFFER_NAME -"

    if [[ "$CMD" == *$'\n'* ]]; then
        # Multi-line: wrap in heredoc with marker comment
        CMD_LINES=$(echo "$CMD" | wc -l)
        SKIP_TOP=$((CMD_LINES + 1))  # continuation prompts + EOF line
        run "tmux send-keys -t $SESSION 'bash << '\\''EOF'\\'' #$MARKER' Enter"
        run "tmux paste-buffer -t $SESSION -b $BUFFER_NAME"
        run "tmux send-keys -t $SESSION Enter 'EOF' Enter"
    else
        # Single-line: paste command, append marker comment
        SKIP_TOP=0
        run "tmux paste-buffer -t $SESSION -b $BUFFER_NAME"
        run "tmux send-keys -t $SESSION ' #$MARKER' Enter"
    fi

    sleep 0.3
fi

# Stream output while waiting for completion
ELAPSED=0
PRINTED_LINES=0
PRINTED_CHARS=0
TRUNCATED=0

while true; do
    SNAP=$(snapshot)

    PROCS=$(echo "$SNAP" | grep -m1 '^PROCS=' | cut -d= -f2)
    OUTPUT=$(echo "$SNAP" | sed -n "/$SNAP_DELIM/,\$p" | tail -n +2)

    IDLE=0
    [ "$PROCS" -eq 2 ] && IDLE=1

    if [ "$OPT_CONTINUE" -eq 1 ]; then
        # Continue mode: no marker, just stream everything new
        TOTAL=$(echo "$OUTPUT" | wc -l)
        if [ "$CONTINUE_PRINTED" -eq 0 ]; then
            CONTEXT=$(echo "$OUTPUT" | tail -5)
            if [ -n "$CONTEXT" ]; then
                printf '%s\n' "$CONTEXT"
            fi
            CONTINUE_PRINTED=$TOTAL
        elif [ "$TOTAL" -gt "$CONTINUE_PRINTED" ]; then
            NEW_COUNT=$((TOTAL - CONTINUE_PRINTED))
            NEW_OUTPUT=$(echo "$OUTPUT" | tail -n "$NEW_COUNT")
            if [ -n "$NEW_OUTPUT" ] && [ "$TRUNCATED" -eq 0 ]; then
                if [ "$TRUNCATE_HALF" -gt 0 ]; then
                    REMAINING=$((TRUNCATE_HALF - PRINTED_CHARS))
                    if [ "$REMAINING" -gt 0 ]; then
                        if [ "${#NEW_OUTPUT}" -le "$REMAINING" ]; then
                            printf '%s\n' "$NEW_OUTPUT"
                            PRINTED_CHARS=$((PRINTED_CHARS + ${#NEW_OUTPUT} + 1))
                        else
                            echo "${NEW_OUTPUT:0:$REMAINING}"
                            echo "[...truncated...]"
                            TRUNCATED=1
                        fi
                    fi
                else
                    printf '%s\n' "$NEW_OUTPUT"
                fi
            fi
            CONTINUE_PRINTED=$TOTAL
        fi

        if [ "$IDLE" -eq 1 ]; then
            if [ "$TRUNCATE_HALF" -gt 0 ] && [ "$TRUNCATED" -eq 1 ]; then
                echo "${OUTPUT: -$TRUNCATE_HALF}"
            fi
            break
        fi
    else
        # Normal mode: extract output after marker
        CMD_OUTPUT=$(extract_output "$OUTPUT" "$SKIP_TOP" "$IDLE")

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
            OUTPUT=$(echo "$SNAP" | sed -n "/$SNAP_DELIM/,\$p" | tail -n +2)
            CMD_OUTPUT=$(extract_output "$OUTPUT" "$SKIP_TOP" 1)

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
    fi

    sleep 0.5
    ELAPSED=$((ELAPSED + 1))
    if [ "$ELAPSED" -gt "$((TIMEOUT * 2))" ]; then
        # On timeout with truncation, print the tail end of what we have so far
        if [ "$TRUNCATE_HALF" -gt 0 ] && [ "$TRUNCATED" -eq 1 ]; then
            SNAP=$(snapshot)
            OUTPUT=$(echo "$SNAP" | sed -n "/$SNAP_DELIM/,\$p" | tail -n +2)
            if [ "$OPT_CONTINUE" -eq 1 ]; then
                FULL_OUTPUT="$OUTPUT"
            else
                FULL_OUTPUT=$(extract_output "$OUTPUT" "$SKIP_TOP" 0)
            fi
            if [ -n "$FULL_OUTPUT" ]; then
                echo "${FULL_OUTPUT: -$TRUNCATE_HALF}"
            fi
        fi
        echo "[TIMEOUT after ${TIMEOUT}s]"
        exit 0
    fi
done
