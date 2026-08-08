#!/usr/bin/env bash
# `cond && ok "…" || bad "…"` is a deliberate assert idiom throughout this file —
# `ok`/`bad` always return 0, so the SC2015 false-C-after-true-B footgun can't fire.
# shellcheck disable=SC2015
#
# Regression test for `config.pr_size.generated_paths` — the Phase 3.0 size gate
# excluding machine-generated artifacts from the counted diff (lea-docs#1399).
#
# Two things are under test, and the second one is the point:
#
#   1. The exclusion itself — a PR of 3500 handwritten + 1000 generated lines
#      passes a 4000-line block cap, a PR of 4500 handwritten lines does not,
#      and both numbers are printed either way.
#   2. **The two enforcement tiers agree.** `pr-size-check` (tier 2, called from
#      the §3.0 spec block) and `do-pr-size-pretooluse.sh` (tier 3, PreToolUse on
#      `gh pr create`) are run on the SAME repo state and must return the SAME
#      verdict. Before v0.13.0 the hook re-implemented the measurement and read
#      exactly four config keys, so a path-exclusion field added to only one of
#      them would have produced WARN from the gate and BLOCK from the hook on one
#      diff. That divergence is the failure this file exists to catch.
#
# Case M is the mutation check: the same fixture with `generated_paths` removed
# from the config must BLOCK. If someone deletes the exclusion logic, case 1
# and case M converge and this file goes red.
#
# Self-contained: synthetic repos under a temp dir, real wrapper + real hook, no
# network, no dependence on the developer's git config.
# Run: bash tests/pr-size-generated-paths.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../skills/do/scripts/pr-size-check"
HOOK="$SCRIPT_DIR/../skills/do/hooks/do-pr-size-pretooluse.sh"
[ -x "$WRAPPER" ] || { echo "FATAL: pr-size-check not found/executable at $WRAPPER"; exit 1; }
[ -x "$HOOK" ]    || { echo "FATAL: do-pr-size-pretooluse.sh not found/executable at $HOOK"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required (the hook parses its payload with it)"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1 HOME="$WORK/home"
mkdir -p "$HOME"

pass=0; fail=0
ok()  { printf '    ok  — %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '    FAIL — %s\n' "$1"; fail=$((fail+1)); }

# ------------------------------------------------------------------ fixture --
R="$WORK/repo"
git init -q -b main "$R"
git -C "$R" commit -q --allow-empty -m init

branch() { git -C "$R" checkout -q main && git -C "$R" checkout -q -b "$1"; }
commit() { git -C "$R" add -A && git -C "$R" commit -q -m "$1"; }

branch mixed
mkdir -p "$R/internal" "$R/openapi"
seq 1 3500 > "$R/internal/service.go"
seq 1 1000 > "$R/openapi/routes.json"
commit "3500 handwritten + 1000 generated"

branch handwritten-only
mkdir -p "$R/internal"
seq 1 4500 > "$R/internal/service.go"
commit "4500 handwritten"

branch glob-edges
mkdir -p "$R/openapi/v1" "$R/pkg" "$R/weird"
seq 1 10 > "$R/openapi/routes.json"        # excluded — openapi/*.json
seq 1 20 > "$R/openapi/v1/deep.json"       # NOT excluded — `*` must not cross /
seq 1 30 > "$R/pkg/api.pb.go"              # excluded — slash-free **/*.pb.go
seq 1 40 > "$R/weird/a+b(c).json"          # NOT excluded, and must not blow up the ERE
commit "glob edge cases"

git -C "$R" checkout -q main
mkdir -p "$R/.claude/do"        # untracked on purpose — config is repo state, not diff

CFG="$R/.claude/do/config.json"
write_cfg_with_exclusion() {
  cat > "$CFG" <<'JSON'
{
  "pr_size": {
    "block_lines": 4000,
    "generated_paths": ["openapi/*.json", "**/*.pb.go"]
  }
}
JSON
}
write_cfg_without_exclusion() {
  cat > "$CFG" <<'JSON'
{
  "pr_size": {
    "block_lines": 4000
  }
}
JSON
}

# ------------------------------------------------------------------ helpers --
# Runs the wrapper the way the §3.0 spec block does.
wrapper_on() {  # $1 = head branch → sets W_OUT / W_RC
  W_OUT="$("$WRAPPER" --repo "$R" --base main --head "$1" 2>&1)"; W_RC=$?
}

# Runs the hook the way Claude Code does: PreToolUse payload on stdin for a
# `gh pr create` naming the same base/head, cwd = the repo.
hook_on() {  # $1 = head branch [$2 = "--draft"] → sets H_OUT / H_ERR / H_RC
  local cmd payload
  cmd="gh pr create --base main --head $1 --title t --body b ${2:-}"
  payload="$(jq -n --arg c "$cmd" --arg cwd "$R" \
    '{session_id:"s", transcript_path:"/dev/null", cwd:$cwd, permission_mode:"default",
      hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$c, description:"pr"}}')"
  H_OUT="$(printf '%s' "$payload" | "$HOOK" 2>"$WORK/hook.err")"; H_RC=$?
  H_ERR="$(cat "$WORK/hook.err")"
}

