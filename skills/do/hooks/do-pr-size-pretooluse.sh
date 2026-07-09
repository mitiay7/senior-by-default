#!/bin/bash
# do-pr-size-pretooluse.sh — Claude Code **PreToolUse hook** (matcher: Bash;
# harness-level enforcement tier, see references/hooks.md). OPT-IN.
#
# Purpose: tier-3 backstop for the Phase 3.0 PR-size gate — §19f's runtime leg.
# Tier 2 (the `pr-size-check` wrapper inside the §3.0 bash block) is still
# model-dependent: if the orchestrator creates the PR without running §3.0, no
# gate fires — and production shipped 8 PRs >2000 lines as `warn` exactly that
# way. This hook re-checks at the runtime level: every Bash command that
# creates a PR/MR (`gh pr create` / `glab mr create`) gets the same size
# verdict first, computed from the repo's REAL diff.
#
# SELF-SCOPING: no-op on any Bash command that is not a PR/MR creation. Like
# do-secret-scan-pretooluse.sh it is deliberately NOT /do-specific — an
# unreviewable 4000-line PR is a problem in any session — but it never
# disturbs non-PR work.
#
# DRAFT ESCAPE HATCH (load-bearing): §3.0's own BLOCK remediation is "push
# current state as a DRAFT PR + `blocked` label". A `--draft` creation is
# therefore ALWAYS allowed — on a BLOCK verdict it gets the verdict injected
# as context (keep it draft, apply the label) instead of a deny. Blocking
# drafts would deadlock the sanctioned escape path.
#
# FAIL-OPEN (deliberate, mirrors do-secret-scan-pretooluse.sh): missing jq /
# wrapper / non-repo dir / unresolvable base ref / wrapper REJECT or crash →
# exit 0 (allow). It DENIES — exit 2, stderr fed back to the model — ONLY on
# a confirmed over-block-cap diff (pr-size-check exit 3) for a NON-draft
# creation. A backstop must never break legitimate PRs on uncertainty.
#
# Inputs it derives (all from the hook payload + the repo, never trusted from
# the model): repo dir = leading `cd <dir> &&` in the command (quote-stripped;
# an unexpandable `$VAR` falls through) else the call's `.cwd`; base ref =
# `--base/-B` (gh) / `--target-branch/-b` (glab) else `origin/HEAD` →
# origin/main → origin/master → main → master; head ref = `--head/-H` (gh) /
# `--source-branch/-s` (glab) if locally resolvable else HEAD. Thresholds =
# `.pr_size.*` from `<repo>/.claude/do/config.json` when present (numeric),
# else the wrapper's config-schema.md defaults. Lines = added+deleted churn
# from `git diff base...head --numstat`, same formula as §3.0.
#
# Self-locating: finds the sibling pr-size-check via $0, so it works under any
# skill name / install path.

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)
if [ -n "$TOOL" ] && [ "$TOOL" != "Bash" ]; then exit 0; fi   # matcher scopes already; belt & braces

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || true)
[ -z "$CMD" ] && exit 0

# PR/MR creation in one command segment. Subcommand order is fixed for both
# CLIs (`gh pr create [flags]`, `glab mr create [flags]`).
IS_GH=""
if printf '%s' "$CMD" | grep -qE '(^|[^[:alnum:]_-])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'; then
  IS_GH=1
elif printf '%s' "$CMD" | grep -qE '(^|[^[:alnum:]_-])glab[[:space:]]+mr[[:space:]]+create([[:space:]]|$)'; then
  IS_GH=""
else
  exit 0   # not a PR/MR creation → allow, no-op
fi

# Draft detection. `--draft` is common to both CLIs; bare `-d` is draft ONLY
# for gh (`glab mr create -d` is --description). A false draft-positive (e.g.
# "-d" inside a --body string) degrades to allow-with-context — fail-open.
DRAFT=""
printf '%s' "$CMD" | grep -qE '(^|[[:space:]])--draft([[:space:]]|$|=)' && DRAFT=1
[ -n "$IS_GH" ] && printf '%s' "$CMD" | grep -qE '(^|[[:space:]])-d([[:space:]]|$)' && DRAFT=1

HOOK_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P || echo "")
PR_SIZE_CHECK="$HOOK_DIR/../scripts/pr-size-check"
[ -x "$PR_SIZE_CHECK" ] || exit 0

# Repo dir: leading `cd <dir>` in the command wins; else the tool call's cwd.
DIR=$(printf '%s' "$CMD" | sed -n -E 's/^[[:space:]]*cd[[:space:]]+([^;&|]+).*/\1/p' | head -1 || true)
DIR=$(printf '%s' "$DIR" | sed -E 's/[[:space:]]+$//')
DIR=${DIR#\"}; DIR=${DIR%\"}; DIR=${DIR#\'}; DIR=${DIR%\'}
# shellcheck disable=SC2088  # literal leading tilde survives quoting — expand it ourselves
case "$DIR" in
  ''|\$*) DIR="" ;;                 # empty or unexpandable $VARIABLE literal
  "~"|"~/"*) DIR="$HOME${DIR#\~}" ;;
