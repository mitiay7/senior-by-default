#!/usr/bin/env bash
# `cond && ok "…" || bad "…"` is a deliberate assert idiom throughout this file —
# `ok`/`bad` always return 0, so the SC2015 false-C-after-true-B footgun can't fire.
# shellcheck disable=SC2015
#
# Regression test for the v0.13.0 telemetry-integrity fixes. Every case here
# corresponds to a defect found by reading 93 production entries, not to a
# hypothetical:
#
#   1. `scope` was free text — 93 entries carried ELEVEN spellings of six
#      concepts (backend/Backend/B, Frontend/frontend/F, …), so any per-scope
#      aggregate split one bucket into three.
#   2. Duplicate entries — i1183 appears as a byte-identical line, i1233 twice
#      with different bodies. Every aggregate double-counted them.
#   3. `specialist_audit` with a real verdict alongside `specialist_iterations:
#      []` — self-contradictory, and silently absent from the specialist
#      aggregate. 14 of 34 audited runs; i1540 recorded "4 auditors" in the gate
#      details and `[]` here.
#   4. `blockers` written as bare strings instead of objects (i1233) — crashed
#      `.blockers[].category` consumers mid-report and scored as zero.
#   5. metrics-report's block% was `findings / appearances` — a ratio of two
#      different units, which printed `silent-failure-hunter 200%`.
#
# Self-contained: temp logs, real wrappers, no network.
# Run: bash tests/telemetry-integrity.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPEND="$SCRIPT_DIR/../skills/do/scripts/metrics-append"
REPORT="$SCRIPT_DIR/../skills/do/scripts/metrics-report"
[ -x "$APPEND" ] || { echo "FATAL: metrics-append not found/executable at $APPEND"; exit 1; }
[ -x "$REPORT" ] || { echo "FATAL: metrics-report not found/executable at $REPORT"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/t.jsonl"

pass=0; fail=0
ok()  { printf '    ok  — %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '    FAIL — %s\n' "$1"; fail=$((fail+1)); }

# add <ref> <started_at> [extra args…] — stdout+stderr captured into $OUT, rc into $RC
add() {
  local ref="$1" st="$2"; shift 2
  OUT="$("$APPEND" --log "$LOG" --ref "$ref" --complexity M --implementer sonnet \
    --outcome merged --started-at "$st" --ended-at 2026-08-16T23:00:00Z \
    --files-changed 3 --lines-added 10 --lines-deleted 2 \
    --sr-performed true --sr-claimed ready "$@" 2>&1)"
  RC=$?
}

echo "TEST 1 — scope normalization (controlled vocabulary, preserve-with-NOTE outside it)"
add i900 2026-08-16T10:00:00Z --scope Backend
[ "$(jq -r 'select(.ref=="i900").scope' "$LOG")" = "backend" ] && ok "Backend → backend" || bad "Backend not folded"
[[ "$OUT" == *"scope-normalize: 'Backend' → 'backend'"* ]] && ok "…and says so on stderr" || bad "no normalize NOTE"
add i901 2026-08-16T10:00:01Z --scope B
[ "$(jq -r 'select(.ref=="i901").scope' "$LOG")" = "backend" ] && ok "B → backend" || bad "B not expanded"
add i902 2026-08-16T10:00:02Z --scope "  FrontEnd "
[ "$(jq -r 'select(.ref=="i902").scope' "$LOG")" = "frontend" ] && ok "'  FrontEnd ' → frontend" || bad "case+space not folded"
add i903 2026-08-16T10:00:03Z --scope landing
[ "$(jq -r 'select(.ref=="i903").scope' "$LOG")" = "landing" ] && ok "landing preserved (not in vocabulary)" || bad "unknown scope mangled"
[[ "$OUT" == *"not in the controlled vocabulary"* ]] && ok "…with an explicit NOTE" || bad "no out-of-vocabulary NOTE"
[ "$RC" = "0" ] && ok "…and does NOT reject (a descriptive field must not push callers to direct-write)" || bad "unknown scope rejected"

echo
echo "TEST 2 — duplicate (ref, started_at) is rejected; a genuine re-run is not"
add i900 2026-08-16T10:00:00Z --scope backend
[ "$RC" = "1" ] && [[ "$OUT" == REJECT*"duplicate entry"* ]] && ok "identical (ref, started_at) rejected" || bad "duplicate accepted: $OUT"
[ "$(grep -c . "$LOG")" = "4" ] && ok "…and nothing was written" || bad "rejected entry still landed"
add i900 2026-08-16T15:00:00Z --scope backend
[ "$RC" = "0" ] && ok "same ref with a new started_at is a legitimate re-run" || bad "re-run blocked: $OUT"
add i900 2026-08-16T15:00:00Z --scope backend --allow-duplicate-ref
[ "$RC" = "0" ] && ok "--allow-duplicate-ref is the documented escape hatch" || bad "escape hatch broken: $OUT"

echo
echo "TEST 3 — the specialist_audit gate and the detail array must agree"
add i910 2026-08-16T16:00:00Z --gates-json '{"specialist_audit":{"status":"pass"}}'
[ "$RC" = "1" ] && [[ "$OUT" == *"contradictory"* ]] && ok "gate=pass + iterations=[] rejected" || bad "contradiction accepted: $OUT"
for st in warn fail block; do
  add "i91$st" 2026-08-16T16:00:01Z --gates-json "{\"specialist_audit\":{\"status\":\"$st\"}}"
  [ "$RC" = "1" ] && ok "gate=$st + iterations=[] rejected" || bad "gate=$st contradiction accepted"
done
add i911 2026-08-16T16:00:02Z --gates-json '{"specialist_audit":{"status":"skipped"}}'
[ "$RC" = "0" ] && ok "gate=skipped + iterations=[] is the honest 'none ran'" || bad "skipped wrongly rejected: $OUT"
add i912 2026-08-16T16:00:03Z --gates-json '{"build":{"status":"pass"}}'
[ "$RC" = "0" ] && ok "no specialist_audit gate at all → unaffected" || bad "absent gate wrongly rejected: $OUT"

echo
echo "TEST 4 — bare-string blockers are lifted to objects, not stubbed"
add i920 2026-08-16T17:00:00Z --gates-json '{"specialist_audit":{"status":"fail"}}' \
  --specialist-iterations-json '[{"cycle":1,"auditors":["p:sec","sec"],"approvers":[],"blockers":["p:sec"]}]'
[ "$RC" = "0" ] && ok "entry with string blockers is accepted" || bad "string blockers rejected: $OUT"
SHAPE="$(jq -c 'select(.ref=="i920").specialist_iterations[0].blockers' "$LOG")"
[ "$SHAPE" = '[{"agent":"p:sec"}]' ] && ok "lifted to {agent: …}" || bad "wrong lifted shape: $SHAPE"
jq -e 'select(.ref=="i920").specialist_iterations[0].blockers[0] | has("category") | not' "$LOG" >/dev/null \
  && ok "category/summary left ABSENT, not fabricated" || bad "lifting invented fields"
[[ "$OUT" == *"lifted 1 bare-string blocker"* ]] && ok "…with a NOTE naming the count" || bad "no lift NOTE"
[[ "$OUT" == *"namespaced and bare form"* ]] && ok "mixed namespacing surfaced (p:sec vs sec)" || bad "no namespacing NOTE"
# The whole point: a consumer indexing .category must no longer die.
jq -r '.specialist_iterations[]?.blockers[]?.category // "-"' "$LOG" >/dev/null 2>&1 \
  && ok "'.blockers[].category' no longer crashes the log" || bad "consumer still dies on this log"

echo
echo "TEST 5 — metrics-report block% cannot exceed 100% and counts cycles, not findings"
RLOG="$WORK/report.jsonl"
# One agent, one cycle, THREE findings — the exact shape that printed 200%/300%.
"$APPEND" --log "$RLOG" --ref i930 --complexity H --implementer sonnet --outcome merged \
  --started-at 2026-08-16T18:00:00Z --ended-at 2026-08-16T19:00:00Z \
  --files-changed 3 --lines-added 10 --lines-deleted 2 --sr-performed true --sr-claimed ready \
  --gates-json '{"specialist_audit":{"status":"fail"}}' \
  --specialist-iterations-json '[{"cycle":1,"auditors":["p:hunter"],"approvers":[],"blockers":[
     {"agent":"p:hunter","category":"a","file_line":"f:1","summary":"s1"},
     {"agent":"p:hunter","category":"b","file_line":"f:2","summary":"s2"},
     {"agent":"p:hunter","category":"c","file_line":"f:3","summary":"s3"}]}]' >/dev/null 2>&1
