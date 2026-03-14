# claude-tmux

A reusable skill that lets Claude Code execute commands in persistent tmux sessions, local or remote. Commands are dispatched via heredoc, output streams back in real time, and the script waits for completion before returning.

## Why

Claude Code's Bash tool runs each command in an isolated shell. That's fine for quick things, but falls short when you need:

- **Persistent sessions** -- environment, working directory, and processes carry over between commands
- **Long-running commands** -- fire off a build or install, check on it later with `--continue`
- **User visibility** -- the user can watch the tmux pane in real time
- **Parallel sessions** -- build in one, test in another, server in a third
- **Surviving disconnects** -- commands keep running if the Claude session ends
- **Remote execution** -- same interface whether local or over SSH

## Install

```bash
# From your project root:
mkdir -p .claude/skills
ln -s /absolute/path/to/claude-tmux .claude/skills/claude-tmux
```

Claude Code auto-discovers skills by scanning `.claude/skills/*/SKILL.md` on startup. **Restart Claude Code after installing** for the skill to take effect. The skill will appear in the available skills list and activate automatically when the task matches, or manually via `/claude-tmux`.

On first use, Claude will ask which host(s) to target and save them to memory. No manual CLAUDE.md configuration needed.

### Create a tmux session

```bash
# Local
tmux new -s my-session

# Remote (SSH key auth required)
ssh user@host "tmux new -d -s my-session"
```

## Usage

Commands are passed via stdin (heredoc) to avoid shell escaping issues.

```bash
# Basic: run a command, wait up to 60s
./tmux-exec.sh --session my-session --timeout 60 << 'EOF'
make build
EOF

# Remote session
./tmux-exec.sh --host user@host --session my-session --timeout 60 << 'EOF'
docker compose up -d
EOF

# Multi-line commands work naturally
./tmux-exec.sh --session my-session --timeout 60 << 'EOF'
for i in 1 2 3; do
  echo "iteration $i"
done
EOF
```

### Flags

| Flag | Description |
|------|-------------|
| `--session NAME` | Tmux session name (or set `TMUX_REMOTE_SESSION`) |
| `--host USER@HOST` | SSH target for remote sessions (or set `TMUX_REMOTE_HOST`, omit for local) |
| `--timeout SECS` | Timeout in seconds (default: 30) |
| `--truncate-chars N` | Truncate output to N chars (default: 2000). Shows head + `[...truncated...]` + tail |
| `--dangerously-skip-truncation` | Disable truncation entirely |
| `--raw` | Raw paste mode -- stdin goes directly into the pane via tmux buffer. No marker, no polling. For TUI targets |
| `--keys KEY...` | Send tmux key names (Enter, C-c, Up, etc.) via send-keys. Returns pane contents after sending |
| `--continue` | Continue mode -- resume watching a command that timed out |
| `--peek-chars [N]` | Peek mode -- show last N chars on screen (default: 2000), no command needed |

### Continue mode

If a command times out, use `--continue` to pick up where you left off:

```bash
# Command times out after 30s
./tmux-exec.sh --session my-session --timeout 30 << 'EOF'
make -j8
EOF

# Resume watching (another 120s)
./tmux-exec.sh --session my-session --continue --timeout 120
```

### Raw and key modes

For TUI targets (e.g. another Claude Code instance), text and keystrokes are separate operations:

- `--raw` pastes text via tmux buffer (literal, no escaping issues)
- `--keys` sends tmux key names via send-keys (Enter, C-c, Up, etc.)

```bash
# Paste text into a TUI pane:
./tmux-exec.sh --session my-session --raw << 'EOF'
hello world
EOF

# Submit with Enter:
./tmux-exec.sh --session my-session --keys Enter

# Send Ctrl-C:
./tmux-exec.sh --session my-session --keys C-c

# Multiple keys in one call:
./tmux-exec.sh --session my-session --keys Up Up Enter
```

### Peek mode

Check what's on screen without running a command:

```bash
./tmux-exec.sh --session my-session --peek-chars 500
```

### Heredoc input

Commands are passed via heredoc rather than as arguments. This avoids escaping issues -- characters like `!`, `"`, and `$` pass through cleanly:

```bash
./tmux-exec.sh --session my-session --timeout 30 << 'EOF'
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

The marker-based approach survives normal tmux scrollback eviction and always finds the correct output even with long history — with one exception (see bugs).

## Requirements

- tmux on the target machine
- bash on both machines
- SSH key auth (for remote sessions)
