# Phase 0 — Setup & Routing

Read this when entering Phase 0 (every task starts here). Everything below runs before Phase 1+.

## Preflight — intent clarity + minimal path

Before any side effects (issue creation, worktree creation, commits, pushes), read `$ARGUMENTS` and decide whether the task is clear enough to execute.

- If multiple interpretations would produce different behavior or data contracts, STOP and ask the user.
- If one reasonable interpretation exists but there are assumptions, proceed only after recording the assumptions in the Phase 0 announce and, for M/H, the issue body.
- Prefer the smallest path that meets the user goal. If the user asked for a broad change but a narrower change clearly satisfies the goal, surface the tradeoff before proceeding.
- Convert the request into concrete pass/fail acceptance criteria before Phase 1 (M/H) or Phase 2 (T/L).

## Steps

Phase 0 is **6 logical steps**, not 12 sub-phases. Conditional bullets are inline; they only fire when relevant config or context is present.

### 1. Load + validate config

Walk CWD upward for `.claude/do/config.json`. First match wins. Defaults defined in [`config-schema.md`](config-schema.md) (single-repo, no issue tracker, no UI/i18n gates, no specialists, no context doc).

- **Found** → validate per [`config-validation.md`](config-validation.md). Hard error → STOP. Warnings → print and proceed. Set:
  ```bash
  CONFIG_FOUND=1
  CONFIG_LINE="Config: LOADED $CONFIG_PATH"
  ```
- **None** → set `CONFIG_FOUND=0`. Use in-memory defaults for now. **Auto-init is DEFERRED to the end of Step 4** (needs stack-detect output to populate `_meta.auto_generated_for_stack`). `CONFIG_LINE` will be set there.

**Conditional, inline**:
- `config.wip_limit` set → count `git worktree list` + open issues assigned to user; warn if sum > limit. Opt-in only; default disabled. (Kanban WIP limits derive from human team context-switching cost; in AI-orchestrated workflows with isolated agent contexts, parallel sessions are usually a strength — leave unset unless you specifically want a soft ceiling.)
- `config.postmortem.trigger_keywords` match `$ARGUMENTS` OR branch matches `branch_prefixes` (e.g. `fix/...`) → suggest `/postmortem` skill if installed, else add `## Postmortem` section to Phase 1 issue body (cause / impact / detection / mitigation / prevention).

### 2. Companion-skill detect — caveman

Skip if `--no-caveman` in `$ARGUMENTS` (set `CAVEMAN_LINE=""` in that case — announce will omit the line). Otherwise — **run this bash verbatim** (do not paraphrase, do not "check mentally", do not compose the announce line yourself — see [anti-patterns §19b](anti-patterns.md)):

```bash
CAVEMAN_STATUS="NOT INSTALLED"
unset CAVEMAN_PATH
for p in \
  "$HOME/.claude/skills/caveman" \
  "$HOME/.claude/plugins/cache/caveman" \
  "$HOME/.claude/plugins/cache/JuliusBrussee/caveman" \
  "$HOME/.agents/skills/caveman"; do
  if [ -f "$p/SKILL.md" ]; then CAVEMAN_STATUS="ACTIVE"; CAVEMAN_PATH="$p"; break; fi
done
if [ "$CAVEMAN_STATUS" = "ACTIVE" ]; then
  CAVEMAN_LINE="Caveman: ACTIVE (path: $CAVEMAN_PATH)"
else
  CAVEMAN_LINE="Caveman: NOT INSTALLED — install: curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash"
fi
echo "$CAVEMAN_LINE"
```

**The bash builds the FULL announce line, including the install hint.** The spec deliberately contains no other copyable template of either form — if you "know what the line looks like" without running the bash, you're guessing, and Phase 0 will emit a fabricated value (production-confirmed failure mode, same as `metrics-append` bypass). The Phase 0 announce template at the bottom references `$CAVEMAN_LINE` literally; no `$CAVEMAN_LINE` = no announce line = visible bug.

Path-list rationale: positions 1–3 are the canonical Claude Code install locations (`curl … install.sh` script, plugin cache by short name, plugin cache by owner/repo). Position 4 covers the agent-skill manager which installs to `~/.agents/skills/` and may or may not also symlink into `~/.claude/skills/` depending on the user's setup. `[ -f "$p/SKILL.md" ]` (not `[ -d "$p" ]`) — resolves symlinks correctly and rejects empty directories from failed installs.

When `CAVEMAN_STATUS=ACTIVE`, Sub-Agent prompts get the caveman-style directive (see [`phase-2-implementation.md`](phase-2-implementation.md) Rules section). Caveman is **passive** (SessionStart hook); once active, all assistant output flows through compression. No runtime wrapping needed — only the prompt directive.

### 3. Resolve target repo(s)

If `$ARGUMENTS` has `--repo=NAME` → use that.

Else if `config.workspace.repos` exists → match `$ARGUMENTS` against each repo's `scope_keywords`:
- 1 match → that repo
- multiple → fullstack (multiple worktrees)
- 0 → ask user

