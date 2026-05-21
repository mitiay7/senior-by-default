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

### Step 3: emit the entry — **ONLY via the `metrics-append` wrapper**

There is exactly one supported way to write to the metrics log: the wrapper script at
`~/.claude/skills/do/scripts/metrics-append` (resolves to the same path inside the installed
skill). Direct `echo ... >> "$LOG_PATH"`, calling `python3 -c '...' >> "$LOG_PATH"`, or using
the `Write` tool against the log path are all an [anti-pattern](anti-patterns.md) — past
production runs proved sub-agents systematically compose free-form JSON when an in-doc template
is "suggested", producing 100+ distinct field names across a few dozen entries and emitting the
critical `self_review` calibration block in **0 of 37** observed entries. The wrapper's named-args
CLI removes that freedom: unknown flags reject, missing required flags reject, bad enums reject,
and the on-disk shape is guaranteed uniform across runs.

The wrapper enforces:
- Required fields present (`--ref`, `--complexity`, `--implementer`, `--outcome`,
  `--started-at`, `--ended-at`, `--files-changed`, `--lines-added`, `--lines-deleted`,
  `--sr-performed`, `--sr-claimed`, `--sr-calibration`)
- Enum validation on complexity / implementer / outcome / self-review fields
- JSON validity of `--gates-json` / `--phase-durations-json` payloads
- Atomic append with pre/post line-count delta verification
- Exit code 0 on success (stdout: `OK pre=N post=N+1 path=<log>`), 1 on schema reject
  (stderr: `REJECT <reason>`), 2 on I/O failure (stderr: `IOFAIL <reason>`)

**Computing `$OUTCOME` (strict 3-value enum — production audit found 16 distinct values pre-enforcement; the wrapper now hard-rejects anything else)**:

```bash
# Decide outcome from the actual Phase 4 result, not from a guess.
# Read state in this exact order (first match wins):
if [ "$BLOCKED" = "true" ]; then
  # Phase 3 escalated after 3 failed cycles, draft PR + `blocked` label applied
  OUTCOME="blocked"
elif gh pr view "$PR_NUMBER" --repo "$CODE_REPO" --json mergedAt -q .mergedAt 2>/dev/null | grep -qv '^$'; then
  # PR is merged (either auto-merge completed or manual merge)
  OUTCOME="merged"
else
  # PR opened but not yet merged (manual review pending, or auto-merge waiting for CI)
  OUTCOME="ready_for_review"
fi
```

Do NOT invent values like `pr_opened`, `success`, `shipped`, `merged_pending`, `merged_or_pr_open` — wrapper rejects. The 3-value mapping is exhaustive for /do's exit states.

