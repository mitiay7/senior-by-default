# Anti-patterns (what NOT to do)

Read this BEFORE finalizing any task as a sanity check (Phase 4 calls back into this list).

Grouped into 4 categories, ~20 distinct rules. Hot ones are bolded — those are the ones audit + production runs proved get violated most.

## Process

1. **Subjective reviews** ("rate 1-10", "looks fine") — pass/fail only against acceptance criteria. Includes: tests written after review (Phase 2 task — Gate 3.1 Build/Test Verify blocks review), scope creep (log as new issue, never expand current task), issues without measurable acceptance criteria.
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
10. **Committing secrets** — `.env*`, `*.key`, `*.pem`, `credentials.*`, `*.secret`, inline keys/tokens. The Phase 4.1.2 `secret-scan` wrapper owns this check over the FULL push range (`merge-base(origin/main, HEAD)..HEAD` — not `--cached`: earlier task commits never appear in the staged diff) and the push is dispatched on its exit code (§19g). Eyeballing the diff is not the gate.
11. **Hardcoded `Co-Authored-By` model name** — auto-detect from environment metadata. Never hardcode a model version.
12. **Auto-named branches without `i{N}` for M/H** — branches MUST follow `config.naming.issue.branch` (default `feat/i{N}-{slug}`). The `{N}` is what links commits/PRs/metrics/tracker. **Phase 4.0 runs BEFORE PR open and renames UNCONDITIONALLY — via the `branch-normalize` wrapper (§19j), never inline bash**. "Pre-spawned worktree" is NOT an excuse — the wrapper's `git branch -m` works on pre-spawned worktrees too. Renames flagged as `branch_rename` in the metrics entry's `--notes`.
13. **Using `Agent(isolation: "worktree")` for Phase 2** — auto-names branches (`claude/<adj>-<noun>`), bypasses `config.naming`. Pre-create worktree explicitly via `git worktree add`, then spawn Agent without isolation.

## Code

14. **Hardcoded user-facing strings** (only if `config.i18n` set) — must use `config.i18n.fn()`. Add keys to all `locale_files`.
15. **Adding dependencies not listed in Requirements**. Phase 3 dep-vuln scan also blocks at configured `security_scan.threshold`.
16. **Amending migration files during review** — always write NEW migration with a fresh UTC timestamp prefix (`date -u +%Y%m%d%H%M%S`). Never amend; never allocate "next free number" — parallel sessions all pick the same slot (2026-05-09 miro-rooms-rentals: three `/do` agents each picked `000036`).
17. **Backwards-compat shims** — clean breaks only. No re-exports, `_unused` vars, comment-explanations of WHAT.
18. **Skipping zero-downtime migration audit** when migration present — `migration_audit` specialist MUST apply the [`zero-downtime-migrations.md`](zero-downtime-migrations.md) checklist explicitly with PASS/FAIL per item; "looks fine" is not an audit.

## Distributed-team & enforcement

