---
name: claude-tmux
description: Execute commands in persistent tmux sessions, local or remote. Use when running long-running commands, builds, installs, servers, or any task that needs persistent shell state, user visibility, or parallel execution. Prefer this over the built-in Bash tool for anything that isn't a quick one-off.
allowed-tools: Bash(.claude/skills/claude-tmux/tmux-exec.sh:*)
---

# Tmux Operation

### First-time setup

On first use, ask the user which host(s) to target (e.g. `user@host`) or whether sessions are local. Save this to your memory so future sessions have it.

Use auto-generated session names: `claude-session-0`, `claude-session-1`, etc. Check `tmux list-sessions` before creating new ones -- reuse existing sessions when possible.

### CRITICAL: Never kill or interrupt busy panes

**NEVER send C-c, C-d, kill-session, or any destructive keys to a pane that is busy with another process.** If a pane reports "busy", **peek first** (`--peek-chars`) to see what's running. If it's someone else's process (a build, sync, download, server, etc.), **leave it alone and use a different session.** You could destroy hours of work by blindly canceling a running process.

---

You have access to tmux sessions for persistent command execution -- local or remote. Prefer this over the built-in Bash tool when you need:

- **Persistent state** -- working directory, env vars, and processes carry over between commands
- **Long-running commands** -- builds, installs, servers. Use `--continue` to check back on timeouts
- **User visibility** -- the user can watch the tmux pane in real time
- **Parallel sessions** -- separate sessions for concurrent tasks
- **Remote execution** -- same interface over SSH

Use the built-in Bash tool for quick, stateless one-off commands.

### Running commands

```bash
# Basic (30s default timeout):
.claude/skills/claude-tmux/tmux-exec.sh --session SESSION << 'EOF'
command here
EOF

# Remote with explicit timeout:
.claude/skills/claude-tmux/tmux-exec.sh --host USER@HOST --session SESSION --timeout 60 << 'EOF'
command here
EOF
```

Always pass commands via heredoc (avoids escaping issues with special characters like !, ", $, etc.).

### Flags

| Flag | Description |
|------|-------------|
| `--session NAME` | Session name (or set `TMUX_REMOTE_SESSION`) |
| `--host USER@HOST` | SSH target (or set `TMUX_REMOTE_HOST`, omit for local) |
| `--timeout SECS` | Timeout in seconds (default: 30) |
| `--truncate-chars N` | Truncate output to N chars (default: 2000) |
| `--dangerously-skip-truncation` | Disable truncation entirely |
| `--raw` | Paste stdin into pane via buffer (for TUIs). Fire-and-forget |
| `--keys KEY...` | Send tmux key names (Enter, C-c, Up, etc.). Returns pane contents after sending |
| `--continue` | Continue watching a timed-out command |
| `--peek-chars [N]` | Peek at last N chars on screen (default: 2000, no command needed) |

### Raw and key modes (for TUI targets)

Use `--raw` to paste text and `--keys` to send keystrokes. These are separate mechanisms -- text goes via tmux buffer (literal, no escaping), keys go via send-keys (interpreted as key names).

```bash
# Paste text into a TUI pane:
.claude/skills/claude-tmux/tmux-exec.sh --session SESSION --raw << 'EOF'
hello world
EOF

# Then submit with Enter:
.claude/skills/claude-tmux/tmux-exec.sh --session SESSION --keys Enter

# Send Ctrl-C:
.claude/skills/claude-tmux/tmux-exec.sh --session SESSION --keys C-c

# Multiple keys:
.claude/skills/claude-tmux/tmux-exec.sh --session SESSION --keys Up Up Enter
```

### Timeout and continue

Always specify a timeout. Default is 30s -- intentionally short. If a command times out, resume with:

```bash
.claude/skills/claude-tmux/tmux-exec.sh --session SESSION --continue --timeout 120
```

### Session management

Do most work in a single primary session. If you need parallelism, spawn extras:

```bash
# Local
tmux new -d -s claude-session-0
# Remote
ssh user@host "tmux new -d -s claude-session-0"
```

Check existing sessions before creating new ones: `tmux list-sessions` (or `ssh user@host "tmux list-sessions"`).

### Manual fallback

```bash
# Send raw keystrokes (e.g. cancel a command)
ssh user@host "tmux send-keys -t session C-c"
# Read pane output directly
ssh user@host "tmux capture-pane -t session -p" | tail -20
```
