# claude-tmux

A reusable skill that lets Claude Code execute commands in persistent tmux sessions, local or remote. Commands are dispatched via heredoc, output streams back in real time, and the script waits for completion before returning.

## Why

Claude Code's Bash tool runs each command in an isolated shell. That's fine for quick things, but falls short when you need:

- **Persistent sessions** -- environment, working directory, and processes carry over between commands
- **Long-running commands** -- fire off a build or install, check on it later with `-c`
- **User visibility** -- the user can watch the tmux pane in real time
- **Parallel sessions** -- build in one, test in another, server in a third
- **Surviving disconnects** -- commands keep running if the Claude session ends
- **Remote execution** -- same interface whether local or over SSH

## Setup

### 1. Create a tmux session

```bash
# Local
tmux new -s my-session

# Remote (SSH key auth required)
ssh user@host "tmux new -d -s my-session"
```

### 2. Add to your project

Copy or symlink `tmux-exec.sh` into your project, then paste `CLAUDE_TEMPLATE.md` into your project's `.claude/CLAUDE.md`. Replace the placeholder values (`SESSION`, `USER@HOST`) with your actual settings.

## Usage

Commands are passed via stdin (heredoc) to avoid shell escaping issues. The last positional argument is the timeout in seconds.

```bash
# Basic: run a command, wait up to 60s
./tmux-exec.sh -s my-session 60 << 'EOF'
make build
EOF

# Remote session
./tmux-exec.sh -h user@host -s my-session 60 << 'EOF'
docker compose up -d
EOF

# Multi-line commands work naturally
./tmux-exec.sh -s my-session 60 << 'EOF'
for i in 1 2 3; do
  echo "iteration $i"
done
EOF
```

### Flags

| Flag | Description |
|------|-------------|
| `-s NAME` | Tmux session name (or set `TMUX_REMOTE_SESSION`) |
| `-h USER@HOST` | SSH target for remote sessions (or set `TMUX_REMOTE_HOST`, omit for local) |
| `-t N` | Truncate output to N chars (default: 2000). Shows head + `[...truncated...]` + tail |
| `-T` | Disable truncation entirely |
| `-c` | Continue mode -- resume watching a command that timed out |
| `-p [N]` | Peek mode -- show last N chars on screen (default: 2000), no command needed |

### Continue mode

If a command times out, use `-c` to pick up where you left off:

```bash
# Command times out after 30s
./tmux-exec.sh -s my-session 30 << 'EOF'
make -j8
EOF

# Resume watching (another 120s)
./tmux-exec.sh -s my-session -c 120
```

### Peek mode

Check what's on screen without running a command:

```bash
./tmux-exec.sh -s my-session -p 500
```

### Heredoc input

Commands are passed via heredoc rather than as arguments. This avoids escaping issues -- characters like `!`, `"`, and `$` pass through cleanly:

```bash
./tmux-exec.sh -s my-session 30 << 'EOF'
if ! grep -q "pattern" file.txt; then
  echo "not found!"
fi
EOF
```

## How it works

1. Reads command from stdin
2. Checks the pane is idle, loads command into a tmux buffer, pastes it, and appends a `#__TMUX_MARKER__` comment -- all in one SSH call
   - **Single-line:** command + marker comment, then Enter
   - **Multi-line:** wraps in `bash << 'TMUX_EOF' #__TMUX_MARKER__`
3. Polls `capture-pane` on the remote side, finds the last marker, extracts only the command output, returns it with idle status -- minimal data transfer
4. Detects completion via `pgrep --parent $PANE_PID` (ignores orphaned processes on reused TTYs)
5. Final trailing capture to catch output that flushed after the last poll

The marker-based approach survives tmux scrollback eviction and always finds the correct output even with long history.

## TODO

- **Send keys mode** -- wrap `tmux send-keys` for raw keystrokes (Ctrl-C, arrow keys, etc.) without running a command
- **Stress test same-session parallelism** -- Claude's Bash tool is serial in practice, but Claude may still try to launch multiple background commands targeting the same session. The idle check + dispatch sequence isn't atomic, so two near-simultaneous calls could both pass the "is busy" check and clobber each other. Need to test this and decide whether to add locking or just document it as a footgun

## Requirements

- tmux on the target machine
- bash on both machines
- SSH key auth (for remote sessions)
