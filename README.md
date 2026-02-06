# claude-tmux

A skill for Claude Code to run commands in tmux sessions -- local or remote.

## Why

Claude Code's built-in Bash tool runs commands in isolated shell invocations. That's fine for quick things, but sometimes you need:

- **Persistent sessions** -- working directory, environment variables, and running processes carry over between commands
- **Non-blocking execution** -- fire off a long build or install and check on it later
- **User visibility** -- the user can watch the tmux pane in real time and see exactly what Claude is doing
- **Multiple parallel sessions** -- spawn separate sessions for different tasks (build in one, test in another, server in a third)
- **Surviving disconnects** -- commands keep running even if the Claude session ends
- **Local or remote** -- same workflow whether the session is on this machine or on a server over SSH

## Setup

### 1. Create a tmux session

Local:
```bash
tmux new -s my-session
```

Remote (make sure SSH key auth works):
```bash
ssh user@host "tmux new -d -s my-session"
```

### 2. Add the skill to your project

Copy or symlink `tmux-wait.sh` into your project, then paste the contents of `CLAUDE_TEMPLATE.md` into your project's `.claude/CLAUDE.md`, replacing the placeholder values (`SESSION`, `USER@HOST`) with your actual session name and host.

## tmux-wait.sh

The script sends a command to a tmux session, polls until it finishes, and returns clean output.

**Commands are passed via stdin (heredoc)** to avoid shell escaping issues:

```bash
# Local session (120s timeout)
./tmux-wait.sh -s my-session 120 << 'EOF'
make build
EOF

# Remote session (60s timeout)
./tmux-wait.sh -h user@host -s my-session 60 << 'EOF'
docker compose up -d
EOF

# Disable truncation (output is truncated to 2000 chars by default)
./tmux-wait.sh -s my-session -T 300 << 'EOF'
make build
EOF

# Custom truncation limit (5000 chars, 600s timeout)
./tmux-wait.sh -s my-session -t 5000 600 << 'EOF'
npm install
EOF

# Continue watching a timed-out command (picks up where you left off)
./tmux-wait.sh -s my-session -c 120

# Peek at the last 500 chars on screen (no command, no marker needed)
./tmux-wait.sh -s my-session -p 500

# Multi-line commands (60s timeout)
./tmux-wait.sh -s my-session 60 << 'EOF'
for i in 1 2 3; do
  echo "iteration $i"
done
EOF

# Environment variables (30s timeout)
export TMUX_REMOTE_HOST=user@host    # omit for local sessions
export TMUX_REMOTE_SESSION=my-session
./tmux-wait.sh 30 << 'EOF'
echo "hello from remote"
EOF
```

**Always specify a timeout.** Default is 30s -- intentionally short to encourage explicit timeouts. Commands that hang will block Claude indefinitely. Use `-c` to resume watching if a command times out.

### Why heredoc?

Passing commands as arguments (`'command'`) causes escaping issues -- characters like `!` get mangled through the shell layers. Heredoc input passes through cleanly, giving full shell compatibility including `if ! cmd`, `echo "hello!"`, etc.

### How it works

1. Reads command from stdin (heredoc)
2. Checks the pane is idle, loads command into a named tmux buffer, pastes it, and appends a `#__TMUX_MARKER__` comment -- all in a single SSH call to minimize latency
   - **Single-line:** pastes command + marker comment, presses Enter
   - **Multi-line:** wraps in `bash << 'EOF' #__TMUX_MARKER__` heredoc
3. Polls `capture-pane` on the remote side, finds the last marker, extracts only the command output (with `skip_top` applied), and returns it along with idle status -- keeping data transfer minimal
4. Detects completion by checking if the shell (`pane_pid`) has any child processes via `pgrep --parent`. This ignores orphaned processes on reused TTYs.
5. Does a final trailing capture to catch any output that flushed after the last poll

The marker-based approach survives tmux scrollback eviction (unlike line counting) and always finds the correct command output even with a long scrollback history.

## TODO

- **Send keys mode** -- wrap `tmux send-keys` so you can send raw keystrokes (Ctrl-C, arrow keys, etc.) without running a command. tmux already supports this, but having it in the script keeps all tmux interaction in one place.
- **Rename the script** -- `tmux-wait` undersells it now that it does dispatch, streaming, peek, continue, truncation, and remote-side extraction. Needs a better name.

## Requirements

- tmux on the target machine
- bash on both machines
- SSH key auth (for remote sessions)

