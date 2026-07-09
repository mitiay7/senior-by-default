#!/usr/bin/env bash
# senior-by-default uninstaller. Reverses install.sh idempotently.
#
# Usage:
#   ~/.local/share/senior-by-default/uninstall.sh
#
# Non-interactive (env var overrides):
#   PURGE_INSTALL_DIR=1 PURGE_CACHE=1 PURGE_METRICS=1 \
#     ~/.local/share/senior-by-default/uninstall.sh

set -euo pipefail

CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
CACHE_DIR="$HOME/.claude/do/cache"
METRICS_DIR="$HOME/.claude/do/metrics"

TRIGGER_BEGIN="<!-- senior-by-default:trigger:start -->"
TRIGGER_END="<!-- senior-by-default:trigger:end -->"

# Discover this script's own dir = INSTALL_DIR
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INSTALL_DIR="$SCRIPT_DIR"

log()  { printf "▸ %s\n" "$*"; }
warn() { printf "⚠ %s\n" "$*" >&2; }
ok()   { printf "✓ %s\n" "$*"; }

if [ -e /dev/tty ] && [ -r /dev/tty ]; then
  TTY_IN=/dev/tty
else
  TTY_IN=/dev/stdin
fi

confirm() {
  local q="$1" def="$2" answer="" override="${3:-}"
  if [ -n "$override" ]; then
    answer="$override"
  elif [ -t 1 ]; then
    printf "%s [%s]: " "$q" "$def" >&2
    read -r answer < "$TTY_IN" || answer=""
  fi
  answer="${answer:-$def}"
  [[ "$answer" =~ ^[Yy1] ]]
}

echo
echo "═══ senior-by-default uninstaller ════════════════════════════════════"
echo
log "Install dir: $INSTALL_DIR"
echo

# --- Step 1: remove symlinks pointing into our INSTALL_DIR ------------------

