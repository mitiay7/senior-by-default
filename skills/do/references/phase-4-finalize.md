# Phase 4 — Finalize

Tracker operations use `{Tracker.OP}` from [`trackers.md`](trackers.md). Branch / commit naming uses `config.naming.issue.{branch, ref_format}`.

> **Critical ordering**: Phase 4.0 (branch normalization) MUST run BEFORE 4.2 (PR creation). Final announce (4.13) is COUPLED to Phase 4.11 metrics emission via shared bash variables — you literally cannot emit the announce without first running the metrics-append command. See "Final announce" at the bottom of this file.

## 4.0 Branch normalization — UNCONDITIONAL, BEFORE any push or PR

The very first step of Phase 4. **Runs before commit, push, or PR creation**, so the PR opens on the correct branch name from the start.

```bash
ACTUAL=$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD)

# Compute EXPECTED from config.naming + N + slug
if [ "$COMPLEXITY" = "L" ] || [ "$COMPLEXITY" = "T" ]; then
  EXPECTED="feat/${SLUG}"             # config.naming.low.branch
else
  EXPECTED="feat/i${N}-${SLUG}"       # config.naming.issue.branch
fi

if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "⚠ Branch mismatch: actual=$ACTUAL expected=$EXPECTED — renaming"
  git -C "$WORKTREE_PATH" branch -m "$EXPECTED"
  # If old branch was already pushed, delete its remote ref:
  git -C "$WORKTREE_PATH" push origin --delete "$ACTUAL" 2>/dev/null || true
  RENAMED_BRANCH=true
fi
```

### Pre-spawned worktree is NOT an excuse

If you find yourself inside a worktree that was created by Claude Code's harness (`Agent(isolation: "worktree")`) with an auto-named branch like `claude/<adj>-<noun>-<hash>`, the rename is STILL UNCONDITIONAL. Do not rationalize "the worktree was pre-spawned, so I'll keep the auto-name" — the worktree path is fine to keep, but the BRANCH must follow `config.naming` so that downstream PR titles, commit `Ref:` lines, metrics entries, and tracker comments all cross-reference correctly via the `i{N}` token.

If you found yourself in this situation, also record `"branch_rename"` in the metrics entry below — this is the signal that some upstream automation pre-spawned a worktree without following the skill's worktree-setup spec. Useful diagnostic.

## 4.1 Commit
Final commit message:
- Subject per Conventional Commits (see [`git-rules.md`](git-rules.md))
- Body includes `Ref: {config.issue_tracker.repo}#{N}` if issue tracker configured (use `config.naming.issue.ref_format` for the formatted id)
- Footer: `Co-Authored-By: <current model from environment> <noreply@anthropic.com>` — **auto-detect from environment, never hardcode**

Secret check (filenames + content) before push. See [`git-rules.md`](git-rules.md).

### 4.1.2 Push
```
git -C "$WORKTREE_PATH" push -u origin "$EXPECTED"
```

## 4.2 PR / MR creation (Medium / High, if issue tracker configured)

PR/MR is always against the **code-hosting** platform. Detect from `git remote get-url origin`:
- `github.com` → `gh pr create --repo {code_repo}`
- `gitlab.com` or self-hosted GitLab → `glab mr create -R {code_repo}`
- Other → instruct user to open via web UI

PR body close keyword:
- Same-repo issue tracker: `{config.issue_tracker.commands.close_keyword or "Closes"} #{N}`
- Cross-repo: `Refs {config.issue_tracker.repo}#{N}`
- Linear / Jira / etc: prepend `{close_keyword} {N}` to PR description

