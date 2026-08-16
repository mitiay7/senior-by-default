#!/bin/bash
# do-metrics-stop-gate.sh — Claude Code **Stop hook** (harness-level enforcement
# tier; see references/hooks.md). OPT-IN — not installed by default.
#
# Purpose: the wrapper + announce-coupling in Phase 4.11/4.13 make metrics-skip
# rare but still model-dependent (the orchestrator can write a prose announce and
# stop). This hook is the harness-enforced backstop: the Claude Code runtime runs
# it on every Stop, and it BLOCKS the stop when a /do finalize turn lacks a
# valid, file-backed, fresh `Metrics:` line. Backstop, not a guarantee — it is
# opt-in and verifies the announce against the log file, nothing stronger.
#
# SELF-SCOPING (critical — this is why it's safe to register globally): the hook
# is a NO-OP on any turn that doesn't carry the /do final-announce signature
# (`Complete. Branch:` or `Models: orchestrator=`). Normal Q&A, other skills, and
# non-/do work never match → never blocked. A turn that QUOTES the §4.13 spec
# (docs work on the skill itself) carries UNEXPANDED placeholders
# (`$BRANCH_NAME`, `${METRICS_LINE}`, …) and is also a no-op — a real announce
# ships expanded values only. This placeholder guard is deliberately narrower
# than a cwd-based self-repo guard, which would also disable the backstop for
# genuine /do runs on this repo.
#
# Decision protocol (Claude Code Stop hook): read JSON on stdin, emit
# {"decision":"block","reason":"..."} on stdout with exit 0 to block the stop;
# exit 0 with no output to allow it. `stop_hook_active` guards against loops.
#
# Graceful degradation: genuine uncertainty (no last message, jq missing,
# unreadable mtime) → exit 0 (allow). The hook only ever blocks on a POSITIVE
# detection: metrics claim missing, outside the closed set of §4.13 forms,
# contradicted by the file, internally inconsistent, or stale.
#
# LOCKSTEP INVARIANT: the parsers below understand exactly the announce forms
# the §4.13 bash flow emits (references/phase-4-finalize.md). Change the
# announce format and this hook TOGETHER — drift either false-blocks every
# legitimate run (a tell appended after the path breaks the path parse) or
# silently disables verification (a tell inserted before "in" empties it).

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0   # no jq → cannot evaluate → allow

# Self-locate the sibling metrics-append for the remediation messages (same $0
# pattern as do-plan-size-pretooluse.sh) — NEVER a hardcoded install path:
# plugin installs and renamed SKILL_NAMEs have no ~/.claude/skills/do/, and a
# wrong remediation path would send the orchestrator to a nonexistent wrapper.
SCRIPTS_DIR=$(cd "$(dirname "$0")/../scripts" 2>/dev/null && pwd -P || echo "")
if [ -n "$SCRIPTS_DIR" ]; then
  METRICS_APPEND="$SCRIPTS_DIR/metrics-append"
else
  METRICS_APPEND="the metrics-append wrapper (sibling scripts/ dir of this hook)"
fi

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
#
# These are English literals and stay English literals: the §4.13 announce is a
# PROTOCOL block, mandated to be emitted verbatim regardless of the session's
# language (phase-4-finalize.md §"The announce is a protocol, not prose"). A
# translated announce reads as "not a finalize turn" here and this gate allows
# it — the enforcement disappears silently, which is precisely the §19a
# direct-write bypass it exists to catch. Do NOT try to fix that by guessing at
# translations; fix it upstream by emitting the block as written. (The sibling
# token hook additionally triggers on the machine-readable `Metrics:` line,
# which carries no translatable words — that widening is safe there because it
# only ever ENRICHES; widening an enforcement trigger is a different risk.)
printf '%s\n' "$MSG" | grep -qE '^(Complete\. Branch:|Models: orchestrator=)' || exit 0

