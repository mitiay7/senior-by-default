# Phase 1 — Issue Creation (Medium / High only)

**Skip entirely if** `config.issue_tracker` is missing, or `type == "none"`. For Low complexity, also skip (no issue is needed — Sonnet runs from inline task description).

**Skips are announced, never silent** — print exactly one line, then move on:

- Plain none/missing: `[Phase 1] SKIPPED — tracker: none`
- Degraded none (config carries `_meta.tracker_degraded_from`, or Phase 0's `$CONFIG_LINE` included a `Tracker: DEGRADED to none (…)` line): `[Phase 1] SKIPPED — tracker: none (DEGRADED from {github|gitlab}: {tracker_degraded_reason})` — repeat the reason at the phase that lost functionality; the Phase 0 announce alone scrolls away, and a silent skip reads as "worked as configured" when the truth is "tracker CLI missing/unauthenticated" (audit #13).
- Low complexity: `[Phase 1] SKIPPED — Low complexity (inline task description)`

Downstream stays consistent with [`trackers.md`](trackers.md) §none: no `Closes #N`, no `Ref:` in commits, no issue comments in Phase 4.

## Tracker abstraction

All tracker operations go through `config.issue_tracker.commands` (defaults filled per `type` — see [`trackers.md`](trackers.md)).

In this document, `{Tracker.OP}` denotes the operation `OP`. **Execution is argv-safe** — user-controlled `{title}` and `{labels}` are passed via env vars (built-in github/gitlab) or argv array slots (custom trackers), never substituted into shell strings. See [`trackers.md`](trackers.md) §Security for the threat model and the concrete invocation pattern.

For multi-line bodies, write to a temp file first (`mktemp`), then pass the path as `{body_file}` — body content stays out of shell entirely.

## Labels
- **Required**: `config.issue_tracker.required_labels` (always applied)
- **Optional**: `config.issue_tracker.optional_labels` (apply if relevant: phase markers, type tags)
- **Domain**: pick applicable subset of `config.issue_tracker.domain_labels` (the affected feature areas)

Joined as comma-separated string for `{labels}` placeholder.

## Two-step pattern (chicken-and-egg with issue number)

Issue body needs the issue number for the worktree-setup block; create returns the number. Workaround:

1. Write body to temp file with literal `{ISSUE_NUM}` placeholder
2. Run `{Tracker.create}` — capture id from stdout (URL trailing integer for github/gitlab)
3. Substitute `{ISSUE_NUM}` → actual id (ALL occurrences — the line-1 execute callout and the worktree-setup block both carry it)
4. Run `{Tracker.edit_body}` with updated file

Verify: `{Tracker.view_body} | grep -c ISSUE_NUM` → `0`. Persistent placeholder → retry once → on second failure: alert user, do NOT proceed to Phase 2.

## Naming

Use `config.naming.issue` (defaults: `worktree_suffix: "i{N}"`, `branch: "feat/i{N}-{slug}"`, `ref_format: "i{N}"`).

`{slug}` = kebab-case derivation from `$ARGUMENTS` (lowercase, alphanum + hyphens, max 40 chars). Strip leading/trailing hyphens.

`{N}` = the just-created issue id (e.g. `42`, `eng-123`).

## Identify planned files (for concurrent-edit + CODEOWNERS)

Before writing the issue body, derive the rough list of files the task will touch:
- Affected files from `## Implementation Hints` section
- Files matching keywords in `$ARGUMENTS` (grep the codebase)
- New files implied by the task

This list feeds the concurrent-edit check (next section) AND Phase 4.2 CODEOWNERS reviewer routing.

## Concurrent-edit check (`config.concurrent_edit_check.enabled`, default true)

Run immediately after the planned-files list above exists — moved here from Phase 0 Step 5, where it was circularly sequenced (it needs Phase 1's planned files; audit #19):

```bash
# PLANNED_FILES is an ARRAY, and the pathspec is expanded quoted. An unquoted
# scalar (`-- $PLANNED_FILES`) relies on the shell word-splitting it — bash does,
# **zsh does not**. Under zsh the whole list collapses into ONE pathspec with
# spaces in it, which matches nothing, so git prints no commits and exits 0 — the
# gate reports "no concurrent edits" for every multi-file task and the failure is
# SILENT (production: an entire session ran with this gate permanently green).
# Quoted array expansion behaves identically under bash and zsh, and survives
# paths containing spaces.
PLANNED_FILES=(internal/foo/service.go internal/foo/repository.go)   # from the Est deltas list

# REQUIRED: refresh origin/main first — otherwise reads stale ref, misses recent activity
git -C "$REPO" fetch origin main --quiet
git -C "$REPO" log --since="${LOOKBACK_DAYS} days ago" --name-only --pretty="%h %an" origin/main -- "${PLANNED_FILES[@]}"
```

`LOOKBACK_DAYS` = `config.concurrent_edit_check.lookback_days` (default 7). Recent commits on planned files → WARN with author+SHA list; proceed. The warning rides in two places: the issue body's Implementation Hints (template below) and the Phase 1 announce.

**Empty output is a verdict, not a pass — sanity-check it.** This gate's failure mode is silence, so an empty result on a repo with any history deserves one probe before you believe it: re-run with a single known-touched path and confirm you get commits back. A gate that cannot fail is not a gate ([anti-patterns §25](anti-patterns.md)).

## Issue body template

Conditional markers `[+ if X → "..."]` mean: include only if X is true; remove markers in final output.

Locale: `config.issue_locale`. Below shows `en` as canonical; for `ru` use the Russian callout and prologue.

**Line 1 is the execute callout — the literal first line of the body.** No heading above it, no preamble, never inside `<details>`. Trackers truncate the body to the first ~150 chars in list views — the callout must surface in list previews, email notifications, and Slack link unfurls. Locale variants and tracker adaptations: see [Locale-specific callout & prologues](#locale-specific-callout--prologues).

```
> 🚀 **Execute:** `+++ #{ISSUE_NUM}` — runs the `/do` skill (routes by complexity, plans, implements, gates, opens PR). Or paste this issue URL after `+++`.

{Prologue — locale-dependent}

[+ if context_doc → "Before starting, read `{context_doc.path}` — it has the project structure, conventions, current state, and open work. Do not re-explore the repos."
                  | ru: "Перед началом прочитай `{context_doc.path}` — там структура проекта, конвенции, текущее состояние и открытые задачи. Не пере-исследуй репозитории."]

[+ if any non-obvious assumption or tradeoff was resolved before issue creation → "### Assumptions / Tradeoffs
{short list of assumptions accepted, rejected broader scope, or simpler path chosen. If ambiguity remains that changes behavior, do not create the issue yet — ask the user first.}"]

### Context — {why, architecture fit, deps}

### Requirements — {checklist of concrete deliverables}

### Acceptance Criteria — pass/fail
- All requirements implemented (each checkbox maps to a diff)
- Every changed line traces to a requirement, acceptance criterion, or cleanup introduced by this change
- Tests pass (happy path + error path per public function with branching)
- Build passes: {full build/lint/test command list from cache.build_cmds + cache.lint_cmds + cache.test_cmd}
- No regressions (no deleted assertions, no removed error handling)
- No hardcoded values, no committed secrets
[+ if context_doc.required_for_finalize → "- `{context_doc.path}` updated (sections listed in 'On Completion')"]
[+ if Migration → "- Migration {TS} applies cleanly on a fresh DB AND passes zero-downtime audit (see references/zero-downtime-migrations.md): no DROP/RENAME without expand-contract; no NOT NULL on existing column without backfill; CONCURRENTLY index on tables >10K rows"]
[+ if Frontend AND i18n configured → "- All user-facing strings use `{i18n.fn}()`, keys present in: {i18n.locale_files joined by ', '}"]
[+ if feature_flags configured AND scope in feature_flags.required_for_scopes →
    "- Feature gated behind flag `{flag_name}` in `{feature_flags.system}`; default `{feature_flags.default_state}`. Flag registered in `{feature_flags.registry_path}`."]
[+ if config.security_scan.enabled → "- Dependency vulnerability scan passes at threshold `{security_scan.threshold}`"]
[+ if config.public_docs_dir AND scope changes public API → "- Corresponding docs in `{public_docs_dir}` updated"]
[+ for each acceptance_extension whose trigger_keywords match → "- {extension.criterion}"]

### Implementation Hints
{files, patterns, edge cases, gotchas. Pass references to similar modules from Phase 0 if relevant.}
**Est deltas (MANDATORY)** — one line per planned file: `{path} — ~{N} lines`. The Phase 2.0 plan-size gate reads `PLANNED_FILES` (line count of this list) and `PLANNED_LINES_EST` (sum of the `~N`) from THIS list — numbers grounded in the issue artifact, never invented at gate time ([phase-2 §2.0](phase-2-implementation.md)). For High, §2.0 replays on the approved plan's deltas after plan approval.
Prefer existing patterns and the smallest implementation that satisfies the criteria. Do not add new abstractions, config, flags, dependencies, or broad refactors unless they are listed in Requirements.
{If the concurrent-edit check (§Concurrent-edit check above) warned: "⚠ Recent activity on these files: {file: author@sha list}. Coordinate or rebase frequently."}

[+ if Migration → "### Migration
Prefix: {TS} — UTC timestamp generated at creation time via `date -u +%Y%m%d%H%M%S`. Never a sequential next-free number (parallel sessions collide on it).
Files: {repo}/{cache.migration_dir}/{TS}_{slug}.{cache.migration_pattern_ext}
Mixing with existing sequential migrations is fine (numeric sort: 000036 < 20260509073812); leave history as-is.
Use IF NOT EXISTS guards for idempotency.
**Zero-downtime audit will run** (references/zero-downtime-migrations.md). Plan expand-contract if any DROP/RENAME/NOT NULL is required."]

[+ if feature_flags configured AND scope in required_for_scopes → "### Feature Flag
Name: {flag_name}
System: {feature_flags.system}
Default: {feature_flags.default_state}
Wrap entry point. Document rollout plan in PR description."]

[+ if postmortem context (Phase 0 Step 1) → "### Postmortem
Cause: {one-liner}
Impact: {who/what affected, duration if known}
Detection: {how spotted}
Mitigation: {immediate fix this PR delivers}
Prevention: {longer-term action — separate issue if not in scope}"]

### Out of Scope
{explicit non-goals to prevent scope creep. Include unrelated cleanup/dead-code notes here or as follow-up issues; do not fold them into the current task.}

### Worktree Setup
Per target repo:
```
git -C {repo_path} fetch origin --prune
git -C {repo_path} worktree add {config.worktree.base or repo_parent}/{repo_name}-{config.naming.issue.worktree_suffix} -b {config.naming.issue.branch} origin/main
```
With `{N}` = ISSUE_NUM and `{slug}` derived from $ARGUMENTS.

### Build Checklist
{cache.build_cmds joined with " && "}
{cache.lint_cmds joined with " && "}
{cache.test_cmd, if Tests: YES}
{If affected-graph in use (phase-0 Step 4 predicate — false when --no-affected-graph was passed): note "Build/test scoped to affected projects via {affected_graph.tool}."}

### Branch
{config.naming.issue.branch} substituted

### On Completion
[+ if context_doc.required_for_finalize →
"1. **Update `{context_doc.path}`** (BEFORE posting the completion comment). Touch at minimum:
   - §{sections.current_state} Current State — record new migration prefix if applicable; move this issue Open Work → Recently Merged; update 'Last merged issue' + 'Last PR' + 'Last updated: YYYY-MM-DD'
   [+ if New module → '   - §{sections.structure} Repository Structures — add `{new-path}/`']
   [+ if Feature change → '   - §<feature-section> — note the new endpoint / invariant / field']
   [+ if Infra change → '   - §{sections.deployment} Deployment — env vars / compose changes']
   [+ if New constraint → '   - §{sections.constraints} Known Constraints — add gotcha']"]
[+ if tech_debt_doc → "2. Deferred items → append to `{tech_debt_doc}` 'Batched deferred' section."]
[+ if config.adr.dir AND complexity is High AND architectural decision involved → "3. ADR-{NNNN} committed at `{config.adr.dir}/{NNNN}-{slug}.md`. Status: Accepted."]
4. Comment on this issue with:
   ```
   ✅ Done. PR: <url> · Migration: {TS} (or —) · Build: <list of ✓ checks> [+ if context_doc → "· Context updated: {context_doc.path} §N[, §M]"] [+ if ADR → "· ADR-{NNNN}"] [+ if auto-merge → "· Auto-merge enabled"]
   ```
```

## Locale-specific callout & prologues

### Execute callout (line 1) — MANDATORY

**en** (default):
```
> 🚀 **Execute:** `+++ #{ISSUE_NUM}` — runs the `/do` skill (routes by complexity, plans, implements, gates, opens PR). Or paste this issue URL after `+++`.
```

**ru**:
```
> 🚀 **Выполнить:** `+++ #{ISSUE_NUM}` — запускает скилл `/do` (маршрутизация по сложности, план, реализация, гейты, PR). Или вставь URL этого issue после `+++`.
```

Rules (both locales):
- Literal line 1 of the body — no heading above it, no preamble, never wrapped in `<details>` (defeats list-preview visibility).
- `{ISSUE_NUM}` rides the existing two-step substitution; the `grep -c ISSUE_NUM` → `0` verify already covers it.
- github/gitlab: markdown as-is. Custom trackers (Linear, Jira, …): adapt syntax if blockquote/backticks don't render, keep the semantics — one visually-distinct first line containing the literal `+++` invocation. Reference the issue by the tracker's native id (`#{ISSUE_NUM}` → e.g. `ENG-123`) or point at the URL form (`+++ <issue URL>`). See [`trackers.md`](trackers.md).
- Applies to EVERY issue this skill creates — Phase 1 bodies AND Phase 4.4 tech-debt issues.

Origin: global rule 2026-05-19, revised same day from "a section anywhere in the body" → "first-line callout" — the section version sank under acceptance-criteria scrolling and never surfaced in tracker list previews, email notifications, or Slack unfurls.

### Prologue (line 3, after the blank line)

**en** (default):
```
Read the issue and start implementation immediately. Do NOT output a plan, do NOT output a task list, do NOT ask clarifying questions unless the issue is internally contradictory or impossible to satisfy. In that case, stop and report the exact contradiction instead of guessing.
```

**ru**:
```
Прочитай issue, сразу приступай к реализации. НЕ выводи план, НЕ выводи список задач, НЕ переспрашивай, если только issue не противоречит само себе или его невозможно выполнить. В этом случае остановись и назови точное противоречие, а не угадывай.
```

## Announce
```
[Phase 1] Issue {tracker.ref_format-substituted-N} created: {url from Tracker.view_url}
[+ if concurrent-edit check warned → "⚠ Concurrent edits on planned files in last {LOOKBACK_DAYS} days: {file: author@sha list}"]
[+ if notifications configured → also send "task_started" event per references/notifications.md]
```
