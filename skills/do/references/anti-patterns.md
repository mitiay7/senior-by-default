# Anti-patterns (what NOT to do)

Read this BEFORE finalizing any task as a sanity check (Phase 4 calls back into this list).

Grouped into 4 categories, ~20 distinct rules. Hot ones are bolded — those are the ones audit + production runs proved get violated most.

## Process

1. **Subjective reviews** ("rate 1-10", "looks fine") — pass/fail only against acceptance criteria. Includes: tests written after review (Phase 2 task — Test Gate blocks review), scope creep (log as new issue, never expand current task), issues without measurable acceptance criteria.
2. **Roles immutable** — Opus writes code only with `--implementer=opus`; Sonnet never makes architectural decisions; Haiku never does logic/multi-file work. Opus fixing code directly in review → return to Sonnet, re-run gates.
3. **Silent assumptions** — if interpretations would produce different behavior, ask BEFORE creating issues/worktrees/commits/PRs. Low-risk assumptions: record in issue body / Phase 0 announce.
4. **Speculative scope** — speculative abstractions, config, feature flags, "future flexibility", drive-by refactors, formatting churn, comment rewrites, changed lines that don't trace to the request/requirement/criterion/cleanup.

## Memory & context

5. **Re-detecting stack on every run** — Phase 0 uses cache from `~/.claude/do/cache/<slug>.json` unless `--redetect` requested. Ignoring `--redetect` is also a violation — blow away the cache when asked.
6. **Re-exploring codebase instead of reading `context_doc`** — every Sonnet prompt's first step is to read it. Same for `memory_path` if configured.
7. **Finalizing without `context_doc` update** when `required_for_finalize: true` — Phase 4.6 is BLOCKING.
8. **Loading reference files preemptively** — references are progressive disclosure; load only when corresponding phase fires.

## Git

9. Using `git checkout -b` instead of `git worktree add`. Force-push, amending, history rewrite on shared branches. Modifying `.git/config` or `core.hooksPath`.
10. **Committing secrets** — `.env*`, `*.key`, `*.pem`, `credentials.*`, `*.secret`. Verify `git diff --cached --name-only` + content inspection before every push.
11. **Hardcoded `Co-Authored-By` model name** — auto-detect from environment metadata. Never hardcode a model version.
12. **Auto-named branches without `i{N}` for M/H** — branches MUST follow `config.naming.issue.branch` (default `feat/i{N}-{slug}`). The `{N}` is what links commits/PRs/metrics/tracker. **Phase 4.0 runs BEFORE PR open and renames UNCONDITIONALLY**. "Pre-spawned worktree" is NOT an excuse — `git branch -m` works on pre-spawned worktrees too. Renames flagged in metrics entry's `branch_rename`.
13. **Using `Agent(isolation: "worktree")` for Phase 2** — auto-names branches (`claude/<adj>-<noun>`), bypasses `config.naming`. Pre-create worktree explicitly via `git worktree add`, then spawn Agent without isolation.

## Code

14. **Hardcoded user-facing strings** (only if `config.i18n` set) — must use `config.i18n.fn()`. Add keys to all `locale_files`.
15. **Adding dependencies not listed in Requirements**. Phase 3 dep-vuln scan also blocks at configured `security_scan.threshold`.
16. **Amending migration files during review** — always write NEW migration with higher number. Never amend.
17. **Backwards-compat shims** — clean breaks only. No re-exports, `_unused` vars, comment-explanations of WHAT.
18. **Skipping zero-downtime migration audit** when migration present — `migration_audit` specialist MUST apply the [`zero-downtime-migrations.md`](zero-downtime-migrations.md) checklist explicitly with PASS/FAIL per item; "looks fine" is not an audit.

## Distributed-team & enforcement

