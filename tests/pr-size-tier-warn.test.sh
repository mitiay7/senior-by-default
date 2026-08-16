#!/usr/bin/env bash
# `cond && ok "…" || bad "…"` is a deliberate assert idiom throughout this file —
# `ok`/`bad` always return 0, so the SC2015 false-C-after-true-B footgun can't fire.
# shellcheck disable=SC2015
#
# Regression test for tier-aware PR-size warn caps (v0.13.0).
#
# The bug being fixed: warn was flat 800/20 for every complexity tier, which put
# it BELOW the H bucket's own plan-time cap of 25 files / 1500 lines. An H plan
# measured at 1400 lines PASSED Phase 2.0 and was then GUARANTEED to WARN at
# Phase 3.0 — two gates in one pipeline disagreeing by construction. Telemetry
# over 93 runs: pr_size warned on 43 of 86 runs (80% of all H runs), so the
# amber verdict carried no information and `calibration_size`, which scores the
# self-review's size prediction against this gate, sat at 53% — a coin flip.
#
# The invariant that matters most is #3 below: the warn caps this wrapper uses
# for a tier must be byte-identical to the caps `plan-size-check` gates that
# tier's PLAN against. They are duplicated (each wrapper must work in a bare
# checkout with no sibling scripts), so only a test keeps them in step.
#
# Self-contained: no repo fixtures needed — `--lines/--files` mode exercises the
# threshold resolution directly. No network, no git, no config.
# Run: bash tests/pr-size-tier-warn.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../skills/do/scripts/pr-size-check"
PLAN="$SCRIPT_DIR/../skills/do/scripts/plan-size-check"
[ -x "$WRAPPER" ] || { echo "FATAL: pr-size-check not found/executable at $WRAPPER"; exit 1; }
[ -x "$PLAN" ]    || { echo "FATAL: plan-size-check not found/executable at $PLAN"; exit 1; }

pass=0; fail=0
ok()  { printf '    ok  — %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '    FAIL — %s\n' "$1"; fail=$((fail+1)); }

# run <expected-verdict> <label> -- <args...>
run() {
  local want="$1" label="$2"; shift 3
  local out rc
  out="$("$WRAPPER" "$@" 2>&1)"; rc=$?
  case "$out" in
    "Phase 3.0: $want"*) ok "$label" ;;
    *) bad "$label — wanted $want, got: $out (rc=$rc)" ;;
  esac
}

echo "TEST 1 — no --tier reproduces pre-0.13 behavior exactly (flat 800/20)"
run WARN "900L/10f → WARN at the flat cap"   -- --lines 900  --files 10
run PASS "700L/10f → PASS at the flat cap"   -- --lines 700  --files 10
run WARN "700L/25f → WARN on files"          -- --lines 700  --files 25
out="$("$WRAPPER" --lines 700 --files 10 2>&1)"
case "$out" in
  *"[warn caps:"*) bad "tier-less run must not stamp a warn-caps source: $out" ;;
  *)               ok "tier-less verdict line is unchanged (no source stamp)" ;;
esac

echo
echo "TEST 2 — each tier warns at its own bucket"
run PASS "H 900L/10f is inside the H budget"    -- --lines 900  --files 10 --tier H
run WARN "H 1600L/10f is over the H budget"     -- --lines 1600 --files 10 --tier H
run WARN "H 700L/30f is over the H file cap"    -- --lines 700  --files 30 --tier H
run WARN "M 700L/5f is over the M budget"       -- --lines 700  --files 5  --tier M
run PASS "M 500L/5f is inside the M budget"     -- --lines 500  --files 5  --tier M
run WARN "L 250L/2f is over the L budget"       -- --lines 250  --files 2  --tier L
run PASS "L 150L/2f is inside the L budget"     -- --lines 150  --files 2  --tier L
run WARN "T 60L/1f is over the T budget"        -- --lines 60   --files 1  --tier T
run PASS "T 40L/1f is inside the T budget"      -- --lines 40   --files 1  --tier T

