## Tmux Operation

You have access to tmux sessions for running commands -- local or remote. This is often better than the built-in Bash tool because:

- **Persistent sessions** -- working directory, environment variables, and running processes carry over between commands. No re-setting-up context.
- **Non-blocking execution** -- fire off a long build, install, or server and check on it later. You don't have to sit and wait.
- **User visibility** -- the user can watch the tmux pane in real time and see exactly what you're doing.
- **Multiple parallel sessions** -- spawn separate sessions for different tasks. Build in one, test in another, run a server in a third.
- **Surviving disconnects** -- commands keep running even if the Claude session ends.
- **Local or remote** -- same workflow whether the session is on this machine or on a server over SSH.

Use tmux for anything interactive, long-running, or where persistent state matters. Use the built-in Bash tool for quick one-off commands where none of the above matters.

Do most work in a single primary session. If you need parallel execution, spawn extra sessions named `claude-session-0`, `claude-session-1`, etc. Reuse existing sessions instead of killing and creating new ones -- check `tmux list-sessions` first. Only spawn a new session when you genuinely need parallelism.

**Run a command and wait for completion (preferred):**
```bash
# Local:
./tmux-wait.sh -s SESSION << 'EOF'
command here
EOF

# Remote:
./tmux-wait.sh -h USER@HOST -s SESSION << 'EOF'
command here
EOF

# With timeout (before heredoc):
./tmux-wait.sh -h USER@HOST -s SESSION 60 << 'EOF'
command here
EOF
```
Pass commands via heredoc to avoid shell escaping issues. Polls until finished, streams output as it appears. Default timeout 30s. Output truncated to 2000 chars by default (`-T` to disable, `-t N` for custom limit). Use `-c` to continue watching a timed-out command. Use `-p [N]` to peek at the last N chars on screen without running a command (default 2000).

**Spawn a new session** when you need parallelism:
```bash
# Local
tmux new -d -s claude-session-0
# Remote
ssh user@host "tmux new -d -s claude-session-0"
```
Then use `tmux-wait.sh` with `-s claude-session-0` to operate in it. Check what's running:
```bash
# Local
tmux list-sessions
# Remote
ssh user@host "tmux list-sessions"
```

**Manual operations** (fallback):
```bash
# Send a command (omit ssh for local)
ssh user@host "tmux send-keys -t session 'command' Enter"
# Read output (pipe to tail -N for last N lines)
ssh user@host "tmux capture-pane -t session -p" | tail -20
# Cancel
ssh user@host "tmux send-keys -t session C-c"
```
