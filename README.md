# senior-by-default

You type:
```
/do add user avatars to settings page
```
or with the optional shortcut (set up by `install.sh`):
```
+++ add user avatars to settings page
```
(or `/senior-by-default:do add user avatars to settings page` if installed as a plugin — see [Install](#install).)

The skill creates an issue, spins up a worktree on `feat/i42-add-user-avatars`, has Sonnet implement it (with self-review), runs gated quality checks (PR-size, dep-vuln, i18n, contract, zero-downtime migration audit), opens the PR, and — if you opted in — waits for green CI and auto-merges.

> **AI does the principal-engineer work. You ship the ideas.**

A multi-actor pipeline skill for [Claude Code](https://claude.ai/code).

## What it actually does

1. **Routes by complexity** — Trivial → Haiku, Low/Medium → Sonnet, High → Opus plan-review + Sonnet implementation.
2. **Creates an issue** in your tracker (GitHub or GitLab) with structured Acceptance Criteria, Implementation Hints, Build Checklist, Worktree Setup.
3. **Spawns a sub-agent** in an isolated git worktree on a properly-named branch (`feat/i42-...`).
4. **Runs gates in Phase 3** — tests, UI rendering (via Claude Preview), i18n parity, BE↔FE contract alignment, dependency vulnerability scan, PR-size guard, optional CODEOWNERS-routed specialist audit.
5. **Verifies, commits, pushes, opens PR** — optionally waits for CI and enables auto-merge.
6. **Updates context doc** (if configured), logs metrics for skill-iteration feedback, sends async notifications.

The whole thing is configurable per project via `.claude/do/config.json`. Most features are skip-by-default — out of the box you get build/test enforcement, self-review, and PR-size guards. Everything else is opt-in.

## ⚠ Security & permissions

This skill performs writes against your git repo and your issue tracker:

- Creates issues in your tracker (GitHub/GitLab)
- Creates branches and worktrees
- Commits and pushes code
- Opens pull requests
- **With `auto_merge.enabled: true`** — merges to default branch when CI is green, without manual review

The skill inherits whatever auth `gh`/`git` already have on your machine — assume it can do anything *you* can do from your terminal. Audit `.claude/do/config.json` before committing it (it carries webhook URLs, repo names, branch templates). Read `install.sh` before running with `curl | bash`. Keep `auto_merge.enabled: false` until you've watched a few task cycles.

## Why this vs. other "team of agents" skills

- **Three actors with strict role boundaries** — Opus *never* writes code (except with explicit `--implementer=opus` flag), Sonnet *never* makes architectural decisions, Haiku *only* does ≤2-file mechanical changes.
- **Karpathy-style behavioral guardrails** — assumptions surfaced before side effects, simplest viable implementation, surgical diffs only, and verifiable goals for every non-trivial task.
- **Quality gates are pass/fail against acceptance criteria** — no "rate this 1-10" subjective review.
- **Zero-downtime migration audit** baked in: `DROP COLUMN` / `RENAME` / `NOT NULL`-without-default get blocked with expand-contract pattern suggested.
- **Self-review calibration metric** — Sonnet declares `claimed_status: ready` before Phase 3; Phase 3 outcomes are compared and `false_positive` rate tracked over time. The highest-signal data point for skill iteration.
- **Stack-aware**: detects Go / TS / Rust / Python / Ruby / PHP / JVM / Dart / .NET / Deno / Elixir, scans monorepo subdirs (`apps/`, `services/`, etc.) for marker files. Caches detection per repo.
- **Tracker-agnostic**: GitHub (`gh`) by default, GitLab (`glab`), or custom command templates for Linear/Jira/etc.

## Install

The two install paths invoke the skill with **different slash-commands** because plugins are namespaced. Pick one and stick to it:

| Install method | Slash-command | Customizable? |
|---|---|---|
| Plugin install (recommended) | `/senior-by-default:do <task>` | Skill name fixed by plugin manifest |
| Manual symlink (`install.sh` or by hand) | `/do <task>` | Yes — `install.sh` lets you rename via `SKILL_NAME` |

### Recommended — Claude Code plugin install

Once `senior-by-default` is listed in a marketplace you've added (or you point Claude Code at this repo as a marketplace):

```
/plugin install senior-by-default@mitiay7/senior-by-default
```

After install, run tasks with the **plugin-namespaced command**:

```
/senior-by-default:do add user avatars to settings page
```

If you want a `+++` shortcut, add this block to `~/.claude/CLAUDE.md` manually (the plugin path doesn't run `install.sh`, so the trigger isn't auto-installed):

```md
<!-- senior-by-default:trigger:start -->
## +++ Trigger

When a user message starts with `+++`, treat everything after `+++` as the argument and invoke the `/senior-by-default:do` skill with that text.
<!-- senior-by-default:trigger:end -->
```

### Manual — clone + symlink

For users who want to track `main` directly, hack on the skill, or use the bare `/do` command without a plugin namespace:

```bash
git clone https://github.com/mitiay7/senior-by-default ~/.local/share/senior-by-default
mkdir -p ~/.claude/skills
ln -s ~/.local/share/senior-by-default/skills/do ~/.claude/skills/do
```

Run tasks with `/do <task>` (no plugin namespace).

### One-liner (review the script first)

The `install.sh` is interactive — it asks for skill name (default `do`), trigger shortcut (default `+++`, `none` to skip), and install dir. It writes a symlink, optionally appends a marker-wrapped trigger block to `~/.claude/CLAUDE.md`, and runs dependency checks.

**This script does manual symlink install, NOT plugin install.** It registers `/do` (or your custom name), not `/senior-by-default:do`. **Read it first**: <https://github.com/mitiay7/senior-by-default/blob/main/install.sh>

```bash
curl -fsSL https://raw.githubusercontent.com/mitiay7/senior-by-default/main/install.sh | bash
```

Non-interactive (env vars override prompts):
```bash
SKILL_NAME=do TRIGGER=+++ INSTALL_DIR=~/.local/share/senior-by-default \
  curl -fsSL https://raw.githubusercontent.com/mitiay7/senior-by-default/main/install.sh | bash
```

## Configure your project

**Zero-touch by default — Phase 0 auto-generates `.claude/do/config.json` on first run.** When you run `/do` in a project that doesn't have one, the orchestrator detects context and writes a minimum-viable config without prompting:

- `issue_tracker.{type,repo}` from `git remote get-url origin` (github/gitlab/none, owner/repo auto-extracted)
- `issue_locale` from `$ARGUMENTS` script (Cyrillic → `ru`, Hiragana/Katakana/CJK → `ja`, Hangul → `ko`, else `en`; explicit `--issue-locale=<code>` wins)
- recommended `specialists` preset wiring the 6 Phase-3-audit plugins listed below
- documented tier-1 `metrics` preset (`~/.claude/do/metrics/{repo_slug}.jsonl` — cross-project, scannable by a single daily report)
- `_meta._setup_notes` listing exact `/plugin install` commands so the file is self-contained

The Phase 0 announce shows what was written verbatim — no parsing needed:
```
Config: AUTO-GENERATED → /path/to/repo/.claude/do/config.json
Metrics config: INCLUDED in auto-init
```

The file is left **unstaged** — you review and commit when ready. Subsequent `/do` runs re-read it on every Phase 0; no reload after extension.

### If your project already has a config

Phase 0 Step 1 loads it via the same path. If the file exists but **doesn't have a `metrics` block**, the orchestrator patches the documented tier-1 preset in idempotently — `_meta` is stamped with `last_patched_by` / `last_patched_at` / `last_patch_added` for observability. Existing `metrics: {...}` is left alone; explicit `metrics: null` (opt-out) is respected. Announce:
```
Config: LOADED /path/to/repo/.claude/do/config.json
Metrics config: AUTO-ADDED to /path/.../config.json    # or ALREADY CONFIGURED / EXPLICIT OPT-OUT
```

### Opt-outs (advanced)

| Flag in `$ARGUMENTS` | Effect |
|---|---|
| `--no-config-init` | Use in-session defaults; write nothing |
| `--no-specialists` | Auto-init config without the `specialists` preset (Opus inline review fallback) |
| `--no-metrics` | Skip metrics auto-config in both the Step 4 auto-init AND Step 1 patch paths |

### Customizing the auto-generated config

The auto-init writes the universally-useful minimum. For the rest — `context_doc`, `workspace.repos`, `ui_gate`, `acceptance_extensions`, `naming` overrides, `ci.required`, `auto_merge.enabled`, `notifications.slack_webhook` — extend the file by hand or copy from a fuller example.

**Get a starter example** (any install method):

```bash
mkdir -p .claude/do
curl -fsSL https://raw.githubusercontent.com/mitiay7/senior-by-default/main/examples/python-fastapi-config.json \
  -o .claude/do/config.json
```

Available examples:
- `minimal-config.json` — single-repo + GitHub (close to what auto-init produces, minus presets)
- `multi-repo-go-react-config.json` — workspace with Go API + React web + docs
- `python-fastapi-config.json` — Python + Alembic + GitHub + specialists + context-doc
- `rust-workspace-config.json` — Rust workspace + GitLab

If you have a local clone (manual install dir at `~/.local/share/senior-by-default/examples/`), copy from there. Plugin-install users — Claude Code stores plugins under `~/.claude/plugins/cache/...` with versioned subdirs that change across updates; that path is **not stable** to copy from. Use the curl above or clone the repo separately.

Full schema: [`skills/do/references/config-schema.md`](skills/do/references/config-schema.md).
JSON Schema for programmatic validation: [`skills/do/references/config.schema.json`](skills/do/references/config.schema.json).

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

Three Claude models with hard role boundaries — see [`skills/do/SKILL.md`](skills/do/SKILL.md) for the rule set and [`skills/do/references/`](skills/do/references/) for per-phase details.

## Configuration cheat sheet

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

See [`skills/do/references/config-schema.md`](skills/do/references/config-schema.md) for the full schema and [`examples/`](examples/) for ready-to-adapt configs.

## Recommended companion: caveman (install FIRST)

[caveman](https://github.com/JuliusBrussee/caveman) is a Claude Code skill that compresses agent output by ~75% via "caveman speak" while preserving full technical accuracy. It's passive (SessionStart hook), so once installed it just works for any session — including ours.

**Install it before senior-by-default** so all Sub-Agent spawns from Phase 2 inherit compressed output:

```bash
curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash
```

Phase 0 Step 2 detects whether caveman is installed and emits one of two **structurally-coupled** announce lines (the line comes from `[ -f SKILL.md ]` over 4 candidate paths — `~/.claude/skills/caveman`, `~/.claude/plugins/cache/caveman`, `~/.claude/plugins/cache/JuliusBrussee/caveman`, `~/.agents/skills/caveman` — no in-doc copyable template, so any divergence in the announce signals fabrication):

- **Active** → `Caveman: ACTIVE (path: <resolved-path>)`. Sub-Agent prompts include a directive to respond in caveman style for natural-language framing (code, paths, JSON, diffs, completion-report formats are NEVER compressed — those are LITERAL strings parsed by downstream tooling).
- **Not installed** → `Caveman: NOT INSTALLED — install: curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash`. The skill works without caveman; you just spend more output tokens.

Per-task opt-out: `--no-caveman` in `$ARGUMENTS`.

Why install caveman first: SessionStart hooks fire at session boot; if you install caveman after senior-by-default, you'll need to restart your Claude Code session for compression to take effect.

## Recommended Claude Code plugins for Phase 3 specialist review

The skill uses `subagent_type` strings from these plugins for parallel specialist review (Phase 2 plan review, Phase 3.6 audit). All optional — without them, Opus does inline review.

**Marketplaces** (add once via `/plugin marketplace add <repo>`):

| Marketplace | Source |
|---|---|
| `claude-plugins-official` | [`anthropics/claude-plugins-official`](https://github.com/anthropics/claude-plugins-official) |
| `claude-code-workflows` | [`wshobson/agents`](https://github.com/wshobson/agents) |

**Plugins** (install via `/plugin install <name>@<marketplace>`):

| Plugin | Marketplace | Agents used by /do |
|---|---|---|
| `backend-development` | wshobson | `backend-architect`, `security-auditor` |
| `code-refactoring` | wshobson | `code-reviewer` |
| `database-design` | wshobson | `database-architect` (zero-downtime migration audit) |
| `ui-design` | wshobson | `ui-designer`, `design-system-architect`, `accessibility-expert` |
| `javascript-typescript` | wshobson | `typescript-pro`, `javascript-pro` |
| `pr-review-toolkit` | anthropic-official | `silent-failure-hunter` |

If a referenced plugin isn't installed, the skill falls back gracefully (no error, just no parallel specialist for that scope — Opus does inline review).

> **Historical note:** earlier versions of this README listed `frontend-excellence:react-specialist|component-architect|frontend-optimizer`, but no public marketplace actually ships that plugin (it was an aspirational placeholder). The closest functional substitute is `ui-design` (wshobson) for design-system/UX/a11y review + `javascript-typescript` for TS-pro coverage on Next.js/React stacks. Example configs and CHANGELOG were updated accordingly.

## Required tooling

- **Claude Code** with skill support
- **`git`** ≥ 2.5 (for `git worktree`)
- **`gh` CLI** authenticated (`gh auth login`) — for GitHub tracker
- **`jq`** — for parsing tracker output and config introspection
- **`python3`** — for JSON validation

For non-GitHub trackers: `glab` (GitLab), or custom command templates per [`skills/do/references/trackers.md`](skills/do/references/trackers.md).

## Override flags

Pass these in the task argument.

**Main** (commonly used per-task):

| Flag | Effect |
|---|---|
| `--complexity=T\|L\|M\|H` | Force complexity bucket |
| `--implementer=opus\|sonnet\|haiku` | Override implementer (rare; see SKILL.md) |
| `--repo=NAME` | Force target repo (multi-repo workspace) |
| `--redetect` | Force stack re-detection (skip cache) |
| `--auto-merge` / `--no-auto-merge` | Per-task auto-merge override |

**Advanced** (config-level toggles, mostly opt-outs):

| Flag | Effect |
|---|---|
| `--skip-ci-wait` | Don't wait for CI before final announce |
| `--no-self-review` | Skip Phase 2.5 self-review (emergencies only) |
| `--no-codeowners` | Skip CODEOWNERS-routed review |
| `--no-notify` | Skip notifications for this task |
| `--no-affected-graph` | Run full build/test even when monorepo affected-graph detected |
| `--no-caveman` | Skip companion-skill detection (Phase 0 Step 2) |
| `--no-config-init` | Skip auto-generation of `.claude/do/config.json` when missing |
| `--no-specialists` | Auto-init config WITHOUT the default specialists preset |
| `--no-metrics` | Skip telemetry auto-config (both new + existing config paths) |
| `--issue-locale=<code>` | Override locale detection (e.g. `--issue-locale=fr`) |

Full flag semantics: [`skills/do/SKILL.md`](skills/do/SKILL.md).

## Documentation map

- [`skills/do/SKILL.md`](skills/do/SKILL.md) — main skill file, Phase 0 entry point, top-level rules
- [`skills/do/references/config-schema.md`](skills/do/references/config-schema.md) — full config schema (markdown)
- [`skills/do/references/config.schema.json`](skills/do/references/config.schema.json) — JSON Schema for programmatic validation
- [`skills/do/references/config-validation.md`](skills/do/references/config-validation.md) — validation rules + flow
- [`skills/do/references/stack-detection.md`](skills/do/references/stack-detection.md) — language/PM detection + cache mechanics
- [`skills/do/references/trackers.md`](skills/do/references/trackers.md) — GitHub / GitLab / custom tracker integration
- [`skills/do/references/git-rules.md`](skills/do/references/git-rules.md) — worktree, branch, commit, secrets
- [`skills/do/references/phase-1-issue.md`](skills/do/references/phase-1-issue.md) — issue body template, two-step pattern
- [`skills/do/references/phase-2-implementation.md`](skills/do/references/phase-2-implementation.md) — Sonnet prompt, plan review, self-review
- [`skills/do/references/phase-3-review.md`](skills/do/references/phase-3-review.md) — all gates, specialist audit, Opus review
- [`skills/do/references/phase-4-finalize.md`](skills/do/references/phase-4-finalize.md) — commit, push, PR, CI, auto-merge, metrics
- [`skills/do/references/zero-downtime-migrations.md`](skills/do/references/zero-downtime-migrations.md) — migration audit checklist, expand-contract pattern
- [`skills/do/references/codeowners.md`](skills/do/references/codeowners.md) — CODEOWNERS routing
- [`skills/do/references/adr.md`](skills/do/references/adr.md) — ADR template + numbering
- [`skills/do/references/notifications.md`](skills/do/references/notifications.md) — Slack / Teams webhook formats
- [`skills/do/references/anti-patterns.md`](skills/do/references/anti-patterns.md) — what NOT to do (sanity-check before announce)

## Troubleshooting

**`gh` not authenticated** → `gh auth login` (web flow). Required scopes: `repo`, `workflow`.

**Phase 0 announce says "Specialists not available — falling back to Sonnet"** → That string isn't actually emitted by the skill; sub-agents say it when `Agent(subagent_type=<plugin>:<agent>)` fails because the plugin isn't installed. Check `config.specialists.*` against installed plugins (`claude plugin list`). Either install the missing plugin (see [Recommended Claude Code plugins](#recommended-claude-code-plugins-for-phase-3-specialist-review)) or remove the reference from your config — Opus inline review takes over per group.

**Branch is `claude/funny-leakey-...` instead of `feat/i42-...`** → Phase 4.0 detects and renames automatically before PR creation; metrics record this as a Phase 2 spec violation. If it keeps happening, your Opus instance is using `Agent(isolation: "worktree")` — see anti-pattern 13 in [`skills/do/references/anti-patterns.md`](skills/do/references/anti-patterns.md).

**Metrics not appearing in `~/.claude/do/metrics/*.jsonl`** → Two cases. (a) `config.metrics.log_path` is unset — Phase 0 should now auto-add the block on first run; if it didn't, check the announce for `Metrics config: AUTO-ADDED` or `Metrics config: PATCH SKIPPED — <reason>`. (b) Block is set but Phase 4.11 silently skipped emission — the final announce MUST include `Metrics: <count> entries in <path>`. If it doesn't, that's a bug; file an issue with the announce text.

**Phase 0 announce missing `Caveman:` / `Config:` / `Metrics config:` lines** → Structural-coupling violation (the lines come exclusively from wrapper bash output, never composed). If any is absent in the announce, the orchestrator skipped Phase 0 Step 2 or Step 4 auto-init / Step 1 patch. See anti-patterns §19b (caveman) and §19c (config / metrics) in [`skills/do/references/anti-patterns.md`](skills/do/references/anti-patterns.md).

**`gh pr checks` times out** → You probably set `ci.required: true` but your repo doesn't have actual CI workflows running. Either set `ci.required: false` or wire up `.github/workflows/`.

**Stack detection wrong for monorepo** → If your stack markers (`go.mod`, `package.json`) live in subdirs (e.g., `apps/`, `App/`, `services/`), the detector scans depth-3. If still wrong: hand-edit `~/.claude/do/cache/<slug>.json` with correct values. Force re-detect with `--redetect`.

**`+++` doesn't trigger anything** → install.sh writes the trigger block to `~/.claude/CLAUDE.md`, wrapped in `<!-- senior-by-default:trigger:start/end -->` markers. Open the file and verify the block is there. If you installed via plugin (which doesn't run install.sh), add the block manually — see the snippet under [Recommended — Claude Code plugin install](#recommended--claude-code-plugin-install) above.

**Worry about auto-trigger from description match** → The skill's frontmatter has explicit "TRIGGER ONLY when LITERALLY starts with `/do`, `/<plugin>:do`, or `+++`" + "NEVER auto-trigger from description matching". This is a soft guard — Claude generally respects it, but if you want hard enforcement, you can add `disable-model-invocation: true` back to the SKILL.md frontmatter (this disables `+++` shortcut as a side effect). See [CHANGELOG [0.3.0]](CHANGELOG.md) for the trade-off discussion.

## Status

`v0.5.0` released + active `[Unreleased]` cycle — see [`CHANGELOG.md`](CHANGELOG.md). Architecture is stable. Recent work has hardened Phase 0 around three **structurally-coupled** wrappers (`metrics-append` / `config-init` / `config-ensure-metrics`) — every side-effect announce token (`Caveman:`, `Config:`, `Metrics config:`, `Metrics:`) comes from a bash variable that the announce literally interpolates, so skipping the side-effect physically prevents emitting a fake announce line. Production runs surface the divergence as visible bugs rather than silent skips.

Tier-1 metrics schema settled in v0.5.0; expect minor field additions but no breaking changes. Plugin substrate continues to evolve (the recommended plugin list above was rebuilt in May 2026 after a phantom `frontend-excellence` reference was identified and replaced with real `ui-design` + `javascript-typescript` from the wshobson marketplace).

## Uninstall

```bash
~/.local/share/senior-by-default/uninstall.sh
```

Removes the symlink, the trigger block from `~/.claude/CLAUDE.md` (if added by the installer), and optionally the install dir, cache, and metrics. See [`uninstall.sh`](uninstall.sh).

## License

[MIT](LICENSE) — Dmitry Bychkov, 2026.