PR body should also include:
- Brief summary of changes
- Test plan (from Sonnet's report)
- Self-review summary (from Phase 2.5)
- ADR reference if exists (`References ADR-{NNNN}`)
- PR-size note if Phase 3.0 warned

CODEOWNERS: do NOT bypass auto-request. For GitLab MRs, manually `--reviewer` per CODEOWNERS owners (see [`codeowners.md`](codeowners.md)).

Fullstack → PR per code repo. One repo's PR fails → draft PR for failing one, normal PR for passing one, document mismatch in issue comment.

## 4.2.5 CI Gate — wait for green checks

**Skipped if `config.ci.required` is not explicitly set to `true`** (no auto-default — feature is opt-in). Most solo / local-only setups don't run cloud CI; gating on missing checks would just timeout.

If `config.ci.required: true` AND `--skip-ci-wait` not in `$ARGUMENTS`:

GitHub:
```
gh pr checks {N} --watch --interval 30 --required
```
With timeout `config.ci.timeout_seconds` (default 1800 = 30 min). Use `timeout` shell command:
```
timeout {timeout_seconds} gh pr checks {N} --watch --interval 30 --required
```

GitLab:
```
glab ci status --branch {branch} --wait
```

Custom: `config.ci.wait_command` (template with `{N}`, `{branch}`, `{repo}` placeholders).

Outcomes:
- All required checks PASS → proceed to 4.2.6
- Any required check FAIL → 
  - If `config.ci.fail_action == "block"` (default): pull failure logs (`gh run view --log-failed`), return to Sonnet for fix (counts as a Phase 3 cycle)
  - If `"warn"`: print failure summary, proceed but add `⚠ CI failures: {names}` to issue comment in 4.7
- Timeout → escalate to user: `"CI gate timed out after {N}s. Check {url} manually."`. Do NOT auto-merge.
- Send `ci_failed` notification if configured.

## 4.2.6 Auto-merge

If `config.auto_merge.enabled` OR `--auto-merge` in `$ARGUMENTS` (and `--no-auto-merge` not present):
- Verify CI is green (4.2.5 already passed) AND PR isn't blocked by required reviews
- Run:
  ```
  gh pr merge {N} --auto --{config.auto_merge.method}    # squash | merge | rebase
  ```
  with `--delete-branch` if `config.auto_merge.delete_branch: true` (default true)
- For GitLab:
  ```
  glab mr merge {N} --auto-merge --{method}
  ```
- Print: `Auto-merge enabled. Will merge when reviews approved.`

If auto-merge command rejected (branch protection requires explicit reviewer) → fall back to `await_review` mode: print PR url and required-reviewer list, wait for manual merge.

**Never auto-merge if `config.ci.required: false`** — would defeat the gate. Warn user if both flags conflict.

## 4.3 Low complexity — skip PR
No PR. Emit change summary:
- Files changed (paths)
- Functions added / modified
- Build / test results
- Self-review section (if enabled)

Tell user:
```
Branch pushed: {branch}. Review diff and merge when ready.
git -C {repo} diff main...{branch}
```

## 4.4 Tech-debt accumulation
New tech-debt items found during the task:
- If `config.tech_debt_doc` set → append to "Batched deferred" section
- Else if `config.issue_tracker` set → create new issue with label `tech-debt`
- Else → write to `config.memory_path` (or `auto`-resolved memory path)

Skip if no items.

## 4.5 Feature docs
If you changed feature logic AND feature docs exist (project-specific path) → update them. Skip for cosmetic / refactor changes. Already covered by 3.0.6 if `config.public_docs_dir` set.

## 4.6 Context doc update — BLOCKING
**Only if `config.context_doc.required_for_finalize: true`.** Otherwise skip.

For all complexity levels: update `config.context_doc.path`. Required sections (use `config.context_doc.sections` mapping):

- **§{sections.current_state}** — bump "Last updated" to today's date. If migration → bump "Next migration" + append. If merged → move from Open Work → Recently Merged. Update "Last merged issue" / "Last PR".
- **§{sections.structure}** — add new module/page/route. Remove deleted.
- **<feature-section>** — update endpoints, invariants, types if changed.
- **§{sections.deployment}** — only if env / compose / webhook changed.
- **§{sections.constraints}** — add gotchas, remove obsolete ones.

### Delivery
If the PR already touches the file → commit in same branch.

Else push directly to context_doc's repo `main`:
```
cd {dir containing context_doc} && git pull origin main
# edit
git add {context_doc.path} && git commit -m "docs(agent-context): update after {ref_format} — {summary}" && git push origin main
```

If Sonnet failed to update → Opus updates inline + notes in PR description: `Context updated by Opus: {sections}`.

## 4.7 Issue comment (M/H — REQUIRED if issue tracker)
Use `{Tracker.comment}` with body file:
```
✅ Done. PR: <url> · Migration: NNN (or —) · Build: <list of ✓ checks> [+ if context_doc → "· Context updated: {context_doc.path} §N[, §M]"] [+ if ADR → "· ADR-{NNNN}"] [+ if auto-merge → "· Auto-merge enabled"]
```

Required content if context_doc updated: `Context updated: {context_doc.path} §N[, §M]`.

## 4.8 Worktree cleanup
**Tell user — do NOT execute** unless explicitly requested OR auto-merge enabled with `delete_branch: true` (then GitHub deletes the remote branch on merge; user still removes local worktree).

If `config.worktree.cleanup_cmd` set → suggest that template (substitute `{repo}`, `{suffix}`).
Else suggest:
```
After merge:
  git -C {main_repo_path} worktree remove {worktree_path}
  git -C {main_repo_path} branch -D {branch}    # only after merge confirmed
```

## 4.9 Rollback note
If merged branch turns out to have bugs:
- New `fix/...` branch from `origin/main`
- `git revert <merge-sha>`
- Never rewrite history of merged work

If postmortem context applies → trigger `/postmortem` flow (or write postmortem section into the rollback issue).

## 4.10 Lessons learned (optional)
If `config.lessons_doc` set:
- Ask user: "Anything surprising worth recording? (skip / one-line / full entry)"
- One-line or full → append to `config.lessons_doc` with date + ref_format prefix
- Skip → continue silently

## 4.11 Metrics log — **MANDATORY when configured**

**If `config.metrics.log_path` is set, this step is NOT optional.** Skipping it is an [anti-pattern](anti-patterns.md). Phase 4 cannot be considered complete until the JSONL entry is appended AND verified. The final announce (below) MUST include either `Metrics: <count> entries in <path>` or an explicit skip reason (`Metrics: skipped — <reason>`).

If the field is unset/null → silently skip (no log path = no metrics, no warning).

### Step 1: prepare path
```bash
LOG_PATH="<resolved log_path>"        # placeholders like {repo_slug} substituted by you
mkdir -p "$(dirname "$LOG_PATH")"
```

`{repo_slug}` placeholder substitution (if present in `log_path`):
- Take the repo path (`config.workspace.repos.<key>.path` or single-repo path)
- Apply: `[^a-zA-Z0-9]+` → `-`, then strip leading/trailing `-`
- Example: `/Users/alice/work/my-monorepo` → `Users-alice-work-my-monorepo`

### Step 2: compose the entry
Always include (Tier 0+): `ref, title, started_at, ended_at, complexity, scope, implementer, files_changed, lines_added, lines_deleted, phase_durations_seconds, review_cycles, gates, ci_status, auto_merge, outcome, blocked_reason`.

If `config.metrics.tier >= 1`, additionally:
- `gates[name].details` — populated by Phase 3 at the moment of detection (see Phase 3 metrics-capture section)
- `gates[name].fix_cycle` — which review cycle resolved this gate (0 = first try)
- `self_review` block — `{performed, claimed_status, calibration, miscalibrated}` per the calibration logic below
- `specialist_iterations` — accumulated during Phase 3.6 (High only)

All captured strings truncated to `config.metrics.max_string_length` (default 500) to keep JSONL parseable.

### Step 3: build the entry — **structurally enforced shape**

Do NOT compose JSON as a free-form string. Build with `jq -n` from explicit env vars so that
(a) bash fails loudly on missing required fields and (b) the on-disk schema is uniform across runs.

This template is the canonical shape. Cross-run analysis (FP-rate, complexity vs review cycles,
gate failure trends) requires every entry to use the same keys with the same types — past audits
found 100+ distinct field names across a few dozen entries when sub-agents built JSON freely.

```bash
# Required fields — sub-agent MUST set ALL before build. `:?` halts bash on unset.
: "${REF:?REF unset (e.g. i42 for M/H, slug for L/T)}"
: "${COMPLEXITY:?COMPLEXITY unset (T|L|M|H)}"
: "${IMPLEMENTER:?IMPLEMENTER unset (haiku|sonnet|opus)}"
: "${OUTCOME:?OUTCOME unset (merged|pr_opened|blocked|abandoned|verified_no_change)}"
: "${STARTED_AT:?STARTED_AT unset (ISO-8601 UTC)}"
: "${ENDED_AT:?ENDED_AT unset (ISO-8601 UTC)}"
: "${FILES_CHANGED:?FILES_CHANGED unset (integer)}"
: "${LINES_ADDED:?LINES_ADDED unset (integer)}"
: "${LINES_DELETED:?LINES_DELETED unset (integer)}"

# self_review block — REQUIRED when tier >= 1 AND config.self_review.enabled.
# Even when self-review was not performed, set explicit "skipped"/"n/a" values — never omit.
: "${SR_PERFORMED:?SR_PERFORMED unset (true|false from Phase 2.5)}"
: "${SR_CLAIMED_STATUS:?SR_CLAIMED_STATUS unset (ready|deferred|uncertain|n/a)}"
: "${SR_CALIBRATION:?SR_CALIBRATION unset (accurate|false_positive|false_negative|skipped) — see calibration logic below}"

# Optional fields with safe defaults. Done as plain assignments because `${var:-{}}` and
# `${var:-[]}` parse incorrectly in bash (the closing `}` of the expansion swallows the
# brace, leaving a trailing literal that breaks `jq --argjson`).
[ -z "${PHASE_DURATIONS_JSON:-}"     ] && PHASE_DURATIONS_JSON='{}'
[ -z "${GATES_JSON:-}"               ] && GATES_JSON='{}'
[ -z "${SR_MISCALIBRATED:-}"         ] && SR_MISCALIBRATED='[]'
[ -z "${SPECIALIST_ITERATIONS_JSON:-}" ] && SPECIALIST_ITERATIONS_JSON='[]'
REVIEW_CYCLES="${REVIEW_CYCLES:-0}"
AUTO_MERGE_FLAG="${AUTO_MERGE_FLAG:-false}"
CI_STATUS="${CI_STATUS:-skipped}"

JSON_ENTRY=$(jq -cn \
  --arg     ref             "$REF" \
  --arg     title           "${TITLE:-}" \
  --arg     started_at      "$STARTED_AT" \
  --arg     ended_at        "$ENDED_AT" \
  --arg     complexity      "$COMPLEXITY" \
  --arg     scope           "${SCOPE:-}" \
  --arg     implementer     "$IMPLEMENTER" \
  --argjson files_changed   "$FILES_CHANGED" \
  --argjson lines_added     "$LINES_ADDED" \
  --argjson lines_deleted   "$LINES_DELETED" \
  --argjson phase_durations "$PHASE_DURATIONS_JSON" \
  --argjson review_cycles   "$REVIEW_CYCLES" \
  --argjson gates           "$GATES_JSON" \
  --argjson sr_performed    "$SR_PERFORMED" \
  --arg     sr_claimed      "$SR_CLAIMED_STATUS" \
  --arg     sr_calibration  "$SR_CALIBRATION" \
  --argjson sr_misc         "$SR_MISCALIBRATED" \
  --argjson specialist_iters "$SPECIALIST_ITERATIONS_JSON" \
  --arg     ci_status       "$CI_STATUS" \
  --argjson auto_merge      "$AUTO_MERGE_FLAG" \
  --arg     outcome         "$OUTCOME" \
  --arg     blocked_reason  "${BLOCKED_REASON:-}" \
  '{
     ref:$ref, title:$title,
     started_at:$started_at, ended_at:$ended_at,
     complexity:$complexity, scope:$scope, implementer:$implementer,
     files_changed:$files_changed, lines_added:$lines_added, lines_deleted:$lines_deleted,
     phase_durations_seconds:$phase_durations,
     review_cycles:$review_cycles,
     gates:$gates,
     self_review:{
       performed:$sr_performed,
       claimed_status:$sr_claimed,
       calibration:$sr_calibration,
       miscalibrated:$sr_misc
     },
     specialist_iterations:$specialist_iters,
     ci_status:$ci_status,
     auto_merge:$auto_merge,
     outcome:$outcome,
     blocked_reason:(if $blocked_reason=="" then null else $blocked_reason end)
   }')
```