Else → CWD must be inside a git repo. Use `git rev-parse --show-toplevel`.

### 4. Stack cache (load or detect)

For each target repo, compute cache slug from absolute path. Slug rule: replace every run of non-alphanumeric characters with a single `-`, then strip leading/trailing `-`. Example: `/Users/alice/work/api` → `Users-alice-work-api`. Cache file: `~/.claude/do/cache/<slug>.json`. Full canonical algorithm: [`stack-detection.md`](stack-detection.md).

**Load cache** (default):
- Verify `cache.version == 1`
- Verify `cache.repo_path` matches current repo's absolute path (guards slug collisions — `/Users/alice/work-api` and `/Users/alice/work/api` collide to same slug)
- If `$ARGUMENTS` doesn't contain `--redetect` (or NL equivalent like "re-detect stack") → use cache, skip to step 5

**Detect** (cache miss / version mismatch / `--redetect`):
- Run detection per [`stack-detection.md`](stack-detection.md)
- If `nx.json` or `turbo.json` present, set `affected_graph_tool`. Override build/test commands if `config.affected_graph` enabled.
- Write result to cache. Always include canonical `repo_path`.

Cache fields used throughout phases 1–4: `stack`, `package_manager`, `build_cmds`, `lint_cmds`, `test_cmd`, `ui_files`, `ui_extensions`, `migration_dir`, `migration_pattern`, `affected_graph_tool`. Never re-derive mid-task.

**Auto-init config (only if Step 1 set `CONFIG_FOUND=0` AND `--no-config-init` not in `$ARGUMENTS`)** — **run this bash verbatim** (do not Write a `config.json` by hand, do not compose `$CONFIG_LINE` yourself — see [anti-patterns §19c](anti-patterns.md)):

```bash
# Detect tracker from git remote (origin). Bash parameter expansion only —
# avoids sed regex with `](...)` that confuses markdown link parsers.
REMOTE_URL="$(git -C "$REPO" remote get-url origin 2>/dev/null || true)"
case "$REMOTE_URL" in
  *github.com*) TRACKER="github"; TR_PATH="${REMOTE_URL##*github.com[:/]}"; TRACKER_REPO="${TR_PATH%.git}" ;;
  *gitlab.com*) TRACKER="gitlab"; TR_PATH="${REMOTE_URL##*gitlab.com[:/]}"; TRACKER_REPO="${TR_PATH%.git}" ;;
  *)            TRACKER="none"; TRACKER_REPO="" ;;
esac

# Call the wrapper. Captures full stdout/stderr into CONFIG_LINE — the wrapper
# itself emits the canonical line on success ("Config: AUTO-GENERATED → …"),
# and "REJECT …" / "IOFAIL …" on the skip paths (already exists, refused
# context, missing tooling). Either way, $CONFIG_LINE is the announce token.
if [ "$TRACKER" = "none" ]; then
  CONFIG_LINE="$(~/.claude/skills/do/scripts/config-init \
    --repo-root "$REPO" --tracker none --stack "$STACK" 2>&1)" \
    || CONFIG_LINE="Config: AUTO-INIT SKIPPED — $CONFIG_LINE"
else
  CONFIG_LINE="$(~/.claude/skills/do/scripts/config-init \
    --repo-root "$REPO" --tracker "$TRACKER" --tracker-repo "$TRACKER_REPO" --stack "$STACK" 2>&1)" \
    || CONFIG_LINE="Config: AUTO-INIT SKIPPED — $CONFIG_LINE"
fi
echo "$CONFIG_LINE"
```