ROW="$("$REPORT" --log "$RLOG" 2>/dev/null | grep -E '^\s+hunter\s')"
# shellcheck disable=SC2086  # splitting the row into columns is the point
set -- $ROW
[ "${2:-}" = "1" ] && ok "audits = 1 (cycles taken part in)"        || bad "audits column wrong: $ROW"
[ "${3:-}" = "1" ] && ok "blocked = 1 (cycles with ≥1 blocker)"     || bad "blocked column wrong: $ROW"
[ "${4:-}" = "3" ] && ok "findings = 3 (raw records, still visible)" || bad "findings column wrong: $ROW"
[ "${5:-}" = "100%" ] && ok "block% = 100%, not 300%"                || bad "block% wrong: $ROW"
MAXPCT="$("$REPORT" --log "$RLOG" --json 2>/dev/null | jq '[.specialists[].block_rate_pct // 0] | max')"
[ "$MAXPCT" -le 100 ] && ok "no agent can score above 100%" || bad "block% above 100: $MAXPCT"

echo
echo "TEST 6 — an agent that blocks without being listed as an auditor still counts"
# Denominator = cycles the agent PARTICIPATED in (auditor OR blocker). Without
# the union it would be 1/0 and the rate would divide by zero or exceed 100.
BLOG="$WORK/blocker-only.jsonl"
"$APPEND" --log "$BLOG" --ref i940 --complexity H --implementer sonnet --outcome merged \
  --started-at 2026-08-16T20:00:00Z --ended-at 2026-08-16T21:00:00Z \
  --files-changed 1 --lines-added 1 --lines-deleted 0 --sr-performed true --sr-claimed ready \
  --gates-json '{"specialist_audit":{"status":"fail"}}' \
  --specialist-iterations-json '[{"cycle":1,"auditors":["p:sec"],"approvers":[],"blockers":[
     {"agent":"p:ghost","category":"x","file_line":"f:1","summary":"s"}]}]' >/dev/null 2>&1
GROW="$("$REPORT" --log "$BLOG" --json 2>/dev/null | jq -c '.specialists[] | select(.agent=="ghost")')"
[ "$(echo "$GROW" | jq -r '.appearances')" = "1" ]     && ok "blocker-only agent has 1 audit"    || bad "ghost appearances wrong: $GROW"
[ "$(echo "$GROW" | jq -r '.block_rate_pct')" = "100" ] && ok "…and a well-defined 100% rate"     || bad "ghost rate wrong: $GROW"

echo
echo "──────────────────────────────────────────"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