### Step 3.5: schema gate — refuse to append a malformed entry

```bash
echo "$JSON_ENTRY" | jq -e '
  (.ref            | type=="string" and length>0)              and
  (.complexity     | test("^[TLMH]$"))                          and
  (.implementer    | test("^(haiku|sonnet|opus)$"))             and
  (.outcome        | type=="string" and length>0)               and
  (.files_changed  | type=="number")                            and
  (.self_review.performed     | type=="boolean")                and
  (.self_review.claimed_status| test("^(ready|deferred|uncertain|n/a)$"))   and
  (.self_review.calibration   | test("^(accurate|false_positive|false_negative|skipped)$"))
' >/dev/null || {
  # Do NOT append. Surface in the announce so it's visible, not silently dropped.
  METRICS_LINE="Metrics: SCHEMA REJECT — required fields or self_review invalid; entry NOT appended"
  SCHEMA_OK=0
}
SCHEMA_OK=${SCHEMA_OK:-1}
```

### Step 4: append + verify (REQUIRED)

The append + count-delta check is folded into the Phase 4.13 announce block below — it runs only
if `SCHEMA_OK=1`. There is no separate "echo $JSON >> file" step; the announce procedure owns
both the write and the verification, so a sub-agent cannot append without producing the announce
and cannot produce the announce without first running the schema gate.

