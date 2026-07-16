# Phase 4 — Finalize

Tracker operations use `{Tracker.OP}` from [`trackers.md`](trackers.md). Branch / commit naming uses `config.naming.issue.{branch, ref_format}`.

On entering this phase, stamp the task clock (`phase_entered_at["4"]` — one-liner in [`phase-0-setup.md`](phase-0-setup.md) §Task clock) if you haven't already; §4.11 derives phase durations from the stamps and reads `--started-at` back from the same file.

> **Critical ordering**: Phase 4.0 (branch normalization) MUST run BEFORE 4.2 (PR creation). Final announce (4.13) is COUPLED to Phase 4.11 metrics emission via shared bash variables — you literally cannot emit the announce without first running the metrics-append command. See "Final announce" at the bottom of this file.

## 4.0 Branch normalization — UNCONDITIONAL, BEFORE any push or PR — via the `branch-normalize` wrapper

The very first step of Phase 4. **Runs before commit, push, or PR creation**, so the PR opens on the correct branch name from the start. The decision is **wrapper-owned** (`branch-normalize`): slug kebab-normalization (ASCII lowercased, hostile characters → `-`, Unicode letters preserved, 40-char cap), `config.naming` template substitution, `-v2..-v9` collision suffixes ([git-rules.md](git-rules.md) §Branch collisions), the rename itself, and old-remote-ref cleanup are all internal to it. Do NOT compute an `EXPECTED` name in spec bash and do NOT announce a branch name you didn't get from wrapper stdout — this step was inline bash through v0.8.x with a confirmed production violation (v0.3.1: "Complete. Branch: feat/i…" announced while the worktree still sat on the harness auto-name). See [anti-patterns §19j](anti-patterns.md).

```bash
# Canonical do-scripts resolver — identical line in every wrapper block; each
# block runs in a fresh shell, so re-resolve here (rationale: phase-0-setup.md Step 1).
DO_SCRIPTS="$(find -L ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT/skills"} "$HOME/.claude/skills" "$HOME/.claude/plugins/cache" "$HOME/.local/share/senior-by-default/skills" -maxdepth 7 -type f -name metrics-append -path '*/scripts/*' 2>/dev/null | head -1)"; DO_SCRIPTS="${DO_SCRIPTS%/metrics-append}"

# Optional flags go through an ARRAY, never `${VAR:+--flag "$VAR"}` — see §4.11's
# note: that idiom needs shell word-splitting, which bash does and **zsh does not**,
# collapsing flag+value into one argv token the wrapper rejects.
# --branch-template only when config.naming overrides the defaults
# (low: feat/{slug}; issue: feat/i{N}-{slug} — the wrapper knows both).
BRANCH_ARGS=()
add_opt() { [ -n "${2:-}" ] && BRANCH_ARGS+=("$1" "$2"); return 0; }
add_opt --issue-number    "${N:-}"
add_opt --branch-template "${BRANCH_TEMPLATE:-}"

if [ -x "$DO_SCRIPTS/branch-normalize" ]; then
  BRANCH_LINE="$("$DO_SCRIPTS/branch-normalize" -C "$WORKTREE_PATH" \
      --complexity "$COMPLEXITY" --slug "$SLUG" \
      ${BRANCH_ARGS[@]+"${BRANCH_ARGS[@]}"} 2>&1)" \
    || BRANCH_LINE="Phase 4.0: NORMALIZE FAILED — $BRANCH_LINE"
else
  # FAIL CLOSED — explicit token, never an empty variable.
  BRANCH_LINE="Phase 4.0: NORMALIZE SKIPPED — do-scripts resolver found no install (probed plugin root, ~/.claude/skills/*/scripts, plugin cache, ~/.local/share/senior-by-default)"
fi
echo "$BRANCH_LINE"
```

Dispatch on the wrapper's verdict line (the `head=<sha8>` — the repo's real HEAD at run time — is the §19j anti-fabrication tell; carry the line verbatim, never retype):

- `Phase 4.0: BRANCH OK name=<name> head=<sha8>` — already normalized; proceed.
- `Phase 4.0: BRANCH RENAMED <old>→<new> head=<sha8> old_remote=<…>` — renamed. Record `branch_rename: <old>→<new>` in the §4.11 `--notes` — the signal that upstream automation pre-spawned a worktree without following the worktree-setup spec. `old_remote=delete-failed(…)` → tell the user the stale remote ref needs manual cleanup; do not retry the delete yourself.
- `Phase 4.0: NORMALIZE FAILED — REJECT <reason>` / `NORMALIZE SKIPPED` → **fail closed**: do NOT proceed to 4.1/4.2 on an unnormalized branch. Collision cap (`-v9`) → ask the user; missing install → re-run install.sh / `/plugin install`, then re-run 4.0.

### Pre-spawned worktree is NOT an excuse

