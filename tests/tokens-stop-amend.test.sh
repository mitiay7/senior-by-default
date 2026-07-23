#!/usr/bin/env bash
# `cond && ok "…" || bad "…"` is a deliberate assert idiom throughout this file —
# `ok`/`bad` always return 0, so the SC2015 false-C-after-true-B footgun can't fire.
# shellcheck disable=SC2015
#
# Regression test for the token-usage Stop-hook amend loop (issue #1):
#   - `metrics-append --amend-tokens` adds a tokens object to an existing entry,
#     refuses to overwrite one, and picks the LAST entry matching --ref;
#   - `do-tokens-stop-amend.sh` self-scopes (no-op off a /do finalize turn, no-op
#     on a spec-quoting turn), sums transcript usage into the right entry by ref,
#     is idempotent on a second fire, and never blocks.
#
# Self-contained: builds synthetic JSONL logs + synthetic transcripts under a
# temp dir, feeds the hook JSON on stdin exactly as Claude Code does. No network.
# Run: bash tests/tokens-stop-amend.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPEND="$SCRIPT_DIR/../skills/do/scripts/metrics-append"
HOOK="$SCRIPT_DIR/../skills/do/hooks/do-tokens-stop-amend.sh"
[ -x "$APPEND" ] || { echo "FATAL: metrics-append not found/executable at $APPEND"; exit 1; }
[ -x "$HOOK" ]   || { echo "FATAL: do-tokens-stop-amend.sh not found/executable at $HOOK"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

# --- helpers ---------------------------------------------------------------
# A minimal-but-schema-valid appended entry for ref $1 in log $2, started/ended $3/$4.
mk_entry() {
  "$APPEND" --log "$2" --ref "$1" --complexity M --implementer sonnet \
    --outcome merged --started-at "$3" --ended-at "$4" \
    --files-changed 1 --lines-added 1 --lines-deleted 0 \
    --sr-performed true --sr-claimed ready >/dev/null 2>&1
}
# An assistant transcript record with usage, at timestamp $1, in=$2/out(split)
# We encode in as input_tokens for simplicity; the hook sums input+cache+cache_read.
mk_usage_line() {
  jq -cn --arg ts "$1" --argjson it "$2" --argjson cc "$3" --argjson cr "$4" --argjson ot "$5" \
    '{type:"assistant", timestamp:$ts,
      message:{usage:{input_tokens:$it, cache_creation_input_tokens:$cc, cache_read_input_tokens:$cr, output_tokens:$ot}}}'
}
tokens_of() { jq -rc --arg r "$1" 'select(.ref==$r) | .tokens // "NONE"' "$2" | tail -1; }

echo "TEST 1 — wrapper --amend-tokens happy path"
LOG="$WORK/t1.jsonl"
mk_entry i100 "$LOG" 2026-07-23T08:00:00Z 2026-07-23T08:20:00Z
OUT=$("$APPEND" --amend-tokens --log "$LOG" --ref i100 --tokens-in 111 --tokens-out 22 2>&1)
RC=$?
[ $RC -eq 0 ] && ok "exit 0" || bad "exit $RC ($OUT)"
case "$OUT" in "OK amended ref=i100"*) ok "OK line shape" ;; *) bad "OK line: $OUT" ;; esac
T=$(tokens_of i100 "$LOG")
[ "$(echo "$T" | jq -c .)" = '{"in":111,"out":22}' ] && ok "tokens {in:111,out:22} written" || bad "tokens = $T"
# nothing else changed
[ "$(jq -r 'select(.ref=="i100") | .complexity' "$LOG")" = "M" ] && ok "other fields intact" || bad "other fields mutated"
LINES=$(grep -c '' "$LOG"); [ "$LINES" -eq 1 ] && ok "line count unchanged (1)" || bad "line count $LINES"

