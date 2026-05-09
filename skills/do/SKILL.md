---
name: do
version: 0.2.5
model: opus
disable-model-invocation: true
description: |
  Multi-actor implementation pipeline for Claude Code. Routes coding tasks by complexity (Trivial→Haiku, Low/Medium→Sonnet, High→Opus plan + Sonnet impl), creates issue in tracker, runs gated review (PR-size, dep-vuln, i18n, contract, zero-downtime migration audit), opens PR with optional CI gate and auto-merge.
  TRIGGER when: user invokes /do; task describes a coding change (≥1 file modified or created, defined outcome); `.claude/do/config.json` present in repo or workspace root.
  SKIP when: pure Q&A or explanation; code review without implementation; scaffolding-from-scratch ("create new project"); exploratory ("how would I…"); single-line edits where the pipeline is overkill.
---

<!--
Frontmatter rationale:
- `model: opus` — pins the orchestrator (Phase 0 routing, Phase 3 review,
  Phase 4 decisions) to Opus regardless of session model. Implementation
  delegates to Sonnet/Haiku via explicit `Agent(model: "...")` calls.
- `disable-model-invocation: true` — skill performs side effects (creates
  issues, commits, pushes, opens PRs, optionally auto-merges). It must
  fire only on explicit `/do` slash-command invocation, never
  auto-discovered from description matching mid-conversation. Note this
  also blocks Skill-tool invocation, so any "shortcut" mechanism (e.g.
  rewriting `+++ X` → `/do X`) MUST happen at CLI level (e.g. a
  `UserPromptSubmit` hook in `~/.claude/settings.json`), not via a
  CLAUDE.md instruction asking the model to invoke this skill.
-->


# Multi-Actor Implementation Pipeline

## Notation conventions

This SKILL.md uses shorthand for Claude Code primitives — clarification for adopters reading the source:

- **`Agent(model: "<X>")`** — invoke the Task tool with the `subagent_type` mapping to model `<X>`. Concrete subagent types come from installed plugins (e.g. `code-refactoring:code-reviewer`); when none specified, harness defaults are used.
- **Worktree creation** — always explicit `git worktree add` (per [`references/git-rules.md`](references/git-rules.md)). The Task tool's `isolation: "worktree"` parameter is **forbidden** here because it auto-names branches, breaking `config.naming` traceability.
- **`<current model from environment>`** — Co-Authored-By footer reads the running model identifier from the harness session metadata (e.g. "Claude Opus 4.7 (1M context)"). Never hardcode a model version.

> **Opus** — analysis, issue creation, code review, merge decisions. NEVER writes code **except** when explicitly invoked via `--implementer=opus` (rare: deep algorithmic, security-critical, complex concurrency). When Opus implements, the Phase 3 Opus review MUST be a fresh cold-context `Agent` invocation — independence of review is preserved by separation of context, not separation of model.
> **Sonnet** (`Agent(model: "sonnet")`) — plan, implement, test, self-review. NEVER makes architectural decisions. Also reviews Haiku's diffs for Trivial tasks.
> **Haiku** (`Agent(model: "haiku")`) — Trivial mechanical changes only (1-2 files, no logic decisions). NEVER touches Medium/High tasks. NEVER reviews its own work.
> **No backwards compat** — clean breaks only. No re-exports, `_unused` vars, shims.
> **Context doc is mandatory IF configured.** Sonnet reads it before exploring; Phase 4 updates it.

**Input**: `$ARGUMENTS`

## Progressive disclosure — load references on demand

Do NOT preload these. Read each only when its trigger fires.

