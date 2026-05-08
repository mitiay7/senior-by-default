#!/usr/bin/env bash
# senior-by-default skill installer.
# Idempotent: safe to re-run.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mitiay7/senior-by-default/main/install.sh | bash
# Or, after cloning:
#   ./install.sh
#
# Non-interactive mode (env vars override prompts):
#   SKILL_NAME=do TRIGGER=+++ INSTALL_DIR=~/.local/share/senior-by-default \
#     curl -fsSL .../install.sh | bash

set -euo pipefail

REPO_URL="https://github.com/mitiay7/senior-by-default.git"
DEFAULT_INSTALL_DIR="$HOME/.local/share/senior-by-default"
DEFAULT_SKILL_NAME="do"
DEFAULT_TRIGGER="+++"
CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"

# Markers for safe install/uninstall round-trip in CLAUDE.md
TRIGGER_BEGIN="<!-- senior-by-default:trigger:start -->"
TRIGGER_END="<!-- senior-by-default:trigger:end -->"

log()  { printf "▸ %s\n" "$*"; }
warn() { printf "⚠ %s\n" "$*" >&2; }
ok()   { printf "✓ %s\n" "$*"; }
die()  { printf "✗ %s\n" "$*" >&2; exit 1; }

# --- Interactive helpers (work under curl-pipe via /dev/tty) ----------------

if [ -e /dev/tty ] && [ -r /dev/tty ]; then
  TTY_IN=/dev/tty
else
  TTY_IN=/dev/stdin
fi

prompt() {
  # prompt <label> <default> <env-var-name>
  local label="$1" default="$2" envvar="$3" answer=""
  local override="${!envvar:-}"
  if [ -n "$override" ]; then
    printf "%s: %s (from \$%s)\n" "$label" "$override" "$envvar"
    echo "$override"
    return
  fi
  if [ -t 1 ]; then
    printf "%s [%s]: " "$label" "$default" >&2
    read -r answer < "$TTY_IN" || answer=""
  fi
  echo "${answer:-$default}"
}

confirm() {
  # confirm <prompt> <default-yn>
  local q="$1" def="$2" answer=""
  if [ -t 1 ]; then
    printf "%s [%s]: " "$q" "$def" >&2
    read -r answer < "$TTY_IN" || answer=""
  fi
  answer="${answer:-$def}"
  [[ "$answer" =~ ^[Yy] ]]
}

# --- Step 1: gather settings ------------------------------------------------

echo
echo "═══ senior-by-default installer ══════════════════════════════════════"
echo

INSTALL_DIR=$(prompt "Install directory" "$DEFAULT_INSTALL_DIR" "INSTALL_DIR")
SKILL_NAME=$(prompt "Skill name (becomes /$DEFAULT_SKILL_NAME slash-command)" "$DEFAULT_SKILL_NAME" "SKILL_NAME")
TRIGGER=$(prompt "Trigger shortcut (use 'none' to skip)" "$DEFAULT_TRIGGER" "TRIGGER")

# Validate skill name (must be valid filesystem name)
if ! [[ "$SKILL_NAME" =~ ^[a-z][a-z0-9_-]*$ ]]; then
  die "Skill name must be lowercase alphanumeric with - or _ (got '$SKILL_NAME')"
fi

echo
log "Plan:"
echo "  • Install repo at: $INSTALL_DIR"
echo "  • Symlink:         $CLAUDE_SKILLS_DIR/$SKILL_NAME → \$INSTALL_DIR/skills/do"
echo "  • Slash command:   /$SKILL_NAME"
if [ "$TRIGGER" != "none" ] && [ -n "$TRIGGER" ]; then
  echo "  • Trigger:         '$TRIGGER ...' → /$SKILL_NAME ..."
else
  echo "  • Trigger:         (skipped — use /$SKILL_NAME directly)"
fi
echo

# --- Step 2: hard-dependency check (fail-fast) ------------------------------

log "Checking required tools..."
hard_missing=()
for cmd in git python3; do
  command -v "$cmd" >/dev/null 2>&1 || hard_missing+=("$cmd")
