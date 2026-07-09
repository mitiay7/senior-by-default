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

## 2.0 Plan-size sanity check (wrapper-owned; pre-spawn every tier, again post-plan-approval for H)

Re-verify the Phase 0 routing against grounded numbers before spending implementer time. **Invoke the wrapper verbatim** (do not paraphrase, do not "decide mentally", do not skip — see [anti-patterns §19d](anti-patterns.md)).

**Input provenance — per tier.** `PLANNED_FILES` / `PLANNED_LINES_EST` MUST be read out of a written artifact. Inventing them at gate time makes the gate tautological — Phase 0 chose the bucket from the same guess, so the wrapper faithfully PASSes fabricated small estimates (production audit: 0 rebumps across 32 entries while 16 of 21 M-tasks shipped over the M caps):

| Tier | Artifact §2.0 reads the numbers from | When §2.0 runs |
|---|---|---|
| T/L | the inline task description (format below): `PLANNED_FILES` = count of `**Files**` bullets, `PLANNED_LINES_EST` = the `**EstLines**` sum. Write the description FIRST, then gate it. | once, pre-spawn |
| M | the Phase 1 issue's `### Implementation Hints` → mandatory `Est deltas` list ([phase-1-issue.md](phase-1-issue.md)): count of listed files + sum of their `~N lines` deltas. Copy from the issue, not from memory. | once, pre-spawn |
| H | pre-spawn: the same Phase 1 `Est deltas` list as M. Post-approval: the approved plan's per-file line deltas. | **twice** — the approved plan does not exist until Step 2 completes (the old "run pre-spawn on the approved plan" instruction was time-inverted), so re-run after plan approval and BEFORE Step 3 implementation. The second run is where SPLIT-REQUIRED has real data. |

```bash
PLANNED_FILES=<file count read from the tier's artifact (table above)>
PLANNED_LINES_EST=<sum of the per-file line deltas from the same artifact>

# Canonical do-scripts resolver — identical line in every wrapper block; each
# block runs in a fresh shell, so re-resolve here (rationale: phase-0-setup.md Step 1).
DO_SCRIPTS="$(find -L ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT/skills"} "$HOME/.claude/skills" "$HOME/.claude/plugins/cache" "$HOME/.local/share/senior-by-default/skills" -maxdepth 7 -type f -name metrics-append -path '*/scripts/*' 2>/dev/null | head -1)"; DO_SCRIPTS="${DO_SCRIPTS%/metrics-append}"

if [ -x "$DO_SCRIPTS/plan-size-check" ]; then
  PLAN_SIZE_LINE="$("$DO_SCRIPTS/plan-size-check" \
    --current-complexity "$COMPLEXITY" \
    --planned-files "$PLANNED_FILES" \
    --planned-lines "$PLANNED_LINES_EST")"
else
  # FAIL CLOSED — explicit token so the case below has a matching arm.
  PLAN_SIZE_LINE="Phase 2.0: GATE ERROR — plan-size-check wrapper not found (do-scripts resolver found no install)"
fi
echo "$PLAN_SIZE_LINE"

case "$PLAN_SIZE_LINE" in
  "Phase 2.0: PASS"*)
    # Plan fits the current bucket. Proceed to Sonnet spawn unchanged.
    ;;
  "Phase 2.0: REBUMP"*)
    COMPLEXITY_REBUMPED_FROM="$COMPLEXITY"
    COMPLEXITY="H"
    # Re-enter at the new tier — the path differs by whether an issue exists:
    # - M: issue EXISTS — update it (Phase 1 edit_body: labels + a re-bump
    #   note), then run the H flow (Step 2 specialist plan review) before
    #   any implementation.
    # - T/L: NO issue exists (T/L skip Phase 1 per SKILL.md) — run Phase 1
    #   NOW to CREATE the issue at the new tier, then continue with the H
    #   flow. "Re-run Phase 1 (issue update)" was a dead-end here; issue
    #   CREATION is the defined path.
    ;;
  "Phase 2.0: SPLIT-REQUIRED"*)
    # Already H and the plan STILL exceeds the H ceiling. The ceiling is
    # owned by plan-size-check — its values live ONLY in the wrapper; spec
    # prose deliberately carries no copy (see anti-fabrication tell below).
    # Single PR is the wrong shape — STOP before spending Sonnet time. The wrapper
    # line includes a suggested sub-issue count ("Split into ~N sub-issues").
    # 1. Do NOT spawn Sonnet (on H's post-approval run: do NOT proceed to Step 3).
    # 2. Present the wrapper line + suggested split to the user. 3. Offer to file
    # the N sub-issues (each a scoped slice of the plan). 4. Re-run /do per
    # sub-issue. This branch fires on real data on H's post-approval run (v0.7.0
    # gave H a real ceiling — previously effectively unbounded, so SPLIT-REQUIRED
    # was dead code and 3000–4000-line H PRs sailed through to an unreviewable
    # Phase 3).
    ;;
  "Phase 2.0: GATE ERROR"*)
    # FAIL CLOSED — the wrapper is unreachable, which means the install is
    # broken (every wrapper ships in the same scripts/ dir). Do NOT spawn
    # the implementer, do NOT eyeball the thresholds yourself (§19d — that is
    # the exact fabrication path the wrapper closed). Surface the line to the
    # user, STOP; fix = re-run install.sh or /plugin install, then retry.
    ;;
esac
```

