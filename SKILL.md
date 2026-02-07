---
name: claude-tmux
description: Execute commands in persistent tmux sessions, local or remote. Use when running long-running commands, builds, installs, servers, or any task that needs persistent shell state, user visibility, or parallel execution. Prefer this over the built-in Bash tool for anything that isn't a quick one-off.
allowed-tools: Bash(tmux-exec.sh:*), Bash(./tmux-exec.sh:*), Bash(.claude/skills/claude-tmux/tmux-exec.sh:*)
---

# Tmux Operation

### First-time setup

On first use, ask the user which host(s) to target (e.g. `user@host`) or whether sessions are local. Save this to your memory so future sessions have it.

Use auto-generated session names: `claude-session-0`, `claude-session-1`, etc. Check `tmux list-sessions` before creating new ones -- reuse existing sessions when possible.

---

You have access to tmux sessions for persistent command execution -- local or remote. Prefer this over the built-in Bash tool when you need:

- **Persistent state** -- working directory, env vars, and processes carry over between commands
- **Long-running commands** -- builds, installs, servers. Use `-c` to check back on timeouts
- **User visibility** -- the user can watch the tmux pane in real time
- **Parallel sessions** -- separate sessions for concurrent tasks
- **Remote execution** -- same interface over SSH

Use the built-in Bash tool for quick, stateless one-off commands.

### Running commands

```bash
# Basic (30s default timeout):
./tmux-exec.sh -s SESSION << 'EOF'
command here
EOF

# Remote with explicit timeout:
./tmux-exec.sh -h USER@HOST -s SESSION 60 << 'EOF'
command here
EOF
```

Always pass commands via heredoc (avoids escaping issues with `!`, `"`, `$`, etc.). The last positional argument is the timeout in seconds.

### Flags

| Flag | Description |
|------|-------------|
| `-s NAME` | Session name (or set `TMUX_REMOTE_SESSION`) |
| `-h USER@HOST` | SSH target (or set `TMUX_REMOTE_HOST`, omit for local) |
| `-t N` | Truncate output to N chars (default: 2000) |
| `-T` | Disable truncation |
| `-c` | Continue watching a timed-out command |
| `-p [N]` | Peek at last N chars on screen (no command needed) |

### Timeout and continue

Always specify a timeout. Default is 30s -- intentionally short. If a command times out, resume with:

```bash
./tmux-exec.sh -s SESSION -c 120
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