If you find yourself inside a worktree that was created by Claude Code's harness (`Agent(isolation: "worktree")`) with an auto-named branch like `claude/<adj>-<noun>-<hash>`, the rename is STILL UNCONDITIONAL — run the wrapper anyway. Do not rationalize "the worktree was pre-spawned, so I'll keep the auto-name" — the worktree path is fine to keep, but the BRANCH must follow `config.naming` so that downstream PR titles, commit `Ref:` lines, metrics entries, and tracker comments all cross-reference correctly via the `i{N}` token. The BRANCH RENAMED verdict + `--notes` record (above) is the diagnostic trail.

## 4.1 Commit
Final commit message:
- Subject per Conventional Commits (see [`git-rules.md`](git-rules.md))
- Body includes `Ref: {config.issue_tracker.repo}#{N}` if issue tracker configured (use `config.naming.issue.ref_format` for the formatted id)
- Footer: `Co-Authored-By: <current model from environment> <noreply@anthropic.com>` — **auto-detect from environment, never hardcode**

### 4.1.2 Push — gated on `secret-scan` (ONE bash block, push only on its exit 0)

The pre-push secret check is **wrapper-owned** (`secret-scan` — globs + content patterns from [`git-rules.md`](git-rules.md) §Secret guard). It scans the **full push range** `merge-base(origin/main, HEAD)..HEAD`, names + per-commit added content — NOT the staged diff: by 4.1 the earlier Phase 2 commits are already in branch history, so a secret committed (or committed-then-deleted) mid-implementation never appears in `--cached` yet every one of those blobs gets pushed. Do NOT eyeball the diff and decide "clean" yourself (anti-pattern [§19g](anti-patterns.md)) — this is the single irreversible skip in the pipeline: a pushed secret is revoke-and-rotate, not revert.

The push lives INSIDE the same block, dispatched on the wrapper's exit code — run as ONE Bash command (fresh-shell model: a scan run in a separate block proves nothing about the block that pushes):

```bash
# Canonical do-scripts resolver — identical line in every wrapper block; each
# block runs in a fresh shell, so re-resolve here (rationale: phase-0-setup.md Step 1).
DO_SCRIPTS="$(find -L ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT/skills"} "$HOME/.claude/skills" "$HOME/.claude/plugins/cache" "$HOME/.local/share/senior-by-default/skills" -maxdepth 7 -type f -name metrics-append -path '*/scripts/*' 2>/dev/null | head -1)"; DO_SCRIPTS="${DO_SCRIPTS%/metrics-append}"

if [ ! -x "$DO_SCRIPTS/secret-scan" ]; then
  # FAIL CLOSED — the gate cannot run; pushing unchecked deletes the only
  # irreversible-skip guard. Fix = re-run install.sh / /plugin install, re-run 4.1.2.
  SECRET_SCAN_OUT="Phase 4.1: GATE ERROR — secret-scan wrapper not found (do-scripts resolver found no install)"
  printf '%s\n' "$SECRET_SCAN_OUT" "PUSH WITHHELD — do not push until the wrapper resolves."
elif SECRET_SCAN_OUT="$("$DO_SCRIPTS/secret-scan" -C "$WORKTREE_PATH" 2>&1)"; then
  printf '%s\n' "$SECRET_SCAN_OUT"                    # SECRETS PASS + range tell
  # HEAD = the current branch, i.e. the §4.0-normalized name (fresh shell:
  # no $EXPECTED variable survives from 4.0; the branch itself is the carrier).
  git -C "$WORKTREE_PATH" push -u origin HEAD
else
  printf '%s\n' "$SECRET_SCAN_OUT"                    # SECRETS BLOCK + finding list, or REJECT
  echo "PUSH WITHHELD — secret-scan did not pass. NEVER push around this gate (separate block, other cwd, --no-verify)."
fi
```

Dispatch on the wrapper's first output line:
- `Phase 4.1: SECRETS PASS` (exit 0) → the push already ran in the same block. Record for §4.11/§4.13: `gates.secret_scan = { "status": "pass", "details": { "tell": "<the wrapper's verdict line, verbatim>" } }` — the range SHAs + counts in it are the §19g anti-fabrication tell; carry the line from real stdout, never retype from memory.
- `Phase 4.1: SECRETS BLOCK` (exit 3) → push withheld. **STOP**: alert the user with the finding list (paths + pattern names only — the wrapper never prints the secret text). Remove the secret from branch history or rotate it; do NOT proceed to 4.2. Metrics: `gates.secret_scan = { "status": "block", "details": { "tell": "<verdict line>" } }`, `OUTCOME="blocked"`, `--blocked-reason "secret_scan block"`.
- `REJECT …` (exit 1) / `GATE ERROR` → fail closed: no push happened. Fix the invocation / install and re-run 4.1.2; a REJECT is never a pass. If the task ends here: `gates.secret_scan = { "status": "fail", "details": { "reason": "<the REJECT/GATE ERROR line>" } }`.

