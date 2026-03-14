# TODO

## Bugs

- **Stdin not reaching `cat` when invoked from Claude Code Bash tool** (likely fixed): Was caused by SSH calls before `CMD=$(cat)` consuming stdin. Fixed by adding `< /dev/null` to the auto-create session `run` call. Needs confirmation with remote execution.

- **Empty output on short/single-line commands** (not reproduced locally): Claude sometimes gets empty output and falls back to `tmux capture-pane` directly. Could not reproduce with local sessions — tested single-line, multi-line, rapid sequential, post-flood, and fast commands. May be remote-only (SSH timing) or intermittent. Need to capture the exact command and session state next time it happens.

- **Marker eviction on huge output**: If a command produces enough output to exceed tmux's `history-limit` (default 2000 lines), the marker gets pushed out of scrollback. The script prints `[OUTPUT EXCEEDED TMUX SCROLLBACK]` and falls back to showing the tail of the pane (respects `--truncate-chars`, defaults to 2000 chars). Not as clean as marker-based extraction, but better than silent empty. Bumping `history-limit` on session creation avoids the issue entirely.

- **Same-session parallelism**: Tested and confirmed broken. The idle check + dispatch isn't atomic, so concurrent calls all pass the busy check and paste over each other. Local sessions: simple `flock` around the whole execution. Remote sessions: harder — current architecture does many short SSH calls so you can't hold a lock across them.

## Ideas

- **Single-SSH rewrite**: Move the entire poll loop to the remote side so it runs as one SSH call. Flock wraps the whole thing. Also eliminates per-poll SSH latency (~1-2s per round-trip). Downside: ~100 lines of bash shipped over SSH every invocation, escaping complexity, harder to debug.

- **Remote helper script**: On first use, scp a helper script to the remote machine (e.g. `/tmp/tmux-exec-remote.sh`). Local side just calls `ssh host /tmp/tmux-exec-remote.sh <args>`. The remote script does flock + dispatch + poll + streaming. Avoids shipping code every call, easier to debug (it's a real file on the remote), and the remote script can be version-checked and re-deployed if stale. Downside: adds a deploy/sync step.

- **Auto-deploy tmux**: If the remote doesn't have tmux, scp a statically compiled binary (e.g. from `tmux-static` on GitHub) and use that. Same deploy pattern as the remote helper script. Binary must match the remote's architecture. Preferred install locations in order: `$XDG_RUNTIME_DIR` (per-user tmpfs, avoids noexec issues), `/tmp` (may be noexec on hardened systems), `~/bin` as a last resort (schedule deletion via `at` or a background `sleep N && rm` to avoid leaving permanent files on someone else's machine).

- **No-tmux fallback**: If the remote has no tmux and we can't deploy it, fall back to plain SSH with a background process + output file: `nohup cmd > /tmp/tmux-exec-output-$ID 2>&1 & echo $!`, then poll the file. Loses the user-visible pane but keeps persistent execution and output capture. Degraded mode beats no mode.

- **Screen as a fallback**: GNU screen ships on more systems than tmux, especially older/minimal servers. The core mechanics (send command, capture output, check idle) all have screen equivalents. Could adapt automatically.

- **Multiplexer auto-detection**: On first connect, probe the remote: `which tmux || which screen || echo NONE`. Cache the result. Pick the best available backend automatically rather than failing.
