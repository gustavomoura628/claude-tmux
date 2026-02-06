# Dev Diary

## 2026-02-04 -- Initial skill

Built a reusable skill for Claude Code to operate tmux sessions -- local or remote. Persistent sessions, non-blocking execution, user-visible terminals, parallel sessions for concurrent tasks. Includes `tmux-wait.sh` (sends a command, polls for completion via output markers, returns clean output) and a `CLAUDE_TEMPLATE.md` ready to paste into any project's `.claude/CLAUDE.md`.

## 2026-02-05 -- Marker-based extraction, continue mode, peek

Major overhaul of `tmux-wait.sh` to fix several output capture bugs.

**Marker-based extraction** replaced line counting. The old approach counted scrollback lines before/after command execution, but tmux's `history-limit` evicts old lines during long sessions, causing `LINES_NOW < LINES_BEFORE` and negative line counts. Now the script appends `#__TMUX_MARKER__` as a bash comment to the command line. `extract_output()` greps for the last marker in `capture-pane` output and takes everything after it. Immune to scrollback eviction.

**Multi-marker bug** -- when running back-to-back commands, old markers remain in scrollback. `extract_output` originally used `sed` which matched the first marker. Fixed by using `grep -n | tail -1` to always find the last one.

**Continue mode refactored** -- `-c` used to have its own line-counting code path in the main loop. Now it uses the same marker-based extraction as normal mode: takes an initial snapshot to find current output length, sets `PRINTED_LINES` to 5 lines before the end for context, then falls through to the normal streaming loop. Fixes prompt leaking in continue mode output.

**Other fixes this session:**
- `capture-pane -J` to join wrapped lines (fixes mixed logical/display line counting)
- Removed `pipefail` to fix SIGPIPE errors in pipe chains
- Truncation always on (2000 chars default), `-T` to disable
- Timeout exits 0 (Bash tool hides stdout on non-zero exit)
- Fixed off-by-one that skipped the first output line

**New: `-p [N]` peek flag** -- grabs the last N characters from the pane without running a command or needing a marker. Useful for checking what's on screen in any pane.

**Discovery: Claude Code Bash tool is serial** -- parallel Bash tool calls are executed sequentially, not concurrently. This means concurrent tmux-wait.sh calls to the same session can't race each other, so no concurrency handling needed.

**Idle detection fix** -- replaced `ps --tty` process counting with `pgrep --parent $PANE_PID`. The old approach counted all processes on the TTY, including orphaned processes from killed sessions that reused the same PTY. The new approach only checks if the shell has children.

**SSH latency optimization** -- combined 4 separate SSH calls for command dispatch (idle check, load-buffer, paste-buffer, send-keys) into a single piped SSH call. Halved dispatch latency (~4.4s to ~2.2s over SSH).

**Remote-side extraction** -- moved marker finding and skip_top filtering from the local side into the `snapshot()` function that runs on the remote. Instead of transferring the entire pane scrollback every poll, only the extracted command output and idle status come back. Reduces data transfer significantly.

Docs consolidated: README updated to describe the marker-based approach, combined dispatch, and pgrep idle detection.

## 2026-02-05 -- Stress test: the playground session

Fixed the nested heredoc bug (multi-line commands use `bash << 'EOF'` internally, which collides if the command itself contains `EOF`). Changed delimiter to `TMUX_EOF`. Discovered while trying to write a bash script via multi-line tmux-wait command that contained its own heredoc.

Then went wild with a stress test playground. Wrote and ran 4 scripts entirely through tmux-wait.sh over SSH:

**Matrix rain** (`matrix.sh`) -- 200 frames of falling katakana/hex characters with ANSI cursor addressing. Tests fast streaming + escape codes. Peek mode (`-p`) showed empty for this one since cursor-addressed drawing doesn't leave linear text in capture-pane -- expected behavior, good to know.

**Conway's Game of Life** (`life.sh`) -- 100 generations of a 60x25 toroidal grid with bash associative arrays. Rendered at 5fps via `\033[H` cursor home. Completed clean, peek caught it mid-generation showing live cell patterns.

**Mandelbrot set** (`mandelbrot.sh`) -- 80x30 ASCII fractal using pure bash integer arithmetic (fixed-point *1000). No bc, no awk, just `$(( ))`. Every character of the output captured perfectly -- the classic cardioid and bulb in `.:-=+*#%@` density shading.

**4-way parallel race** -- spawned 4 tmux sessions, each running `race.sh` printing 1000 lines at full speed with no sleep. All 4 launched as background tasks, all 4 completed clean. Truncation worked perfectly on each (head ~16 lines + `[...truncated...]` + tail ~14 lines). Zero cross-contamination between sessions.

Results:

| Test | Sessions | Output | Result |
|------|----------|--------|--------|
| Matrix rain | 1 | 200 frames ANSI | Clean |
| Game of Life | 1 | 100 generations | Clean |
| Burst (base64) | 1 | 500 lines | Clean, truncation correct |
| Mandelbrot | 1 | 30 rows ASCII art | Every char captured |
| 4-way race | 4 parallel | 4x1000 lines | All clean, no cross-talk |
| Nested heredoc | - | inner `SCRIPT` delimiter | TMUX_EOF fix works |

The whole session was done without touching the remote machine directly -- every script was written, deployed, and executed through tmux-wait.sh.