> There is NO spec-copyable pass form for this gate — the verdict line with its range SHAs exists only in wrapper stdout. Proceeding to 4.2 / the §4.13 announce presupposes a real `SECRETS PASS` earlier in this transcript.

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

- User replies exactly `merge unverified` → proceed to the merge commands below; add `⚠ merged unverified (per-run user confirmation, no CI gate)` to the §4.7 issue comment and the §4.13 announce.
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
- Else if `config.issue_tracker` set → create new issue with label `tech-debt` (body starts with the line-1 execute callout, same as Phase 1 — see [`phase-1-issue.md`](phase-1-issue.md) §Execute callout)
- Else → write to `config.memory_path` (or `auto`-resolved memory path)

Skip if no items.

## 4.5 Feature docs
If you changed feature logic AND feature docs exist (project-specific path) → update them. Skip for cosmetic / refactor changes. Already covered by 3.0.6 if `config.public_docs_dir` set.

## 4.6 Context doc update — BLOCKING
**Only if `config.context_doc.required_for_finalize: true`.** Otherwise skip.

For all complexity levels: update `config.context_doc.path`. Required sections (use `config.context_doc.sections` mapping):

- **§{sections.current_state}** — bump "Last updated" to today's date. If migration → append it ({TS} prefix); a legacy "Next migration" counter, if present, is informational only — never allocate from it. If merged → move from Open Work → Recently Merged. Update "Last merged issue" / "Last PR".
- **§{sections.structure}** — add new module/page/route. Remove deleted.
- **<feature-section>** — update endpoints, invariants, types if changed.
- **§{sections.deployment}** — only if env / compose / webhook changed.
- **§{sections.constraints}** — add gotchas, remove obsolete ones.

### Delivery — three paths, strictly ordered

1. **Context doc lives in the SAME repo as the task** → commit `{context_doc.path}` on the task branch; the PR carries it. This is the only path inside the code repo — [git-rules.md](git-rules.md) "never commit to main" has NO exception here.

2. **Separate docs repo (multi-repo workspace), default** → short-lived branch + PR, same worktree discipline as any other repo:
   ```
   git -C {docs_repo} fetch origin --prune
   git -C {docs_repo} worktree add {docs_repo}/.claude/worktrees/docs-{ref_format} -b docs/{ref_format}-context origin/main
   # edit {context_doc.path} in the worktree
   git add {context_doc.path} && git commit -m "docs(agent-context): update after {ref_format} — {summary}"
   git push -u origin docs/{ref_format}-context
   # open the PR; merge per the docs repo's own rules (auto-merge if configured there)
   ```
   Suggest worktree removal after merge per §4.8 — single-file docs branches don't linger.

3. **Separate docs repo with explicit `config.context_doc.allow_main_push: true`** → direct push:
   ```
   cd {dir containing context_doc} && git pull origin main
   # edit
   git add {context_doc.path} && git commit -m "docs(agent-context): update after {ref_format} — {summary}" && git push origin main
   ```
   This is the **sole scoped exception** to "never commit to main": it applies only to a docs repo that is NOT the task's code repo, only to `{context_doc.path}`, and only under the explicit config opt-in. Missing opt-in, or context doc inside the code repo → paths 1/2. Pre-fix, this block said `git push origin main` unconditionally while git-rules said "never commit to main, no exceptions" — an orchestrator honoring either sentence broke the other (audit #19).

If Sonnet failed to update → Opus updates inline + notes in PR description: `Context updated by Opus: {sections}`.

## 4.7 Issue comment (M/H — REQUIRED if issue tracker)
Use `{Tracker.comment}` with body file:
```
✅ Done. PR: <url> · Migration: {TS} (or —) · Build: <list of ✓ checks> [+ if context_doc → "· Context updated: {context_doc.path} §N[, §M]"] [+ if ADR → "· ADR-{NNNN}"] [+ if auto-merge → "· Auto-merge enabled"] [+ if merged unverified per §4.2.6 confirmation → "· ⚠ merged unverified (per-run user confirmation, no CI gate)"]
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

**If `config.metrics.log_path` is set, this step is NOT optional.** Skipping it is an [anti-pattern](anti-patterns.md). Phase 4 cannot be considered complete until the JSONL entry is appended AND verified. The final announce (below) MUST end with a `Metrics:` line in one of the exactly three forms the §4.13 bash flow emits: `Metrics: <count> entries in <path> (pre=<n> gates=<n>)`, `Metrics: APPEND FAILED — <reason>`, or `Metrics: not configured (…)`. This is a CLOSED set — there is no hand-written skip form. A `Metrics: skipped — <reason>` line matches no bash path in this file; it marks the announce as composed by hand (anti-pattern §19a) and the Stop hook blocks it when enabled.

If the field is unset/null → silently skip (no log path = no metrics, no warning).

### Step 1: prepare path
```bash
LOG_PATH="<resolved log_path>"        # placeholders like {repo_slug} substituted by you
case "$LOG_PATH" in "~/"*) LOG_PATH="$HOME/${LOG_PATH#\~/}" ;; esac   # config paths are DATA — a leading ~ never
                                      # saw shell expansion; expand explicitly or this mkdir creates a literal
                                      # ./~ directory (audit #18c; metrics-append expands its --log the same way)
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

