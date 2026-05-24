# Phase 2 — Implementation (Sonnet)

## Rules
- **Budget guard**: 3 Sonnet relaunches without progress → STOP, escalate to user. Progress = at least one previously-failing acceptance criterion now passes.
- **Worktree is created by Opus BEFORE spawning Sub-Agent** — see "Worktree setup" below. Sub-Agent does NOT create the worktree.
- **Never use `Agent(..., isolation: "worktree")`** — that mechanism auto-names branches (`claude/funny-leakey-...`) and bypasses `config.naming`. Always pre-create worktree explicitly via `git worktree add` per [`git-rules.md`](git-rules.md), then spawn `Agent(model: "sonnet")` WITHOUT isolation, passing the worktree path as the working directory in the prompt.
- **Behavioral guardrails**: no silent assumptions, no speculative abstractions, no drive-by cleanup. Every changed line must trace to the task, an acceptance criterion, or cleanup caused by this change.
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

### Spawn announce (visible to user)

Immediately before spawning the Sub-Agent, print a one-line announce so the user sees which model is being invoked for which role:

```
[Phase 2] Spawning Agent(model: "{IMPLEMENTER_MODEL}") in {WORKTREE_PATH} on branch {BRANCH}
```

Where `{IMPLEMENTER_MODEL}` is from Phase 0 announce (`haiku` for Trivial, `sonnet` for Low/Medium, `sonnet` for High default — `opus` only with explicit `--implementer=opus` override).

For High complexity with specialist plan-review (Step 2 below), also announce each specialist before invocation:
```
[Phase 2 Step 2] Spawning specialists in parallel for plan review:
  - {subagent_type_1}
  - {subagent_type_2}
  - {subagent_type_3}
```

## 2.0 Plan-size sanity check (BEFORE Sonnet launch)

Before constructing the Sonnet prompt, re-verify the Phase 0 routing against the now-concrete plan (the approved plan has actual file list + behaviour scope, more precise than Phase 0's pre-exploration estimate). **Invoke the wrapper verbatim** (do not paraphrase, do not "decide mentally", do not skip — see [anti-patterns §19d](anti-patterns.md)):

```bash
PLANNED_FILES=<count of files in the approved plan>
PLANNED_LINES_EST=<sum of per-file estimated line deltas in the approved plan>

PLAN_SIZE_LINE="$(~/.claude/skills/do/scripts/plan-size-check \
  --current-complexity "$COMPLEXITY" \
  --planned-files "$PLANNED_FILES" \
  --planned-lines "$PLANNED_LINES_EST")"
echo "$PLAN_SIZE_LINE"

case "$PLAN_SIZE_LINE" in
  "Phase 2.0: PASS"*)
    # Plan fits the current bucket. Proceed to Sonnet spawn unchanged.
    ;;
  "Phase 2.0: REBUMP"*)
    # Plan exceeds. Bump to H, re-run Phase 1 (issue update) + Phase 2
    # specialist plan-review with new tier.
    COMPLEXITY_REBUMPED_FROM="$COMPLEXITY"
    COMPLEXITY="H"
    # Replay Phase 1.5 / Phase 2 specialist plan-review at the new tier.
    ;;
  "Phase 2.0: SPLIT-REQUIRED"*)
    # Already H and still over. Single PR is the wrong shape for the task.
    # STOP — ask user to split before re-running.
    ;;
esac
```

**Why a wrapper, not inline bash** (v2 fix): the v1 inline-bash approach was systematically bypassed. Production audit of 32 post-v0.6.0 entries showed **0 re-bumps** despite **16 of 21 M-tasks shipping >600 lines or >8 files**. Same fabrication-skip pattern as caveman v1/v2 — orchestrator reads the threshold values + case-statement in the spec, decides "looks fine to me", produces no output, no signal in metrics that the check was skipped. The wrapper hides the thresholds and prints a structured decision line that the spec's case-statement must parse. If `$PLAN_SIZE_LINE` is empty (wrapper didn't run) the case-statement matches nothing — visible bug.

**Anti-fabrication tell**: the wrapper output includes the actual computed cap values for the bucket (e.g. `caps: 8 files / 600 lines` for M). The spec contains no copy-pasteable form of either the cap values or the full output template — orchestrator skipping the wrapper can't reproduce the exact values without running it.

**Observability**: on the REBUMP branch, set `$COMPLEXITY_REBUMPED_FROM` (shown above) so the Phase 4.13 metrics-append invocation can pass `--complexity-rebumped-from "$COMPLEXITY_REBUMPED_FROM"`. Recorded in JSONL as `complexity_rebumped_from` (omitted when no re-bump). Downstream metric: count of T/L/M re-bumps over time tells whether Phase 0 routing accuracy is improving or whether plan-size is the load-bearing layer.

**Why this exists** (production audit 2026-05-21): 6 of 13 false-positive cases were tasks routed Medium that shipped 942–1859 lines. Phase 0 file-count estimate was 4–8 (correct M bucket bound) but actual files came out 9–31 and lines 942–1859 — both H-bucket territory. Without this check the orchestrator runs Sonnet for an hour, Phase 3 catches `pr_size=warn` after the fact, and ~$/task is wasted on review-cycles instead of being prevented at plan time. The check is cheap (numeric comparison) and runs once per spawn.

**Don't skip when "close enough"** — `9 files / 700 lines` on M is the exact boundary where audits showed FP rates climb. Bump even on the boundary; H workflow (specialist plan review + ADR) is the right tooling for that scale.

## 2.0.5 Stale-main check (before each Sonnet launch)

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

