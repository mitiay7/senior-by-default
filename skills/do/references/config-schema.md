# do.config.json schema — read path

Runtime reference for **reading** an existing `.claude/do/config.json`: where it lives, how paths resolve, what each field means, and the no-config defaults. **Creating or editing a config** (Phase 0 auto-init, hand-authoring a whole file) → read [`config-authoring.md`](config-authoring.md) instead — it carries the full annotated schema, the telemetry JSONL entry shape, and example configs. The machine-readable source of truth is [`config.schema.json`](config.schema.json).

## Location & discovery
Place at `<workspace_or_repo_root>/.claude/do/config.json`. The skill walks up from CWD to find the first match. None found → use the defaults below (and Phase 0 auto-init offers to write one — see [`config-authoring.md`](config-authoring.md)).

The skill **reads but never writes** config on a normal run. Hand-edited (or written once by auto-init).

Validate with [`config-validation.md`](config-validation.md) on every load.

## Path resolution

All path-bearing fields (`context_doc.path`, `tech_debt_doc`, `lessons_doc`, `i18n.locale_files`, `worktree.base`, `ui_gate.login_script`, `metrics.log_path`, `adr.dir`, `public_docs_dir`, etc.) accept either:

- **Absolute path** — used as-is
- **Relative path** — resolved against the **directory containing `config.json`** (NOT the current working directory). For workspace configs at `/path/to/workspace/.claude/do/config.json`, a relative `docs/AGENT_CONTEXT.md` resolves to `/path/to/workspace/docs/AGENT_CONTEXT.md`.

`~` (home tilde) is expanded.

Validators (Phase 0 Step 1) and runtime path checks MUST apply this rule consistently.

## Field semantics

The full annotated JSON shape of every field lives in [`config-authoring.md`](config-authoring.md) §"Full schema"; below is what each field *means* when the skill reads it. **No field is strictly required** — `version` is recommended (validators default to `1` + warn if omitted; an explicit `version: 2` mismatch is a hard failure), every other field is optional and falls back to the defaults documented here.

### Core (universal)

#### `workspace`
Multi-repo setups. `repos.<key>.scope_keywords` drives Phase 0 Step 3 routing. Multiple matches → fullstack. Omit for single-repo.

#### `issue_tracker`
`type` options: `github` (default, uses `gh`), `gitlab` (uses `glab`), `none` (skip Phase 1), `custom` (requires `commands` block). See [`trackers.md`](trackers.md).

Omitted `type` = `github` — and `repo` is still required (every `gh` call passes `--repo`). The schema enforces exactly this: the github/gitlab branch fires on omitted type, and only an explicit `type: "custom"` demands a `commands` block. Pre-fix, the custom branch fired vacuously on omitted type, rejecting the documented github-default shorthand `{"repo": "owner/name"}`.

#### `context_doc`
Sonnet reads it before exploring. `sections` = name → number-or-anchor map. `required_for_finalize: true` → Phase 4.6 BLOCKS. `allow_main_push: true` (default false) opts a SEPARATE docs repo into Phase 4.6's direct-push delivery — the sole scoped exception to "never commit to main"; without it, docs-repo delivery goes through a short-lived branch + PR (phase-4 §4.6 Delivery). Ignored when the context doc lives in the task's code repo.

#### `i18n`, `ui_gate`, `contract_gate`
Each enables the corresponding Phase 3 gate. Omit → gate skipped.

