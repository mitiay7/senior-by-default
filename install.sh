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

log()  { printf "▸ %s\n" "$*"; }
warn() { printf "⚠ %s\n" "$*" >&2; }
ok()   { printf "✓ %s\n" "$*"; }

# --- Interactive helpers (work under curl-pipe via /dev/tty) ----------------

# tty_in: stream to read user input from. /dev/tty if available, else stdin.
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
  warn "Skill name must be lowercase alphanumeric with - or _ (got '$SKILL_NAME')"
  exit 1
fi

echo
log "Plan:"
echo "  • Install repo at: $INSTALL_DIR"
echo "  • Symlink:         $CLAUDE_SKILLS_DIR/$SKILL_NAME → \$INSTALL_DIR"
echo "  • Slash command:   /$SKILL_NAME"
if [ "$TRIGGER" != "none" ] && [ -n "$TRIGGER" ]; then
  echo "  • Trigger:         '$TRIGGER ...' → /$SKILL_NAME ..."
else
  echo "  • Trigger:         (skipped — use /$SKILL_NAME directly)"
fi
echo

# --- Step 2: clone / update repo --------------------------------------------

if [ -d "$INSTALL_DIR/.git" ]; then
  log "Updating existing install at $INSTALL_DIR"
  git -C "$INSTALL_DIR" pull --ff-only
else
  log "Cloning $REPO_URL → $INSTALL_DIR"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

# --- Step 3: symlink into ~/.claude/skills/ ---------------------------------

mkdir -p "$CLAUDE_SKILLS_DIR"
SYMLINK_PATH="$CLAUDE_SKILLS_DIR/$SKILL_NAME"

if [ -L "$SYMLINK_PATH" ]; then
  CURRENT_TARGET=$(readlink "$SYMLINK_PATH")
  if [ "$CURRENT_TARGET" = "$INSTALL_DIR" ]; then
    ok "Symlink already correct"
  else
    warn "$SYMLINK_PATH points elsewhere ($CURRENT_TARGET)"
    if confirm "Replace it?" "N"; then
      rm "$SYMLINK_PATH"
      ln -s "$INSTALL_DIR" "$SYMLINK_PATH"
      ok "Symlink updated"
    else
      warn "Skipped symlink — your /$SKILL_NAME may not work"
    fi
  fi
elif [ -e "$SYMLINK_PATH" ]; then
  warn "$SYMLINK_PATH exists and is NOT a symlink — won't overwrite"
  warn "Move/remove it manually, then re-run install.sh"
  exit 1
else
  ln -s "$INSTALL_DIR" "$SYMLINK_PATH"
  ok "Symlinked $SYMLINK_PATH → $INSTALL_DIR"
fi

# --- Step 4: customize SKILL.md if non-default name -------------------------

if [ "$SKILL_NAME" != "$DEFAULT_SKILL_NAME" ]; then
  log "Patching SKILL.md frontmatter for custom name '$SKILL_NAME'"
  # Replace `name: do` (frontmatter), `/do` (slash-command refs), and `do` skill mentions in description
  python3 - "$INSTALL_DIR/SKILL.md" "$DEFAULT_SKILL_NAME" "$SKILL_NAME" <<'PY'
import re, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    content = f.read()

# 1. Frontmatter `name: <old>` → `name: <new>`
content = re.sub(r'^(name:\s*)' + re.escape(old) + r'\b', r'\1' + new, content, count=1, flags=re.MULTILINE)

# 2. /<old> slash-command references → /<new>  (only when followed by space, paren, period, slash, or end)
content = re.sub(r'/' + re.escape(old) + r'(?=[\s).\\/]|$)', '/' + new, content)

with open(path, 'w') as f:
    f.write(content)
print("  patched")
PY
fi

# --- Step 5: trigger setup (optional) --------------------------------------

if [ "$TRIGGER" != "none" ] && [ -n "$TRIGGER" ]; then
  TRIGGER_HEADER="## ${TRIGGER} Trigger"
  TRIGGER_BLOCK=$(cat <<EOF


${TRIGGER_HEADER}

When a user message starts with \`${TRIGGER}\`, treat everything after \`${TRIGGER}\` as the argument and invoke the \`/${SKILL_NAME}\` skill with that text. This is a shorthand — \`${TRIGGER} add user avatars\` is equivalent to \`/${SKILL_NAME} add user avatars\`.
EOF
)

  if [ -f "$CLAUDE_MD" ]; then
    if grep -qF "$TRIGGER_HEADER" "$CLAUDE_MD" 2>/dev/null; then
      ok "Trigger already configured in $CLAUDE_MD"
    elif confirm "Append trigger to existing $CLAUDE_MD?" "Y"; then
      printf "%s\n" "$TRIGGER_BLOCK" >> "$CLAUDE_MD"
      ok "Trigger added to $CLAUDE_MD"
    else
      log "Skipped. Add this manually to $CLAUDE_MD when ready:"
      echo "$TRIGGER_BLOCK"
    fi
  else
    log "Creating $CLAUDE_MD with trigger"
    mkdir -p "$(dirname "$CLAUDE_MD")"
    printf "# Global Instructions\n%s\n" "$TRIGGER_BLOCK" > "$CLAUDE_MD"
    ok "Created $CLAUDE_MD"
  fi
fi

# --- Step 6: dependency check ----------------------------------------------

echo
log "Checking dependencies..."
missing=()
for cmd in git jq python3; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
command -v gh >/dev/null 2>&1 || missing+=("gh (GitHub CLI)")

if [ ${#missing[@]} -gt 0 ]; then
  warn "Missing tools: ${missing[*]}"
  warn "macOS: brew install ${missing[*]}"
  warn "Linux: use your distro's package manager"
fi

if command -v gh >/dev/null 2>&1; then
  if ! gh auth status >/dev/null 2>&1; then
    warn "gh is installed but not authenticated. Run: gh auth login"
  else
    ok "gh authenticated"
  fi
fi

# --- Step 7: done ----------------------------------------------------------

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

Documentation: $INSTALL_DIR/README.md
Schema:        $INSTALL_DIR/references/config-schema.md
Issues:        https://github.com/mitiay7/senior-by-default/issues

EOF