echo "TEST 2 — refuse to overwrite an existing tokens object"
OUT=$("$APPEND" --amend-tokens --log "$LOG" --ref i100 --tokens-in 999 --tokens-out 999 2>&1); RC=$?
[ $RC -eq 1 ] && ok "exit 1 (REJECT)" || bad "exit $RC"
case "$OUT" in *"already recorded"*) ok "REJECT reason mentions already-recorded" ;; *) bad "reason: $OUT" ;; esac
[ "$(tokens_of i100 "$LOG" | jq -c .)" = '{"in":111,"out":22}' ] && ok "original tokens preserved" || bad "tokens clobbered"

echo "TEST 3 — one flag alone is allowed; missing both rejects"
LOG3="$WORK/t3.jsonl"; mk_entry i101 "$LOG3" 2026-07-23T08:00:00Z 2026-07-23T08:10:00Z
"$APPEND" --amend-tokens --log "$LOG3" --ref i101 --tokens-out 50 >/dev/null 2>&1 \
  && [ "$(tokens_of i101 "$LOG3" | jq -c .)" = '{"out":50}' ] && ok "out-only amend → {out:50}" || bad "out-only amend"
LOG3b="$WORK/t3b.jsonl"; mk_entry i102 "$LOG3b" 2026-07-23T08:00:00Z 2026-07-23T08:10:00Z
"$APPEND" --amend-tokens --log "$LOG3b" --ref i102 >/dev/null 2>&1 && bad "no-flags accepted" || ok "no-flags rejected"

echo "TEST 4 — --ref picks the LAST matching entry (repeated ref across re-runs)"
LOG4="$WORK/t4.jsonl"
mk_entry i200 "$LOG4" 2026-07-23T07:00:00Z 2026-07-23T07:05:00Z
mk_entry i200 "$LOG4" 2026-07-23T09:00:00Z 2026-07-23T09:05:00Z
"$APPEND" --amend-tokens --log "$LOG4" --ref i200 --tokens-in 7 --tokens-out 7 >/dev/null 2>&1
FIRST=$(jq -r 'select(.ref=="i200")' "$LOG4" | jq -sr '.[0].tokens // "NONE"')
LAST=$(jq -r 'select(.ref=="i200")' "$LOG4" | jq -sr '.[1].tokens | @json')
[ "$FIRST" = "NONE" ] && ok "first i200 untouched" || bad "first got $FIRST"
[ "$LAST" = '{"in":7,"out":7}' ] && ok "last i200 amended" || bad "last got $LAST"

echo "TEST 5 — unknown ref / missing log reject"
"$APPEND" --amend-tokens --log "$LOG4" --ref nope --tokens-in 1 >/dev/null 2>&1 && bad "unknown ref accepted" || ok "unknown ref rejected"
"$APPEND" --amend-tokens --log "$WORK/nosuch.jsonl" --ref i1 --tokens-in 1 >/dev/null 2>&1 && bad "missing log accepted" || ok "missing log rejected"

echo "TEST 6 — estimate ban: non-integer token values reject"
LOG6="$WORK/t6.jsonl"; mk_entry i300 "$LOG6" 2026-07-23T08:00:00Z 2026-07-23T08:10:00Z
"$APPEND" --amend-tokens --log "$LOG6" --ref i300 --tokens-in 1.5 >/dev/null 2>&1 && bad "float accepted" || ok "float rejected"
"$APPEND" --amend-tokens --log "$LOG6" --ref i300 --tokens-in abc >/dev/null 2>&1 && bad "non-int accepted" || ok "non-int rejected"

# --- Hook end-to-end -------------------------------------------------------
# Build a finalize announce message + a transcript with usage, feed the hook.
mk_announce() {
  # $1 = ref to reference in the announce
  cat <<EOF
Complete. Branch: feat/${1}-thing pushed.

Metrics: 1 entries in LOGPATH (pre=0 gates=3).
EOF
}
feed_hook() { # $1 = announce message, $2 = transcript path → runs hook with stdin JSON
  jq -cn --arg m "$1" --arg tp "$2" '{last_assistant_message:$m, transcript_path:$tp, stop_hook_active:false}' | "$HOOK"
}