There is exactly one supported way to write to the metrics log: the `metrics-append` wrapper
in the installed skill's `scripts/` dir, located at runtime by the canonical do-scripts
resolver (`"$DO_SCRIPTS/metrics-append"` — the §4.13 block resolves it; never a hardcoded
`~/.claude/skills/do/...` literal, which exists only for the default-name symlink install —
plugin installs and renamed SKILL_NAMEs have no such path).
Direct `echo ... >> "$LOG_PATH"`, calling `python3 -c '...' >> "$LOG_PATH"`, or using
the `Write` tool against the log path are all an [anti-pattern](anti-patterns.md) — past
production runs proved sub-agents systematically compose free-form JSON when an in-doc template
is "suggested", producing 100+ distinct field names across a few dozen entries and emitting the
critical `self_review` calibration block in **0 of 37** observed entries. The wrapper's named-args
CLI removes that freedom: unknown flags reject, missing required flags reject, bad enums reject,
and the on-disk shape is guaranteed uniform across runs.

The wrapper enforces:
- Required fields present (`--ref`, `--complexity`, `--implementer`, `--outcome`,
  `--started-at`, `--ended-at`, `--files-changed`, `--lines-added`, `--lines-deleted`,
  `--sr-performed`, `--sr-claimed`)
- Enum validation on complexity / implementer / outcome / self-review fields, plus
  outcome↔blocked_reason consistency (`blocked` requires a reason; a reason with any
  other outcome REJECTs)