### Self-review calibration logic
After Phase 3 completes, before Step 2:

```
phase3_failed_gates = [g for g in gates if gates[g].status in ("fail", "block")]
sonnet_claimed = sonnet_self_review.claimed_status        # "ready" | "deferred" | "uncertain"

if not self_review.performed:
    calibration = "skipped"
elif sonnet_claimed == "ready" and phase3_failed_gates:
    calibration = "false_positive"
    miscalibrated = [f"{g}: claimed clean; Phase 3 found {brief_reason}" for g in phase3_failed_gates]
elif sonnet_claimed == "ready" and not phase3_failed_gates:
    calibration = "accurate"
elif sonnet_claimed in ("deferred", "uncertain") and not phase3_failed_gates:
    calibration = "false_negative"
else:
    calibration = "accurate"   # flagged issues, Phase 3 confirmed
```

This calibration metric is the **highest-signal data point** for skill iteration. False-positive rate trending up → self-review prompt too lax. False-negative rate up → Sonnet over-flagging.

### Schema reference
See [`config-schema.md`](config-schema.md) under `metrics` for the full Tier 1 entry schema.

### What metrics enable
DORA-ish self-analysis: cycle time per complexity, review-iterations distribution, gate failure rate, self-review calibration trend, CI flakiness (when CI gate is opt-in-on).

