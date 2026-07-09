# do.config.json schema

## Location & discovery
Place at `<workspace_or_repo_root>/.claude/do/config.json`. The skill walks up from CWD to find the first match. None found → use defaults below.

The skill **reads but never writes** config. Hand-edited.

Validate with [`config-validation.md`](config-validation.md) on every load.

## Path resolution

All path-bearing fields (`context_doc.path`, `tech_debt_doc`, `lessons_doc`, `i18n.locale_files`, `worktree.base`, `ui_gate.login_script`, `metrics.log_path`, `adr.dir`, `public_docs_dir`, etc.) accept either:

- **Absolute path** — used as-is
- **Relative path** — resolved against the **directory containing `config.json`** (NOT the current working directory). For workspace configs at `/path/to/workspace/.claude/do/config.json`, a relative `docs/AGENT_CONTEXT.md` resolves to `/path/to/workspace/docs/AGENT_CONTEXT.md`.

`~` (home tilde) is expanded.

Validators (Phase 0 Step 1) and runtime path checks MUST apply this rule consistently.

## Full schema

**No fields are strictly required.** `version` is *recommended* — it identifies the schema version. If omitted, validators default to `1` and emit a warning (back-compat for early hand-written configs). Explicit mismatches (`version: 2` against this schema) are hard failures.

All other fields are optional; missing fields fall back to defaults documented below. The JSON Schema in [`config.schema.json`](config.schema.json) reflects this — `version` is **not** in the schema's `required` array.

