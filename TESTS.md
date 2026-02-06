# tmux-wait.sh Test Suite

Run all tests against a live tmux session. Replace `-h USER@HOST -s SESSION` with your session.

## Prerequisites

Between each test, ensure the pane is idle (no running commands). If a previous test timed out, run:

```bash
./tmux-wait.sh -h HOST -s SESSION -c 60
```

## 1. Basic Output

### 1a. Single-line command

```bash
./tmux-wait.sh -h HOST -s SESSION -T 15 << 'EOF'
echo "AAA"; echo "BBB"; echo "CCC"
EOF
```

**Expected:** Exactly 3 lines: `AAA`, `BBB`, `CCC`. No marker, no command echo, no prompt.

### 1b. Multi-line command

```bash
./tmux-wait.sh -h HOST -s SESSION -T 15 << 'EOF'
for i in 1 2 3; do
  echo "line $i"
done
EOF
```

**Expected:** `line 1`, `line 2`, `line 3`. No heredoc body, no prompt.

### 1c. No output

```bash
./tmux-wait.sh -h HOST -s SESSION -T 15 << 'EOF'
sleep 1
EOF
```

**Expected:** Empty output (no blank lines, no prompt).

## 2. Streaming

### 2a. Slow output (0.5s per line)

```bash
./tmux-wait.sh -h HOST -s SESSION -T 15 << 'EOF'
for i in $(seq 1 10); do echo "line $i"; sleep 0.5; done
EOF
```

**Expected:** Lines 1-10, appearing incrementally. All 10 present. No duplicates (minor duplicates from polling race are cosmetic, not a failure).

### 2b. Fast output (0.1s per line)

```bash
./tmux-wait.sh -h HOST -s SESSION -T 15 << 'EOF'
for i in $(seq 1 10); do echo "line $i"; sleep 0.1; done
EOF
```

**Expected:** All 10 lines present. Line 1 must not be missing.

## 3. Instant Output / Scrollback Eviction

### 3a. Instant burst (no sleep)

```bash
for run in $(seq 1 10); do
  RESULT=$(./tmux-wait.sh -h HOST -s SESSION -T 15 << 'EOF'
for i in $(seq 1 50); do echo "line $i"; done
EOF
)
  COUNT=$(echo "$RESULT" | grep -c "^line ")
  echo "Run $run: $COUNT lines"
done
```

**Expected:** All 10 runs report 50 lines. This tests that the marker-based extraction survives scrollback buffer eviction (tmux `history-limit` is typically 2000).

## 4. Truncation

### 4a. Default truncation (2000 chars)

```bash
./tmux-wait.sh -h HOST -s SESSION 15 << 'EOF'
for i in $(seq 1 50); do echo "line $i: padding_$(head -c 50 /dev/urandom | base64 | tr -d '\n')"; done
EOF
```

**Expected:** Head section (first ~1000 chars), then `[...truncated...]`, then tail section (last ~1000 chars). Both sections visible.

### 4b. Custom truncation (-t N)

```bash
./tmux-wait.sh -h HOST -s SESSION -t 200 15 << 'EOF'
for i in $(seq 1 50); do echo "trunc test $i"; done
EOF
```

**Expected:** Small head (~100 chars), `[...truncated...]`, small tail (~100 chars).

### 4c. No truncation (-T)

```bash
./tmux-wait.sh -h HOST -s SESSION -T 15 << 'EOF'
for i in $(seq 1 50); do echo "line $i"; done
EOF
```

**Expected:** All 50 lines, no `[...truncated...]`.

### 4d. Truncation with long wrapped lines

```bash
./tmux-wait.sh -h HOST -s SESSION -t 5000 30 << 'EOF'
for i in $(seq 1 100); do echo "line $i: $(head -c 300 /dev/urandom | base64 | tr -d '\n')"; sleep 0.05; done
EOF
```

**Expected:** Head shows first few lines, `[...truncated...]`, tail shows lines near 100. Tail must reference lines near the end, not the middle.

## 5. Timeout

### 5a. Basic timeout

```bash
./tmux-wait.sh -h HOST -s SESSION -T 5 << 'EOF'
for i in $(seq 1 100); do echo "line $i"; sleep 0.3; done
EOF
```

**Expected:** Partial output (lines 1 through ~16), then `[TIMEOUT after 5s]`. Exit code 0.

### 5b. Timeout with truncation shows tail

```bash
./tmux-wait.sh -h HOST -s SESSION -t 500 8 << 'EOF'
for i in $(seq 1 100); do echo "line $i: $(head -c 100 /dev/urandom | base64 | tr -d '\n')"; sleep 0.3; done
EOF
```

**Expected:** Head (first ~250 chars), `[...truncated...]`, tail (last ~250 chars showing lines near where timeout hit), then `[TIMEOUT after 8s]`. The tail section must be visible (not swallowed by the Bash tool's error formatting — this is why timeout uses exit 0).

## 6. Continue Mode

### 6a. Timeout then continue

```bash
# Step 1: start command, let it timeout
./tmux-wait.sh -h HOST -s SESSION -T 5 << 'EOF'
for i in $(seq 1 100); do echo "line $i"; sleep 0.3; done
EOF

# Step 2: wait for command to progress
sleep 10

# Step 3: continue watching
./tmux-wait.sh -h HOST -s SESSION -c -T 30
```

**Expected:** Step 1 shows lines 1-~16 + `[TIMEOUT after 5s]`. Step 3 picks up near the current position and streams remaining lines through 100.

### 6b. Continue with truncation

```bash
# Step 1: start with truncation, let it timeout
./tmux-wait.sh -h HOST -s SESSION -t 500 5 << 'EOF'
for i in $(seq 1 100); do echo "line $i: $(head -c 100 /dev/urandom | base64 | tr -d '\n')"; sleep 0.3; done
EOF

# Step 2: wait
sleep 10

# Step 3: continue with truncation
./tmux-wait.sh -h HOST -s SESSION -c -t 500 30
```

**Expected:** Step 3 picks up near current position and shows truncated output through line 100.

## 7. Edge Cases

### 7a. Command with special characters

```bash
./tmux-wait.sh -h HOST -s SESSION -T 15 << 'EOF'
echo "hello!"; echo '$HOME'; echo "line with \"quotes\""
EOF
```

**Expected:** `hello!`, `$HOME` (literal), `line with "quotes"`. Heredoc input avoids escaping issues.

### 7b. Pane busy detection

```bash
# Start a background command manually first:
ssh HOST "tmux send-keys -t SESSION 'sleep 30' Enter"
sleep 1

# Try to run a command:
./tmux-wait.sh -h HOST -s SESSION -T 5 << 'EOF'
echo "should not run"
EOF
```

**Expected:** `[ERROR] Pane is busy` on stderr, exit code 1. Then cancel the sleep:

```bash
ssh HOST "tmux send-keys -t SESSION C-c"
```