log "Scanning $CLAUDE_SKILLS_DIR for symlinks pointing into $INSTALL_DIR"
removed_links=0
if [ -d "$CLAUDE_SKILLS_DIR" ]; then
  for link in "$CLAUDE_SKILLS_DIR"/*; do
    [ -L "$link" ] || continue
    target=$(readlink "$link")
    case "$target" in
      "$INSTALL_DIR"/*|"$INSTALL_DIR")
        rm "$link"
        ok "Removed symlink $link → $target"
        removed_links=$((removed_links + 1))
        ;;
    esac
  done
fi
[ $removed_links -eq 0 ] && log "No symlinks pointed into $INSTALL_DIR"

# --- Step 2: strip trigger block from ~/.claude/CLAUDE.md -------------------

if [ -f "$CLAUDE_MD" ] && grep -qF "$TRIGGER_BEGIN" "$CLAUDE_MD"; then
  log "Removing trigger block from $CLAUDE_MD"
  # Use python for portable in-place block removal (sed multi-line is BSD/GNU divergent)
  python3 - "$CLAUDE_MD" "$TRIGGER_BEGIN" "$TRIGGER_END" <<'PY'
import sys, re
path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    text = f.read()
pattern = re.compile(
    r'\n*' + re.escape(begin) + r'.*?' + re.escape(end) + r'\n*',
    re.DOTALL,
)
new = pattern.sub('\n', text)
with open(path, 'w') as f:
    f.write(new)
PY
  ok "Trigger block removed (kept the rest of $CLAUDE_MD intact)"
else
  log "No trigger block found in $CLAUDE_MD (or file doesn't exist) — skipping"
fi

# --- Step 2.5: remove enforcement hook entries from ~/.claude/settings.json --

# Reverses install.sh Step 6.5 (opt-in hooks merge). Step 1 removed the symlink
# those hook commands resolve through — leaving the entries behind means
# missing-script hook errors on every Stop, every Task spawn, and every Bash
# call, in every project, with nothing attributing them to this skill. Matched
# by script basename (do-metrics-stop-gate.sh / do-plan-size-pretooluse.sh /
# do-secret-scan-pretooluse.sh / do-pr-size-pretooluse.sh), so custom-skill-name
# installs and manual settings.with-hooks.json merges are covered too.
# Fail-open: an un-editable settings.json warns and never aborts the rest of
# the uninstall.

SETTINGS_JSON="$HOME/.claude/settings.json"
HOOK_RE='do-(metrics-stop-gate|plan-size-pretooluse|secret-scan-pretooluse|pr-size-pretooluse)\.sh'
HOOKS_SUMMARY="No /do enforcement hook entries in $SETTINGS_JSON — nothing to remove"

if [ -f "$SETTINGS_JSON" ] && grep -qE "$HOOK_RE" "$SETTINGS_JSON" 2>/dev/null; then
  if command -v jq >/dev/null 2>&1; then
    log "Removing /do enforcement hook entries from $SETTINGS_JSON"
    backup="$SETTINGS_JSON.bak.$(date +%s)"
    tmp=$(mktemp)
    if jq --arg re "$HOOK_RE" '
        if (.hooks | type) == "object" then
          .hooks |= (
            with_entries(
              if (.value | type) == "array" then
                .value |= (
                  map(if (.hooks | type) == "array"
                      then .hooks |= map(select((.command // "") | test($re) | not))
                      else . end)
                  | map(select((.hooks | type) != "array" or (.hooks | length) > 0))
                )
              else . end
            )
            | with_entries(select((.value | type) != "array" or (.value | length) > 0))
          )
          | if (.hooks | length) == 0 then del(.hooks) else . end
        else . end
      ' "$SETTINGS_JSON" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      cp "$SETTINGS_JSON" "$backup"
      mv "$tmp" "$SETTINGS_JSON"
      ok "Hook entries removed (backup: $backup)"
      HOOKS_SUMMARY="Removed /do enforcement hook entries from $SETTINGS_JSON (backup: $backup)"
    else
      rm -f "$tmp"
      warn "Could not edit $SETTINGS_JSON (invalid JSON?) — left untouched."
      warn "Remove the Stop/PreToolUse entries whose command ends in"
      warn "do-metrics-stop-gate.sh / do-plan-size-pretooluse.sh /"
      warn "do-secret-scan-pretooluse.sh / do-pr-size-pretooluse.sh manually,"
      warn "then run /hooks in Claude Code to confirm they're gone."
      HOOKS_SUMMARY="LEFT IN PLACE: /do hook entries in $SETTINGS_JSON (file un-editable) — remove manually"
    fi
  else
    warn "jq not found — cannot remove /do enforcement hook entries from $SETTINGS_JSON."
    warn "Without removal, Claude Code errors on every Stop, Task spawn, and Bash"
    warn "call (the hook scripts no longer exist). Remove manually: open"
    warn "$SETTINGS_JSON and delete the Stop/PreToolUse entries whose command ends"
    warn "in do-metrics-stop-gate.sh / do-plan-size-pretooluse.sh /"
    warn "do-secret-scan-pretooluse.sh / do-pr-size-pretooluse.sh, then run"
    warn "/hooks in Claude Code to confirm they're gone."
    HOOKS_SUMMARY="LEFT IN PLACE: /do hook entries in $SETTINGS_JSON (jq missing) — remove manually"
  fi
else
  log "No /do enforcement hook entries in $SETTINGS_JSON — skipping"
fi

# --- Step 3: optional purges ------------------------------------------------

PURGE_INSTALL=${PURGE_INSTALL_DIR:-}
PURGE_CACHE_VAR=${PURGE_CACHE:-}
PURGE_METRICS_VAR=${PURGE_METRICS:-}

if [ -d "$CACHE_DIR" ] && [ -n "$(ls -A "$CACHE_DIR" 2>/dev/null)" ]; then
  if confirm "Delete stack-detection cache at $CACHE_DIR?" "N" "$PURGE_CACHE_VAR"; then
    rm -rf "$CACHE_DIR"
    ok "Cache deleted"
  else
    log "Cache kept at $CACHE_DIR"
  fi
fi

if [ -d "$METRICS_DIR" ] && [ -n "$(ls -A "$METRICS_DIR" 2>/dev/null)" ]; then
  if confirm "Delete metrics logs at $METRICS_DIR?" "N" "$PURGE_METRICS_VAR"; then
    rm -rf "$METRICS_DIR"
    ok "Metrics deleted"
  else
    log "Metrics kept at $METRICS_DIR (you may want them for skill iteration)"
  fi
fi

if confirm "Delete install dir $INSTALL_DIR?" "N" "$PURGE_INSTALL"; then
  cd /
  rm -rf "$INSTALL_DIR"
  ok "Install dir deleted"
else
  log "Install dir kept at $INSTALL_DIR"
fi

# --- Step 4: done ----------------------------------------------------------

cat <<EOF

═══════════════════════════════════════════════════════════════════════
✓ senior-by-default uninstalled.

What was touched:
  • Removed any symlinks in $CLAUDE_SKILLS_DIR pointing at $INSTALL_DIR
  • Stripped the begin/end-marked trigger block from $CLAUDE_MD (if present)
  • $HOOKS_SUMMARY
  • Optionally purged: cache, metrics, install dir (per your answers)

What was NOT touched:
  • Project-level configs (.claude/do/config.json in your repos)
  • The rest of ~/.claude/CLAUDE.md
  • Everything else in $SETTINGS_JSON (only /do hook entries are ever removed)
  • Any project-side worktrees or branches

Re-install any time:
  curl -fsSL https://raw.githubusercontent.com/mitiay7/senior-by-default/main/install.sh | bash

EOF
