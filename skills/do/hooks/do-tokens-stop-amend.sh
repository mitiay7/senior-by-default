#!/bin/bash
# do-tokens-stop-amend.sh — Claude Code **Stop hook** (harness-level tier; see
# references/hooks.md). OPT-IN — not installed by default.
#
# Purpose: close the token-accounting loop that v0.10.0 opened. `metrics-append
# --tokens-in/--tokens-out` can record per-run usage, but NO in-session actor
# can read its own usage (/cost is TUI-only; a sub-agent can't see its usage;
# headless JSON usage lands after the session ends). The ONLY actor that ever
# sees harness-recorded usage is a hook: Claude Code hands a Stop hook the
# `transcript_path`, and the transcript's assistant records carry
# `message.usage`. This hook sums those and amends the run's telemetry entry
# with a `tokens` object — the honest, measured figure the estimate ban demands.
#
# NEVER blocks. Unlike do-metrics-stop-gate.sh (which enforces that a Metrics
# line exists), this hook only ENRICHES an already-written entry. It emits no
# decision; every failure path is a silent exit 0 (telemetry enrichment must
# never wedge a Stop).
#
# SELF-SCOPING (why it's safe to register globally): identical guard to the
# metrics gate — a no-op on any turn that lacks the /do final-announce
# signature (`Complete. Branch:` / `Models: orchestrator=`), a no-op on a turn
# that QUOTES the §4.13 spec (unexpanded placeholders), and `stop_hook_active`
# guards the loop. IDEMPOTENT: once the entry has a `tokens` key the wrapper
# REJECTs the second amend and this hook swallows it — a re-fired Stop is clean.
#
# LOCKSTEP INVARIANT: the announce parser understands exactly the `Metrics:`
# forms the §4.13 bash flow emits. Change that format and update this hook +
# do-metrics-stop-gate.sh together.

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0   # no jq → cannot evaluate → no-op

SCRIPTS_DIR=$(cd "$(dirname "$0")/../scripts" 2>/dev/null && pwd -P || echo "")
METRICS_APPEND="$SCRIPTS_DIR/metrics-append"
[ -x "$METRICS_APPEND" ] || exit 0   # can't amend without the wrapper → no-op

jqr() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null || true; }

# Loop guard.
[ "$(jqr '.stop_hook_active')" = "true" ] && exit 0

MSG=$(jqr '.last_assistant_message')
TP=$(jqr '.transcript_path'); TP="${TP/#\~/$HOME}"

# Fallback: derive the last assistant text from the transcript if the field is
# absent on this runtime (same best-effort as the metrics gate).
if [ -z "$MSG" ] || [ "$MSG" = "null" ]; then
  if [ -n "$TP" ] && [ -f "$TP" ]; then
    MSG=$(tail -80 "$TP" 2>/dev/null \
      | jq -r 'select((.type // .role) == "assistant")
               | (.message.content // .content // .text // [])
               | if type=="array" then (map(select(.type=="text").text) | join("\n"))
                 elif type=="string" then . else "" end' 2>/dev/null \
      | tail -40 || true)
  fi
fi
[ -z "$MSG" ] && exit 0

# /do finalize signature. Neither present → not a /do finalize turn → no-op.
printf '%s\n' "$MSG" | grep -qE '^(Complete\. Branch:|Models: orchestrator=)' || exit 0

# Template-quoting guard: a message carrying unexpanded §4.13 variables is
# quoting/editing the spec, not announcing a finalize.
printf '%s' "$MSG" | grep -qE '\$(\{)?(METRICS_LINE|METRICS_RESULT|POST_COUNT|EXPECTED|BRANCH_NAME|BRANCH_LINE|ORCHESTRATOR_MODEL)' && exit 0

# Need a transcript to sum usage from — no transcript path, no enrichment.
[ -n "$TP" ] && [ -f "$TP" ] || exit 0

# Parse the log path out of the Metrics line (closed set — §4.13). Terminal
# states (not configured / APPEND FAILED) carry no usable path → no-op.
METRICS_LINE=$(printf '%s\n' "$MSG" | grep -E '^Metrics:' | tail -1)
[ -n "$METRICS_LINE" ] || exit 0
case "$METRICS_LINE" in
  "Metrics: not configured"*) exit 0 ;;
  "Metrics: APPEND FAILED"*)  exit 0 ;;
