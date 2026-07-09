#!/bin/bash
# hook-live-sim.sh — release-gate harness for the tier-3 hooks (CONTRIBUTING
# "Test checklist" item 7; hooks.md §Verified 2026-07-09).
#
# Why this exists: v0.8.0 shipped the hooks validated with mock stdin only —
# they had never been live-registered, so a wrong payload-field assumption
# would have made the backstop silently no-op forever while the docs claimed
# coverage (audit finding #16, the v0.2.4 "nobody re-tested the documented
# flow" lesson). This harness closes that loop and MUST pass before any
# release that touches hooks/, the §4.13 announce format, or install.sh's
# hook merge.
#
# What it does — fully sandboxed (temp HOME + temp install copy; it never
# touches your real ~/.claude, your settings.json, or a deployed install):
#
#   R. REGISTRATION — copies this repo into the sandbox (origin remote
#      removed: the sim can never hit the network), runs the REAL install.sh
#      with ENABLE_HOOKS=Y against the sandbox HOME, and asserts all four
#      hook entries land in $HOME/.claude/settings.json exactly as hooks.md
#      documents (Stop ×1, PreToolUse Task ×1, PreToolUse Bash ×2; every
#      registered command resolves to an executable through the symlink).
#      Re-runs install.sh to prove the merge is idempotent; runs uninstall.sh
#      at the end to prove removal leaves no stranded entries.
#
#   P. PAYLOAD SIMULATION — invokes each REGISTERED command (read back out of
#      the sandbox settings.json — the exact string the harness would exec)
#      with realistic Stop / PreToolUse JSON payloads matching the Claude
#      Code hooks reference (code.claude.com/docs/en/hooks): common envelope
#      session_id / prompt_id / transcript_path / cwd / permission_mode /
#      hook_event_name, plus tool_name + tool_input (PreToolUse) or
#      last_assistant_message + stop_hook_active (Stop; both fields are
#      documented — reference §Stop and hooks-guide loop-protection section).
#      Asserts every allow / block / inject path per hook, including the
#      metrics gate's transcript FALLBACK against the real transcript JSONL
#      shape ({"type":"assistant","message":{"content":[{"type":"text",..}]}}).
#
# Requirements: bash 3.2+, jq, git, python3 (install.sh dependencies).
# Usage: skills/do/hooks/hook-live-sim.sh [--keep]   (--keep retains sandbox)
# Exit: 0 = all cases pass; 1 = failures (prints the failing case list).

# shellcheck disable=SC2016  # single-quoted `Metrics:`/${METRICS_LINE} literals are intentional (grep -F fixtures)
set -u

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd -P)
for c in jq git python3; do
  command -v "$c" >/dev/null 2>&1 || { echo "FATAL: $c required" >&2; exit 1; }
done

SB=$(mktemp -d "${TMPDIR:-/tmp}/hook-live-sim.XXXXXX") || exit 1
KEEP=""; [ "${1:-}" = "--keep" ] && KEEP=1
# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() { [ -n "$KEEP" ] && { echo "sandbox kept: $SB"; return; }; rm -rf "$SB"; }
trap cleanup EXIT

PASS=0; FAIL=0; FAILED=""
okc()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
failc() { FAIL=$((FAIL + 1)); FAILED="$FAILED $1"; printf '  FAIL %s — %s\n' "$1" "$2"; }

RC=0; OUTF="$SB/out"; ERRF="$SB/err"
run_hook() { # $1=hook-cmd  $2=payload-json
  printf '%s' "$2" | "$1" >"$OUTF" 2>"$ERRF"; RC=$?
}

# ---------------------------------------------------------------- fixtures --
SB_HOME="$SB/home"; mkdir -p "$SB_HOME"
SB_INSTALL="$SB/install"
SETTINGS="$SB_HOME/.claude/settings.json"

git_q() { git -c user.email=sim@example.invalid -c user.name=sim "$@"; }

