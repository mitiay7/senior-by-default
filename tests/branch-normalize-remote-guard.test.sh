#!/usr/bin/env bash
# `cond && ok "…" || bad "…"` is a deliberate assert idiom throughout this file —
# `ok`/`bad` always return 0, so the SC2015 false-C-after-true-B footgun can't fire.
# shellcheck disable=SC2015
#
# Regression test for the Phase 4.0 old-remote-ref cleanup default-branch-deletion bug.
#
# The bug (shipped through v0.11.0): `branch-normalize` keyed the post-rename
# `git push --delete` off the OLD branch's @{upstream}. A worktree branch cut
# with `git worktree add -b X origin/main` has upstream=origin/main, so the
# cleanup ran `git push origin --delete main` — deleting the default branch.
# Only branch protection (or a bare remote refusing to delete its current
# branch) ever saved it in the wild.
#
# The fix: clean up ONLY the remote ref matching the OLD LOCAL NAME ($ACTUAL),
# gated on (a) it was actually pushed and (b) it is not the default/main/master
# branch (hard guard → `skipped(protected:<branch>)`). @{upstream} is used only
# to pick the remote NAME, never the branch to delete.
#
# Self-contained: builds synthetic bare origins + clones under a temp dir, runs
# the real wrapper, asserts on the bare remote (the source of truth). No network,
# no dependence on the user's git config. Run: bash tests/branch-normalize-remote-guard.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BN="$SCRIPT_DIR/../skills/do/scripts/branch-normalize"
[ -x "$BN" ] || { echo "FATAL: branch-normalize not found/executable at $BN"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Deterministic identity — do not read the developer's real git config.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1 HOME="$WORK/home"
mkdir -p "$HOME"

pass=0; fail=0
ok()  { printf '    ok  — %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '    FAIL — %s\n' "$1"; fail=$((fail+1)); }

# make_origin <bare-path> <default-branch> [extra-branch...]
# Seeds a bare repo with `main` (+ any extra branches), then points its HEAD at
# <default-branch>. A non-main default lets us prove the OLD bug would actually
# delete main (a bare remote refuses to delete only its *current* branch).
make_origin() {
  bare="$1"; default="$2"; shift 2
  seed="$WORK/seed.${bare##*/}"
  git init -q -b main "$seed"
  git -C "$seed" commit -q --allow-empty -m init
  for b in "$@"; do git -C "$seed" branch "$b"; done
  git init -q --bare "$bare"
  git -C "$seed" remote add origin "$bare"
  git -C "$seed" push -q origin main "$@"
  git -C "$bare" symbolic-ref HEAD "refs/heads/$default"
}

remote_has() { git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }
cur_branch() { git -C "$1" rev-parse --abbrev-ref HEAD; }

echo "== Case A: worktree branch tracking origin/main — rename must NOT touch main =="
# The exact reported scenario. origin default = develop so a reintroduced bug
# would SUCCEED in deleting main (making this a real regression trap).
originA="$WORK/originA.git"
make_origin "$originA" develop develop
cloneA="$WORK/cloneA"
git clone -q "$originA" "$cloneA"
wtA="$WORK/wtA"
git -C "$cloneA" worktree add -q -b claude/quirky-fox "$wtA" origin/main
git -C "$wtA" branch --set-upstream-to=origin/main >/dev/null 2>&1
[ "$(git -C "$wtA" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" = "origin/main" ] \
  && ok "fixture: worktree branch upstream is origin/main" \
  || bad "fixture: worktree branch upstream is NOT origin/main (test would be meaningless)"
outA="$("$BN" -C "$wtA" --complexity L --slug fox 2>&1)"; rcA=$?
echo "    verdict: $outA"
[ "$rcA" -eq 0 ]                                   && ok "exit 0" || bad "exit $rcA (expected 0)"
remote_has "$originA" main                         && ok "origin/main SURVIVES" || bad "origin/main was DELETED — the bug"
case "$outA" in *"old_remote=none"*) ok "old_remote=none (never targeted main)";; *) bad "old_remote not 'none': $outA";; esac
case "$outA" in *deleted*main*|*delete-failed*main*) bad "verdict TARGETED main: $outA";; *) ok "verdict never names main as a delete target";; esac
[ "$(cur_branch "$wtA")" = "feat/fox" ]            && ok "local branch renamed to feat/fox" || bad "local branch is $(cur_branch "$wtA") (expected feat/fox)"

echo "== Case B: hard guard — current branch IS main (default) =="
originB="$WORK/originB.git"
make_origin "$originB" main
cloneB="$WORK/cloneB"
git clone -q "$originB" "$cloneB"
[ "$(cur_branch "$cloneB")" = "main" ] || bad "fixture: clone not on main"
outB="$("$BN" -C "$cloneB" --complexity L --slug fox 2>&1)"; rcB=$?
echo "    verdict: $outB"
[ "$rcB" -eq 0 ]                                   && ok "exit 0" || bad "exit $rcB (expected 0)"
case "$outB" in *"old_remote=skipped(protected:main)"*) ok "old_remote=skipped(protected:main)";; *) bad "guard did not fire: $outB";; esac
remote_has "$originB" main                         && ok "origin/main SURVIVES" || bad "origin/main was DELETED — the bug"
[ "$(cur_branch "$cloneB")" = "feat/fox" ]         && ok "local branch renamed to feat/fox" || bad "local branch is $(cur_branch "$cloneB")"

echo "== Case C: legitimate stale-ref cleanup is preserved (non-default pushed branch) =="
originC="$WORK/originC.git"
make_origin "$originC" main
cloneC="$WORK/cloneC"
git clone -q "$originC" "$cloneC"
git -C "$cloneC" checkout -q -b oldfeature
git -C "$cloneC" commit -q --allow-empty -m work
git -C "$cloneC" push -q -u origin oldfeature
outC="$("$BN" -C "$cloneC" --complexity L --slug fox 2>&1)"; rcC=$?
echo "    verdict: $outC"
[ "$rcC" -eq 0 ]                                   && ok "exit 0" || bad "exit $rcC (expected 0)"
case "$outC" in *"old_remote=deleted(origin/oldfeature)"*) ok "old_remote=deleted(origin/oldfeature)";; *) bad "stale ref not cleaned: $outC";; esac
remote_has "$originC" oldfeature                    && bad "origin/oldfeature NOT deleted" || ok "origin/oldfeature deleted"
remote_has "$originC" main                          && ok "origin/main untouched" || bad "origin/main was collaterally deleted"

echo "== Case D: --no-remote-delete opts out entirely (no delete, no guard message) =="
originD="$WORK/originD.git"
make_origin "$originD" main
cloneD="$WORK/cloneD"
git clone -q "$originD" "$cloneD"
git -C "$cloneD" checkout -q -b oldfeature
git -C "$cloneD" commit -q --allow-empty -m work
git -C "$cloneD" push -q -u origin oldfeature
outD="$("$BN" -C "$cloneD" --complexity L --slug fox --no-remote-delete 2>&1)"; rcD=$?
echo "    verdict: $outD"
[ "$rcD" -eq 0 ]                                   && ok "exit 0" || bad "exit $rcD (expected 0)"
case "$outD" in *"old_remote=none"*) ok "old_remote=none (opt-out)";; *) bad "unexpected old_remote under opt-out: $outD";; esac
remote_has "$originD" oldfeature                    && ok "origin/oldfeature preserved under opt-out" || bad "origin/oldfeature deleted despite --no-remote-delete"

echo
echo "==================================================="
printf 'branch-normalize remote-guard: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
