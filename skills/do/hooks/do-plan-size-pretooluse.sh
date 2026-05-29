#!/bin/bash
# do-plan-size-pretooluse.sh — Claude Code **PreToolUse hook** (matcher: Task;
# harness-level enforcement tier, see references/hooks.md). OPT-IN.
#
# Purpose: surface the Phase 2.0 plan-size verdict at the moment the implementer
# sub-agent is spawned, so the size gate can't be silently skipped. Runs
# plan-size-check itself and injects the verdict as `additionalContext` (the
# model cannot not-see it). NON-BLOCKING by design: it never denies a spawn (a
# parse miss must not break legit Task uses) — REBUMP/SPLIT-REQUIRED handling
# stays the orchestrator's job per phase-2-implementation.md §2.0, this just
# makes the verdict impossible to miss.
#
# Acts ONLY when the spawn prompt carries the structured marker the /do Phase 2
# spawn emits:
#     PLAN-SIZE: files=<N> lines=<M> complexity=<T|L|M|H>
# No marker (any other Task spawn — Explore, code-review, etc.) → allow, no-op.
#
# Self-locating: finds the sibling plan-size-check via $0, so it works under any
# skill name / install path. jq or wrapper missing → silent allow (degradation).

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

HOOK_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P || echo "")
PLAN_SIZE_CHECK="$HOOK_DIR/../scripts/plan-size-check"

PROMPT=$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // .tool_input.description // ""' 2>/dev/null || true)
[ -z "$PROMPT" ] && exit 0

LINE=$(printf '%s\n' "$PROMPT" | grep -oE 'PLAN-SIZE:[[:space:]]*files=[0-9]+[[:space:]]+lines=[0-9]+[[:space:]]+complexity=[TLMH]' | head -1 || true)
[ -z "$LINE" ] && exit 0   # no marker → allow, no-op

FILES=$(printf '%s' "$LINE" | sed -n 's/.*files=\([0-9]*\).*/\1/p')
LINES=$(printf '%s' "$LINE" | sed -n 's/.*lines=\([0-9]*\).*/\1/p')
CX=$(printf '%s'    "$LINE" | sed -n 's/.*complexity=\([TLMH]\).*/\1/p')
{ [ -z "$FILES" ] || [ -z "$LINES" ] || [ -z "$CX" ]; } && exit 0

[ -x "$PLAN_SIZE_CHECK" ] || exit 0
VERDICT=$("$PLAN_SIZE_CHECK" --current-complexity "$CX" --planned-files "$FILES" --planned-lines "$LINES" 2>/dev/null || true)
[ -z "$VERDICT" ] && exit 0

jq -n --arg v "$VERDICT" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    additionalContext: ("[plan-size-check / PreToolUse hook] " + $v + "  — if this is REBUMP or SPLIT-REQUIRED, resolve it per phase-2-implementation.md §2.0 BEFORE relying on this spawn (do not implement at the wrong tier; SPLIT-REQUIRED means split into sub-issues first).")
  }
}'
exit 0
