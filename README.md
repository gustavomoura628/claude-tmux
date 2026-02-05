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

```bash
# Local session
./tmux-wait.sh -s my-session 'make build' 60

# Remote session
./tmux-wait.sh -h user@host -s my-session 'docker compose up -d' 120

# With environment variables
export TMUX_REMOTE_HOST=user@host    # omit for local sessions
export TMUX_REMOTE_SESSION=my-session
./tmux-wait.sh 'npm test' 30
```

Default timeout is 120 seconds. Exit 0 on completion, exit 1 on timeout.

### How it works

1. Sends a no-op start marker (`: TMUX_START_xxx`) to the session
2. Sends the command chained with an echo end marker: `(cmd); echo TMUX_END_xxx`
3. Polls `tmux capture-pane` every 2 seconds
4. The end marker only appears as echo output after the command completes -- queued keystrokes get echoed during execution, but the echo output only appears once the shell processes it
5. Returns just the command's output, stripped of all markers

## Requirements

- tmux on the target machine
- bash on both machines
- SSH key auth (for remote sessions)