19. **The fabrication principle — every side-effect must be wrapper-owned with a tell.** This is the single root cause behind the entire 19-family and the most-violated class in production. **The orchestrator systematically skips inline spec-bash and fabricates plausible output** — it reads a threshold/template/case-statement in the spec, decides "looks fine", and composes the expected line without running anything (or writes its own free-form JSON). Soft "MANDATORY" prose does not fix this; neither does inline bash with the output literal visible in the spec (the orchestrator copy-pastes the literal).

    **The fix, every time:** move the side-effect + its literal strings into an external wrapper in `scripts/`; the spec only `$(invokes)` it and dispatches on the output. The wrapper embeds an **anti-fabrication tell** — a value the orchestrator cannot reproduce without running it (a resolved path, a probed-paths list, computed caps, a line-count delta, a breach/overage list). An announce/entry that can't be backed by a real wrapper run is then a *visible* bug, not a silent skip. Applies whether you are the spawned agent or a parent orchestrator — **if you're reading this, you are the executor; there is no "the other one" to defer to.**

    The instances (each is "bypassed the wrapper / hand-composed its output"). Tier-2 = wrapper (always on). Tier-3 = optional [hook](hooks.md) backstop that re-checks at the runtime level when enabled.

    | id | Side-effect → wrapper | Anti-fabrication tell | "you bypassed it" diagnostic | Tier-3 |
    |---|---|---|---|---|
    | 19a | metrics append → `metrics-append` (only path; `echo>>`/`Write`/`python -c >>` forbidden; self-review calibration verdicts + outcome↔blocked_reason consistency computed/enforced INSIDE the wrapper — hand-passed `--sr-calibration*` REJECTs on contradiction) | `OK pre=N post=N+1 path=… gates=… renamed=… noncanon=… cal=<c>/<d>/<s>` (pre/post line-count delta + wrapper-computed calibration echo) | final message has prose + no `Metrics:` line, OR entry uses drifted field names (`ts`/`insertions`/`verdict`/`outcomes` instead of `started_at`/`lines_added`/`outcome`); the 7 audited bypasses all missed the same 5 canonical fields; entry calibration inconsistent with its own `gates` object → direct write | **Stop hook** |
    | 19b | caveman detect → `check-caveman` | `(path: <resolved>)` (ACTIVE) or `(probed: <P1..P4>)` (NOT INSTALLED) — list built from the wrapper's array | `Caveman:` line lacking either suffix (hit twice in prod, 2026-05-17 miro-rooms + lea-web) | — |
    | 19c | config init → `config-init` (`Write`/`echo>`/`jq>`/`cat<<EOF>` forbidden; refuses overwrite/self/`$HOME`-root, schema-validates) | the emitted `Config:` line + written file at the resolved path | hand-composed `Config: AUTO-GENERATED →` with no file; OR **post-editing the file + appending ` (patched …)` to `$CONFIG_LINE`** — pass `--issue-locale` at invocation, or edit as a clearly-separate post-Phase-0 step that doesn't touch `$CONFIG_LINE` | — |
    | 19d | plan-size routing → `plan-size-check` | derived `[tell:<head8>:<ck>]` suffix on every verdict line — checksum over inputs + wrapper-internal caps + repo HEAD short-SHA (session-varying); not composable from spec text (the H ceiling and the formula live only in the wrapper) | a `Phase 2.0:` line missing the tell suffix or whose `<ck>` doesn't recompute from the printed inputs + HEAD; OR files/lines clearly over-bucket but `complexity_rebumped_from` absent (0/32 in the audit that motivated the wrapper); OR gate inputs with no source artifact (§2.0 input-provenance table: T/L description block, M/H issue `Est deltas`, H approved-plan deltas) | **PreToolUse hook** |
    | 19e | gate vocabulary → `metrics-append` normalization (v0.7.0) | OK-line `renamed=<R> noncanon=<list>` | `gates` object has obvious synonyms (`tests`, `i18n_gate`) the wrapper would have renamed → entry was direct `>>`/Write | (via 19a) |
    | 19f | PR-size verdict → `pr-size-check` (v0.7.0) | `breached: [..]` + `+N lines/+N files` overage; **BLOCK exits 3** (hard halt, can't degrade to advisory) | `gates.pr_size.status="warn"` with `details.lines > config.block_lines` — the wrapper would have emitted `block`. 8 prod PRs >2000 lines all shipped as `warn` before this wrapper | **PreToolUse hook** (matcher `Bash`, self-scopes to `gh pr create`/`glab mr create`; denies non-draft over block cap, `--draft` always passes — the §3.0 escape path) |
    | 19g | pre-push secret gate → `secret-scan` (the §4.1.2 push lives in the same bash block, dispatched on its exit code; `--cached` eyeballing forbidden — earlier task commits never appear in the staged diff, yet their blobs push) | verdict line with the REAL range SHAs + counts (`range <base7>..<head7> clean (N commits, M files; globs=8 patterns=7)`); **BLOCK exits 3** with a findings list (paths + pattern names, never the secret text) | a push with no `SECRETS PASS` in the transcript, or a `gates.secret_scan` tell whose SHAs don't match the branch's real merge-base/HEAD. The ONE irreversible skip: a pushed secret is revoke-and-rotate, not revert | **PreToolUse hook** (matcher `Bash`, self-scopes to `git push`) |
    | 19h | Phase 2 build/test evidence → `build-verify` (Gate 3.1: the ORCHESTRATOR re-runs cache build/lint/test in `$WORKTREE_PATH`; the implementer's self-reported exit codes are NEVER the gate — the report format literally asks Sonnet to write its own rc's, the same trust hole one level down); **FAIL exits 3** (return to Sonnet) | per-command `rc=<n> <n>ms <n>L tail=<8-hex>` — elapsed-ms + output-line-count + output-tail hash, not reproducible without running (a bare rc=0 is guessable and does NOT satisfy the tell standard) | `gates.build`/`test` = pass with no `Phase 3.1: VERIFY` line in the transcript; a leg `skipped` while the cache has commands for it (or `test` skipped on a Tests: YES task); **implementer report claimed PASS where the re-run FAILs → record `details.self_report_mismatch: true` and treat the report as fabrication-class** (feeds §4.11 calibration) | — (opt-in `ci.required` gate §4.2.5 re-proves post-push; it does not replace the pre-commit re-run on the default no-CI path) |
    | 19i | metrics-config patch → `config-ensure-metrics` (Phase 0 Step 1; direct Edit/Write of config.json to add/announce the `metrics` block forbidden; the spec prints state tokens only, never the full lines) | `(cfg=<cksum over jq -cS canonical JSON of the file actually read/written> …)` suffix on all three outcome lines; AUTO-ADDED adds `patched_at=<runtime clock>`, ALREADY CONFIGURED adds the real `keys=` count — auditors recompute the crc from the file on disk | a `Metrics config: ALREADY CONFIGURED / EXPLICIT OPT-OUT / AUTO-ADDED` line without the `(cfg=…)` suffix, or whose crc doesn't recompute from the config file — telemetry state was announced without running the wrapper (kills the metrics loop behind a green announce); spec-side `PATCH SKIPPED` / `SKIPPED (--no-metrics)` forms are copyable on purpose (honest degraded states) | — |
    | 19j | branch normalization → `branch-normalize` (Phase 4.0; owns slug kebab-normalization incl. Unicode/slash handling, `config.naming` template substitution, `-v2..-v9` collision suffixes, the `git branch -m` itself, old-remote-ref cleanup; computing `EXPECTED` in spec bash forbidden) | `head=<sha8>` (the repo's REAL HEAD at run time, session-varying) on the `BRANCH OK name=…` / `BRANCH RENAMED <old>→<new>` verdict; §4.13's `Complete. Branch:` value is a live `git rev-parse` read-back in the announce block, cross-checked against the §4.0 verdict | the v0.3.1 production violation: `Complete. Branch: feat/i{N}-…` announced while `git branch` still shows the `claude/<adj>-<noun>` auto-name; or a Phase 4.0 line with no `head=` tell / a `head=` that isn't the branch's real HEAD; or a push/PR on a branch that never appeared in a BRANCH OK/RENAMED verdict | — |

    Correction is identical in every row: **re-run the wrapper and use its real stdout** — never hand-compose, never post-annotate. The local `daily-report.sh` scanner (operator-side) surfaces bypassed metrics entries in a "Schema bypass" section, so 19a/19e bypasses are visible within a day even if a hook isn't enabled.

20. **Bypassing CODEOWNERS** — never `--reviewer @other` past auto-request; never disable CODEOWNERS-driven specialist routing without explicit `--no-codeowners`.
21. **Producing an over-block-threshold PR and shipping it as `warn`** — Phase 3.0's `pr-size-check` wrapper BLOCKS (exit 3) past `config.pr_size.block_*` (default 2000 lines / 50 files); block is a hard halt → draft PR + `blocked` label, not a mergeable `warn`. If you hit it, the plan was wrong, not the implementation — Phase 2.0 plan-size-check (the H ceiling is owned by the wrapper; its values appear nowhere in spec prose, on purpose) should have caught it at plan time and said SPLIT-REQUIRED. Re-plan into smaller issues. Never downgrade BLOCK to WARN to get a merge.
22. **Skipping Sonnet self-review** — Phase 2.5 catches what Phase 3 would catch but cheaper. `--no-self-review` is emergencies only.
23. **Shell-injecting `{title}`/`{labels}` into tracker command strings** — user-controlled `$ARGUMENTS` reaches `{title}`. Title like `x" --milestone 5 --label injected "y` smuggles CLI flags through naive shell substitution. **`shlex.quote` is NOT sufficient fallback** — when template wraps `{title}` in `"..."`, a `"` inside title closes the surrounding quote. Built-in github/gitlab MUST execute argv-safe (env-var-passed values); custom trackers MUST use argv-array `commands` form. JSON Schema enforces: string-form `commands.<op>` with `{title}`/`{labels}` fails validation. See [`trackers.md`](trackers.md) §Security.
24. **Compressing structured output when caveman is active** — caveman style applies to natural-language framing ONLY. Code, file paths, error messages, JSON, diffs, Phase 2.5 `claimed_status: ready` self-review block, Phase 4.11 metrics JSONL, final announce format are LITERAL strings parsed by downstream tooling. Compressing them breaks parsing.

## Opt-in only (apply only when configured)

These fire ONLY when corresponding config feature is enabled — without config, they don't apply:

- **Skipping CI gate before announce** — only if `ci.required: true`. For local-only setups (no `ci` block) the Phase 3.1 `build-verify` re-run is the gate (§19h) — the implementer's self-report never is.
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