# The `Phase 3.0: X` token, wherever the tier put it (wrapper stdout, hook
# additionalContext on allow, hook stderr on deny).
verdict_of() { printf '%s' "$1" | grep -oE 'Phase 3\.0: (PASS|WARN|BLOCK)' | head -1; }

# ============================================================ 1. exclusion on
echo "== Case 1: 3500 handwritten + 1000 generated vs block_lines 4000 → must NOT block =="
write_cfg_with_exclusion
wrapper_on mixed
echo "    verdict: $W_OUT"
[ "$W_RC" -eq 0 ] && ok "wrapper exit 0 (not the exit-3 hard halt)" || bad "wrapper exit $W_RC (expected 0)"
[ "$(verdict_of "$W_OUT")" = "Phase 3.0: WARN" ] \
  && ok "verdict WARN — 3500 counted is over warn 800, under block 4000" \
  || bad "verdict is '$(verdict_of "$W_OUT")' (expected WARN)"
case "$W_OUT" in
  *"3500 handwritten + 1000 generated = 4500 total lines"*)
    ok "both numbers reported separately (3500 + 1000 = 4500)" ;;
  *) bad "output does not report handwritten/generated/total separately: $W_OUT" ;;
esac
case "$W_OUT" in
  *"(1 + 1 = 2 files)"*) ok "file counts reported separately too (1 + 1 = 2)" ;;
  *) bad "output does not report the file split: $W_OUT" ;;
esac
case "$W_OUT" in
  *"| diff main...mixed"*) ok "measured range printed (anti-fabrication tell)" ;;
  *) bad "output does not name the measured range: $W_OUT" ;;
esac

# ============================================== 2. exclusion is not a loophole
echo "== Case 2: 4500 handwritten, same cap → must still BLOCK =="
wrapper_on handwritten-only
echo "    verdict: $W_OUT"
[ "$W_RC" -eq 3 ] && ok "wrapper exit 3 (hard halt)" || bad "wrapper exit $W_RC (expected 3)"
[ "$(verdict_of "$W_OUT")" = "Phase 3.0: BLOCK" ] \
  && ok "verdict BLOCK — the exclusion did not open a hole" \
  || bad "verdict is '$(verdict_of "$W_OUT")' (expected BLOCK)"
case "$W_OUT" in
  *"generated excluded"*) bad "reports an exclusion where nothing was excluded: $W_OUT" ;;
  *) ok "no generated clause when nothing matched (output shape unchanged)" ;;
esac

