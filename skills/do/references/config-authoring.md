# do.config.json — authoring & full schema reference

**Load this file only when CREATING or EDITING a `.claude/do/config.json`** — Phase 0 auto-init (which writes a config), or hand-authoring/reviewing a whole file. A steady-state run that only *reads* an existing config does **not** need this file; the read-path reference (location, path resolution, per-field semantics, defaults) lives in [`config-schema.md`](config-schema.md). The machine-readable source of truth for the shape is [`config.schema.json`](config.schema.json); this file is its annotated human companion.

## Full schema

**No fields are strictly required.** `version` is *recommended* — it identifies the schema version. If omitted, validators default to `1` and emit a warning (back-compat for early hand-written configs). Explicit mismatches (`version: 2` against this schema) are hard failures.

All other fields are optional; missing fields fall back to defaults documented in [`config-schema.md`](config-schema.md) §"Field semantics" / §"Defaults if no config". The JSON Schema in [`config.schema.json`](config.schema.json) reflects this — `version` is **not** in the schema's `required` array.

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
    "required_for_finalize": true,
    "allow_main_push": false
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

  // Default preset written by config-init (its jq literal is the source of truth;
  // auto-init filters entries against installed plugins). Shown in full because a
  // 2026-07 audit misread the placeholder version and recommended removing an agent
  // from a preset it was never in — document reality, not shapes:
  "specialists": {
    "backend_plan":    ["backend-development:backend-architect", "backend-development:security-auditor", "database-design:database-architect"],
    "frontend_plan":   ["ui-design:design-system-architect", "ui-design:ui-designer", "javascript-typescript:typescript-pro"],
    "backend_audit":   ["code-refactoring:code-reviewer", "backend-development:backend-architect", "backend-development:security-auditor"],
    "frontend_audit":  ["code-refactoring:code-reviewer", "ui-design:ui-designer", "pr-review-toolkit:silent-failure-hunter", "ui-design:accessibility-expert"],
    "migration_audit": ["database-design:database-architect"]
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
    "block_files": 50,
    "auto_split": true
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

## Telemetry JSONL entry schema (Tier 1)

The shape `metrics-append` writes when `metrics.tier: 1` — consulted when working on the config's `metrics` block or the telemetry system, never when reading config for a run (the `metrics-append` wrapper owns and enforces this shape; see [`config-schema.md`](config-schema.md) §"Field semantics" `#### metrics` for the field-by-field meaning).

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

## Examples

Live at repo root, not inside the skill (paths assume the plugin layout `<plugin>/skills/do/references/`):

- [`multi-repo-go-react-config.json`](../../../examples/multi-repo-go-react-config.json) — full multi-repo workspace (Go + React + docs)
- [`minimal-config.json`](../../../examples/minimal-config.json) — single-repo + GitHub
- [`python-fastapi-config.json`](../../../examples/python-fastapi-config.json) — Python + Alembic
- [`rust-workspace-config.json`](../../../examples/rust-workspace-config.json) — Rust + GitLab