```json
{
  "version": 1,

  "workspace": {
    "is_workspace": true,
    "repos": {
      "<repo-key>": {
        "path": "/abs/path/to/repo",
        "scope_keywords": ["..."]
      }
    }
  },

  "issue_tracker": {
    "type": "github" | "gitlab" | "none" | "custom",
    "repo": "owner/repo",
    "required_labels": ["..."],
    "optional_labels": ["..."],
    "domain_labels": ["..."],
    "commands": { "list_open": "...", "create": "...", "view_body": "...", "edit_body": "...", "comment": "...", "view_url": "...", "close_keyword": "Closes" }
  },

  "context_doc": {
    "path": "/abs/or/rel/path/AGENT_CONTEXT.md",
    "sections": { "current_state": 6, "structure": 4, "deployment": 11, "constraints": 12 },
    "required_for_finalize": true
  },

  "tech_debt_doc": "/abs/or/rel/path/tech-debt.md",

  "i18n": {
    "fn": "t",
    "locale_files": ["path/to/en.json", "path/to/ru.json"],
    "ui_extensions": [".tsx", ".jsx"]
  },

  "ui_gate": {
    "infra_cmd": "make up",
    "dev_cmd": "pnpm dev",
    "url": "http://localhost:3000",
    "login_script": "/abs/path/login.sh"
  },

  "contract_gate": {
    "frontend_types_path": "packages/shared/src/api/",
    "backend_handlers_path": "internal/api/"
  },

  "specialists": {
    "backend_plan": ["agent1", "agent2"],
    "frontend_plan": ["..."],
    "backend_audit": ["..."],
    "frontend_audit": ["..."],
    "migration_audit": ["..."]
  },

  "naming": {
    "low":   { "worktree_suffix": "do-{slug}",   "branch": "feat/{slug}" },
    "issue": { "worktree_suffix": "i{N}",        "branch": "feat/i{N}-{slug}", "ref_format": "i{N}" }
  },

  "issue_locale": "en" | "ru" | "ja" | "ko" | "pt-BR" | ...,   // any ^[a-z]{2}(-[A-Z]{2})?$ code — pattern, not an enum

  "worktree": {
    "base": "/abs/path/parent",
    "cleanup_cmd": "/abs/script.sh done {repo} {suffix}"
  },

  "memory_path": "auto" | "/abs/path/MEMORY.md",

  "acceptance_extensions": [
    { "trigger_keywords": ["..."], "criterion": "..." }
  ],

  "ci": {
    "required": true,
    "wait_command": "gh pr checks {N} --watch --interval 30",
    "status_command": "gh pr checks {N} --required",
    "timeout_seconds": 1800,
    "fail_action": "block"
  },

  "auto_merge": {
    "enabled": false,
    "method": "squash" | "merge" | "rebase",
    "delete_branch": true,
    "command": "gh pr merge {N} --auto --{method}"
  },

  "pr_size": {
    "warn_lines": 800,
    "warn_files": 20,
    "block_lines": 2000,
    "block_files": 50
  },

  "stale_main": {
    "warn_commits_behind": 20,
    "block_commits_behind": 50,
    "auto_rebase": false
  },

  "self_review": {
    "enabled": true
  },

  "codeowners": {
    "enabled": true,
    "paths": [".github/CODEOWNERS", ".gitlab/CODEOWNERS", "docs/CODEOWNERS"],
    "agent_map": { "@team-frontend": "ui-design:ui-designer", "@team-platform": "backend-development:backend-architect" }
  },

  "wip_limit": null,

  "concurrent_edit_check": {
    "enabled": true,
    "lookback_days": 7
  },

  "feature_flags": {
    "system": "launchdarkly" | "growthbook" | "unleash" | "env" | "custom",
    "registry_path": "config/flags.json",
    "naming_convention": "snake_case",
    "default_state": "off",
    "required_for_scopes": ["frontend", "fullstack"]
  },

  "adr": {
    "dir": "docs/adr/",
    "min_complexity": "high",
    "template_path": null,
    "filename_format": "{NNNN}-{slug}.md"
  },

  "affected_graph": {
    "tool": "nx" | "turbo" | "auto",
    "base_ref": "origin/main",
    "test_command_override": null,
    "lint_command_override": null
  },

  "security_scan": {
    "enabled": true,
    "threshold": "low" | "moderate" | "high" | "critical",
    "command_override_by_pm": { "npm": "...", "go": "...", "cargo": "..." }
  },

  "notifications": {
    "slack_webhook": "https://hooks.slack.com/services/...",
    "teams_webhook": null,
    "events": ["task_started", "task_blocked", "task_completed"],
    "templates": { "task_started": "...", "task_blocked": "...", "task_completed": "..." }
  },

  "public_docs_dir": "docs/api/",

  "lessons_doc": "docs/lessons.md",

  "metrics": {                                            // or null = explicit opt-out (nullable like ui_gate)
    "log_path": "~/.claude/do/metrics/{repo_slug}.jsonl", // or null = keep block, disable JSONL emission
    "include_phase_durations": true,
    "tier": 1,
    "capture_failure_details": true,
    "capture_self_review_calibration": true,
    "capture_specialist_iterations": true,
    "max_string_length": 500
  },

  "postmortem": {
    "trigger_keywords": ["incident", "regression", "postmortem", "outage", "p0", "p1"],
    "branch_prefixes": ["fix/", "hotfix/"],
    "template_path": null
  }
}
```

## Field semantics

### Core (universal)

#### `workspace`
Multi-repo setups. `repos.<key>.scope_keywords` drives Phase 0 Step 3 routing. Multiple matches → fullstack. Omit for single-repo.

#### `issue_tracker`
`type` options: `github` (default, uses `gh`), `gitlab` (uses `glab`), `none` (skip Phase 1), `custom` (requires `commands` block). See [`trackers.md`](trackers.md).

Omitted `type` = `github` — and `repo` is still required (every `gh` call passes `--repo`). The schema enforces exactly this: the github/gitlab branch fires on omitted type, and only an explicit `type: "custom"` demands a `commands` block. Pre-fix, the custom branch fired vacuously on omitted type, rejecting the documented github-default shorthand `{"repo": "owner/name"}`.

#### `context_doc`
Sonnet reads it before exploring. `sections` = name → number-or-anchor map. `required_for_finalize: true` → Phase 4.6 BLOCKS.

#### `i18n`, `ui_gate`, `contract_gate`
Each enables the corresponding Phase 3 gate. Omit → gate skipped.

