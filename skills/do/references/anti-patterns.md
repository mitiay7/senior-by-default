# Anti-patterns (what NOT to do)

Read this BEFORE finalizing any task as a sanity check (Phase 4 calls back into this list).

## Process
1. **Subjective reviews** ("rate 1-10", "looks fine") — pass/fail only against acceptance criteria
2. **Tests after review** — Phase 2 task; Test Gate (3.1) blocks review
3. **Scope creep in review** — log as new issue, never expand current task
4. **Opus writing code / Sonnet making architecture decisions** — roles are immutable
5. **Opus fixing code directly during review** — return to Sonnet, then re-run gates
6. **Issues without measurable acceptance criteria** — every checkbox must map to a verifiable fact
7. **Specialist review for Low tasks** — Opus diff scan only

## Memory & context
8. **Re-detecting stack on every run** — Phase 0.2 must use cache from `~/.claude/do/cache/<slug>.json` unless `--redetect` requested
9. **Re-exploring codebase instead of reading configured `context_doc`** — first step of every Sonnet prompt is to read it
10. **Ignoring tech-debt in Sonnet prompts** — always grep `config.memory_path` for module names if memory configured
11. **Finalizing without updating `context_doc`** when `required_for_finalize: true` — Phase 4.6 is BLOCKING; issue template includes it; completion comment must cite touched sections

## Git
12. Using `git checkout -b` instead of `git worktree add`
13. Committing secrets — `.env*`, `*.key`, `*.pem`, `credentials.*`, `*.secret`
14. Pushing without secret check (filenames + content inspection)
15. Orphaned worktrees — check at Phase 0.3, remind at Phase 4.8
16. **Hardcoded `Co-Authored-By` model name** — auto-detect current model from environment metadata
17. Force-pushing, amending, or any history rewrite on shared branches
18. Modifying `.git/config` or `core.hooksPath`

## Code
19. Hardcoded user-facing strings (only an anti-pattern if `config.i18n` set) — ALL must use `config.i18n.fn()`
20. Adding dependencies not listed in issue Requirements
21. Amending migration files during review — always write a NEW migration with a higher number
22. Backwards-compat shims, re-exports, `_unused` vars marked just-in-case — clean breaks only
23. Comments explaining WHAT (well-named identifiers do that) — only comment WHY when non-obvious

## Universalization-specific (post-rewrite)
24. Hardcoding repo paths, build commands, or specialists in SKILL.md — all project-specific values come from `config.json`; if it's not in config, it's not part of the skill
25. Ignoring `--redetect` request — when user explicitly asks to re-detect stack, blow away the cache file and start fresh
26. Loading reference files preemptively — references are progressive disclosure; load only when the corresponding phase fires
27. Hardcoding `gh` (GitHub CLI) calls in references — use `{Tracker.OP}` abstraction from [`trackers.md`](trackers.md) so GitLab / custom trackers work
28. Hardcoding `i{N}` / `feat/i{N}-...` naming — use `config.naming` placeholders so trackers with prefixed IDs (Linear, Jira) work
29. Skipping config validation — run [`config-validation.md`](config-validation.md) every Phase 0.0; broken config should fail loud, not produce garbage downstream
30. Inlining multi-line bodies into shell commands — write to `mktemp` file and pass `{body_file}` to avoid quoting hell across `gh` / `glab` / custom CLIs

## Distributed-team practices (HIGH)
31. **Skipping CI gate before announce** *(only if `config.ci.required: true` is explicitly set — opt-in)* — Phase 4.2.5 must wait for green checks; "build passes locally" ≠ "CI passes"; production deploys should not happen on red CI. For local-only setups (no `ci` block) this anti-pattern doesn't apply — Phase 2/3 build/lint/test enforcement is the gate.

31a. **Skipping Phase 4.11 metrics emission** when `config.metrics.log_path` is set — this is the feedback loop for skill iteration. The final announce MUST include `Metrics: <count> entries in <path>` (success) or `Metrics: APPEND FAILED — <reason>` (failure). Silent omission means the step was skipped, which corrupts the dataset and makes drift undetectable. Verify with `wc -l` after appending — if the file didn't grow by 1, retry or report failure.

31b. **Using `Agent(isolation: "worktree")` for Phase 2 implementation** — auto-creates worktrees with auto-named branches (`claude/funny-leakey-...`) that bypass `config.naming`. Always pre-create worktree explicitly via `git worktree add` (Opus's job, before spawning Sub-Agent). Sub-Agent gets the path passed in the prompt and works there without isolation. See [`git-rules.md`](git-rules.md).

31c. **Auto-named branches without `i{N}` issue id** for M/H tasks — branches MUST follow `config.naming.issue.branch` template (default `feat/i{N}-{slug}`). The `{N}` is what links commits, PRs, metrics entries, and tracker comments. Phase 4.1.0 validates and renames if needed; renames are flagged in metrics as Phase 2 spec violations.

31d. **Shell-injecting `{title}` or `{labels}` into tracker command strings** — user-controlled `$ARGUMENTS` reaches `{title}`. A title like `x" --milestone 5 --label injected "y` smuggles extra CLI flags through naive shell substitution into `gh`/`glab`/etc. Built-in github/gitlab MUST execute with argv-safe semantics (env-var-passed values, e.g. `gh issue create --title "$TITLE" ...`); custom trackers MUST use the argv-array `commands` form for any operation carrying user content. **`shlex.quote` is NOT a sufficient fallback** — when a string template wraps `{title}` in `"..."`, a `"` inside the title closes the surrounding quote regardless of how the substituted value is escaped. JSON Schema enforces this: string-form `commands.<op>` containing `{title}` or `{labels}` fails validation. See [`trackers.md`](trackers.md) §Security and §"Why the string form CANNOT carry user content".
32. **Bypassing CODEOWNERS** — never `--reviewer @other` past the auto-request; never disable CODEOWNERS-driven specialist routing without explicit `--no-codeowners`
33. **Producing a 2000-line PR** — Phase 3.0 blocks; if Sonnet hit the threshold, the plan was wrong, not the implementation. Re-plan into smaller issues
34. **Skipping Sonnet self-review** — Phase 2.5 catches what Phase 3 would catch but cheaper. `--no-self-review` is for emergencies only
35. **Migration without zero-downtime audit** — `migration_audit` specialist MUST apply the [`zero-downtime-migrations.md`](zero-downtime-migrations.md) checklist explicitly with PASS/FAIL per item; "looks fine" is not an audit
36. **Long-running branch (>50 commits behind main)** — Phase 2.0 blocks; either rebase or split the work; long-running branches accumulate merge conflicts and stale assumptions
37. **Auto-merge without CI configured** — if `config.auto_merge.enabled` but `config.ci.required: false`, you've automated a hand grenade. Phase 4 warns; user must explicitly accept the risk

## Distributed-team practices (MEDIUM/LOW)
38. **Frontend feature without flag** when `config.feature_flags.system` is set and scope requires it — Phase 1 acceptance criteria includes the flag; Phase 3.7 verifies wrap at entry point
39. **High task without ADR** when `config.adr.dir` is set and architectural decision involved — preserve the "why" for future engineers; ADRs are immutable history
40. **Public API change without docs update** — Phase 3.0.6 catches if `config.public_docs_dir` set; don't ship undocumented breaking changes
41. **Notification spam** — only Phase boundaries (`task_started`, `task_blocked`, `task_completed`); never per-cycle, per-gate, or per-commit
42. **Ignoring concurrent-edit warnings** — if Phase 0.3 says someone touched these files in last 7 days, coordinate; merging blind invites churn