echo
echo "TEST 3 — the tier warn caps ARE the plan-size buckets (cross-wrapper invariant)"
# Probe plan-size-check for each tier's caps by reading them off its own PASS
# line, then assert pr-size-check treats exactly those numbers as the boundary:
# cap ⇒ PASS, cap+1 ⇒ WARN, on both dimensions. If either wrapper's table is
# edited alone, this block goes red.
for tier in T L M H; do
  planline="$("$PLAN" --current-complexity "$tier" --planned-files 0 --planned-lines 0 2>&1)"
  cf="$(printf '%s' "$planline" | sed -n 's/.*caps: \([0-9]*\) files.*/\1/p')"
  cl="$(printf '%s' "$planline" | sed -n 's/.*caps: [0-9]* files \/ \([0-9]*\) lines.*/\1/p')"
  if [ -z "$cf" ] || [ -z "$cl" ]; then
    bad "$tier — could not read caps off plan-size-check: $planline"
    continue
  fi
  run PASS "$tier — exactly at the plan cap (${cl}L/${cf}f) PASSes" -- --lines "$cl" --files "$cf" --tier "$tier"
  run WARN "$tier — one line over the plan cap WARNs"               -- --lines "$((cl + 1))" --files "$cf" --tier "$tier"
  run WARN "$tier — one file over the plan cap WARNs"               -- --lines "$cl" --files "$((cf + 1))" --tier "$tier"
done

echo
echo "TEST 4 — precedence: explicit flag > tier, per dimension"
out="$("$WRAPPER" --lines 900 --files 5 --tier H --warn-lines 800 2>&1)"
case "$out" in
  "Phase 3.0: WARN"*"(800/25)"*) ok "--warn-lines wins on lines, tier still supplies files" ;;
  *) bad "mixed precedence wrong: $out" ;;
esac
case "$out" in
  *"lines=cli files=tier H"*) ok "the source stamp names both origins" ;;
  *) bad "source stamp missing or wrong: $out" ;;
esac
run PASS "--warn-files wins on files" -- --lines 100 --files 30 --tier T --warn-files 40 --warn-lines 200

echo
echo "TEST 5 — block caps are tier-INDEPENDENT (an unreviewable diff is unreviewable)"
for tier in T L M H; do
  out="$("$WRAPPER" --lines 2100 --files 5 --tier "$tier" 2>&1)"; rc=$?
  case "$out:$rc" in
    "Phase 3.0: BLOCK"*":3") ok "$tier — 2100L blocks at the shared 2000 cap, exit 3" ;;
    *) bad "$tier — wanted BLOCK/rc=3, got: $out (rc=$rc)" ;;
  esac
done
# …and the band between the two caps stays a WARN: H's generous warn budget
# must neither swallow a block nor promote a warn.
run WARN "H 1600L sits in the 1500→2000 band → WARN, not BLOCK" -- --lines 1600 --files 10 --tier H

echo
echo "TEST 6 — bad input rejected"
out="$("$WRAPPER" --lines 10 --files 1 --tier X 2>&1)"; rc=$?
[ "$rc" = "1" ] && [[ "$out" == REJECT* ]] && ok "--tier X rejected (exit 1)" || bad "bad tier not rejected: $out (rc=$rc)"
out="$("$WRAPPER" --lines 10 --files 1 --tier '' 2>&1)"; rc=$?
[ "$rc" = "0" ] && ok "--tier '' is treated as absent (flat defaults)" || bad "empty tier should behave as absent: $out (rc=$rc)"

echo
echo "TEST 7 — config.pr_size.* still wins over the tier bucket"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_NOSYSTEM=1
R="$WORK/repo"; git init -q -b main "$R"; git -C "$R" commit -q --allow-empty -m init
mkdir -p "$R/.claude/do"
printf '{"pr_size":{"warn_lines":300,"warn_files":4}}\n' > "$R/.claude/do/config.json"
git -C "$R" checkout -q -b feat
# 500 lines across 1 file — inside H's 1500/25 bucket, outside the config's 300/4.
awk 'BEGIN{for(i=0;i<500;i++) print "line " i}' > "$R/big.txt"
git -C "$R" add -A && git -C "$R" commit -q -m big
out="$("$WRAPPER" --repo "$R" --base main --tier H 2>&1)"
case "$out" in
  "Phase 3.0: WARN"*"(300/4)"*"[warn caps: config]"*) ok "config beats the tier bucket and says so" ;;
  *) bad "config precedence wrong: $out" ;;
esac
if command -v jq >/dev/null 2>&1; then
  # CLI supplies lines (1000), config still supplies files (4), tier supplies
  # neither — the stamp must say exactly that.
  out="$("$WRAPPER" --repo "$R" --base main --tier H --warn-lines 1000 2>&1)"
  case "$out" in
    "Phase 3.0: PASS"*"warn 1000/4"*"[warn caps: lines=cli files=config]"*)
      ok "CLI beats config beats tier, per dimension" ;;
    *) bad "full precedence chain wrong: $out" ;;
  esac
else
  ok "skipped CLI-over-config probe (no jq)"
fi

echo
echo "──────────────────────────────────────────"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