#### `specialists`
`subagent_type` lists for parallel review. Omit → Opus inline review fallback. A CONFIGURED entry whose plugin is unavailable at spawn time also falls back to Opus inline — per seat, announced, never Sonnet (audit #9; [`phase-2-implementation.md`](phase-2-implementation.md) Plan Review, [`phase-3-review.md`](phase-3-review.md) §3.6). Auto-init writes only entries verified against `~/.claude/plugins/installed_plugins.json` ([`phase-0-setup.md`](phase-0-setup.md) Step 4).

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
- **Precondition (single-sourced in [phase-4 §4.2.6](phase-4-finalize.md))**: fires only when `ci.required` is explicitly `true` AND that run's §4.2.5 CI gate passed. `false`/unset/no-`ci`-block → per-run hand-grenade warning + explicit confirmation, else `await_review`. `enabled: true` alone never merges unverified.
- `enabled: false` by default (opt-in — auto-merge is risky)
- `method` — `squash` (default), `merge`, or `rebase`
- `delete_branch: true` — clean up branch after merge
- Override per-task: `--auto-merge` or `--no-auto-merge` in `$ARGUMENTS`

#### `pr_size`
Phase 3.0 (pre-gate) check via `git diff main...HEAD --shortstat`.
- `warn_lines: 800` (default) — warn user, proceed
- `warn_files: 20`
- `block_lines: 2000` — STOP, suggest splitting into follow-up issues
- `block_files: 50`

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
Phase 0 Step 5 check: list recent commits touching planned files. Configurable lookback.
Recent commits → warn with author + SHA list (someone else may be editing nearby).

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
Phase 4: append per-task JSONL entry to `log_path`. For DORA-ish self-analysis + skill evolution feedback loop.

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

JSONL entry schema (Tier 1):
```json
{
  "ref": "i42",
  "title": "...",
  "started_at": "ISO8601",
  "ended_at": "ISO8601",
  "complexity": "M",
  "scope": "Frontend|Backend|Fullstack",
  "implementer": "sonnet|opus|haiku",
  "models": {
    "orchestrator": "opus",
    "implementer": "sonnet|opus|haiku",
    "specialists": ["backend-development:backend-architect", "code-refactoring:code-reviewer"]
  },
  "files_changed": 7,
  "lines_added": 320,
  "lines_deleted": 45,
  "phase_durations_seconds": {"0": 12, "1": 40, "2": 900, "3": 180, "4": 60},
  "review_cycles": 1,
  "gates": {
    "test": { "status": "pass" },
    "i18n": {
      "status": "fail",
      "fix_cycle": 1,
      "details": { "unwrapped_count": 4, "locale_drift": { "ru.json": ["users.greeting"] } }
    },
    "contract": {
      "status": "fail",
      "fix_cycle": 1,
      "details": { "mismatches": [{ "endpoint": "/api/users", "field": "createdAt", "be": "time.Time", "fe": "number" }] }
    },
    "pr_size": { "status": "warn", "details": { "lines": 950, "files": 12 } },
    "dep_vuln": { "status": "pass" },
    "ui_gate": { "status": "skipped", "skip_reason": "infra_unavailable" }
  },
  "self_review": {
    "performed": true,
    "claimed_status": "ready",
    "calibration": "false_positive",
    "calibration_defect": "false_positive",
    "calibration_size": "n_a",
    "miscalibrated": ["AC2: claimed implemented; Phase 3.3 found 4 unwrapped strings"]
  },
  "specialist_iterations": [
    {
      "cycle": 1,
      "auditors": ["backend-architect", "security-auditor"],
      "approvers": ["backend-architect"],
      "blockers": [
        { "agent": "security-auditor", "category": "input_validation", "file_line": "internal/api/users.go:42", "summary": "Unbounded query allows resource exhaustion" }
      ]
    },
    { "cycle": 2, "auditors": ["..."], "approvers": ["backend-architect", "security-auditor"], "blockers": [] }
  ],
  "ci_status": "green|red|skipped",
  "auto_merge": false,
  "outcome": "merged|ready_for_review|blocked",
  "blocked_reason": null,
  "complexity_rebumped_from": "M"   // OPTIONAL — present only when Phase 2.0 plan-size sanity check
                                    // re-routed the task to a higher tier. Value = original tier
                                    // before bump (T|L|M). Absent in entries where no re-bump
                                    // happened (the common case). Use this to measure plan-size-
                                    // check effectiveness — count of T→H / L→H / M→H entries
                                    // over time tells whether Phase 0 routing accuracy is
                                    // improving or plan-size is the load-bearing layer.
}
```

**Gate keys are a controlled vocabulary.** The `gates` object's keys are normalized by
the `metrics-append` wrapper to a canonical set (`build`, `lint`, `type_check`, `test`,
`dep_vuln`, `pr_size`, `i18n`, `contract`, `ui_gate`, `migration_audit`,
`specialist_audit`, `opus_review`, `public_docs`, `secret_scan`, `diff_scan`,
`plan_size`, `codeowners`, `stale_main`, `concurrent_edit`). Common aliases
(`tests`→`test`, `i18n_gate`→`i18n`, `ui`/`visual_verify`/`visual_smoke`→`ui_gate`,
`dep_vuln_go`/`dep_vuln_pnpm`→`dep_vuln`, `type-check`/`lint_typecheck`→`type_check`,
`go_vet`/`vet`→`lint`, …) are renamed automatically; gate statuses coerce to
`pass`|`warn`|`fail`|`block`|`skipped`. Keys with no canonical home (task-specific
ad-hoc checks) are preserved verbatim but flagged in the wrapper's `noncanon=` output.
See [`phase-4-finalize.md`](phase-4-finalize.md) §4.11 "Gate vocabulary" for the full
mapping and rationale. **Confounder warning for cross-cohort analysis:** the specialist
plugins were installed mid-stream (≈2026-05-17), so `false_positive`/`self_review`
calibration rates are NOT comparable across that boundary — pre-install cohorts had zero
specialist review, hence mechanically fewer findings. Segment any FP-rate trend on the
install date; see the `self_review` calibration split (`calibration_defect` /
`calibration_size`) for the de-confounded signal.

Set tier=0 to revert to lean metrics (just outcome + per-gate pass/fail/skip booleans).

#### `postmortem`
Phase 0 detection: if `$ARGUMENTS` matches `trigger_keywords` OR branch matches `branch_prefixes` → suggest postmortem template addition to issue body / link to a separate `/postmortem` skill.

Defaults if `postmortem` is omitted entirely:
- `trigger_keywords`: `["incident", "regression", "postmortem", "outage", "p0", "p1", "hotfix", "revert"]`
- `branch_prefixes`: `["fix/", "hotfix/"]`
- `template_path`: null (use built-in template — see Phase 1 issue-body section)

Override either array to customize. Set `trigger_keywords: []` AND `branch_prefixes: []` to effectively disable.

## Defaults if no config

- Single-repo: CWD must be inside a git repo
- All Phase 1-4 features above: skipped or use built-in defaults (CI gate OFF (opt-in only — most setups have no cloud CI), auto-merge OFF, self-review ON, PR-size guard ON with shown thresholds, stale-main check ON with shown thresholds (warn 20 / block 50 — Phase 2.0.5 applies them whether or not `stale_main` is configured), CODEOWNERS routing ON if file exists, WIP limit OFF (opt-in only), concurrent-edit check ON, security scan ON with threshold "high", everything else OFF)
- Acceptance extensions: none
- Issue locale: en
- Memory path: auto

## Examples

Live at repo root, not inside the skill (paths assume the plugin layout `<plugin>/skills/do/references/`):

- [`multi-repo-go-react-config.json`](../../../examples/multi-repo-go-react-config.json) — full multi-repo workspace (Go + React + docs)
- [`minimal-config.json`](../../../examples/minimal-config.json) — single-repo + GitHub
- [`python-fastapi-config.json`](../../../examples/python-fastapi-config.json) — Python + Alembic
- [`rust-workspace-config.json`](../../../examples/rust-workspace-config.json) — Rust + GitLab