esac
LINE="${METRICS_LINE%.}"
LINE=$(printf '%s\n' "$LINE" | sed 's/ (pre=[0-9][0-9]* gates=[0-9][0-9]*)$//')
PATHV=$(printf '%s\n' "$LINE" | sed -n 's/^Metrics:[[:space:]]*[0-9][0-9]*[[:space:]]*entries in \(..*\)$/\1/p')
PATHV="${PATHV/#\~/$HOME}"
[ -n "$PATHV" ] && [ -f "$PATHV" ] || exit 0

# Find the target entry: the LAST log entry whose .ref appears in the announce
# text AND which has no `tokens` key yet. Ref-match (not "last line") is what
# makes this correct under concurrent same-log sessions. None found → no-op
# (already amended, or the announce references no on-log ref).
TARGET_REF=""
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  printf '%s' "$MSG" | grep -qF -- "$ref" || continue
  TARGET_REF="$ref"   # keep scanning; last match on-file wins
done < <(jq -r 'select(has("tokens") | not) | .ref // empty' "$PATHV" 2>/dev/null || true)
[ -n "$TARGET_REF" ] || exit 0

# Grab the entry's time window to bound the transcript sum. Pad generously:
# 120s before started_at (Phase 0 preflight vs first model turn) and 900s after
# ended_at (finalize bash + this Stop). If timestamps are unusable, sum the
# whole transcript — over-counting a single-task session is acceptable; the
# window only matters when several tasks share one transcript, which /do runs
# do not (one worktree session per task).
ENTRY=$(jq -c --arg r "$TARGET_REF" 'select(.ref==$r) | {started_at, ended_at}' "$PATHV" 2>/dev/null | tail -1 || true)
S_AT=$(printf '%s' "$ENTRY" | jq -r '.started_at // empty' 2>/dev/null || true)
E_AT=$(printf '%s' "$ENTRY" | jq -r '.ended_at // empty' 2>/dev/null || true)

# Convert ISO-8601 UTC to epoch (BSD `date -j -f` and GNU `date -d` dialects).
iso2epoch() {
  local iso="$1" e=""
  [ -n "$iso" ] || { echo ""; return; }
  e=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null) \
    || e=$(date -u -d "$iso" +%s 2>/dev/null) || e=""
  echo "$e"
}
LO=$(iso2epoch "$S_AT"); HI=$(iso2epoch "$E_AT")
[ -n "$LO" ] && LO=$((LO - 120))
[ -n "$HI" ] && HI=$((HI + 900))

# Sum harness-recorded usage across transcript assistant records in the window.
# in  = input + cache_creation + cache_read (all billed input); out = output.
# A record without a parseable timestamp is counted when either bound is unset
# (whole-transcript mode) and skipped only when it falls outside a known bound.
SUMS=$(jq -sr --arg lo "${LO:-}" --arg hi "${HI:-}" '
  ([ .[]
     | select((.type // .role) == "assistant")
     | . as $rec
     | (.message.usage // .usage // empty) as $u
     | select($u != null)
     | ((.timestamp // .ts // "") ) as $tsraw
     | ($tsraw | if type=="string" and (test("^[0-9]{4}-")) then
           (try (sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) catch null)
         else null end) as $ts
     | select(
         ($lo == "" and $hi == "")
         or ($ts == null)
         or (($lo == "" or $ts >= ($lo|tonumber)) and ($hi == "" or $ts <= ($hi|tonumber)))
       )
     | {
         tin: (( $u.input_tokens // 0 ) + ( $u.cache_creation_input_tokens // 0 ) + ( $u.cache_read_input_tokens // 0 )),
         tout: ( $u.output_tokens // 0 )
       }
   ]) as $rows
  | { in: ([$rows[].tin] | add // 0), out: ([$rows[].tout] | add // 0) }
  | "\(.in) \(.out)"
' "$TP" 2>/dev/null || true)

TIN=$(printf '%s' "$SUMS" | awk '{print $1}')
TOUT=$(printf '%s' "$SUMS" | awk '{print $2}')
[[ "$TIN"  =~ ^[0-9]+$ ]] || TIN=0
[[ "$TOUT" =~ ^[0-9]+$ ]] || TOUT=0
# Nothing measured (empty/zero transcript window) → don't write a misleading
# {in:0,out:0}. Absence stays honest.
[ "$TIN" -eq 0 ] && [ "$TOUT" -eq 0 ] && exit 0

# Amend. Silent on any wrapper result — this hook never blocks a Stop.
"$METRICS_APPEND" --amend-tokens --log "$PATHV" --ref "$TARGET_REF" \
  --tokens-in "$TIN" --tokens-out "$TOUT" >/dev/null 2>&1 || true

exit 0
