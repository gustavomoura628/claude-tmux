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

## Install

```bash
# From your project root:
mkdir -p .claude/skills
ln -s /absolute/path/to/claude-tmux .claude/skills/claude-tmux
```

Claude Code auto-discovers skills by scanning `.claude/skills/*/SKILL.md` on startup. The skill will appear in the available skills list and activate automatically when the task matches, or manually via `/claude-tmux`.

On first use, Claude will ask which host(s) to target and save them to memory. No manual CLAUDE.md configuration needed.

### Create a tmux session

```bash
# Local
tmux new -s my-session

# Remote (SSH key auth required)
ssh user@host "tmux new -d -s my-session"
```

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
| `--dangerously-skip-truncation` | Disable truncation entirely |
| `--raw` | Raw paste mode -- stdin goes directly into the pane via tmux buffer. No marker, no polling. For TUI targets |
| `--keys KEY...` | Send tmux key names (Enter, C-c, Up, etc.) via send-keys. Fire-and-forget |
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

### Raw and key modes

For TUI targets (e.g. another Claude Code instance), text and keystrokes are separate operations:

- `--raw` pastes text via tmux buffer (literal, no escaping issues)
- `--keys` sends tmux key names via send-keys (Enter, C-c, Up, etc.)

```bash
# Paste text into a TUI pane:
./tmux-exec.sh -s my-session --raw << 'EOF'
hello world
EOF

# Submit with Enter:
./tmux-exec.sh -s my-session --keys Enter

# Send Ctrl-C:
./tmux-exec.sh -s my-session --keys C-c

# Multiple keys in one call:
./tmux-exec.sh -s my-session --keys Up Up Enter
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

The marker-based approach survives normal tmux scrollback eviction and always finds the correct output even with long history — with one exception (see bugs).

## Known Bugs

- **Marker eviction on huge output** -- if a command produces enough output to exceed tmux's `history-limit` (default 2000 lines), the marker gets pushed out of scrollback. When this happens, the script prints `[OUTPUT EXCEEDED TMUX SCROLLBACK]` and falls back to showing the tail of the pane (respects `-t`, defaults to 2000 chars). Not as clean as marker-based extraction, but better than silent empty. Bumping `history-limit` on session creation avoids the issue entirely.
- **Same-session parallelism** -- tested and confirmed broken. The idle check + dispatch isn't atomic, so concurrent calls all pass the busy check and paste over each other. Local sessions: simple `flock` around the whole execution. Remote sessions: harder — current architecture does many short SSH calls so you can't hold a lock across them.

## TODO

### Ideas

- **Single-SSH rewrite** -- move the entire poll loop to the remote side so it runs as one SSH call. Flock wraps the whole thing. Also eliminates per-poll SSH latency (~1-2s per round-trip). Downside: ~100 lines of bash shipped over SSH every invocation, escaping complexity, harder to debug.
- **Remote helper script** -- on first use, scp a helper script to the remote machine (e.g. `/tmp/tmux-exec-remote.sh`). Local side just calls `ssh host /tmp/tmux-exec-remote.sh <args>`. The remote script does flock + dispatch + poll + streaming. Avoids shipping code every call, easier to debug (it's a real file on the remote), and the remote script can be version-checked and re-deployed if stale. Downside: adds a deploy/sync step.
- **Auto-deploy tmux** -- if the remote doesn't have tmux, scp a statically compiled binary (e.g. from `tmux-static` on GitHub) and use that. Same deploy pattern as the remote helper script. Binary must match the remote's architecture. Preferred install locations in order: `$XDG_RUNTIME_DIR` (per-user tmpfs, avoids noexec issues), `/tmp` (may be noexec on hardened systems), `~/bin` as a last resort (schedule deletion via `at` or a background `sleep N && rm` to avoid leaving permanent files on someone else's machine).
- **No-tmux fallback** -- if the remote has no tmux and we can't deploy it, fall back to plain SSH with a background process + output file: `nohup cmd > /tmp/tmux-exec-output-$ID 2>&1 & echo $!`, then poll the file. Loses the user-visible pane but keeps persistent execution and output capture. Degraded mode beats no mode.
- **Screen as a fallback** -- GNU screen ships on more systems than tmux, especially older/minimal servers. The core mechanics (send command, capture output, check idle) all have screen equivalents. Could adapt automatically.
- **Multiplexer auto-detection** -- on first connect, probe the remote: `which tmux || which screen || echo NONE`. Cache the result. Pick the best available backend automatically rather than failing.

## Requirements

- tmux on the target machine
- bash on both machines
- SSH key auth (for remote sessions)