mk_repo() { # $1=dir — main + bare origin with origin/main; leaves main checked out
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" checkout -q -b main
  echo base > "$1/base.txt"
  git_q -C "$1" add -A
  git_q -C "$1" commit -qm base
}
add_origin() { # $1=dir — bare-clone current branches as origin, fetch refs
  git clone -q --bare "$1" "$1-origin.git"
  git -C "$1" remote add origin "$1-origin.git"
  git -C "$1" fetch -q origin
}

# Payload builders — envelope fields per the Claude Code hooks reference.
pre_payload() { # $1=tool_name $2=tool_input-json $3=cwd
  jq -n --arg tn "$1" --argjson ti "$2" --arg cwd "$3" --arg tp "$SB/transcript.jsonl" '{
    session_id: "sim-session", prompt_id: "11111111-1111-4111-8111-111111111111",
    transcript_path: $tp, cwd: $cwd, permission_mode: "default",
    hook_event_name: "PreToolUse", tool_name: $tn, tool_input: $ti }'
}
stop_payload() { # $1=last_assistant_message $2=stop_hook_active(true/false)
  jq -n --arg m "$1" --argjson a "$2" --arg cwd "$SB" --arg tp "$SB/transcript.jsonl" '{
    session_id: "sim-session", prompt_id: "11111111-1111-4111-8111-111111111111",
    transcript_path: $tp, cwd: $cwd, permission_mode: "default",
    hook_event_name: "Stop", stop_hook_active: $a, last_assistant_message: $m }'
}
stop_payload_no_msg() { # $1=transcript_path — no last_assistant_message field at all
  jq -n --arg cwd "$SB" --arg tp "$1" '{
    session_id: "sim-session", prompt_id: "11111111-1111-4111-8111-111111111111",
    transcript_path: $tp, cwd: $cwd, permission_mode: "default",
    hook_event_name: "Stop", stop_hook_active: false }'
}

# ============================================================ R. REGISTRATION
echo "R. registration (real install.sh against sandbox HOME)"

cp -R "$REPO_ROOT" "$SB_INSTALL"
git -C "$SB_INSTALL" remote remove origin >/dev/null 2>&1 || true   # never network

if HOME="$SB_HOME" INSTALL_DIR="$SB_INSTALL" SKILL_NAME="do" TRIGGER=none ENABLE_HOOKS=Y \
     bash "$SB_INSTALL/install.sh" >"$SB/install.log" 2>&1; then
  okc "R1 install.sh completed (ENABLE_HOOKS=Y, sandbox HOME)"
else
  failc "R1" "install.sh exited $? — see $SB/install.log"; KEEP=1
fi

if [ -f "$SETTINGS" ] && jq -e . "$SETTINGS" >/dev/null 2>&1; then
  okc "R2a settings.json exists and parses"
else
  failc "R2a" "sandbox settings.json missing/invalid"; KEEP=1
fi

STOP_HOOK=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$SETTINGS" 2>/dev/null)
PLAN_HOOK=$(jq -r '[.hooks.PreToolUse[]? | select(.matcher == "Task")][0].hooks[0].command // empty' "$SETTINGS" 2>/dev/null)
SECRET_HOOK=$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command | select(endswith("do-secret-scan-pretooluse.sh"))][0] // empty' "$SETTINGS" 2>/dev/null)
PRSIZE_HOOK=$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command | select(endswith("do-pr-size-pretooluse.sh"))][0] // empty' "$SETTINGS" 2>/dev/null)