## 4.12 Notify completion
If `config.notifications` configured AND `task_completed` in events → send. See [`notifications.md`](notifications.md). Include PR url, auto-merge status, ADR ref if applicable.

## 4.13 Final announce — **STRUCTURALLY COUPLED to Phase 4.11 metrics emission**

The announce is the final user-visible output. It MUST be generated by the bash procedure below — **the metrics emit and the announce print are one shell flow**. The announce text references `$METRICS_LINE` which is set ONLY by the emit block. You cannot produce the announce without running the emit.

### The procedure (run this whole block as one Bash command)

```bash
# Phase 4.0.5 pre-emit: capture count before append
if [ -n "$LOG_PATH" ]; then
  mkdir -p "$(dirname "$LOG_PATH")"
  PRE_COUNT=$(wc -l < "$LOG_PATH" 2>/dev/null | tr -d ' ' || echo 0)
fi

# Phase 4.11 emit + delta verify
# Skipped if Step 3.5 set SCHEMA_OK=0 (METRICS_LINE already populated with SCHEMA REJECT).
if [ -n "$LOG_PATH" ] && [ "${SCHEMA_OK:-1}" -eq 1 ]; then
  if echo "$JSON_ENTRY" >> "$LOG_PATH"; then
    POST_COUNT=$(wc -l < "$LOG_PATH" | tr -d ' ')
    DELTA=$((POST_COUNT - PRE_COUNT))
    if [ "$DELTA" -eq 1 ]; then
      METRICS_LINE="Metrics: $POST_COUNT entries in $LOG_PATH"
    else
      # `>>` returned exit 0 but file didn't grow — silent corruption (disk full, lock, etc.)
      METRICS_LINE="Metrics: APPEND FAILED — pre=$PRE_COUNT post=$POST_COUNT delta=$DELTA expected=1"
    fi
  else
    METRICS_LINE="Metrics: APPEND FAILED — write error to $LOG_PATH (exit $?)"
  fi
elif [ -z "$LOG_PATH" ]; then
  METRICS_LINE="Metrics: not configured (set config.metrics.log_path to enable)"
fi
# else: METRICS_LINE already set by Step 3.5 schema reject — keep as-is.

# Phase 4.13 announce — uses $METRICS_LINE computed above
[ -n "$CONTEXT_DOC_UPDATED" ] && CTX_LINE="Context: $CONTEXT_DOC_PATH §$SECTIONS updated."
[ -n "$ADR_NUMBER"          ] && ADR_LINE="ADR-${ADR_NUMBER} committed."

# Models line — orchestrator from frontmatter (opus), implementer from Phase 0 complexity routing,
# specialists from Phase 2 plan-review / Phase 3.6 audit roster (or "none")
MODELS_LINE="Models: orchestrator=${ORCHESTRATOR_MODEL:-opus}, implementer=${IMPLEMENTER_MODEL:-sonnet}, specialists=[${SPECIALISTS_LIST:-none}]"

cat <<EOF
Complete. Branch: $EXPECTED. PR: ${PR_URL:--}. CI: ${CI_STATUS:-skipped}. Auto-merge: ${AUTO_MERGE_STATUS:-off}.
${CTX_LINE:+$CTX_LINE
}${ADR_LINE:+$ADR_LINE
}${MODELS_LINE}.
${METRICS_LINE}.
EOF
```