- JSON validity of `--gates-json` / `--phase-durations-json` payloads
- **Gate-vocabulary normalization** of `--gates-json` keys + statuses (see "Gate
  vocabulary" below) — known aliases renamed to canonical, unknown keys preserved+flagged
- **Calibration computation** — all three self-review calibration verdicts are computed
  INSIDE the wrapper from the raw inputs (see "Self-review calibration logic" below);
  hand-passed `--sr-calibration*` flags are optional cross-checks that REJECT on
  contradiction
- **Write integrity** (audit #18) — the append is serialized under a `<log>.lock`
  mkdir lock (concurrent /do runs on the shared per-repo log no longer race),
  a missing trailing newline on the log is repaired BEFORE appending (no fused
  entries), and success is verified by CONTENT (the exact entry present as a
  full line — `grep -qxF`); the pre/post line-count delta is informational only
  (a surprise delta flags a non-wrapper writer on stderr instead of
  false-failing a successful append into a duplicate-entry retry)
- Exit code 0 on success (stdout:
  `OK pre=N post=N+1 path=<log> gates=<C> renamed=<R> noncanon=<list|-> cal=<c>/<d>/<s>`
  — `cal=` echoes the wrapper-computed calibration verdicts), 1 on schema
  reject (stderr: `REJECT <reason>`), 2 on I/O failure (stderr: `IOFAIL <reason>`)

#### Gate vocabulary (controlled, OPEN set)

The `gates` object's keys are a **controlled vocabulary** — same data-quality lesson
as the `outcome` enum (v0.6.0 found 16 outcome variants; the May-24 audit found ~110
distinct gate keys for ~19 real gates, e.g. `test`/`tests`/`test_gate`/`go_test`,
`ui`/`ui_gate`/`visual_verify`, `dep_vuln`/`dep_vuln_go`/`dep_vuln_pnpm`). Uncontrolled,
every synonym splits a gate's stats across buckets and the gate-failure-rate metric is
noise. The `metrics-append` wrapper normalizes automatically — you do NOT compose the
final key names, the wrapper does:

**Canonical gate keys** (the names that survive into the JSONL):

| Key | Phase | Key | Phase |
|---|---|---|---|
| `pr_size` | 3.0 | `ui_gate` | 3.2 |
| `dep_vuln` | 3.0.5 | `i18n` | 3.3 |
| `public_docs` | 3.0.6 | `contract` | 3.4 |
| `build` / `lint` / `type_check` | 2 checklist / 3.1 verify | `diff_scan` | 3.5 (Low) |
| `test` | 3.1 | `specialist_audit` | 3.6 (High) |
| `secret_scan` | 4.1 pre-push | `opus_review` | 3.7 (M/H) |
| `migration_audit` | 3.6 migration | `codeowners` | 3.6 routing |
| `plan_size` | 2.0 | `stale_main` | 2.0.5 |
| `concurrent_edit` | 1 (post planned-files) | | |

Each value is `{ "status": "pass"|"warn"|"fail"|"block"|"skipped", ["fix_cycle": N,]
["details": {...}] }`. The wrapper coerces scalar values (`"pass"`, `true`) into the
`{status: ...}` shape and normalizes status aliases (`skip`/`n/a`/`n-a`/`na` → `skipped`;
`ok`/`clean`/`true` → `pass`). Pass whatever name is natural at capture time — common
aliases (`tests`, `i18n_gate`, `type-check`, `go_vet`, `dep_vuln_pnpm`, …) are renamed
for you. A **task-specific** check with no canonical home (e.g. `idempotency_cache_correct`)
is **preserved as-is** (not rejected) but counted in the `noncanon=` field of the OK line
so it's visible. Do NOT hand-rename your ad-hoc checks to a canonical name they don't
match — let the wrapper decide; a fabricated `Metrics:` line that claims canonical keys
the wrapper never emitted is an [anti-pattern](anti-patterns.md).

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

**Computing `$SR_SIZE_ASSESSMENT`**: the machine-readable `size_assessment:` value from the Phase 2.5 self-review block (`fits|exceeds|unknown`), verbatim — never inferred from prose. Self-review absent → omit the flag (wrapper defaults `n_a`). Do NOT compute `--sr-calibration*` values — the wrapper computes all three calibration verdicts from the raw inputs (see "Self-review calibration logic" below).

**Computing `$STARTED_AT` / `$ENDED_AT` / `$PHASE_DURATIONS_JSON`**: Phase 0 preflight already captured `STARTED_AT` into the task clock file ([`phase-0-setup.md`](phase-0-setup.md) §Task clock) — **read it back from disk; NEVER re-run `date` for it here**. A spec bash block runs in a fresh shell, so no variable from Phase 0 survives to this one; the clock file is the carrier. The wrapper hard-rejects `--ended-at < --started-at` (production audit: 36% of pre-fix entries had negative cycle times from back-computing started_at at the end). The §4.13 procedure below performs the read-back as its first lines:

- `$STARTED_AT` — `jq -r '.started_at'` from the clock file. Cross-check against the Phase 0 announce `Started:` line: a mismatch means a parallel same-CWD session overwrote the clock — prefer the announce value (it is the genuine echo of this task's capture). Clock file missing AND no announce line → the capture was skipped; that is a Phase 0 spec violation to note in `--notes`, not a license to back-compute.
- `$ENDED_AT` — now: `date -u +%Y-%m-%dT%H:%M:%SZ` at emit time. This is the ONLY timestamp legitimately generated in Phase 4.
- `$PHASE_DURATIONS_JSON` — derived from the clock's `phase_entered_at` stamps (duration of a phase = delta to the next stamp; last stamped phase ends at `$ENDED_AT`). Do NOT invent durations from memory; missing stamps → empty result → flag omitted (it's optional).

Canonical invocation (executed by the §4.13 announce block; do NOT run it standalone, the
announce coupling depends on capturing its stdout into `$METRICS_LINE`):

```bash
# $DO_SCRIPTS comes from the canonical do-scripts resolver (the §4.13 block runs it).
"$DO_SCRIPTS/metrics-append" \
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
  --sr-size-assessment "$SR_SIZE_ASSESSMENT" \                # raw Phase 2.5 size_assessment value (fits|exceeds|unknown; omit → n_a)
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

The shipped `metrics-report` CLI (`"$DO_SCRIPTS/metrics-report"`, same resolver as
`metrics-append`) scans logs for schema-invalid entries and surfaces them in a SCHEMA
BYPASS section, excluded from aggregates. So even if a sub-agent bypasses the wrapper,
the bypass shows up the next time anyone runs the report rather than silently polluting
the analysis. Don't rely on this — it's a tripwire, not a fix. (Operators may
additionally wire it into a cron/launchd daily report; that wiring is optional and
outside the skill.)

Analyze accumulated telemetry any time: `"$DO_SCRIPTS/metrics-report"` — per-tier
counts, gate pass/fail rates, rebump rate, calibration accuracy, top failing gates;
`--since <date>`, `--repo <slug>`, `--json`. Read-only; NOT a phase step — never run it
as part of the pipeline, it's the human feedback loop.

### Self-review calibration logic — COMPUTED INSIDE `metrics-append`, not by you

The three calibration verdicts (`calibration`, `calibration_defect`, `calibration_size`)
are a pure function of data the wrapper already receives: `--sr-performed`,
`--sr-claimed`, the normalized `--gates-json`, `--specialist-iterations-json` blockers,
`--sr-size-assessment` (the raw Phase 2.5 `size_assessment:` value), and
`--complexity-rebumped-from`. **The wrapper computes them** — do NOT compute and pass
them yourself. Pre-fix they were orchestrator-computed with enum-only validation: a
trust-based verdict on the single highest-signal data point of the telemetry loop
(audit finding #14c). The `--sr-calibration*` flags still exist as optional
cross-checks — if passed, a value contradicting the wrapper's computation REJECTs the
entry (hand-math drift becomes a visible bug); omitted is the normal path. The OK line
echoes the computed verdicts (`cal=<c>/<d>/<s>`).

Your job is only to deliver the RAW inputs faithfully: the gates as Phase 3 recorded
them, `--sr-claimed` from the Phase 2.5 `claimed_status:` line, and
`--sr-size-assessment` from the Phase 2.5 `size_assessment:` line.

**Reference — the function the wrapper implements** (documentation of wrapper
internals, not an instruction to hand-execute):

```
phase3_failed_gates = [g for g in gates if gates[g].status in ("fail", "block")]
sonnet_claimed = sonnet_self_review.claimed_status        # "ready" | "deferred" | "uncertain"

# --- Legacy combined calibration (`calibration`; unchanged semantics) ---
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

(`miscalibrated` remains caller-provided free text via `--sr-miscalibrated-json` — it
is descriptive, not a verdict.)

**Why split** (production audit, 254 entries): of 44 `false_positive` entries, **17 (39%)
fired ONLY `pr_size=warn`** — Sonnet's code was fine, it just under-predicted diff size.
Counting those as "self-review missed something" inflates the FP rate and conflates two
different failures: *missing a real code defect* vs *not predicting diff size*. The split
records each separately so future audits read the right signal.

```
# A "real code defect" = any NON-pr_size gate failing/blocking, OR a specialist blocker.
specialist_blocked = any(c.blockers for c in specialist_iterations)
defect_found = [g for g in phase3_failed_gates if g != "pr_size"] or specialist_blocked

# --- calibration_defect: code-correctness dimension ---
if not self_review.performed:                       calibration_defect = "skipped"
elif sonnet_claimed == "ready" and defect_found:    calibration_defect = "false_positive"
elif sonnet_claimed == "ready":                     calibration_defect = "accurate"
elif sonnet_claimed in ("deferred","uncertain") and not defect_found:
                                                    calibration_defect = "false_negative"
else:                                               calibration_defect = "accurate"

# --- calibration_size: diff-size-prediction dimension ---
pr_size_fired      = gates.get("pr_size", {}).get("status") in ("warn", "block")
# Sonnet "flagged size" = --sr-size-assessment == "exceeds" (the Phase 2.5 machine-readable
# line — don't guess from prose), OR a Phase 2.0 plan-size rebump happened this task
# (--complexity-rebumped-from is set).
sonnet_flagged_size = (sr_size_assessment == "exceeds") \
                      or (COMPLEXITY_REBUMPED_FROM != "")

if not self_review.performed:                       calibration_size = "skipped"
elif "pr_size" not in gates:                        calibration_size = "n_a"   # gate didn't run
elif sonnet_flagged_size and pr_size_fired:         calibration_size = "accurate"
elif (not sonnet_flagged_size) and pr_size_fired:   calibration_size = "false_positive"  # under-predicted
elif sonnet_flagged_size and (not pr_size_fired):   calibration_size = "false_negative"  # over-predicted
else:                                               calibration_size = "accurate"
```

Why this matters downstream: `calibration_defect` is the **highest-signal data point** for
skill iteration (the de-confounded FP rate: defect-FP trending up → self-review prompt too
lax; defect-FN up → Sonnet over-flagging), while `calibration_size` tells whether Phase 0/2.0
routing predicts diff size well (size-FP up → routing under-estimates; the P0 PR-size ceiling
+ plan-size-check should drive it down). **Confounder**: do not compare FP rates across the
≈2026-05-17 specialist-plugin-install boundary — pre-install cohorts had zero specialist
review, so mechanically fewer findings. Segment any trend on that date.

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
# Task clock read-back — Phase 0 preflight wrote it (phase-0-setup.md §Task clock).
# Fresh shell: no variable survives from Phase 0, so STARTED_AT comes from disk,
# never from re-computation. Same CWD-anchored derivation as the capture.
CLOCK_ANCHOR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CLOCK_FILE="$HOME/.claude/do/state/$(printf '%s' "$CLOCK_ANCHOR" | sed -E 's/[^a-zA-Z0-9]+/-/g; s/^-+//; s/-+$//').task-clock.json"
STARTED_AT="$(jq -r '.started_at // empty' "$CLOCK_FILE" 2>/dev/null)"
[ -n "$STARTED_AT" ] || STARTED_AT="<exact value from the Phase 0 announce 'Started:' line — never date(1) here>"
ENDED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# phase_durations_seconds from the per-phase stamps: delta to the next stamp;
# the last stamped phase ends at ENDED_AT. No/partial stamps → empty → flag omitted.
PHASE_DURATIONS_JSON="$(jq -c --arg end "$ENDED_AT" '
  [.phase_entered_at | to_entries[] | {k: .key, t: (.value | fromdateiso8601)}]
  | sort_by(.t) | . as $e
  | [range(0; length)
     | {key: $e[.].k,
        value: ((if . + 1 < ($e | length) then $e[. + 1].t else ($end | fromdateiso8601) end) - $e[.].t)}]
  | from_entries' "$CLOCK_FILE" 2>/dev/null)" || PHASE_DURATIONS_JSON=""

# Canonical do-scripts resolver — identical line in every wrapper block; each
# block runs in a fresh shell, so re-resolve here (rationale: phase-0-setup.md Step 1).
DO_SCRIPTS="$(find -L ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT/skills"} "$HOME/.claude/skills" "$HOME/.claude/plugins/cache" "$HOME/.local/share/senior-by-default/skills" -maxdepth 7 -type f -name metrics-append -path '*/scripts/*' 2>/dev/null | head -1)"; DO_SCRIPTS="${DO_SCRIPTS%/metrics-append}"