for pair in "R2b-stop:$STOP_HOOK:do-metrics-stop-gate.sh" \
            "R2c-plan:$PLAN_HOOK:do-plan-size-pretooluse.sh" \
            "R2d-secret:$SECRET_HOOK:do-secret-scan-pretooluse.sh" \
            "R2e-prsize:$PRSIZE_HOOK:do-pr-size-pretooluse.sh"; do
  name=${pair%%:*}; rest=${pair#*:}; cmd=${rest%:*}; base=${rest##*:}
  if [ -n "$cmd" ] && [ "$(basename "$cmd")" = "$base" ] && [ -x "$cmd" ]; then
    okc "$name registered + executable ($base)"
  else
    failc "$name" "expected executable $base, got: '${cmd:-<none>}'"
  fi
done

N_TASK=$(jq '[.hooks.PreToolUse[]? | select(.matcher == "Task")] | length' "$SETTINGS" 2>/dev/null)
N_BASH=$(jq '[.hooks.PreToolUse[]? | select(.matcher == "Bash")] | length' "$SETTINGS" 2>/dev/null)
N_STOP=$(jq '.hooks.Stop | length' "$SETTINGS" 2>/dev/null)
if [ "$N_STOP" = "1" ] && [ "$N_TASK" = "1" ] && [ "$N_BASH" = "2" ]; then
  okc "R2f entry counts Stop=1 Task=1 Bash=2 (per hooks.md)"
else
  failc "R2f" "counts Stop=$N_STOP Task=$N_TASK Bash=$N_BASH"
fi

HOME="$SB_HOME" INSTALL_DIR="$SB_INSTALL" SKILL_NAME="do" TRIGGER=none ENABLE_HOOKS=Y \
  bash "$SB_INSTALL/install.sh" >"$SB/install2.log" 2>&1
N_TASK2=$(jq '[.hooks.PreToolUse[]? | select(.matcher == "Task")] | length' "$SETTINGS" 2>/dev/null)
N_BASH2=$(jq '[.hooks.PreToolUse[]? | select(.matcher == "Bash")] | length' "$SETTINGS" 2>/dev/null)
N_STOP2=$(jq '.hooks.Stop | length' "$SETTINGS" 2>/dev/null)
if [ "$N_STOP2" = "1" ] && [ "$N_TASK2" = "1" ] && [ "$N_BASH2" = "2" ]; then
  okc "R3 re-run is idempotent (no duplicate entries)"
else
  failc "R3" "after re-run: Stop=$N_STOP2 Task=$N_TASK2 Bash=$N_BASH2"
fi

# ================================================= P1. metrics Stop gate (M*)
echo "P1. do-metrics-stop-gate.sh (Stop payloads)"

LOG_OK="$SB/metrics-ok.jsonl"
printf '%s\n' '{"ref":"i40","outcome":"merged"}' '{"ref":"i41","outcome":"merged"}' \
              '{"ref":"i41b","outcome":"merged"}' '{"ref":"i42","outcome":"merged"}' > "$LOG_OK"
LOG_STALE="$SB/metrics-stale.jsonl"
printf '%s\n' '{"ref":"i97"}' '{"ref":"i98"}' '{"ref":"i98b"}' '{"ref":"i99"}' > "$LOG_STALE"
OLD_TS=$(python3 -c 'import time; print(time.strftime("%Y%m%d%H%M.%S", time.localtime(time.time()-7200)))')
touch -t "$OLD_TS" "$LOG_STALE"

ANNOUNCE_HEAD="Complete. Branch: fix/i42-add-thing (pushed). PR: https://example.invalid/pr/7
Models: orchestrator=opus-4-6 implementer=sonnet-4-5"

run_hook "$STOP_HOOK" "$(stop_payload "$ANNOUNCE_HEAD
Metrics: 4 entries in $LOG_OK (pre=3 gates=6)." false)"
if [ "$RC" -eq 0 ] && [ ! -s "$OUTF" ]; then okc "M1 compliant announce (pre=/gates= tell) → allow"
else failc "M1" "rc=$RC out=$(head -c200 "$OUTF")"; fi

run_hook "$STOP_HOOK" "$(stop_payload "$ANNOUNCE_HEAD
All done." false)"
if jq -e '.decision == "block"' "$OUTF" >/dev/null 2>&1 && grep -qF 'NO `Metrics:` line' "$OUTF"; then
  okc "M2 finalize without Metrics line → block"
else failc "M2" "rc=$RC out=$(head -c200 "$OUTF")"; fi

run_hook "$STOP_HOOK" "$(stop_payload "$ANNOUNCE_HEAD
Metrics: skipped — not needed for a docs task." false)"
if jq -e '.decision == "block"' "$OUTF" >/dev/null 2>&1 && grep -q 'matches none' "$OUTF"; then
  okc "M3 hand-composed 'Metrics: skipped' → block (closed set)"
else failc "M3" "rc=$RC out=$(head -c200 "$OUTF")"; fi

run_hook "$STOP_HOOK" "$(stop_payload "$ANNOUNCE_HEAD
Metrics: 4 entries in $LOG_OK (pre=4 gates=6)." false)"
if jq -e '.decision == "block"' "$OUTF" >/dev/null 2>&1 && grep -q 'internally inconsistent' "$OUTF"; then
  okc "M4 tell pre+1 != N → block"
else failc "M4" "rc=$RC out=$(head -c200 "$OUTF")"; fi

run_hook "$STOP_HOOK" "$(stop_payload "$ANNOUNCE_HEAD
Metrics: 4 entries in $SB/nope.jsonl (pre=3 gates=6)." false)"
if jq -e '.decision == "block"' "$OUTF" >/dev/null 2>&1 && grep -q 'does not exist' "$OUTF"; then
  okc "M5 claimed log path missing → block"
else failc "M5" "rc=$RC out=$(head -c200 "$OUTF")"; fi

run_hook "$STOP_HOOK" "$(stop_payload "$ANNOUNCE_HEAD
Metrics: 9 entries in $LOG_OK (pre=8 gates=6)." false)"
if jq -e '.decision == "block"' "$OUTF" >/dev/null 2>&1 && grep -q 'NOT appended' "$OUTF"; then
  okc "M6 claimed count > file lines → block"
else failc "M6" "rc=$RC out=$(head -c200 "$OUTF")"; fi

run_hook "$STOP_HOOK" "$(stop_payload "$ANNOUNCE_HEAD
Metrics: 4 entries in $LOG_STALE (pre=3 gates=6)." false)"
if jq -e '.decision == "block"' "$OUTF" >/dev/null 2>&1 && grep -q 'STALE' "$OUTF"; then
  okc "M7 stale log (ref mismatch + old mtime) → block"
else failc "M7" "rc=$RC out=$(head -c200 "$OUTF")"; fi

run_hook "$STOP_HOOK" "$(stop_payload "Just a normal answer about your question. No /do run here." false)"
if [ "$RC" -eq 0 ] && [ ! -s "$OUTF" ]; then okc "M8 non-/do turn → no-op (self-scoping)"
else failc "M8" "rc=$RC out=$(head -c200 "$OUTF")"; fi

run_hook "$STOP_HOOK" "$(stop_payload "$ANNOUNCE_HEAD
All done." true)"
if [ "$RC" -eq 0 ] && [ ! -s "$OUTF" ]; then okc "M9 stop_hook_active=true → allow (loop guard)"
else failc "M9" "rc=$RC out=$(head -c200 "$OUTF")"; fi

run_hook "$STOP_HOOK" "$(stop_payload 'Complete. Branch: docs pass on phase-4-finalize.md
The spec template emits: Metrics: ${METRICS_LINE}' false)"
if [ "$RC" -eq 0 ] && [ ! -s "$OUTF" ]; then okc "M10 unexpanded placeholder quote → no-op (docs-work guard)"
else failc "M10" "rc=$RC out=$(head -c200 "$OUTF")"; fi

run_hook "$STOP_HOOK" "$(stop_payload "$ANNOUNCE_HEAD
Metrics: not configured (no metrics block in config.json)." false)"
if [ "$RC" -eq 0 ] && [ ! -s "$OUTF" ]; then okc "M11 'Metrics: not configured' terminal state → allow"
else failc "M11" "rc=$RC out=$(head -c200 "$OUTF")"; fi

# Transcript fallback: payload WITHOUT last_assistant_message; transcript in
# the real Claude Code JSONL shape (verified against an actual local
# transcript: type=assistant, message.content = array of {type:"text",text}).
TR="$SB/fallback-transcript.jsonl"
jq -nc '{type:"user", message:{role:"user", content:[{type:"text", text:"+++ ship the thing"}]}}' > "$TR"
jq -nc '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:"Working on it."}]}}' >> "$TR"
jq -nc --arg t "$ANNOUNCE_HEAD
All done, no metrics emitted." '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:$t}]}}' >> "$TR"
run_hook "$STOP_HOOK" "$(stop_payload_no_msg "$TR")"
if jq -e '.decision == "block"' "$OUTF" >/dev/null 2>&1 && grep -qF 'NO `Metrics:` line' "$OUTF"; then
  okc "M12 no last_assistant_message field → transcript fallback still blocks"
else failc "M12" "rc=$RC out=$(head -c200 "$OUTF")"; fi

# ========================================== P2. plan-size PreToolUse (Task) --
echo "P2. do-plan-size-pretooluse.sh (PreToolUse Task payloads)"

TASK_TI() { jq -n --arg p "$1" '{description: "Implement issue", prompt: $p, subagent_type: "general-purpose"}'; }

run_hook "$PLAN_HOOK" "$(pre_payload Task "$(TASK_TI 'Implement per plan.
PLAN-SIZE: files=30 lines=2000 complexity=H
Do the work.')" "$SB")"
if jq -e '.hookSpecificOutput.permissionDecision == "allow"' "$OUTF" >/dev/null 2>&1 \
   && grep -q 'SPLIT-REQUIRED' "$OUTF" && grep -q '\[tell:' "$OUTF"; then
  okc "P2a oversized marker → SPLIT-REQUIRED verdict injected (tell intact, non-blocking)"
else failc "P2a" "rc=$RC out=$(head -c200 "$OUTF")"; fi

run_hook "$PLAN_HOOK" "$(pre_payload Task "$(TASK_TI 'PLAN-SIZE: files=12 lines=800 complexity=M')" "$SB")"
if jq -e '.hookSpecificOutput.permissionDecision == "allow"' "$OUTF" >/dev/null 2>&1 \
   && grep -q 'REBUMP M→H' "$OUTF"; then
  okc "P2b over-M marker → REBUMP M→H verdict injected"
else failc "P2b" "rc=$RC out=$(head -c200 "$OUTF")"; fi

run_hook "$PLAN_HOOK" "$(pre_payload Task "$(TASK_TI 'PLAN-SIZE: files=3 lines=120 complexity=M')" "$SB")"
if jq -e '.hookSpecificOutput.permissionDecision == "allow"' "$OUTF" >/dev/null 2>&1 \
   && grep -q 'Phase 2.0: PASS' "$OUTF"; then
  okc "P2c in-bucket marker → PASS verdict injected"
else failc "P2c" "rc=$RC out=$(head -c200 "$OUTF")"; fi

run_hook "$PLAN_HOOK" "$(pre_payload Task "$(TASK_TI 'Explore the codebase and summarize the auth flow.')" "$SB")"
if [ "$RC" -eq 0 ] && [ ! -s "$OUTF" ]; then okc "P2d no marker (Explore-style Task) → no-op"
else failc "P2d" "rc=$RC out=$(head -c200 "$OUTF")"; fi

# ======================================== P3. secret-scan PreToolUse (Bash) --
echo "P3. do-secret-scan-pretooluse.sh (PreToolUse Bash payloads)"

SR_CLEAN="$SB/srepo-clean"
mk_repo "$SR_CLEAN"
git -C "$SR_CLEAN" checkout -q -b feature
echo "honest work" > "$SR_CLEAN/feature.txt"
git_q -C "$SR_CLEAN" add -A && git_q -C "$SR_CLEAN" commit -qm feature
git -C "$SR_CLEAN" checkout -q main
add_origin "$SR_CLEAN"
git -C "$SR_CLEAN" checkout -q feature

SR_DIRTY="$SB/srepo-dirty"
mk_repo "$SR_DIRTY"
add_origin "$SR_DIRTY"
git -C "$SR_DIRTY" checkout -q -b feature
FAKE_AWS=$(printf 'AKIA%s' 'IOSFODNN7EXAMPLE')   # concatenated so THIS file never matches the scanner
printf 'aws_access_key_id = %s\n' "$FAKE_AWS" > "$SR_DIRTY/settings.py"
git_q -C "$SR_DIRTY" add -A && git_q -C "$SR_DIRTY" commit -qm oops
git -C "$SR_DIRTY" rm -q settings.py && git_q -C "$SR_DIRTY" commit -qm "remove it"

run_hook "$SECRET_HOOK" "$(pre_payload Bash "$(jq -n '{command: "git push origin feature", description: "push"}')" "$SR_CLEAN")"
if [ "$RC" -eq 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "allow"' "$OUTF" >/dev/null 2>&1 \
   && grep -q 'clean' "$OUTF"; then
  okc "P3a clean-range push → allow + PASS tell injected"
else failc "P3a" "rc=$RC out=$(head -c200 "$OUTF")"; fi

run_hook "$SECRET_HOOK" "$(pre_payload Bash "$(jq -n '{command: "git push origin feature", description: "push"}')" "$SR_DIRTY")"
if [ "$RC" -eq 2 ] && grep -q 'BLOCKED this git push' "$ERRF"; then
  okc "P3b committed-then-deleted secret in range → exit 2 deny"
else failc "P3b" "rc=$RC err=$(head -c200 "$ERRF")"; fi

run_hook "$SECRET_HOOK" "$(pre_payload Bash "$(jq -n '{command: "ls -la", description: "list"}')" "$SR_DIRTY")"
if [ "$RC" -eq 0 ] && [ ! -s "$OUTF" ]; then okc "P3c non-push command → no-op"
else failc "P3c" "rc=$RC out=$(head -c200 "$OUTF")"; fi

# =========================================== P4. pr-size PreToolUse (Bash) --
echo "P4. do-pr-size-pretooluse.sh (PreToolUse Bash payloads)"

PR="$SB/prrepo"
mk_repo "$PR"
git -C "$PR" checkout -q -b feat-big;   seq 1 2500 > "$PR/big.txt";   git_q -C "$PR" add -A; git_q -C "$PR" commit -qm big
git -C "$PR" checkout -q main
git -C "$PR" checkout -q -b feat-warn;  seq 1 1000 > "$PR/warn.txt";  git_q -C "$PR" add -A; git_q -C "$PR" commit -qm warn
git -C "$PR" checkout -q main
git -C "$PR" checkout -q -b feat-small; printf '1\n2\n3\n4\n5\n' > "$PR/small.txt"; git_q -C "$PR" add -A; git_q -C "$PR" commit -qm small
git -C "$PR" checkout -q main
add_origin "$PR"

GH_BIG='gh pr create --repo acme/x --base main --head feat-big --title "t" --body "b"'

run_hook "$PRSIZE_HOOK" "$(pre_payload Bash "$(jq -n --arg c "$GH_BIG" '{command: $c, description: "pr"}')" "$PR")"
if [ "$RC" -eq 2 ] && grep -q 'Phase 3.0: BLOCK' "$ERRF" && grep -q 'draft' "$ERRF"; then
  okc "P4a over-block-cap non-draft gh pr create → exit 2 deny (draft path named)"
else failc "P4a" "rc=$RC err=$(head -c200 "$ERRF")"; fi

run_hook "$PRSIZE_HOOK" "$(pre_payload Bash "$(jq -n --arg c "$GH_BIG --draft" '{command: $c, description: "pr"}')" "$PR")"
if [ "$RC" -eq 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "allow"' "$OUTF" >/dev/null 2>&1 \
   && grep -q 'Phase 3.0: BLOCK' "$OUTF" && grep -q 'blocked' "$OUTF"; then
  okc "P4b same diff with --draft → allowed, BLOCK verdict injected (§3.0 escape path)"
else failc "P4b" "rc=$RC out=$(head -c200 "$OUTF")"; fi

run_hook "$PRSIZE_HOOK" "$(pre_payload Bash "$(jq -n '{command: "gh pr create --base main --head feat-small -t x -b y", description: "pr"}')" "$PR")"
if [ "$RC" -eq 0 ] && grep -q 'Phase 3.0: PASS' "$OUTF"; then
  okc "P4c small diff → allow + PASS verdict injected"
else failc "P4c" "rc=$RC out=$(head -c200 "$OUTF")"; fi

run_hook "$PRSIZE_HOOK" "$(pre_payload Bash "$(jq -n '{command: "gh pr create --base main --head feat-warn", description: "pr"}')" "$PR")"
if [ "$RC" -eq 0 ] && grep -q 'Phase 3.0: WARN' "$OUTF"; then
  okc "P4d over-warn diff → allow + WARN verdict injected"
else failc "P4d" "rc=$RC out=$(head -c200 "$OUTF")"; fi

run_hook "$PRSIZE_HOOK" "$(pre_payload Bash "$(jq -n '{command: "glab mr create -R acme/x --target-branch main --source-branch feat-big", description: "mr"}')" "$PR")"
if [ "$RC" -eq 2 ] && grep -q 'Phase 3.0: BLOCK' "$ERRF"; then
  okc "P4e glab mr create over cap → exit 2 deny"
else failc "P4e" "rc=$RC err=$(head -c200 "$ERRF")"; fi

run_hook "$PRSIZE_HOOK" "$(pre_payload Bash "$(jq -n '{command: "gh pr list --state open", description: "list"}')" "$PR")"
NOOP1_RC=$RC; NOOP1_SZ=$(wc -c < "$OUTF")
run_hook "$PRSIZE_HOOK" "$(pre_payload Bash "$(jq -n '{command: "echo hi", description: "echo"}')" "$PR")"
if [ "$NOOP1_RC" -eq 0 ] && [ "$NOOP1_SZ" -eq 0 ] && [ "$RC" -eq 0 ] && [ ! -s "$OUTF" ]; then
  okc "P4f non-create commands (gh pr list, echo) → no-op"
else failc "P4f" "rc=$NOOP1_RC/$RC"; fi

run_hook "$PRSIZE_HOOK" "$(pre_payload Bash "$(jq -n --arg c "cd $PR && $GH_BIG" '{command: $c, description: "pr"}')" "$SB")"
if [ "$RC" -eq 2 ] && grep -q 'Phase 3.0: BLOCK' "$ERRF"; then
  okc "P4g leading 'cd <worktree> &&' from foreign cwd → repo resolved, deny"
else failc "P4g" "rc=$RC err=$(head -c200 "$ERRF")"; fi

NOBASE="$SB/nobase"
mkdir -p "$NOBASE"; git -C "$NOBASE" init -q; git -C "$NOBASE" checkout -q -b trunk
echo x > "$NOBASE/f"; git_q -C "$NOBASE" add -A; git_q -C "$NOBASE" commit -qm x
run_hook "$PRSIZE_HOOK" "$(pre_payload Bash "$(jq -n '{command: "gh pr create --title t --body b", description: "pr"}')" "$NOBASE")"
if [ "$RC" -eq 0 ] && [ ! -s "$OUTF" ]; then okc "P4h no resolvable base ref → fail-open allow"
else failc "P4h" "rc=$RC out=$(head -c200 "$OUTF")"; fi

mkdir -p "$PR/.claude/do"
printf '{"pr_size":{"block_lines":10000,"block_files":100}}\n' > "$PR/.claude/do/config.json"
run_hook "$PRSIZE_HOOK" "$(pre_payload Bash "$(jq -n --arg c "$GH_BIG" '{command: $c, description: "pr"}')" "$PR")"
if [ "$RC" -eq 0 ] && grep -q 'Phase 3.0: WARN' "$OUTF"; then
  okc "P4i project config raises block cap → same diff now WARN, allowed"
else failc "P4i" "rc=$RC out=$(head -c200 "$OUTF")"; fi
rm -f "$PR/.claude/do/config.json"

# ============================================================== U. UNINSTALL
echo "U. uninstall.sh removes registrations"

HOME="$SB_HOME" bash "$SB_INSTALL/uninstall.sh" >"$SB/uninstall.log" 2>&1
if [ -f "$SETTINGS" ] \
   && ! grep -qE 'do-(metrics-stop-gate|plan-size-pretooluse|secret-scan-pretooluse|pr-size-pretooluse)\.sh' "$SETTINGS"; then
  okc "U1 all four hook entries stripped from settings.json"
else
  failc "U1" "hook entries still present (or settings gone) — see $SB/uninstall.log"
fi

# ------------------------------------------------------------------ summary
echo
echo "hook-live-sim: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED:$FAILED"
  KEEP=1
  exit 1
fi
exit 0
