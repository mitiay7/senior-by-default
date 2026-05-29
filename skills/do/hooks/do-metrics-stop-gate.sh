#!/bin/bash
# do-metrics-stop-gate.sh — Claude Code **Stop hook** (harness-level enforcement
# tier; see references/hooks.md). OPT-IN — not installed by default.
#
# Purpose: the wrapper + announce-coupling in Phase 4.11/4.13 make metrics-skip
# rare but still model-dependent (the orchestrator can write a prose announce and
# stop). This hook is the harness backstop: the Claude Code runtime runs it on
# every Stop, and it BLOCKS the stop when a /do finalize turn lacks a valid,
# file-backed `Metrics:` line — making emission non-bypassable.
#
# SELF-SCOPING (critical — this is why it's safe to register globally): the hook
# is a NO-OP on any turn that doesn't carry the /do final-announce signature
# (`Complete. Branch:` or `Models: orchestrator=`). Normal Q&A, other skills, and
# non-/do work never match → never blocked.
#
# Decision protocol (Claude Code Stop hook): read JSON on stdin, emit
# {"decision":"block","reason":"..."} on stdout with exit 0 to block the stop;
# exit 0 with no output to allow it. `stop_hook_active` guards against loops.
#
# Graceful degradation: any uncertainty (no last message, unrecognized Metrics
# form, jq missing) → exit 0 (allow). The hook only ever blocks on a POSITIVE
# detection of a /do finalize that is missing/contradicted by its metrics claim.

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0   # no jq → cannot evaluate → allow

jqr() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null || true; }

# Loop guard: if we already blocked this turn, allow the stop now.
[ "$(jqr '.stop_hook_active')" = "true" ] && exit 0

MSG=$(jqr '.last_assistant_message')

# Fallback: derive the last assistant text from the transcript if the field is
# absent on this runtime. Best-effort; empty result → safe no-op below.
if [ -z "$MSG" ] || [ "$MSG" = "null" ]; then
  TP=$(jqr '.transcript_path'); TP="${TP/#\~/$HOME}"
  if [ -n "$TP" ] && [ -f "$TP" ]; then
    MSG=$(tail -80 "$TP" 2>/dev/null \
      | jq -r 'select((.type // .role) == "assistant")
               | (.message.content // .content // .text // [])
               | if type=="array" then (map(select(.type=="text").text) | join("\n"))
                 elif type=="string" then . else "" end' 2>/dev/null \
      | tail -40 || true)
  fi
fi
[ -z "$MSG" ] && exit 0   # nothing to inspect → allow

# /do finalize signature. Neither present → not a /do finalize turn → allow.
printf '%s\n' "$MSG" | grep -qE '^(Complete\. Branch:|Models: orchestrator=)' || exit 0

METRICS_LINE=$(printf '%s\n' "$MSG" | grep -E '^Metrics:' | tail -1)

if [ -z "$METRICS_LINE" ]; then
  jq -n '{decision:"block", reason:"senior-by-default Phase 4.13: this is a /do finalize turn (announce present) but there is NO `Metrics:` line at the end. Do NOT compose a prose announce — run the §4.13 metrics-emit bash flow verbatim (it sets and prints $METRICS_LINE via ~/.claude/skills/do/scripts/metrics-append). See references/phase-4-finalize.md and anti-pattern §19."}'
  exit 0
fi

# Terminal states already surfaced to the user — do not re-block.
case "$METRICS_LINE" in
  "Metrics: not configured"*) exit 0 ;;
  "Metrics: APPEND FAILED"*)  exit 0 ;;
esac

# "Metrics: <N> entries in <path>" — verify the claim is backed by the real file
# (promotes the wrapper's pre/post line-count tell to harness-level enforcement).
N=$(printf '%s\n' "$METRICS_LINE" | sed -n 's/^Metrics:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*entries.*/\1/p')
PATHV=$(printf '%s\n' "$METRICS_LINE" | sed -n 's/^Metrics:.*entries in \(.*\)$/\1/p')
PATHV="${PATHV%.}"; PATHV="${PATHV/#\~/$HOME}"

# Unrecognized Metrics: form → don't risk a false block.
{ [ -z "$N" ] || [ -z "$PATHV" ]; } && exit 0

if [ ! -f "$PATHV" ]; then
  jq -n --arg l "$METRICS_LINE" --arg p "$PATHV" '{decision:"block", reason:("senior-by-default Phase 4.13: the announce claims `" + $l + "` but the log file " + $p + " does not exist — the Metrics line was composed by hand, metrics-append never ran. Emit via ~/.claude/skills/do/scripts/metrics-append (the §4.13 flow). Anti-pattern §19/§19a.")}'
  exit 0
fi

ACTUAL=$(wc -l < "$PATHV" 2>/dev/null | tr -d ' '); ACTUAL="${ACTUAL:-0}"
if [ "$ACTUAL" -lt "$N" ]; then
  jq -n --arg l "$METRICS_LINE" --arg a "$ACTUAL" --arg n "$N" '{decision:"block", reason:("senior-by-default Phase 4.13: the announce claims " + $n + " entries but the log actually has " + $a + " lines — the entry was NOT appended this turn (fabricated or silently-failed Metrics line). Re-run the §4.13 metrics-append emit and use its real OK output.")}'
  exit 0
fi

exit 0
