# senior-by-default

> **AI does the principal-engineer work. You ship the ideas.**

A multi-actor pipeline skill for [Claude Code](https://claude.ai/code) that takes a one-line task description and runs it through architect-grade review, senior-grade implementation, and gated quality checks — without standups, sprint planning, or scope-creep ceremony.

## What it actually does

You type:
```
/do add user avatars to settings page
```

The skill:

1. **Routes** by complexity (Trivial → Haiku, Low/Medium → Sonnet, High → Opus plan-review + Sonnet implementation).
2. **Creates an issue** in your tracker (GitHub or GitLab) with structured Acceptance Criteria, Implementation Hints, Build Checklist, and Worktree Setup.
3. **Spawns a sub-agent** in an isolated git worktree on a properly-named branch (`feat/i42-add-user-avatars`).
4. **Runs gates** in Phase 3: tests, UI rendering (via Claude Preview), i18n parity, BE↔FE contract alignment, dependency vulnerability scan, PR-size guard, optionally CODEOWNERS-routed specialist audit.
5. **Verifies, commits, pushes, opens PR.** Optionally waits for CI to go green and enables auto-merge.
6. **Updates your context doc**, logs metrics for skill-iteration feedback, sends async notifications.

The whole thing is configurable per project via `.claude/do/config.json`. Most features are skip-by-default — out of the box you get build/test enforcement, self-review, and PR-size guards. Everything else is opt-in.

## Why this vs. other "team of agents" skills

- **Three actors with strict role boundaries** — Opus *never* writes code (except with explicit `--implementer=opus` flag), Sonnet *never* makes architectural decisions, Haiku *only* does ≤2-file mechanical changes. Hierarchy is enforced, not aspirational.
- **Quality gates are pass/fail against acceptance criteria** — no "rate this 1-10" subjective review.
- **Zero-downtime migration audit** baked in: `DROP COLUMN` / `RENAME` / `NOT NULL`-without-default get blocked with expand-contract pattern suggested.
- **Self-review calibration metric** — Sonnet declares `claimed_status: ready` before Phase 3; Phase 3 outcomes are compared and `false_positive` rate tracked over time. The highest-signal data point for skill iteration.
- **Stack-aware**: detects Go / TS / Rust / Python / Ruby / PHP / JVM / Dart / .NET / Deno / Elixir, scans monorepo subdirs (`apps/`, `services/`, etc.) for marker files. Caches detection per repo.
- **Tracker-agnostic**: GitHub (`gh`) by default, GitLab (`glab`), or custom command templates for Linear/Jira/etc.

## Quick start

### 1. Install
```bash
curl -fsSL https://raw.githubusercontent.com/mitiay7/senior-by-default/main/install.sh | bash
```

Or manually:
```bash
git clone https://github.com/mitiay7/senior-by-default ~/.local/share/senior-by-default
mkdir -p ~/.claude/skills
ln -s ~/.local/share/senior-by-default ~/.claude/skills/do
```

### 2. (Optional) Add `+++` shortcut

Add to `~/.claude/CLAUDE.md`:
```md
## +++ Trigger
When a user message starts with `+++`, treat everything after `+++` as the argument and invoke the `/do` skill with that text.
```

Now `+++ fix payment retries` is shorthand for `/do fix payment retries`.

### 3. Configure your project

Drop `.claude/do/config.json` at your project root or workspace root. Start with the minimal example:

```bash
mkdir -p .claude/do
cp ~/.claude/skills/do/examples/minimal-config.json .claude/do/config.json
# Edit: set issue_tracker.repo to your owner/repo
```

For multi-repo workspaces, monorepo, Python, or Rust projects, see [`examples/`](examples/) for full configs.

Full schema: [`references/config-schema.md`](references/config-schema.md).

### 4. Run a task

```
/do add a /health endpoint that checks DB connectivity
```

That's it. Skill picks complexity, creates issue, runs Sonnet, gates the diff, opens PR.

## Architecture

```
┌─────────────────── Phase 0: SETUP ───────────────────┐
│ Find config → validate → resolve repo(s)            │
│ Stack detection (cached per repo)                   │
│ Duplicate / concurrent-edit / migration checks      │
│ Complexity routing (T/L/M/H)                        │
└────────────┬─────────────────────────────────────────┘
             │
   ┌─────────▼──────────┐
   │ Phase 1: ISSUE     │  M/H only — structured body with
   │ (in tracker)       │  acceptance criteria, build checklist,
   │                    │  worktree setup, completion checklist
   └─────────┬──────────┘
             │
   ┌─────────▼──────────┐
   │ Phase 2: PLAN +    │  Worktree pre-created by Opus.
   │ IMPLEMENT          │  High → specialist plan review (parallel)
   │ (Sonnet/Haiku)     │  Sonnet self-reviews before reporting done
   └─────────┬──────────┘
             │
   ┌─────────▼──────────┐
   │ Phase 3: REVIEW    │  Gates: PR-size · dep-vuln · public-docs ·
   │ (Opus + gates)     │  test · UI · i18n · contract · diff-scan ·
   │                    │  specialist audit (High) · Opus criteria
   └─────────┬──────────┘
             │
   ┌─────────▼──────────┐
   │ Phase 4: FINALIZE  │  Branch verify → commit → push → PR →
   │                    │  CI gate (opt-in) → auto-merge (opt-in) →
   │                    │  context doc update → metrics log →
   │                    │  notifications
   └────────────────────┘
```

Three Claude models with hard role boundaries — see [SKILL.md](SKILL.md) for the rule set and [`references/`](references/) for per-phase details.

## Configuration

The skill is driven entirely by `.claude/do/config.json`. Everything is optional — without a config, you get sensible defaults (single-repo, no issue tracker, no UI/i18n gates, build/test/lint enforcement only).

Common opt-in features:

| Feature | Set | Effect |
|---|---|---|
| GitHub issues + PRs | `issue_tracker.{type,repo}` | Phase 1 creates issue, Phase 4 opens PR with `Closes #N` |
| Living context doc | `context_doc.path` + `required_for_finalize: true` | Sonnet reads it before exploring; Phase 4.6 BLOCKS until it's updated |
| i18n gate | `i18n.{fn, locale_files}` | Phase 3.3 catches hardcoded strings + locale-key drift |
| UI gate | `ui_gate.{infra_cmd, dev_cmd, url}` | Phase 3.2 takes screenshots, checks console errors via Claude Preview |
| Specialist parallel review | `specialists.{backend_plan, frontend_audit, ...}` | Phase 2 (High) and Phase 3.6 spawn 2-3 reviewers in parallel |
| CI wait + auto-merge | `ci.required: true` + `auto_merge.enabled: true` | Phase 4 waits for green CI, then `gh pr merge --auto` |
| Slack/Teams notifications | `notifications.slack_webhook` | Phase 1/4 broadcast task lifecycle |
| Metrics for skill iteration | `metrics.log_path` + `tier: 1` | JSONL append per task; self-review calibration tracked |

See [`references/config-schema.md`](references/config-schema.md) for the full schema and [`examples/`](examples/) for ready-to-adapt configs.

## Recommended Claude Code plugins

The skill uses `subagent_type` strings from these plugins for parallel specialist review (Phase 2 plan review, Phase 3.6 audit). All optional — without them, Opus does inline review:

- `backend-development` — backend-architect, security-auditor
- `frontend-excellence` — react-specialist, component-architect, frontend-optimizer
- `database-design` — database-architect (zero-downtime migration audit)
- `code-refactoring` — code-reviewer
- `pr-review-toolkit` — silent-failure-hunter

If a referenced agent isn't installed, the skill falls back gracefully (no error, just no parallel specialist for that scope).

## Required tooling

- **Claude Code** with skill support
- **`git`** ≥ 2.5 (for `git worktree`)
- **`gh` CLI** authenticated (`gh auth login`) — for GitHub tracker
- **`jq`** — for parsing tracker output and config introspection
- **`python3`** — for JSON validation

For non-GitHub trackers: `glab` (GitLab), or custom command templates per `references/trackers.md`.

## Override flags

Pass these in the task argument:

| Flag | Effect |
|---|---|
| `--complexity=T\|L\|M\|H` | Force complexity bucket |
| `--implementer=opus\|sonnet\|haiku` | Override implementer (rare; see SKILL.md) |
| `--repo=NAME` | Force target repo (multi-repo workspace) |
| `--redetect` | Force stack re-detection (skip cache) |
| `--auto-merge` / `--no-auto-merge` | Per-task override |
| `--skip-ci-wait` | Don't wait for CI before final announce |
| `--no-self-review` | Skip Phase 2.5 self-review (emergencies) |
| `--no-codeowners` | Skip CODEOWNERS-routed review |
| `--no-notify` | Skip notifications for this task |

## Documentation map

- [`SKILL.md`](SKILL.md) — main skill file, Phase 0 entry point, top-level rules
- [`references/config-schema.md`](references/config-schema.md) — full config schema with all fields documented
- [`references/config-validation.md`](references/config-validation.md) — validation rules
- [`references/stack-detection.md`](references/stack-detection.md) — language/PM detection + cache mechanics
- [`references/trackers.md`](references/trackers.md) — GitHub / GitLab / custom tracker integration
- [`references/git-rules.md`](references/git-rules.md) — worktree, branch, commit, secrets
- [`references/phase-1-issue.md`](references/phase-1-issue.md) — issue body template, two-step pattern
- [`references/phase-2-implementation.md`](references/phase-2-implementation.md) — Sonnet prompt, plan review, self-review
- [`references/phase-3-review.md`](references/phase-3-review.md) — all gates, specialist audit, Opus review
- [`references/phase-4-finalize.md`](references/phase-4-finalize.md) — commit, push, PR, CI, auto-merge, metrics
- [`references/zero-downtime-migrations.md`](references/zero-downtime-migrations.md) — migration audit checklist, expand-contract pattern
- [`references/codeowners.md`](references/codeowners.md) — CODEOWNERS routing
- [`references/adr.md`](references/adr.md) — ADR template + numbering
- [`references/notifications.md`](references/notifications.md) — Slack / Teams webhook formats
- [`references/anti-patterns.md`](references/anti-patterns.md) — what NOT to do (sanity-check before announce)

## Troubleshooting

**`gh` not authenticated** → `gh auth login` (web flow). Required scopes: `repo`, `workflow`.

**Skill says "specialist not found"** → That `subagent_type` plugin isn't installed. Either install it (see Recommended plugins above) or remove it from `config.specialists.*` — Opus inline review takes over.

**Branch is `claude/funny-leakey-...` instead of `feat/i42-...`** → Phase 4.1.0 detects and renames automatically; metrics record this as a Phase 2 spec violation. If it keeps happening, your Opus instance is using `Agent(isolation: "worktree")` — see anti-pattern 31b in [`references/anti-patterns.md`](references/anti-patterns.md).

**Metrics not appearing in `~/.claude/do/metrics/*.jsonl`** → Skill is skipping Phase 4.11. Check the final announce — it MUST include `Metrics: <count> entries in <path>`. If it doesn't, that's a bug; file an issue with the announce text.

**`gh pr checks` times out** → You probably set `ci.required: true` but your repo doesn't have actual CI workflows running. Either set `ci.required: false` or wire up `.github/workflows/`.

**Stack detection wrong for monorepo** → If your stack markers (`go.mod`, `package.json`) live in subdirs (e.g., `apps/`, `App/`, `services/`), the detector scans depth-3. If still wrong: hand-edit `~/.claude/do/cache/<slug>.json` with correct values. Force re-detect with `--redetect`.

## Status

`v0.1.0` — early release. The architecture is stable; metrics-driven skill iteration is in progress. Expect Tier 1 metrics schema to evolve.

## License

[MIT](LICENSE) — Dmitry Bychkov, 2026.
