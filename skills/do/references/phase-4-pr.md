# Phase 4 — PR, CI gate, auto-merge, issue comment (§4.2 / §4.2.5 / §4.2.6 / §4.7)

**Load this file ONLY on the PR path: Medium / High with a code-hosting remote.** Trivial and Low never open PRs ([SKILL.md](../SKILL.md) tier simplifications; [`phase-4-finalize.md`](phase-4-finalize.md) §4.3) — on a T/L run, do NOT read this file. Section numbers continue `phase-4-finalize.md`'s scheme: prose elsewhere that cites "§4.2.5" or "Phase 4.2" refers to the sections below.

Sequencing (owned by [`phase-4-finalize.md`](phase-4-finalize.md)): §4.0 branch-normalize and the §4.1.2 secret-scan-gated push run BEFORE anything here; §4.11 metrics + §4.13 announce run AFTER, back in the core file. Outputs to carry back: `$PR_URL`, `$CI_STATUS`, `$AUTO_MERGE_STATUS` (+ the `⚠ merged unverified` fragment when §4.2.6's per-run confirmation path fired) — the §4.13 announce and §4.11 `--ci-status`/`--auto-merge` flags consume them; on T/L runs they simply stay unset and the announce prints its defaults. On the **auto-split path** (§4.2.1) also carry `$SPLIT_PR_URLS` (ordered stack list) and `pr_auto_split=k` in `--notes`; `$PR_URL` = the part-1 PR.

## 4.2 PR / MR creation (Medium / High, if issue tracker configured)

> **Auto-split fork (v0.11.0):** if Phase 3.0 set `PR_SPLIT_REQUIRED=1` (a `pr_size` BLOCK with auto-split armed), do NOT open a single PR here — jump to **§4.2.1 Auto-split delivery** below, which opens a *stack* of sub-cap PRs instead. The single-PR flow in this section is the normal (non-split) path.

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

## 4.2.1 Auto-split delivery — **stack of sub-cap PRs (only when `PR_SPLIT_REQUIRED=1`)**

Reached ONLY when Phase 3.0 hit a `pr_size` BLOCK with auto-split armed (default; §3.0). The full change has already been reviewed as one unit (Phase 3 ran to APPROVE on the whole diff), committed on the normalized tip branch (§4.0), and pushed (§4.1.2). This section splits **delivery** into a stack of PRs each under the cap — the wrapper owns the partition + branch construction, so you do not hand-pick file groups.

**Why a stack, not independent PRs:** the only auto-generatable split that is guaranteed build-coherent is stacked — part 1 branches off `main`, part *i* off part *i-1*, and the **last part's head IS the tip branch** (already pushed). Each PR's diff *against its base* is one sub-cap file-group; the stack tip is byte-identical to the reviewed change. Merged in stack order, `main` ends exactly at the reviewed tip. GitHub auto-retargets a child PR's base to the grandparent when the parent merges, so the stack collapses cleanly.

Run the wrapper (one bash block; `pr-split` builds the local part branches, verifies the partition, prints the plan — it does NOT push or open PRs):

```bash
# Canonical do-scripts resolver — identical line in every wrapper block.
DO_SCRIPTS="$(find -L ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT/skills"} "$HOME/.claude/skills" "$HOME/.claude/plugins/cache" "$HOME/.local/share/senior-by-default/skills" -maxdepth 7 -type f -name metrics-append -path '*/scripts/*' 2>/dev/null | head -1)"; DO_SCRIPTS="${DO_SCRIPTS%/metrics-append}"

BRANCH_NAME="$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD)"   # the §4.0-normalized tip branch (already pushed)
PLAN_JSON="$(mktemp)"

# Target = the WARN caps (reviewable ≈800-line parts), not the block caps; pass
# config.pr_size.* overrides via the same add_opt array idiom as §3.0 (zsh-safe).
SPLIT_ARGS=()
add_opt() { [ -n "${2:-}" ] && SPLIT_ARGS+=("$1" "$2"); return 0; }
add_opt --target-lines "${CFG_WARN_LINES:-800}"
add_opt --target-files "${CFG_WARN_FILES:-20}"
add_opt --block-lines  "${CFG_BLOCK_LINES:-}"
add_opt --block-files  "${CFG_BLOCK_FILES:-}"

if [ -x "$DO_SCRIPTS/pr-split" ]; then
  # --base is the PR base-branch NAME (the repo default — main/master); the
  # wrapper resolves origin/<base>, takes the merge-base with the tip, and opens
  # part 1 against this branch. $DEFAULT_BRANCH from stack/remote detection, else main.
  SPLIT_OUT="$("$DO_SCRIPTS/pr-split" --dir "$WORKTREE_PATH" --tip-branch "$BRANCH_NAME" \
      --base "${DEFAULT_BRANCH:-main}" --commit-subject "$COMMIT_SUBJECT" --plan-json "$PLAN_JSON" \
      ${SPLIT_ARGS[@]+"${SPLIT_ARGS[@]}"} 2>&1)" && SPLIT_RC=0 || SPLIT_RC=$?
else
  SPLIT_OUT="Phase 4.2: SPLIT-FAILED — pr-split wrapper not found (do-scripts resolver found no install)"; SPLIT_RC=3
fi
printf '%s\n' "$SPLIT_OUT"
```

Dispatch on the wrapper's outcome:

- **`SPLIT-OK` (exit 0)** — the plan is real (part branches built + verified; the `[tell:…]` on `SPLIT-PLAN` is the anti-fabrication tell). Then, **in stack order**, for each `SPLIT-PART` line:
  - `push=yes` parts → `git -C "$WORKTREE_PATH" push -u origin "<branch>"`. No extra secret scan: every part's content is a subset of the tip, which §4.1.2 already scanned over its full range — pushing already-scanned blobs. (`push=no` is the tip part — §4.1.2 already pushed it.)
  - Open one PR per part: `gh pr create --repo {code_repo} --base "<base>" --head "<branch>" --title "{PR title} (part i/k)"`. The PreToolUse hook (if enabled) measures `<base>...<branch>` — one sub-cap group — so each passes as non-draft. Body per part: the normal §4.2 content **plus** a stack header:
    ```
    ⛓ Stack part i/k · base: <base> · merge parts in order (1→k). This PR's diff is one slice of a change too large for a single reviewable PR; the full change was reviewed as a unit in {issue ref}.
    ```
    (Populate the per-part file list / line count from `$PLAN_JSON`.)
  - Collect every PR URL. Set `PR_URL` = the **part-1** PR (the base of the stack) for the §4.13 announce; carry the full ordered list as `$SPLIT_PR_URLS`.
  - Metrics/outcome: `gates.pr_size = { "status": "block", "details": { "lines": <L>, "files": <F>, "thresholds_breached": [...], "auto_split": { "parts": k, "branches": [...] } } }`; **`OUTCOME="ready_for_review"`** (k PRs open, none merged); append `pr_auto_split=k` to `--notes`. Do NOT set `BLOCKED`/`blocked-reason`.
  - **Merge-on-finish (§4.10.5) does NOT fire** — its fire conditions already exclude a `pr_size` BLOCK; never auto-merge a stack. §4.13 `Merged:` prints `no`.
- **`SPLIT-FAILED` (exit 3)** — fall back to the **pre-0.11 hard-halt path** (the §3.0 opt-out escalation): push the tip as a **draft** PR (`gh pr create --draft`, title `WIP:`), file follow-up split sub-issues, apply the `blocked` label, set `BLOCKED=true` / `OUTCOME="blocked"` / `--blocked-reason "pr_size block (auto-split failed: <reason>)"`, and tell the user. Reasons the wrapper reports: fewer than 2 parts possible (e.g. one file bigger than the cap), a construction step failed, or the partition self-check did not confirm exact groups / tip tree. Fail-safe: never open a partial or unverified stack.

After the stack (or the fallback draft) is created, continue to §4.7 (issue comment — list all stack PR URLs) and back to [`phase-4-finalize.md`](phase-4-finalize.md) §4.8 onward. Skip §4.2.5/§4.2.6 for the split path (CI-gate/auto-merge are single-PR features; the stack is reviewed and merged manually in order).

## 4.2.5 CI Gate — wait for green checks

**Skipped if `config.ci.required` is not explicitly set to `true`** (no auto-default — feature is opt-in). Most solo / local-only setups don't run cloud CI; gating on missing checks would just timeout. When skipped, §4.2.6 auto-merge is OFF the normal path — its precondition (the single source, below) requires this gate to have RUN and PASSED.

When configured, this gate independently re-proves build/test post-push — but it runs after commit/push/PR, so it never replaces the Phase 3.1 `build-verify` re-run (pre-commit hygiene on every path; the ONLY independent evidence on the default no-CI path — anti-patterns §19h).

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

> Distinct mode: [`phase-4-finalize.md`](phase-4-finalize.md) §4.10.5 **merge-on-finish** (the `+++`-form / `--merge` immediate end-of-run merge) is NOT this feature and does not use this section's precondition — it has its own fire conditions, defined only there. This section governs only the config/flag-armed merge-when-CI-green below; neither section cites the other as permission.

If `config.auto_merge.enabled` OR `--auto-merge` in `$ARGUMENTS` (and `--no-auto-merge` not present):

**Precondition — the single source of truth for when auto-merge may fire.** No other text defines this; [anti-patterns](anti-patterns.md)' auto-merge bullet and the README defer here:

> Auto-merge is allowed ONLY when `config.ci.required` is **explicitly `true`** AND this run's §4.2.5 gate produced a PASS.

`ci.required: false`, unset, and no `ci` block at all are ONE state — unverified. §4.2.5 was skipped, "CI is green" is not checkable, and no independent post-push evidence exists. Config alone (`auto_merge.enabled: true` + no `ci` block — the default solo/local setup) never pre-authorizes an unverified merge.

Unverified state + auto-merge requested → print the warning and require **explicit per-run confirmation**:

```
⚠ Auto-merge requested, but config.ci.required is not explicitly true — nothing will
  verify this PR post-push. Merging unverified is an automated hand grenade.
  Reply exactly "merge unverified" to proceed THIS run; anything else → await_review.
```

- User replies exactly `merge unverified` → proceed to the merge commands below; add `⚠ merged unverified (per-run user confirmation, no CI gate)` to the §4.7 issue comment and the [`phase-4-finalize.md`](phase-4-finalize.md) §4.13 announce.
- Any other reply, or no reply → **`await_review`**: print PR url, wait for manual merge. Not an error — the PR is open, the pipeline completes.

Precondition satisfied (§4.2.5 PASS this run, or per-run confirmation given):
- Verify PR isn't blocked by required reviews
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

Origin (audit #11): pre-fix, this section's guard read "never auto-merge if `ci.required: false`" — by its letter it missed the common UNSET default, its "verify CI is green (4.2.5 already passed)" was vacuous when 4.2.5 was skipped, and anti-patterns said "warns; user must explicitly accept" for the same state. Two texts, two rules — an orchestrator inclined to proceed cited whichever permitted it, and a PR auto-merged with zero verification. One rule now, defined here only.

## 4.7 Issue comment (M/H — REQUIRED if issue tracker)
Use `{Tracker.comment}` with body file:
```
✅ Done. PR: <url> · Migration: {TS} (or —) · Build: <list of ✓ checks> [+ if context_doc → "· Context updated: {context_doc.path} §N[, §M]"] [+ if ADR → "· ADR-{NNNN}"] [+ if auto-merge → "· Auto-merge enabled"] [+ if merged unverified per §4.2.6 confirmation → "· ⚠ merged unverified (per-run user confirmation, no CI gate)"]
```

Required content if context_doc updated: `Context updated: {context_doc.path} §N[, §M]`.

After this section, return to [`phase-4-finalize.md`](phase-4-finalize.md) §4.8 (worktree cleanup) and onward to §4.11/§4.13.
