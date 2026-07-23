# Changelog

All notable changes to this skill will be documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) loosely; versioning follows [SemVer](https://semver.org/).

## [Unreleased]

### Changed — decide the tracker-`none` Phase 1 skip in SKILL.md, don't load `phase-1-issue.md` to find it (issue #2)

On M/H with the default local-only config (`issue_tracker.type: none`), `phase-1-issue.md` (17.2 KB ≈ 4.3k tokens) was read **only to execute its own first line** — "Skip entirely if … `type == none`". The skip decision now lives in [`SKILL.md`](skills/do/SKILL.md) (which the orchestrator has already read): before the Phase 1 file is opened, it checks the tracker and, on missing/`none`, skips with the exact one-line announce (plain + degraded forms preserved verbatim, incl. the audit-#13 reason repetition) — `phase-1-issue.md` loads **only** when a tracker is configured (`type` set and ≠ `none`), the sole case that actually creates an issue. The none-path downstream semantics (no `Closes #N`, no `Ref:`, no issue comment) are stated inline so `trackers.md` isn't needed either. Behavior-preserving: the concurrent-edit check sits below the skip rule inside `phase-1-issue.md`, so tracker-`none` runs already skipped it. `phase-1-issue.md` keeps its skip paragraph for direct readers with a pointer to the new decision site.

### Added — token-usage Stop hook: the `tokens` field is finally fillable (issue #1)

v0.10.0 added `metrics-append --tokens-in/--tokens-out` so the skill could compute its own ROI. A 2026-07-23 re-audit found **0 of 27** post-v0.10.0 entries ever carried a `tokens` object — and diagnosed it as **structural, not neglect**: no in-session actor can read its own usage (`/cost` is TUI-only; a sub-agent can't observe its own usage; a headless usage block lands only after the session ends). The one actor the runtime hands harness-recorded usage is a **hook** — a Stop hook receives `transcript_path`, and the transcript's assistant records carry `message.usage`.

New opt-in Stop hook [`do-tokens-stop-amend.sh`](skills/do/hooks/do-tokens-stop-amend.sh) closes the loop: after a `/do` finalize turn it sums the transcript's harness-recorded usage (`in = input + cache_creation + cache_read`, `out = output`) within the entry's `[started_at − 120s, ended_at + 900s]` window and back-fills the run's telemetry via a new `metrics-append --amend-tokens` mode. Design points: **amend, not append** (adds only an absent `tokens` key, under the same log lock, verified to change nothing else, REJECTs a second amend → idempotent re-fires); **ref-match, not last-line** (targets the entry whose `.ref` is named in the announce, so concurrent same-log sessions don't cross-fill); **never blocks** (unlike the metrics *gate*, it emits no decision — telemetry enrichment must not wedge a Stop); **all-zero → no write** (absence stays honest). Registered in [`settings.with-hooks.json`](skills/do/hooks/settings.with-hooks.json) as a second `Stop` hook, merged by `install.sh` and stripped by `uninstall.sh` alongside the other four; self-scoped exactly like `do-metrics-stop-gate.sh`, so global registration is safe. Every summed figure is harness-measured, so the estimate ban holds; the manual `--tokens-*` flags stay legal for an operator with a genuine readout.

New end-to-end suite [`tests/tokens-stop-amend.test.sh`](tests/tokens-stop-amend.test.sh) — 23 assertions on synthetic logs + transcripts: wrapper happy path, refuse-overwrite, one-flag-alone, last-ref-wins, estimate-ban rejects, and the hook summing real transcript usage into the ref-matched entry, idempotent re-fire, self-scope no-ops (non-finalize + spec-quoting turns), concurrent-session ref selection, never-blocks. Docs synced in lockstep: [`hooks.md`](skills/do/references/hooks.md) (new hook section + count fixes), [`phase-4-finalize.md`](skills/do/references/phase-4-finalize.md) §4.11 (names the hook as the sanctioned source), [`telemetry-internals.md`](skills/do/references/telemetry-internals.md) (rationale: why the flags stayed empty, window/cache/idempotence semantics), and the README hook roster + TOKENS section. `metrics-report` needs no change — it already reads `.tokens.in/.tokens.out`; verified it renders amended entries.

## [0.11.1] — 2026-07-23

### Fixed — `branch-normalize` old-remote cleanup could delete the default branch (`origin/main`)

Phase 4.0's post-rename remote cleanup keyed its `git push --delete` off the old branch's `@{upstream}`. A worktree branch created with `git worktree add -b <name> origin/main` — the exact shape the Claude Code harness pre-spawns — has `upstream = origin/main`, so on a rename the cleanup ran `git push origin --delete main`, **deleting the repository's default branch**. Only branch protection (or a bare remote refusing to delete its own current branch) prevented data loss in the wild.

The cleanup now targets ONLY the remote ref matching the **old local branch name** (`$ACTUAL`), and only when (a) that ref was actually pushed and (b) it is not the default / `main` / `master` branch. A hard guard short-circuits with a new verdict value `old_remote=skipped(protected:<branch>)` when the old name is protected; `@{upstream}` is now consulted solely to pick the remote *name*, never the branch to delete. A pre-spawned worktree that never pushed its auto-name reports `old_remote=none` and leaves `origin/main` untouched; a genuinely stale pushed feature branch is still cleaned up (`deleted(<remote>/<old>)`), and `--no-remote-delete` still opts out entirely.

New regression test [`tests/branch-normalize-remote-guard.test.sh`](tests/branch-normalize-remote-guard.test.sh) builds synthetic bare origins + clones and asserts all four paths (worktree-tracking-main → no delete; current-branch-is-main → guarded; non-default pushed branch → still cleaned; opt-out) — green on both macOS/BSD and GNU/Linux. Docs synced in lockstep: the `branch-normalize` header verdict grammar, [phase-4-finalize.md](skills/do/references/phase-4-finalize.md) §4.0 dispatch (the `old_remote` value list + `skipped(protected:…)` guidance), and [anti-patterns.md](skills/do/references/anti-patterns.md) §19j.

## [0.11.0] — 2026-07-23

### Added — auto-split: a Phase 3.0 PR-size BLOCK now splits into a stack of sub-cap PRs instead of halting

Before this release, an over-block-cap change (default >2000 lines / >50 files) was a hard halt: draft PR + `blocked` label, and the user had to split it into follow-up issues by hand. Now the default response is to **split automatically**. On a BLOCK, Phase 3 still reviews the full change as one unit (all gates, specialists, Opus review run on the complete diff), and then new [phase-4-pr.md §4.2.1](skills/do/references/phase-4-pr.md) partitions **delivery** into a stack of individually-reviewable PRs — each under the WARN caps (≈800 lines), reviewed once as a unit, merged in order. The run ends `ready_for_review` with *k* open PRs, not `blocked`. Opt out with `config.pr_size.auto_split: false` or `--no-split` (reverts to the pre-0.11 draft-PR + `blocked` hard halt).

New wrapper [`pr-split`](skills/do/scripts/pr-split) owns the split — the tenth tier-2 enforcement wrapper, same anti-fabrication discipline as `pr-size-check` / `plan-size-check` (the orchestrator cannot hand-roll a split):
- **Partition** — next-fit bin-pack of the changed files (in path order, for directory cohesion) into ordered groups, each ≤ target churn/files. A lone file bigger than the cap is its own part (a file can't be hunk-split across PRs) — reported, never silently merged.
- **Stacked, not independent** — the only auto-generatable split that is guaranteed build-coherent: part 1 branches off the base's *merge-base* with the tip (three-dot PR semantics, so a `main` that advanced mid-task can't leak unrelated commits in as phantom deletions), part *i* off part *i-1*, and the **last part's head IS the reviewed tip branch** (already pushed — no orphan branch, keeps its `feat/iN-slug` name). Each PR's diff against its base is one sub-cap group; the stack tip is byte-identical to the reviewed change; merged in order, `main` ends exactly at the reviewed tip. GitHub auto-retargets a child PR's base to the grandparent when the parent merges, so the stack collapses cleanly.
- **Hard self-check** — every built part's diff-against-base must equal exactly its file-group, and `base_{k-1}...tip` must equal exactly the last group (proving the union is complete and the tip is a valid stack head). Any mismatch, or fewer than 2 parts possible, or a construction failure → `SPLIT-FAILED` (exit 3), the wrapper touches nothing further, and §4.2.1 **falls back to the pre-0.11 draft-PR + `blocked` path**. Fail-safe: never open a partial or unverified stack.

The PreToolUse PR-size hook needs no split-awareness — each stacked part's per-part diff (base = the previous part branch) is sub-cap, so those non-draft creations pass its RC=0 arm naturally; the deny only ever fires on a genuine single over-block PR, which auto-split never produces. This is **not** downgrading BLOCK to `warn` (anti-patterns §19f/§21): the over-block change still never ships as one PR — it ships as *k* sub-cap PRs. `gates.pr_size.status` stays `"block"` (with `details.auto_split.{parts, branches}`) so telemetry stays honest; `OUTCOME` is `ready_for_review`; merge-on-finish (§4.10.5) still excludes any `pr_size` BLOCK — a stack is merged manually in order, never one part at a time.

Surfaces updated in the same release: `config.pr_size.auto_split` in [config.schema.json](skills/do/references/config.schema.json) + [config-schema.md](skills/do/references/config-schema.md); `--no-split`/`--split` in [SKILL.md](skills/do/SKILL.md); the §3.0 BLOCK arm + "block is not advisory" note in [phase-3-review.md](skills/do/references/phase-3-review.md); §4.2.1 delivery + §4.13 announce `Split:` line + §4.10.5 exclusion in the phase-4 files; the `pr-size-check` BLOCK message/docs, the `do-pr-size-pretooluse.sh` deny/context strings, [hooks.md](skills/do/references/hooks.md), [anti-patterns.md](skills/do/references/anti-patterns.md) §19f/§21, and the README PR-size row + hook + wrapper roster. `pr-split` verified against synthetic repos: multi-part packing by lines and by file count, multi-commit tips, adds/modifies/deletes, spaces + binary files, divergent-main merge-base correctness, single-file/too-small → SPLIT-FAILED, idempotent re-runs — in every success case merging the stack reproduces the original tip tree byte-for-byte.

## [0.10.1] — 2026-07-17

### Added — merge-on-finish: `+++` invocations merge the gated branch and clean the worktree; `nomerge` opts out

The two invocation forms now differ at the finish line. A message starting `+++` sets `merge_on_finish = true`: after a clean Phase 3 APPROVE, new [phase-4 §4.10.5](skills/do/references/phase-4-finalize.md) merges the branch — `gh pr merge --<config.auto_merge.method, default squash> --delete-branch` on M/H; on T/L (no PR exists by design) a local merge into `main` (`pull --ff-only`, then ff-merge, else a single merge commit, push) — and then removes the worktree and local branch. `+++ nomerge task` / `--no-merge` keeps the current await-review behavior; plain `/do` still defaults to it, `/do --merge` opts in; an explicit flag always beats the form default. The orchestrator detects the form from the literal user message (the `+++` prefix is visible to it), so no trigger-block magic is required — but `install.sh`'s CLAUDE.md block and the live install's block were updated to state the semantic difference instead of claiming the forms are "equivalent".

Guardrails, stated once (§4.10.5 only — deliberately NOT woven into §4.2.6, to avoid recreating the audit-#11 "two texts, two rules" class; the anti-patterns auto-merge bullet and §4.2.6 each carry a one-line distinction pointer):
- Never fires on `blocked`/escalated/draft outcomes or a withheld push; a red or timed-out `ci.required` gate always wins.
- T/L local path requires the main checkout on `main` and porcelain-clean; merge conflicts are abort-and-hand-back (branch stays pushed for manual review, no cleanup) — never resolved on `main`.
- Branch-protection refusal on M/H → `await_review` fallback; never retried with `--admin`/bypass flags.
- "Never commit to main" gains its second scoped exception in [git-rules.md](skills/do/references/git-rules.md): merging THIS run's gated branch under an explicit merge-on-finish invocation — never raw implementation commits.

Plumbing: §4.10.5 stamps `merge_status`/`merged_branch` into the task-clock file (the established fresh-shell carrier), §4.13 reads them back — the announce's `Complete.` line gains a `Merged:` token (Stop-hook parsers unaffected: the scoping prefix and the closed `Metrics:` forms are unchanged) and the branch-name live read-back gets its sole legitimate fallback for the merged-and-cleaned case. §4.11 outcome logic records `merged` for completed merge-on-finish runs (T/L included) with `merge_on_finish` in `--notes`, keeping the path distinguishable from §4.2.6 auto-merge in telemetry (`auto_merge` stays `false`). §4.8 worktree-cleanup advisory notes the executed path; §4.3's "merge when ready" tell is skipped when the merge replaces it.

## [0.10.0] — 2026-07-17

Telemetry-driven diet release. Input: a maximum-thoroughness re-audit of 227 production runs (miro-rooms-rentals) cross-validated against 109 runs on a second repo (lea) — every number below recomputed from the raw JSONL, not taken from the original audit report (which the re-check corrected in several places). The release cuts measured dead weight, fixes the one gate the data proved backwards, and gives the telemetry loop the cost axis it was missing. Deliberately NOT done, against the original audit's advice: removing review from Low (the tier gradient did not replicate on the second repo — L out-fired M there), removing `database-architect` from `backend_audit` (it was never in that preset; the audit read a placeholder doc), dropping `opus_review` as "duplicative" (specialists are High-only; §3.7 is the ONLY review gate Medium has), and hard-rejecting unknown gate names (the open set is a documented design decision).

### Changed — Phase 4 split: PR/CI/auto-merge path extracted to `phase-4-pr.md`; telemetry rationale to `telemetry-internals.md`

Measured: `ci_status` was `skipped`/absent in 227 of 227 runs, `auto_merge` fired 0 times, yet every run — including 4 Trivial and 44 Low — loaded the 50 KB `phase-4-finalize.md` whose PR/CI/auto-merge/issue-comment sections they can never execute (T/L have no PR path, and the file had no early exit: "Trivial" appeared 0 times, §4.3 Low sat *after* all the PR/CI content). §4.2 / §4.2.5 / §4.2.6 / §4.7 now live in [`phase-4-pr.md`](skills/do/references/phase-4-pr.md), loaded ONLY on M/H with a code-hosting remote; section numbers are preserved so every external "§4.2.6" citation stays valid, and the auto-merge precondition remains single-sourced (its ONE definition just moved files — anti-patterns, config-schema, README pointers updated). Design rationale, calibration pseudocode (explicitly "wrapper internals, not an instruction"), the three-layer enforcement history, and the gate-vocabulary war stories moved to [`telemetry-internals.md`](skills/do/references/telemetry-internals.md) — consulted when *changing* the telemetry system, never loaded at runtime. Core file: 51 KB → 41 KB for every run; T/L additionally skip the 7 KB PR file entirely. The §4.13 announce/metrics coupling (and its Stop-hook LOCKSTEP) stays intact in the core file — `$CI_STATUS`/`$AUTO_MERGE_FLAG` simply stay unset on T/L and default to `skipped`/`false` exactly as before.

### Changed — complete Low review path extracted to `phase-3-low.md` (same rigor, ~78% less context)

Low runs loaded the 23 KB `phase-3-review.md` to execute one section (§3.5). The full Low path — §3.1 `build-verify` re-run (Low is NOT exempt), dep-vuln scan, the 11-item Opus diff-scan checklist, one fix cycle, metrics keys, announce — now lives in the self-contained [`phase-3-low.md`](skills/do/references/phase-3-low.md) (~5 KB); phase-3-review.md §3.5 is a switch-here pointer. **Review semantics are byte-equivalent** — this is the behavior-neutral version of the original audit's "no plan, just do it for L" proposal, which was rejected on evidence: on the primary repo L gates fired in only 1/44 runs (2.3%), but on the second repo L fired in 2/17 (11.8%) — MORE than M (10.1%). Single-repo data doesn't justify removing a guardrail; shrinking its context cost needs no justification.

### Fixed — concurrent-edit gate warns on in-flight work, not merged history (0 true positives in 13 checks)

The gate's premise was backwards: it warned when planned files had *merged* commits in the last `lookback_days`, but a commit already in `origin/main` cannot conflict — the worktree branches from it. What conflicts is work that hasn't landed. Production score of the old heuristic: 13 recorded checks, 3 warns, **zero true positives**, and both annotated warns refuted themselves ("all prior edits landed in main, no in-flight branches" — recorded as a warn anyway). The primary signal is now unmerged remote branches (`git branch -r --no-merged origin/main`) and other live worktrees touching planned files → WARN with branch+author+SHA; merged-history activity within the lookback demoted to an INFO line in Implementation Hints (build-awareness, not a conflict). Same config shape (`enabled`, `lookback_days` — now scoping only the INFO query), still warn-only, zsh-safe array pathspec from v0.9.1 preserved. `config-schema.md` updated to match.

### Added — token accounting: `metrics-append --tokens-in/--tokens-out` + §4.11 wiring

The re-audit's sharpest measurement finding: across all 369 telemetry entries in every log, **zero carried any cost field** — the skill logged durations, gates, and diff sizes but structurally could not compute its own ROI (every cost claim in every audit was chars/4 guesswork). Two optional non-negative-int flags now record a top-level `tokens: {in, out}` object (only provided keys; both absent = no key, absent-not-null). Validation mirrors the other int flags (REJECT on non-numeric); the schema gate accepts the optional field; the §4.13 announce block passes them via `add_opt` like every optional flag. Hard rule, stated at every surface (usage header, §4.11, telemetry-internals): populate ONLY from harness-reported usage, NEVER estimate — a guessed number poisons ROI math precisely because it's indistinguishable from a measured one; absence is honest.

### Added — `metrics-report` consumes the write-only half of the schema (+ SOFT DRIFT tier)

`metrics-append` faithfully recorded `phase_durations_seconds`, `review_cycles`, diff sizes, `specialist_iterations`, and rebumps; the shipped report read none of them — the same cost-without-payoff pattern audit #15 closed for the log as a whole. New sections (all canonical-entries-only, `--since`-aware, additive to the existing output — old sections verified byte-identical): **TIER DETAIL** (runs / median wall-min / mean cycles / median lines+files / gate-caused-fix-cycle rate per tier — on production data this prints the release's own justification: H 32/45 runs with a gate-triggered fix vs L 1/34), normalized **rebump transitions** (M→H: 20, T→L: 1 — 43% of High runs are plan-size promotions), **SPECIALIST AUDITS** (per-agent appearances/blockers/block-rate: accessibility-expert 129%, silent-failure-hunter 100%, database-architect 18%), **TOKENS** (per-tier medians once the new flags populate), and **SOFT DRIFT** — canonical entries whose `gates` is empty or whose `self_review` lacks `.calibration`: they pass the schema gate yet contribute zero gate/calibration signal (21 such entries on the primary log; the residual blind spot the re-audit identified after confirming hard drift stopped 2026-05-31). `--json` gains matching keys.

### Fixed — stop-gate false-block on a metrics log missing its trailing newline

`do-metrics-stop-gate.sh` counted entries with `wc -l`, which counts newline *bytes*: a log whose final line lost its terminator undercounts by 1, so a truthful `Metrics: N entries` announce read as inflated and the hook BLOCKed a legitimate finalize. Now `grep -c ''` (counts the unterminated final line too); `-lt` semantics and every other check unchanged. Verified: unterminated 3-line log + truthful announce → allow; genuinely inflated claim → still blocks. (`metrics-append` itself already repaired missing newlines before appending — the hook was the only reader still counting bytes.)

### Fixed — `config-schema.md` documents the real specialist preset (placeholder misled an audit)

The `specialists` example showed `["agent1", "agent2"]` placeholders while the actual default preset lived only in `config-init`'s jq literal — unreadable from the reference docs. Consequence, live: the 2026-07 external audit recommended "remove `database-architect` from `backend_plan`/`backend_audit`" — but it was never in `backend_audit`; the recommendation was refuted only by reading `config-init`. The schema doc now shows the full real preset (backend_plan/frontend_plan/backend_audit/frontend_audit/migration_audit) with config-init named as source of truth.

### Docs — SKILL.md per-tier load map + Low-tier exclusions made explicit

The per-phase reference table now routes by tier (Phase 3: M/H → phase-3-review, Low → phase-3-low; Phase 4: core always + phase-4-pr on M/H-with-code-host, T/L never), and the Low simplifications line states what was previously only derivable (no PR, no ADR — ADR is High-only; context-doc §4.6 still applies when configured). README pipeline-reference list updated with the three new files.

## [0.9.1] — 2026-07-16

Shell-portability release. The orchestrator's shell is frequently **zsh**, which does not word-split unquoted expansions; two spec idioms assumed bash and misbehaved there. One of them made a gate incapable of failing. Found by running the skill against a real repo for a full session (lea-api, 4 issues shipped) and noticing a gate that was green in a state where it could not have been.

### Fixed — Phase 1 concurrent-edit gate reported "no concurrent edits" for every multi-file task under zsh (silent false all-clear)

`git log … -- $PLANNED_FILES` relied on the shell splitting the scalar into one pathspec per file. bash does; **zsh does not** — the whole list arrives as a single pathspec containing spaces, matches nothing, and `git log` prints no commits and exits 0. The gate therefore reported a clean result for every task touching more than one file, and the failure was indistinguishable from a genuine pass. Confirmed in production: an entire session ran with this gate permanently green while `service.go` had 10 commits in the lookback window.

`PLANNED_FILES` is now an array expanded as `-- "${PLANNED_FILES[@]}"` — identical under bash and zsh, and it survives paths containing spaces. The section also states the rule the failure taught: an empty result from a check whose pass is indistinguishable from "matched nothing" is a claim requiring evidence, not a pass ([anti-patterns §25](skills/do/references/anti-patterns.md)).

### Fixed — `${VAR:+--flag "$VAR"}` collapsed flag and value into one argv token under zsh, so wrappers rejected the call (18 sites)

Same root cause, louder symptom: under zsh the expansion is a SINGLE word, so `metrics-append` received `--notes some long text` as one argument and answered `REJECT unknown arg`, surfacing as `Metrics: APPEND FAILED` in the final announce. All 18 occurrences (4 in `pr-size-check`, 2 in `branch-normalize`, 12 in `metrics-append`) now build an args array via a small `add_opt` helper and expand it guarded (`${ARGS[@]+"${ARGS[@]}"}`, which keeps an empty array safe under `set -u`). Verified byte-identical output under bash 3.2 and zsh 5.9, including multi-word values and empty-value omission.

Deliberately unchanged: the do-scripts resolver's `${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT/skills"}`. That expansion yields a single word, which is exactly what both shells produce — the defect is specific to expansions that must split into several words. Verified rather than swept.

### Fixed — `skills/do/SKILL.md` still declared `version: 0.8.1` after the 0.9.0 release

The 0.9.0 release bumped `plugin.json` and the README status line but missed the SKILL.md frontmatter, so the skill advertised a version it had not been for a release. Now `0.9.1` in all three places.

### Added — anti-patterns §25: assuming bash word-splitting; "a gate that cannot fail is not a gate"

Documents both idioms, the portable array fix, the safe single-word case, and the general rule the incident produced. The same class bit the operator's own verification script during the session (`go test $PKGS` collapsed to one argument and printed an empty failing-test set that read as "0 regressions") — a reviewer's tooling is not exempt from the anti-patterns it enforces.

## [0.9.0] — 2026-07-09

Enforcement-integrity release. Two audit tiers (26-finding, 17-agent audit of 2026-07-09): the now-tier (9 fixes: timestamp migrations, `+++` first-line issue callout, portable metrics-append, stop-gate bypass closure, STARTED_AT task clock, schema fixes, uninstall hook reversal, stale-ref sweep) and the next-tier (enforcement integrity on every install path: dynamic wrapper resolution + self-marketplace, wrapper-owned secret-scan coupled to the push, orchestrator-verified build/lint/test, grounded plan-size inputs, §19 de-verbatim + branch-normalize + in-wrapper calibration, hook live-sim release gate, single-sourced auto-merge + tracker preflight, verified specialists preset + locked writes, metrics-report consumer, caveman fork/smart integration + spec-contradiction fixes). All entries below this heading until [0.8.1] belong to this release.

### Fixed — caveman detection matches the real plugin-cache layout + fork-aware install hint + `levels:` register tell (was: plugin installs read NOT INSTALLED — the exact false negative the wrapper was built to kill)

`check-caveman`'s plugin-cache probes tested `~/.claude/plugins/cache/caveman` and `.../JuliusBrussee/caveman` — paths no Claude Code plugin install ever creates. The real layout (verified 2026-07-09 against a live install) is marketplace-namespaced and versioned: `cache/<marketplace>/<plugin>/<version>/skills/<skill>/SKILL.md`. A `/plugin install`-ed caveman therefore read NOT INSTALLED — the same false-negative class as the 2026-05-17 incident the wrapper exists to prevent. The install hint also curled upstream `JuliusBrussee/caveman` while the maintained distribution is the `mitiay7/caveman` fork (adds the `smart` level; upstream 404s on `-fable` tags), and the Phase 2 directive prescribed the full grammar-dropping register that readability-enforcing harnesses fight.

**Fix:** the wrapper keeps its 4 fixed paths and adds glob probes for the marketplace-cache layout (versioned + versionless; caveman's `marketplace.json` names both marketplace and plugin `caveman`, fork included, so one `<marketplace>` glob covers both sources) — every expansion is `-f`-tested and the MATCHED path prints in the ACTIVE line, preserving the tell; unmatched globs stay in the probed list as literal patterns (still spec-uncopyable). New **`levels:` hint** in the ACTIVE form (`smart` | `base`, grepped from the installed SKILL.md at run time) selects the Phase 2 directive register: `smart` (content compression, grammar intact — the designed fit) when supported, full otherwise; code/paths/JSON/diff/report LITERAL-string exemptions unchanged in both registers. Install hint now points at the fork with a one-line provenance note. README section updated to match (fork-first install, real probe set, both tell forms); anti-patterns §19b ledger row updated. Sandbox-probed: versioned cache, versionless cache, legacy fixed path, and empty-HOME probed-list forms all verified, plus a read-only run against the real install (`levels: smart`). Audit finding #22 (minor).

### Fixed — spec self-contradictions an orchestrator could not execute as written (audit #19, minor)

Five verified either-way-you-break-a-rule spots, all resolved toward one executable reading:

- **§4.6 vs "never commit to main":** phase-4 §4.6 instructed `git push origin main` for context docs unconditionally while git-rules said "never commit to main, no exceptions". Delivery is now three strictly-ordered paths: same-repo → task branch (no exception in the code repo, ever); separate docs repo → short-lived `docs/{ref}-context` branch + PR by default; direct main push ONLY into a separate docs repo under new explicit `config.context_doc.allow_main_push: true` (schema + docs) — named as the sole scoped exception in git-rules and SKILL.md.
- **Concurrent-edit check unreachable:** Phase 0 Step 5 needed Phase 1's planned-files list, and nothing looped back — circular sequencing left the gate dead for M/H, its only applicable tiers. Moved into Phase 1 immediately after the planned-files derivation; warning rides the issue's Implementation Hints + the Phase 1 announce; Phase 0/SKILL.md/config docs/gate-vocabulary pointers updated. T/L skip it by construction.
- **Forced `--complexity` vs Phase 2.0 REBUMP:** precedence was unspecified. Now: STOP-and-ask (never silently override either side); user-approved re-bump records the forced marker `complexity_rebumped_from="<tier>(forced)"`, declined keeps the forced tier with the wrapper verdict quoted in announce + metrics notes.
- **SKIP list vs Trivial tier:** "single-line edits where the pipeline is overkill" contradicted Trivial's purpose. Explicit invocation of an implementable task now ALWAYS runs — one-liners route to Trivial, never refused.
- **"Opus plan" vs Sonnet drafting:** description promised Opus plans on High while phase-2 has Sonnet drafting them. Description reworded to "Sonnet plan + specialist/Opus plan review + Sonnet impl"; Roles now distinguish drafting from deciding (nothing Sonnet proposes is architectural authority until specialists/Opus approve).

### Fixed — `--no-affected-graph` is wired, not just documented (was: a documented control that silently no-oped — scoped tests ran while the user believed the full suite passed)

The flag existed only in flag tables: Phase 0 Step 4 overrode build/test commands unconditionally on nx/turbo detection and phase-2's Build line scoped via the tool without checking `$ARGUMENTS`. A monorepo user passes this flag precisely when they suspect the affected graph missed cross-project breakage — the most dangerous moment for a silent no-op. **Fix:** one per-task predicate defined at Phase 0 Step 4 — *in use = tool detected AND `config.affected_graph` enabled AND `--no-affected-graph` absent* — consumed by Step 6 test scoping, the Phase 1 Build Checklist, phase-2's Build line, and phase-3's `build-verify` command substitution; the announce shows `Affected-graph: disabled (flag)` and the suppression-paths list documents the flow. The cache still records `affected_graph_tool` (durable fact); the flag's effect is never baked into cache. Audit finding #17 (major).

### Fixed — SKILL.md digest drift: hardcoded model literal, phantom behaviors, missing flag rows, leaky trigger (audit #21, minor)

- Trivial Phase 4 hardcoded `Co-Author = Claude Haiku 4.5` — the exact stale-literal class the skill's own rules (and v0.8.1) forbid. Now: the implementer sub-agent's model identifier read from ITS session metadata; new Notation bullet pins `opus`/`sonnet`/`haiku` as harness tier aliases (top/mid/fast), never dated model ids.
- `--implementer=sonnet`'s "minus the issue-skip warning" referenced a warning defined nowhere — deleted; the row now spells explicit no-op semantics on L/M/H (announced, never silent), `--implementer=haiku` HARD REJECT extended to cover L (was M/H with L unspecified), and the table states there are no implicit rejections beyond that one.
- `--issue-locale=<code>` was fully implemented in phase-0 but absent from SKILL.md's flag tables (README declares SKILL.md the source of full flag semantics) — row added.
- Phase table said "Trivial uses Sonnet diff-scan only", contradicting the dep-vuln exception 8 lines below — parenthetical fixed.
- Trigger token-bounded: `/do`/`+++` must be a complete token (`/docs`, `/done` don't match) with a unified-diff exclusion (`+++ b/` / `--- a/` prefixes are pasted diffs, not invocations) — mirrored in install.sh's CLAUDE.md trigger block and the README manual snippet.
- Volatile "(8 production violations)" count deduplicated out of SKILL.md — points at the anti-patterns §19f ledger, the single home for such counts.

### Added — `metrics-report`: the telemetry consumer now ships with the skill (was: write-only telemetry for every install but the author's — the detection tier rested on a scanner adopters couldn't obtain)

`daily-report.sh` was referenced in 6+ places as a load-bearing defense tier ("the daily-report scanner will surface the bypass in tomorrow's report", the `Fired*` column, "scannable by a single daily report") but existed only on the operator's machine. For adopters the metrics tier was pure write-side cost — entries accumulated with zero payoff — and the consolidated §19 detection story partly rested on a tool they could not run. The telemetry analysis confirmed the loop WAS closed on the operator's machine (44 generated reports): a shipping gap, not a design gap.

**Fix — ship the consumer:** new read-only CLI [`skills/do/scripts/metrics-report`](skills/do/scripts/metrics-report) (bash + jq, no new dependencies):

- **Aggregates**: per-complexity-tier counts with outcome split, plan-size rebump rate + `X→Y` transitions, self-review calibration accuracy across all 3 dimensions (`legacy`/`defect`/`size`, `n_a`-aware), per-gate pass/warn/fail/block/skip table with fail rates, top-5 failing gates. `--since <date>` range filter (lexicographic ISO compare on `started_at`), `--json` for machine-readable output.
- **Log resolution** mirrors the write side: `--log <path>` (tilde-expanded like `metrics-append`) → current dir's `.claude/do/config.json` `metrics.log_path` with §4.11-identical `{repo_slug}` substitution → all of `~/.claude/do/metrics/*.jsonl` (the tier-1 preset home; `--repo <slug>` narrows, a miss lists available slugs).
- **It IS the §19a detection tier now**: parseable entries missing the canonical fields (`ref`/`started_at`/`ended_at`/`complexity`/`outcome`/`self_review` — the direct-write signature) land in a SCHEMA BYPASS section, listed by ref and excluded from aggregates. Malformed lines are skipped with a stderr WARN, never fatal (one corrupt line must not kill the report). Empty/absent logs get a helpful "no entries yet" message, exit 0; only user errors (bad flag, explicit `--log`/`--repo` miss) REJECT with exit 1.
- **Doc sweep** — every `daily-report.sh` reference now points at the shipped command: phase-4 "Defense in depth" + bypass diagnostic, anti-patterns §19 correction row, `metrics-append`/`config-init` header comments, README (auto-init preset line, feature table, new "Reading the telemetry" section with usage, v0.7/v0.8 status notes). Cron/launchd/HTML wiring is explicitly optional operator-side extra. CONTRIBUTING test checklist item 4 extended: changes touching the metrics schema or `metrics-append` must aggregate cleanly through `metrics-report` (crafted-log probe recipe included). The report is the human feedback loop, NOT a phase step — phase-4 says so explicitly (an orchestrator must never run it mid-pipeline).

Verified on macOS/BSD + debian/GNU against a crafted 20-entry log covering every enum value (all 4 tiers, 3 outcomes, all calibration verdicts incl. `n_a`, all 5 gate statuses + an unknown status + an unknown gate key + a scalar gate value, all 3 rebump transitions, 3 bypass-shaped entries) plus a malformed line: every aggregate matched hand-computed expectations exactly on both platforms (tier counts, 18% rebump, 60/67/63% calibration, top-failing order), the malformed line WARNed and was skipped, bypass refs listed, `--since` filtered 17→8, `--json` passed jq assertions, config/`{repo_slug}`/tilde/default-dir/`--repo` resolution all probed, empty + missing + no-logs paths produce the helpful message.

Audit finding #15 (major).

### Fixed — specialists preset verified against installed plugins + a defined Opus-inline rule for configured-but-unavailable specialists (was: preset written blind, fallback improvised — the phantom-plugin incident re-armed on every new machine)

`config-init` emitted the 6-plugin specialists preset without ever consulting `~/.claude/plugins/installed_plugins.json` (machine-readable, present on every plugin-enabled install), and the README's claimed graceful degradation ("falls back to Opus inline review, no error") had no mechanism anywhere — phase-2/phase-3 only covered `specialists` NOT SET, never "set but the `subagent_type` doesn't spawn". That's the exact gap behind the historical `frontend-excellence` incident, which surfaced downstream as an improvised fallback to the WRONG model ("Specialists not available — falling back to Sonnet"): an H-tier plan silently reviewed by the implementer's own tier, the independence the specialist stage exists to add.

**Fix — both halves, config-time and spawn-time:**

- **`config-init` verifies the preset before writing it**: reads the version-2 manifest (`{plugins: {"<name>@<marketplace>": [{version, …}]}}`), DROPS entries whose plugin is missing, OMITS groups that become empty (all-missing → the whole `specialists` block is omitted), and emits a further stdout line after `Config:`/`Tracker:` — `Specialists: PRESET VERIFIED (N/M plugins installed: <name@version, …>)` | `PRESET FILTERED (…; MISSING: … — entries dropped, groups omitted: …; to restore: /plugin install …)` | `PRESET EMPTY (…)` | `UNVERIFIED (no readable manifest — full preset written)`. The `name@version` list is read from the manifest at runtime — not composable from spec text (§19c tell standard; ledger row extended). The line rides inside `$CONFIG_LINE` verbatim (phase-0 prefix glob unaffected); `_meta._setup_notes` records drops + per-plugin restore commands. Manifest unreadable/malformed → fail-open with the honest UNVERIFIED form (the spawn-time rule still covers the gap).
- **Spawn-time rule in phase-2 (Plan Review) and phase-3 (§3.6)**: a configured specialist whose `subagent_type` fails to spawn → announce per seat — `Specialist {type}: NOT AVAILABLE — Opus inline fallback for {group}` — and Opus reviews that seat inline with the same inputs, checklist obligations (migration seats still apply the zero-downtime checklist), roster count, and blocking authority. NEVER substitute Sonnet or any implementer-tier model; never drop the seat or hand-edit the config mid-task to hide the gap. Hand-edited configs and post-init uninstalls still reach this rule even with the config-time filter in place.
- README: auto-init section shows the `Specialists:` verdict forms; the plugins section and the "falling back to Sonnet" troubleshooting entry now describe the two-layer defense.

Verified in a sandboxed probe matrix (temp HOME, real manifest shapes): full manifest → `PRESET VERIFIED (6/6 …)` with real versions + all 5 groups written; phantom-plugin manifest (3 of 6 absent) → `PRESET FILTERED (3/6 …)`, `frontend_plan` omitted, `frontend_audit` filtered to its one installed plugin, zero phantom entries in the file, setup-notes record the drop; empty manifest → `PRESET EMPTY`, no `specialists` key; no/malformed manifest → `UNVERIFIED` + full preset; `--no-specialists` unchanged (no line, no block); filtered configs pass the jsonschema gate.

Audit finding #9 (major).

### Fixed — metrics-append/config-init write-path integrity: lock-serialized content-verified appends, terminator repair, tilde expansion, atomic fail-if-exists config commit (was: four corruption/false-fail holes under real concurrency)

Four write-integrity holes in one class — no locking anywhere, and flock(1) doesn't ship on stock macOS: **(a)** `metrics-append`'s pre/post `wc -l` delta raced concurrent /do runs (a documented real workflow — the 3-parallel-agent postmortem) on the deliberately-shared per-repo log → spurious IOFAIL after a SUCCESSFUL append → the spec-instructed retry duplicated the entry, corrupting the telemetry the system exists to keep honest; **(b)** a log missing its trailing newline (SIGKILL, full disk) FUSED the next append into the corrupt last line while the delta check still PASSed (wc -l counts newlines: pre missed the partial line, post counted it); **(c)** a quoted `'~'` in `--log` appended to a literal `./~` directory (an rm-baiting trap) while the Stop hook expanded the same configured path against `$HOME` and read a different file → data loss + spurious block; **(d)** `config-init`'s `-e`-check→`mv` window let parallel auto-inits silently clobber each other despite the never-overwrite guarantee.

**Fix:**

- **mkdir-based lock around append+verify** (`<log>.lock/` — atomic on every POSIX FS): concurrent wrapper writers serialize; a lock held past the 10s wait window with mtime ≥60s old is a crashed holder — broken with a stderr NOTE and retried (BSD/GNU dual-path `stat` as SEPARATE assignments — GNU `stat -f %m` prints a filesystem block to stdout before failing, so an `a || b` chain inside one substitution captures garbage; found live in the debian probe run).
- **Content-based verify is authoritative** (`grep -qxF` for the exact entry as a full line); the pre/post delta is demoted to informational — a surprise delta now flags a non-wrapper writer (§19a) on stderr instead of false-failing a successful append into the duplicate-entry retry. OK-line format unchanged (§4.13 parsers + Stop hook lockstep preserved); the Stop hook's tell check relaxes `pre+1 ≠ N` → blocks only `pre+1 > N` (the stale-`wc -l` hand-composition signature) while tolerating concurrent growth, mirroring its existing `-lt` count check — hook-live-sim extended to 38 cases (M4b pins the tolerance), green on macOS/BSD + debian/GNU.
- **Terminator repair before appending**: `tail -c 1` probe; a missing trailing newline is repaired (stderr NOTE) before the entry is written with `printf '%s\n'` — no more fused/unparseable records.
- **Tilde expansion at arg-parse** in both wrappers (`--log`, `--repo-root`): config paths are data — a quoted leading `~` never saw shell expansion; now expanded against `$HOME`, matching the Stop hook's read side. The §4.11 Step 1 snippet expands it spec-side too (the orchestrator's own `mkdir -p` was the other `./~` creator).
- **`config-init` commits atomic-fail-if-exists**: `ln` (atomic, fails when the target exists) then `rm` — the first parallel init wins, the loser dies loudly with `REJECT already exists (lost an init race …)`; plus a content-based post-write verify (`jq -e .` on the committed file catches truncated writes behind the success announce).

Verified in a sandboxed probe matrix, green on macOS/BSD bash 3.2 and debian/GNU (64 + 62 checks; the 2 skips are python3-jsonschema absent in the container): 10× parallel appends to one log → 10 lines, every entry exactly once, all exit 0, zero IOFAIL, no lock litter, every OK tell post=pre+1; newline-less log → repaired, 2 parseable lines, no `}{` fusion; quoted-tilde `--log` → lands under `$HOME`, no `./~`; 2-minute-old stale lock → broken after the wait, append succeeds; 4× parallel config-inits → exactly 1 winner, 3 `REJECT already exists`, committed file valid and matching the winner; quoted-tilde `--repo-root` → expands (bare `~` still refused as home-root); all pre-existing REJECT paths unchanged; Stop hook allows pre+1==N and N>pre+1, still blocks pre==N.

Audit finding #18 (minor, verified-major impact — telemetry corruption class).

### Fixed — auto-merge precondition single-sourced: explicit `ci.required: true` + a passing §4.2.5 gate, else per-run confirmation → `await_review` (was: two authoritative texts disagreed, and the unset-CI default auto-merged unverified)

§4.2.6's guard read "never auto-merge if `ci.required: false`" — by its letter it covered only the explicit `false`, not the common UNSET default (the solo/local setup the spec optimizes for), and its "verify CI is green (4.2.5 already passed)" was vacuous when §4.2.5 was skipped (that gate only runs on explicit `true`). Meanwhile anti-patterns' auto-merge bullet said the same state "warns; user must explicitly accept" — "never" vs "warn+accept", two contradictory instructions for one state, so an orchestrator inclined to proceed could cite whichever text permitted it. Net effect: `auto_merge.enabled: true` + no `ci` block auto-merged a PR with zero post-push verification.

**Fix — one rule, defined in §4.2.6 only:**

- **Precondition**: auto-merge fires ONLY when `config.ci.required` is **explicitly `true`** AND this run's §4.2.5 gate PASSED. Explicit `false`, unset, and no-`ci`-block are ONE state — unverified; config alone never pre-authorizes an unverified merge.
- **Unverified + auto-merge requested** → hand-grenade warning + **exact-phrase per-run confirmation** (`merge unverified`); confirmed → merge proceeds with `⚠ merged unverified (per-run user confirmation, no CI gate)` recorded in the §4.7 issue comment and the §4.13 announce (new optional token); anything else, including silence → `await_review` (PR stays open, pipeline completes normally — not an error).
- **All other texts now defer**: the anti-patterns bullet points at §4.2.6 and explicitly disclaims being a rule of its own ("never cite this bullet as the permissive alternative"); §4.2.5 states the hard dependency; config-schema.md's `ci`/`auto_merge` sections and both README surfaces (security bullet + cheat-sheet row) repeat the pointer, not a second rule.

No config field shape changed (`ci.required` stays a boolean; `auto_merge` block unchanged) — schema untouched; all `examples/*.json` re-validated against it (none enables `auto_merge`, no example drift).

Audit finding #11 (major).

### Fixed — Phase 0 fresh-machine preflight: wrapper-owned gh/glab presence+auth gate with DEGRADED-to-none, and an explicit non-git-directory STOP (was: both states resolved by model improvisation)

Auto-init wrote `issue_tracker.type: github` purely from the remote URL — never `command -v gh`, never `gh auth status` — so the most common fresh-machine state (git present, gh absent) committed the pipeline to a tracker it can't talk to, and the first failure surfaced as a raw `gh: command not found` mid-pipeline with no spec'd fallback. Running `/do` outside a git repo likewise had no defined behavior: Step 3's `git rev-parse` failed quietly and the first symptom was later Step 4/5 bash dereferencing an unset `$REPO` — both against the skill's own every-failure-mode-is-a-spec'd-line philosophy.

**Fix:**

- **`config-init` owns the tracker preflight** (existing wrapper extended — no wrapper sprawl): on github/gitlab detections it probes `command -v gh|glab` + `gh|glab auth status` BEFORE writing the type. Probe fails → the written config degrades to `type: "none"` with `_meta.tracker_degraded_from`/`tracker_degraded_reason` + the remedy in `_setup_notes`, and a second stdout line after the `Config:` line: `Tracker: DEGRADED to none (<tool> missing|unauthenticated — <fix>)` (honest degraded state, copyable on purpose). Probe passes → `Tracker: github|gitlab OK (<tool version>; auth account: <login>)` — version + account are runtime probes, not composable from spec text (the §19c tell standard; ledger row extended, including "pre-probing gh in spec bash and flipping `$TRACKER` yourself" as a named bypass). The verdict rides second so phase-0's `"Config: AUTO-GENERATED"*` prefix glob keeps matching; both lines travel inside `$CONFIG_LINE` verbatim into the announce.
- **DEGRADED-to-none is a defined mode, never a silent skip**: trackers.md §none documents it (runtime-identical to plain none; the difference is observability + the recorded restore path); phase-1-issue.md now requires an announced skip — `[Phase 1] SKIPPED — tracker: none (DEGRADED from github: gh missing)` — repeating the reason at the phase that lost functionality (plain-none and Low-complexity skips gain announce lines too).
- **Step 3 non-git STOP**: verbatim bash — `git rev-parse --show-toplevel` failure prints `STOP: not inside a git repo — cd into a project repo, pass --repo=NAME (needs config.workspace.repos), or git init first` and HALTs Phase 0 before any Step 4/5 work or side effects.
- README: auto-init section shows the `Tracker:` verdict forms; troubleshooting gains the degraded-tracker and non-git-STOP entries.

Verified in a sandboxed probe matrix (33 checks green on macOS bash 3.2; 31/31 behavioral re-pass on debian/GNU — the 2 skips are python3-jsonschema absent in the container, and the schema checks passed on macOS): non-git STOP text + exit 1 and in-repo `Repo:` pass-through; gh-missing (PATH-restricted) → DEGRADED line + `type: none` + `_meta` markers + remedy, no dangling `repo` key; gh-present-unauthenticated (shim) → `gh unauthenticated` reason; gh-authenticated (shim) → exact OK line with version+account tell, no degrade markers; glab-missing gitlab mirror; plain `--tracker none` unchanged (single stdout line, no verdict); the phase-0 prefix glob against a 2-line `$CONFIG_LINE`; degraded + OK configs validate against config.schema.json; all three REJECT paths unchanged (overwrite / bad tracker / missing `--tracker-repo`). Shellcheck-clean, bash-3.2-clean.

Audit finding #13 (major).

### Fixed — tier-3 hooks live-verified end-to-end + the missing §19f PR-creation backstop shipped (was: hooks validated with mock stdin only, never live-registered; §19f's Tier-3 cell claimed a hook that didn't exist)

v0.8.0 shipped the hooks with mock-stdin validation only — the `last_assistant_message` field name and the transcript-fallback jq shape were assumptions about the real Stop payload, and a wrong assumption would have made the backstop silently no-op forever while hooks.md, the §19 table, and README told users the gap was covered (the v0.2.4 "nobody re-tested the documented flow" lesson verbatim). Separately, §19f's Tier-3 cell claimed a PreToolUse backstop for the PR-size gate, but the shipped hook only acts on `PLAN-SIZE:` markers at plan time — the PR-creation hook that `pr-size-check`'s exit 3 was designed for was never shipped.

**Fix — verify what exists, ship what was claimed, gate the future:**

- **`hooks/hook-live-sim.sh` shipped (release gate)** — a sandboxed harness (temp HOME + repo copy with the origin remote removed; it can never touch the real `~/.claude` or the network) that (R) runs the REAL `install.sh` with `ENABLE_HOOKS=Y` and asserts all four hook entries register exactly as hooks.md documents (fully-resolved absolute commands through the skills symlink; idempotent re-run; `uninstall.sh` strips all four), then (P) drives every REGISTERED command with realistic Stop/PreToolUse payloads and asserts each allow/block/inject path. **37 cases, green on macOS/BSD and debian/GNU.** Payload shapes are grounded, not assumed: `last_assistant_message` and `stop_hook_active` are both documented (hooks reference + hooks-guide, fetched 2026-07-09), the PreToolUse envelope matches the reference, and the metrics gate's transcript fallback was verified against a real local transcript's JSONL shape — including an M12 case proving the hook still blocks when the `last_assistant_message` field is absent entirely. The matrix covers the metrics gate's full closed-set/tell/freshness/loop-guard behavior with the NEW `(pre=<p> gates=<g>)` format, plan-size verdict injection (tell intact, always non-blocking), secret-scan's committed-then-deleted range deny, and the new pr-size hook below.
- **`hooks/do-pr-size-pretooluse.sh` shipped (fourth hook)** — §19f's Tier-3 leg made real: PreToolUse on `Bash`, self-scoped to `gh pr create` / `glab mr create`, re-runs `pr-size-check` against the repo's REAL diff (repo dir from a leading `cd <dir> &&` else the call's cwd; base from `--base`/`-B`/`--target-branch`/`-b` else `origin/HEAD`→main/master; head from `--head`/`-H`/`--source-branch`/`-s` when locally resolvable; thresholds from the project's `config.pr_size.*` when present; same `--numstat` churn formula as §3.0). **Denies (exit 2) ONLY a confirmed over-block-cap non-draft creation**; `--draft` is ALWAYS allowed — §3.0's own BLOCK remediation is "draft PR + `blocked` label", so blocking drafts would deadlock the sanctioned escape path (a draft under BLOCK gets the verdict injected as context instead). PASS/WARN verdicts are injected as `additionalContext` so `gates.pr_size` gets a genuine wrapper line even when §3.0 was skipped; everything uncertain fails open. Wired into `settings.with-hooks.json`, `install.sh` Step 6.5 (Bash-matcher merge loop), and `uninstall.sh`'s `HOOK_RE` (no stranded entries after uninstall).
- **Docs now match reality** — `hooks.md`: new pr-size hook section, three→four sweeps, and a **§Verified 2026-07-09** section recording the verified payload shapes, the registration steps, what the matrix proves per hook, and the honest residual (the sim feeds documented payloads to registered commands; it is not a full live Claude Code session — after a Claude Code major upgrade, re-run the sim and check `/hooks` + one real finalize). `anti-patterns.md` §19f Tier-3 cell rewritten from the phantom "(shares plan-size marker tier)" to the real hook + its deny/draft contract. README: fourth hook bullet + live-sim note, three→four counts. **CONTRIBUTING gains release-gate item 7**: hook live-sim MUST pass (both platforms) for any change touching `hooks/`, the §4.13 announce format, or install/uninstall hook wiring.

Audit finding #16 (major).

### Fixed — remaining §19 tier-1 surfaces: Metrics-config templates de-verbatimized, branch normalization wrapper-owned, calibration computed inside `metrics-append` (was: three announce/data surfaces still composable or trust-based)

The audit's residual sweep found three surfaces contradicting the spec's own "no copyable templates" invariant — the STARTED_AT capture gap from the same finding shipped earlier (task-clock preflight); this closes the rest. **(a)** All three `Metrics config:` wrapper outcome lines were printed verbatim in phase-0 Step 1 prose with no runtime-only tell — the one wrapper-owned announce token missing from the §19 ledger; fabricating telemetry state behind a green announce was undetectable. **(b)** Phase 4.0 branch normalization was inline spec bash with a confirmed production violation (v0.3.1: "Complete. Branch: $EXPECTED" announced without renaming — the worktree still sat on the harness auto-name, breaking `i{N}` traceability), and the announce's `Complete. Branch:` value was a shell variable that — under the fresh-shell-per-block model — never even survives to §4.13. **(c)** The three self-review calibration verdicts, the highest-signal data point in the telemetry loop, were orchestrator-computed with enum-only validation — pure trust, though they are a pure function of flags `metrics-append` already receives.

**Fix — the §19 treatment on all three:**

- **(a) `config-ensure-metrics` tell + de-verbatim** — every outcome line (ALREADY CONFIGURED / EXPLICIT OPT-OUT / AUTO-ADDED) now ends with a runtime fingerprint: `(cfg=<POSIX cksum over jq -cS canonical JSON of the file actually read/written> …)`, AUTO-ADDED adding `patched_at=<runtime clock>` and ALREADY CONFIGURED the real `keys=` count — auditors recompute the crc from the file on disk. Phase-0 Step 1 prose reduced to state tokens (full lines live only in the wrapper, same pattern as `check-caveman`); spec-side fallback forms (`PATCH SKIPPED`, `SKIPPED (--no-metrics)`, Step 4 mirrors) stay copyable on purpose as honest degraded states. New **§19i** ledger row; README announce examples updated.
- **(b) `scripts/branch-normalize` shipped** (ninth wrapper) — owns slug kebab-normalization (ASCII lowercased, hostile ASCII squeezed to `-`, **Unicode letters preserved** byte-deterministically via LC_ALL=C — no locale-dependent `[:alnum:]`; 40-char cap), `config.naming` template substitution (`{N}`/`{slug}`; `{N}` without `--issue-number` REJECTs), `-v2..-v9` collision suffixes with the cap→ask-user path, `git check-ref-format` validity, the rename itself, and old-remote-ref cleanup (upstream-aware, `--no-remote-delete` opt-out). Verdict lines `BRANCH OK name=… head=<sha8>` / `BRANCH RENAMED <old>→<new> head=<sha8> old_remote=…` carry the session-varying HEAD tell; REJECT (exit 1) fails closed, rename failure exits 2. §4.0 rewritten to resolver + dispatch (`$BRANCH_LINE`, fail-closed `NORMALIZE SKIPPED`); §4.13's `Complete. Branch:` is now a **live `git rev-parse` read-back** in the announce block (the old `$EXPECTED` reference could never survive the fresh shell anyway), cross-checked against the §4.0 verdict; the §4.1.2 push targets `HEAD` for the same reason. git-rules §Branch-verification section rewritten; new **§19j** row; Stop-hook placeholder guard extended (`BRANCH_NAME`/`BRANCH_LINE`, keeping `EXPECTED` for pre-§19j spec quotes).
- **(c) calibration computed inside `metrics-append`** — all three verdicts (`calibration`, `calibration_defect`, `calibration_size`) are now computed by the wrapper from raw inputs it already holds: `--sr-performed`/`--sr-claimed`, the NORMALIZED gates (post-alias, so `tests`→`test` can't skew the failed-gate scan), specialist blockers, the new `--sr-size-assessment` flag (the raw Phase 2.5 `size_assessment:` value — the only added input), and `--complexity-rebumped-from`. The `--sr-calibration*` flags became optional cross-checks: a hand-passed value contradicting the computation hard-REJECTs (drift is a visible bug), `n_a` on the split dims = legacy "not computed", omitted = normal path. The OK line gains a `cal=<c>/<d>/<s>` echo (tell); §4.13 parsers verified compatible. Bonus consistency gate from the same finding: `--outcome blocked` without `--blocked-reason` (and the converse) now REJECTs. §4.11 pseudocode re-framed as documentation of the wrapper's pure function; §19a row updated.

Verified in a sandboxed probe matrix: branch-normalize 12 cases (Cyrillic slug with slashes/punctuation renames and round-trips `BRANCH OK`; collision → `-v2`; >40-char truncation; `{N}`-without-issue / empty-slug / detached-HEAD / non-repo / unknown-flag REJECTs; custom `task/{N}/{slug}` template; local-bare-origin upstream delete + `--no-remote-delete`); config-ensure-metrics all three outcomes carry recomputable `cfg=` crcs (crc changes with file content; REJECT paths unchanged); metrics-append hand-math parity on the §4.11 formula across 8 cases including the 39%-de-confound case (`ready` + only `pr_size=warn` → `accurate/accurate/false_positive`), specialist-blocker defect-FP, contradiction REJECT, matching-legacy-flags back-compat pass, and both blocked-reason contradictions; §4.13 `sed` parsers extract pre/post/gates from the extended OK line. All scripts bash-3.2-clean (incl. a real 3.2 parser bug found in probing: bare `$VAR` followed by a multibyte `→` mis-parses — braced), shellcheck-clean, no awk interval regexes.

Audit finding #14 (major) — remainder; the STARTED_AT task-clock slice shipped separately (4a2ea41).

### Fixed — plan-size gate: grounded inputs per tier, real L-tier REBUMP path, and a tell that can't be composed from spec text (was: neutralizable from both ends)

The load-bearing Phase 2.0 gate — built after 16 of 21 M-tasks shipped over the M caps with 0 recorded rebumps — was defeatable at both its input and its output. **Garbage-in:** `PLANNED_FILES`/`PLANNED_LINES_EST` were sourced from "the approved plan", which exists only for High — and even for High only AFTER the Step 2 spawn, while §2.0 ran before it (time-inverted as specced). For T/L/M the numbers were orchestrator-invented at gate time, making the gate tautological: Phase 0 picked the bucket from the same guess, the wrapper faithfully PASSed it, and the tier-3 hook re-ran the wrapper on the same invented numbers. The L-tier REBUMP branch dead-ended on "re-run Phase 1 (issue update)" when no issue exists (Low skips Phase 1), and referenced a "Phase 1.5" that exists nowhere. **Void tell:** the spec claimed "no copy-pasteable form of the cap values" while printing them in phase-2 prose (M example, H ceiling twice), the Phase 0 routing matrix, anti-patterns §19d/§21, and the README — every PASS/REBUMP/SPLIT-REQUIRED line was composable from spec text without running the wrapper, so the fabrication epidemic the wrapper was built against could return undetected.

**Fix — ground the inputs, define the paths, make the output non-composable:**

- **Input provenance table in §2.0 (per tier)** — numbers MUST be read out of a written artifact, never invented at gate time: T/L from the inline task description, whose format now carries a per-file `~N lines` delta on each `**Files**` bullet plus a mandatory `**EstLines**` sum (written BEFORE the gate runs); M from the Phase 1 issue's `### Implementation Hints`, which now requires an `Est deltas` list (`{path} — ~{N} lines` per planned file); H runs the gate **twice** — pre-spawn on the Phase 1 estimates, and again after Step 2 plan approval (before Step 3 implementation) on the approved plan's per-file deltas, the first artifact with real per-file scope and the run where SPLIT-REQUIRED has real data. The Step 2 → Step 3 transition and the PLAN-SIZE hook-marker instruction (most-recent-run numbers) wire the second run in at the point of use.
- **REBUMP branch defines the actual re-entry path** — M: update the existing issue and run the H flow; T/L: no issue exists, so run Phase 1 NOW to CREATE it at the new tier, then continue (creation IS the path; the old "issue update" instruction was unfollowable). Dangling "Phase 1.5" reference removed.
- **Derived anti-fabrication tell** — every `plan-size-check` verdict line now ends with `[tell:<head8>:<ck>]`: `<head8>` = repo HEAD short-SHA at run time (session-varying; `nogit` outside a repo), `<ck>` = POSIX `cksum` over inputs + wrapper-internal caps + `<head8>`. Offline composition is detectably wrong (the spec carries neither the formula nor the H ceiling, and HEAD changes per session); auditors recompute `<ck>` from the printed line. §2.0 prefix-glob dispatch, the PreToolUse hook (verdict passed through opaquely, verbatim), and metrics (never parse the line) all stay compatible — verified.
- **Cap-literal scrub with the second layer preserved** — the H ceiling now lives ONLY in the wrapper (scrubbed from phase-2 SPLIT branch prose, anti-patterns §21, README ×2); the Phase 0 routing matrix keeps T/L/M (Phase 0 routes with them — their composability is what the tell defends). Critically, the implementer's self-review step 6 — text embedded in the Sonnet prompt, whose only cap source was its own literals — was NOT naively scrubbed: it now invokes the same `plan-size-check` wrapper on the ACTUAL post-write diff (`git diff --shortstat main...HEAD` parsed into files/insertions), so layer 2 gets the same structured, tell-carrying verdict instead of eyeballable numbers; REBUMP/SPLIT there forces `size_assessment: exceeds` + `claimed_status: deferred` with the wrapper line quoted verbatim. `size_assessment` gains an `unknown` value for the wrapper-unresolvable case (fail-honest, never eyeball). §19d row rewritten for the new tell + an input-provenance bypass diagnostic.

Verified in a sandboxed probe matrix (27 checks): PASS/REBUMP/SPLIT-REQUIRED all carry the tell and keep exit 0 + prefix-glob compatibility; SPLIT suggest-count math intact; the tell recomputes from printed inputs + HEAD and changes when HEAD does; `nogit` fallback outside a repo; REJECT path unchanged (exit 1); hook injects the REBUMP verdict tell-intact as jq-parseable `additionalContext`, no-ops without the marker, and works from a non-git cwd; step-6 shortstat parsing extracts exact files/insertions and feeds the wrapper. Shellcheck-clean, bash-3.2-safe constructs only (`cksum`/`cut`, no awk interval regexes).

Audit finding #6 (major), with all three verification adjustments applied (implementer-prompt second layer preserved via wrapper invocation instead of literal scrub; H timing inversion fixed via the twice-run rule; tell hardened with the session-varying HEAD component).

### Fixed — Phase 3 build/test gates re-run by the orchestrator via `build-verify` (was: adjudicated entirely from the implementer's self-report)

Gate 3.1 said "Tests: YES but no PASS output → return to Sonnet" and the Phase 3.7 review criteria literally read "PASS in Sonnet report" / "confirmed in Sonnet report" for tests, build, and migration — the orchestrator was never instructed to re-run `cache.build_cmds`/`lint_cmds`/`test_cmd` in `$WORKTREE_PATH` at any point before commit/push/PR. That is the §19 fabrication class one trust level down: the Phase 2 report format asks Sonnet to write its own exit codes, so a plausible green self-report sailed through with zero independent evidence — and with `auto_merge` enabled and no CI (the default path; the §4.2.5 CI gate is opt-in and post-push anyway), all the way to merged main. Meanwhile pr-size and plan-size in the same file were wrapper-hardened against exactly this failure mode.

**Fix — the §19 treatment (wrapper + structural coupling):**

- **`scripts/build-verify` shipped** — the ONLY supported way to produce the Phase 3.1 VERIFY PASS/FAIL/SKIPPED decision. Runs the checklist (`--build`/`--lint`/`--test`, each via `bash -c` from the worktree so cached monorepo `cd App && …` commands work) in order build → lint → test, fail-fast; **FAIL exits 3** (return to Sonnet with the failing command's last-15-lines tail); bad invocation REJECTs (exit 1, fail closed). Per-command anti-fabrication tell: `rc=<n> <n>ms <n>L tail=<8-hex CRC of the last 20 output lines>` — elapsed-ms + line-count + output-tail hash are not reproducible without running (a bare rc=0 is guessable and would fail the §19 tell standard). Degraded stacks handled per stack-detection.md: `stack: "other"` yields no commands → VERIFY SKIPPED, legs recorded `skipped`, never `pass`; the test leg is scoped to Tests: YES tasks. `build`/`lint`/`test` were already canonical gate vocabulary in `metrics-append` — reused, no schema change.
- **`phase-3-review.md` §3.1 rewritten** — resolver + wrapper + `case` dispatch in the §3.0 pattern; commands sourced from the stack cache with `config.affected_graph` substituting affected-scoped equivalents (re-run cost stays sane in monorepos; `--no-affected-graph` = full set); resolver-miss fails closed (`GATE ERROR`, never "fall back to the Sonnet report"). **Self-report mismatch is now a first-class signal**: implementer claimed PASS where the re-run FAILs → `details.self_report_mismatch: true`, treated as fabrication-class and fed into §4.11 self-review calibration. Coverage rule unchanged. §3.5 (Low) prerequisite wired to the same re-run — SKILL.md routed Low around most gates, which would have left the Low path self-report-only; §3.7 "Tests pass"/"Build passes" criteria now cite the orchestrator's own `VERIFY PASS` legs; Phase 3 announce carries a `Verify:` token from the wrapper verdict line.
- **`anti-patterns.md` §19h row added** — wrapper, tell, bypass diagnostics (a `pass` leg with no `Phase 3.1: VERIFY` transcript line; a leg `skipped` while the cache has commands; test skipped on a Tests: YES task; PASS-claim-vs-FAIL-re-run mismatch), and the note that the opt-in CI gate re-proves post-push but never replaces the pre-commit re-run. Phase 2 sub-agent report step warns that exit codes are cross-checked (self-review block unchanged — this adds verification, not replaces it).

Verified in a sandboxed probe matrix on bash 3.2 (macOS): multi-command PASS with per-cmd tells (including `cd`-prefixed monorepo cmds), mid-checklist FAIL exits 3 with NOT-RUN fail-fast marking + failing tail, no-commands VERIFY SKIPPED exits 0, first-command failure skips everything downstream, REJECT on missing `--dir` / bad dir / unknown flag. Shellcheck-clean, no awk interval regexes (CONTRIBUTING §6).

Audit finding #7 (major).

### Fixed — pre-push secret gate is wrapper-owned over the full push range (was: instruction-only, and scoped to a diff that misses committed secrets)

The only irreversible gate in the pipeline — a pushed secret is revoke-and-rotate, not revert — was tier-1 prose: `phase-4-finalize.md` §4.1 said "Secret check (filenames + content) before push", and `git-rules.md` §Secret guard was a glob list + regex hints applied by model judgment. By the §19 ledger's own law (metrics: 7 audited bypasses; caveman: 2 prod bypasses; plan-size: 0/32 rebumps pre-wrapper; pr-size: 8 over-block PRs shipped as warn), every instruction-only check eventually gets skipped. Worse, the prose itself carried a latent bypass: it said to check `git diff --cached` — but by Phase 4.1 the earlier Phase 2 commits are already in branch history, so a secret committed (or committed-then-deleted) mid-implementation never appears in the staged diff yet every one of those blobs gets pushed.

**Fix — the §19 treatment (wrapper + structural coupling + optional tier-3 hook):**

- **`scripts/secret-scan` shipped** — the ONLY supported way to produce the pre-push PASS/BLOCK decision. Scans the **full push range** `merge-base(origin/main → origin/master, HEAD)..HEAD` via `git log -p`: per-commit file names against the git-rules globs (`.env*`, `*.key`, `*.pem`, `credentials.*`, `*.secret`, `id_rsa*`, `*.p12`, `*.pfx`; template files `*.example`/`*.sample`/`*.template`/`*.dist` exempt from the name check only) and per-commit **added lines** against 7 content patterns (AWS `AKIA`, `sk-` API keys, Slack `xox*`, GitHub `gh?_`, PEM private-key blocks, signed JWTs, quoted secret assignments — matched with `grep -E`, portable across BSD/GNU) — so add-then-delete is caught too. No origin/main (or unrelated histories) → full-tree HEAD scan fallback. **BLOCK exits 3** with a findings list (pattern names + paths — never the secret text, so output is transcript-safe); PASS emits the anti-fabrication tell (real range SHAs + commit/file counts, not reproducible without running); bad invocation REJECTs (exit 1, fail closed). `secret_scan` was already canonical gate vocabulary in `metrics-append` — no schema change.
- **`phase-4-finalize.md` §4.1.2 rewritten** — scan and push are ONE bash block (fresh-shell model: a scan in a separate block proves nothing about the block that pushes); `git push` runs ONLY inside the wrapper's exit-0 branch; resolver-miss fails closed (`GATE ERROR` + `PUSH WITHHELD`, same family as Phase 2.0/3.0). Dispatch instructions carry the verdict line verbatim into `gates.secret_scan.details.tell` for the §4.13 announce/metrics coupling; BLOCK maps to `OUTCOME="blocked"`. There is deliberately NO spec-copyable pass form.
- **`git-rules.md` §Secret guard rewritten** — names the wrapper as the executor, documents the full-range rationale and the `--cached` latent bypass, keeps the glob/pattern lists as documentation of what the wrapper enforces. `anti-patterns.md` §10 no longer re-teaches the `--cached` check; **new §19g row** records wrapper, tell, bypass diagnostic, and tier-3 backstop. SKILL.md top-level git constraint updated to match.
- **Optional tier-3 hook: `hooks/do-secret-scan-pretooluse.sh`** (PreToolUse, matcher `Bash`) — re-runs the scan before any Bash command performing a `git push` (`git stash push` excluded; repo dir from `-C <dir>` or the call's cwd). **Blocks (exit 2) only on a confirmed match** (wrapper exit 3), feeding the findings list back to the model; everything else fails open — missing jq/wrapper, REJECT, crash, unresolvable dir → allow. On PASS it injects the genuine verdict tell as `additionalContext`. Unlike the other two hooks it deliberately also guards non-/do pushes (the no-secrets rule is unconditional and the failure irreversible). Wired into `settings.with-hooks.json`, `install.sh` Step 6.5 opt-in merge, and `uninstall.sh`'s basename-matched removal (`HOOK_RE` now covers all three hooks — no stranded Bash-hook entries after uninstall); `hooks.md` + README updated (seven wrappers, three hooks).

Verified in a sandboxed probe matrix: planted AWS key committed then deleted mid-branch + `.env` file in an earlier commit — invisible to both `git diff --cached` (empty) and the endpoint diff — BLOCK exit 3 with both findings attributed (`name-glob .env*`, `content aws_access_key` + commit SHA); clean branch PASS with range tell; no-remote and unrelated-history repos fall back to full-tree (clean PASS / planted Slack token BLOCK); template `.env.example` name exempt but a real secret inside it still blocks (case-insensitive assignment pattern); REJECT on non-repo, unborn HEAD, unknown flag, unresolvable `--base`. Hook simulation: blocks `git push` and `git -C <worktree> push` against the dirty repo (exit 2, findings on stderr), allows clean pushes with the PASS tell injected, no-ops on `git status`/`git stash push`/`git log | grep push`, falls back to cwd for an unexpandable `"$WORKTREE_PATH"`, and fails open on non-repo cwd / missing cwd. Both new scripts are bash-3.2-clean (macOS) and avoid awk interval regexes (BSD/GNU/mawk divergence — the CONTRIBUTING §6 lesson).

Audit finding #5 (major).

### Fixed — migration prefixes: sequential next-free allocation → UTC timestamps (collision-proof)

The skill taught next-free-integer migration allocation at four points — Phase 0.5 computed `ls | sort -V | tail -1` + 1, the Phase 1 issue template hardcoded `Number: NNN` / `NNN_{slug}` filenames, Phase 3.7 said "increment migration number" on amendment, anti-patterns §16 said "write NEW migration with higher number" — while explicitly endorsing parallel sessions. That rebuilds by construction the 2026-05-09 miro-rooms-rentals incident: three parallel `/do` agents each picked `000036` as next-free, the duplicate gate fired only on the third rebase, and the second slipped to main via `--admin` merge. The Phase 0.5 cross-branch lookahead races identically — sessions that pick "next number" at spawn, before any commits exist, all pass it.

**Fix — timestamps remove the race by construction** (two sessions creating a migration in the same UTC second is essentially impossible):

- **`phase-0-setup.md` Step 5** — prefix is now *generated*, not computed: `MIGRATION_PREFIX="$(date -u +%Y%m%d%H%M%S)"`. The cross-branch scan is retained but downgraded STOP → WARN as a legacy-duplicate check only (timestamp prefixes cannot collide with in-flight work). Origin note added.
- **`phase-1-issue.md`** — issue template's `### Migration` section now reads `Prefix: {TS}` (UTC timestamp, generated at creation time) with the `{TS}_{slug}` file pattern; acceptance criterion updated to `Migration {TS}`.
- **`phase-3-review.md` §3.7** amendment rule — "write NEW migration with a fresh UTC timestamp prefix"; never amend, never allocate sequentially.
- **`anti-patterns.md` §16** — "higher number" → "fresh UTC timestamp prefix", with the collision incident recorded (this line otherwise re-taught the sequential pattern the other edits remove).
- **Display placeholders swept** (`NNN` → `{TS}`, non-breaking): Phase 0 announce + Phase 2 flags `Migration: {YES {TS}/NO}`, Phase 1/4 issue-comment `Migration: {TS} (or —)`, `notifications.md` `migration_proposed` body. Context-doc guidance in Phase 1/4 no longer bumps a "Next migration" counter — legacy counters are informational only, never allocated from.

Mixing with existing sequential migrations is fine — every common migration tool sorts numerically (`000036` < `20260509073812`), so new timestamp files come after the legacy ones; history is never renumbered. No script parses migration numbers (verified), so the placeholder sweep is display-only. Aligns the skill with the global collision-proof migration-naming rule written after the same incident.

### Fixed — plugin install works end-to-end; wrapper paths resolve on every install layout (was: recommended install a dead end; literal wrapper paths killed the tier-2 layer on any non-default install)

Two compounding breaks on the README's "recommended" path. (a) `/plugin marketplace add` requires `.claude-plugin/marketplace.json`, which didn't exist — the only documented self-service install failed in the user's first five minutes. (b) Even installed, all six wrapper invocations (`check-caveman`, `config-init`, `config-ensure-metrics`, `plan-size-check`, `pr-size-check`, `metrics-append`) hardcoded `~/.claude/skills/do/scripts/` — a path only the default-name symlink install creates. Under plugin cache or a custom `SKILL_NAME` every wrapper call failed and the orchestrator fell back to hand-composing announce lines — the precise §19 fabrication class the wrappers were built (v0.6/v0.7) to prevent. Four of the six call sites (`check-caveman`, `plan-size-check`, `pr-size-check`, `metrics-append`) had NO missing-file fallback at all: empty gate variables, unmatched case-arms, and the pr-size hard halt ("BLOCK exits 3, cannot be narrated past") silently vanishing.

**Fix:**

- **`.claude-plugin/marketplace.json` shipped** (self-marketplace pattern) and `plugin.json` now declares `"skills": "./skills/"`. Install is two commands: `/plugin marketplace add mitiay7/senior-by-default` → `/plugin install senior-by-default@senior-by-default`. README plugin-install section rewritten accordingly.
- **Canonical do-scripts resolver, repeated verbatim in every wrapper block** — a one-line probe (`find -L` over `$CLAUDE_PLUGIN_ROOT/skills` → `~/.claude/skills/<any name>/scripts` → `~/.claude/plugins/cache` → `~/.local/share/senior-by-default/skills`; sentinel file `metrics-append`; first hit wins) sets `$DO_SCRIPTS` per block. Per-block, NOT resolve-once-at-Phase-0: each spec bash block runs in a fresh shell (same shell model as the task clock), so a variable resolved in Phase 0 does not exist in the Phase 2/3/4 shells. Every live-spec literal replaced: `phase-0-setup.md` Step 1 (config-ensure-metrics), Step 2 (check-caveman), Step 4 (config-init ×2); `phase-2-implementation.md` §2.0; `phase-3-review.md` §3.0; `phase-4-finalize.md` §4.11 canonical invocation + §4.13 emit block. This changelog's own historical literals intentionally untouched (release notes are records, not spec).
- **Fail closed at all six sites** — a resolver miss now emits an explicit token, never an empty gate variable: `Metrics config: PATCH SKIPPED — …`, `Caveman: CHECK SKIPPED — …` (documented as the one spec-copyable `Caveman:` form — an honest degraded state the user will chase, not a plausible-looking success), `Config: AUTO-INIT SKIPPED — …`, `Phase 2.0: GATE ERROR` (new case-arm — do NOT spawn the implementer, STOP), `Phase 3.0: GATE ERROR` (new case-arm — treat like BLOCK, never like pass; `PR_SIZE_RC=127`), `Metrics: APPEND FAILED — …` (already a legal terminal form the Stop hook does not re-block).
- **`hooks/do-metrics-stop-gate.sh`** — both block-reason remediation strings now name the sibling `metrics-append` self-located via `$0` (the pattern sibling `do-plan-size-pretooluse.sh` already used); settings.json registers hooks by absolute path, so `$0` always resolves. No parser change — the hook verifies the announce against the **log** path, not the wrapper path.
- **False prose claim removed** — `phase-4-finalize.md` §4.11 no longer asserts the literal path "resolves to the same path inside the installed skill"; `hooks.md`'s custom-name caveat is now explicitly scoped to hook registration only (wrapper invocations self-resolve).

Verified in a sandboxed probe matrix (temp `$HOME` per layout): default symlink, renamed `SKILL_NAME` (rendered copy), plugin cache (versioned nested subdirs), `$CLAUDE_PLUGIN_ROOT` set (wins over a coexisting symlink), `~/.local/share` clone only, and `$HOME` containing spaces — all resolve to the right `scripts/` dir; the none-installed layout resolves empty and each call site's fail-closed branch emits its explicit token.

Audit finding #2 (critical). Supersedes the interim README known-limitation callout recorded under the stale-reference sweep entry below.

### Fixed — issue bodies open with the line-1 `+++` execute callout (global rule compliance)

The Phase 1 issue template opened with the locale prologue, violating the global first-line execute-callout rule (2026-05-19 — revised same day from "a section anywhere in the body" to "literal first line" precisely because trackers truncate list previews to ~150 chars; a buried callout never surfaces in list views, email notifications, or Slack unfurls). Every M/H issue `/do` created was non-compliant, as were Phase 4.4 tech-debt issues. Fired on 100% of M/H tasks.

- **`phase-1-issue.md`** — template line 1 is now the canonical callout blockquote ("🚀 **Execute:** `+++ #{ISSUE_NUM}` — runs the `/do` skill … Or paste this issue URL after `+++`."), blank line, then the prologue. Placement invariant spelled out above the template: no heading above it, no preamble, never inside `<details>`. `{ISSUE_NUM}` rides the existing two-step substitution — step 3 now says "ALL occurrences" and the `grep -c ISSUE_NUM` → `0` verify already guards the new occurrence. "Locale-specific prologues" section renamed to "Locale-specific callout & prologues"; **ru** callout variant added beside the ru prologue; Origin note recorded.
- **`trackers.md`** — custom trackers (Linear, Jira, …): adapt syntax if blockquote/backticks don't render, keep the semantics — one visually-distinct first line with the literal `+++` invocation, tracker-native issue ref (e.g. `ENG-123`) or issue URL after `+++`.
- **`phase-4-finalize.md` §4.4** — tech-debt issues created in the tracker start with the same callout (the global rule covers every agent-created issue, not just Phase 1).

Audit finding #12 (major).

### Fixed — `metrics-append` timestamp parsing portable across BSD/GNU (was: hard-fail on every Linux host)

`scripts/metrics-append` converted `--started-at`/`--ended-at` to epochs via `date -j -u -f` — BSD-only. On GNU/Linux both calls fail (`invalid option -- 'j'`) with stderr suppressed, so every valid ISO-8601 timestamp died with the misleading `REJECT … not ISO-8601 UTC`. Total telemetry loss for the whole platform on "the ONLY supported way" to emit — and with `hooks/do-metrics-stop-gate.sh` blocking finalize until a genuine wrapper run is evidenced, a Linux orchestrator was wedged between an always-failing wrapper and a blocking hook: exactly the §19a direct-write bypass pressure the wrapper exists to remove.

**Fix** (`scripts/metrics-append` timestamp block), three layers:

- **Strict shape regex FIRST** — `^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$` gates both timestamps before any `date(1)` call. The ordering is load-bearing: GNU `date -d` is lenient (accepts `2026-05-21`, `tomorrow`, `@0`), so without the regex the GNU fallback would silently *weaken* validation on exactly the platform being fixed. The regex is the validator; `date` only converts.
- **BSD/GNU dual-path epoch conversion** — `date -j -u -f … || date -u -d …` with `|| die` when both fail. Each side rejects the other's flags cleanly (GNU: `invalid option -- 'j'`; BSD: `illegal option -- d`; both exit 1), so die-on-malformed is preserved on both platforms. busybox/musl `date` supports neither form — documented in the script as not a supported emission platform.
- **Honest die message** — the epoch-conversion failure no longer claims "not ISO-8601 UTC" (shape is proven by the time it fires); it names the real causes (out-of-range field, or `date(1)` neither BSD nor GNU).

Verified empirically on both platforms. macOS BSD path: canonical timestamp → epoch `1779352200`; BSD `date -d` exits 1 so the fallback chain still dies; shape-valid out-of-range `2026-13-45T99:99:99Z` rejected; negative-cycle ordering check fires; equal timestamps accepted. Debian GNU via docker: same epoch `1779352200` (identical cross-platform math); valid entry now appends `OK pre=0 post=1` where pre-fix was total loss; `2026-05-21` / `tomorrow` / `@0` all REJECT via the regex; negative-cycle check fires. `CONTRIBUTING.md` test checklist gained item 6: any change touching `scripts/`/`hooks/` gets one GNU/Linux run (docker one-liner provided) — this exact flag-divergence class is what it catches.

Audit finding #3 (major).

### Fixed — metrics Stop-gate hardened: closed announce set, freshness cross-check, tell carried into the announce (was: defeatable in both directions)

The announce/stop-gate chain was defeatable in both directions, all verified against the live hook. False negatives: the hook blocked only when the log had FEWER lines than claimed, so claiming the log's current `wc -l` with zero appends this turn passed silently — the cheapest move for the exact adversary the hook names; §4.11 sanctioned a `Metrics: skipped — <reason>` form no bash path ever emits (hand-composable, and the hook's unrecognized-form fallthrough allowed it); and §4.13 rebuilt the user-visible line as `Metrics: $POST_COUNT entries in $LOG_PATH`, stripping the wrapper's `pre=/post=/gates=` tell — the whole line was composable verbatim from spec text, unlike `check-caveman` whose canonical strings live only in the wrapper. False positive: a session quoting the §4.13 heredoc template (docs work on phase-4 itself) tripped the no-`Metrics:`-line block.

**Fix**, spec and hook in lockstep:

- **`phase-4-finalize.md` §4.11** — the phantom skip form is deleted (`Metrics: skipped` had zero emitting bash paths repo-wide); the legal `Metrics:` forms are now an explicitly CLOSED set of three: `<count> entries in <path> (pre=<n> gates=<n>)`, `APPEND FAILED — <reason>`, `not configured (…)`. "What broke the procedure" gains the matching bullet.
- **`phase-4-finalize.md` §4.13** — the announce now carries part of the wrapper's anti-fabrication tell: `(pre=<n> gates=<n>)` parsed from the OK line, anchored on `^OK` because `$METRICS_RESULT` holds `2>&1` and a `NOTE gate-normalize:` stderr line may precede it. LOCKSTEP comment added at the format definition: change the announce format and the hook's parsers together, never one side alone — a tell appended after the path would false-block every legitimate run under the old path parse; one inserted before "in" would empty it and silently disable verification.
- **`hooks/do-metrics-stop-gate.sh`** — three new positive detections plus a false-positive guard:
  - **Closed set** — an unrecognized `Metrics:` form (`skipped — <reason>`, prose restatements) now BLOCKS; the old fallthrough-allow at that exact point was the documented bypass. Terminal states (`not configured`, `APPEND FAILED`) still pass; the tell suffix stays optional so pre-tell installs don't false-block.
  - **Tell consistency** — a carried tell must satisfy `pre`+1 = count (the wrapper guarantees post = pre+1 for a single append); a hand-composed tell copied from a stale `wc -l` typically writes pre = count → block.
  - **Freshness cross-check** — the count check only proves the file has ≥ N lines, not that THIS turn appended one. Now the last JSONL entry's `ref` must appear in the announce OR the log mtime must be within 30 minutes (BSD/GNU dual-path `stat`; unreadable mtime → allow, uncertainty never blocks). The count comparison stays `<` (not `≠`) deliberately — a concurrent `/do` session appending to the same log between emit and Stop legitimately pushes the count above the claim.
  - **Template-quoting guard** — a message carrying unexpanded §4.13 placeholders (`$EXPECTED`, `${METRICS_LINE}`, …) is quoting/editing the spec, not finalizing → no-op. Deliberately narrower than a cwd-based self-repo guard (which would disable the backstop for genuine `/do` runs on this repo). "Require both signature lines" was considered and dropped: it trades a false positive for a cheaper false negative (omit the `Models:` line to escape hook scope entirely).
- **"non-bypassable" → "harness-enforced backstop"** — README hook section + v0.8 status highlight, `hooks.md`, the hook header, and `install.sh` step-6.5 comment/prompt no longer claim the absolute; the hook is opt-in and verifies the announce against the log file, nothing stronger. Historical release notes below keep their original wording.
- **Docs lockstep** — README troubleshooting and `hooks.md` now show the tell-carrying announce shape; `hooks.md` documents the new block conditions and the lockstep invariant (re-install after changing either side so the deployed `~/.claude` copies match — a new-format spec against an old-format hook false-blocks every run).

Verified with an 18-case probe harness of crafted Stop payloads: legit announces allow (new/old format, fresh log, ref-in-announce with stale mtime, concurrent ACTUAL > N); bypasses block (stale-count claim in both formats, `skipped` form, prose restatement, 99-entry over-claim, missing `Metrics:` line, pre=count tell mismatch, nonexistent path); template-quoting and `stop_hook_active` don't false-block. End-to-end: a genuine `metrics-append` run → §4.13 parse → announce → hook allow, exercising the multi-line NOTE+OK output.

Audit finding #4 (major).

### Fixed — Phase 0 task clock: `STARTED_AT` captured at entry into a durable file (was: never captured; Phase 4.11's hard-reject unsatisfiable)

No phase-0-through-3 text ever instructed capturing `STARTED_AT`. Phase 4.11 said "capture **at Phase 0 entry** … NOT retroactively at Phase 4.13" — but that sentence lives in `phase-4-finalize.md`, which progressive disclosure (anti-patterns §8) forbids preloading, so a spec-compliant orchestrator first learned the requirement AFTER the moment it could satisfy it. The only remaining move was back-computing at emit time — the exact pattern behind the 36%-negative-cycle-time production failure that `metrics-append`'s `--ended-at < --started-at` hard-reject was built to catch. Compounding shell-model trap: even an orchestrator that ran `STARTED_AT=$(date …)` early lost it — every spec bash block executes in a fresh shell, so no Phase 0 variable survives to the Phase 4 process. The value must live on disk.

**Fix — task clock file, written at Phase 0 entry, read back at Phase 4.11:**

- **`phase-0-setup.md` §Preflight** — new "Task clock" block, the FIRST action of Phase 0 (before the clarity check): verbatim bash captures `STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)` and writes `{started_at, phase_entered_at: {"0": …}}` to `~/.claude/do/state/<cwd-slug>.task-clock.json` (slug: same char-mapping as the stack cache, anchored on the orchestrator's CWD git-toplevel — the only anchor that exists before Step 3 resolves the target repo, and re-derivable identically in Phase 4's fresh shell). Echoes `Clock: started <ts> → <file>` as the transcript fallback. Per-phase stamps: a one-liner `jq '.phase_entered_at[$p] = $t'` run on ENTERING each later phase — degradation is asymmetric by design (missed stamp loses one duration split; missed capture would lose `--started-at` entirely, hence capture-first).
- **`phase-0-setup.md` §Announce** — new mandatory `Started: {STARTED_AT}` line (listed with `Models:` in the mandatory set). Doubles as the transcript-durable fallback and the cross-check anchor: parallel same-CWD sessions share the clock path (latest Phase 0 wins), and a Phase 4 read-back that mismatches the announce means an overwrite — prefer the announce value, it is the genuine echo of this task's capture.
- **`phase-4-finalize.md` §4.11** — "Computing `$STARTED_AT`" rewritten as read-back-from-disk (`jq -r '.started_at'`), never `date` re-derivation; `$ENDED_AT` documented as the ONLY timestamp legitimately generated in Phase 4; `$PHASE_DURATIONS_JSON` now derived from the clock's stamps (delta to next stamp; last stamped phase ends at `$ENDED_AT`) instead of being invented from memory. Clock missing AND no announce line → Phase 0 spec violation noted in `--notes`, not a license to back-compute.
- **`phase-4-finalize.md` §4.13** — the announce/emit bash block opens with the clock read-back + duration-derivation lines (CWD-anchored re-derivation, `fromdateiso8601` deltas), so `--started-at` and `--phase-durations-json` are populated by the same one-shell flow that emits — previously the block referenced `$STARTED_AT` that nothing had ever set. Phase-entry stamp reminder added at the top of the file.
- **`scripts/metrics-append`** — both `--started-at` die messages (missing-arg, negative-cycle) now point at the clock file read-back instead of the unactionable "capture at Phase 0" advice that fired only after the capture window had passed.

Degradation verified empirically: missing clock file → empty read-back → announce-value fallback; clock without stamps → `PHASE_DURATIONS_JSON=""` → optional flag omitted; phase-0-only stamps → `{"0": <total>}`; skipped phase 3 → its span correctly attributed to the preceding stamp's delta. Duration keys match the documented `phase_durations_seconds` shape (`config-schema.md` tier-1 example).

Audit finding #14 (major) — now-tier slice (`STARTED_AT` capture). The sibling next-tier items (de-verbatim Metrics-config templates + §19g row, `branch-normalize` wrapper, wrapper-computed calibration) are deliberately not in this change.

### Fixed — config.schema.json rejected documented-valid configs on three verified paths; schema-gate skips are now visibly announced

The schema — "the source of truth" per `config-validation.md` — hard-rejected three config shapes the skill's own docs and scripts produce, all empirically reproduced against jsonschema 4.26.0 (draft 2020-12):

- **(a) `issue_locale` enum `["ru","en"]`** — Phase 0 auto-init detects `ja`/`ko` from `$ARGUMENTS` and passes them straight to `config-init`, whose own schema gate then REJECTed the value it was handed: exit 1 for every Japanese/Korean task. Now a pattern, `^[a-z]{2}(-[A-Z]{2})?$` — any ISO 639-1 code, optional region. `config-init` additionally validates `--issue-locale` up front against the same pattern, so a bad locale yields an actionable `REJECT --issue-locale …` instead of an opaque schema-gate error — and still fails closed when jsonschema is absent.
- **(b) both documented metrics opt-outs were schema-INVALID** — `metrics: null` (the explicit opt-out `config-ensure-metrics` honors: "user EXPLICITLY opted out… respect intent") and `metrics.log_path: null` (the opt-out `config-init` writes into every generated config's `_setup_notes`). Users following the skill's written advice got configs any conformant validator hard-STOPs (`config-validation.md`: ERRORS → STOP). `metrics` is now nullable via `oneOf` (same shape as `ui_gate`); `log_path` is `["string","null"]`.
- **(c) omitted `issue_tracker.type` fired the custom-tracker branch** — `{"repo":"o/r"}` was rejected demanding a custom `commands` block, though `config-schema.md` documents github as the default when `type` is omitted. Per the audit verification, `required:["type"]` is added ONLY to the custom if-branch (stops the vacuous match), NOT to the github/gitlab branch — its vacuous match on omitted type is deliberately kept: an omitted-type config IS a github config and must carry `repo` (every `gh` call in `trackers.md` passes `--repo`); gating it on explicit type would make `issue_tracker:{}` schema-valid but runtime-broken. Both branches now carry `$comment`s so the asymmetry survives future edits.

**Schema-gate skips are no longer silent.** Both write-path wrappers (`config-init`, `config-ensure-metrics`) validated only when python3-jsonschema happened to be importable — absent, they wrote the file unvalidated under the identical clean announce, indistinguishable from a validated write. Their success lines now carry a wrapper-emitted ` (schema gate SKIPPED — jsonschema unavailable)` suffix when the gate couldn't run. Safe by construction: `phase-0-setup.md` matches `"Config: AUTO-GENERATED"*` as a prefix glob, and the suffix is the wrapper's own tell, not an agent annotation — §19c forbids the agent decorating `$CONFIG_LINE`, not the wrapper emitting a richer line. `phase-0-setup.md` (Step 1 outcome list, Step 4 `$CONFIG_LINE` comment) tells orchestrators to carry the suffix verbatim, never strip it.

- **`references/config.schema.json`** — the three fixes above, plus descriptions recording the pre-fix failure modes.
- **`references/config-schema.md`** — sketch line shows the pattern (not the two-value union); `issue_locale` gets its own semantics section; `issue_tracker` documents the omitted-type = github + `repo`-still-required contract the schema now enforces; `metrics` documents both nullable opt-outs.
- **`references/config-validation.md`** — Validation flow gains step 3 (programmatic schema gate; jsonschema absent → run rule-based checks AND append the visible skip suffix to the announce — never silent); new `issue_locale` / `metrics` rule sections; `issue_tracker` rule notes the omitted-type default.
- **`scripts/config-init`, `scripts/config-ensure-metrics`** — `SCHEMA_GATE_SUFFIX` on the success announce; header exit-code docs updated; up-front locale check (config-init).

Gates, all green: the fixed schema self-checks against draft 2020-12; all 4 `examples/*.json` validate (CI's `json-validate` job unchanged); 8 positive probes for the documented-valid shapes (ja/ko/pt-BR locales, `metrics:null`, `log_path:null`, omitted-type-with-repo, explicit github, custom-with-commands) now pass; 7 negative probes (≥1 per fixed bug: `english`/`RU` locales, `log_path:42`, `metrics:true`, custom-without-commands, github-without-repo, empty `issue_tracker:{}`) still fail. End-to-end: `config-init --issue-locale ja` succeeds and its output validates; bad locale REJECTs up front with and without jsonschema; simulated jsonschema-absent runs of both wrappers emit the suffixed announce; `metrics:null` opt-out is respected untouched and validates.

Audit finding #8 (major) — three verification adjustments applied (custom-branch-only `required:["type"]`; existing CI `json-validate` job already covers examples positively, the gap was negative/documented-scenario probes — run as commit gates here; announce-suffix confirmed glob- and §19c-safe). The fixture-test-file wiring into CI is deliberately left to the tests follow-up.

### Fixed — `uninstall.sh` reverses the hooks merge (was: stranded `settings.json` entries → hook errors on every Stop/Task spawn after uninstall)

`install.sh` Step 6.5 (v0.8.0) merges the opt-in `Stop`/`PreToolUse` hook commands — paths through the `~/.claude/skills/<name>` symlink — into `~/.claude/settings.json`. `uninstall.sh` removed that symlink, never touched `settings.json`, and claimed "✓ uninstalled": a user who had opted in got missing-script hook errors on every Stop event and every Task spawn, in **every** project, with nothing attributing the breakage to senior-by-default. Found independently by 2 of 8 audit analyses.

**Fix — uninstall Step 2.5 mirrors the install merge in reverse** (`uninstall.sh`):

- **jq-based removal, matched by script basename** (`do-metrics-stop-gate.sh` / `do-plan-size-pretooluse.sh`) — covers install-written symlink paths, custom-skill-name installs (the directory changes, the basenames don't), and manual `settings.with-hooks.json` merges alike. Emptied hook groups and event arrays are dropped; a `hooks` object left empty is deleted; everything else in the file round-trips untouched.
- **Timestamped `.bak.<epoch>` backup** (same style as the install-side merge) taken only when an edit actually lands — a no-op or failed run never litters backups.
- **Fail-open on every degraded path**: `jq` absent → entries left in place, manual removal instructions printed (delete the two entries, confirm via `/hooks`); `settings.json` invalid JSON → warn, file left byte-identical; no entries present → skip. None of these aborts the rest of the uninstall (`set -e`-safe), and the final "What was touched" summary reports the hook-removal outcome honestly per branch (`Removed … (backup: …)` / `LEFT IN PLACE … — remove manually` / `nothing to remove`).
- **Docs**: README §Uninstall names the settings.json step + the jq-missing fallback; `hooks.md` gains a "Disabling / uninstalling" section documenting the reverse-merge, the basename matcher, and why the step is load-bearing.

Probed in a sandbox HOME (real `uninstall.sh`, no mocks): install-shaped merged settings → both `do-*` entries gone, unrelated Stop hook + `permissions`/`model`/`env` keys byte-intact, emptied `PreToolUse` cleaned, exactly one backup carrying the pre-edit content, symlink and trigger block also removed; second run is idempotent (skip, no second backup); jq-absent run (restricted PATH) leaves the file untouched, prints the manual instructions, exits 0; invalid-JSON settings likewise untouched with no backup.

Audit finding #10 (major).

### Fixed — stale-reference sweep across the executable spec; honest install caveats in README (was: phantom phase ids, dangling anti-pattern ids, drifted claims)

The spec carried dead cross-references from before the Phase 0 6-step reorganization and the anti-patterns renumbering — the exact stale-reference class this repo already had an incident about (v0.5.0 README drift → phantom-plugin cascade). Executors hitting `Phase 0.0.3` or `Anti-pattern 31a` either improvise a mapping or conclude the spec is unreliable. All live-spec hits fixed; `CHANGELOG` history intentionally untouched (release notes are records, not spec).

**Retired `Phase 0.x` sub-phase ids → the 6-step layout** (Step 1 config, Step 2 caveman, Step 3 repos, Step 4 stack cache, Step 5 sanity, Step 6 routing/announce):

- `phase-1-issue.md` — `0.3` → Step 5 (concurrent-edit, ×2); `0.0.2` → Step 1 (postmortem context)
- `phase-2-implementation.md` — `0.0.3` → Step 2 (caveman directive condition); `0.5` → Step 5 (`{TS}` prefix comment); `0.1` → plain "Phase 0" (reference modules — no single owning step)
- `config-schema.md` — `0.0` → Step 1 (path-resolution validators); `0.1` → Step 3 (multi-repo routing); `0.0.1` → "Step 1 WIP check" (`wip_limit`); `0.3` → Step 5 (`concurrent_edit_check`)
- `config-validation.md` — `0.0` → Step 1 (when validation runs); warnings print "before the Phase 0 announce (Step 6)"
- `stack-detection.md` — `0.2` → Step 4 (when detection runs); `0.6` → "Step 5 migration detection"
- `notifications.md` — `task_started` fires after "Step 6 announce" (was `0.4`); `migration_proposed` on "Step 5" detection (was `0.6`)
- `config.schema.json` — `wip_limit` description names the Step 1 WIP check (was `Phase 0.0.1`; description-only, all `examples/*.json` re-validated)
- `phase-4-finalize.md` gate-vocab table — `concurrent_edit` phase `0.3` → `0 Step 5`

**Dangling anti-pattern ids** (numbering ends at §24; `31a`/`31c` never existed): `phase-2-implementation.md` pinned reminders #1/#2 now cite [anti-pattern §12] (branch rename) and [§19a] (metrics announce/emit coupling), linked.

**Phantom "Phase 4.0.5"**: reminder #3 told the executor to hand-run `wc -l` pre/post — a procedure that moved INTO `metrics-append` in v0.7.0 (the wrapper emits `OK pre=N post=N+1 …` only on delta=1, `IOFAIL append silent-fail: …` otherwise). Rewritten against the wrapper's OK line: verify `OK ` + `post = pre + 1` in the captured output; non-OK surfaces verbatim as `Metrics: APPEND FAILED — <reason>`. Hand-recounting is now explicitly forbidden — a spec teaching a manual re-implementation of a wrapper-owned tell was §19-adjacent by its own standards.

**`stale_main` default aligned**: `config-schema.md` "Defaults if no config" claimed stale-main was covered by "everything else OFF" while `phase-2-implementation.md` §2.0.5 applies warn-20/block-50 unconditionally. The defaults list now names it ON with the shown thresholds.

**Caveman claim**: `~75%` compression → `65% (measured)` in the Phase 2 sub-agent directive and README (the measured figure the caveman skill itself ships).

**README install honesty**:

- **Known-limitation callout under the plugin-install section** (interim mitigation for audit finding #2 — superseded in this same release by the dynamic wrapper-path resolver entry above): the six tier-2 wrappers were invoked at the literal `~/.claude/skills/do/scripts/`, which only the manual symlink install at default name `do` creates; plugin installs and custom `SKILL_NAME`s degraded to prose-level enforcement. The callout has since been replaced by the resolver story.
- **Caveman fork note**: one sentence pointing at the curated fork [mitiay7/caveman] (`v1.10.x-fable` releases, adds a `smart` level — content compression, grammar intact — suited for Fable-class harnesses); upstream JuliusBrussee link and install one-liner kept.

Audit finding #20 (minor); README caveat = interim mitigation for finding #2 (critical); 65%-figure + fork note overlap finding #22 (minor).

## [0.8.1] — 2026-05-31

**Patch — version-agnostic model examples.** Doc/comment-only fix; no behavior change.

### Fixed — stale `opus-4.7` example literals (version-agnostic now)

Three example literals hardcoded `opus-4.7` / `Opus 4.7`: `scripts/metrics-append` (2 usage-comment lines for `--orchestrator`) and `references/git-rules.md` (Co-Authored-By footer example). The orchestrator read these as canonical and recorded `opus-4.7` in telemetry / could copy the stale footer even when running a newer model build.

**Not a spawn-logic bug.** Agents spawn via the version-agnostic aliases `opus`/`sonnet`/`haiku` (SKILL.md notation) and frontmatter `model: opus`, all resolved by the harness to the current build — confirmed by the v0.7.0/v0.8.0 commits already carrying `Claude Opus 4.8 (1M context)` footers. Only the example literals were stale.

**Fix** (consistent with the skill's own rule "Never hardcode a model version", anti-patterns §11): replaced the `opus-4.7` literals with `opus-<version>` placeholders + explicit "read the running model id from session metadata, omit to default to the `opus` alias" guidance. Runtime enum `opus-[0-9.]+` still accepts real values like `opus-4.8` — verified it records correctly. Won't rot at the next model release.

## [0.8.0] — 2026-05-29

**Hook-based enforcement + cleanup.** v0.7.0 fixed the measurement instrument and added a PR-size ceiling; v0.8.0 closes the enforcement loop and tidies what the prior cycles accreted.

**Release-level summary:**

- **Tier-3 harness hooks (P3, opt-in).** The wrapper tier is strong but model-dependent — if the orchestrator never invokes a wrapper, it can't fire. Two opt-in Claude Code hooks add a runtime backstop the model can't skip: a **Stop hook** that blocks a `/do` finalize lacking a valid, file-backed `Metrics:` line (self-scopes to `/do` runs), and a **PreToolUse hook** that surfaces the plan-size verdict at spawn time. Off by default; ship as `skills/do/hooks/` + `references/hooks.md` + opt-in `install.sh` wiring. The skill is unchanged without them.
- **Gate investigation (P4).** The five "never-failing" gates are NOT theater — `0 fails` was a measurement artifact (Phase 3 loops until pass, records the resolved state). Counting `fix_cycle>0`, all fire (`opus_review` 16/125, `test` 5/130, `i18n` 5/104, …). All kept; the daily report gained a `Fired*` column so live gates stop looking dead.
- **§19 consolidation (P4).** The 7-entry §19 anti-pattern family (one root cause, much repetition) collapsed to one principle + a 6-row instance table (with a new tier-3-hook column). Legacy ids retained for cross-references.
- **Wrapper-lib: assessed, declined (P4).** The only duplication is trivial 1-liners + an 8-line block in 2 wrappers; self-containment is a documented design value and a sourced lib would add a failure mode on the Phase 0 critical path. Cargo-cult DRY, declined with rationale.

The three enforcement tiers are now explicit: soft instruction → structural-coupling wrapper (default) → opt-in harness hook. See [`references/hooks.md`](skills/do/references/hooks.md).

### Cleanup — gate investigation, §19 consolidation, wrapper-lib assessment (P4)

#### Dead-gate investigation → keep all five (measurement artifact, not theater)

The audit flagged five gates as never-failing (`opus_review`, `i18n`, `contract`, `test`, `migration_audit` — all `0 fails` across runs). Investigated before pruning: the `0 fails` is a **measurement artifact**, not theater. Phase 3 loops until pass and records the *terminal* (resolved) gate state, so a gate that fired and was fixed within the task shows `status: pass` with `fix_cycle > 0`. Counting `fix_cycle > 0` (the gate actually caught something), all five DO fire: **`opus_review` 16/125, `test` 5/130, `i18n` 5/104, `contract` 2/81, `migration_audit` 1/38**. None is removed — each is a safety gate with demonstrated catches; removing any would lose real defect detection. The spec-level justification to keep them is exactly this `fix_cycle` evidence.

- **`daily-report.sh`** (operator-side) — gate table gains a **`Fired*`** column = terminal fail/block/warn OR `fix_cycle > 0`, sorted by it. This is the honest "is this gate doing anything?" metric; the old fail-only view hid the resolved catches and made live gates look dead. (e.g. `specialist_audit` Fired 39, `pr_size` 36, `dep_vuln` 21, `opus_review` 16 — all previously showed Fail 0.)

#### §19 anti-pattern family consolidated

- **`anti-patterns.md`** — the sprawling §19 / §19a–§19f (7 entries, heavy repetition of the same root cause) collapsed into **one principle** ("the orchestrator skips inline spec-bash and fabricates output; every side-effect must be wrapper-owned with a tell") **+ a compact 6-row instance table** (id · side-effect→wrapper · anti-fabrication tell · bypass diagnostic · tier-3 hook). Legacy ids (19a–19f) are retained as table-row tags so existing `§19c`-style cross-references still resolve. The table adds a **Tier-3 hook** column noting which instances now have a runtime backstop (19a metrics → Stop hook; 19d/19f size → PreToolUse hook). No information lost; ~70 lines → a principle + table.

#### Wrapper boilerplate — assessed, extraction declined (intentional)

Reviewed the 6 wrappers (1036 LOC) for a shared `scripts/_wrapper-lib.sh`. Found the only duplication is trivial or localized: `die`/`iofail` are 1-line definitions (5/3 wrappers), and the lone substantial repeat is an 8-line schema-validate python block in exactly 2 wrappers (`config-init`, `config-ensure-metrics`). **Decision: do not extract.** Rationale — (1) the wrappers' **self-containment is a documented design value** (`plan-size-check`: "duplicated here ON PURPOSE so the wrapper is self-contained"); each is independently inspectable/copyable, which matters for an audit-sensitive tool; (2) a sourced lib adds a "lib not found / not sourced" failure mode to the Phase 0 critical path (`config-init`/`config-ensure-metrics`) to save ~30 lines; (3) the schema-validate is already best-effort (skips when `jsonschema` is absent). Extracting would be cargo-cult DRY against an explicit principle. SKILL.md top-level anti-pattern list + README reviewed for consistency with the consolidation (legacy §-references still resolve; no edits needed beyond the P0–P3 additions).

### Hook-based enforcement (tier 3, OPT-IN) (P3)

The wrapper tier (tier 2) is strong but model-dependent: if the orchestrator never invokes a wrapper, it can't fire (~18% compliance on the internal-only plan-size check, higher on user-visible ones). For the two checks that MUST happen every task, add **Claude Code hooks** — scripts the runtime executes itself, independent of the model. Opt-in and off by default; the skill degrades cleanly to tiers 1+2 without them.

#### Added

- **`skills/do/hooks/do-metrics-stop-gate.sh`** (NEW, Stop hook) — makes Phase 4.11 metrics emission non-bypassable at the runtime level. Self-scopes to `/do` runs (no-op unless the last assistant message carries the `Complete. Branch:` / `Models: orchestrator=` announce signature — safe to register globally). Blocks the stop (`{"decision":"block",...}`) when a `/do` finalize lacks a `Metrics:` line OR the `Metrics: <N> entries in <path>` claim isn't backed by the file (path missing, or `wc -l < path` < N) — promoting the wrapper's pre/post line-count tell to harness enforcement. `stop_hook_active` loop-guard; terminal states (`not configured`, `APPEND FAILED`) not re-blocked.
- **`skills/do/hooks/do-plan-size-pretooluse.sh`** (NEW, PreToolUse hook, matcher `Task`) — surfaces the Phase 2.0 plan-size verdict at implementer-spawn time. Non-blocking by design (injects `additionalContext`, never denies). Acts only on the `PLAN-SIZE: files=N lines=M complexity=C` marker the Phase 2 spawn prompt now emits; any other `Task` spawn → no-op. Self-locates `plan-size-check` via `$0`.
- **`skills/do/hooks/settings.with-hooks.json`** (NEW) — the opt-in settings fragment to merge into `~/.claude/settings.json` or a project `.claude/settings.json`.
- **`references/hooks.md`** (NEW) — documents the three enforcement tiers (soft instruction → structural-coupling wrapper → harness hook), which checks each covers, the two shipped hooks, install instructions, and the global-scope caveat (why both hooks self-scope).

#### Changed

- **`install.sh`** — new opt-in Step 6.5 (default **No**): merges the hooks into `~/.claude/settings.json` idempotently (checks for the exact command before adding, backs up first, validates JSON, refuses on un-parseable existing settings). Never a mandatory mutation; respects the `ENABLE_HOOKS` env for non-interactive installs.
- **`phase-2-implementation.md`** — Sonnet-spawn prompt Flags section emits the `PLAN-SIZE:` marker; §2.0 documents the optional PreToolUse backstop.
- **`SKILL.md`** progressive-disclosure table + **README** gain a hooks section / doc-map entry. **`.github/workflows/lint.yml`** json-syntax step now also validates `settings.with-hooks.json` (kept out of the `examples/*.json` schema-validation glob — it's a settings file, not a do-config).

#### Tested

Both hook scripts validated with mock stdin across all branches (Stop: non-/do no-op, valid/missing/file-missing/count-mismatch/not-configured/loop-guard; PreToolUse: PASS/REBUMP/SPLIT-REQUIRED injection + no-marker no-op). The settings merge tested for idempotency + key-preservation + invalid-JSON refusal. Hooks were NOT registered into the live session (a Stop hook there would gate the session itself) — runtime registration is documented for the user to enable.

## [0.7.0] — 2026-05-29

**Measurement integrity + a PR-size ceiling that actually blocks.** This cycle acts on a 225-entry audit (May 14–24, since extended to 254 live entries). Two of the three big findings were that the metrics *instrument itself* was lying — the `gates` vocabulary had drifted to ~110 names for ~19 real gates, and the single `calibration` field conflated "missed a real defect" with "didn't predict diff size" (39% of "false positives" were pure `pr_size=warn` noise). The third was the real defect: tasks were too big and the size ceiling was never enforced — 8 PRs added >2000 lines and every one shipped as `pr_size=warn` despite `block_lines=2000`.

**Release-level summary** (detail in the entries below + the post-v0.6.0 follow-ups folded in from the prior `[Unreleased]`):

- **Controlled vocabulary for `gates` (P1).** `metrics-append` normalizes gate keys (alias map → 19 canonical names) + statuses (→ `pass|warn|fail|block|skipped`), coerces scalar values, merges collisions by severity, and **preserves** (never rejects) unknown task-specific keys with a `noncanon=` tell. Measured on 254 live entries: 60 raw synonym buckets → 19 canonical + a few one-offs.
- **Split calibration (P2).** New `calibration_defect` (real code defect missed — the de-confounded primary signal) + `calibration_size` (diff-size prediction) dimensions alongside the back-compat `calibration`. Flags default to `n_a`; the orchestrator computes both per the §4.11 logic.
- **PR-size ceiling that blocks (P0).** `plan-size-check` H bucket got a real ceiling (25 files / 1500 lines) so `SPLIT-REQUIRED` fires instead of being dead code. New `pr-size-check` wrapper owns the Phase 3.0 PASS/WARN/BLOCK decision; **BLOCK exits 3** (hard halt → draft PR + `blocked`), so the orchestrator can no longer downgrade block to warn.
- **Same structural-coupling invariant throughout.** Every new check is a wrapper that owns the decision + the literal strings + an anti-fabrication tell (gate rename counts, computed split counts, breach/overage lists); the spec only invokes + dispatches.

### Metrics — controlled vocabulary for `gates` keys + statuses (P1)

Audit of 225 canonical entries (May 14–24) found the `gates` JSON had **~110 distinct keys for ~19 real gates** — `test`/`tests`/`test_gate`/`go_test`, `ui`/`ui_gate`/`visual_verify`/`visual_smoke`, `i18n`/`i18n_gate`, `contract`/`contract_gate`, `dep_vuln`/`dep_vuln_go`/`dep_vuln_pnpm`, `type_check`/`type-check`/`lint_typecheck` — plus equally-drifty statuses (`skip`/`n/a`/`n-a`/`na`/`n_a`, scalar `pass`/`true`/`ok`/`clean`). Same data-quality class as the v0.6.0 `outcome`-enum drift: every synonym splits one gate's stats across buckets, so the daily-report gate-failure-rate was noise. `outcome` got a controlled vocabulary in v0.6.0; `gates` had none until now.

#### Changed

- **`metrics-append` — gate-vocabulary normalization** (jq step before the entry is built). Defines a 19-name canonical set (`build`, `lint`, `type_check`, `test`, `dep_vuln`, `pr_size`, `i18n`, `contract`, `ui_gate`, `migration_audit`, `specialist_audit`, `opus_review`, `public_docs`, `secret_scan`, `diff_scan`, `plan_size`, `codeowners`, `stale_main`, `concurrent_edit`) + a ~70-entry alias map. Known aliases are renamed to canonical; scalar gate values (`"pass"`, `true`) are coerced to `{status: …}`; statuses normalize to `pass|warn|fail|block|skipped` (with `skip`/`n/a`/`na` → `skipped`, prefix-matching for `skipped_no_ui`-style suffixed statuses). Key collisions after aliasing (e.g. `test` + `go_test`) merge by max severity (block>fail>warn>pass>skipped).
- **Policy: warn-normalize, not hard-reject.** Gate keys are an OPEN set (legitimate task-specific checks like `idempotency_cache_correct` exist), unlike the closed `outcome`/`complexity` enums. Unknown keys are **preserved verbatim** (entry NOT rejected — rejecting on the announce-coupled critical path would tempt the orchestrator to drop real gate signal or fabricate) but counted + surfaced. The closed enums stay hard-reject.
- **Anti-fabrication tell extended.** The OK line now ends `gates=<C> renamed=<R> noncanon=<list|->` — the orchestrator can't reproduce the rename count / non-canonical list without running the wrapper against the actual `--gates-json`. Non-canonical keys + statuses also print a `NOTE gate-normalize:` line to stderr. The `post=` sed-extraction in §4.13 is unaffected (verified).
- **`phase-4-finalize.md` §4.11** — new "Gate vocabulary (controlled, OPEN set)" subsection with the canonical table (key → phase) + alias/normalization rules. **`config-schema.md`** — JSONL example `ui`→`ui_gate`; controlled-vocabulary note added (+ the specialist-install confounder warning). **`phase-3-review.md`** — metrics-capture intro points to the canonical list. **`anti-patterns.md` §19e (NEW)** — gate-name fabrication documented as the same class as outcome-enum drift.
- **`daily-report.sh`** (operator-side, not shipped) — gate-failure-rate now buckets by canonical name (mirrors the wrapper alias map), so the 254 historical entries aggregate correctly (60 raw synonym buckets → ~19 canonical + a few task-specific one-offs). Also hardened: input parsing tolerates malformed JSONL lines (`fromjson?` instead of a fragile `jq -s` slurp that crashed on one corrupt line), and the `VALID_JSON`/bypass filters no longer crash when `self_review` is a non-object (2 such entries existed).

#### Measured impact (254 live entries)

- Gate buckets in the daily report: **60 → 19 canonical + ~8 task-specific one-offs**. `test` consolidated to 1 fail / 106 pass (was scattered across `test`/`tests`/`test_gate`/`go_test`/`go_test_race`/`unit_tests`/…), `specialist_audit` to 2/54, `dep_vuln` to 0/64, `pr_size` to 0/144.
- Confirms P4's "never-fails" gate candidates with clean data: `opus_review` 0/124, `i18n` 0/76, `contract` 0/39, `migration_audit` 0/19.

### Metrics — split self-review calibration into defect vs size (P2)

The single `self_review.calibration` field conflated two unrelated failures: *Sonnet missed a real code defect* and *Sonnet didn't predict diff size*. Audit of 254 live entries: of **44 `false_positive` entries, 17 (39%) fired ONLY `pr_size=warn`** — the code was fine, the diff was just big. Counting those as "self-review missed something" inflates the FP rate and misleads skill iteration (you'd tighten the self-review prompt when the actual problem is routing/size).

#### Added

- **`metrics-append` — `--sr-calibration-defect` + `--sr-calibration-size` flags** (enum `accurate|false_positive|false_negative|skipped|n_a`, default `n_a`). Recorded under `self_review.calibration_defect` / `self_review.calibration_size`. The legacy `self_review.calibration` is **unchanged** (back-compat) — callers that don't pass the split flags get `n_a` for both, correctly read as "split not computed; use the combined field." Enum-validated + asserted in the defense-in-depth schema gate.
  - `calibration_defect` — did Phase 3 find a real CODE defect (any non-`pr_size` gate fail/block, or a specialist blocker) that Sonnet claimed `ready` over? This is the **de-confounded primary calibration signal** going forward.
  - `calibration_size` — did Sonnet predict the diff size? (`pr_size` warn/block vs Sonnet's `size_assessment`/Phase 2.0 rebump). `n_a` when the `pr_size` gate didn't run.

#### Changed

- **`phase-4-finalize.md` §4.11 calibration logic** — rewritten to compute all three values (legacy + the two split dimensions) with explicit, copy-able pseudocode; §4.13 + the §4.11 canonical invocation now pass the two new flags.
- **`phase-2-implementation.md` Self-Review** — new step #8 instructs distinguishing a CODE deferral from a SIZE deferral; the completion-report format gains a machine-readable `size_assessment: fits|exceeds` line and splits `Deferred:` into `Deferred (code)` / `Deferred (size)` so the orchestrator computes `calibration_size` from a signal, not prose.
- **`config-schema.md`** — JSONL example shows the three calibration fields (+ the previously-missing `claimed_status`); `capture_self_review_calibration` description documents the split; **specialist-install confounder** documented (FP rates not comparable across the ≈2026-05-17 plugin-install boundary — pre-install cohorts had zero specialist review).

#### Why it matters

`calibration_defect` is now the metric to watch for self-review-prompt tuning (it ignores size noise); `calibration_size` measures whether Phase 0 line-aware routing + Phase 2.0 plan-size check + the P0 PR-size ceiling actually predict diff size. The two move independently — conflating them is why the v0.6→post-v0.6 "FP regression 15%→33%" looked alarming when it was mostly more reviewers + diff-size noise.

### PR-size ceiling that actually blocks + SPLIT-REQUIRED that actually fires (P0)

The single biggest quality gap: tasks were too big and the size ceiling was never enforced. Audit (254 entries): H-complexity diff median 855 lines, p90 3103, max 4166; **8 PRs added >2000 lines and ALL shipped as `pr_size=warn`, never `block`**, despite `block_lines=2000` (i807 3587L, i1167 3669L, i1100 2067L, i1168 2053L). Two root causes — (1) Phase 2.0 `plan-size-check`'s H bucket was effectively unbounded (`MAX_FILES=999 / MAX_LINES=99999`), so the `SPLIT-REQUIRED` branch was dead code; (2) Phase 3.0's PR-size gate described `block → STOP` as inline spec text the orchestrator treated as advisory and degraded to `warn`.

#### Changed

- **`plan-size-check` — real H ceiling**: `MAX_FILES 999→25`, `MAX_LINES 99999→1500`. `SPLIT-REQUIRED` now fires for genuinely-huge H plans (verified: 30 files / 4000 lines → `SPLIT-REQUIRED — … Split into ~3 sub-issues`). The H cap sits BELOW the Phase 3 `pr_size` block default (2000/50) on purpose: plan-time catches obviously-too-big before an hour of Sonnet; the 1500→2000 band is the estimate-error margin Phase 3 warns on; >2000 actual is the hard block. The suggested split count is computed (ceil of the worse overage) and doubles as an anti-fabrication tell.
- **`phase-2-implementation.md` §2.0 SPLIT-REQUIRED branch** — now actionable (present the suggested count, offer to file N sub-issues, re-run per slice) instead of a vague "ask user to split" that never triggered.

#### Added

- **`skills/do/scripts/pr-size-check`** (NEW wrapper) — the ONLY supported way to produce the Phase 3.0 PASS/WARN/BLOCK decision. Takes the real `git diff` `--lines`/`--files` (+ optional config threshold overrides; defaults baked in: warn 800/20, block 2000/50). Moves the verdict out of orchestrator judgment — it passes numbers, the wrapper decides. **BLOCK exits 3** (a hard halt) so the gate cannot degrade to advisory; PASS/WARN exit 0. Output carries `breached: [..]` + `+N lines/+N files` overage as the anti-fabrication tell. Same structural-coupling pattern as `plan-size-check`/`check-caveman`. (Clean exit codes also make it directly usable as a P3 `PreToolUse` hook on PR creation.)
- **`phase-3-review.md` §3.0** — rewritten to invoke `pr-size-check` + dispatch on the output/exit-3; BLOCK routes to the draft-PR + `blocked`-label escalation (same path as Phase 3.6 3-cycle exhaustion), `outcome=blocked`. "block is not advisory" called out explicitly.
- **`anti-patterns.md` §19f (NEW)** — "composing the Phase 3.0 PR-size verdict by hand" documented as the same fabrication-skip class as §19d (plan-size) / §19b (caveman). **§21** rewritten: block is a hard halt, never downgrade BLOCK→WARN to get a merge.

#### Docs

- **README** — new "PR-size ceiling" cheat-sheet row (warn/block thresholds + the plan-time/PR-time split). `examples/*.json` and the `config-init` auto-init preset were checked — neither encodes `pr_size`, so no threshold values needed updating (the wrapper defaults match config-schema.md).

#### Expected impact (measure at next audit)

- H tasks planning >1500 lines / >25 files re-route to SPLIT-REQUIRED at Phase 2.0 instead of producing a 3000–4000-line PR.
- PRs whose actual diff exceeds block thresholds halt at Phase 3.0 (`outcome=blocked`, draft PR) instead of shipping as `ready_for_review` with `pr_size=warn`. The 8 historical >2000-line `warn` PRs would all have blocked.

### Post-v0.6.0 audit follow-ups — 4 fixes from 32-entry data

After v0.6.0 deployed (May 21, 11:23Z), 32 canonical post-deploy entries accumulated in ~2.5 days. Audit (see [previous CHANGELOG entry](#phase-20-plan-size-check--observability-via-complexity_rebumped_from)) showed:

- Schema fixes worked perfectly (outcome 100% canonical, 0% negative cycle times, 100% orchestrator captured)
- FP rate REGRESSED from 15% → 33% with **0 Phase 2.0 re-bumps** despite **16 of 21 M-tasks** shipping >600 lines or >8 files
- 7 bypass entries with fabricated free-form shapes
- 1 case (i1023) with stub `specialist_iterations` (4 cycles all empty)

Four fixes, all in this [Unreleased] cycle:

#### Added

- **`skills/do/scripts/plan-size-check`** (NEW wrapper) — Phase 2.0 plan-size check moved out of inline spec bash into external wrapper. Same fabrication-avoidance pattern as `check-caveman` v3. Thresholds + bucket caps live ONLY in the wrapper. Outputs one of three structured decision lines: `Phase 2.0: PASS — ...`, `Phase 2.0: REBUMP <C>→H — ...`, `Phase 2.0: SPLIT-REQUIRED — ...`. Spec uses `case "$PLAN_SIZE_LINE" in` to dispatch — empty `$PLAN_SIZE_LINE` (wrapper skipped) matches nothing = visible bug. Anti-fabrication tell: output includes actual computed cap values for the bucket.

#### Changed

- **`metrics-append` — `--specialist-iterations-json` anti-stub validation** — reject if ANY cycle has `auditors=[]` AND `approvers=[]` AND `blockers=[]` (the i1023 fabrication pattern: sub-agent fabricated a 4-cycle structure with all-empty fields to satisfy field-present requirement). Real cycles MUST have at least `auditors` populated. If specialists genuinely didn't run for a cycle — omit the cycle, don't fabricate placeholder shape.
- **`phase-2-implementation.md` §2.0** — inline plan-size bash replaced with wrapper invocation + `case "$PLAN_SIZE_LINE"` dispatch. Explanation paragraph about WHY (the 0-rebump audit finding).
- **`phase-2-implementation.md` Self-Review section** — new pre-claim step (#6): `git diff main...HEAD --stat` and check against routed bucket caps. If diff exceeds M-bucket caps (600 lines / 8 files), return `claimed_status: deferred` with re-route hint instead of `ready`. Second-layer check using actual post-write diff, catches what Phase 2.0 plan-time check missed.
- **`anti-patterns.md` §19a** — added "Observed bypass shapes" subsection documenting 7 post-v0.6.0 bypass cases with specific field-name patterns (`ts`/`timestamp`, `insertions`/`deletions`, `verdict`/`outcomes`/`phase_4_status` invented). Confirms bypass = direct Write/echo, not wrapper misuse.
- **`anti-patterns.md` §19d (NEW)** — "Composing Phase 2.0 plan-size check decision by hand". Documents the 0/32 production observation. Same diagnostic pattern as §19b (caveman): missing structural tell in announce = wrapper skipped.

#### Expected impact (measure at next audit, ~T+50 fresh entries)

- **Phase 2.0 rebump rate >0%** for M-tasks shipping >600 lines (current: 0/16 expected, target: should fire on all 16)
- **FP rate** for M complexity should drop below baseline 12% once re-bumped tasks get H-tier specialist plan-review
- **Specialist iterations** no longer have stub shapes (i1023-style rejected at wrapper)
- **Bypass rate** still likely 10-20% — wrappers can't force sub-agents who don't call them; mitigation is daily-report tripwire visibility (already restored) and adding §19a observed shapes as the cookbook for code-review

### Phase 2.0 plan-size check — observability via `complexity_rebumped_from`

The v0.6.0 Phase 2.0 plan-size sanity check re-routes tasks to H when Sonnet's plan exceeds the bucket's caps, but the re-route fired silently — no field in the metrics entry captured that it happened. Result: we can't measure how often the check fires, on which transitions, or whether it correlates with lower FP rates. Adding observability now (cheap, +20 LOC) so the v0.6→v0.7 audit has the data.

#### Added

- **`metrics-append` — new `--complexity-rebumped-from {T|L|M}` flag** (optional, omit when no re-bump). Validates: enum is T|L|M (not H — H means already at top), and `--complexity-rebumped-from` cannot equal `--complexity` (re-bump means routed > original). Recorded in entry as top-level `complexity_rebumped_from` key, **omitted entirely** when no re-bump (keeps entries lean — only the rare cases get the field).

#### Changed

- **`phase-2-implementation.md` §2.0 plan-size check bash** — sets `COMPLEXITY_REBUMPED_FROM="$COMPLEXITY"` before bumping `COMPLEXITY` to H. New "Observability" paragraph explains the downstream metric.
- **`phase-4-finalize.md` §4.13 invocation** — passes `${COMPLEXITY_REBUMPED_FROM:+--complexity-rebumped-from "$COMPLEXITY_REBUMPED_FROM"}` (optional flag, no-op when var unset — the common case).
- **`config-schema.md` JSONL example** — adds `complexity_rebumped_from` to the documented Tier-1 entry shape with usage notes.

#### What this unlocks

Downstream analysis can now answer:
- "How often does Phase 2.0 fire?" — count of entries with the field present
- "Which Phase 0 bucket is most often wrong?" — distribution of T/L/M values in the field
- "Do re-bumped tasks have lower FP rate than tasks that stayed in their original bucket?" — comparison metric
- "Is Phase 0 routing improving over time?" — rate of re-bumps declining = Phase 0 estimates getting better

If after 100+ post-v0.6.0 entries the re-bump rate is <5%, line-aware Phase 0 routing is working as designed. If 15-25%, plan-size check is doing the heavy lifting. If >25%, Phase 0 estimate heuristics need revisiting.

## [0.6.0] — 2026-05-21

Phase 0 hardening cycle. 10 commits over 7 days (May 14–21) added 4 structurally-coupled wrappers (`check-caveman`, `config-init`, `config-ensure-metrics`, plus the existing `metrics-append` got v2), zero-touch project setup (auto-init of `.claude/do/config.json` with specialists + metrics presets), and line-aware complexity routing. Every change in this release traces to a documented production failure — see per-entry "Origin" / "Production-confirmed" / "Postmortem" sections below.

**Release-level summary** (detail in entries below):
- **4 wrappers, 4 structural-coupling tells.** Each announce token (`Caveman:`, `Config:`, `Metrics config:`, `Metrics:`) comes from wrapper stdout. Wrappers include a "tell" the orchestrator can't fabricate without running them (resolved path, probed-paths list, written file path, log line-count delta). Off-line copies become detectable visible bugs.
- **Zero-touch project setup.** First-run `/do` in a project auto-generates a working config (tracker from git remote, locale from `$ARGUMENTS`, specialists preset, tier-1 metrics preset). Existing configs missing `metrics` get patched idempotently.
- **Line-aware routing.** Phase 0 estimates files AND lines; refactor-keyword bumper for scope-multiplying changes; Phase 2.0 plan-size sanity check re-routes when Sonnet's plan exceeds bucket caps. Catches the May 21 burst of 6 underestimated Medium-tasks before they ship 1000+ line PRs.
- **Metrics enum cleanup.** `outcome` strict 3-value enum, timestamp ordering gate, orchestrator capture — addresses 121-entry audit that found 16 outcome variants and 36% negative cycle times.
- **Phantom plugin removed.** `frontend-excellence` (aspirational placeholder, not on any public marketplace) replaced with real `ui-design` + `javascript-typescript` (wshobson/agents).

### Phase 0/2 — line-aware complexity routing + Phase 2 plan-size sanity check

Postmortem of 13 false-positive cases on 2026-05-21 (10 of 13 in `miro-rooms-rentals`, all bursting in a 5-hour window) showed a consistent pattern: tasks routed Medium that actually produced 942–1859 lines / 9–31 files. The existing complexity matrix only cared about file count; line count was never considered. Phase 0 estimated `Files: ~7` correctly but ended up at 16+. `pr_size=warn` fired at Phase 3 (correctly!) but the wrapper didn't block because warn ≠ block, and `block_lines` defaults are tuned for H-bucket sizes (1500–2000 lines), making them no-ops on M tasks that wrote 1000+ lines.

Two complementary fixes — catch at routing time (cheap) and catch at plan time (when routing missed).

#### Changed

- **`phase-0-setup.md` complexity matrix** — added explicit "Lines added (est)" column with per-tier caps (T ≤50, L ≤200, M ≤600, H >600). New rule: "estimate BOTH files AND lines, pick the higher bucket." Includes references to the May 21 audit so the rule's origin is traceable.
- **`phase-0-setup.md` — refactor-keyword bumper** — new section. If `$ARGUMENTS` contains `refactor` / `rename` / `restructure` / `unify` / `consolidate` / `migrate <X> to <Y>` / `rewrite` / `extract <module>` / `split <module>` — prefer one tier higher. Refactors compound across the codebase even when "only N files" are touched directly.
- **`phase-0-setup.md` announce template** — adds `EstLines: ~{L}` next to `Files: ~{N}` so the estimate is visible to the user at routing time (and metrics-logged for future audit accuracy).

#### Added

- **`phase-2-implementation.md` §2.0 — Plan-size sanity check (NEW)** — runs once per Sonnet spawn, immediately after the approved plan is in and BEFORE the prompt is constructed. Compares planned files + estimated lines against the routed bucket's caps; if exceeded:
  - **Bumps to H** (re-runs Phase 1 issue update + Phase 2 specialist plan-review with new tier) when current is T/L/M
  - **Aborts and asks user to split** when current is already H (single PR is the wrong shape for the task)
  
  The old §2.0 (Stale-main check) is renumbered to §2.0.5. Check is cheap (numeric comparison) and runs ONCE per spawn — no per-iteration cost.

#### Why both at Phase 0 AND Phase 2

Phase 0 estimates are pre-exploration — the orchestrator hasn't seen the actual file list yet, just the user's task description. The estimate can be off by 2-4× for refactor-class tasks. Phase 2 re-checks against the now-concrete approved plan (file list is fixed by that point). Plan-size check at Phase 2 catches what Phase 0 estimate missed.

#### Expected impact

The May 21 postmortem 6 FP cases:
| ref | files (actual) | lines added | At Phase 0 (file-count rule alone) | At Phase 0 (NEW line-est rule) | At Phase 2.0 (plan-size check) |
|---|---|---|---|---|---|
| i968 | 16 | 1859 | H (>9 files) | H | (already H) |
| i970 | 9 | 1345 | H | H | (already H) |
| i963 | 13 | 1248 | H | H | (already H) |
| i961 | 28 | 1169 | H | H | (already H) |
| i969 | 21 | 1014 | H | H | (already H) |
| i959 | 31 | 942 | H | H | (already H) |

All 6 should have been routed H from Phase 0 by **the existing file-count rule** (>9 files = H). The Phase 0 announce showed `Files: ~N` < 9 for all of them — meaning the orchestrator's estimate was wrong, AND the line-estimate column would NOW be the secondary check that catches it (942–1859 >> 600 cap). Phase 2 plan-size check is the third layer: even if both Phase 0 estimates miss, by Phase 2 the plan has the real file list and the check fires.

### Phase 4.12 — `metrics-append` hardening: outcome enum, timestamp ordering, orchestrator capture

Audit of 121 canonical entries (May 14–21) surfaced three concrete data-quality issues that escaped the existing v0.6 wrapper:

1. **`outcome` field — 16 distinct values for what should be 3.** Wrapper accepted any non-empty string. Production drift: `success`/`completed`/`shipped`/`ok`/`pr_opened`/`pr_open`/`ready_for_review` for ~92 entries, plus **9 spelling variants of "merged"** (`merged_pending`, `merged_pr_open`, `merged_or_pr_open`, `merged_ready`, `merged_to_main_or_pr_open`, `merged_or_pushed`, `merged_open`, `merged_via_pr`). Cross-run aggregation (merge rate, blocked-PR analysis) required manual normalization on every dashboard.

2. **36% of entries had `ended_at < started_at`** (median negative delta: -2.5 hours). Sub-agents captured both timestamps at Phase 4.13 using inconsistent timezone handling or back-computing `started_at` incorrectly. Cycle-time analysis on a metric where 36% of values are nonsensical is useless — real median cycle time (23 min) only computable after filtering negatives.

3. **`orchestrator` field never captured.** All 121 canonical entries had it absent or `"?"`. Spec mandates capture per [SKILL.md notation](skills/do/SKILL.md#notation) — the Co-Authored-By footer reads model from session metadata for the same reason, but metrics-append had no flag for it.

#### Changed

- **`scripts/metrics-append` — strict outcome enum.** Regex `^(merged|ready_for_review|blocked)$`. Rejects everything else with a verbose error message explaining the canonical mapping (avoid replaying the audit).
- **`scripts/metrics-append` — timestamp ordering gate.** Both `--started-at` and `--ended-at` parsed via `date -j -u -f`. Reject if `ended_epoch < started_epoch`. Error message points at the most common cause (capturing both at Phase 4.13 retroactively) and the fix (capture STARTED_AT at Phase 0 entry).
- **`scripts/metrics-append` — `--orchestrator` flag.** Optional with default `"opus"` (spec mandates orchestrator=opus). Accepts `opus`, `opus-N.M`, plus `haiku`/`sonnet` for testing. Regex-validated. Schema gate (jq) also asserts the field exists.
- **`phase-4-finalize.md` §4.13 invocation** — adds `--orchestrator` passthrough (`${ORCHESTRATOR:+...}` form so it's optional for callers that don't track model version).
- **`phase-4-finalize.md` §4.11 (Step 2 area)** — new "Computing `$OUTCOME`" block. Explicit decision tree using `gh pr view --json mergedAt` and `$BLOCKED` flag, NOT free-form guessing. Plus "Computing `$ORCHESTRATOR`" and "Computing `$STARTED_AT`" guidance with anti-patterns called out.

#### Migration

Existing 121 canonical entries remain valid for retrospective analysis if you filter out the 36% with negative cycle times and bucket the 16 outcome variants manually. Fresh entries from this version forward will have uniform enum + positive deltas + non-null orchestrator.

### Phase 0.2 — caveman detect v3: external wrapper + probed-paths tell

**Third iteration on the same fabrication.** Production confirmed today (2026-05-17, lea-web run): orchestrator announced `Caveman: NOT INSTALLED — install: curl ...` while caveman was installed at path #1. The v2 fix had moved the line template into the bash literal (the `CAVEMAN_LINE="..."` assignment) — but the literal is still visible to the orchestrator at parse time, so it copy-pasted from there without running the bash. Same root failure, one indirection deeper.

v3 structural fix: detection moved to `scripts/check-caveman` wrapper. The spec now contains zero copyable form of either announce string — only `CAVEMAN_LINE="$(~/.claude/skills/do/scripts/check-caveman)"`. Plus a runtime-only **anti-fabrication tell**: the NOT-INSTALLED form includes `(probed: <P1>, <P2>, <P3>, <P4>)` — the actual paths checked, built from the wrapper's internal array, NEVER written in the spec. Orchestrator skipping the wrapper cannot include this suffix without inventing path names, which is a visible bug.

#### Added

- **`skills/do/scripts/check-caveman`** — zero-arg bash wrapper, exits 0 always. Two output forms:
  - `Caveman: ACTIVE (path: <resolved-path>)` — when any of 4 candidate paths has `SKILL.md`
  - `Caveman: NOT INSTALLED (probed: <P1>, <P2>, <P3>, <P4>) — install: curl …` — full probed-paths suffix as anti-fabrication tell

#### Changed

- **`phase-0-setup.md` Step 2** — replaced 13-line inline bash with 2-line wrapper invocation. Removed all prose descriptions of the canonical announce templates (only wrapper outputs them now). Explanation of WHY a wrapper (vs inline) is now part of the step text.
- **`anti-patterns.md` §19b** — rewritten as v3 entry. Documents both 2026-05-17 production fabrications (miro-rooms + lea-web). Diagnostic clause: announce missing `(path: ...)` or `(probed: ...)` suffix → orchestrator skipped the wrapper.

#### Why three iterations

Each version removed the previous round's copyable surface, orchestrator pivoted to the next-most-visible literal:
- **v1** (initial): prose bullets ("- ACTIVE → ...", "- NOT INSTALLED → ...") with full strings. Orchestrator copied from bullets.
- **v2** (this CHANGELOG, earlier): bullets removed, strings in `CAVEMAN_LINE="..."` bash assignments. Orchestrator copied from assignments.
- **v3** (now): wrapper-only. Spec has `$(wrapper)` invocation, zero string literals. Plus probed-paths tell makes off-line copies detectable even if a future orchestrator's prompt-cached spec is stale.

The general lesson: **structural coupling works only if there's no literal copy of the output in the spec for the agent to read.** Wrappers achieve this; inline bash with output-string literals does not.

### Phase 0.6 — telemetry auto-config (new + existing paths)

Sibling change to the specialists preset (below). Same friction: every new project gets a config without `metrics` block → Phase 4.11 silently no-ops (per spec line 205: "unset/null log_path → silently skip"), and the user has no telemetry until they remember to add the block by hand. Worse, EXISTING configs that pre-date the metrics rollout (or were copied from minimal example) also lack the block — Phase 0 had no way to surface or remediate this.

Fix covers both paths:
- **New configs (Step 4 auto-init)**: `config-init` now emits the documented tier-1 `metrics` preset by default (same flag pattern as `--specialists` — opt-out via `--no-metrics`).
- **Existing configs (Step 1 found-case)**: new `config-ensure-metrics` wrapper runs on every `/do` against a found config. If `metrics` key is absent → patches in the default preset + stamps `_meta` with `last_patched_*` provenance. If `metrics: {...}` → leaves alone. If `metrics: null` (explicit opt-out) → respects.

#### Added

- **`skills/do/scripts/config-ensure-metrics`** — bash wrapper, idempotent, named-arg CLI (`--config <path>`). Three outcomes via stdout (same structural-coupling pattern as `metrics-append` / `config-init`):
  - `Metrics config: ALREADY CONFIGURED in <path>` — `metrics: {object}` present, no change
  - `Metrics config: EXPLICIT OPT-OUT in <path> (metrics: null)` — key present with null value, user intent respected
  - `Metrics config: AUTO-ADDED to <path>` — key was absent, default tier-1 preset patched in via atomic tmp+rename
  - Refuses: missing `--config`, invalid JSON, senior-by-default repo itself (defense-in-depth — config dir → repo root walk + skill-source check), `jq` not installed. Schema-validates patched config against `config.schema.json` before write if `jsonschema` available.
- **`config-init` — new `--metrics {default|none}` flag** (default: `default`). When `default`, emits the documented tier-1 preset alongside specialists. `_setup_notes` extended to describe metrics behavior.

#### Changed

- **`phase-0-setup.md` Step 1 (found-case)** — added telemetry-ensure block: `config-ensure-metrics` called on the loaded config unless `--no-metrics` in `$ARGUMENTS`. `$METRICS_CONFIG_LINE` captures wrapper stdout (3 forms above + `SKIPPED (--no-metrics)` + `PATCH SKIPPED — <reason>` for refuse paths).
- **`phase-0-setup.md` Step 4 auto-init bash** — detects `--no-metrics` in `$ARGUMENTS`, passes `--metrics default|none` to `config-init`. After wrapper call, mirrors metrics state into `$METRICS_CONFIG_LINE` (`INCLUDED in auto-init` / `SKIPPED (--no-metrics)` / `N/A (auto-init skipped)`) so the announce token is uniformly set regardless of which Step set it.
- **`phase-0-setup.md` Announce template** — added mandatory `$METRICS_CONFIG_LINE` placeholder alongside `$CAVEMAN_LINE` / `$CONFIG_LINE`. Same "DO NOT compose" guard.
- **`SKILL.md` advanced flags** — added `--no-metrics`.

#### The preset (matches `config-schema.md` documented defaults)

```json
"metrics": {
  "log_path": "~/.claude/do/metrics/{repo_slug}.jsonl",
  "include_phase_durations": true,
  "tier": 1,
  "capture_failure_details": true,
  "capture_self_review_calibration": true,
  "capture_specialist_iterations": true,
  "max_string_length": 500
}
```

Home-based log location (not in-repo) means a single `daily-report.sh` scanner can see telemetry from every project. `{repo_slug}` placeholder resolved by Phase 4.11 at write time per [`phase-4-finalize.md`](skills/do/references/phase-4-finalize.md).

#### Why a separate wrapper for the patch path (not extend `config-init`)

`config-init` refuses-on-exists by design — that contract is load-bearing (prevents accidental overwrite of user customizations). Adding a `--patch-mode` flag would erode it. Single-purpose `config-ensure-metrics` keeps the two operations cleanly separated: create-or-fail vs ensure-section-or-noop. Each operation is one wrapper, one announce line, one anti-pattern bucket.

### Phase 0.5 — `config-init` ships specialists preset by default

Companion change to the `frontend-excellence → ui-design` docs swap below. With the README + examples updated, the natural next question is: why does the auto-generated config still omit `specialists` entirely? Every new project gets a minimum-viable config and the user has to copy a snippet from `examples/` to wire up Phase 3 specialist review. The friction is exactly the same one that produced the original "no config" annoyance.

Fix: auto-init now emits the recommended `specialists` preset by default, referencing the 6 real plugins from the two recommended marketplaces. The wrapper's `_setup_notes` lists the exact `/plugin install` commands so users have a self-contained install path inside the generated file. If a plugin isn't installed, /do falls back to Opus inline review for that group — same graceful-degradation behavior as before.

#### Changed

- **`scripts/config-init`** — new `--specialists {default|none}` flag (default: `default`). `default` emits the preset; `none` omits the block. `_setup_notes` text dynamically extended with install hint when preset enabled.
- **`phase-0-setup.md` Step 4 auto-init bash** — detects `--no-specialists` in `$ARGUMENTS`, passes `--specialists default|none` to wrapper. Updated trailing paragraph to describe the new shape (`version + _meta + issue_tracker + issue_locale + specialists`).
- **`SKILL.md` advanced flags** — added `--no-specialists` opt-out (alongside `--no-config-init`).

#### The preset

| Group | Agents |
|---|---|
| `backend_plan` | `backend-development:backend-architect`, `backend-development:security-auditor`, `database-design:database-architect` |
| `frontend_plan` | `ui-design:design-system-architect`, `ui-design:ui-designer`, `javascript-typescript:typescript-pro` |
| `backend_audit` | `code-refactoring:code-reviewer`, `backend-development:backend-architect`, `backend-development:security-auditor` |
| `frontend_audit` | `code-refactoring:code-reviewer`, `ui-design:ui-designer`, `pr-review-toolkit:silent-failure-hunter`, `ui-design:accessibility-expert` |
| `migration_audit` | `database-design:database-architect` |

Universal across stacks — Phase 3 routing already gates by diff content (frontend_audit fires on FE diff, backend on BE diff, migration_audit on migration presence). Users on pure-FE or pure-BE projects pay nothing for the unused groups.

#### Why bake it into the wrapper

Same reason as the original `config-init` design (see CHANGELOG below): keep the wrapper as the single source of truth for what auto-init writes. If users hand-edit the generated file to add specialists, that's expected; if downstream tooling has to guess "did /do write specialists or did the user add them later?", it can't tell. Wrapper-emitted preset solves both — discoverable defaults + observable provenance via `_meta.auto_generated_by`.

### Docs — replace phantom `frontend-excellence` plugin with real `ui-design` + `javascript-typescript`

Production-confirmed: orchestrator on a real Next.js project hit "Specialists not available — falling back to Sonnet" because `config.specialists.frontend_*` referenced `frontend-excellence:react-specialist|component-architect|frontend-optimizer`, but **no public marketplace ships a `frontend-excellence` plugin** — it was an aspirational placeholder that propagated from this README + the multi-repo example config to user configs. Verified by searching `anthropics/claude-plugins-official` (35 plugins, no match) and `wshobson/agents` (81 plugins, no match), and by github code-search across the public ecosystem.

#### Changed

- **README.md** — Recommended-plugins section restructured: separated marketplaces (`anthropics/claude-plugins-official` + `wshobson/agents`) from plugins, added install commands (`/plugin marketplace add` + `/plugin install <name>@<marketplace>`), replaced `frontend-excellence` line with `ui-design` (3 agents — `ui-designer`, `design-system-architect`, `accessibility-expert`) and `javascript-typescript` (2 agents — `typescript-pro`, `javascript-pro`). Historical note explains the replacement.
- **`examples/multi-repo-go-react-config.json`** — `specialists.frontend_plan` and `frontend_audit` updated to use the real substitutes. Audit roster grew to 4 (was 3) by adding `ui-design:accessibility-expert` — a11y is a strong Phase 3 audit angle for FE-heavy diffs.
- **`skills/do/references/codeowners.md`** — example agent_map updated.
- **`skills/do/references/config-schema.md`** — example agent_map updated.

#### Substitution rationale

| Original (phantom) | Replacement (real) | Closest semantic match |
|---|---|---|
| `frontend-excellence:react-specialist` | `ui-design:ui-designer` | UI/UX review |
| `frontend-excellence:component-architect` | `ui-design:design-system-architect` | Design-system / component-architecture review |
| `frontend-excellence:frontend-optimizer` | `javascript-typescript:typescript-pro` | TS-pro for type-safety + modern JS; the closest "quality optimizer" on a Next.js stack |
| n/a (new in audit roster) | `ui-design:accessibility-expert` | a11y audit — strong Phase 3 signal for FE |

#### Why this didn't bite earlier

The skill's fallback ("Opus inline review when specialist not available") is silent and works correctly. Users would just see slightly less parallelism and assume that was the design. Production observation surfaced the issue when the orchestrator narrated "Specialists not available" — that string isn't even in the spec; it's what sub-agents say when `Agent(subagent_type=<missing>)` fails. The bug wasn't broken behavior, it was misleading docs.

### Phase 0.4 — auto-init: locale detection + tighter `$CONFIG_LINE` contract

Production observation from the v0.3 auto-init: orchestrator ran the wrapper with default `--issue-locale en`, noticed the repo was Russian-speaking (Cyrillic in `$ARGUMENTS` + assumptions), post-edited the generated config to flip `issue_locale: en → ru`, and appended `" (patched issue_locale=ru)"` to `$CONFIG_LINE` in the announce. The patch itself was correct adaptation; the channel was wrong — `$CONFIG_LINE` is meant to be exactly what the wrapper emitted, augmenting it with free-form suffixes breaks structural coupling and sets precedent for arbitrary post-edits.

#### Changed

- **`phase-0-setup.md` Step 4 auto-init bash** — now detects `$ISSUE_LOCALE` from `$ARGUMENTS` before calling the wrapper: explicit `--issue-locale=<code>` wins; otherwise Cyrillic → `ru`, Hiragana/Katakana/CJK Unified Ideographs → `ja`, Hangul → `ko`, else default `en`. Passes the resolved value via `--issue-locale "$ISSUE_LOCALE"` in both `tracker=none` and `tracker={github,gitlab}` branches. Wrapper writes the right value in one atomic call; `$CONFIG_LINE` stays canonical.
- **`anti-patterns.md` §19c** — added explicit prohibition of the "post-edit + announce-annotation" pattern (production diagnostic + the two correct paths: pass `--issue-locale` at invocation, or edit the file as a separate clearly-separate step that does NOT touch `$CONFIG_LINE`).
- **`phase-0-setup.md` Step 4 trailing note** — explains why locale detection lives at invocation, not post-edit: keeps wrapper as single source of truth for `$CONFIG_LINE`.

#### Why detection lives in spec bash, not wrapper

Wrapper already accepts `--issue-locale`; the gap was just that nobody was passing it. Detection naturally belongs in the orchestrator's context (it has `$ARGUMENTS`, repo paths, README, etc.), not in the wrapper (which is single-purpose: write a valid config given args). Moving detection into wrapper would also force the wrapper to take a stance on auto-detection rules — better to keep wrapper deterministic and let the spec bash evolve detection heuristics.

#### Detection coverage (current)

| Script | Locale |
|---|---|
| Cyrillic (Russian, Ukrainian, Belarusian, etc.) | `ru` |
| CJK Unified Ideographs (Chinese, Japanese kanji) | `ja` (conservative default — extend per project) |
| Hiragana / Katakana (Japanese-specific kana) | `ja` |
| Hangul (Korean) | `ko` |
| Default | `en` |

Coarse on purpose. If your project needs `zh` vs `ja`, `uk` vs `ru`, or any other locale, pass `--issue-locale=<code>` explicitly in `$ARGUMENTS`. The detection block is small, easy to extend.

### Phase 0 — caveman detect v2 + auto-init of `.claude/do/config.json`

Two issues from production observation of the prior `[Unreleased]` v1 caveman fix:

1. **Caveman v1 didn't stick.** With the verbatim bash and mandatory-line patch, orchestrator still emitted `Caveman: NOT INSTALLED — install: curl -fsSL ...` on a machine where caveman was actually installed at the first path. Diagnosis: orchestrator read the spec, saw the `NOT INSTALLED` example bullet describing the not-found case, copy-pasted the full string (including install-hint suffix that the v1 bash did NOT echo). Confirmation = the install-hint suffix `— install: curl ...` was in the announce but the v1 bash's echo template only produced `Caveman: NOT INSTALLED` without that suffix. So the bash didn't run.

2. **`No .claude/do/config.json — using defaults` is a noisy status with no path forward.** Real projects benefit from a config (tracker integration, specialists, workspace routing), but writing one by hand from the schema is friction nobody pays. Result: every `/do` run in a fresh repo reports "no config" and that's the end of it.

#### Added

- **`skills/do/scripts/config-init`** — bash wrapper, named-args CLI. Required flags: `--repo-root`, `--tracker {github|gitlab|none}`. Conditional: `--tracker-repo owner/repo` (required when tracker ≠ none, regex-validated). Optional: `--stack`, `--issue-locale`. Refuses overwrite, refuses `$HOME` or `/` root, refuses to bootstrap senior-by-default itself (detects `skills/do/SKILL.md` at root). Composes minimal valid config (`version`, `_meta`, `issue_tracker`, `issue_locale`) via `jq -n`. Validates against `config.schema.json` if `python3 -m jsonschema` available. Atomic tmp+rename write. Exit codes: 0 OK / 1 REJECT / 2 IOFAIL — same shape as `metrics-append`.

#### Changed

- **`phase-0-setup.md` Step 2 (caveman v2)** — bash now builds the FULL announce line (including install-hint suffix for NOT INSTALLED) and assigns to `$CAVEMAN_LINE`. Removed the post-bash bullets that described the two output forms in prose — those were the copy-paste bait. Announce template references `$CAVEMAN_LINE` literally (same coupling as `$METRICS_LINE`). Spec contains no other example of either form's full text.
- **`phase-0-setup.md` Step 1** — restructured to set `CONFIG_FOUND` flag and `$CONFIG_LINE`. Found-case sets `CONFIG_LINE="Config: LOADED $CONFIG_PATH"`. Missing-case defers `$CONFIG_LINE` to Step 4 auto-init.
- **`phase-0-setup.md` Step 4** — added "Auto-init config" block at the end. Detects tracker from `git remote get-url origin` (github/gitlab/none with owner/repo extraction). Calls `config-init` with detected values, captures stdout/stderr into `$CONFIG_LINE`. Refuse paths produce `Config: AUTO-INIT SKIPPED — <reason>` — not errors, just visible notes.
- **`phase-0-setup.md` Announce template** — `Caveman:` and `Config:` lines replaced with literal `$CAVEMAN_LINE` / `$CONFIG_LINE` placeholders and "DO NOT compose" markers. Suppression: `--no-caveman` empties `$CAVEMAN_LINE` (line omitted); `--no-config-init` sets `$CONFIG_LINE="Config: NONE — using defaults (--no-config-init)"`.
- **`SKILL.md` advanced flags** — added `--no-config-init`.
- **`anti-patterns.md` §19b (new)** — "Composing the `Caveman:` announce line by hand instead of running Step 2 bash". Documents the exact production failure mode (install-hint suffix in announce while bash didn't emit it) as the diagnostic.
- **`anti-patterns.md` §19c (new)** — "Writing `.claude/do/config.json` directly instead of calling `config-init`". Bans `Write`, `echo >`, `jq > config.json`, `cat <<EOF >` paths. Notes that hand-composing `Config: AUTO-GENERATED →` without invoking the wrapper falls under this — lying about file state.

#### Why this round (not the v1 fix)

v1 added the verbatim bash but kept descriptive bullets immediately below it (`- ACTIVE → ...` / `- NOT INSTALLED → ...` with the install-hint string spelled out). Those bullets were the bait — sub-agents pattern-match on plausible-looking copyable strings. The v1 bash echoed only `Caveman: STATUS [path]`; the bullets' install-hint suffix was NOT in any bash variable. Yet the prod announce contained the full `NOT INSTALLED — install: curl ...` form. Only way that happens is hand-composition from prose.

v2 fix: the bash builds the COMPLETE line. The spec contains no other place where either full form appears verbatim. If the announce diverges from one of the two bash-emitted shapes by even a character, that's a fabrication tell.

Same coupling extended to config: there's no in-doc template to copy from; the wrapper's stdout IS the announce line. The five forms (`LOADED`, `AUTO-GENERATED`, `AUTO-INIT SKIPPED — ...`, `NONE — using defaults (--no-config-init)`) only emerge from the bash/wrapper combination, never from hand composition.

### Phase 0.2 — caveman detect: concrete bash + mandatory announce line

Production report: orchestrator ran `/do` on a machine where caveman was installed at `~/.claude/skills/caveman` (the FIRST path in the spec's detect list), yet the Phase 0 announce omitted the `Caveman:` line — same failure mode as the pre-v0.3.1 `metrics-append` bypass: prose-only spec → sub-agent reads, decides, skips, composes announce without the line. No way to tell from the announce whether detection ran-and-found-nothing or wasn't attempted.

#### Changed

- **`phase-0-setup.md` Step 2** — replaced "detect at one of: …" prose with a verbatim bash block (`for p in …; do [ -f "$p/SKILL.md" ] && { CAVEMAN_STATUS=ACTIVE; break; }; done; echo "Caveman: …"`). Same structural-coupling pattern as `metrics-append`: the announce line literally comes out of the bash, so it cannot be silently skipped.
- **`phase-0-setup.md` Step 2 — path list extended** to 4 entries. Added `~/.agents/skills/caveman` for users who installed via the agent-skill manager without a `~/.claude/skills/` symlink. Pinned the test to `[ -f "$p/SKILL.md" ]` (not `[ -d "$p" ]`) to resolve symlinks correctly and reject empty directories left by failed installs.
- **`phase-0-setup.md` Announce block** — promoted `Caveman:` from a conditional `[+ if …]` bracket to a mandatory line in the fixed template, alongside `Models:`. The only suppression path is `--no-caveman` (which skips Step 2 entirely). Absent line in announce now = visible bug.

#### Why this matters

Detection skipped silently → Phase 2 Sub-Agent prompts don't get the caveman-style directive even when caveman is active → output isn't compressed for the spawned agent → tokens wasted, register inconsistent across orchestrator vs sub-agent. The audit pattern (instruction-only spec → non-deterministic execution) is the same one that bit Phase 4.11 twice; the fix shape is the same too (move from "you should …" prose to "run this bash" + mandatory output token).

### Phase 4.11 — external `metrics-append` wrapper (real enforcement, take 2)

Audit of 9 production entries written after the prior `[Unreleased]` change showed the in-doc `jq -n` template + `:?`-guards approach **did not actually enforce anything**: 5 of 9 sub-agents bypassed the documented bash flow entirely (composed JSON via Write / echo / python with whatever shape they wanted, 100+ distinct field names across runs, `self_review` block missing in 5 of 9). The prior fix would have rejected these entries IF the sub-agent ran the documented bash block, but sub-agents don't reliably run documented bash — they read it, decide on a different approach, and write whatever JSON they want directly to the log path.

#### Added

- **`skills/do/scripts/metrics-append`** — standalone bash wrapper, named-args CLI. Required flags: `--log`, `--ref`, `--complexity`, `--implementer`, `--outcome`, `--started-at`, `--ended-at`, `--files-changed`, `--lines-added`, `--lines-deleted`, `--sr-performed`, `--sr-claimed`, `--sr-calibration`. Unknown flags reject. Bad enum values reject. Malformed JSON payloads (`--gates-json`, `--phase-durations-json`) reject. Append is atomic with pre/post line-count delta verification. Exit codes: 0 OK / 1 REJECT / 2 IOFAIL with explicit stderr message in each failure case.

#### Changed

- **`phase-4-finalize.md` Step 3** — removed the `jq -n` inline template (proven ignored). Replaced with: "the ONLY supported way to write is via `~/.claude/skills/do/scripts/metrics-append`". Documents the canonical invocation that the §4.13 announce block uses.
- **`phase-4-finalize.md` §4.13 emit block** — now invokes the wrapper and captures stdout into `$METRICS_LINE`. No JSON composition in the announce flow anymore. Removed `SCHEMA_OK` plumbing (wrapper exit code is the gate).
- **`phase-4-finalize.md` "Why structural coupling"** — rewritten to explain the three enforcement layers: soft instruction (failed) → bash coupling (caught the announce-skip pattern but not free-form JSON) → external wrapper (catches both).
- **`anti-patterns.md` #19a (new)** — "Writing to `$LOG_PATH` directly instead of calling `metrics-append`". Explicitly bans `echo >>`, `Write` tool, `python3 -c '...' >>`, manual `jq` + `>>`. Points at the wrapper and at the daily-report tripwire.

#### Tripwire (operator-side, not part of the skill distribution)

A local `daily-report.sh` (separate from the skill) now scans for entries that don't match the canonical shape and surfaces them in a "Schema bypass" section, listing which required fields are missing per entry. Bypasses become visible in the next morning's report instead of silently polluting analytics. Sub-agents that ignore the wrapper will see their entries excluded from analytics within 24 hours.

#### Migration

Past JSONL entries from the prior `[Unreleased]` cycle are mixed (some valid, most bypass). Operators should drop bypass entries and accumulate fresh — the wrapper guarantees uniform schema from this version forward.

### Phase 4.11 — structural schema enforcement for metrics JSONL

Sub-agents were composing the metrics entry as a free-form JSON string, producing wildly inconsistent shapes across runs (100+ distinct field names across a few dozen entries in one repo's log: `ts`/`timestamp`, `loc_added`/`added`/`insertions`/`lines_added`, `pr`/`pr_number`/`pr_url`, six spellings of `follow_up` — every run reinvented the schema). The `self_review` block — the highest-signal calibration signal — was emitted in **0 of 37** observed entries despite tier-1 config explicitly requesting it. Cross-run analysis (FP-rate, complexity vs cycles, gate failure trends) was impossible without manual normalization.

#### Changed

- **`phase-4-finalize.md` Step 3** — replaced the `JSON='{...}'` free-form-string example with a `jq -n --arg/--argjson` template fed from explicit env vars. `:?`-guards on required fields (`REF`, `COMPLEXITY`, `IMPLEMENTER`, `OUTCOME`, `STARTED_AT`, `ENDED_AT`, `FILES_CHANGED`, `LINES_ADDED`, `LINES_DELETED`, `SR_PERFORMED`, `SR_CLAIMED_STATUS`, `SR_CALIBRATION`) halt bash if unset. Optional fields default via plain `[ -z "${VAR:-}" ] && VAR=...` assignment (`${VAR:-{}}` parse bug: closing `}` of expansion swallows brace, leaves trailing literal that breaks `jq --argjson` — confirmed in dry-run).
- **`phase-4-finalize.md` Step 3.5 (new)** — `jq -e` schema gate. Validates types + regex on `complexity`, `implementer`, `outcome`, `self_review.{performed, claimed_status, calibration}`. On reject sets `SCHEMA_OK=0` and `METRICS_LINE="Metrics: SCHEMA REJECT — ..."`. The reject is intentional — silently appending a malformed entry pollutes the schema and degrades calibration analysis far worse than a visible reject does.
- **`phase-4-finalize.md` §4.13 emit block** — append now gated by `SCHEMA_OK=1`. Reject path keeps `METRICS_LINE` from Step 3.5; announce still prints. Same structural coupling as before (no emit → no announce) plus a new layer (no schema → no emit).
- **`phase-4-finalize.md` "What broke the procedure looks like"** — added diagnostic for `SCHEMA REJECT` line in announce.

#### Breaking behavior

Tasks where the sub-agent doesn't populate the `SR_*` env vars from Phase 2.5 will now produce `Metrics: SCHEMA REJECT — ...` instead of silently appending an entry missing `self_review`. For tier-0 or self-review-disabled configs, set `SR_PERFORMED=false`, `SR_CLAIMED_STATUS=n/a`, `SR_CALIBRATION=skipped` — these are valid enum values, not workarounds.

#### Migration

Past JSONL entries are unusable for calibration (no `self_review` block, ~120 distinct field names). Delete and accumulate fresh — ~20–30 valid entries gives the first reliable FP-rate point.

## [0.5.0] — 2026-05-14

Cleanup release. Audit found ~7% of repo content was structural bloat — false hierarchy (12 sub-phases in Phase 0), duplicated procedure docs (Phase 4.13 procedure repeated 3×), numbered anti-patterns with `31a/31b/31c/31d/31e/31f` chaos from incremental fixes, unsorted override flags (main vs niche slammed together), unused config sections lacking experimental marking.

**No behavior change.** Structural reorg only. SKILL.md shrunk from 331 → ~190 lines. Phase 0 detail extracted to dedicated reference. Anti-patterns rationalized 53 → ~25 grouped entries. Override flags split into main (5) + advanced (6). Phase 4.13 procedure consolidated to single canonical block. Experimental config sections marked.

### Changed

- **`SKILL.md` Phase 0 detail extracted** to new `references/phase-0-setup.md` (~170 lines). SKILL.md keeps a 6-bullet summary + pointer. Previous structure had 12 numbered sub-phases (`0.0`, `0.0.1`, `0.0.2`, `0.0.3`, `0.1`, ..., `0.8`) implying false hierarchy — `0.0.1` prefix suggested "sub-checks before main setup" when most were conditional bullets that only fire per config. Now 6 logical steps with conditionals inline.
- **`anti-patterns.md` rationalized**: 53 numbered entries with `31a-f` chaos → 24 grouped entries across 6 categories (Process / Memory & context / Git / Code / Distributed-team & enforcement / Opt-in only / Universalization-specific). Hot ones bolded. No info loss — overlapping entries merged, historical universalization items moved to bottom.
- **`SKILL.md` override flags split** into Main (5: `--complexity`, `--implementer`, `--repo`, `--redetect`, `--auto-merge`) + Advanced (6 niche: `--skip-ci-wait`, `--no-self-review`, `--no-codeowners`, `--no-notify`, `--no-affected-graph`, `--no-caveman`). Clearer separation of what most users override per-task vs config-level toggles.
- **`phase-4-finalize.md` §4.13 procedure consolidated**: bash flow was implicit in 3 sections (header notice + "The procedure" + "Why" subsections). Now: one canonical bash block, "Why structural coupling" explanation, "What broke the procedure looks like" diagnostic. ~50 lines saved, single source of truth.
- **`config-schema.md` experimental fields marked**: `wip_limit`, `feature_flags`, `lessons_doc`, `postmortem`, `concurrent_edit_check` now under "Experimental / niche fields" section with explicit "leave unset unless you specifically know what you want" guidance. Not removed for back-compat.
- **SKILL.md top-level anti-patterns line** shortened from 12-item run-on prose to 9-bullet list grouped by what's hot in production.

### Lines saved

| Area | Before | After | Saved |
|---|---|---|---|
| SKILL.md | 331 | ~190 | 140 |
| anti-patterns.md | 78 | ~75 | 3 (count similar but density up) |
| phase-4-finalize.md | 353 | ~310 | 40 |
| **Total realistic** | — | — | **~180 lines, ~5% of repo** |

### Not simplified (despite size)

- Phase 2 Sub-Agent prompt template (200+ lines) — each instruction bought by audit/production lesson
- 14 reference files via progressive disclosure — works as designed
- JSON Schema — programmatic validation, distinct consumer
- 4 example configs — different stacks need different shapes
- CHANGELOG — release history, archived later when v1.0+

### What to verify

After upgrading, run `+++ <small task>` in a sandbox/test project. Final assistant message should still end with `Metrics: <N> entries in <path>.` line (structural coupling unchanged). Phase 0 announce should still produce the `Models:` line. Branch should still be `feat/i{N}-{slug}` (not `claude/<adj>-<noun>`).

## [0.4.0] — 2026-05-11

Minor release. Adapts the four behavioral guardrails from [`forrestchang/andrej-karpathy-skills`](https://github.com/forrestchang/andrej-karpathy-skills) into the `do` pipeline without changing config shape or output schemas.

### Added
- **Top-level operating principles** in `SKILL.md`: think before coding, simplicity first, surgical changes, and goal-driven execution.
- **Phase 0 intent clarity check** before side effects: ask when interpretations would change behavior; otherwise record assumptions and convert the request into pass/fail criteria.
- **Phase 1 issue template hooks** for assumptions/tradeoffs, traceability of changed lines, and explicit no-scope-creep language.
- **Phase 2 implementer guardrails** passed to spawned agents: no silent assumptions, no speculative abstractions/config/deps/flags, plan steps include verification checks, and self-review must confirm simplicity + surgical scope.
- **Phase 3 review criteria** for speculative complexity, drive-by edits, and changed lines that do not trace to the task.
- **Anti-pattern entries** for silent assumptions, weak goals, speculative abstractions, drive-by cleanup, and untraceable changes.

### Changed
- README now calls out the behavioral guardrails as a core differentiator.
- Troubleshooting branch-normalization wording now references Phase 4.0, matching the current flow.

### No breaking changes
Prompt-only tightening. Existing `.claude/do/config.json` files, metrics JSONL shape, branch naming, and final announce format are unchanged.

## [0.3.3] — 2026-05-09

Patch release. Adds explicit model-usage visibility so users see (and metrics record) which model handles which role per task.

### Added
- **Phase 0 announce now includes `Models:` line** — `Models: orchestrator=opus | implementer={haiku|sonnet|opus}`. Implementer auto-derived from complexity (T→haiku, L/M→sonnet, H→sonnet); appended `(override)` when `--implementer=X` flag was passed.
- **Phase 2 spawn announce** — before invoking the implementer Sub-Agent, prints `[Phase 2] Spawning Agent(model: "<X>") in <worktree> on branch <branch>`. For High-complexity plan-review with specialists: prints the parallel-spawn list of `subagent_type` strings.
- **Phase 3.6 specialist roster announce** — before invoking audit specialists, prints the cycle number + count + list of `subagent_type` strings being invoked in parallel.
- **Phase 4.13 announce now includes `Models:` line** — `Models: orchestrator=opus, implementer=sonnet, specialists=[...]`. Provides full audit trail of which models touched the task.
- **Metrics entry `models` block** — new field in Tier 1 schema:
  ```json
  "models": {
    "orchestrator": "opus",
    "implementer": "sonnet|opus|haiku",
    "specialists": ["backend-development:backend-architect", "..."]
  }
  ```
  Enables downstream analysis like "did Haiku tasks have higher false_positive rate than Sonnet?", "which specialist combos correlate with longer review cycles?", etc.

### Why
Skill design routes work across three models (Opus/Sonnet/Haiku) plus optional plugin-provided specialists. Until v0.3.3 this was implicit — user had to read CHANGELOG / spec to know what spawned where. Now every spawn is visible at the moment it happens.

### No breaking changes
Output additions only; existing announce parsers (looking for `Metrics:` line) still work — `Models:` line precedes `Metrics:` but doesn't shadow it.

## [0.3.2] — 2026-05-09

Patch release. Closes the remaining gap from v0.3.1 after learning the actual production execution model.

### Context

User clarified: skill is invoked from a **parent Claude Code session that uses Task tool to spawn sub-agents** with `isolation: "worktree"`. User confirms each spawn manually. The spawned agent runs the entire skill flow start-to-finish and returns. There is no "Opus parent picks up after Sub-Agent reports done" — the spawned agent IS the orchestrator and implementer.

### Why v0.3.1 framing was wrong

v0.3.1's Phase 2 prompt addressed "Opus orchestrator" expecting a parent that finalizes after sub-agent. In the actual execution model, the spawned agent reads "you (Opus) MUST run Phase 4.13 after Sub-Agent reports done" and rationalizes: "I'm the sub-agent, the Opus parent will do this" — except there is no Opus parent that returns to do that. So the step gets skipped.

### Fixed

- **Phase 2 prompt template framing fixed**: critical Phase 4 reminders now address "whoever is currently executing this skill flow — whether you are the spawned agent doing everything yourself, or a parent orchestrator". Explicit: "if you're reading this, you are the executor". No more deferring to a non-existent parent.
- **Phase 4.13 procedure now includes Phase 4.0.5 pre-emit sanity check**: capture `wc -l` of `$LOG_PATH` BEFORE the append (`PRE_COUNT`), then verify after the append that `POST_COUNT - PRE_COUNT == 1`. If delta isn't exactly 1, set `METRICS_LINE="Metrics: APPEND FAILED — pre=X post=Y delta=Z expected=1"`. Catches silent corruption (disk full, permission flip mid-write, file lock, etc.) that would otherwise return exit 0 but write nothing.
- **Anti-pattern 31a updated**: explicitly mentions execution-model framing — "applies whether you are the spawned agent doing everything yourself, or a parent orchestrator — there's no 'the other one' to defer to; if you're reading this, you are the executor."

### Real-world test

In a fresh `+++` task on a project with `metrics.log_path` configured, the final assistant message MUST end with one of:
- `Metrics: <N> entries in <path>.` — success
- `Metrics: APPEND FAILED — pre=X post=Y delta=Z expected=1.` — write succeeded but delta wrong (silent corruption)
- `Metrics: APPEND FAILED — write error to <path> (exit N).` — write failed
- `Metrics: not configured (set config.metrics.log_path to enable).` — feature disabled

If the final message ends with PR-summary prose and no `Metrics:` line at all, the bash procedure was skipped — that's now provably the wrong path because the procedure literally generates the entire announce text. Free-form prose announce should be impossible.

## [0.3.1] — 2026-05-09

Patch release. Fixes two systematic Phase 4 escapes observed in real production runs:
1. **Phase 4.11 metrics emission consistently skipped** despite "MANDATORY" labels, even with `disable-model-invocation` removed in v0.3.0. Sub-agents/Opus orchestrator open the PR, write a detailed PR-summary prose, then stop — never appending JSONL.
2. **Phase 4.1.0 branch rename rationalized away** when worktree was pre-spawned by Claude Code's harness. Sub-agent observed mismatch (`claude/<adj>-<noun>-<hash>` vs `feat/i{N}-{slug}`) and explicitly chose NOT to rename, citing "the worktree was pre-spawned" as exception — even though `git branch -m` works fine on pre-spawned worktrees.

Both bugs are the same class: **soft instructional enforcement fails when the agent treats steps as ceremony**. v0.3.1 replaces soft enforcement with structural coupling.

### Changed
- **Phase 4.13 final-announce is now a single bash procedure that EMITS METRICS AND PRINTS ANNOUNCE in one block**. Announce text references `$METRICS_LINE` shell variable that's set ONLY by the metrics-append step. You cannot produce the announce without running the emit. If the announce comes out without the `Metrics: ...` line, the procedure was skipped (free-form prose written instead). Hard structural coupling, not soft instruction.
- **Phase 4.0 (renamed from 4.1.0, moved up)**: branch normalization runs BEFORE Phase 4.2 PR creation. PR opens on the correct `feat/i{N}-{slug}` branch from the start, not `claude/...`. Eliminates the "PR is on auto-name; would have been i{N}-{slug} but" rationalization.
- **Pre-spawned worktree is NOT an excuse**: Phase 4.0 spec explicitly states the rename is UNCONDITIONAL. Worktree path is fine to keep; branch must follow `config.naming` for `i{N}`-traceability across commits/PRs/metrics/tracker comments.
- **Phase 2 sub-agent prompt template**: Phase 4 critical reminder pinned at the TOP of the Rules section (was buried at the end). Sub-agent's first instruction is "When this Sub-Agent reports done, you (Opus) MUST run the Phase 4.13 final-announce bash procedure verbatim..." — orchestrator gets the reminder at session-start context, not at end-of-task when it's already forgotten.

### Anti-patterns strengthened
- **31a (skip metrics emission)**: now points at the bash-coupling solution. Says: "if your final assistant message ends with PR-summary prose and NO `Metrics: ...` line, you skipped the procedure — go back and run the bash flow verbatim instead of composing prose announce."
- **31c (auto-named branches)**: now points at Phase 4.0 (BEFORE PR open) instead of 4.1.0 (after). Explicitly forbids the "pre-spawned worktree" rationalization.

### Top-level anti-patterns in SKILL.md updated
Two new entries surfaced to the top-level visible list:
- "Final assistant message ends with PR-summary prose and NO `Metrics: ...` line" (you skipped Phase 4.13 procedure)
- "Auto-named branches without `i{N}` for M/H" — now references Phase 4.0 (BEFORE PR) and explicitly disqualifies pre-spawn excuses

### Background
v0.3.0 removed `disable-model-invocation: true` to enable `+++` shortcut. We expected Phase 4.11 enforcement to hold via the strict description language. Real production runs showed it doesn't — sub-agents read all the right instructions but skip the final emit step because by the end of a long flow it feels ceremonial.

The pattern of failures (consistent across multiple sessions, regardless of caveman compression directive specifics) confirmed instructional enforcement is insufficient. v0.3.1 ships structural enforcement: the announce text physically depends on the metrics-emit shell variable. If sub-agent skips the emit, the announce literally can't be composed. Test in a fresh session: if the final message ends with `Metrics: <N> entries in <path>.`, the procedure ran. If the final message is free-form prose ending with PR-summary, it didn't.

## [0.3.0] — 2026-05-09

Minor release. Restores `+++` shortcut by removing `disable-model-invocation: true` and replacing the hard architectural guard with a strict-description soft guard.

### The trade-off

Third-pass audit (in v0.2.0) added `disable-model-invocation: true` because the skill performs side effects (issues, commits, pushes, PRs, optional auto-merge) and shouldn't auto-trigger from description matching mid-conversation. **The flag was correct** — it's defense-in-depth.

But the same flag also blocks Skill-tool invocations routed through a `+++` CLAUDE.md trigger. Verified with claude-code-guide: Claude Code currently has **no CLI-level prompt-rewrite mechanism** (`UserPromptSubmit` hook only supports adding context or blocking, not replacement). So with the flag set, `+++` simply cannot work — only `/do <task>` does.

v0.3.0 picks ergonomics over the hard guard:
- **Removed**: `disable-model-invocation: true` from frontmatter
- **Replaced with**: strict description language — `TRIGGER ONLY when the user's message LITERALLY starts with /do, /<plugin>:do, or +++`. `NEVER auto-trigger from description matching, perceived task fit, or conversational context, EVEN IF a coding task otherwise matches every other criterion.`
- **Result**: `+++` shortcut works; risk of false-positive description-match auto-trigger goes from "architecturally impossible" to "depends on Claude respecting the strict description". In practice Claude is good at respecting clear "ONLY when... NEVER..." rules; in pathological cases it could still misfire.

### What if I want the hard guard back?

Edit your local `~/.claude/skills/do/SKILL.md` (or `~/.claude/plugins/.../skills/do/SKILL.md`) and re-add `disable-model-invocation: true` to the frontmatter. You'll lose the `+++` shortcut. Document this trade-off in your team's onboarding so people know `/do <task>` is the only invocation in your setup.

### Changed
- **`skills/do/SKILL.md` frontmatter**: removed `disable-model-invocation: true`. Description rewritten with explicit "TRIGGER ONLY when LITERALLY starts with..." + "NEVER auto-trigger" language as soft guard. HTML comment under frontmatter explains the trade-off and the reason the flag was removed (CC harness lacks CLI-level prompt rewriting).
- **`install.sh`**: TRIGGER feature restored (was removed in v0.2.4 because the trigger didn't work). New installs get `+++` block in `~/.claude/CLAUDE.md` again. Marker-wrapped for clean uninstall.
- **`install.sh` Step 6**: legacy-cleanup branch (v0.2.4 behavior) replaced with trigger-setup branch (v0.2.0 behavior, but for a now-working trigger).
- **`README.md`**: removed broken "Why no `+++` shortcut via CLAUDE.md" + "Shortcut setup (CLI hook)" sections. Restored `+++` shortcut documentation in plugin install + manual install paths. Top example now shows both `/do` and `+++` forms. New Troubleshooting entries: "`+++` doesn't trigger anything" (check the trigger block in CLAUDE.md), "Worry about auto-trigger from description match" (re-add the flag for hard guard, lose the shortcut).
- **`.github/workflows/lint.yml`**: frontmatter check updated. Now ASSERTS `disable-model-invocation` is NOT set (or false), and that description contains "TRIGGER ONLY" + "NEVER auto-trigger". Locks in the v0.3.0 design — preventing accidental re-introduction of the flag without also removing the trigger feature.

### Migration for v0.2.4–v0.2.5 users

Re-run `install.sh` — it will write the `+++` trigger block to `~/.claude/CLAUDE.md` (which v0.2.4 cleanup may have stripped). Or add the marker-wrapped block manually:

```md
<!-- senior-by-default:trigger:start -->
## +++ Trigger

When a user message starts with `+++`, treat everything after `+++` as the argument and invoke the `/do` skill with that text. This is a shorthand — `+++ add user avatars` is equivalent to `/do add user avatars`.
<!-- senior-by-default:trigger:end -->
```

For plugin install users: replace `/do` with `/senior-by-default:do` in the block.

### Lessons from this whole arc (v0.2.0 → v0.2.5 → v0.3.0)

1. **Audit recommendations need end-to-end re-test of all documented entry points.** v0.2.0 added `disable-model-invocation` (correct fix for stated risk) but broke the documented `+++` flow. Caught only when a real user (the author) tried `+++` after the changes shipped.

2. **CI shellcheck on install.sh actually catches things.** v0.2.5 hot-fix happened in 5 minutes because shellcheck pinpointed the bad backtick on the right line.

3. **README that documents non-existent features is worse than missing docs.** v0.2.4 invented a "UserPromptSubmit hook that rewrites prompts" that Claude Code doesn't support. Removed in v0.3.0. Fix: verify any "PRs welcome" / "you can do X" claim against actual API docs before shipping.

4. **Hard guards (architectural) are stronger than soft guards (instructional).** v0.3.0 trades hard for soft for ergonomic reasons. That's the author's call as the primary user; teams with stricter security postures should keep the hard guard.

## [0.2.5] — 2026-05-09

Hot-fix for v0.2.4 — install.sh syntax error caught by CI shellcheck immediately after release.

### Fixed
- **`install.sh:219`**: `log "Kept legacy block. It does nothing — \`/do <task>\` works regardless."` — backticks inside double quotes triggered shell command substitution. shellcheck SC1073/SC1072 errors. Fix: switched to single-quoted string (no interpolation, no metachar parsing). Same class of quoting bug we fixed for tracker commands in v0.2.1, in our own installer this time.

### Lesson
v0.2.4 release notes already called for "CI smoke-test that the documented invocation flow actually fires (not just `bash -n` syntax check)". Shellcheck on install.sh is part of that. v0.2.4 added shellcheck to CI in v0.2.0 — and it caught this one before any user did. Working as intended.

## [0.2.4] — 2026-05-09

Patch release. Removes a broken-by-design feature: the `+++` trigger that v0.2.0–v0.2.3 wrote into `~/.claude/CLAUDE.md` never actually worked because of `disable-model-invocation: true` on the skill (added in v0.2.0 per third-pass audit). Surfaced when a real user (the author) tried `+++` after the v0.2.0 audit fixes and got:

```
Skill do cannot be used with Skill tool due to disable-model-invocation
```

Audit passes 1-7 didn't catch it because nobody re-tested the documented `+++` flow end-to-end after the third-pass `disable-model-invocation` change. The flag (correctly) blocks ALL Skill-tool invocations — including the supposedly-explicit ones the `+++` trigger asked the model to make.

### Changed
- **`install.sh`**: TRIGGER feature removed. No longer prompts for or writes a `+++` trigger block to CLAUDE.md.
- **`install.sh`**: new Step 6 — detects legacy marker-wrapped trigger blocks from v0.2.0–v0.2.3 in `~/.claude/CLAUDE.md` and offers to strip them (default: yes). Existing users get cleaned up on next install/update.
- **`README.md`**: removed `+++` shortcut promise from plugin install section. New "Why no `+++` shortcut via CLAUDE.md" Troubleshooting entry explains the conflict. New "Shortcut setup (CLI hook)" section sketches the right way to do `+++` (a `UserPromptSubmit` hook in `~/.claude/settings.json` that rewrites `+++ X` → `/do X` at CLI level — bypasses `disable-model-invocation` because it produces a real slash-command, not a Skill-tool invocation).
- **`SKILL.md` frontmatter description**: TRIGGER line dropped `(or +++ shortcut)`.
- **`SKILL.md` notation comment**: clarifies that any shortcut mechanism MUST happen at CLI level, never via CLAUDE.md instruction asking the model to invoke the skill.
- **`CONTRIBUTING.md`**: bug-report template + smoke-test checklist now reference `/do` (not `+++`).
- **References (`stack-detection.md`, `trackers.md`)**: example invocations updated from `+++ ...` to `/do ...`.

### Migration for existing users (v0.2.0–v0.2.3 installs)

Re-run `install.sh` — Step 6 will offer to strip the dead `+++` block from your `~/.claude/CLAUDE.md`. Or remove it manually (search for `<!-- senior-by-default:trigger:start -->` … `<!-- senior-by-default:trigger:end -->`).

If you want a `+++`-style shortcut, set up the CLI hook described in README "Shortcut setup (CLI hook)" — that path works regardless of `disable-model-invocation`.

## [0.2.3] — 2026-05-09

Patch release. Bug fix in `install.sh` — env-var override path was broken in v0.2.0–v0.2.2.

### Fixed
- **`install.sh prompt()` env-var override path**: when the user ran `SKILL_NAME=do TRIGGER=+++ curl ... | bash`, `prompt()` printed its `(from $ENVVAR)` confirmation banner to **stdout** instead of stderr. `SKILL_NAME=$(prompt ...)` then captured both the banner AND the value, producing a multi-line string that failed the next-line regex validation:
  ```
  ✗ Skill name must be lowercase alphanumeric with - or _ (got 'Skill name (becomes /do slash-command): do (from $SKILL_NAME)
  do')
  ```
  Interactive path was unaffected because that branch already wrote to `>&2`. Audit passes 1-6 didn't catch it because no pass exercised the `curl ... | bash` env-var path end-to-end.

  Fix: redirect the env-var override `printf` to `>&2`, matching the interactive branch. Added a code comment explaining why all user-facing prints in `prompt()` MUST go to stderr (only the value goes to stdout).

  Verified: `SKILL_NAME=mysuperskill prompt ...` now captures cleanly; subsequent regex validation passes; full `install.sh` env-var-override flow runs end-to-end on a clean machine.

## [0.2.2] — 2026-05-08

Patch release. Companion-skill integration with [caveman](https://github.com/JuliusBrussee/caveman) — additive, opt-in, no schema or behavior changes for existing configs.

### Added
- **Companion skill: caveman integration** — Phase 0.0.3 detects whether caveman is installed and announces its activation status. Caveman's SessionStart hook compresses agent output ~75% via "caveman speak" while preserving technical accuracy; once active, all Sub-Agent spawns from Phase 2 inherit compressed mode.
  - **Phase 2 Sub-Agent prompt template** now includes a conditional caveman-style directive (only when Phase 0.0.3 detected caveman as ACTIVE). Critically distinguishes natural-language framing (compress freely) from structured output — code, paths, JSON, diffs, `claimed_status: ready` self-review block, Phase 4.11 metrics JSONL, and final announce format MUST stay LITERAL because downstream tooling parses them.
  - **`--no-caveman`** override flag for per-task opt-out.
  - **README**: new "Recommended companion: caveman (install FIRST)" section above the Phase 3 plugins list. Explains why install order matters (SessionStart hook fires at session boot — installing caveman after senior-by-default requires session restart).
  - **Anti-pattern 31e**: skipping Phase 0.0.3 when caveman is installed.
  - **Anti-pattern 31f**: compressing structured output (would break Phase 4.11 metrics calibration parsing).

## [0.2.1] — 2026-05-08

Patch release. Security follow-up after sixth-pass audit found a bypass in v0.2.0's shlex-quote fallback for legacy string-form tracker commands.

### Security (audit sixth pass)
- **Schema-reject string-form `commands.<op>` containing `{title}` or `{labels}`**. The v0.2.0 `shlex.quote` fallback was insufficient when the template wraps the placeholder in `"..."` (the natural shape of `--title "{title}"`): a `"` inside user-supplied title content closes the surrounding quote regardless of how the substituted value is escaped. Reproducible exploit:
  - template: `--title "{title}"`
  - title from `$ARGUMENTS`: `x" --milestone 5 --label injected "y`
  - after `shlex.quote`: `'x" --milestone 5 --label injected "y'`
  - naive substitution: `--title "'x" --milestone 5 --label injected "y'"`
  - shell parses → `--title 'x · --milestone · 5 · --label · injected · y'` (six argv elements; injection succeeded)
  - **No text-level escape can fix this** — only argv-array form is safe.

  Fix: `config.schema.json` now has `not: { pattern: "\\{(title|labels)\\}" }` on the string variant of `trackerCommand`. String-form commands carrying user-controlled placeholders fail validation; argv-array form is required for any operation that interpolates `{title}` or `{labels}`. String form remains valid for ops without user content (`view_url`, `view_body`, `edit_body`, `comment` with body-file).

  - **`references/trackers.md`**: new subsection "Why the string form CANNOT carry user content (and is schema-rejected for it)" with the exploit and schema rule.
  - **`references/anti-patterns.md` 31d**: updated — `shlex.quote` is NOT sufficient fallback; schema enforces the constraint.

  Verified negatively: string with `{title}` rejected; string with `{labels}` rejected; string without user content (e.g. `linear issue view {N} --json | jq -r .url`) accepted; argv array with `{title}` accepted; existing 4 example configs still validate.

## [0.2.0] — 2026-05-08

Five rounds of independent audit closed. SemVer minor: additive schema changes, new opt-in features, structural reorg under `skills/do/`, security hardening of tracker execution. No breaking changes for existing user configs (legacy string-form tracker commands still validate).

### Security (audit fifth pass)
- **Shell injection via `{title}` placeholder** in tracker commands. User-controlled `$ARGUMENTS` reaches `{title}`; a malicious title (`x" --milestone 5 --label injected "y`) smuggled extra CLI flags through naive shell substitution.
  - **`references/trackers.md` rewritten** with explicit "Security: argv-safe execution is MANDATORY" section at top, including the exploit example, the env-var-based fix pattern, and argv-array form for custom trackers.
  - **Built-in `github`/`gitlab` tables** now show env-var argv-safe invocations (`gh issue create --title "$TITLE" ...`) instead of string templates with placeholder substitution.
  - **Custom trackers**: argv-array form is now the documented preferred form. String form remains for back-compat with mandatory `shlex.quote` fallback + deprecation warning.
  - **JSON Schema** `commands.<op>` now accepts either argv array (preferred) or string (deprecated) via `oneOf` in new `$defs/trackerCommand` definition.
  - **Anti-pattern 31d** added.
  - **Top-level anti-patterns in SKILL.md** updated.
  - **`phase-1-issue.md`** points readers at the secure execution pattern in trackers.md.

### Fixed (audit fourth pass)
- **Plugin examples local-path row removed from README**. Claude Code stores plugins under `~/.claude/plugins/cache/...` with versioned subdirectories that change across updates — the documented copy path was unstable. Plugin users are now directed to Option A (curl from raw.githubusercontent.com) or to clone the repo separately for local examples.
- **Custom `SKILL_NAME` no longer mutates tracked files**. Previously `install.sh` patched `skills/do/SKILL.md` in the cloned install dir, which broke `git pull --ff-only` on subsequent runs (local-changes detection skipped pull). Refactored: pristine clone is never modified; for custom names, a patched copy is regenerated on every install at `$INSTALL_DIR/.rendered-skills/<name>/` (gitignored). Symlink points at the rendered copy. Default name still symlinks straight at the pristine source — zero overhead.
- **Schema/markdown contract fully aligned on `version`**. `config-schema.md` prose now says "no fields are strictly required, `version` is *recommended*, defaults to 1 with warning, explicit mismatches hard-fail" — matches what `config.schema.json` actually does.
- **JSON Schema description rewritten** to declare the back-compat default-1 behavior explicitly, removing "all fields except version are optional" wording that contradicted the actual `required` array (empty).
- **Bonus**: `workspace` block in JSON Schema now has `required: ["is_workspace", "repos"]`. Previously empty `workspace: {}` or `workspace: {"repos":{}}` (without `is_workspace: true`) silently passed validation — fourth-pass auditor flagged this as "malformed workspace passes unexpectedly".

### Fixed (audit third pass)
- **`model: opus` pinned in SKILL.md frontmatter** — orchestrator role (Phase 0 routing, Phase 3 review, Phase 4 decisions) now runs on Opus regardless of session model. Previously the skill ran on whatever active session model the user had, so a Sonnet session silently downgraded "Opus reviews" to Sonnet reviewing itself.
- **`disable-model-invocation: true` added** — skill creates issues, commits, pushes, opens PRs, optionally auto-merges. Must not auto-discover from description matching mid-conversation; only fires on explicit `/do` or `+++`.
- **Configure-your-project section in README rewritten** — install-agnostic curl variant for any install path; lookup table for plugin / manual-symlink / custom-clone install dirs. Old `cp ~/.claude/skills/do/../../examples/...` only worked for default symlink install.
- **CI frontmatter check tightened** — now asserts `model: opus` and `disable-model-invocation: true` are present (locks in the design decisions).

### Fixed (audit second pass)
- **Plugin install slash-command** documented correctly in README: `/senior-by-default:do` (plugin namespace) vs `/do` (manual symlink). Was: README implied `/plugin install` registers `/do`, which would mislead plugin-path users.
- **JSON Schema `version` no longer required** — matches the documented backcompat behavior in `config-validation.md` (missing version → default 1 + warn). Was: schema hard-failed configs that markdown said were valid.

### Changed (post-audit)
- **Restructured to plugin format**: `SKILL.md` and `references/` moved under `skills/do/`; added `.claude-plugin/plugin.json` manifest. Enables `/plugin install` distribution path.
- **`SKILL.md` frontmatter**: switched from prose blob to `TRIGGER:`/`SKIP:` format per Anthropic skill conventions; added `version: 0.1.0`.
- **README**: example-first lead, then tagline. Install order: plugin install → manual symlink → curl-pipe (last, with "review the script" warning). Added security/permissions section.
- **`config.schema.json`**: full JSON Schema (draft 2020-12) for programmatic validation. CI validates all examples against it.
- **`config-schema.md` + `config-validation.md`**: documented relative-path resolution (relative to config.json's dir, not CWD); `version` default-to-1 behavior with warning instead of hard-fail.
- **`stack-detection.md`** + Phase 0.2: cache verification now compares `cache.repo_path` against current repo (guards slug collision for `/foo/work-api` vs `/foo/work/api`).
- **Phase 0.3 concurrent-edit check**: now runs `git fetch origin main` first (was reading stale local ref).
- **`postmortem` defaults documented**: trigger keywords + branch prefixes listed in config-schema prose.
- **Notation section** added to `SKILL.md`: `Agent(model: ...)` shorthand explained for adopters reading source.
- **Pseudocode unification**: bash-first reference implementations (slug rule, etc.).
- **Markdown table escaping**: `--complexity=T\|L\|M\|H` no longer breaks GitHub rendering.

### Added (post-audit)
- `.github/workflows/lint.yml` — shellcheck + JSON validate + frontmatter check + markdown-link sanity.
- `uninstall.sh` — symlink removal, marker-aware trigger-block stripping from `~/.claude/CLAUDE.md`, optional cache/metrics/install-dir purge.
- `install.sh`: marker-wrapped trigger blocks (`<!-- senior-by-default:trigger:start/end -->`), local-changes detection before pull, fail-fast on hard deps (git/python3), warn on soft deps (jq/gh).

### Fixed (post-audit)
- Broken links in `SKILL.md` and `config-schema.md` to renamed `examples/multi-repo-go-react-config.json` (was `lea-config.json`).
- Self-referential link in `phase-4-finalize.md` (`references/notifications.md` → `notifications.md`).

## [0.1.0] — 2026-05-08

Initial public release.

### Architecture
- **Three-actor pipeline**: Opus (architect/reviewer), Sonnet (implementer), Haiku (trivial mechanical changes). Strict role boundaries enforced via SKILL.md rules and Phase 2 prompt construction.
- **Complexity routing**: Trivial / Low / Medium / High auto-detected from `$ARGUMENTS` + file count + scope, with `--complexity=` override flag.
- **Progressive disclosure**: SKILL.md (~250 lines) loads phase-specific references on demand; total ~2000 lines of documentation across 14 reference files.

### Phases
- **Phase 0 — Setup & routing**: config discovery + validation, stack detection (cached per repo), duplicate / concurrent-edit / migration checks, complexity assignment.
- **Phase 1 — Issue creation** (M/H): structured body with acceptance criteria, build checklist, worktree-setup commands; tracker-agnostic command templates.
- **Phase 2 — Implementation**: worktree pre-created by Opus (no `Agent(isolation: "worktree")`); Sonnet self-review with `claimed_status` declaration; stale-main check; ADR generation for High complexity.
- **Phase 3 — Code review**: gates for PR-size, dependency vulns, public-docs, tests, UI (Claude Preview), i18n, contract (BE↔FE types); Low diff-scan; specialist parallel audit (High); Opus acceptance-criteria check.
- **Phase 4 — Finalize**: branch verification, commit + push, PR creation, optional CI gate, optional auto-merge, context-doc update, mandatory metrics emission.

### Stack support
- Auto-detection: Go / TS / JS / Rust / Python / Ruby / PHP / Dart-Flutter / JVM / .NET / Deno / Elixir.
- Multi-stack monorepos: subdir-scan up to depth 3 when root has no markers (handles `apps/`, `services/`, `App/`, etc.).
- Package manager detection from lockfiles for JS ecosystem.

### Trackers
- Built-in: `github` (gh CLI), `gitlab` (glab CLI), `none`.
- `custom` type with command templates for Linear, Jira, internal trackers.
- Cross-repo close-keyword logic (Closes vs Refs).

### Distributed-team practices
- CODEOWNERS-aware specialist routing in Phase 3.6.
- Zero-downtime migration audit checklist (forbidden ops: DROP/RENAME/NOT NULL-without-default; expand-contract pattern).
- ADR generation for High-complexity architectural decisions.
- PR-size guards (warn at 800 lines / 20 files; block at 2000 / 50).
- Stale-main detection with optional auto-rebase.
- Sonnet self-review with calibration metric (`accurate` / `false_positive` / `false_negative`).
- Opt-in: CI gate, auto-merge, async notifications (Slack/Teams), feature flags, WIP limits.

### Metrics (Tier 1)
- JSONL append per task to `config.metrics.log_path`.
- Captured: phase durations, gate failure details, self-review calibration, specialist iterations with file:line citations, branch_rename flags, outcome, blocked_reason.
- **Mandatory emission** when `metrics.log_path` configured — final announce verifies append succeeded.

### Anti-patterns
- 42 documented anti-patterns across general process, memory/context, git, code, distributed-team practices.
- Pre-finalize sanity check loads `references/anti-patterns.md`.

### Configuration
- 4 example configs: minimal (single-repo + GitHub), multi-repo Go+React, Python+FastAPI+Alembic, Rust workspace + GitLab.
- Validation rules in `references/config-validation.md`.
- All features opt-in or skip-by-default; out of the box you get build/test/lint enforcement, self-review, PR-size guards, concurrent-edit warnings.

### Known limitations
- Tier 1 metrics schema may evolve; entries don't yet have schema version field.
- No `/do-review` companion skill yet for automated metrics analysis (Tier 2 — planned after data accumulates).
- `Agent(isolation: "worktree")` shortcut by Opus is hard-forbidden but enforcement relies on Phase 4.1.0 branch-rename fallback when violated.