# Phase 4.11 emit — invoke the wrapper. METRICS_LINE is set ONLY by capturing its result.
# The wrapper does schema validation, lock-serialized append, and content-based post-write
# verify internally. We never compose JSON here; we never `>>` to the log file here.
# Optional flags go through an ARRAY. Do NOT use `${VAR:+--flag "$VAR"}` here: that
# idiom depends on the shell word-splitting the expansion, which **bash does and zsh
# does NOT**. Under zsh each one collapses into a SINGLE argv token
# (`--notes some long text`), and metrics-append rejects it — the announce then reads
# `Metrics: APPEND FAILED — REJECT unknown arg: --notes …`. add_opt behaves identically
# under bash and zsh, drops unset/empty values, and keeps multi-word values (--notes,
# --title, the JSON payloads) intact. Long JSON is safest passed via a file
# (`--gates-json "$(jq -c . /tmp/gates.json)"`): a shell variable holding an
# em-dash-laden JSON blob has bitten this flow before.
METRICS_ARGS=()
add_opt() { [ -n "${2:-}" ] && METRICS_ARGS+=("$1" "$2"); return 0; }
add_opt --complexity-rebumped-from "${COMPLEXITY_REBUMPED_FROM:-}"
add_opt --orchestrator             "${ORCHESTRATOR:-}"
add_opt --sr-size-assessment       "${SR_SIZE_ASSESSMENT:-}"
add_opt --title                    "${TITLE:-}"
add_opt --scope                    "${SCOPE:-}"
add_opt --notes                    "${NOTES:-}"
add_opt --gates-json               "${GATES_JSON:-}"
add_opt --phase-durations-json     "${PHASE_DURATIONS_JSON:-}"
add_opt --review-cycles            "${REVIEW_CYCLES:-}"
add_opt --ci-status                "${CI_STATUS:-}"
add_opt --auto-merge               "${AUTO_MERGE_FLAG:-}"
add_opt --blocked-reason           "${BLOCKED_REASON:-}"