19. **Final assistant message ends with PR-summary prose and NO `Metrics: ...` line** — Phase 4.13 procedure was skipped. The announce is structurally coupled to Phase 4.11 metrics emission via shared `$METRICS_LINE` bash variable; run the bash flow verbatim from [`phase-4-finalize.md`](phase-4-finalize.md). Composing prose announce instead of running the procedure is the most common production bug.

    Applies whether you are the spawned agent doing everything yourself, or a parent orchestrator. If you're reading this, you are the executor. There is no "the other one" to defer to.

    Pre/post line-count delta verify lives inside the `metrics-append` wrapper (called from the §4.13 bash flow), so silent `>>` corruption (disk full, lock) is caught and surfaced as `Metrics: APPEND FAILED — IOFAIL …`.

19a. **Writing to `$LOG_PATH` directly instead of calling `metrics-append`** — `echo "$JSON" >> "$LOG_PATH"`, `Write` tool against the log path, `python3 -c '...' >> "$LOG_PATH"`, manually `jq`-built JSON appended via `>>` — ALL forbidden. The only supported emission path is `~/.claude/skills/do/scripts/metrics-append` invoked by the §4.13 bash block. The wrapper enforces named-args, enum validation, JSON-payload validity, and atomic append.

    Why: in-doc bash templates with `:?`-guards and `jq -e` schema gates were proven (v0.6 audit) to be skipped systematically — sub-agents composed their own JSON shapes via Write/echo/python, producing 5 of 9 entries with no `self_review` block despite Phase 4.11 explicitly requiring it. The wrapper is the structural enforcement that the in-doc template couldn't be.

    Tripwire: the local `daily-report.sh` script (separate from the skill) scans for entries that don't match the canonical shape and surfaces them in tomorrow's report under a "Schema bypass" section. Bypasses are visible. Don't bypass.

19b. **Composing the `Caveman:` announce line by hand instead of running `~/.claude/skills/do/scripts/check-caveman`** — production-confirmed failure mode, hit TWICE: (1) 2026-05-17 miro-rooms run announced "NOT INSTALLED — install: curl ..." while caveman was installed at path #1 (v1 inline-bash with prose bullets — orchestrator copy-pasted from bullets); (2) 2026-05-17 lea-web run same fabrication despite v2 fix (orchestrator copy-pasted from the bash literal itself — the line template was still visible in the spec's `CAVEMAN_LINE="..."` assignment).

    v3 structural fix: detection moved to external wrapper `scripts/check-caveman`. The canonical announce strings live ONLY in the wrapper, never in the spec. Spec just invokes `CAVEMAN_LINE="$(~/.claude/skills/do/scripts/check-caveman)"`. The wrapper emits one of:
    - `Caveman: ACTIVE (path: <resolved-path>)` — path varies per machine, unguessable
    - `Caveman: NOT INSTALLED (probed: <P1>, <P2>, <P3>, <P4>) — install: curl …` — **the `(probed: ...)` suffix is the anti-fabrication tell**. The full probed-paths list is built from the wrapper's internal array, never appears in the spec, so orchestrator skipping the wrapper cannot include this suffix without inventing path names (visible bug).

    **Diagnostic:** if your announce has a `Caveman:` line that lacks EITHER the `(path: ...)` suffix (ACTIVE) OR the `(probed: ...)` suffix (NOT INSTALLED) — orchestrator skipped the wrapper. Same correction every time: re-run, paste actual wrapper stdout.

    Why we keep iterating this: every time we removed one prose template from the spec, orchestrator pivoted to the next-most-visible literal. v1 had bullets, v2 had bash assignments, v3 has only `$(wrapper)` invocation. The probed-list tell guarantees that even if the orchestrator's prompt-cached spec is stale, the announce can't pass off-line copies as wrapper output — the suffix would be absent.

