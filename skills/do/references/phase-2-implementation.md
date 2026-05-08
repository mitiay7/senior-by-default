# Phase 2 — Implementation (Sonnet)

## Rules
- **Budget guard**: 3 Sonnet relaunches without progress → STOP, escalate to user. Progress = at least one previously-failing acceptance criterion now passes.
- **Worktree is created by Opus BEFORE spawning Sub-Agent** — see "Worktree setup" below. Sub-Agent does NOT create the worktree.
- **Never use `Agent(..., isolation: "worktree")`** — that mechanism auto-names branches (`claude/funny-leakey-...`) and bypasses `config.naming`. Always pre-create worktree explicitly via `git worktree add` per [`git-rules.md`](git-rules.md), then spawn `Agent(model: "sonnet")` WITHOUT isolation, passing the worktree path as the working directory in the prompt.
- M/H: checkpoint commits as `wip(module): ...` between major chunks.
- **Error recovery**: capture error → diagnose root cause → targeted fix. Don't retry blindly. Don't abandon after a single failure.
- **No new dependencies** (`go get`, `pnpm add`, `cargo add`, `pip install`, etc.) unless explicitly listed in issue Requirements. If needed and not listed → STOP, report to Opus.

## Worktree setup (Opus does this BEFORE spawning Sub-Agent)

Compute branch + worktree path from `config.naming` and `config.worktree`:

```bash
# Inputs
N="42"                              # issue number / id (M/H) — empty for Low
SLUG="add-user-avatars"             # kebab-case from $ARGUMENTS
COMPLEXITY="M"                      # T | L | M | H

# Resolve from config.naming
if [ "$COMPLEXITY" = "L" ] || [ "$COMPLEXITY" = "T" ]; then
  WORKTREE_SUFFIX="do-${SLUG}"      # config.naming.low.worktree_suffix
  BRANCH="feat/${SLUG}"             # config.naming.low.branch
else
  WORKTREE_SUFFIX="i${N}"           # config.naming.issue.worktree_suffix
  BRANCH="feat/i${N}-${SLUG}"       # config.naming.issue.branch
fi

# Resolve from config.worktree
if [ -n "$CONFIG_WORKTREE_BASE" ]; then
  WORKTREE_PATH="${CONFIG_WORKTREE_BASE}/${REPO_NAME}-${WORKTREE_SUFFIX}"   # sibling style (multi-repo workspaces)
else
  WORKTREE_PATH="${REPO_PATH}/.claude/worktrees/${WORKTREE_SUFFIX}"          # Claude Code style (default)
fi

# Create
git -C "$REPO_PATH" fetch origin --prune
git -C "$REPO_PATH" worktree add "$WORKTREE_PATH" -b "$BRANCH" origin/main
```

If branch already exists (collision): increment `-v2`, `-v3`, ..., cap `-v9` per [`git-rules.md`](git-rules.md).

Pass `WORKTREE_PATH` and `BRANCH` to Sub-Agent in the prompt's first lines:
```
You will work in worktree: {WORKTREE_PATH}
Your branch is already created: {BRANCH}
Do NOT create another worktree. Do NOT use Agent's isolation parameter (you ARE the agent).
First action: cd to that path and verify `git rev-parse --abbrev-ref HEAD` matches {BRANCH}.
```

## 2.0 Stale-main check (before each Sonnet launch)

Before launching Sonnet (or relaunching after a fix cycle), check how far behind `main` the worktree is:
```
git -C {worktree_path} fetch origin --quiet
git -C {worktree_path} rev-list --count HEAD..origin/main
```

