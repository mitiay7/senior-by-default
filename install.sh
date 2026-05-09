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
#   SKILL_NAME=do INSTALL_DIR=~/.local/share/senior-by-default \
#     curl -fsSL .../install.sh | bash

set -euo pipefail

REPO_URL="https://github.com/mitiay7/senior-by-default.git"
DEFAULT_INSTALL_DIR="$HOME/.local/share/senior-by-default"
DEFAULT_SKILL_NAME="do"
CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"

# Markers used by uninstall.sh to clean up legacy +++ trigger blocks
# from earlier installs (v0.2.0–v0.2.3) that wrote them. New installs
# don't write trigger blocks because the skill has disable-model-invocation:
# true — a CLAUDE.md instruction asking the model to invoke /do via Skill
# tool gets blocked. Use a CLI-level UserPromptSubmit hook in
# ~/.claude/settings.json if you want a +++ shortcut (see README
# Troubleshooting section).
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
  # Returns the chosen value on stdout. ALL user-facing prints go to stderr —
  # otherwise they'd be captured into the value by `VAR=$(prompt ...)` and break
  # downstream validation (e.g. `[[ "$VAR" =~ ^[a-z]... ]]` would see the entire
  # banner string as the "value"). This bit hard in v0.2.0–v0.2.2 under
  # env-var override (`SKILL_NAME=do curl ... | bash`); fixed in v0.2.3.
  local label="$1" default="$2" envvar="$3" answer=""
  local override="${!envvar:-}"
  if [ -n "$override" ]; then
    printf "%s: %s (from \$%s)\n" "$label" "$override" "$envvar" >&2
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

# Validate skill name (must be valid filesystem name)
if ! [[ "$SKILL_NAME" =~ ^[a-z][a-z0-9_-]*$ ]]; then
  die "Skill name must be lowercase alphanumeric with - or _ (got '$SKILL_NAME')"
fi

echo
log "Plan:"
echo "  • Install repo at: $INSTALL_DIR"
echo "  • Symlink:         $CLAUDE_SKILLS_DIR/$SKILL_NAME → \$INSTALL_DIR/skills/do"
echo "  • Slash command:   /$SKILL_NAME"
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

# --- Step 4: resolve symlink target (pristine vs rendered) ------------------

# Pristine source — never modified, so `git pull` always works.
PRISTINE_SOURCE="$INSTALL_DIR/skills/do"
if [ ! -d "$PRISTINE_SOURCE" ]; then
  die "Expected $PRISTINE_SOURCE to exist but it doesn't — install dir layout is wrong"
fi

if [ "$SKILL_NAME" = "$DEFAULT_SKILL_NAME" ]; then
  # Default name: symlink directly to pristine source (no copy needed)
  SYMLINK_TARGET="$PRISTINE_SOURCE"
else
  # Custom name: regenerate a patched copy in .rendered-skills/<name>/
  # This dir is gitignored, so the pristine clone stays clean for `git pull`.
  RENDERED_ROOT="$INSTALL_DIR/.rendered-skills"
  RENDERED_DIR="$RENDERED_ROOT/$SKILL_NAME"
  log "Generating patched skill copy at $RENDERED_DIR"
  rm -rf "$RENDERED_DIR"
  mkdir -p "$RENDERED_DIR"
  cp -R "$PRISTINE_SOURCE/." "$RENDERED_DIR/"
  python3 - "$RENDERED_DIR/SKILL.md" "$DEFAULT_SKILL_NAME" "$SKILL_NAME" <<'PY'
import re, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    content = f.read()
# Frontmatter `name: <old>` → `name: <new>`
content = re.sub(r'^(name:\s*)' + re.escape(old) + r'\b', r'\1' + new, content, count=1, flags=re.MULTILINE)
# Slash-command refs `/<old>` → `/<new>` (where followed by space, paren, period, slash, or EOL)
content = re.sub(r'/' + re.escape(old) + r'(?=[\s).\\/]|$)', '/' + new, content)
with open(path, 'w') as f:
    f.write(content)
print(f"  patched RENDERED copy (pristine source untouched)")
PY
  SYMLINK_TARGET="$RENDERED_DIR"
fi

# --- Step 5: symlink into ~/.claude/skills/ ---------------------------------

mkdir -p "$CLAUDE_SKILLS_DIR"
SYMLINK_PATH="$CLAUDE_SKILLS_DIR/$SKILL_NAME"

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

# --- Step 6: legacy trigger cleanup ----------------------------------------

# Versions 0.2.0–0.2.3 wrote a "+++ Trigger" block to ~/.claude/CLAUDE.md
# instructing the model to invoke /do via Skill tool when seeing +++.
# That trigger never worked because the skill has disable-model-invocation:
# true (Skill-tool invocations are blocked, including supposedly-explicit
# ones). On install/update, we offer to strip the legacy marker-wrapped
# block so users aren't left with a dead instruction in their CLAUDE.md.
# Use a CLI-level UserPromptSubmit hook in ~/.claude/settings.json if you
# want a `+++` shortcut — see README "Troubleshooting" / "Shortcut setup".

if [ -f "$CLAUDE_MD" ] && grep -qF "$TRIGGER_BEGIN" "$CLAUDE_MD" 2>/dev/null; then
  warn "Found legacy +++ trigger block in $CLAUDE_MD (broken since skill has disable-model-invocation: true)"
  if confirm "Remove the legacy block?" "Y"; then
    python3 - "$CLAUDE_MD" "$TRIGGER_BEGIN" "$TRIGGER_END" <<'PY'
import sys, re
path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    text = f.read()
pattern = re.compile(r'\n*' + re.escape(begin) + r'.*?' + re.escape(end) + r'\n*', re.DOTALL)
new = pattern.sub('\n', text)
with open(path, 'w') as f:
    f.write(new)
PY
    ok "Legacy trigger block removed (rest of $CLAUDE_MD preserved)"
  else
    log 'Kept legacy block. It does nothing — /do <task> works regardless.'
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

       /$SKILL_NAME add a /health endpoint that checks DB connectivity

     (Want a shorter prefix like \`+++\`? It can't go through SKILL.md
     description because the skill has \`disable-model-invocation: true\`
     for safety. Set up a CLI-level UserPromptSubmit hook in
     ~/.claude/settings.json instead — see README "Shortcut setup".)

  3. Uninstall any time:
       $INSTALL_DIR/uninstall.sh

Documentation: $INSTALL_DIR/README.md
Schema:        $INSTALL_DIR/skills/do/references/config-schema.md
Issues:        https://github.com/mitiay7/senior-by-default/issues

EOF
