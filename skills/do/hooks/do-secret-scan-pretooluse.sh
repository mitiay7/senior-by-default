#!/bin/bash
# do-secret-scan-pretooluse.sh — Claude Code **PreToolUse hook** (matcher: Bash;
# harness-level enforcement tier, see references/hooks.md). OPT-IN.
#
# Purpose: tier-3 backstop for the Phase 4.1 pre-push secret gate — the single
# IRREVERSIBLE skip in the pipeline (a pushed secret is revoke-and-rotate, not
# revert). Tier 2 (the `secret-scan` wrapper gating the push inside the §4.1
# bash block) is still model-dependent: if the orchestrator pushes outside the
# gated block, no scan runs. This hook re-checks at the runtime level: every
# Bash command that performs a `git push` gets the same scan first.
#
# SELF-SCOPING: no-op on any Bash command that is not a `git push` (`git stash
# push` excluded). Unlike the other two shipped hooks this one is deliberately
# NOT /do-specific — a pushed secret is equally unrecoverable outside /do, and
# the rule it enforces (git-rules.md §Secret guard) is unconditional. It still
# never disturbs non-push work.
#
# FAIL-OPEN (deliberate, mirrors do-plan-size-pretooluse.sh): missing jq /
# wrapper / unresolvable repo dir / wrapper REJECT or crash → exit 0 (allow).
# It BLOCKS — exit 2, stderr fed back to the model — ONLY on a confirmed
# secret match (secret-scan exit 3). A backstop must never break legitimate
# pushes on uncertainty.
#
# Repo-dir resolution for the scan: `git -C <dir> push` → <dir> (after quote
# stripping; a `$VARIABLE` path cannot be expanded here and falls through);
# otherwise the hook input's `.cwd`. Worst case the fallback scans the wrong
# repo and yields an empty-range PASS — degraded to no-op, never a false block.
#
# Self-locating: finds the sibling secret-scan via $0, so it works under any
# skill name / install path.

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)
if [ -n "$TOOL" ] && [ "$TOOL" != "Bash" ]; then exit 0; fi   # matcher scopes already; belt & braces

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || true)
[ -z "$CMD" ] && exit 0

# `git … push` in one command segment (not across |;&). `git stash push` is
# local-only — neutralize it before matching so it never triggers a scan.
CMD_X=$(printf '%s' "$CMD" | sed 's/stash[[:space:]][[:space:]]*push/stash-op/g')
printf '%s' "$CMD_X" | grep -qE '(^|[^[:alnum:]_-])git[[:space:]]+([^|;&]*[[:space:]])?push([[:space:]]|$|[^[:alnum:]_-])' || exit 0

HOOK_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P || echo "")
SECRET_SCAN="$HOOK_DIR/../scripts/secret-scan"
[ -x "$SECRET_SCAN" ] || exit 0

# Repo dir: explicit `-C <dir>` wins; else the tool call's cwd.
DIR=$(printf '%s' "$CMD" | grep -oE '(^|[^[:alnum:]_-])git[[:space:]]+-C[[:space:]]+[^[:space:]]+' | head -1 | sed -E 's/.*-C[[:space:]]+//' || true)
DIR=${DIR#\"}; DIR=${DIR%\"}; DIR=${DIR#\'}; DIR=${DIR%\'}
# SC2088: the "~" branch matches a LITERAL leading tilde in the extracted -C
# argument (quoting in the original command suppressed expansion) — we expand
# it ourselves here.
# shellcheck disable=SC2088
case "$DIR" in
  ''|\$*) DIR="" ;;                 # empty or unexpandable $VARIABLE literal
  "~"|"~/"*) DIR="$HOME${DIR#\~}" ;;
esac
if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
  DIR=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
fi
[ -n "$DIR" ] && [ -d "$DIR" ] || exit 0

OUT=$("$SECRET_SCAN" -C "$DIR" 2>/dev/null)
RC=$?

if [ "$RC" -eq 3 ]; then
  {
    echo "[secret-scan / PreToolUse hook] BLOCKED this git push — confirmed secret material in the unpushed range:"
    printf '%s\n' "$OUT"
    echo "A pushed secret is revoke-and-rotate, not revert (git-rules.md §Secret guard). STOP: alert the user, remove the secret from branch history (or rotate it), then re-run the Phase 4.1 gated block. Do NOT retry the push unchanged and do NOT push from another directory to dodge this check (anti-pattern §19g)."
  } >&2
  exit 2
fi

if [ "$RC" -eq 0 ] && [ -n "$OUT" ]; then
  FIRST=$(printf '%s\n' "$OUT" | head -1)
  jq -n --arg v "$FIRST" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      additionalContext: ("[secret-scan / PreToolUse hook] " + $v + " — if this push is a /do Phase 4.1 finalize, this verdict line (from a real wrapper run) is what belongs in the gates-json secret_scan entry.")
    }
  }'
  exit 0
fi

exit 0   # REJECT / crash / anything else → fail-open (allow)