### Why structural coupling, not soft instruction

Five rounds of audit (v0.2.0 → v0.3.0) + production runs proved that "Phase 4.11 mandatory" written as a separate instruction gets skipped systematically — sub-agent reads it at session start, opens the PR, writes detailed PR-summary as final output, stops without emitting metrics. The bash coupling makes the metrics-emit step a hard precondition for producing the announce text.

Two enforcement layers in the bash flow:
1. **Structural** — `$METRICS_LINE` set only by emit block → no emit → can't compose announce
2. **Pre/post delta** — `>>` can return exit 0 while writing nothing (disk full, lock, permission). PRE_COUNT vs POST_COUNT delta catches that.

If `config.metrics.log_path` is unset, METRICS_LINE = "not configured" — announce still works, only file write is skipped.

### What "broke the procedure" looks like

- Final assistant message ends with PR summary, no `Metrics:` line at the very end → you skipped the bash procedure
- `Metrics:` line says `APPEND FAILED` → file write returned exit 0 but didn't grow; diagnose disk/lock/permission
- `Metrics:` line says `SCHEMA REJECT` → one of the Step 3 `:?` vars was unset, or Step 3.5 jq gate rejected the entry. Fix the missing field (most often `SR_PERFORMED` / `SR_CLAIMED_STATUS` / `SR_CALIBRATION` from Phase 2.5) and re-run the emit block. The reject is intentional — appending a malformed entry pollutes the cross-run schema and silently degrades calibration analysis.
- Announce uses different format than above (free prose) → you composed text instead of running the bash flow

For the spawned-agent execution model (agent runs everything start-to-finish and returns to a parent), this matters extra: the agent's final message is the only thing the parent sees. If diagnostic ends up there, parent flags it; if announce is plain prose, parent thinks success.

**Applies whether you are the spawned agent doing everything yourself, or a parent orchestrator** — there's no "the other one" to defer to; if you're reading this, you are the executor.

Before sending the announcement, scan [`anti-patterns.md`](anti-patterns.md) — verify nothing applies.
