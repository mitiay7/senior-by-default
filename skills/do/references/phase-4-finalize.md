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

### Step 3: write atomically
Build the entry as a single-line JSON object (no newlines inside) and append:

```bash
JSON='{"ref":"i42","title":"...","started_at":"2026-05-08T04:15:00Z","ended_at":"2026-05-08T04:46:00Z","complexity":"M","scope":"Backend","implementer":"sonnet","files_changed":3,"lines_added":42,"lines_deleted":7,"phase_durations_seconds":{"0":12,"1":40,"2":900,"3":180,"4":60},"review_cycles":1,"gates":{"test":{"status":"pass"},"i18n":{"status":"n-a"}},"self_review":{"performed":true,"claimed_status":"ready","calibration":"accurate","miscalibrated":[]},"specialist_iterations":[],"ci_status":"skipped","auto_merge":false,"outcome":"merged","blocked_reason":null}'

echo "$JSON" >> "$LOG_PATH"
```

Use single-quoted bash heredoc OR build via `python3 -c 'import json,sys; print(json.dumps({...}))' >> "$LOG_PATH"` for safer escaping. **Do NOT** use multi-line JSON — JSONL = one object per line.

### Step 4: verify (REQUIRED)
```bash
COUNT=$(wc -l < "$LOG_PATH" | tr -d ' ')
echo "Metrics: $COUNT entries in $LOG_PATH"
```

Check the printed count grew by 1 from before. If the file didn't grow, the append failed — diagnose (permission? typo in JSON?) and retry, or report failure in the final announce as `Metrics: APPEND FAILED — <reason>`.

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

The announce is the final user-visible output. It MUST be generated by the procedure below — **the metrics-emit step and the announce-print step are one bash flow**. You cannot produce the announce without first appending the JSONL entry, because the announce text references a shell variable (`$METRICS_LINE`) that the emit step computes.

If the announce comes out without `Metrics: ...` at the end (when `config.metrics.log_path` is set), you broke the procedure — go back and follow it.

### The procedure (run this whole block as one Bash command)

```bash
# === Phase 4.0.5 pre-emit sanity check — capture pre-count ===
if [ -n "$LOG_PATH" ]; then
  mkdir -p "$(dirname "$LOG_PATH")"
  PRE_COUNT=$(wc -l < "$LOG_PATH" 2>/dev/null | tr -d ' ' || echo 0)
fi

# === Phase 4.11 metrics emit (atomic with announce) ===
if [ -n "$LOG_PATH" ]; then
  # JSON_ENTRY constructed earlier in Phase 4.11 (see §4.11 for schema).
  # Truncate, then append the line.
  if echo "$JSON_ENTRY" >> "$LOG_PATH"; then
    POST_COUNT=$(wc -l < "$LOG_PATH" | tr -d ' ')
    DELTA=$((POST_COUNT - PRE_COUNT))
    if [ "$DELTA" -eq 1 ]; then
      METRICS_LINE="Metrics: $POST_COUNT entries in $LOG_PATH"
    else
      # Append "succeeded" but file didn't grow by exactly 1 — silent corruption
      METRICS_LINE="Metrics: APPEND FAILED — pre=$PRE_COUNT post=$POST_COUNT delta=$DELTA expected=1"
    fi
  else
    METRICS_LINE="Metrics: APPEND FAILED — write error to $LOG_PATH (exit $?)"
  fi
else
  METRICS_LINE="Metrics: not configured (set config.metrics.log_path to enable)"
fi

# === Phase 4.13 announce — uses $METRICS_LINE computed above ===
# Optional lines added per task context:
[ -n "$CONTEXT_DOC_UPDATED" ] && CTX_LINE="Context: $CONTEXT_DOC_PATH §$SECTIONS updated."
[ -n "$ADR_NUMBER"          ] && ADR_LINE="ADR-${ADR_NUMBER} committed."

cat <<EOF
Complete. Branch: $EXPECTED. PR: ${PR_URL:--}. CI: ${CI_STATUS:-skipped}. Auto-merge: ${AUTO_MERGE_STATUS:-off}.
${CTX_LINE:+$CTX_LINE
}${ADR_LINE:+$ADR_LINE
}${METRICS_LINE}.
EOF
```

### Why pre-count + delta verification

Just running `echo >> file` and reading `wc -l` after isn't sufficient — `>>` can succeed (returns exit 0) while the actual write is partial or zero (e.g., disk full, file locked, permission flipped mid-write). Capturing PRE_COUNT before and verifying DELTA == 1 after is the cheapest way to fail loud on silent corruption. If something went wrong, the announce reports `APPEND FAILED` with diagnostic numbers — user sees it immediately rather than discovering a missing entry days later when reviewing metrics.

For the spawned-agent execution model (where the agent runs everything start-to-finish and returns to a parent), this matters extra because the agent's final message is the only thing the parent sees — if the diagnostic ends up there, parent flags it; if announce is plain prose, parent thinks success.

### Why the coupling

Five rounds of audit (v0.2.0 → v0.3.0) and several real production runs proved that "Phase 4.11 mandatory" written as a separate instruction in the middle of phase-4-finalize.md gets skipped systematically — sub-agent reads the instruction at session start, opens the PR, writes a detailed PR-summary as the final output, and stops without emitting metrics. By making the announce SHELL-DEPEND on the metrics-emit step (`$METRICS_LINE` is set ONLY by the emit block), you cannot produce the announce text without running the emit block. Hard structural coupling, not soft instruction.

If `config.metrics.log_path` is unset, the announce still works (METRICS_LINE = "not configured") — only the file write is skipped.

### What "broke the procedure" looks like

- Final assistant message ends with PR summary, no `Metrics:` line at the very end → you skipped the bash procedure
- `Metrics:` line is present but `wc -l` count didn't grow → entry write failed silently
- Announce uses different format than above → you composed prose instead of running the bash flow

Before sending the announcement, scan [`anti-patterns.md`](anti-patterns.md) — verify nothing in the list applies to what you just did.
