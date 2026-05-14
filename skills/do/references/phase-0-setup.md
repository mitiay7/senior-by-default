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

Walk CWD upward for `.claude/do/config.json`. First match wins. None → use defaults (single-repo, no issue tracker, no UI/i18n gates, no specialists, no context doc). Defaults defined in [`config-schema.md`](config-schema.md).

If config found → validate per [`config-validation.md`](config-validation.md). Hard error → STOP. Warnings → print and proceed.

**Conditional, inline**:
- `config.wip_limit` set → count `git worktree list` + open issues assigned to user; warn if sum > limit. Opt-in only; default disabled. (Kanban WIP limits derive from human team context-switching cost; in AI-orchestrated workflows with isolated agent contexts, parallel sessions are usually a strength — leave unset unless you specifically want a soft ceiling.)
- `config.postmortem.trigger_keywords` match `$ARGUMENTS` OR branch matches `branch_prefixes` (e.g. `fix/...`) → suggest `/postmortem` skill if installed, else add `## Postmortem` section to Phase 1 issue body (cause / impact / detection / mitigation / prevention).

### 2. Companion-skill detect — caveman

Skip if `--no-caveman` in `$ARGUMENTS`.

Detect [caveman](https://github.com/JuliusBrussee/caveman) at one of:
- `$HOME/.claude/skills/caveman`
- `$HOME/.claude/plugins/cache/caveman`
- `$HOME/.claude/plugins/cache/JuliusBrussee/caveman`

- **Found** → `Caveman: ACTIVE (output compressed)`. Sub-Agent prompts get caveman-style directive (see [`phase-2-implementation.md`](phase-2-implementation.md) Rules section).
- **Not found** → `Caveman: NOT INSTALLED — install: curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash`. Continue without; caveman is recommended, not required.

Caveman is **passive** (SessionStart hook). Once active, all assistant output flows through compression. No runtime wrapping needed — only the prompt directive.

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
  WIP: {n}/{limit} | Affected-graph: {nx/turbo/none}
  [+ if assumptions recorded → "Assumptions: {short list}"]
  [+ if simpler path chosen → "Tradeoff: {short explanation of narrower implementation}"]
  [+ if concurrent edits → "⚠ Concurrent edits on planned files in last {N} days"]
  [+ if postmortem context → "ℹ Postmortem section will be added to issue"]
  [+ if caveman active/missing → "Caveman: ACTIVE|NOT INSTALLED ..."]
```

The `Models:` line is mandatory — makes model usage explicit so users see (and metrics record) which model handles which role for this task.
