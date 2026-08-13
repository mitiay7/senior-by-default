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
# push` excluded). Unlike the metrics/plan-size hooks this one is deliberately
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
# Repo-dir resolution for the scan, in order (lea-docs#1463):
#   1. `git -C <dir> push` → <dir> (after quote stripping; a `$VARIABLE` path
#      cannot be expanded here and falls through);
#   2. a `cd <dir>` / `pushd <dir>` earlier in the SAME command — this is how a
#      push from a worktree is actually written (`cd <worktree> && git push`),
#      and it names the directory the push will really run in;
#   3. the hook input's `.cwd` — the SESSION's directory, which in the /do flow
#      is almost never the worktree being pushed.
#
# Whatever step 1–3 yields, an EMPTY range there is treated as a wrong guess and
# not as a clean bill: the hook then scans every worktree of that repository
# holding commits ahead of origin/main and unions the verdicts.
#
# The old comment here called the fallback harmless — "worst case the fallback
# scans the wrong repo and yields an empty-range PASS — degraded to no-op, never
# a false block". Half of that was true: there is no false block. But the no-op
# PRINTED A PASS, and /do §4.1 instructs the model to paste that line into
# gates.secret_scan as proof the gate ran. Reproduced live on 2026-08-13: a
# commit containing a password assignment was allowed through while the hook
# reported `range f1c451e..f1c451e clean (0 commits, 0 files)`.
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

# SC2088: the "~" branches below match a LITERAL leading tilde in an extracted
# argument (quoting in the original command suppressed expansion) — we expand it
# ourselves here.
# shellcheck disable=SC2088
normalize_dir() {
  local d="$1"
  d=${d#\"}; d=${d%\"}; d=${d#\'}; d=${d%\'}
  case "$d" in
    ''|\$*) d="" ;;                 # empty or unexpandable $VARIABLE literal
    "~"|"~/"*) d="$HOME${d#\~}" ;;
  esac
  printf '%s' "$d"
}

# 1. explicit `git -C <dir>`
DIR=$(normalize_dir "$(printf '%s' "$CMD" | grep -oE '(^|[^[:alnum:]_-])git[[:space:]]+-C[[:space:]]+[^[:space:]]+' | head -1 | sed -E 's/.*-C[[:space:]]+//' || true)")

# 2. `cd <dir>` / `pushd <dir>` in the same command. This is the shape a push
#    from a worktree actually takes — `cd <worktree> && git push` — so it is a
#    far better answer than the session cwd. Last one wins: a command may cd
#    more than once, and the effective directory is the final one.
if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
  DIR=$(normalize_dir "$(printf '%s' "$CMD" | grep -oE '(^|[^[:alnum:]_-])(cd|pushd)[[:space:]]+[^[:space:];&|]+' | tail -1 | sed -E 's/.*(cd|pushd)[[:space:]]+//' || true)")
fi

# 3. the session's cwd
if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
  DIR=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
fi
[ -n "$DIR" ] && [ -d "$DIR" ] || exit 0

block_push() { # $1 = scan output
  {
    echo "[secret-scan / PreToolUse hook] BLOCKED this git push — confirmed secret material in the unpushed range:"
    printf '%s\n' "$1"
    echo "A pushed secret is revoke-and-rotate, not revert (git-rules.md §Secret guard). STOP: alert the user, remove the secret from branch history (or rotate it), then re-run the Phase 4.1 gated block. Do NOT retry the push unchanged and do NOT push from another directory to dodge this check (anti-pattern §19g)."
  } >&2
  exit 2
}

allow_with() { # $1 = additionalContext text
  jq -n --arg v "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      additionalContext: $v
    }
  }'
  exit 0
}

OUT=$("$SECRET_SCAN" -C "$DIR" 2>/dev/null)
RC=$?

[ "$RC" -eq 3 ] && block_push "$OUT"

if [ "$RC" -eq 0 ] && [ -n "$OUT" ]; then
  allow_with "[secret-scan / PreToolUse hook] $(printf '%s\n' "$OUT" | head -1) — if this push is a /do Phase 4.1 finalize, this verdict line (from a real wrapper run) is what belongs in the gates-json secret_scan entry."
fi

# RC 4 = INCONCLUSIVE: the chosen directory had nothing to scan. Do not stop
# here — that is the exact state in which the push being gated lives in ANOTHER
# worktree of the same repository (lea-docs#1463). Scan every worktree holding
# commits ahead of origin/main and union the verdicts: one BLOCK blocks.
if [ "$RC" -eq 4 ]; then
  SCANNED=""
  while IFS= read -r wt; do
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    [ "$wt" = "$DIR" ] && continue
    AHEAD=$(git -C "$wt" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
    [ "${AHEAD:-0}" -gt 0 ] 2>/dev/null || continue
    WOUT=$("$SECRET_SCAN" -C "$wt" 2>/dev/null)
    WRC=$?
    [ "$WRC" -eq 3 ] && block_push "$WOUT"
    [ "$WRC" -eq 0 ] && SCANNED="${SCANNED}${SCANNED:+; }$(printf '%s\n' "$WOUT" | head -1)"
  done < <(git -C "$DIR" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')

  if [ -n "$SCANNED" ]; then
    allow_with "[secret-scan / PreToolUse hook] the directory this hook resolved ($DIR) had NOTHING to scan, so every sibling worktree ahead of origin/main was scanned instead: $SCANNED — use the verdict whose [dir: …] matches the directory this push runs from; the others are not evidence for it."
  fi

  allow_with "[secret-scan / PreToolUse hook] NOT SCANNED — $(printf '%s\n' "$OUT" | head -1). No sibling worktree of that repository holds commits ahead of origin/main either. This is NOT a pass: do NOT put it in the gates-json secret_scan entry. Before pushing, run the wrapper against the directory this push actually runs from: secret-scan -C <that-directory>."
fi

exit 0   # REJECT / crash / anything else → fail-open (allow)