**Computing `$ORCHESTRATOR`**: pass the running model identifier from session metadata (same source as Co-Authored-By footer per [SKILL.md notation](../SKILL.md#notation)). If unknown, omit the flag — wrapper defaults to `"opus"` (spec mandates orchestrator=opus regardless of model version).

**Computing `$STARTED_AT`**: capture **at Phase 0 entry** (the moment the orchestrator first runs `date -u +%Y-%m-%dT%H:%M:%SZ`), NOT retroactively at Phase 4.13. The wrapper hard-rejects `--ended-at < --started-at` (production audit: 36% of pre-fix entries had negative cycle times from back-computing started_at at the end).

Canonical invocation (executed by the §4.13 announce block; do NOT run it standalone, the
announce coupling depends on capturing its stdout into `$METRICS_LINE`):

```bash
~/.claude/skills/do/scripts/metrics-append \
  --log              "$LOG_PATH" \
  --ref              "$REF" \
  --complexity       "$COMPLEXITY" \
  --orchestrator     "$ORCHESTRATOR" \
  --implementer      "$IMPLEMENTER" \
  --outcome          "$OUTCOME" \
  --started-at       "$STARTED_AT" \
  --ended-at         "$ENDED_AT" \
  --files-changed    "$FILES_CHANGED" \
  --lines-added      "$LINES_ADDED" \
  --lines-deleted    "$LINES_DELETED" \
  --sr-performed     "$SR_PERFORMED" \
  --sr-claimed       "$SR_CLAIMED_STATUS" \
  --sr-calibration   "$SR_CALIBRATION" \
  [--gates-json              "$GATES_JSON" \                  # optional, defaults {}
   --phase-durations-json    "$PHASE_DURATIONS_JSON" \         # optional, defaults {}
   --review-cycles           "$REVIEW_CYCLES" \                # optional, defaults 0
   --ci-status               "$CI_STATUS" \                    # optional, defaults skipped
   --auto-merge              "$AUTO_MERGE_FLAG" \              # optional, defaults false
   --blocked-reason          "$BLOCKED_REASON" \               # optional
   --title                   "$TITLE" \                        # optional
   --scope                   "$SCOPE" \                        # optional
   --notes                   "$NOTES" \                        # optional free-text
   --specialist-iterations-json "$SPECIALIST_ITERATIONS_JSON" \# optional
   --sr-miscalibrated-json   "$SR_MISCALIBRATED_JSON"]          # optional, defaults []
```

#### Defense in depth

A daily report script (`~/.claude/do/metrics/daily-report.sh`, separate from the skill)
scans logs for schema-invalid entries and surfaces them in a dedicated section. So even if
a sub-agent bypasses the wrapper, the bypass shows up in the next morning's report rather
than silently polluting the analysis. Don't rely on this — it's a tripwire, not a fix.

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
# Phase 4.11 emit — invoke the wrapper. METRICS_LINE is set ONLY by capturing its result.
# The wrapper does schema validation, atomic append, and pre/post line-count delta verify
# internally. We never compose JSON here; we never `>>` to the log file here.
if [ -n "$LOG_PATH" ]; then
  if METRICS_RESULT=$(~/.claude/skills/do/scripts/metrics-append \
        --log              "$LOG_PATH" \
        --ref              "$REF" \
        --complexity       "$COMPLEXITY" \
        ${ORCHESTRATOR:+--orchestrator "$ORCHESTRATOR"} \
        --implementer      "$IMPLEMENTER" \
        --outcome          "$OUTCOME" \
        --started-at       "$STARTED_AT" \
        --ended-at         "$ENDED_AT" \
        --files-changed    "$FILES_CHANGED" \
        --lines-added      "$LINES_ADDED" \
        --lines-deleted    "$LINES_DELETED" \
        --sr-performed     "$SR_PERFORMED" \
        --sr-claimed       "$SR_CLAIMED_STATUS" \
        --sr-calibration   "$SR_CALIBRATION" \
        ${TITLE:+--title              "$TITLE"} \
        ${SCOPE:+--scope              "$SCOPE"} \
        ${NOTES:+--notes              "$NOTES"} \
        ${GATES_JSON:+--gates-json    "$GATES_JSON"} \
        ${PHASE_DURATIONS_JSON:+--phase-durations-json "$PHASE_DURATIONS_JSON"} \
        ${REVIEW_CYCLES:+--review-cycles "$REVIEW_CYCLES"} \
        ${CI_STATUS:+--ci-status      "$CI_STATUS"} \
        ${AUTO_MERGE_FLAG:+--auto-merge "$AUTO_MERGE_FLAG"} \
        ${BLOCKED_REASON:+--blocked-reason "$BLOCKED_REASON"} \
        2>&1); then
    # stdout shape: "OK pre=N post=N+1 path=<log>"
    POST_COUNT=$(echo "$METRICS_RESULT" | sed -n 's/.*post=\([0-9]*\).*/\1/p')
    METRICS_LINE="Metrics: $POST_COUNT entries in $LOG_PATH"
  else
    # wrapper printed REJECT <reason> or IOFAIL <reason> to stderr (captured via 2>&1)
    METRICS_LINE="Metrics: APPEND FAILED — $METRICS_RESULT"
  fi
else
  METRICS_LINE="Metrics: not configured (set config.metrics.log_path to enable)"
fi

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

### Why structural coupling + external wrapper, not soft instruction

Three enforcement layers, each addressing a failure mode the previous one missed:

1. **Soft "mandatory" instruction** (v0.1–v0.3) — got skipped systematically. Sub-agent reads "Phase 4.11 mandatory" at session start, opens the PR, writes detailed PR-summary as final output, stops without emitting metrics.

2. **Announce↔emit bash coupling** (v0.3–v0.5) — `$METRICS_LINE` set only by the emit block, no emit → can't compose announce. Fixed the "stops without emitting" failure. Still let sub-agents compose JSON freely inside the emit block, producing 100+ distinct field names across runs and `self_review` block missing in 0 of 37 entries (v0.6 audit).

3. **External wrapper with named-args CLI** (current) — the wrapper is the only path to a valid append. Unknown flags reject, missing required flags reject, bad enums reject. Sub-agent cannot invent a new shape without making the announce print `Metrics: APPEND FAILED — REJECT <reason>`, which is visible. Pre/post line-count delta verification lives inside the wrapper too, so a `>>` that returns exit 0 without actually writing (disk full, lock) is still caught.

The wrapper file (`skills/do/scripts/metrics-append`) lives in the skill and ships with the install. The §4.13 bash block above invokes it and captures stdout into `$METRICS_LINE`. If `config.metrics.log_path` is unset, the wrapper isn't called and METRICS_LINE = "not configured" — announce still works, only the file write is skipped.

### What "broke the procedure" looks like

- Final assistant message ends with PR summary, no `Metrics:` line at the very end → you skipped the bash procedure
- `Metrics:` line says `APPEND FAILED — REJECT <reason>` → the wrapper rejected your input. The reason is explicit (missing required arg, bad enum, malformed JSON payload). Fix the offending value and re-run the emit. Most common: forgot `--sr-performed/--sr-claimed/--sr-calibration` from Phase 2.5.
- `Metrics:` line says `APPEND FAILED — IOFAIL <reason>` → file write or count-delta check failed. Diagnose disk/lock/permission.
- Announce uses different format than above (free prose) → you composed text instead of running the bash flow
- Log file gained an entry but `Metrics:` line in announce didn't reference it (or shape doesn't match the wrapper output) → you bypassed the wrapper and wrote directly. The daily-report scanner will surface the bypass in tomorrow's report; don't do this.

For the spawned-agent execution model (agent runs everything start-to-finish and returns to a parent), this matters extra: the agent's final message is the only thing the parent sees. If diagnostic ends up there, parent flags it; if announce is plain prose, parent thinks success.

**Applies whether you are the spawned agent doing everything yourself, or a parent orchestrator** — there's no "the other one" to defer to; if you're reading this, you are the executor.

Before sending the announcement, scan [`anti-patterns.md`](anti-patterns.md) — verify nothing applies.