echo "TEST 7 — hook amends the ref-matched entry from transcript usage"
LOG7="$WORK/t7.jsonl"
mk_entry i400 "$LOG7" 2026-07-23T08:00:00Z 2026-07-23T08:30:00Z
TR7="$WORK/t7.transcript.jsonl"
{
  mk_usage_line 2026-07-23T08:05:00Z 100 200 300 40   # in=600 out=40
  mk_usage_line 2026-07-23T08:10:00Z 10 0 0 5          # in=10  out=5
} > "$TR7"
ANN=$(mk_announce i400); ANN="${ANN/LOGPATH/$LOG7}"
feed_hook "$ANN" "$TR7" >/dev/null 2>&1
T=$(tokens_of i400 "$LOG7" | jq -c .)
[ "$T" = '{"in":610,"out":45}' ] && ok "summed in=610 out=45 (input+cache+cache_read)" || bad "got $T"

echo "TEST 8 — hook is idempotent on a second fire"
feed_hook "$ANN" "$TR7" >/dev/null 2>&1
LINES=$(grep -c '' "$LOG7")
[ "$LINES" -eq 1 ] && [ "$(tokens_of i400 "$LOG7" | jq -c .)" = '{"in":610,"out":45}' ] \
  && ok "second fire no-op (count 1, tokens unchanged)" || bad "second fire mutated (lines=$LINES)"

echo "TEST 9 — hook no-op off a /do finalize turn"
LOG9="$WORK/t9.jsonl"; mk_entry i500 "$LOG9" 2026-07-23T08:00:00Z 2026-07-23T08:30:00Z
feed_hook "Sure, here is the summary of your code review." "$TR7" >/dev/null 2>&1
[ "$(tokens_of i500 "$LOG9")" = "NONE" ] && ok "non-finalize turn ignored" || bad "amended off a non-finalize turn"

echo "TEST 10 — hook no-op on a spec-quoting turn (unexpanded placeholders)"
LOG10="$WORK/t10.jsonl"; mk_entry i600 "$LOG10" 2026-07-23T08:00:00Z 2026-07-23T08:30:00Z
QUOTE=$(printf 'Complete. Branch: feat/i600-x\n\nThe announce prints Metrics: $METRICS_LINE at the end.\nMetrics: 1 entries in %s.' "$LOG10")
feed_hook "$QUOTE" "$TR7" >/dev/null 2>&1
[ "$(tokens_of i600 "$LOG10")" = "NONE" ] && ok "spec-quoting turn ignored" || bad "amended a spec quote"

echo "TEST 11 — hook picks the announce's ref among concurrent-session entries"
LOG11="$WORK/t11.jsonl"
mk_entry i700 "$LOG11" 2026-07-23T08:00:00Z 2026-07-23T08:30:00Z   # other session's entry
mk_entry i701 "$LOG11" 2026-07-23T08:00:00Z 2026-07-23T08:30:00Z   # this run's entry
ANN2=$(mk_announce i701); ANN2="${ANN2/LOGPATH/$LOG11}"
feed_hook "$ANN2" "$TR7" >/dev/null 2>&1
[ "$(tokens_of i700 "$LOG11")" = "NONE" ] && ok "unreferenced entry i700 untouched" || bad "amended the wrong entry"
[ "$(tokens_of i701 "$LOG11" | jq -c .)" = '{"in":610,"out":45}' ] && ok "referenced entry i701 amended" || bad "referenced entry not amended"

echo "TEST 12 — hook never emits a block decision"
LOG12="$WORK/t12.jsonl"; mk_entry i800 "$LOG12" 2026-07-23T08:00:00Z 2026-07-23T08:30:00Z
ANN3=$(mk_announce i800); ANN3="${ANN3/LOGPATH/$LOG12}"
OUT=$(feed_hook "$ANN3" "$TR7" 2>/dev/null)
case "$OUT" in *'"decision"'*'"block"'*) bad "hook emitted a block decision" ;; *) ok "no block decision emitted" ;; esac

echo
echo "──────────────────────────────────────────"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
