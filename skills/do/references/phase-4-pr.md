# Phase 4 — PR, CI gate, auto-merge, issue comment (§4.2 / §4.2.5 / §4.2.6 / §4.7)

**Load this file ONLY on the PR path: Medium / High with a code-hosting remote.** Trivial and Low never open PRs ([SKILL.md](../SKILL.md) tier simplifications; [`phase-4-finalize.md`](phase-4-finalize.md) §4.3) — on a T/L run, do NOT read this file. Section numbers continue `phase-4-finalize.md`'s scheme: prose elsewhere that cites "§4.2.5" or "Phase 4.2" refers to the sections below.

Sequencing (owned by [`phase-4-finalize.md`](phase-4-finalize.md)): §4.0 branch-normalize and the §4.1.2 secret-scan-gated push run BEFORE anything here; §4.11 metrics + §4.13 announce run AFTER, back in the core file. Outputs to carry back: `$PR_URL`, `$CI_STATUS`, `$AUTO_MERGE_STATUS` (+ the `⚠ merged unverified` fragment when §4.2.6's per-run confirmation path fired) — the §4.13 announce and §4.11 `--ci-status`/`--auto-merge` flags consume them; on T/L runs they simply stay unset and the announce prints its defaults.

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
