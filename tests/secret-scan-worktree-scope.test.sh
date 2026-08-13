#!/usr/bin/env bash
# `cond && ok "…" || bad "…"` is a deliberate assert idiom throughout this file —
# `ok`/`bad` always return 0, so the SC2015 false-C-after-true-B footgun can't fire.
# shellcheck disable=SC2015
#
# Regression test for the Phase 4.1 secret gate's SCOPE (lea-docs#1463).
#
# The failure this file exists to catch, reproduced live on 2026-08-13: a push
# carrying a password assignment was ALLOWED, and the hook printed
#
#     Phase 4.1: SECRETS PASS — range f1c451e..f1c451e clean (0 commits, 0 files)
#
# Nothing had been scanned. The hook resolved its directory from the hook input's
# `.cwd` — the SESSION's directory — while the push ran in a worktree, and the
# session's checkout was sitting on origin/main, so the range was empty. An empty
# range reported as PASS is worse than no gate at all: /do §4.1 instructs the
# model to paste that very line into `gates.secret_scan` as proof the gate ran,
# so the ABSENCE of a check gets filed as EVIDENCE of one.
#
# Two independent halves are under test, and both must hold:
#
#   1. `secret-scan` itself: an empty range is INCONCLUSIVE (exit 4), never PASS.
#      This fixes the whole class regardless of who picks the directory.
#   2. The hook's directory choice: `cd <dir> && git push` is honoured, and when
#      the resolved directory has nothing to scan, every sibling worktree ahead
#      of origin/main is scanned instead. One BLOCK blocks.
#
# Case M is the mutation check and it is the point of the file: a hook stripped
# of both mechanisms (the `cd` step and the empty-range fan-out) must let the
# secret through with a PASS line. If someone removes the fix, case M converges
# with the real cases and this file goes red.
#
# Self-contained: synthetic repos under a temp dir, real wrapper + real hook, no
# network, no dependence on the developer's git config.
# Run: bash tests/secret-scan-worktree-scope.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../skills/do/scripts/secret-scan"
HOOK="$SCRIPT_DIR/../skills/do/hooks/do-secret-scan-pretooluse.sh"
[ -x "$WRAPPER" ] || { echo "FATAL: secret-scan not found/executable at $WRAPPER"; exit 1; }
[ -x "$HOOK" ]    || { echo "FATAL: do-secret-scan-pretooluse.sh not found/executable at $HOOK"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required (the hook parses its payload with it)"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; return 0; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; return 0; }

git_q() { git -c init.defaultBranch=main -c user.email=t@example.com -c user.name=t "$@"; }

# ── fixtures ────────────────────────────────────────────────────────────────
# origin ──┬── clone      (sits on origin/main; this is the SESSION's cwd)
#          │      └── wt-secret   worktree, 1 commit, contains a secret
#          └── clean      (its own commit, no secret)
build_fixtures() {
  git_q init -q "$WORK/origin"
  ( cd "$WORK/origin" && echo base > a.txt && git_q add -A && git_q commit -qm base && git_q branch -M main )

  git_q clone -q "$WORK/origin" "$WORK/clone"
  ( cd "$WORK/clone" && git_q worktree add -q -b feature "$WORK/wt-secret" )
  # A quoted assignment ≥12 chars — the `secret_assignment` content pattern.
  # The keyword is assembled at runtime ON PURPOSE: written literally, THIS FILE
  # would itself match the pattern and `secret-scan` would (correctly) block the
  # push that ships the test. Renaming the fixture is the fix; suppressing the
  # scanner is not.
  local kw; kw="pass""word"
  ( cd "$WORK/wt-secret" && printf '%s = "hunter2hunter2hunter2"\n' "$kw" > creds.txt \
      && git_q add -A && git_q commit -qm "add creds" )

  git_q clone -q "$WORK/origin" "$WORK/clean"
  ( cd "$WORK/clean" && git_q checkout -qb clean-feature && echo hello > b.txt \
      && git_q add -A && git_q commit -qm ok )

  # A clone with NO commits ahead and NO worktrees: the only fixture in which
  # there is genuinely nothing to scan anywhere. `$WORK/origin` will not do —
  # it has no origin/* remote at all, so the wrapper takes its full-tree
  # fallback and correctly reports a real PASS over the whole HEAD tree.
  git_q clone -q "$WORK/origin" "$WORK/idle"
}
build_fixtures

# HOOK_RC travels through a file, not a variable: `OUT=$(hook_run …)` runs the
# function in a SUBSHELL, so an exit code assigned to a shell variable inside it
# is gone by the time the caller reads it — and every rc assertion would then be
# testing a stale value.
RC_FILE="$WORK/.hook_rc"
hook_run() { # hook_run <hook-path> <cwd> <command> ; prints stdout+stderr, writes rc to $RC_FILE
  local hook="$1" cwd="$2" cmd="$3" out rc
  out=$(jq -n --arg c "$cwd" --arg x "$cmd" \
        '{tool_name:"Bash",cwd:$c,tool_input:{command:$x}}' | bash "$hook" 2>&1)
  rc=$?
  printf '%s' "$rc" > "$RC_FILE"
  printf '%s' "$out"
}
hook_rc() { cat "$RC_FILE" 2>/dev/null || echo 999; }

echo "── 1. secret-scan: the verdicts themselves ──"

OUT=$("$WRAPPER" -C "$WORK/wt-secret" 2>&1); RC=$?
[ "$RC" -eq 3 ] && ok "worktree holding a secret → BLOCK (exit 3)" || bad "worktree holding a secret → expected exit 3, got $RC"
printf '%s' "$OUT" | grep -q 'SECRETS BLOCK' && ok "BLOCK verdict says BLOCK" || bad "BLOCK verdict text: $OUT"
printf '%s' "$OUT" | grep -qF "[dir: " && ok "BLOCK verdict names the scanned directory" || bad "BLOCK verdict has no [dir: …]: $OUT"

OUT=$("$WRAPPER" -C "$WORK/clone" 2>&1); RC=$?
[ "$RC" -eq 4 ] && ok "checkout with 0 commits ahead → INCONCLUSIVE (exit 4)" || bad "empty range → expected exit 4, got $RC"
[ "$RC" -ne 0 ] && ok "empty range is NOT exit 0 — \`secret-scan && git push\` cannot push on it" || bad "empty range still exits 0"
printf '%s' "$OUT" | grep -q 'NOTHING WAS SCANNED' && ok "INCONCLUSIVE says nothing was scanned" || bad "INCONCLUSIVE text: $OUT"
! printf '%s' "$OUT" | grep -q 'SECRETS PASS' && ok "INCONCLUSIVE never prints the word PASS" || bad "INCONCLUSIVE printed PASS: $OUT"
printf '%s' "$OUT" | grep -qF 'do not put this line in gates.secret_scan' \
  && ok "INCONCLUSIVE forbids its own use as gate evidence" || bad "INCONCLUSIVE does not forbid gate use: $OUT"

OUT=$("$WRAPPER" -C "$WORK/clean" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "clean commit ahead of origin/main → PASS (exit 0)" || bad "clean range → expected exit 0, got $RC"
printf '%s' "$OUT" | grep -qF "[dir: " && ok "PASS verdict names the scanned directory" || bad "PASS verdict has no [dir: …]: $OUT"

echo "── 2. the hook: which directory it decides to scan ──"

OUT=$(hook_run "$HOOK" "$WORK/clone" "cd $WORK/wt-secret && git push -u origin feature")
[ "$(hook_rc)" -eq 2 ] && ok "\`cd <worktree> && git push\` with a foreign .cwd → BLOCKED" || bad "cd-form push → expected exit 2, got $(hook_rc)"
printf '%s' "$OUT" | grep -q 'creds.txt' && ok "the block names the offending file" || bad "block output: $OUT"

OUT=$(hook_run "$HOOK" "$WORK/clone" "git push -u origin feature")
[ "$(hook_rc)" -eq 2 ] && ok "bare push, .cwd on origin/main → sibling worktree scanned → BLOCKED" || bad "bare push → expected exit 2, got $(hook_rc)"

OUT=$(hook_run "$HOOK" "$WORK/clean" "git push")
[ "$(hook_rc)" -eq 0 ] && ok "a genuinely clean push is allowed" || bad "clean push → expected exit 0, got $(hook_rc)"
printf '%s' "$OUT" | grep -qF 'belongs in the gates-json secret_scan entry' \
  && ok "a real PASS is offered as gate evidence" || bad "PASS context: $OUT"

# Nothing to scan anywhere: allowed (a backstop must not break pushes), but the
# text must refuse to be used as evidence. This is the case that used to print
# PASS.
OUT=$(hook_run "$HOOK" "$WORK/idle" "git push")
[ "$(hook_rc)" -eq 0 ] && ok "nothing to scan anywhere → still allowed (fail-open backstop)" || bad "no-op case → expected exit 0, got $(hook_rc)"
printf '%s' "$OUT" | grep -qF 'NOT SCANNED' && ok "no-op case says NOT SCANNED out loud" || bad "no-op context: $OUT"
! printf '%s' "$OUT" | grep -qF 'belongs in the gates-json secret_scan entry' \
  && ok "no-op case is NOT offered as gate evidence" || bad "no-op case still offers itself as evidence: $OUT"

echo "── M. mutation: strip the fix, the secret must get through ──"

# Reproduce the pre-fix hook mechanically: drop the `cd` resolution step and the
# empty-range fan-out, leaving `.cwd` as the only source of truth. Anything less
# than a full miss here would mean the cases above pass for some other reason.
MUT="$WORK/hook-mutated.sh"
awk '
  /^# 2\. `cd <dir>` \/ `pushd <dir>` in the same command/ { skipcd = 1 }
  skipcd && /^fi$/ { skipcd = 0; next }
  skipcd { next }
  /^if \[ "\$RC" -eq 4 \]; then$/ { skip4 = 1 }
  skip4 && /^fi$/ { skip4 = 0; next }
  skip4 { next }
  { print }
' "$HOOK" > "$MUT"
chmod +x "$MUT"
bash -n "$MUT" 2>/dev/null && ok "mutated hook is still valid bash (the mutation is meaningful, not a syntax error)" \
  || bad "mutation produced invalid bash — the assertions below would be vacuous"

OUT=$(hook_run "$MUT" "$WORK/clone" "cd $WORK/wt-secret && git push -u origin feature")
[ "$(hook_rc)" -ne 2 ] && ok "MUTATED: the secret push is no longer blocked — the fix is load-bearing" \
  || bad "MUTATED hook still blocks: the passing cases above do not depend on the fix"

# And the second half of the fix, independently: even mutated, the wrapper must
# refuse to call an empty range clean. That is why fixing `secret-scan` matters
# separately from fixing the hook's directory choice.
! printf '%s' "$OUT" | grep -qF 'SECRETS PASS' \
  && ok "MUTATED: still no PASS line — the wrapper's INCONCLUSIVE holds on its own" \
  || bad "MUTATED hook printed a PASS for an empty range: $OUT"

echo
if [ "$FAIL" -ne 0 ]; then
  echo "FAILED: $FAIL assertion(s) failed, $PASS passed"
  exit 1
fi
echo "OK — $PASS assertions passed"