# ================================================= 3. the two tiers must agree
echo "== Case 3: wrapper and PreToolUse hook agree on the same diff =="
for b in mixed handwritten-only glob-edges; do
  wrapper_on "$b"
  hook_on "$b"
  wv="$(verdict_of "$W_OUT")"
  hv="$(verdict_of "$H_OUT$H_ERR")"
  printf '    %-17s wrapper=%s(rc=%d)  hook=%s(rc=%d)\n' "$b" "${wv:-none}" "$W_RC" "${hv:-none}" "$H_RC"
  [ -n "$hv" ] && [ "$wv" = "$hv" ] \
    && ok "$b: identical verdict from both tiers ($wv)" \
    || bad "$b: TIER SPLIT — wrapper '$wv', hook '$hv'"
  # …and the hook's action matches that shared verdict.
  if [ "$wv" = "Phase 3.0: BLOCK" ]; then
    [ "$H_RC" -eq 2 ] && ok "$b: hook denies (exit 2) on the shared BLOCK" \
                      || bad "$b: hook exit $H_RC on a BLOCK verdict (expected 2)"
  else
    [ "$H_RC" -eq 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "allow"' <<<"$H_OUT" >/dev/null 2>&1 \
      && ok "$b: hook allows on the shared $wv" \
      || bad "$b: hook exit $H_RC / non-allow decision on a $wv verdict"
  fi
done

# The draft escape hatch must survive the delegation rewrite.
hook_on handwritten-only --draft
[ "$H_RC" -eq 0 ] && grep -q 'Phase 3.0: BLOCK' <<<"$H_OUT" \
  && ok "draft PR under BLOCK still allowed with the verdict injected" \
  || bad "draft under BLOCK: exit $H_RC out=$(printf '%s' "$H_OUT" | head -c 160)"

# ==================================================== 4. glob semantics matter
echo "== Case 4: glob semantics — * stops at /, slash-free floats, regex chars are literal =="
wrapper_on glob-edges
echo "    verdict: $W_OUT"
# excluded: openapi/routes.json (10) + pkg/api.pb.go (30) = 40 lines / 2 files
# counted:  openapi/v1/deep.json (20) + weird/a+b(c).json (40) = 60 lines / 2 files
case "$W_OUT" in
  *"60 handwritten + 40 generated = 100 total lines (2 + 2 = 4 files)"*)
    ok "openapi/*.json excluded routes.json but NOT v1/deep.json; **/*.pb.go matched at depth; a+b(c).json stayed literal" ;;
  *) bad "glob semantics wrong — expected 60 + 40 = 100 (2 + 2 = 4): $W_OUT" ;;
esac

# ========================================================= M. mutation check
echo "== Case M (mutation): drop generated_paths → the Case 1 fixture must go red =="
write_cfg_without_exclusion
wrapper_on mixed
echo "    verdict: $W_OUT"
[ "$W_RC" -eq 3 ] && ok "without the exclusion the same diff BLOCKs (exit 3)" \
                  || bad "exclusion removed but verdict still $(verdict_of "$W_OUT") — the exclusion is not load-bearing"
hook_on mixed
[ "$H_RC" -eq 2 ] && ok "hook denies too — both tiers flipped together" \
                  || bad "hook exit $H_RC while the wrapper BLOCKed — TIER SPLIT under mutation"

write_cfg_with_exclusion
wrapper_on mixed
[ "$W_RC" -eq 0 ] && ok "restoring generated_paths turns it green again" \
                  || bad "restored config still exits $W_RC"

# ================================================= B. back-compat / arg guards
echo "== Case B: --lines/--files mode and argument guards =="
OUT="$("$WRAPPER" --lines 100 --files 3 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && [ "$(verdict_of "$OUT")" = "Phase 3.0: PASS" ] \
  && ok "legacy --lines/--files still works" || bad "legacy mode: rc=$RC out=$OUT"
case "$OUT" in
  *"generated excluded"*|*"| diff "*) bad "legacy mode leaked --repo-only annotations: $OUT" ;;
  *) ok "legacy mode output byte-shape unchanged (no generated/range clause)" ;;
esac
OUT="$("$WRAPPER" --repo "$R" --lines 1 --files 1 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok "--repo with --lines/--files rejected (exit 1)" || bad "mixed modes: rc=$RC out=$OUT"
OUT="$("$WRAPPER" --lines 1 --files 1 --base main 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok "--base without --repo rejected (exit 1)" || bad "stray --base: rc=$RC out=$OUT"
OUT="$("$WRAPPER" --repo "$WORK/home" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok "--repo pointing outside a git repo rejected (exit 1 → hook fail-open)" \
               || bad "non-repo --repo: rc=$RC out=$OUT"

echo
echo "==================================================="
printf 'pr-size generated_paths: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
