# senior-by-default

You type:
```
/do add user avatars to settings page
```
(or `/senior-by-default:do add user avatars to settings page` if installed as a plugin — see [Install](#install). Want a shorter prefix like `+++`? See [Shortcut setup (CLI hook)](#shortcut-setup-cli-hook).)

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

> **No `+++` shortcut via SKILL.md description** — the skill has `disable-model-invocation: true` for safety (see [Why](#why-no--shortcut-via-claudemd)). Want a short prefix anyway? See [Shortcut setup (CLI hook)](#shortcut-setup-cli-hook) for a `~/.claude/settings.json` `UserPromptSubmit` hook that rewrites `+++ X` → `/<skill>:do X` at the CLI level (works regardless of `disable-model-invocation`).

### Manual — clone + symlink

For users who want to track `main` directly, hack on the skill, or use the bare `/do` command without a plugin namespace:

```bash
git clone https://github.com/mitiay7/senior-by-default ~/.local/share/senior-by-default
mkdir -p ~/.claude/skills
ln -s ~/.local/share/senior-by-default/skills/do ~/.claude/skills/do
```

Run tasks with `/do <task>` (no plugin namespace).

### One-liner (review the script first)

The `install.sh` is interactive — it asks for skill name (default `do`) and install dir. It writes a symlink and runs dependency checks. If a legacy `+++` trigger block exists in `~/.claude/CLAUDE.md` from earlier installs (v0.2.0–v0.2.3), it offers to remove it (the block was a no-op because of `disable-model-invocation: true`).

**This script does manual symlink install, NOT plugin install.** It registers `/do` (or your custom name), not `/senior-by-default:do`. **Read it first**: <https://github.com/mitiay7/senior-by-default/blob/main/install.sh>

```bash
curl -fsSL https://raw.githubusercontent.com/mitiay7/senior-by-default/main/install.sh | bash
```

Non-interactive (env vars override prompts):
```bash
SKILL_NAME=do INSTALL_DIR=~/.local/share/senior-by-default \
  curl -fsSL https://raw.githubusercontent.com/mitiay7/senior-by-default/main/install.sh | bash
```

## Configure your project

Drop `.claude/do/config.json` at your project (or workspace) root. The path the example lives at depends on how you installed:

### Option A: install-agnostic (works for any install method)

Pull the example straight from GitHub:
```bash
mkdir -p .claude/do
curl -fsSL https://raw.githubusercontent.com/mitiay7/senior-by-default/main/examples/minimal-config.json \
  -o .claude/do/config.json
$EDITOR .claude/do/config.json    # set issue_tracker.repo to your owner/repo
```

Available examples (substitute the filename in the URL):
- `minimal-config.json` — single-repo + GitHub
- `multi-repo-go-react-config.json` — workspace with Go API + React web + docs
- `python-fastapi-config.json` — Python + Alembic + GitHub
- `rust-workspace-config.json` — Rust workspace + GitLab

### Option B: copy from a local clone

If you have a local clone of this repo (manual install, or you cloned separately for hacking):

| Install method | Examples directory |
|---|---|
| Manual symlink (default install dir) | `~/.local/share/senior-by-default/examples/` |
| Manual clone elsewhere | `<your-clone>/examples/` |

> **Note for plugin install users:** Claude Code stores plugins under `~/.claude/plugins/cache/...` with versioned subdirectories that change across updates — this path is **not stable** to copy from. Use Option A (curl) instead, or clone the repo separately just for the examples.

```bash
mkdir -p .claude/do
cp <examples-dir>/minimal-config.json .claude/do/config.json    # ← pick row above
$EDITOR .claude/do/config.json
```

For multi-repo workspaces, monorepo, Python, or Rust projects, see [`examples/`](examples/) on GitHub for full configs.

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

Phase 0.0.3 detects whether caveman is installed:
- **Active** → prints `Caveman: ACTIVE (output compressed)`. Sub-Agent prompts include a directive to respond in caveman style for natural-language framing (code, paths, JSON, diffs, completion-report formats are NEVER compressed).
- **Not installed** → warns once, proceeds without compression. The skill works without caveman; you just spend more output tokens.

Per-task opt-out: `--no-caveman` in `$ARGUMENTS`.

Why install caveman first: SessionStart hooks fire at session boot; if you install caveman after senior-by-default, you'll need to restart your Claude Code session for compression to take effect.

## Recommended Claude Code plugins for Phase 3 specialist review

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

For non-GitHub trackers: `glab` (GitLab), or custom command templates per [`skills/do/references/trackers.md`](skills/do/references/trackers.md).

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

**Skill says "specialist not found"** → That `subagent_type` plugin isn't installed. Either install it (see Recommended plugins above) or remove it from `config.specialists.*` — Opus inline review takes over.

**Branch is `claude/funny-leakey-...` instead of `feat/i42-...`** → Phase 4.1.0 detects and renames automatically; metrics record this as a Phase 2 spec violation. If it keeps happening, your Opus instance is using `Agent(isolation: "worktree")` — see anti-pattern 31b in [`skills/do/references/anti-patterns.md`](skills/do/references/anti-patterns.md).

**Metrics not appearing in `~/.claude/do/metrics/*.jsonl`** → Skill is skipping Phase 4.11. Check the final announce — it MUST include `Metrics: <count> entries in <path>`. If it doesn't, that's a bug; file an issue with the announce text.

**`gh pr checks` times out** → You probably set `ci.required: true` but your repo doesn't have actual CI workflows running. Either set `ci.required: false` or wire up `.github/workflows/`.

**Stack detection wrong for monorepo** → If your stack markers (`go.mod`, `package.json`) live in subdirs (e.g., `apps/`, `App/`, `services/`), the detector scans depth-3. If still wrong: hand-edit `~/.claude/do/cache/<slug>.json` with correct values. Force re-detect with `--redetect`.

### Why no `+++` shortcut via CLAUDE.md

The skill has `disable-model-invocation: true` — required by audit (third pass) because the skill performs side effects (creates issues, commits, pushes, opens PRs, optionally auto-merges) and must not auto-trigger from description matching mid-conversation.

A `+++` shortcut written as a CLAUDE.md instruction asking the model to invoke `/do` via the Skill tool gets blocked by the same flag — the harness can't tell "model decided to fire it" from "user typed +++ which the model is forwarding". So the shortcut would simply error:

```
Skill do cannot be used with Skill tool due to disable-model-invocation
```

`/do <task>` (or `/senior-by-default:do <task>` for plugin install) works fine — slash commands are handled by the CLI before the Skill tool path, bypassing the flag.

### Shortcut setup (CLI hook)

If you want a short prefix anyway, set it up at the **CLI level** via a `UserPromptSubmit` hook in `~/.claude/settings.json`. The hook rewrites `+++ X` → `/do X` (or `/senior-by-default:do X` for plugin install) **before** Claude sees the prompt — so the slash-command path fires, `disable-model-invocation` doesn't apply, and you get the shortcut without losing the safety guarantee.

Sketch (verify the exact hook syntax against your Claude Code version):

```jsonc
{
  "hooks": {
    "UserPromptSubmit": [{
      "matcher": "^\\+\\+\\+\\s",
      "hooks": [{
        "type": "command",
        "command": "sed 's|^+++ |/do |'"
      }]
    }]
  }
}
```

This is **outside the skill's scope** — the skill itself stays safe-by-default. PRs welcome with a verified hook config for popular Claude Code versions.

## Status

`v0.1.0` — early release. The architecture is stable; metrics-driven skill iteration is in progress. Expect Tier 1 metrics schema to evolve.

## Uninstall

```bash
~/.local/share/senior-by-default/uninstall.sh
```

Removes the symlink, the trigger block from `~/.claude/CLAUDE.md` (if added by the installer), and optionally the install dir, cache, and metrics. See [`uninstall.sh`](uninstall.sh).

## License

[MIT](LICENSE) — Dmitry Bychkov, 2026.