# Template-quoting guard (false-positive fix): a message carrying unexpanded
# §4.13 variables is quoting/editing the spec, not announcing a finalize.
# BRANCH_NAME/BRANCH_LINE cover the current spec; EXPECTED covers pre-§19j
# spec quotes (kept — dropping it would re-enable the false positive on
# docs work against older checkouts).
printf '%s' "$MSG" | grep -qE '\$(\{)?(METRICS_LINE|METRICS_RESULT|POST_COUNT|EXPECTED|BRANCH_NAME|BRANCH_LINE|ORCHESTRATOR_MODEL)' && exit 0

METRICS_LINE=$(printf '%s\n' "$MSG" | grep -E '^Metrics:' | tail -1)

if [ -z "$METRICS_LINE" ]; then
  jq -n --arg w "$METRICS_APPEND" '{decision:"block", reason:("senior-by-default Phase 4.13: this is a /do finalize turn (announce present) but there is NO `Metrics:` line at the end. Do NOT compose a prose announce — run the §4.13 metrics-emit bash flow verbatim (it sets and prints $METRICS_LINE via " + $w + "). See references/phase-4-finalize.md and anti-pattern §19.")}'
  exit 0
fi

# Terminal states already surfaced to the user — do not re-block.
case "$METRICS_LINE" in
  "Metrics: not configured"*) exit 0 ;;
  "Metrics: APPEND FAILED"*)  exit 0 ;;
esac

# Only one legal form remains (CLOSED set — §4.13 emits exactly three):
#   "Metrics: <N> entries in <path> (pre=<p> gates=<g>)"   (current spec)
#   "Metrics: <N> entries in <path>"                       (pre-tell installs)
# The announce heredoc appends a trailing period; strip one before parsing.
LINE="${METRICS_LINE%.}"

# Optional wrapper tell carried into the announce: " (pre=<p> gates=<g>)".
PRE=$(printf '%s\n' "$LINE" | sed -n 's/^Metrics:.* (pre=\([0-9][0-9]*\) gates=[0-9][0-9]*)$/\1/p')
CORE="$LINE"
[ -n "$PRE" ] && CORE=$(printf '%s\n' "$LINE" | sed 's/ (pre=[0-9][0-9]* gates=[0-9][0-9]*)$//')

N=$(printf '%s\n' "$CORE" | sed -n 's/^Metrics:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*entries in ..*$/\1/p')
PATHV=$(printf '%s\n' "$CORE" | sed -n 's/^Metrics:[[:space:]]*[0-9][0-9]*[[:space:]]*entries in \(..*\)$/\1/p')
PATHV="${PATHV/#\~/$HOME}"

# Closed set: an unparseable `Metrics:` line is a POSITIVE detection, not
# uncertainty — no §4.13 bash path emits any other form. Hand-composed variants
# ("Metrics: skipped — <reason>", prose restatements) land here; the old
# fallthrough-allow at this point was a documented bypass.
if [ -z "$N" ] || [ -z "$PATHV" ]; then
  jq -n --arg l "$METRICS_LINE" '{decision:"block", reason:("senior-by-default Phase 4.13: `" + $l + "` matches none of the three forms the §4.13 bash flow emits (`Metrics: <N> entries in <path> (pre=<p> gates=<g>)`, `Metrics: APPEND FAILED — <reason>`, `Metrics: not configured …`). No bash path emits this line — it was composed by hand; there is no `Metrics: skipped` form. Run the §4.13 metrics-emit flow verbatim and use its real output. Anti-pattern §19/§19a.")}'
  exit 0
fi

