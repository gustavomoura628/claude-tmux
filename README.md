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
# Local session
./tmux-wait.sh -s my-session << 'EOF'
make build
EOF

# Remote session
./tmux-wait.sh -h user@host -s my-session << 'EOF'
docker compose up -d
EOF

# With timeout (default 120s)
./tmux-wait.sh -h user@host -s my-session 60 << 'EOF'
npm test
EOF

# Multi-line commands work naturally
./tmux-wait.sh -s my-session << 'EOF'
for i in 1 2 3; do
  echo "iteration $i"
done
EOF

# Environment variables work too
export TMUX_REMOTE_HOST=user@host    # omit for local sessions
export TMUX_REMOTE_SESSION=my-session
./tmux-wait.sh << 'EOF'
echo "hello from remote"
EOF
```

Exit 0 on completion, exit 1 on timeout.

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

- **Quiet mode for chatty commands** -- Streaming output is great for visibility, but long builds (ESPHome, npm, etc.) can dump thousands of lines into Claude's context window. Add a `-q` flag to suppress streaming and only return final output, or `-t N` to only stream the last N lines. Alternatively, auto-throttle: if more than ~20 lines have been streamed, stop streaming and only print the last ~10 lines when the command finishes.

- **Test edge cases** -- What happens with commands long enough to wrap the tmux terminal? Does line counting break? Also test if a single 10000-char output line is captured correctly with tail.