| When | Read |
|---|---|
| Reading or writing `.claude/do/config.json` | [`references/config-schema.md`](references/config-schema.md) |
| Validating config on load | [`references/config-validation.md`](references/config-validation.md) |
| Phase 0 stack detection or cache I/O | [`references/stack-detection.md`](references/stack-detection.md) |
| Any tracker operation (issue create/edit/comment, PR description close keywords) | [`references/trackers.md`](references/trackers.md) |
| Any git operation | [`references/git-rules.md`](references/git-rules.md) |
| Phase 1 (M/H) — issue creation | [`references/phase-1-issue.md`](references/phase-1-issue.md) |
| Phase 2 — Sonnet prompt construction, plan review, self-review, stale-main check | [`references/phase-2-implementation.md`](references/phase-2-implementation.md) |
| Phase 3 — gates (incl. PR-size + dep-vuln + public-docs), specialist audit, Opus review | [`references/phase-3-review.md`](references/phase-3-review.md) |
| Phase 4 — commit, push, PR, CI gate, auto-merge, finalize | [`references/phase-4-finalize.md`](references/phase-4-finalize.md) |
| Migration audit specialist | [`references/zero-downtime-migrations.md`](references/zero-downtime-migrations.md) |
| Specialist audit + PR reviewer routing | [`references/codeowners.md`](references/codeowners.md) |
| ADR generation (High) | [`references/adr.md`](references/adr.md) |
| Slack/Teams notifications | [`references/notifications.md`](references/notifications.md) |
| Pre-finalize sanity check | [`references/anti-patterns.md`](references/anti-patterns.md) |

Example real-world configs (at repo root):
- [`multi-repo-go-react-config.json`](../../examples/multi-repo-go-react-config.json) — multi-repo workspace (Go API + React web + docs + GitHub)
- [`minimal-config.json`](../../examples/minimal-config.json) — single-repo with GitHub only
- [`python-fastapi-config.json`](../../examples/python-fastapi-config.json) — Python + Alembic + GitHub
- [`rust-workspace-config.json`](../../examples/rust-workspace-config.json) — Rust workspace + GitLab tracker

## $ARGUMENTS handling

Sanitize: strip injection-enabling characters only — `` ` ``, `$()`, `;`, `|`, `&`, `>` followed by a path. **Preserve all Unicode letters** (Cyrillic, CJK, etc.).

Recognize override flags (free-form — accept natural-language equivalents too):

| Flag | Effect |
|---|---|
| `--redetect` | Force stack re-detection (skip cache) |
| `--repo=NAME` | Force target repo (skip routing) |
| `--complexity=T\|L\|M\|H` | Force complexity bucket (T = Trivial → Haiku) |
| `--implementer=opus\|sonnet\|haiku` | Override default implementer for this task. See "Implementer override" below. |
| `--auto-merge` / `--no-auto-merge` | Force auto-merge ON/OFF for this task |
| `--skip-ci-wait` | Don't wait for CI before final announce |
| `--no-self-review` | Skip Sonnet self-review (Phase 2.5) |
| `--no-codeowners` | Skip CODEOWNERS-based reviewer routing |
| `--no-notify` | Skip notifications for this task |
| `--no-affected-graph` | Run full build/test even if monorepo affected-graph is detected |
| `--no-caveman` | Skip companion-skill detection ([caveman](https://github.com/JuliusBrussee/caveman) output compression) for this task |

### Implementer override

By default the implementer is determined by complexity bucket: T → Haiku, L/M/H → Sonnet. `--implementer=` overrides this **for Phase 2 only** — review/audit/merge stay on Opus.

| Override | Allowed on | Effect |
|---|---|---|
| `--implementer=opus` | M/H (rare: deep algorithmic, security-critical, complex concurrency, novel architecture) | Phase 2 spawns `Agent(model: "opus")` instead of Sonnet. **Phase 3 Opus review MUST run as a fresh `Agent(model: "opus")` invocation with no shared context** — the reviewer must not see the implementer's reasoning trace. Announce as "Implementer: Opus (cold-context review required)". |
| `--implementer=sonnet` | T (elevates Trivial to Low-style flow) | Phase 2 spawns Sonnet; Phase 3 diff-scan upgrades to Opus instead of Sonnet. Effectively `--complexity=L` minus the issue-skip warning. |
| `--implementer=haiku` | T only | No-op (already default). On M/H → **HARD REJECT**: Haiku must not make logic decisions on multi-file or architectural work. |

`--implementer=opus` does NOT skip specialists, ADR, CODEOWNERS routing, or PR-size guards. It only changes who writes the code.

If `--implementer=opus` AND complexity is L → warn ("Opus on Low is overkill — proceed?") but honor.

## PHASE 0 — SETUP & ROUTING

### 0.0 Find & validate config
Walk CWD upward for `.claude/do/config.json`. First match wins. None → use defaults (single-repo, no issue tracker, no UI/i18n gates, no specialists, no context doc). Defaults defined in [`references/config-schema.md`](references/config-schema.md).

If config found → validate per [`references/config-validation.md`](references/config-validation.md). Hard error → STOP. Warnings → print and proceed.

### 0.0.1 WIP limit check
**Skipped if `config.wip_limit` is not set** (no default — feature is opt-in).

If set to a positive integer:
- Count active worktrees: `git -C {each known repo} worktree list | grep -v '(bare)' | wc -l` (subtract 1 for main worktree)
- Count open issues assigned to user: `{Tracker.list_open}` filtered for assignee — only if tracker configured
- Sum > limit → warn: `"In-flight work: {N} (limit {M}). Consider finishing existing tasks before starting another."`. Don't block.

WIP limits derive from Kanban literature for **human** teams where context-switching cost is real. In an AI-orchestrated workflow with isolated agent contexts, parallel sessions are often a strength, not a cost — leave `wip_limit` unset unless you specifically want a soft ceiling.

### 0.0.2 Postmortem trigger
If `config.postmortem.trigger_keywords` matches `$ARGUMENTS` OR `$ARGUMENTS` mentions a branch matching `config.postmortem.branch_prefixes` (e.g. `fix/...`):
- Suggest invoking a `/postmortem` skill if installed
- Otherwise: add a `## Postmortem` section to the issue body in Phase 1 (cause, impact, detection, mitigation, prevention)