esac
if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
  DIR=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
fi
[ -n "$DIR" ] && [ -d "$DIR" ] || exit 0
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Extract a flag value: space- or =-separated, quote-stripped; `$VAR` literals
# (the shell would have expanded a real one before the hook ever saw it — a
# surviving `$` means we cannot know the value) are discarded by the caller.
flagval() {  # $1 = extended-regex alternation of flag spellings
  printf '%s' "$CMD" \
    | grep -oE "(^|[[:space:]])($1)([[:space:]]+|=)[^[:space:]]+" | head -1 \
    | sed -E "s/^[[:space:]]*($1)([[:space:]]+|=)//" \
    | sed -E "s/^[\"']//; s/[\"']\$//" || true
}

if [ -n "$IS_GH" ]; then
  BASE=$(flagval '--base|-B'); HEADREF=$(flagval '--head|-H')
else
  BASE=$(flagval '--target-branch|-b'); HEADREF=$(flagval '--source-branch|-s')
fi
case "$BASE"    in \$*) BASE=""    ;; esac
case "$HEADREF" in \$*) HEADREF="" ;; esac

# Base ref: explicit flag (prefer its origin/ mirror) → origin/HEAD → the
# usual defaults. First resolvable candidate wins; none → fail-open.
CANDIDATES=""
if [ -n "$BASE" ]; then
  CANDIDATES="origin/$BASE $BASE"
else
  OH=$(git -C "$DIR" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
  CANDIDATES="${OH:+$OH }origin/main origin/master main master"
fi
BASEREF=""
for c in $CANDIDATES; do
  if git -C "$DIR" rev-parse --verify -q "$c^{commit}" >/dev/null 2>&1; then BASEREF="$c"; break; fi
done
[ -n "$BASEREF" ] || exit 0

# Head ref: explicit flag if it resolves locally, else the checked-out HEAD.
if [ -z "$HEADREF" ] || ! git -C "$DIR" rev-parse --verify -q "$HEADREF^{commit}" >/dev/null 2>&1; then
  HEADREF="HEAD"
fi

# Same churn formula as §3.0: added+deleted from numstat ("-" binary counts
# coerce to 0 in awk); file count = numstat line count.
NUM=$(git -C "$DIR" diff "$BASEREF...$HEADREF" --numstat 2>/dev/null) || exit 0
LINES=$(printf '%s\n' "$NUM" | awk '{a+=$1; d+=$2} END {print a+d+0}')
FILES=$(printf '%s' "$NUM" | grep -c '^' 2>/dev/null); FILES="${FILES:-0}"

# Project threshold overrides, when the repo carries a /do config.
ARGS=(--lines "$LINES" --files "$FILES")
ROOT=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)
CFGF="$ROOT/.claude/do/config.json"
if [ -n "$ROOT" ] && [ -f "$CFGF" ]; then
  for k in warn_lines warn_files block_lines block_files; do
    v=$(jq -r ".pr_size.${k} // empty" "$CFGF" 2>/dev/null || true)
    case "$v" in (*[!0-9]*|'') : ;; (*) ARGS=("${ARGS[@]}" "--${k//_/-}" "$v") ;; esac
  done
fi

OUT=$("$PR_SIZE_CHECK" "${ARGS[@]}" 2>/dev/null)
RC=$?

if [ "$RC" -eq 3 ] && [ -z "$DRAFT" ]; then
  {
    echo "[pr-size-check / PreToolUse hook] BLOCKED this PR/MR creation — the real diff ($BASEREF...$HEADREF in $DIR) is over the hard PR-size cap:"
    printf '%s\n' "$OUT"
    echo "Phase 3.0 BLOCK is not advisory (anti-pattern §19f/§21) and this verdict came from the repo's actual diff — do NOT retry a mergeable PR and do NOT shrink the numbers. The sanctioned path: re-run this command with --draft (title prefixed WIP:), apply the \`blocked\` label, file the split sub-issues, record gates.pr_size.status=\"block\" with OUTCOME=\"blocked\" (phase-3-review.md §3.0)."
  } >&2
  exit 2
fi

if [ "$RC" -eq 3 ] && [ -n "$DRAFT" ]; then
  jq -n --arg v "$OUT" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      additionalContext: ("[pr-size-check / PreToolUse hook] draft PR allowed under a BLOCK verdict: " + $v + " — this is the §3.0 BLOCK path: keep it a draft, apply the `blocked` label, file the split sub-issues; gates.pr_size.status=\"block\", OUTCOME=\"blocked\". Do NOT mark it ready-for-review without splitting.")
    }
  }'
  exit 0
fi

if [ "$RC" -eq 0 ] && [ -n "$OUT" ]; then
  jq -n --arg v "$OUT" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      additionalContext: ("[pr-size-check / PreToolUse hook] " + $v + " — if this is a /do Phase 4 PR creation, this verdict (from a real wrapper run against the actual diff) is what belongs in gates.pr_size. WARN ⇒ add the PR-size note to the PR description (§3.0).")
    }
  }'
  exit 0
fi

exit 0   # REJECT / crash / anything else → fail-open (allow)