**Critical Phase 4 reminders — pinned at top so they don't get forgotten by end-of-task:**

These apply to **whoever is currently executing this skill flow** — whether you are the spawned agent doing everything yourself, or a parent orchestrator that spawned a sub-agent. There is no separate "Opus picks up after Sub-Agent reports" step in most real installs (the spawned agent typically runs the entire flow start-to-finish and returns). So if you are reading this prompt, **you** are responsible for Phase 4.0 + Phase 4.13 procedures.

1. **Phase 4.0 (branch rename) MUST run BEFORE Phase 4.2 (PR open)**, not after. Verify your worktree's branch matches `config.naming.{low|issue}.branch`. If you're in a worktree with auto-named `claude/<adj>-<noun>-<hash>` (Claude Code harness pre-spawn) — RENAME UNCONDITIONALLY via `git branch -m`. The worktree PATH is fine to keep; the BRANCH must follow spec so PR title / commit `Ref:` / metrics `branch_rename` field / tracker comments all cross-reference via `i{N}`. **Pre-spawned worktree is NOT an excuse** — `git branch -m` works on pre-spawned worktrees just fine. Anti-pattern 31c.

2. **Phase 4.13 (final announce) is a single bash procedure, structurally coupled with Phase 4.11 metrics emission** via shared `$METRICS_LINE` shell variable. Run the bash verbatim from [`phase-4-finalize.md`](phase-4-finalize.md) §4.13. You CANNOT produce the announce text without running the emit (variable doesn't exist otherwise). If your final user-visible message ends with PR-summary prose and no `Metrics: ...` line at the very end — you composed prose announce instead of running the bash flow. That's the bug. Anti-pattern 31a.

3. **Phase 4.0.5 (pre-emit sanity check)**: AFTER the bash flow runs, verify `wc -l` of `$LOG_PATH` grew by exactly 1 vs the pre-count you captured before the append. If it didn't grow, the append failed silently — re-run or fail loud with `Metrics: APPEND FAILED — <reason>` in the announce. Don't gloss over.

These three are NOT optional and NOT ceremony. They're the fail-fast contract that makes the skill self-verifying — if you skip them, downstream metrics-driven skill iteration breaks silently.

Now, the rules for the implementation work:

- If multiple interpretations remain and they would change observable behavior, STOP and report the ambiguity. Otherwise state the assumption briefly and proceed.
- Use the smallest implementation that satisfies the acceptance criteria. Do not add new abstraction layers, config knobs, feature flags, generic helpers, or future-proofing unless Requirements explicitly ask for them.
- Match existing style even if you would design it differently. Mention unrelated dead code or cleanup as deferred work; do not edit it here.
- Each plan step must include its verification check. If the implementation starts growing beyond the plan, pause and simplify before continuing.
[+ if i18n configured AND scope is Frontend or Fullstack →
"- ALL user-facing strings must use `{i18n.fn}()`. Add keys to ALL of: {i18n.locale_files joined by ', '}."]
[+ if feature_flags configured AND scope in feature_flags.required_for_scopes →
"- Wrap entry point with feature flag `{flag_name}` ({feature_flags.system}). Default `{feature_flags.default_state}`. Register in `{feature_flags.registry_path}`."]
[+ if config.security_scan.enabled →
"- Do not introduce dependencies with known CVEs at threshold {threshold}. Phase 3 will scan; resolve before review."]
[+ if Phase 0.0.3 detected caveman as ACTIVE →
"- Respond in caveman style — compressed prose, technical accuracy preserved (e.g. 'Bug in auth middleware. Token expiry check use `<` not `<=`. Fix:' instead of 5-sentence narrative). Code, file paths, error messages, and structured output (tables, JSON, diffs) are NEVER compressed — only natural-language framing. The caveman skill is active in this session and will compress output by ~75% — match its register so structure stays consistent. Self-review section, completion reports, and metrics output (Phase 4.11 calibration parsing) follow strict format below — those are LITERAL strings, not prose, do not compress them."]
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
4. Confirm simplicity + surgical scope: no speculative abstraction/config/deps/flags, no unrelated formatting/comment churn, every changed line traceable to the task.
5. Flag anything you skipped or deferred. Don't hide it.
6. **Run `git diff main...HEAD --stat`** and check actual diff size against the bucket the task was routed for. If `complexity=M` and diff > 600 lines OR > 8 files (M-bucket caps per Phase 0 matrix), DO NOT claim `ready` — return `claimed_status: deferred` with a note like "diff size {N} lines / {F} files exceeds M-bucket caps; recommend re-route to H for specialist review". Same for L exceeding 200 lines / 3 files. Calibration rationale: production audit of 32 post-v0.6.0 entries showed M-tasks shipping 1000–2000 lines self-claiming `ready`, with Phase 3 catching `pr_size=warn` after the fact — wasted cycles. Phase 2.0 plan-size check (above) should have caught this at plan-time; this is a second-layer check using the ACTUAL diff post-write. If both layers miss, that's a calibration-data-point for skill iteration.
7. **Declare an overall claimed_status** — one of:
   - `ready` — all acceptance criteria implemented + verified, no known issues, AND diff fits the routed bucket
   - `deferred` — implemented + tested, but explicitly deferred something (with note) OR diff exceeds routed bucket caps (re-route hint above)
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
Simplicity/surgical check: no speculative abstractions or drive-by edits; changed lines trace to task
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
   - Low/Medium: concise inline plan, no review; each step names its verification check
   - High: separate plan output → specialist review (see "High — Plan Review" below); each step names its verification check
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