done
if [ ${#hard_missing[@]} -gt 0 ]; then
  die "Missing required tools: ${hard_missing[*]} (install before running)"
fi

soft_missing=()
for cmd in jq gh; do
  command -v "$cmd" >/dev/null 2>&1 || soft_missing+=("$cmd")
done

# --- Step 3: clone / update repo --------------------------------------------

if [ -d "$INSTALL_DIR/.git" ]; then
  log "Existing install at $INSTALL_DIR — checking state"
  if ! git -C "$INSTALL_DIR" diff --quiet || ! git -C "$INSTALL_DIR" diff --cached --quiet; then
    warn "Local changes detected in $INSTALL_DIR — skipping pull"
    warn "Stash or commit them, then re-run install.sh"
  else
    log "Pulling latest"
    git -C "$INSTALL_DIR" pull --ff-only || warn "git pull --ff-only failed — your branch may have diverged"
  fi
else
  log "Cloning $REPO_URL → $INSTALL_DIR"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

# --- Step 4: symlink into ~/.claude/skills/ ---------------------------------

mkdir -p "$CLAUDE_SKILLS_DIR"
SYMLINK_PATH="$CLAUDE_SKILLS_DIR/$SKILL_NAME"
SYMLINK_TARGET="$INSTALL_DIR/skills/do"

if [ ! -d "$SYMLINK_TARGET" ]; then
  die "Expected $SYMLINK_TARGET to exist but it doesn't — install dir layout is wrong"
fi

if [ -L "$SYMLINK_PATH" ]; then
  CURRENT_TARGET=$(readlink "$SYMLINK_PATH")
  if [ "$CURRENT_TARGET" = "$SYMLINK_TARGET" ]; then
    ok "Symlink already correct"
  else
    warn "$SYMLINK_PATH points elsewhere ($CURRENT_TARGET)"
    if confirm "Replace it?" "N"; then
      rm "$SYMLINK_PATH"
      ln -s "$SYMLINK_TARGET" "$SYMLINK_PATH"
      ok "Symlink updated"
    else
      warn "Skipped symlink — your /$SKILL_NAME may not work"
    fi
  fi
elif [ -e "$SYMLINK_PATH" ]; then
  die "$SYMLINK_PATH exists and is NOT a symlink — move/remove it manually then re-run install.sh"
else
  ln -s "$SYMLINK_TARGET" "$SYMLINK_PATH"
  ok "Symlinked $SYMLINK_PATH → $SYMLINK_TARGET"
fi

# --- Step 5: customize SKILL.md if non-default name -------------------------

if [ "$SKILL_NAME" != "$DEFAULT_SKILL_NAME" ]; then
  log "Patching SKILL.md frontmatter for custom name '$SKILL_NAME'"
  python3 - "$SYMLINK_TARGET/SKILL.md" "$DEFAULT_SKILL_NAME" "$SKILL_NAME" <<'PY'
import re, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    content = f.read()
content = re.sub(r'^(name:\s*)' + re.escape(old) + r'\b', r'\1' + new, content, count=1, flags=re.MULTILINE)
content = re.sub(r'/' + re.escape(old) + r'(?=[\s).\\/]|$)', '/' + new, content)
with open(path, 'w') as f:
    f.write(content)
print("  patched")
PY
fi

# --- Step 6: trigger setup with begin/end markers (safe round-trip) ---------

if [ "$TRIGGER" != "none" ] && [ -n "$TRIGGER" ]; then
  TRIGGER_BLOCK=$(cat <<EOF


$TRIGGER_BEGIN
## ${TRIGGER} Trigger

When a user message starts with \`${TRIGGER}\`, treat everything after \`${TRIGGER}\` as the argument and invoke the \`/${SKILL_NAME}\` skill with that text. This is a shorthand — \`${TRIGGER} add user avatars\` is equivalent to \`/${SKILL_NAME} add user avatars\`.
$TRIGGER_END
EOF
)

  if [ -f "$CLAUDE_MD" ]; then
    if grep -qF "$TRIGGER_BEGIN" "$CLAUDE_MD" 2>/dev/null; then
      ok "Trigger block already present in $CLAUDE_MD (markers found)"
    elif confirm "Append trigger block to $CLAUDE_MD?" "Y"; then
      printf "%s\n" "$TRIGGER_BLOCK" >> "$CLAUDE_MD"
      ok "Trigger added to $CLAUDE_MD (between $TRIGGER_BEGIN ... $TRIGGER_END)"
    else
      log "Skipped. Add manually if you want it later:"
      echo "$TRIGGER_BLOCK"
    fi
  else
    log "Creating $CLAUDE_MD with trigger"
    mkdir -p "$(dirname "$CLAUDE_MD")"
    printf "# Global Instructions\n%s\n" "$TRIGGER_BLOCK" > "$CLAUDE_MD"
    ok "Created $CLAUDE_MD"
  fi
fi

# --- Step 7: soft-dependency status report ---------------------------------

if [ ${#soft_missing[@]} -gt 0 ]; then
  warn "Optional tools missing: ${soft_missing[*]}"
  warn "  • jq     — required for tracker output parsing (install before running tasks)"
  warn "  • gh     — required for GitHub tracker (install + run 'gh auth login')"
  warn "  macOS:    brew install ${soft_missing[*]}"
fi
if command -v gh >/dev/null 2>&1; then
  if ! gh auth status >/dev/null 2>&1; then
    warn "gh is installed but not authenticated. Run: gh auth login"
  else
    ok "gh authenticated"
  fi
fi

# --- Step 8: done ----------------------------------------------------------

cat <<EOF

═══════════════════════════════════════════════════════════════════════
✓ senior-by-default installed.

Next steps:

  1. Configure your project. From your project root:

       mkdir -p .claude/do
       cp $INSTALL_DIR/examples/minimal-config.json .claude/do/config.json
       \$EDITOR .claude/do/config.json    # set issue_tracker.repo

     For multi-repo / monorepo / Python / Rust, see:
       $INSTALL_DIR/examples/

  2. Run your first task in any Claude Code session:

EOF
if [ "$TRIGGER" != "none" ] && [ -n "$TRIGGER" ]; then
  printf "       %s add a /health endpoint that checks DB connectivity\n" "$TRIGGER"
  printf "     (or)  /%s add a /health endpoint ...\n" "$SKILL_NAME"
else
  printf "       /%s add a /health endpoint that checks DB connectivity\n" "$SKILL_NAME"
fi
cat <<EOF

  3. Uninstall any time:
       $INSTALL_DIR/uninstall.sh

Documentation: $INSTALL_DIR/README.md
Schema:        $INSTALL_DIR/skills/do/references/config-schema.md
Issues:        https://github.com/mitiay7/senior-by-default/issues

EOF