if [ -n "$LOG_PATH" ] && [ ! -x "$DO_SCRIPTS/metrics-append" ]; then
  # FAIL CLOSED — never hand-append to the log. APPEND FAILED is a legal
  # terminal form (the Stop hook does not re-block it) and names the fix.
  METRICS_LINE="Metrics: APPEND FAILED — metrics-append wrapper not found (do-scripts resolver found no install)"
elif [ -n "$LOG_PATH" ]; then
  if METRICS_RESULT=$("$DO_SCRIPTS/metrics-append" \
        --log              "$LOG_PATH" \
        --ref              "$REF" \
        --complexity       "$COMPLEXITY" \
        --implementer      "$IMPLEMENTER" \
        --outcome          "$OUTCOME" \
        --started-at       "$STARTED_AT" \
        --ended-at         "$ENDED_AT" \
        --files-changed    "$FILES_CHANGED" \
        --lines-added      "$LINES_ADDED" \
        --lines-deleted    "$LINES_DELETED" \
        --sr-performed     "$SR_PERFORMED" \
        --sr-claimed       "$SR_CLAIMED_STATUS" \
        ${METRICS_ARGS[@]+"${METRICS_ARGS[@]}"} \
        2>&1); then
    # stdout shape: "OK pre=N post=N+1 path=<log> gates=<C> renamed=<R> noncanon=<list|->"
    # (parse anchored on the ^OK line — $METRICS_RESULT holds 2>&1, so a stderr
    # "NOTE gate-normalize: …" line may precede it)
    POST_COUNT=$(echo "$METRICS_RESULT"  | sed -n 's/^OK pre=[0-9]* post=\([0-9]*\) .*/\1/p')
    PRE_COUNT=$(echo "$METRICS_RESULT"   | sed -n 's/^OK pre=\([0-9]*\) post=.*/\1/p')
    GATES_COUNT=$(echo "$METRICS_RESULT" | sed -n 's/^OK .* gates=\([0-9]*\) renamed=.*/\1/p')
    # The (pre= gates=) suffix carries part of the wrapper's anti-fabrication tell
    # into the user-visible line: pre+1 must equal the entry count and gates= must
    # match the appended entry — hand-composed lines with an inconsistent (or
    # guessed) tell are visible bugs, and the Stop hook cross-checks pre+1 == count.
    # LOCKSTEP: this exact format is parsed by hooks/do-metrics-stop-gate.sh —
    # change the format and the hook's parsers together, never one side alone.
    METRICS_LINE="Metrics: $POST_COUNT entries in $LOG_PATH (pre=$PRE_COUNT gates=$GATES_COUNT)"
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