### 0.0.3 Companion skills (token-saving — caveman) — load FIRST

**Run before any Phase 1+ work** so Sub-Agents spawned later inherit token-compressed mode.

Skip if `--no-caveman` flag in `$ARGUMENTS`.

Detect [`caveman`](https://github.com/JuliusBrussee/caveman) (the Claude Code skill that compresses agent output ~75% via "caveman speak", preserving technical accuracy):

```bash
test -d "$HOME/.claude/skills/caveman" \
  || test -d "$HOME/.claude/plugins/cache/caveman" \
  || test -d "$HOME/.claude/plugins/cache/JuliusBrussee/caveman"
```

- **Found** → caveman's SessionStart hook auto-activates compression. Print: `Caveman: ACTIVE (output compressed)`. Note for Phase 2 prompt construction: Sub-Agents will be instructed to respond in caveman style.
- **Not found** → print: `Caveman: NOT INSTALLED — agent outputs will not be compressed. Install for ~75% output token savings: curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash`. Continue without it (caveman is recommended, not required).

Caveman is **passive** — once active, all assistant output (Opus orchestration AND Sub-Agent responses) flows through its compression hook. No wrapping needed in our Phase 2 spawn calls; just instruct the Sub-Agent in its prompt that caveman style applies.

### 0.1 Resolve target repo(s)

If `$ARGUMENTS` contains `--repo=NAME` → use that.

Else if `config.workspace.repos` exists → match `$ARGUMENTS` against each repo's `scope_keywords`:
- 1 match → that repo
- multiple → fullstack mode (multiple worktrees)
- 0 → ask user

Else → CWD must be inside a git repo. Use `git rev-parse --show-toplevel` as the single target.

### 0.2 Stack detection (with cache) — **DO NOT re-detect if cached**

For each target repo:

1. Compute cache slug from the repo's absolute path. Slug rule (see [`references/stack-detection.md`](references/stack-detection.md) for canonical version): replace every run of non-alphanumeric characters with a single `-`, then strip leading/trailing `-`. Example: `/Users/alice/work/api` → `Users-alice-work-api`.
2. Cache file: `~/.claude/do/cache/<slug>.json`.
3. **If cache file exists**:
   - Load it
   - Verify `cache.version == 1`
   - **Verify `cache.repo_path` matches the current repo's absolute path** — guards against slug collisions (e.g. `/Users/alice/work-api` and `/Users/alice/work/api` collide to the same slug). If mismatch → treat as cache miss, re-detect, overwrite.
   - If all checks pass AND `$ARGUMENTS` does NOT contain `--redetect` (or natural-language equivalent like "re-detect stack", "пере-определи стек") → **USE CACHE AS-IS, skip detection entirely**
4. **Else** (no cache, version mismatch, repo_path mismatch, or explicit `--redetect`):
   - Run detection per [`references/stack-detection.md`](references/stack-detection.md)
   - Detect monorepo affected-graph tool: if `nx.json` or `turbo.json` present, set `affected_graph_tool` accordingly. Override build/test commands if `config.affected_graph` enabled.
   - Write the result to cache file (mkdir -p the cache dir if missing). Always include the canonical `repo_path` field.

Cache contains: `stack`, `package_manager`, `build_cmds`, `lint_cmds`, `test_cmd`, `ui_files`, `ui_extensions`, `migration_dir`, `migration_pattern`, `affected_graph_tool`. Use these throughout phases 1-4 — never re-derive them mid-task.

### 0.3 Duplicate + concurrent-edit checks

Only if `config.issue_tracker.type` is set and ≠ `"none"`:
- Run `{Tracker.list_open}` from [`references/trackers.md`](references/trackers.md) (default for `github`: `gh issue list --repo {repo} --state open --limit 20`)

Always:
- `git -C {repo} branch -a`
- `git -C {repo} worktree list`

Duplicate issue or branch → STOP, ask user. Stale worktrees → warn.

If `config.concurrent_edit_check.enabled` (default true) AND Phase 1 will identify planned files:

```bash
# REQUIRED: refresh origin/main first — otherwise we miss recent commits
git -C "$REPO" fetch origin main --quiet
# Then check
git -C "$REPO" log --since="${LOOKBACK_DAYS} days ago" --name-only --pretty="%h %an" origin/main -- $PLANNED_FILES
```

Recent commits on planned files → WARN with author+SHA list. Proceed but note the overlap.

Without the `git fetch`, the check reads stale `origin/main` and silently misses new activity — exactly the failure mode it's meant to prevent.

### 0.4 Complexity & scope

If `$ARGUMENTS` has `--complexity=L|M|H` → use it.

Else estimate:

| Complexity | Indicators | Workflow |
|---|---|---|
| **Trivial** | 1-2 files, mechanical change (typo/rename/comment/lint fix/dep version bump/single constant), zero logic decisions | Haiku solo → Sonnet diff scan → commit |
| **Low** | ≤3 files, single module, simple logic | Sonnet solo → Opus diff scan → commit |
| **Medium** | 4-8 files, new module/API | Issue → Sonnet → Opus review |
| **High** | 9+ files, new architecture, breaking changes | Full pipeline + specialists + ADR |

Boundaries: 4 trivial files in one module → prefer Low. 3 files spanning new API surface → prefer Medium. **Any judgment call about behaviour → bump to Low** (Haiku must not pick between alternatives). If task touches migrations, security-sensitive code, public API, or i18n — never Trivial.

Announce override: `Complexity: {override} (was: {suggested})`.

### 0.5 Test detection
**YES**: new functions/services/handlers, logic changes, algorithms.
**NO**: pure UI/CSS, config, docs.

Test command: from cache (`test_cmd`). If `affected_graph_tool` and `config.affected_graph` enabled → use `nx affected:test --base={base_ref}` / `turbo run test --filter=...[{base_ref}]` instead.

### 0.6 Migration detection
Only if `cache.migration_dir != null`.

Next migration number:
```
ls {repo}/{migration_dir}/{migration_pattern} | sort -V | tail -1
```
+ 1.

Conflict check across other branches:
```
git -C {repo} branch -a | xargs -I{} git log {} --oneline -- {migration_dir} 2>/dev/null
```
Conflict detected → STOP, ask user to serialize.

### 0.7 Context doc check
If `config.context_doc.required_for_finalize: true`:
- Set BLOCKING flag for Phase 4.6
- Read context doc now if it exists; pass full text to Sonnet in Phase 2 (or trim to relevant sections if huge)

If not configured → skip Phase 4.6 entirely.

### 0.8 Notify start
If `config.notifications` configured AND `task_started` in events → send. See [`references/notifications.md`](references/notifications.md). Use Phase 1 issue URL if M/H, else inline summary.

### Announce (only after all 0.x checks pass)
```
[Phase 0] Repo: {repo} | Stack: {stack} (cached: {y/n}) | Scope: {B/F/FS} | Complexity: {T/L/M/H}
  Files: ~{N} | Tests: {YES/NO} | Migration: {YES NNN/NO} | Context doc: {required/none}
  WIP: {n}/{limit} | Affected-graph: {nx/turbo/none}
  [+ if concurrent edits → "⚠ Concurrent edits on planned files in last {N} days"]
  [+ if postmortem context → "ℹ Postmortem section will be added to issue"]
```

## PHASES 1-4 — load reference per phase

Read the corresponding reference file when entering each phase.

| Phase | Always-run? | Reference |
|---|---|---|
| 1 — Issue creation | M/H only (skipped for T/L) | [`references/phase-1-issue.md`](references/phase-1-issue.md) |
| 2 — Implementation + self-review + stale-main check + ADR (High) | L/M/H (Trivial uses simplified flow below) | [`references/phase-2-implementation.md`](references/phase-2-implementation.md) |
| 3 — Code review (gates + PR size + dep vuln + public docs + CODEOWNERS audit + Opus review) | L/M/H (Trivial uses Sonnet diff-scan only) | [`references/phase-3-review.md`](references/phase-3-review.md) |
| 4 — Finalize (commit, push, PR, CI gate, auto-merge, context doc, comment, lessons, metrics, notify) | always | [`references/phase-4-finalize.md`](references/phase-4-finalize.md) |

For Low complexity: skip Phase 1, simplified Phase 3.5 only (diff scan + dep vuln scan), no PR in Phase 4 (just push + change summary), still emit metrics + notification if configured.

For Trivial complexity:
- **Phase 1**: skip (no issue).
- **Phase 2**: spawn `Agent(model: "haiku")` with a tightly scoped prompt — exact files + exact change requested. Haiku does NOT explore the codebase, does NOT make architectural decisions, does NOT touch tests. If Haiku reports anything ambiguous → **abort and re-route to Low** (Sonnet).
- **Phase 3**: skip all gates except dep-vuln (only if deps changed). Run a `Agent(model: "sonnet")` diff-scan with one question: "does this diff do exactly what was asked, nothing more?" — Sonnet flags scope creep, accidental edits, secrets, syntax errors. Reject + retry once if issues found; second failure → re-route to Low.
- **Phase 4**: commit + push to worktree branch. **No PR**, no context-doc update, no ADR. Emit metrics + notification if configured. Co-Author on the commit is `Claude Haiku 4.5` (not the parent model).
- **Worktree rule still applies** — Trivial does not bypass `git rules`.

Before announcing completion, scan [`references/anti-patterns.md`](references/anti-patterns.md) as a sanity check.

## Top-level git constraints (full rules: [`references/git-rules.md`](references/git-rules.md))

- Worktree only — never `git checkout -b`, never `git clone`
- Never commit to `main`
- Never `--force`/`--force-with-lease`/`--hard`/`--amend`/`--no-verify`
- Never modify `.git/config` or `core.hooksPath`
- Never commit `.env*`/`*.key`/`*.pem`/`credentials.*`/`*.secret`
- Verify `git diff --cached --name-only` + content before every push
- `Co-Authored-By: <current model from environment>` — auto-detect, never hardcode

## Top-level anti-patterns (full list: [`references/anti-patterns.md`](references/anti-patterns.md))

Re-detecting stack on every run · Re-exploring code instead of trusting `context_doc` · Subjective reviews · Tests after review · Scope creep · Opus writing code without `--implementer=opus` flag · Opus reviewing its own implementation in the same context (cold-context required when `--implementer=opus`) · Haiku making logic decisions or skipping its diff-scan · Hardcoded user-facing strings (if i18n configured) · Committing secrets · Amending migrations · Finalizing without context doc update (if required) · Adding deps not in Requirements · Bypassing CODEOWNERS · Skipping zero-downtime migration audit · Auto-merge without CI configured (only relevant if BOTH ci.required AND auto_merge.enabled are set) · **Skipping Phase 4.11 metrics emission when `config.metrics.log_path` is set** · **Using `Agent(isolation: "worktree")` for Phase 2** (auto-named branches break `config.naming` traceability — Opus pre-creates worktree via `git worktree add`) · **Auto-named branches without `i{N}` for M/H** (Phase 4.1.0 renames + flags as spec violation in metrics) · **Shell-injecting `{title}`/`{labels}` into tracker commands** (user-controlled `$ARGUMENTS` reaches title — pass via env vars or argv-array `commands` form, never via raw shell-string templates; see `references/trackers.md` §Security) · **Compressing structured output when caveman is active** — caveman style applies to natural-language framing only; code, paths, JSON, diffs, `claimed_status` self-review block, Phase 4.11 metrics JSONL, and final announce format are LITERAL and MUST stay un-compressed (they're parsed by downstream tooling).