Apply `config.stale_main` thresholds (defaults: warn 20, block 50):
- ≤warn → proceed
- warn < commits ≤ block → WARN: "Branch is {N} commits behind main. Consider rebasing soon."
- > block → BLOCK. If `config.stale_main.auto_rebase: true` attempt:
  ```
  git -C {worktree_path} rebase origin/main
  ```
  Conflict → escalate to user with files listed. Otherwise: ask user before rebasing (don't auto-rewrite their work).

## Sonnet prompt template

Construct in this order. Include all applicable items, omit sections that don't apply.

```
## Context (read FIRST, before exploring)
[+ if context_doc configured →
"READ `{context_doc.path}` in full. It has the repo map, module layout, conventions, current state, open work[, i18n rules][, deploy pipeline], and the Context Update Protocol.
Do NOT re-explore repos that are already documented there — trust the file."]
[+ if config.adr.dir AND existing ADRs touch this scope → "RELEVANT ADRs (do not violate without superseding): {ADR-NNNN: title; quote 'Decision' section}"]
[+ else: omit this section.]

## Task
{For M/H: full issue body verbatim.
 For L: inline task description (see format below).}

## Acceptance Criteria
{For M/H: copy from issue verbatim.
 For L: 3-5 pass/fail criteria written here.}

## CLAUDE.md
{Full text of target repo's CLAUDE.md if it exists. Skip section if not.}

## Affected Files
{≤10 files: full contents of each.
 More than 10: full contents for the most-changed; path + one-line summary for the rest.}

## Reference Modules
{1-2 similar module paths from Phase 0.1, with key file names. Helps Sonnet match conventions without re-exploring.}

## Approved Plan
{High only: the plan approved by specialists in Step 2 below. Omit for Low/Medium.}

## ADR Draft
{High only, if architectural decision involved: include the draft ADR text per references/adr.md template. Sonnet refines and finalizes during implementation.}

## Tech-Debt Context
[+ if memory_path configured →
"Grep `{memory_path}` for module names appearing in affected code. Include matching deferred tech-debt items here verbatim."]
[+ else: omit.]

## Flags
Tests: {YES/NO} | Migration: {YES NNN/NO}
Build: {cache.build_cmds joined with ' && '}  [+ if affected_graph → "(scoped via {tool})"]
Lint:  {cache.lint_cmds joined with ' && '}
Test:  {cache.test_cmd}

## Rules
[+ if i18n configured AND scope is Frontend or Fullstack →
"- ALL user-facing strings must use `{i18n.fn}()`. Add keys to ALL of: {i18n.locale_files joined by ', '}."]
[+ if feature_flags configured AND scope in feature_flags.required_for_scopes →
"- Wrap entry point with feature flag `{flag_name}` ({feature_flags.system}). Default `{feature_flags.default_state}`. Register in `{feature_flags.registry_path}`."]
[+ if config.security_scan.enabled →
"- Do not introduce dependencies with known CVEs at threshold {threshold}. Phase 3 will scan; resolve before review."]
- No backwards compat — clean breaks only.
- No new dependencies without explicit listing in Requirements.
- Commit specific files only. Convention: `feat|fix|refactor|test|chore|wip(module): desc`
[+ if context_doc.required_for_finalize →
"- Before finalizing: update `{context_doc.path}` per the Context Update Protocol. Name the sections you touched (§{N}/§{M}/...) in your completion report."]

## Self-Review (REQUIRED, do this before reporting done)
After implementation + tests + build pass, run a self-review pass:
1. For EACH acceptance criterion, cite the file:line that proves it implemented (or "test name" for test criteria).
2. For EACH new public function with branching logic, name the happy-path test AND error-path test that cover it.
3. Re-read your own diff (`git diff main...HEAD`) and check against the rules above + the issue's "Out of Scope" section.
4. Flag anything you skipped or deferred. Don't hide it.
5. **Declare an overall claimed_status** — one of:
   - `ready` — all acceptance criteria implemented + verified, no known issues
   - `deferred` — implemented + tested, but explicitly deferred something (with note)
   - `uncertain` — uncertain about a specific aspect (Phase 3 should pay extra attention here)

Output the self-review as a section in your completion report (this section is parsed by Phase 4.11 for metrics calibration — match the format):
```
## Self-Review
claimed_status: ready
Acceptance Criterion 1: ✓ {file.go:42}
Acceptance Criterion 2: ✓ {file.go:80}, test {file_test.go: TestX}
Tests for new fns:
  - HandleFoo: TestHandleFoo_OK / TestHandleFoo_ErrInvalidInput
  - HandleBar: TestHandleBar_OK / TestHandleBar_ErrNotFound
Out-of-scope check: no scope creep detected
Deferred: {nothing | "extracted shared helper, not required by acceptance — added as tech debt note"}
Uncertain: {none | "concurrency in connection pool — flagged for reviewer"}
```

The first line `claimed_status: <ready|deferred|uncertain>` is REQUIRED — Phase 4.11 reads it to compute self-review calibration (`accurate` / `false_positive` / `false_negative`) by comparing against actual Phase 3 outcomes. This is the highest-signal data point for skill iteration; do not omit.

[+ if --no-self-review in $ARGUMENTS: omit this entire section, metrics will record `self_review.performed: false`]
```

## Low-task description format (when no issue exists)
```
**Goal**: {one sentence from $ARGUMENTS}
**Files**: {expected files to modify or create}
**Acceptance**: {3-5 pass/fail criteria}
```

## Tasks the agent runs (in order)
0. **Worktree already exists** (Opus pre-created it per "Worktree setup" above). Sub-Agent verifies `git rev-parse --abbrev-ref HEAD` matches the expected branch name. If mismatch → STOP, alert Opus (don't try to fix from inside).
1. Read context (per "Context" section of the prompt — context_doc, CLAUDE.md, affected files)
2. Plan
   - Medium: inline plan, no review
   - High: separate plan output → specialist review (see "High — Plan Review" below)
3. Implement
4. Write + run tests (if Tests: YES)
5. Run build checklist (ALL commands from `Flags` section)
5.5 **Self-review** per the prompt's Self-Review section (skipped if `--no-self-review`)
6. Report:
   - Files changed (paths)
   - Tests run (each scenario + result)
   - Build output (each command's exit code + key lines)
   - Self-review section

## High — Plan Review (Step 2)

Sonnet outputs the plan only (no code yet). For architectural decisions, also drafts an ADR per [`adr.md`](adr.md).

Then 2-3 specialists review in parallel:

Pick from `config.specialists.{backend_plan|frontend_plan}` based on scope:
- Always include the architect / lead role
- Add security agent if auth / input handling
- Add database agent if migrations
- Fullstack: 1-2 backend + 1 frontend

**If `config.specialists` not set**: fallback — Opus reviews the plan inline (no parallel agents). Note this in announcement.

All specialists APPROVE → Step 3.
Max 3 iterations.

**After 3 iterations without full approval**: Opus makes a binding decision, documents the rationale in an issue comment, proceeds to Step 3. The ADR records "decided over objections from {agent} re: {concern}" in the Alternatives section.

## High — Step 3
Sonnet implements with the approved plan AND the approved ADR.

**Opus posts the approved plan as an issue comment** so it persists across sessions. Use `{Tracker.comment}` from [`trackers.md`](trackers.md) with body file containing:
```
### Approved Plan
{plan text}

### ADR (if applicable)
ADR-{NNNN}: {title} — committed at {dir}/{NNNN}-{slug}.md
```

## Announce
```
[Phase 2] Plan: APPROVED after {N} iterations. Implementation complete. Tests: {pass/skipped}. Build: {pass/fail}. Self-review: {included/skipped}. [+ if ADR → "ADR-{NNNN} created."]
```