19c. **Writing `.claude/do/config.json` directly instead of calling `config-init`** — `Write` tool on the path, `echo > config.json`, `jq -n ... > config.json`, `cat <<EOF > config.json` — all forbidden. The only supported init path is `~/.claude/skills/do/scripts/config-init` invoked from the Phase 0 Step 4 auto-init bash. The wrapper enforces: refuse-on-exists, refuse-bootstrapping-self (won't write into senior-by-default repo), refuse-`$HOME`-root, required-arg validation, owner/repo regex on `--tracker-repo`, schema validation against [`config.schema.json`](config.schema.json) before write, atomic tmp+rename. Same `$CONFIG_LINE` structural-coupling pattern as `$METRICS_LINE` and `$CAVEMAN_LINE`.

    Composing `Config: AUTO-GENERATED → …` by hand without actually invoking the wrapper falls under this — you'd be lying about file state.

    **Post-edit + announce-annotation is also a §19c violation.** Production-confirmed pattern: orchestrator runs wrapper with default `--issue-locale en`, notices repo is non-English (Cyrillic / CJK in `$ARGUMENTS`, README in another language), edits the freshly-written config to flip `issue_locale`, and appends `" (patched issue_locale=ru)"` (or similar) to `$CONFIG_LINE` in the announce. The patch itself is sensible adaptation — the channel is wrong. `$CONFIG_LINE` is what the wrapper emitted; if you augment it with a free-form suffix, downstream parsers can't tell wrapper-output from post-edit-narration, and the structural coupling breaks. Two correct paths instead: (a) pass the right `--issue-locale` to the wrapper at invocation (Step 4 auto-init bash now detects Cyrillic/CJK in `$ARGUMENTS` for this exact reason — extend it if your case isn't covered); (b) edit the file as a separate, clearly-separate step AFTER Phase 0 completes, and do NOT touch `$CONFIG_LINE`.

20. **Bypassing CODEOWNERS** — never `--reviewer @other` past auto-request; never disable CODEOWNERS-driven specialist routing without explicit `--no-codeowners`.
21. **Producing a 2000-line PR** — Phase 3.0 blocks. If you hit the threshold, the plan was wrong, not the implementation. Re-plan into smaller issues.
22. **Skipping Sonnet self-review** — Phase 2.5 catches what Phase 3 would catch but cheaper. `--no-self-review` is emergencies only.
23. **Shell-injecting `{title}`/`{labels}` into tracker command strings** — user-controlled `$ARGUMENTS` reaches `{title}`. Title like `x" --milestone 5 --label injected "y` smuggles CLI flags through naive shell substitution. **`shlex.quote` is NOT sufficient fallback** — when template wraps `{title}` in `"..."`, a `"` inside title closes the surrounding quote. Built-in github/gitlab MUST execute argv-safe (env-var-passed values); custom trackers MUST use argv-array `commands` form. JSON Schema enforces: string-form `commands.<op>` with `{title}`/`{labels}` fails validation. See [`trackers.md`](trackers.md) §Security.
24. **Compressing structured output when caveman is active** — caveman style applies to natural-language framing ONLY. Code, file paths, error messages, JSON, diffs, Phase 2.5 `claimed_status: ready` self-review block, Phase 4.11 metrics JSONL, final announce format are LITERAL strings parsed by downstream tooling. Compressing them breaks parsing.

## Opt-in only (apply only when configured)

These fire ONLY when corresponding config feature is enabled — without config, they don't apply:

- **Skipping CI gate before announce** — only if `ci.required: true`. For local-only setups (no `ci` block) Phase 2/3 build/lint/test is the gate.
- **Auto-merge without CI configured** — `auto_merge.enabled: true` + `ci.required: false` = automated hand grenade. Phase 4 warns; user must explicitly accept.
- **Frontend feature without flag** — only if `feature_flags.system` configured AND scope requires.
- **High task without ADR** — only if `adr.dir` configured AND architectural decision involved.
- **Public API change without docs update** — only if `public_docs_dir` configured.
- **Long-running branch (>50 commits behind main)** — Phase 2.0 blocks per `stale_main.block_commits_behind`.

## Universalization-specific (post-rewrite, low-frequency)

- Hardcoding repo paths / build commands / specialists in SKILL.md (all project-specific values come from `config.json`)
- Hardcoding `gh` calls in references (use `{Tracker.OP}` abstraction)
- Hardcoding `i{N}` / `feat/i{N}-...` (use `config.naming` placeholders for Linear / Jira prefixed IDs)
- Skipping config validation
- Inlining multi-line bodies into shell commands (use `mktemp` + `{body_file}`)