#### `specialists`
`subagent_type` lists for parallel review. Omit → Opus inline review fallback. A CONFIGURED entry whose plugin is unavailable at spawn time also falls back to Opus inline — per seat, announced, never Sonnet (audit #9; [`phase-2-implementation.md`](phase-2-implementation.md) Plan Review, [`phase-3-review.md`](phase-3-review.md) §3.6). Auto-init writes only entries verified against `~/.claude/plugins/installed_plugins.json` ([`phase-0-setup.md`](phase-0-setup.md) Step 4). The full default preset is shown in [`config-authoring.md`](config-authoring.md) §"Full schema".

#### `naming`
Branch/worktree/ref formats. Defaults match `i{N}` convention. Override for Linear / Jira / etc.

#### `issue_locale`
Language for issue/PR bodies. Any ISO 639-1 code, optional region: `en`, `ru`, `ja`, `ko`, `pt-BR`, … — the schema validates by pattern (`^[a-z]{2}(-[A-Z]{2})?$`), NOT an enum. Phase 0 auto-init detects `ru`/`ja`/`ko` from `$ARGUMENTS`; the value it detects must always be schema-valid (the old `["ru","en"]` enum made auto-init reject its own ja/ko detection). Default `en`.

#### `memory_path`, `acceptance_extensions`
See previous schema documentation.

#### `worktree`
Two styles, picked by whether `base` is set:

| `worktree.base` | Worktree path | Style | Use case |
|---|---|---|---|
| Set to absolute parent dir | `{base}/{repo_name}-{suffix}` | **Sibling** (next to repo) | Multi-repo workspaces where you want worktrees adjacent to the original repos |
| Unset / null | `{repo_path}/.claude/worktrees/{suffix}` | **Claude Code** (inside repo's `.claude/`) | Single-repo monorepos; aligns with Claude Code Agent tool conventions |

`{suffix}` derives from `config.naming.{low|issue}.worktree_suffix`.

`cleanup_cmd` (optional) — template for the cleanup command suggested in Phase 4.8. Substitutions: `{repo}`, `{suffix}`, `{branch}`, `{slug}`. If unset, Phase 4.8 falls back to `git worktree remove` + `branch -D`.

**Critical**: never use the Agent tool's `isolation: "worktree"` parameter for Phase 2 — it auto-names branches and breaks `config.naming`. Always pre-create the worktree explicitly via `git worktree add` (Opus's job per [`phase-2-implementation.md`](phase-2-implementation.md) "Worktree setup"), then spawn `Agent(model: "sonnet")` without isolation, passing the worktree path in the prompt.

### Distributed-team integrations

#### `ci`
**Opt-in.** Default OFF — Phase 4.2.5 skipped unless `required: true` is explicitly set. Most setups (solo dev, local-only test running, projects without cloud CI) have nothing to wait for; gating on non-existent checks just times out.

Set when your team relies on cloud CI (GitHub Actions, GitLab CI, CircleCI, etc.) as the merge gate:
- `required: true` — turn the gate ON
- `wait_command` — polling/blocking command. Suggested defaults (override via this field): `gh pr checks {N} --watch --interval 30` for github, `glab ci status --branch {branch} --wait` for gitlab
- `timeout_seconds` — abort wait after N seconds, escalate to user (default 1800)
- `fail_action: "block"` — failed checks → return to Sonnet via Phase 3 retry; `"warn"` — warn but proceed (default "block")

For local-only CI workflows (lefthook, manual `make test`), build/lint/test are already enforced by Phase 2/3 directly — leave `ci` unset. Optionally add a `_note` field documenting why for future-self / teammates. Note: explicit `required: true` is also the `auto_merge` precondition (below) — leaving `ci` unset keeps auto-merge behind a per-run confirmation.

#### `auto_merge`
After PR creation (Phase 4.2), enable auto-merge so PR merges automatically when CI passes + required reviews approve.
- **Precondition (single-sourced in [phase-4 §4.2.6](phase-4-pr.md))**: fires only when `ci.required` is explicitly `true` AND that run's §4.2.5 CI gate passed. `false`/unset/no-`ci`-block → per-run hand-grenade warning + explicit confirmation, else `await_review`. `enabled: true` alone never merges unverified.
- `enabled: false` by default (opt-in — auto-merge is risky)
- `method` — `squash` (default), `merge`, or `rebase`
- `delete_branch: true` — clean up branch after merge
- Override per-task: `--auto-merge` or `--no-auto-merge` in `$ARGUMENTS`

#### `pr_size`
Phase 3.0 (pre-gate) check. The `pr-size-check` wrapper measures the diff itself (`--repo`) — the spec never pre-computes counts.
- `warn_lines: 800` (default) — warn user, proceed
- `warn_files: 20`
- `block_lines: 2000` — over this, the change cannot ship as ONE PR
- `block_files: 50`
- `generated_paths: []` (default) — globs for **machine-generated files committed to the repo** (`["openapi/*.json", "**/*.pb.go"]`). Their lines/files are subtracted from the counted size: a reviewer doesn't read them line by line, a drift check in CI keeps them correct, so counting them measures the wrong thing and forces serial threshold bumps. Both enforcement tiers honor it — the wrapper reads the key, the PreToolUse hook delegates *to the wrapper* — so gate and hook can't split WARN/BLOCK on one diff. The excluded volume is always printed alongside the counted one (`900 handwritten + 1200 generated = 2100 total lines`); it is never hidden. There is no per-run CLI flag, on purpose: the list can only come from the repo's committed config, so it can't be widened to argue a BLOCK down. Globs: `*` doesn't cross `/`, `**` does, `?` = one non-`/` char, a slash-free pattern matches at any depth, a trailing `/` means everything under; no character classes.
- `auto_split: true` (default) — on a BLOCK, Phase 4.2.1 auto-splits delivery into a **stack of sub-cap PRs** (`pr-split` wrapper) each ≤ the WARN caps, reviewed once as a unit and merged in order; the run ends `ready_for_review` with *k* open PRs. Set `false` (or pass `--no-split`) to revert to the pre-0.11 hard halt: draft PR + `blocked` label, user splits manually.

#### `stale_main`
Phase 2 (before each implementation attempt) check via `git rev-list --count HEAD..origin/main`.
- `warn_commits_behind: 20` — warn, proceed
- `block_commits_behind: 50` — require rebase before continuing
- `auto_rebase: false` — if `true`, auto-attempt `git rebase origin/main`; on conflict, escalate

#### `self_review`
Phase 2 task 5.5: Sonnet reviews own diff against acceptance criteria before reporting done. Reduces Phase 3 cycles 30-50% per industry data.
- `enabled: true` by default. Override per-task: `--no-self-review`.

#### `codeowners`
Phase 3.6 specialist routing + PR reviewer auto-request via CODEOWNERS file.
- `paths` — search order; first existing file wins
- `agent_map` — map CODEOWNERS group/handle → `subagent_type` for that group's audit. Specialists from this map merge with `config.specialists.*` lists for the audit phase.

---

## Experimental / niche fields

The following config sections are accepted by validators but have **incomplete implementation** or **untested production paths**. Leave unset unless you specifically know what you want and accept the rough-edge risk. Not removed for back-compat — may be promoted or deprecated in a future release based on real-usage signal.

#### `wip_limit`
**Opt-in, no default.** Omit the field → the Phase 0 Step 1 WIP check is skipped entirely.

If set to a positive integer: Phase 0 counts `git worktree list` across known repos + open issues assigned to user. Over limit → warn (never block).

The feature originates from Kanban WIP limits for human teams (where context-switching is real cost). For AI-orchestrated workflows with isolated agent contexts, parallel sessions are usually beneficial — leave unset unless you have a specific reason for a soft ceiling.

#### `concurrent_edit_check`
Phase 1 check (M/H — runs right after the planned-files list is derived; moved from Phase 0 Step 5, which predated that list — audit #19). **Warns on IN-FLIGHT work only**: unmerged remote branches and other live worktrees touching planned files ([`phase-1-issue.md`](phase-1-issue.md) §Concurrent-edit). Merged-history activity within `lookback_days` (default 7) is demoted to an INFO line — production telemetry showed the old merged-history warn produced 0 true positives in 13 checks with documented false alarms (2026-07-17 re-audit). Warn-only either way; this gate never blocks.

#### `feature_flags`
Phase 1 (issue body) + Phase 2 (Sonnet rule) integration.
- `system` — known: `launchdarkly`, `growthbook`, `unleash`, `env` (env-var-based), `custom`
- `required_for_scopes` — scopes that MUST gate behind a flag (typically `["frontend", "fullstack"]`)
- Generated flag name: `{naming_convention applied to issue slug}` (e.g. `add_user_avatars` for snake_case)
- Adds acceptance criterion: "Feature gated behind flag `{flag}` in `{system}`; default `{default_state}`"

#### `adr`
Architecture Decision Records — generated for High complexity tasks (or per `min_complexity`).
- `dir` — where ADRs live
- `min_complexity: "high"` — only High triggers ADR by default; can be `"medium"`
- `filename_format` — `{NNNN}` auto-incremented from highest existing
- Sonnet writes ADR after plan approval (Step 2 of High path); committed with implementation

#### `affected_graph`
Monorepo support: scope build/test to affected projects.
- `tool: "auto"` — detect from `nx.json` / `turbo.json` presence
- Overrides cache.test_cmd / lint_cmds when affected-graph is in use
- `base_ref` — comparison base for "affected" calculation

#### `security_scan`
Phase 3.0.5 — dependency vulnerability scan based on detected stack.
- `threshold` — minimum severity to fail. `high` (default) blocks high+critical; warns moderate.
- Auto-selected per package_manager:
  - `npm`/`pnpm`/`yarn` → `npm audit --audit-level={threshold} --json`
  - `go` → `govulncheck ./...`
  - `cargo` → `cargo audit`
  - `pip`/`uv`/`poetry` → `pip-audit` or `safety check`
  - `bundler` → `bundle audit`
  - `composer` → `composer audit`
- Override via `command_override_by_pm`

#### `notifications`
Async-friendly broadcasts via webhook.
- Set `slack_webhook` or `teams_webhook` (or both)
- `events` — which Phase boundaries trigger notification
- `templates` — Mustache-style templates with `{title}`, `{N}`, `{url}`, `{summary}` placeholders

#### `public_docs_dir`
Phase 3 check: if diff modifies public API surface AND `public_docs_dir` exists, verify corresponding docs touched. Mismatch → warn (or block if `required` flag added later).

#### `lessons_doc`
Phase 4.10: optional prompt "Anything surprising worth recording?" → append to this doc.

#### `metrics`
Phase 4: append per-task JSONL entry to `log_path`. For DORA-ish self-analysis + skill evolution feedback loop. The full Tier-1 entry shape (and the gate-vocabulary rules) live in [`config-authoring.md`](config-authoring.md) §"Telemetry JSONL entry schema"; the `metrics-append` wrapper owns and enforces it.

Two documented opt-outs, both schema-valid (nullable like `ui_gate`):
- `metrics: null` — explicit opt-out; `config-ensure-metrics` respects the null and never re-patches the default preset in
- `metrics.log_path: null` — keep the block, disable JSONL emission entirely (this is the opt-out auto-init's `_setup_notes` advises)

- `log_path` supports `{repo_slug}` placeholder (resolves to last segment of repo path, lowercased, non-alphanum → `-`)
- `include_phase_durations` — track per-phase wall-clock for cycle-time analysis
- `tier: 1` — selects what to capture. `0` = minimal (just outcome + gate pass/fail), `1` = structured failure details + self-review calibration + specialist iterations (recommended for skill iteration feedback), `2` = reserved for future `/do-review` companion skill that auto-summarizes patterns
- `capture_failure_details` — when a gate fails, include `details` block: which strings unwrapped (i18n), which fields mismatched (contract), which packages vulnerable (dep_vuln), how many lines/files (pr_size), etc.
- `capture_self_review_calibration` — Phase 2.5 self-review claims are recorded; Phase 3 outcomes are compared; calibration computed: `accurate` (claim matched reality), `false_positive` (claimed clean, Phase 3 found issues), `false_negative` (claimed issues, Phase 3 found none). Recorded in **three** dimensions: `calibration` (legacy combined, back-compat), `calibration_defect` (real CODE defect missed — the de-confounded primary signal), and `calibration_size` (diff-size prediction; `n_a` when pr_size gate didn't run). The split exists because ~39% of historical `false_positive` entries fired ONLY `pr_size=warn` — diff-size noise, not code defects. All three verdicts are computed **inside the `metrics-append` wrapper** from the raw inputs (gates, claimed status, specialist blockers, `size_assessment`, rebump flag) — hand-passed `--sr-calibration*` flags are optional cross-checks that hard-REJECT on contradiction. See [`phase-4-finalize.md`](phase-4-finalize.md) §4.11 "Calibration logic".
- `capture_specialist_iterations` — High-complexity Phase 3.6 records each cycle's auditors / approvers / blockers with file:line citations
- `max_string_length` — truncate captured strings (error messages, code snippets) at this length to keep JSONL parseable

#### `postmortem`
Phase 0 detection: if `$ARGUMENTS` matches `trigger_keywords` OR branch matches `branch_prefixes` → suggest postmortem template addition to issue body / link to a separate `/postmortem` skill.

Defaults if `postmortem` is omitted entirely:
- `trigger_keywords`: `["incident", "regression", "postmortem", "outage", "p0", "p1", "hotfix", "revert"]`
- `branch_prefixes`: `["fix/", "hotfix/"]`
- `template_path`: null (use built-in template — see Phase 1 issue-body section)

Override either array to customize. Set `trigger_keywords: []` AND `branch_prefixes: []` to effectively disable.

## Defaults if no config

- Single-repo: CWD must be inside a git repo
- All Phase 1-4 features above: skipped or use built-in defaults (CI gate OFF (opt-in only — most setups have no cloud CI), auto-merge OFF, self-review ON, PR-size guard ON with the `pr_size` thresholds above (warn 800/20, block 2000/50), stale-main check ON with the `stale_main` thresholds above (warn 20 / block 50 — Phase 2.0.5 applies them whether or not `stale_main` is configured), CODEOWNERS routing ON if file exists, WIP limit OFF (opt-in only), concurrent-edit check ON, security scan ON with threshold "high", everything else OFF)
- Acceptance extensions: none
- Issue locale: en
- Memory path: auto