# Tell consistency: under the wrapper's log lock a single append yields
# post = pre + 1; since audit #18 the delta is informational (content verify is
# authoritative), so tolerate N > pre + 1 — a non-wrapper writer inside the
# window, rare and already flagged on the wrapper's stderr. N < pre + 1 stays a
# POSITIVE detection: a hand-composed tell copied from a stale `wc -l`
# typically writes pre == N — caught here.
if [ -n "$PRE" ] && [ "$((10#$PRE + 1))" -gt "$N" ]; then
  jq -n --arg l "$METRICS_LINE" '{decision:"block", reason:("senior-by-default Phase 4.13: `" + $l + "` is internally inconsistent — metrics-append guarantees post >= pre + 1 for a single append, so this tell was not produced by the wrapper (a genuine run never reports a count at or below its own pre). Re-run the §4.13 emit and use its real OK output. Anti-pattern §19/§19a.")}'
  exit 0
fi

if [ ! -f "$PATHV" ]; then
  jq -n --arg l "$METRICS_LINE" --arg p "$PATHV" --arg w "$METRICS_APPEND" '{decision:"block", reason:("senior-by-default Phase 4.13: the announce claims `" + $l + "` but the log file " + $p + " does not exist — the Metrics line was composed by hand, metrics-append never ran. Emit via " + $w + " (the §4.13 flow). Anti-pattern §19/§19a.")}'
  exit 0
fi

# Count check. Deliberately -lt, not -ne: ACTUAL > N is legitimate (a concurrent
# /do session may append to the same log between this session's emit and Stop).
# Newline-tolerant count: `grep -c ''` matches every line INCLUDING an
# unterminated final one, where `wc -l` (which counts newline bytes) undercounts
# it by 1 — a log whose last write lost its trailing newline would false-BLOCK a
# truthful announce. (grep exits 1 on a 0-count empty file but still prints "0";
# the `|| true` keeps that output.)
ACTUAL=$(grep -c '' "$PATHV" 2>/dev/null || true); ACTUAL="${ACTUAL:-0}"
if [ "$ACTUAL" -lt "$N" ]; then
  jq -n --arg l "$METRICS_LINE" --arg a "$ACTUAL" --arg n "$N" '{decision:"block", reason:("senior-by-default Phase 4.13: the announce claims " + $n + " entries but the log actually has " + $a + " lines — the entry was NOT appended this turn (fabricated or silently-failed Metrics line). Re-run the §4.13 metrics-append emit and use its real OK output.")}'
  exit 0
fi

# Freshness cross-check: the count check only proves the file has >= N lines —
# not that THIS turn appended one (claiming N = the log's current `wc -l` with
# zero appends was the cheapest bypass). Fresh = the last JSONL entry's ref
# appears in the announce, OR the file was written within the last 30 minutes
# (the OR absorbs ref-format variance and concurrent-session appends).
# Unreadable mtime → allow (uncertainty never blocks).
FRESH=""
LAST_REF=$(tail -1 "$PATHV" 2>/dev/null | jq -r '.ref // empty' 2>/dev/null || true)
[ -n "$LAST_REF" ] && printf '%s' "$MSG" | grep -qF -- "$LAST_REF" && FRESH="ref"
if [ -z "$FRESH" ]; then
  MTIME=$(stat -f %m "$PATHV" 2>/dev/null) || MTIME=$(stat -c %Y "$PATHV" 2>/dev/null) || MTIME=""
  case "$MTIME" in *[!0-9]*) MTIME="" ;; esac   # neither stat dialect → unknown
  if [ -z "$MTIME" ]; then
    FRESH="unknown-mtime"
  elif [ "$(( $(date +%s) - MTIME ))" -le 1800 ]; then
    FRESH="mtime"
  fi
fi
if [ -z "$FRESH" ]; then
  jq -n --arg l "$METRICS_LINE" --arg p "$PATHV" '{decision:"block", reason:("senior-by-default Phase 4.13: the announce claims `" + $l + "` but " + $p + " is STALE — its last entry does not reference this task and the file has not been written in over 30 minutes. The line claims the log’s existing count without appending (anti-pattern §19/§19a). Re-run the §4.13 metrics-append emit and use its real OK output.")}'
  exit 0
fi

exit 0
