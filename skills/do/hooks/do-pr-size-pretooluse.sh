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
# DRAFT ESCAPE HATCH (load-bearing): §3.0's opt-out BLOCK remediation is "push
# current state as a DRAFT PR + `blocked` label". A `--draft` creation is
# therefore ALWAYS allowed — on a BLOCK verdict it gets the verdict injected
# as context (keep it draft, apply the label) instead of a deny. Blocking
# drafts would deadlock the sanctioned escape path.
#
# AUTO-SPLIT (v0.11.0, default): §3.0 BLOCK normally routes to §4.2.1 auto-split,
# which opens a STACK of PRs whose per-part diff (base = the previous part
# branch) is each sub-cap — so those non-draft creations pass this hook's RC=0
# arm naturally, no special-casing needed. The deny below only ever fires on a
# genuine SINGLE over-block non-draft PR, which auto-split never produces.
#
# FAIL-OPEN (deliberate, mirrors do-secret-scan-pretooluse.sh): missing jq /
# wrapper / non-repo dir / unresolvable base ref / wrapper REJECT or crash →
# exit 0 (allow). It DENIES — exit 2, stderr fed back to the model — ONLY on
# a confirmed over-block-cap diff (pr-size-check exit 3) for a NON-draft
# creation. A backstop must never break legitimate PRs on uncertainty.
#
# MEASUREMENT IS NOT DUPLICATED HERE (lea-docs#1399). This hook parses the *command*
# and hands the wrapper a repo + the refs it named; `pr-size-check --repo` does
# the ref resolution, the `--numstat` churn, the `.claude/do/config.json` read
# (thresholds AND `pr_size.generated_paths` exclusion) and the verdict. Before
# that the hook re-implemented all of it and read exactly four config keys,
# so any new config field — path exclusion above all — would have taken effect
# in the §3.0 wrapper call and NOT here: gate says WARN, hook says BLOCK. That
# split is what lea-docs#1399 was filed over; one implementation is the fix.
#
# NO `--tier` HERE, ON PURPOSE (v0.13.0). §3.0 passes the run's complexity tier
# so the WARN cap matches the budget the plan was approved against; a PreToolUse
# hook sees only a shell command and cannot know the tier. That is safe because
# the ONLY thing this hook enforces is BLOCK, and block caps are deliberately
# tier-independent — an unreviewable diff is unreviewable whoever planned it. So
# the enforced verdict can never split between the two callers; at most the
# advisory WARN *text* differs, and the wrapper stamps `[warn caps: …]` on its
# line so a reader can see which budget produced it.
#
# Inputs it derives (all from the hook payload + the repo, never trusted from
# the model): repo dir = leading `cd <dir> &&` in the command (quote-stripped;
# an unexpandable `$VAR` falls through) else the call's `.cwd`; base ref =
# `--base/-B` (gh) / `--target-branch/-b` (glab); head ref = `--head/-H` (gh) /
# `--source-branch/-s` (glab). Both refs are passed through verbatim — the
# wrapper resolves them (origin/<ref> first, then <ref>; no base ⇒ origin/HEAD →
# origin/main → origin/master → main → master; unresolvable head ⇒ HEAD) and
# fails with REJECT (exit 1 → fail-open here) when nothing resolves.
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

# Everything downstream — ref resolution, the diff, the project config
# (thresholds + generated-path exclusion), the verdict — belongs to the wrapper.
# The hook contributes only what it can see that the wrapper cannot: which repo
# and which refs this command named.
ARGS=(--repo "$DIR")
[ -n "$BASE" ]    && ARGS=("${ARGS[@]}" --base "$BASE")
[ -n "$HEADREF" ] && ARGS=("${ARGS[@]}" --head "$HEADREF")

OUT=$("$PR_SIZE_CHECK" "${ARGS[@]}" 2>/dev/null)
RC=$?

if [ "$RC" -eq 3 ] && [ -z "$DRAFT" ]; then
  {
    echo "[pr-size-check / PreToolUse hook] BLOCKED this PR/MR creation — the real diff in $DIR is over the hard PR-size cap:"
    printf '%s\n' "$OUT"
    echo "Phase 3.0 BLOCK is not advisory (anti-pattern §19f/§21) and this verdict came from the repo's actual diff — do NOT retry a mergeable single PR and do NOT shrink the numbers. Sanctioned paths: (default) auto-split via the pr-split wrapper into a STACK of sub-cap PRs, each opened with --base set to the previous part branch (phase-4-pr.md §4.2.1) — those per-part creations are under cap and pass this hook; OR (--no-split / auto_split:false) re-run this command with --draft (title prefixed WIP:), apply the \`blocked\` label, file the split sub-issues, record gates.pr_size.status=\"block\" with OUTCOME=\"blocked\" (phase-3-review.md §3.0)."
  } >&2
  exit 2
fi

if [ "$RC" -eq 3 ] && [ -n "$DRAFT" ]; then
  jq -n --arg v "$OUT" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      additionalContext: ("[pr-size-check / PreToolUse hook] draft PR allowed under a BLOCK verdict: " + $v + " — this is the §3.0 --no-split/opt-out BLOCK path: keep it a draft, apply the `blocked` label, file the split sub-issues; gates.pr_size.status=\"block\", OUTCOME=\"blocked\". Do NOT mark it ready-for-review without splitting. (The default path is auto-split into a stack of sub-cap PRs — phase-4-pr.md §4.2.1.)")
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