**Why a wrapper, not inline bash** (v2 fix): the v1 inline-bash approach was systematically bypassed. Production audit of 32 post-v0.6.0 entries showed **0 re-bumps** despite **16 of 21 M-tasks shipping over the M-bucket caps**. Same fabrication-skip pattern as caveman v1/v2 — orchestrator reads the threshold values + case-statement in the spec, decides "looks fine to me", produces no output, no signal in metrics that the check was skipped. The wrapper owns the thresholds and prints a structured decision line that the spec's case-statement must parse. If `$PLAN_SIZE_LINE` is empty (wrapper didn't run) the case-statement matches nothing — visible bug.

**Anti-fabrication tell** (v0.9 — the old tell was void: it echoed cap values that were composable from the Phase 0 routing matrix): every wrapper verdict line ends with a derived `[tell:<head8>:<ck>]` suffix — `<head8>` is the repo's current HEAD short-SHA (session-varying), `<ck>` a checksum the wrapper computes over the inputs, its internal caps, and `<head8>`. A line composed from spec text carries no valid tell: the spec contains neither the H ceiling nor the checksum formula, and HEAD changes per session, so offline composition is detectably wrong. Quote verdict lines verbatim wherever they surface (announce, self-review, issue comments) — never strip or "clean up" the suffix; audits recompute it from the printed line.