# Branch name — LIVE read-back from git, never a remembered/composed value
# (fresh shell: no variable survives from §4.0; the branch itself is the
# carrier). MUST equal the name in the §4.0 $BRANCH_LINE verdict — a mismatch
# means the rename never happened or was reverted (the v0.3.1 violation, §19j):
# STOP and re-run 4.0 before announcing.
BRANCH_NAME="$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD)"

# Models line — orchestrator from frontmatter (opus), implementer from Phase 0 complexity routing,
# specialists from Phase 2 plan-review / Phase 3.6 audit roster (or "none")
MODELS_LINE="Models: orchestrator=${ORCHESTRATOR_MODEL:-opus}, implementer=${IMPLEMENTER_MODEL:-sonnet}, specialists=[${SPECIALISTS_LIST:-none}]"

cat <<EOF
Complete. Branch: $BRANCH_NAME. PR: ${PR_URL:--}. CI: ${CI_STATUS:-skipped}. Auto-merge: ${AUTO_MERGE_STATUS:-off}.
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

3. **External wrapper with named-args CLI** (current) — the wrapper is the only path to a valid append. Unknown flags reject, missing required flags reject, bad enums reject. Sub-agent cannot invent a new shape without making the announce print `Metrics: APPEND FAILED — REJECT <reason>`, which is visible. Content-based append verification lives inside the wrapper too (the exact entry must be present as a full line after the lock-serialized write), so a `>>` that returns exit 0 without actually writing (disk full) is still caught.

The wrapper file (`skills/do/scripts/metrics-append`) lives in the skill and ships with the install. The §4.13 bash block above invokes it and captures stdout into `$METRICS_LINE`. If `config.metrics.log_path` is unset, the wrapper isn't called and METRICS_LINE = "not configured" — announce still works, only the file write is skipped.

### What "broke the procedure" looks like

- Final assistant message ends with PR summary, no `Metrics:` line at the very end → you skipped the bash procedure
- `Metrics:` line says `APPEND FAILED — REJECT <reason>` → the wrapper rejected your input. The reason is explicit (missing required arg, bad enum, malformed JSON payload, calibration contradiction). Fix the offending value and re-run the emit. Most common: forgot `--sr-performed/--sr-claimed` from Phase 2.5. A calibration-contradiction REJECT means your hand-passed `--sr-calibration*` value disagrees with the wrapper's computation — drop the flag (the wrapper computes the verdicts), never adjust inputs to force yours through.
- `Metrics:` line says `APPEND FAILED — IOFAIL <reason>` → file write or count-delta check failed. Diagnose disk/lock/permission.
- `Metrics:` line is any OTHER form — `Metrics: skipped — <reason>`, a count without the `(pre=… gates=…)` tell, prose — → no bash path above emits it; you composed it by hand. The Stop hook (when enabled) blocks unrecognized forms outright (the legal set is CLOSED) and cross-checks recognized ones: tell consistency (`pre`+1 = count) plus log freshness (last entry's ref in the announce, or mtime ≤ 30 min). A tell-less count is tolerated by the hook only for pre-tell installs — produced from THIS spec it means the flow wasn't run.
- Announce uses different format than above (free prose) → you composed text instead of running the bash flow
- Log file gained an entry but `Metrics:` line in announce didn't reference it (or shape doesn't match the wrapper output) → you bypassed the wrapper and wrote directly. The shipped `metrics-report` CLI surfaces the bypass in its SCHEMA BYPASS section on the next run; don't do this.

For the spawned-agent execution model (agent runs everything start-to-finish and returns to a parent), this matters extra: the agent's final message is the only thing the parent sees. If diagnostic ends up there, parent flags it; if announce is plain prose, parent thinks success.

**Applies whether you are the spawned agent doing everything yourself, or a parent orchestrator** — there's no "the other one" to defer to; if you're reading this, you are the executor.

Before sending the announcement, scan [`anti-patterns.md`](anti-patterns.md) — verify nothing applies.
