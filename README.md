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

# Truncate output for long builds (-t defaults to 3000 chars, 300s timeout)
./tmux-wait.sh -s my-session -t 300 << 'EOF'
make build
EOF

# Custom truncation limit (5000 chars, 600s timeout)
./tmux-wait.sh -s my-session -t 5000 600 << 'EOF'
npm install
EOF

# Continue watching an already-running command (120s timeout)
./tmux-wait.sh -s my-session -c 120

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

**Always specify a timeout.** Default is 30s -- intentionally short to encourage explicit timeouts. Commands that hang will block Claude indefinitely. Exit 0 on completion, exit 1 on timeout. Use `-c` to resume watching if a command times out.

### Why heredoc?

Passing commands as arguments (`'command'`) causes escaping issues -- characters like `!` get mangled through the shell layers. Heredoc input passes through cleanly, giving full shell compatibility including `if ! cmd`, `echo "hello!"`, etc.

### How it works

1. Reads command from stdin (heredoc)
2. Counts scrollback lines before execution
3. Loads command into a named tmux buffer (one per session, no conflicts)
4. Executes:
   - **Single-line:** pastes command and presses Enter
   - **Multi-line:** wraps in `bash << 'EOF'` heredoc so commands run as a batch
5. Polls `pane_current_command` until the shell returns to idle (bash/zsh/etc)
6. Counts scrollback lines after execution
7. Captures only the new lines (minus the prompt)

No markers in scrollback, no escaping issues. Clean output capture via line counting.

## Requirements

- tmux on the target machine
- bash on both machines
- SSH key auth (for remote sessions)

## TODO

- **Test edge cases** -- What happens with commands long enough to wrap the tmux terminal? Does line counting break? Also test if a single 10000-char output line is captured correctly with tail.