**Optional harness backstop** (tier 3, opt-in): if the user enabled the hooks in [`hooks.md`](hooks.md), the `PreToolUse` plan-size hook re-runs `plan-size-check` at the moment the implementer `Task` is spawned and injects the verdict — provided the spawn prompt carries the `PLAN-SIZE: files={PLANNED_FILES} lines={PLANNED_LINES_EST} complexity={COMPLEXITY}` marker (emit it in the prompt's Flags section, below). The marker carries the numbers from the **most recent** §2.0 run — for H's Step 3 (implementation) relaunch that is the post-approval plan numbers, not the Phase 1 estimates. Harmless without the hook; surfaces the size verdict at the runtime level when present.

**Observability**: on the REBUMP branch, set `$COMPLEXITY_REBUMPED_FROM` (shown above) so the Phase 4.13 metrics-append invocation can pass `--complexity-rebumped-from "$COMPLEXITY_REBUMPED_FROM"`. Recorded in JSONL as `complexity_rebumped_from` (omitted when no re-bump). Downstream metric: count of T/L/M re-bumps over time tells whether Phase 0 routing accuracy is improving or whether plan-size is the load-bearing layer.

**Why this exists** (production audit 2026-05-21): 6 of 13 false-positive cases were tasks routed Medium that shipped 942–1859 lines. Phase 0 file-count estimate was 4–8 (correct M bucket bound) but actual files came out 9–31 and lines 942–1859 — both H-bucket territory. Without this check the orchestrator runs Sonnet for an hour, Phase 3 catches `pr_size=warn` after the fact, and ~$/task is wasted on review-cycles instead of being prevented at plan time. The check is cheap (numeric comparison) and runs once per spawn (twice total for H — see the input-provenance table).

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
{1-2 similar module paths from Phase 0, with key file names. Helps Sonnet match conventions without re-exploring.}

## Approved Plan
{High only: the plan approved by specialists in Step 2 below. Omit for Low/Medium.}

## ADR Draft
{High only, if architectural decision involved: include the draft ADR text per references/adr.md template. Sonnet refines and finalizes during implementation.}

## Tech-Debt Context
[+ if memory_path configured →
"Grep `{memory_path}` for module names appearing in affected code. Include matching deferred tech-debt items here verbatim."]
[+ else: omit.]

## Flags
Tests: {YES/NO} | Migration: {YES {TS}/NO}   <!-- {TS} = UTC timestamp prefix from Phase 0 Step 5 (`date -u +%Y%m%d%H%M%S`), never a sequential number -->
Build: {cache.build_cmds joined with ' && '}  [+ if affected_graph → "(scoped via {tool})"]
Lint:  {cache.lint_cmds joined with ' && '}
Test:  {cache.test_cmd}
PLAN-SIZE: files={PLANNED_FILES} lines={PLANNED_LINES_EST} complexity={COMPLEXITY}
<!-- ^ machine-readable marker from §2.0. Harmless to the implementer; read by the
     optional PreToolUse plan-size hook (references/hooks.md) to surface the verdict
     at spawn time. Omit nothing — emit it verbatim with the §2.0 numbers. -->

## Rules

**Critical Phase 4 reminders — pinned at top so they don't get forgotten by end-of-task:**

These apply to **whoever is currently executing this skill flow** — whether you are the spawned agent doing everything yourself, or a parent orchestrator that spawned a sub-agent. There is no separate "Opus picks up after Sub-Agent reports" step in most real installs (the spawned agent typically runs the entire flow start-to-finish and returns). So if you are reading this prompt, **you** are responsible for Phase 4.0 + Phase 4.13 procedures.

1. **Phase 4.0 (branch rename) MUST run BEFORE Phase 4.2 (PR open)**, not after. The rename decision is owned by the `branch-normalize` wrapper (phase-4-finalize.md §4.0) — never inline `git branch -m` from memory of the naming rules. If you're in a worktree with auto-named `claude/<adj>-<noun>-<hash>` (Claude Code harness pre-spawn) — the wrapper RENAMES UNCONDITIONALLY. The worktree PATH is fine to keep; the BRANCH must follow spec so PR title / commit `Ref:` / metrics `branch_rename` note / tracker comments all cross-reference via `i{N}`. **Pre-spawned worktree is NOT an excuse** — the wrapper's `git branch -m` works on pre-spawned worktrees just fine. [Anti-patterns §12, §19j](anti-patterns.md).

2. **Phase 4.13 (final announce) is a single bash procedure, structurally coupled with Phase 4.11 metrics emission** via shared `$METRICS_LINE` shell variable. Run the bash verbatim from [`phase-4-finalize.md`](phase-4-finalize.md) §4.13. You CANNOT produce the announce text without running the emit (variable doesn't exist otherwise). If your final user-visible message ends with PR-summary prose and no `Metrics: ...` line at the very end — you composed prose announce instead of running the bash flow. That's the bug. [Anti-pattern §19a](anti-patterns.md).

3. **Append verification is wrapper-owned — check the OK line, don't recount**: `metrics-append` counts `$LOG_PATH` lines before and after the write internally and emits `OK pre=N post=N+1 …` only when the delta is exactly 1 (silent write failure → `IOFAIL append silent-fail: pre=… post=… delta=… expected=1`). AFTER the §4.13 bash flow runs, verify the captured wrapper output starts with `OK ` and `post = pre + 1`; any other result surfaces verbatim as `Metrics: APPEND FAILED — <reason>` in the announce. Don't re-implement the count with hand-run `wc -l`, and don't gloss over a non-OK result.

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
[+ if Phase 0 Step 2 detected caveman as ACTIVE →
"- Respond in caveman style — compressed prose, technical accuracy preserved (e.g. 'Bug in auth middleware. Token expiry check use `<` not `<=`. Fix:' instead of 5-sentence narrative). Code, file paths, error messages, and structured output (tables, JSON, diffs) are NEVER compressed — only natural-language framing. The caveman skill is active in this session and will compress output by 65% (measured) — match its register so structure stays consistent. Self-review section, completion reports, and metrics output (Phase 4.11 calibration parsing) follow strict format below — those are LITERAL strings, not prose, do not compress them."]
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
6. **Size check on the ACTUAL diff — wrapper-owned, run verbatim.** The bucket caps are deliberately NOT printed in this prompt (copyable caps get eyeballed, and eyeballed checks get skipped) — the same `plan-size-check` wrapper that gated the plan judges the real diff:

   ```bash
   # Canonical do-scripts resolver — identical line as everywhere else in this skill.
   DO_SCRIPTS="$(find -L ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT/skills"} "$HOME/.claude/skills" "$HOME/.claude/plugins/cache" "$HOME/.local/share/senior-by-default/skills" -maxdepth 7 -type f -name metrics-append -path '*/scripts/*' 2>/dev/null | head -1)"; DO_SCRIPTS="${DO_SCRIPTS%/metrics-append}"
   STAT="$(git diff --shortstat main...HEAD)"
   ACTUAL_FILES="$(printf '%s' "$STAT" | grep -oE '[0-9]+ file' | grep -oE '[0-9]+')"; ACTUAL_FILES="${ACTUAL_FILES:-0}"
   ACTUAL_LINES="$(printf '%s' "$STAT" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+')"; ACTUAL_LINES="${ACTUAL_LINES:-0}"
   if [ -x "$DO_SCRIPTS/plan-size-check" ]; then
     ACTUAL_SIZE_LINE="$("$DO_SCRIPTS/plan-size-check" --current-complexity {COMPLEXITY} --planned-files "$ACTUAL_FILES" --planned-lines "$ACTUAL_LINES")"
   else
     ACTUAL_SIZE_LINE="Phase 2.5: SIZE CHECK UNAVAILABLE — plan-size-check not found; report as-is, do NOT eyeball caps"
   fi
   echo "$ACTUAL_SIZE_LINE"
   ```

   (`{COMPLEXITY}` is the literal tier letter, interpolated by the orchestrator — same value as the `PLAN-SIZE:` marker in Flags.) Dispatch on the line: `PASS` → `size_assessment: fits`. `REBUMP`/`SPLIT-REQUIRED` → `size_assessment: exceeds` AND claimed_status MUST be `deferred`, not `ready` — quote `$ACTUAL_SIZE_LINE` verbatim (its `[tell:…]` suffix included) under `Deferred (size)` with a re-route hint. `SIZE CHECK UNAVAILABLE` → `size_assessment: unknown`, quote the line. Calibration rationale: production audit of 32 post-v0.6.0 entries showed M-tasks shipping far over bucket while self-claiming `ready`, with Phase 3 catching `pr_size=warn` after the fact — wasted cycles. Phase 2.0 plan-size check is layer 1 (plan-time estimates); this is layer 2 on the ACTUAL post-write diff, judged by the same wrapper so the two layers cannot drift. If both layers miss, that's a calibration-data-point for skill iteration.
7. **Declare an overall claimed_status** — one of:
   - `ready` — all acceptance criteria implemented + verified, no known issues, AND diff fits the routed bucket
   - `deferred` — implemented + tested, but explicitly deferred something (with note) OR diff exceeds routed bucket caps (re-route hint above)
   - `uncertain` — uncertain about a specific aspect (Phase 3 should pay extra attention here)
8. **Distinguish a CODE concern from a SIZE concern when you defer.** Phase 4.11 splits self-review calibration into two de-confounded dimensions: `calibration_defect` (did you miss a real code defect?) and `calibration_size` (did you predict diff size?). So when you defer/flag, say WHICH it is — a deferral for "diff size exceeds bucket" is a size signal, not a defect. Emit the explicit `size_assessment:` line so this is machine-readable rather than guessed from prose.

Output the self-review as a section in your completion report (this section is parsed by Phase 4.11 for metrics calibration — match the format):
```
## Self-Review
claimed_status: ready
size_assessment: fits          # fits | exceeds | unknown — from the step-6 wrapper verdict on the ACTUAL diff, never eyeballed (drives calibration_size)
Acceptance Criterion 1: ✓ {file.go:42}
Acceptance Criterion 2: ✓ {file.go:80}, test {file_test.go: TestX}
Tests for new fns:
  - HandleFoo: TestHandleFoo_OK / TestHandleFoo_ErrInvalidInput
  - HandleBar: TestHandleBar_OK / TestHandleBar_ErrNotFound
Simplicity/surgical check: no speculative abstractions or drive-by edits; changed lines trace to task
Out-of-scope check: no scope creep detected
Deferred (code): {nothing | "concurrency in connection pool — flagged for reviewer"}
Deferred (size): {nothing | the step-6 REBUMP/SPLIT-REQUIRED wrapper line quoted verbatim + " — recommend re-route to H"}
Uncertain: {none | "..."}
```

The first line `claimed_status: <ready|deferred|uncertain>` is REQUIRED — Phase 4.11 reads it to compute self-review calibration by comparing against actual Phase 3 outcomes. The `size_assessment: fits|exceeds` line and the split `Deferred (code)` / `Deferred (size)` framing feed the two calibration dimensions (`calibration_defect`, `calibration_size`). This is the highest-signal data point for skill iteration; do not omit.

[+ if --no-self-review in $ARGUMENTS: omit this entire section, metrics will record `self_review.performed: false`]
```

## Low-task description format (when no issue exists)
```
**Goal**: {one sentence from $ARGUMENTS}
**Files**: {expected files to modify or create — one bullet per file, each ending with an estimated line delta: `{path} — ~{N} lines`}
**EstLines**: {sum of the per-file deltas above}
**Acceptance**: {3-5 pass/fail criteria}
```

`**EstLines**` and the per-file deltas are MANDATORY — write this block BEFORE running §2.0. The gate reads `PLANNED_FILES` (bullet count) and `PLANNED_LINES_EST` (the EstLines sum) from THIS block, so the numbers exist in a reviewable artifact instead of being invented at gate time (see §2.0 input provenance).

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

   Report REAL output. Phase 3.1 independently re-runs the same build/lint/test checklist in the worktree (`build-verify` wrapper) — your exit codes are cross-checked, never trusted alone. A claimed PASS that FAILs the re-run is recorded as `self_report_mismatch` (fabrication-class, [anti-patterns §19h](anti-patterns.md)) and counts against your self-review calibration.

## High — Plan Review (Step 2)

Sonnet outputs the plan only (no code yet). For architectural decisions, also drafts an ADR per [`adr.md`](adr.md).

Then 2-3 specialists review in parallel:

Pick from `config.specialists.{backend_plan|frontend_plan}` based on scope:
- Always include the architect / lead role
- Add security agent if auth / input handling
- Add database agent if migrations
- Fullstack: 1-2 backend + 1 frontend

**If `config.specialists` not set**: fallback — Opus reviews the plan inline (no parallel agents). Note this in announcement.

All specialists APPROVE → **re-run §2.0 on the approved plan's per-file line deltas** (H's second, post-approval run — the first artifact with real per-file scope; SPLIT-REQUIRED here means split, not implement), then → Step 3.
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