**Refuse paths (script-side, all produce `AUTO-INIT SKIPPED`, not errors)**:
- Repo root is `$HOME` or `/` — script refuses (looks like a stray `/do` invocation, not a project).
- Repo IS senior-by-default (has `skills/do/SKILL.md` at root) — script refuses to bootstrap its own config.
- `config.json` already exists — refuses to overwrite (Step 1 already loaded it; this branch shouldn't execute, but defense in depth).
- `jq` not installed — refuses with reason.

The generated file is **minimum-viable**: `version + _meta + issue_tracker + issue_locale`. Specialists, `context_doc`, `workspace.repos`, `ui_gate`, `acceptance_extensions`, `naming` overrides — all left for the user to add by extending the file (the `_setup_notes` field in `_meta` points at `examples/` for templates). The file is left unstaged — user reviews and commits when ready. Subsequent `/do` runs re-read it on each Phase 0, so no reload needed after extension.

If `--no-config-init` was passed → skip this block entirely, set `CONFIG_LINE="Config: NONE — using defaults (--no-config-init)"`.

### 5. Sanity checks

**Duplicate check** (only if tracker configured AND ≠ `none`):
- Run `{Tracker.list_open}` from [`trackers.md`](trackers.md). Default for github: `gh issue list --repo {repo} --state open --limit 20`.

**Always**:
- `git -C {repo} branch -a`
- `git -C {repo} worktree list`

Duplicate issue or branch → STOP, ask user. Stale worktrees → warn.

**Concurrent-edit check** (`config.concurrent_edit_check.enabled`, default true) — only when Phase 1 identifies planned files:

```bash
# REQUIRED: refresh origin/main first — otherwise reads stale ref, misses recent activity
git -C "$REPO" fetch origin main --quiet
git -C "$REPO" log --since="${LOOKBACK_DAYS} days ago" --name-only --pretty="%h %an" origin/main -- $PLANNED_FILES
```

Recent commits on planned files → WARN with author+SHA list. Proceed; note overlap.

**Migration detection** (only if `cache.migration_dir != null`):
- Next migration number: `ls {repo}/{migration_dir}/{migration_pattern} | sort -V | tail -1` + 1
- Conflict check across other branches: `git -C {repo} branch -a | xargs -I{} git log {} --oneline -- {migration_dir} 2>/dev/null`
- Conflict → STOP, ask user to serialize

**Context doc check** (only if `config.context_doc.required_for_finalize: true`):
- Set BLOCKING flag for Phase 4 finalize
- Read context doc now if exists; pass to Sonnet in Phase 2 (trim relevant sections if huge)

### 6. Complexity routing + model assignment + announce

If `$ARGUMENTS` has `--complexity=T|L|M|H` → use it.

Else estimate:

| Complexity | Indicators | Workflow |
|---|---|---|
| **Trivial** | 1-2 files, mechanical (typo/rename/comment/lint/dep bump/single constant), zero logic decisions | Haiku solo → Sonnet diff scan → commit |
| **Low** | ≤3 files, single module, simple logic | Sonnet solo → Opus diff scan → commit |
| **Medium** | 4-8 files, new module/API | Issue → Sonnet → Opus review |
| **High** | 9+ files, new architecture, breaking changes | Full pipeline + specialists + ADR |

Boundaries: 4 trivial files in one module → prefer Low. 3 files spanning new API surface → prefer Medium. **Any judgment call about behaviour → bump to Low** (Haiku must not pick between alternatives). If task touches migrations, security-sensitive code, public API, or i18n — never Trivial.

Ambiguity about user intent or observable behavior is never Trivial. Ask if it changes the outcome; otherwise record the assumption and choose the lowest complexity bucket that can verify the acceptance criteria.

**Test detection**: YES for new functions/services/handlers, logic changes, algorithms. NO for pure UI/CSS, config, docs. Test command from `cache.test_cmd`; if `affected_graph_tool` enabled, scope via `nx affected:test` / `turbo run test --filter=...[main]`.

**Model assignment**:
- Orchestrator: always `opus` (per SKILL.md frontmatter `model: opus`)
- Implementer: T → `haiku`; L/M/H → `sonnet`
- `--implementer=X` flag overrides (announce as `implementer=X (override)`)

**Optional: notify start** if `config.notifications.events` includes `task_started`. See [`notifications.md`](notifications.md).

### Announce

After all 6 steps pass:

```
[Phase 0] Repo: {repo} | Stack: {stack} (cached: {y/n}) | Scope: {B/F/FS} | Complexity: {T/L/M/H}
  Files: ~{N} | Tests: {YES/NO} | Migration: {YES NNN/NO} | Context doc: {required/none}
  Models: orchestrator=opus | implementer={haiku|sonnet|opus per complexity, or override}
  {$CAVEMAN_LINE — output of Step 2 bash, verbatim — DO NOT compose}
  {$CONFIG_LINE — output of Step 1 (LOADED) or Step 4 auto-init bash (AUTO-GENERATED | AUTO-INIT SKIPPED | NONE), verbatim — DO NOT compose}
  WIP: {n}/{limit} | Affected-graph: {nx/turbo/none}
  [+ if assumptions recorded → "Assumptions: {short list}"]
  [+ if simpler path chosen → "Tradeoff: {short explanation of narrower implementation}"]
  [+ if concurrent edits → "⚠ Concurrent edits on planned files in last {N} days"]
  [+ if postmortem context → "ℹ Postmortem section will be added to issue"]
```

`Models:`, `$CAVEMAN_LINE`, and `$CONFIG_LINE` are **mandatory** — they make model usage, companion-skill state, and config state explicit so users see (and metrics record) what the orchestrator decided.

The two structural-coupling lines (`$CAVEMAN_LINE`, `$CONFIG_LINE`) come **only** from the bash blocks in Step 2 / Step 4 auto-init respectively. The spec deliberately contains no copyable templates of their full form — if you "know what the line looks like" without running the bash, you're guessing. This is the same structural-enforcement pattern as `$METRICS_LINE` in Phase 4.13 (see [`phase-4-finalize.md`](phase-4-finalize.md) and [anti-patterns §19, §19a, §19b, §19c](anti-patterns.md)).

Suppression paths:
- `--no-caveman` → Step 2 skipped, `$CAVEMAN_LINE=""`, line omitted from announce.
- `--no-config-init` → Step 4 auto-init skipped, `$CONFIG_LINE="Config: NONE — using defaults (--no-config-init)"`, line still printed.
