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

The two invocation forms differ at the finish line: the **`+++` form merges on finish** — after all gates pass it merges the branch (`gh pr merge` on M/H, local fast-forward into `main` on T/L) and removes the worktree; add `nomerge` to skip that (`+++ nomerge fix the button`). A plain **`/do` leaves the branch/PR for manual review** (add `--merge` to opt in). Blocked, escalated, or draft outcomes never merge either way.

> **AI does the principal-engineer work. You ship the ideas.**

A multi-actor pipeline skill for [Claude Code](https://claude.ai/code).

## What it actually does

1. **Routes by complexity** — Trivial → Haiku, Low/Medium → Sonnet, High → Sonnet plan + specialist/Opus plan review + Sonnet implementation.
2. **Creates an issue** in your tracker (GitHub or GitLab) with structured Acceptance Criteria, Implementation Hints, Build Checklist, Worktree Setup.
3. **Spawns a sub-agent** in an isolated git worktree on a properly-named branch (`feat/i42-...`).
4. **Runs gates in Phase 3** — independent build/lint/test re-run in the worktree (`build-verify` wrapper — the implementer's self-report is never the gate), UI rendering (via Claude Preview), i18n parity, BE↔FE contract alignment, dependency vulnerability scan, PR-size guard, optional CODEOWNERS-routed specialist audit.
5. **Verifies, commits, pushes, opens PR** — optionally waits for CI and enables auto-merge.
6. **Updates context doc** (if configured), logs metrics for skill-iteration feedback, sends async notifications.

The whole thing is configurable per project via `.claude/do/config.json`. Most features are skip-by-default — out of the box you get build/test enforcement, self-review, and PR-size guards. Everything else is opt-in.

## ⚠ Security & permissions

This skill performs writes against your git repo and your issue tracker:

- Creates issues in your tracker (GitHub/GitLab)
- Creates branches and worktrees
- Commits and pushes code
- Opens pull requests
- **With `auto_merge.enabled: true`** — merges to default branch when CI is green, without manual review. Precondition (single-sourced in [phase-4 §4.2.6](skills/do/references/phase-4-pr.md)): explicit `ci.required: true` + a passing CI gate that run — anything else gets a per-run "merge unverified" confirmation prompt, else the PR waits for manual review

The skill inherits whatever auth `gh`/`git` already have on your machine — assume it can do anything *you* can do from your terminal. Audit `.claude/do/config.json` before committing it (it carries webhook URLs, repo names, branch templates). Read `install.sh` before running with `curl | bash`. Keep `auto_merge.enabled: false` until you've watched a few task cycles.

## Why this vs. other "team of agents" skills

- **Three actors with strict role boundaries** — Opus *never* writes code (except with explicit `--implementer=opus` flag), Sonnet *never* makes architectural decisions, Haiku *only* does ≤2-file mechanical changes.
- **Karpathy-style behavioral guardrails** — assumptions surfaced before side effects, simplest viable implementation, surgical diffs only, and verifiable goals for every non-trivial task.
- **Quality gates are pass/fail against acceptance criteria** — no "rate this 1-10" subjective review.
- **Zero-downtime migration audit** baked in: `DROP COLUMN` / `RENAME` / `NOT NULL`-without-default get blocked with expand-contract pattern suggested.
- **Self-review calibration metric** — Sonnet declares `claimed_status: ready` before Phase 3; Phase 3 outcomes are compared and the `false_positive` rate tracked over time. Recorded in two de-confounded dimensions — `calibration_defect` (missed a real code defect?) vs `calibration_size` (mis-predicted diff size?) — so size noise doesn't masquerade as a self-review miss. The highest-signal data point for skill iteration.
- **Stack-aware**: detects Go / TS / Rust / Python / Ruby / PHP / JVM / Dart / .NET / Deno / Elixir, scans monorepo subdirs (`apps/`, `services/`, etc.) for marker files. Caches detection per repo.
- **Tracker-agnostic**: GitHub (`gh`) by default, GitLab (`glab`), or custom command templates for Linear/Jira/etc.

## Install

The two install paths invoke the skill with **different slash-commands** because plugins are namespaced. Pick one and stick to it:

| Install method | Slash-command | Customizable? |
|---|---|---|
| Plugin install (recommended) | `/senior-by-default:do <task>` | Skill name fixed by plugin manifest |
| Manual symlink (`install.sh` or by hand) | `/do <task>` | Yes — `install.sh` lets you rename via `SKILL_NAME` |

### Recommended — Claude Code plugin install

The repo is its own marketplace (ships `.claude-plugin/marketplace.json`). Two commands:

```
/plugin marketplace add mitiay7/senior-by-default
/plugin install senior-by-default@senior-by-default
```

(The `@senior-by-default` suffix is the marketplace name from `marketplace.json`, not the GitHub path.) After install, run tasks with the **plugin-namespaced command**:

```
/senior-by-default:do add user avatars to settings page
```

If you want a `+++` shortcut, add this block to `~/.claude/CLAUDE.md` manually (the plugin path doesn't run `install.sh`, so the trigger isn't auto-installed):

```md
<!-- senior-by-default:trigger:start -->
## +++ Trigger

When a user message starts with `+++` as a complete token (followed by whitespace or end of message), treat everything after `+++` as the argument and invoke the `/senior-by-default:do` skill with that text. Do NOT trigger on pasted unified diffs: a message starting `+++ b/` or `--- a/` is diff content, not an invocation.
<!-- senior-by-default:trigger:end -->
```

> **Wrapper-path resolution — all install layouts get the full wrapper tier.** The ten tier-2 enforcement wrappers (`check-caveman`, `config-init`, `config-ensure-metrics`, `plan-size-check`, `pr-size-check`, `pr-split`, `build-verify`, `secret-scan`, `branch-normalize`, `metrics-append`) are located at runtime by a canonical resolver repeated in every spec bash block — probe order: `$CLAUDE_PLUGIN_ROOT` → `~/.claude/skills/<any name>/scripts` (default or renamed `SKILL_NAME`) → plugin cache → `~/.local/share/senior-by-default`. Plugin install, default symlink, and custom `SKILL_NAME` all resolve; there is no hardcoded `~/.claude/skills/do/` literal in the live spec. If no install is found the affected gate **fails closed** with an explicit `SKIPPED` / `GATE ERROR` token in the announce instead of silently degrading to prose-level enforcement. (Earlier versions hardcoded the default-name path — that limitation is fixed; see CHANGELOG.)

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

- `issue_tracker.{type,repo}` from `git remote get-url origin` (github/gitlab/none, owner/repo auto-extracted) — gated by a CLI preflight: `gh`/`glab` missing or unauthenticated → the config degrades to `type: "none"` (issue phase skipped, announced — never a mid-pipeline `gh: command not found`) with the remedy recorded in `_meta`
- `issue_locale` from `$ARGUMENTS` script (Cyrillic → `ru`, Hiragana/Katakana/CJK → `ja`, Hangul → `ko`, else `en`; explicit `--issue-locale=<code>` wins)
- recommended `specialists` preset wiring the 6 Phase-3-audit plugins listed below — **verified against `~/.claude/plugins/installed_plugins.json`**: entries for missing plugins are dropped, groups that become empty are omitted, and the config only ever references specialists that can actually spawn (no manifest → full preset, honestly marked UNVERIFIED)
- documented tier-1 `metrics` preset (`~/.claude/do/metrics/{repo_slug}.jsonl` — cross-project; one run of the shipped [`metrics-report`](skills/do/scripts/metrics-report) CLI sees every repo)
- `_meta._setup_notes` listing exact `/plugin install` commands so the file is self-contained

The Phase 0 announce shows what was written verbatim — no parsing needed:
```
Config: AUTO-GENERATED → /path/to/repo/.claude/do/config.json
Tracker: github OK (gh version 2.62.0 (2026-01-15); auth account: alice)
Specialists: PRESET VERIFIED (6/6 plugins installed: backend-development@1.3.1, code-refactoring@1.2.0, …)
Metrics config: INCLUDED in auto-init
```

The `Tracker:` line is the wrapper's CLI preflight verdict (github/gitlab detections only). On a fresh machine without `gh` (or unauthenticated) it reads `Tracker: DEGRADED to none (gh missing — install gh …, then run 'gh auth login')` — the config is written with `issue_tracker.type: "none"`, Phase 1 is skipped with an explicit announce, and everything else runs. The OK form's tool version + account are probed at runtime (anti-fabrication tell, anti-patterns §19c).

The `Specialists:` line is the preset-verification verdict. With missing plugins it reads `Specialists: PRESET FILTERED (3/6 plugins installed: …; MISSING: ui-design, … — entries dropped, groups omitted: frontend_plan; to restore: /plugin install ui-design@claude-code-workflows; …, then re-add)`; with none installed the block is omitted entirely (`PRESET EMPTY`). The `name@version` list comes from the install manifest at runtime — same tell standard as the tracker line.

On hosts without python3-jsonschema the wrapper writes the file unvalidated and says so — the success line carries a ` (schema gate SKIPPED — jsonschema unavailable)` suffix (never a silent skip); `pip install jsonschema` restores the gate.

The file is left **unstaged** — you review and commit when ready. Subsequent `/do` runs re-read it on every Phase 0; no reload after extension.

### If your project already has a config

Phase 0 Step 1 loads it via the same path. If the file exists but **doesn't have a `metrics` block**, the orchestrator patches the documented tier-1 preset in idempotently — `_meta` is stamped with `last_patched_by` / `last_patched_at` / `last_patch_added` for observability. Existing `metrics: {...}` is left alone; explicit `metrics: null` (opt-out) is respected. Announce:
```
Config: LOADED /path/to/repo/.claude/do/config.json
Metrics config: AUTO-ADDED to /path/.../config.json (cfg=<cksum> patched_at=<utc>)   # or ALREADY CONFIGURED / EXPLICIT OPT-OUT
```

The `(cfg=…)` suffix is the wrapper's anti-fabrication tell — a checksum of the config file it actually read or wrote (recompute with `jq -cS . <path> | cksum`). A `Metrics config:` wrapper form without it was composed by hand (anti-patterns §19i).

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

Full annotated schema + examples: [`skills/do/references/config-authoring.md`](skills/do/references/config-authoring.md) (read when authoring a config). Per-field semantics for a config you already have: [`skills/do/references/config-schema.md`](skills/do/references/config-schema.md).
JSON Schema for programmatic validation: [`skills/do/references/config.schema.json`](skills/do/references/config.schema.json).

## Architecture

```
┌─────────────────── Phase 0: SETUP ───────────────────┐
│ Find config → validate → resolve repo(s)            │
│ Stack detection (cached per repo)                   │
│ Duplicate / migration checks                        │
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
   │ (Opus + gates)     │  build/test verify · UI · i18n · contract · diff-scan ·
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
| CI wait + auto-merge | `ci.required: true` + `auto_merge.enabled: true` | Phase 4 waits for green CI, then `gh pr merge --auto`. Explicit `ci.required: true` is the auto-merge precondition — `auto_merge.enabled` without it (false OR unset) → per-run confirmation prompt, else `await_review` (phase-4 §4.2.6, the single source) |
| Merge on finish | `+++` invocation form (default) / `--merge` on `/do`; opt out with `nomerge` / `--no-merge` | Distinct from auto-merge: after a clean APPROVE, §4.10.5 immediately merges the gated branch (`gh pr merge --squash` on M/H; local ff/merge into `main` on T/L — no PR exists there) and removes the worktree + branch. Never fires on blocked/escalated/draft outcomes; a red CI gate always wins; merge conflicts abort and hand back |
| Slack/Teams notifications | `notifications.slack_webhook` | Phase 1/4 broadcast task lifecycle |
| PR-size ceiling | `pr_size.{warn_lines, block_lines, auto_split, generated_paths, ...}` (on by default: **warn = the run's tier bucket** — T 2f/50L · L 3/200 · M 8/600 · H 25/1500 — block 2000/50, auto_split true, generated_paths empty) | Phase 3.0 `pr-size-check` wrapper measures the diff itself (`--repo`) and decides: ≤warn PASS, >warn WARN (note in PR), >block **BLOCK** (exit 3). Warn caps come from the run's complexity tier (v0.13.0) — the same buckets `plan-size-check` gates the *plan* against — so WARN means "the diff exceeded the budget its own plan was approved against" instead of firing on 80 % of H runs against a flat 800-line cap that sat below H's own 1500-line plan ceiling. Setting `warn_lines`/`warn_files` pins that dimension for every tier; block caps are deliberately tier-independent. On BLOCK the change never ships as one PR — by default Phase 4.2.1 **auto-splits** it into a stack of sub-cap PRs (`pr-split` wrapper), reviewed once as a unit and merged in order; `auto_split:false` / `--no-split` reverts to the hard halt (draft PR + `blocked`). `generated_paths` (globs) excludes committed machine-generated artifacts (`openapi/*.json`, `**/*.pb.go`) from the count — nobody reviews them line by line — and the excluded volume is always printed next to the counted one (`3574 handwritten + 783 generated = 4357 total lines`). Plan-time sibling: Phase 2.0 `plan-size-check` H ceiling (values owned by the wrapper, scrubbed from spec prose) → SPLIT-REQUIRED |
| Metrics for skill iteration | `metrics.log_path` + `tier: 1` | JSONL append per task; self-review calibration tracked in 3 dimensions (`calibration` + de-confounded `calibration_defect` / `calibration_size`); gate keys normalized to a controlled vocabulary; consume with the shipped `metrics-report` CLI (below) |

See [`skills/do/references/config-authoring.md`](skills/do/references/config-authoring.md) for the full annotated schema (and [`config-schema.md`](skills/do/references/config-schema.md) for per-field semantics) plus [`examples/`](examples/) for ready-to-adapt configs.

### Reading the telemetry — `metrics-report`

The consumer ships with the skill — [`skills/do/scripts/metrics-report`](skills/do/scripts/metrics-report), a read-only CLI over the JSONL log(s):

```bash
skills/do/scripts/metrics-report                    # current repo's config, else all of ~/.claude/do/metrics/*.jsonl
skills/do/scripts/metrics-report --since 2026-06-01 # date-range filter (started_at >= date)
skills/do/scripts/metrics-report --repo <slug>      # one repo from the default dir
skills/do/scripts/metrics-report --json             # machine-readable aggregates
```

It reports per-complexity-tier counts (with outcome split), plan-size rebump rate + transitions, self-review calibration accuracy across all 3 dimensions, a per-gate pass/fail table, and the top failing gates. Since v0.10.0 it also aggregates the previously write-only half of the schema: a **TIER DETAIL** table (runs, median wall-minutes, mean review cycles, median diff size, gate-caused-fix-cycle rate per tier — the table that shows where the pipeline actually earns its keep), a **SPECIALIST AUDITS** table (per-agent auditor appearances, blockers, block-rate from `specialist_iterations`), normalized rebump transitions, and a **TOKENS** section (fed by the opt-in `do-tokens-stop-amend.sh` Stop hook, which back-fills each entry's `tokens{in,out}` from the transcript's harness-recorded usage — never estimated — so per-tier ROI becomes measurable instead of chars/4 guesswork; the manual `metrics-append --tokens-in/--tokens-out` flags remain for operators holding a readout). It is also the detection tier for wrapper bypasses: parseable entries missing the canonical fields (`ref`/`started_at`/`ended_at`/`complexity`/`outcome`/`self_review` — the §19a direct-write signature) are listed in a **SCHEMA BYPASS** section and excluded from aggregates, and a **SOFT DRIFT** section lists canonical entries whose `gates`/`self_review.calibration` are empty — present in counts but contributing zero gate/calibration signal; malformed lines are skipped with a warning, never fatal. (Optional operator wiring — cron/launchd, HTML rendering — is left to you; the CLI is the shipped, supported core.)

## Optional: harness-level enforcement hooks

The skill's default enforcement is **structural-coupling wrappers** — each side-effect runs through a `scripts/*` wrapper that owns the decision + an anti-fabrication tell, so a skipped or faked check shows up as a visible bug. That's strong but still *model-dependent*: if the orchestrator never invokes a wrapper, it can't fire.

For the four checks that **must** happen every task — plus token-usage recording — you can opt into **Claude Code hooks** — scripts the runtime executes itself, independent of the model:

- **Stop hook** (`do-metrics-stop-gate.sh`) — blocks the turn from ending when a `/do` finalize lacks a valid, file-backed, fresh `Metrics:` line (closed set of legal forms; tell + freshness cross-checked against the log). The harness-enforced backstop for metrics emission — a backstop, not a guarantee: it's opt-in and verifies the announce against the log file, nothing stronger. Self-scopes to `/do` runs (no-op on normal turns), so it's safe to register globally.
- **Stop hook** (`do-tokens-stop-amend.sh`) — the only actor that can see harness-recorded usage. After a `/do` finalize it sums the transcript's `message.usage` and back-fills the run's telemetry entry with a measured `tokens{in,out}` object via `metrics-append --amend-tokens` (`in` includes cache-read; scoped to the entry by ref + time window). This is what makes the `tokens` field fillable at all — no in-session actor can read its own usage (`/cost` is TUI-only; sub-agents can't observe theirs). Never blocks; idempotent; self-scoped. Closes the 0-of-27-entries gap the v0.10.0 flags left open.
- **PreToolUse hook** (`do-plan-size-pretooluse.sh`, matcher `Task`) — surfaces the Phase 2.0 plan-size verdict at implementer-spawn time. Non-blocking (injects context, never denies).
- **PreToolUse hook** (`do-secret-scan-pretooluse.sh`, matcher `Bash`) — re-runs the Phase 4.1.2 pre-push `secret-scan` before any Bash command performing a `git push`, and **blocks the push on a confirmed secret match** (the one skip that can't be recovered — a pushed secret is revoke-and-rotate, not revert). Fail-open on everything else (missing wrapper, wrapper errors, non-push commands → allow); deliberately guards non-/do pushes too, since the no-secrets rule is unconditional.
- **PreToolUse hook** (`do-pr-size-pretooluse.sh`, matcher `Bash`) — re-runs the Phase 3.0 `pr-size-check` against the repo's **real diff** before any `gh pr create` / `glab mr create`, and **denies a non-draft PR over the block cap** (default 2000 lines / 50 files; honors `config.pr_size.*`). It measures nothing itself: it hands the wrapper `--repo` + the refs the command named, so hook and gate share one implementation of counting, config reading (including `generated_paths`) and verdict — they cannot split WARN/BLOCK on the same diff. It never fights the default auto-split path: each stacked part PR's diff (base = the previous part branch) is sub-cap, so those non-draft creations pass. A `--draft` creation is always allowed — that IS §3.0's `--no-split` BLOCK path (draft + `blocked` label + split issues) — and PASS/WARN verdicts are injected as context so `gates.pr_size` gets a genuine wrapper line even if §3.0 was skipped. Fail-open on any uncertainty.

These are **opt-in and off by default** — the skill works identically without them (it degrades to the wrapper tier). Enable by merging [`skills/do/hooks/settings.with-hooks.json`](skills/do/hooks/settings.with-hooks.json) into your `~/.claude/settings.json` (or per-project `.claude/settings.json`), or let `install.sh` do it when it prompts (default No). The four enforcement hooks are live-sim verified — registration through the real `install.sh` + documented Stop/PreToolUse payloads, 40 cases on BSD+GNU (`skills/do/hooks/hook-live-sim.sh`, a release gate; see [`hooks.md`](skills/do/references/hooks.md) §Verified 2026-07-09); the token-amend hook has its own end-to-end suite (`tests/tokens-stop-amend.test.sh`, 23 assertions), the PR-size tier-agreement + `generated_paths` behavior has `tests/pr-size-generated-paths.test.sh` (24 assertions, runs the wrapper AND the hook on one fixture and fails on any verdict split), the per-tier warn caps have `tests/pr-size-tier-warn.test.sh` (37 assertions, including a cross-wrapper invariant that reads the caps off `plan-size-check` itself), and the telemetry-integrity rules have `tests/telemetry-integrity.test.sh` (30 assertions), and the pre-push secret gate has `tests/secret-scan-worktree-scope.test.sh` (21 assertions). Full rationale + the three enforcement tiers: [`skills/do/references/hooks.md`](skills/do/references/hooks.md).

## Recommended companion: caveman (install FIRST)

[caveman](https://github.com/JuliusBrussee/caveman) is a Claude Code skill that compresses agent output by 65% (measured) via "caveman speak" while preserving full technical accuracy. It's passive (SessionStart hook), so once installed it just works for any session — including ours.

**Install it before senior-by-default** so all Sub-Agent spawns from Phase 2 inherit compressed output. Recommended source: our curated fork [mitiay7/caveman](https://github.com/mitiay7/caveman) — a maintained distribution of `JuliusBrussee/caveman` (`v1.10.x-fable` releases) that adds the `smart` level (content compression, grammar intact — the register readability-enforcing harnesses don't fight):

```bash
curl -fsSL https://raw.githubusercontent.com/mitiay7/caveman/main/install.sh | bash
```

Upstream [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) works too — it just lacks the `smart` level until the fork's PRs merge, so Phase 2 sub-agents get the full (grammar-dropping) register.

Phase 0 Step 2 detects whether caveman is installed via the external `scripts/check-caveman` wrapper (v3 of the detection — earlier inline-bash versions were systematically bypassed by orchestrators copy-pasting the announce template from the spec instead of running the check). The wrapper probes 4 fixed candidate paths (`~/.claude/skills/caveman`, `~/.claude/plugins/cache/caveman`, `~/.claude/plugins/cache/JuliusBrussee/caveman`, `~/.agents/skills/caveman`) plus the marketplace-namespaced plugin cache layout (`~/.claude/plugins/cache/<marketplace>/caveman[/<version>]/skills/caveman` — what `/plugin install` actually creates). The canonical announce strings live ONLY in the wrapper:

- **Active** → `Caveman: ACTIVE (path: <resolved-path>; levels: smart|base)` — path varies per machine, unguessable from spec; the `levels:` hint is grepped from the installed SKILL.md at run time (`smart` = fork-capable install) and selects the Phase 2 directive register
- **Not installed** → `Caveman: NOT INSTALLED (probed: <P1>, <P2>, …) — install: curl …` — the `(probed: …)` suffix lists every candidate the wrapper actually checked (unmatched cache globs stay in the list as literal patterns); **this is the anti-fabrication tell**. The list is built from the wrapper's internal array, never appears in the spec, so an orchestrator skipping the wrapper cannot include the suffix without inventing path names (a visible bug).

When active, Sub-Agent prompts get a directive to respond in caveman style for natural-language framing — `smart` register when the `levels:` hint says the install supports it, full register otherwise (code, paths, JSON, diffs, completion-report formats are NEVER compressed in either register — those are LITERAL strings parsed by downstream tooling).

Per-task opt-out: `--no-caveman` in `$ARGUMENTS`.

If your Phase 0 announce ever shows a `Caveman:` line WITHOUT a `(path: ...)` or `(probed: ...)` suffix, the orchestrator skipped the wrapper — file an issue with the announce text.

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

If a referenced plugin isn't installed, the skill falls back gracefully — and to the RIGHT model. Two layers (audit #9): at **config time**, auto-init verifies the preset against `~/.claude/plugins/installed_plugins.json` and drops missing plugins with a `Specialists: PRESET FILTERED/EMPTY` announce (see [Configure your project](#configure-your-project)); at **spawn time**, a configured-but-unavailable `subagent_type` (hand-edited config, plugin uninstalled later) is announced per seat — `Specialist {type}: NOT AVAILABLE — Opus inline fallback for {group}` — and Opus reviews that seat inline with full blocking authority. Never a silent downgrade to Sonnet, never a dropped seat.

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
- [`skills/do/references/config-schema.md`](skills/do/references/config-schema.md) — config read-path: field semantics + defaults (markdown)
- [`skills/do/references/config-authoring.md`](skills/do/references/config-authoring.md) — config authoring: full annotated schema + JSONL entry shape + examples (loaded only when writing a config)
- [`skills/do/references/config.schema.json`](skills/do/references/config.schema.json) — JSON Schema for programmatic validation
- [`skills/do/references/config-validation.md`](skills/do/references/config-validation.md) — validation rules + flow
- [`skills/do/references/stack-detection.md`](skills/do/references/stack-detection.md) — language/PM detection + cache mechanics
- [`skills/do/references/trackers.md`](skills/do/references/trackers.md) — GitHub / GitLab / custom tracker integration
- [`skills/do/references/git-rules.md`](skills/do/references/git-rules.md) — worktree, branch, commit, secrets
- [`skills/do/references/phase-1-issue.md`](skills/do/references/phase-1-issue.md) — issue body template, two-step pattern
- [`skills/do/references/phase-2-implementation.md`](skills/do/references/phase-2-implementation.md) — Sonnet prompt, plan review, self-review
- [`skills/do/references/phase-3-review.md`](skills/do/references/phase-3-review.md) — M/H gates, specialist audit, Opus review
- [`skills/do/references/phase-3-low.md`](skills/do/references/phase-3-low.md) — the complete Low review path (build-verify + dep-vuln + diff scan); Low loads this instead of phase-3-review
- [`skills/do/references/phase-4-finalize.md`](skills/do/references/phase-4-finalize.md) — commit, push, context doc, metrics, announce (every tier)
- [`skills/do/references/phase-4-pr.md`](skills/do/references/phase-4-pr.md) — PR creation, CI gate, auto-merge, issue comment (M/H with a code-host only; T/L never load it)
- [`skills/do/references/telemetry-internals.md`](skills/do/references/telemetry-internals.md) — telemetry design rationale + wrapper internals (not runtime reading)
- [`skills/do/references/zero-downtime-migrations.md`](skills/do/references/zero-downtime-migrations.md) — migration audit checklist, expand-contract pattern
- [`skills/do/references/codeowners.md`](skills/do/references/codeowners.md) — CODEOWNERS routing
- [`skills/do/references/adr.md`](skills/do/references/adr.md) — ADR template + numbering
- [`skills/do/references/notifications.md`](skills/do/references/notifications.md) — Slack / Teams webhook formats
- [`skills/do/references/anti-patterns.md`](skills/do/references/anti-patterns.md) — what NOT to do (sanity-check before announce)
- [`skills/do/references/hooks.md`](skills/do/references/hooks.md) — opt-in harness-level enforcement (Stop / PreToolUse hooks) + the three enforcement tiers

## Troubleshooting

**`gh` not authenticated** → `gh auth login` (web flow). Required scopes: `repo`, `workflow`. On fresh machines Phase 0 auto-init probes `gh`/`glab` presence + auth before committing to a tracker — a failed probe degrades the config to `issue_tracker.type: "none"` (announced as `Tracker: DEGRADED to none (…)`). Fix the CLI, then set the type back per the config's `_meta._setup_notes`.

**`STOP: not inside a git repo`** → `/do` runs from inside a project repo (Phase 0 Step 3 halts before any side effects otherwise). `cd` into the repo, pass `--repo=NAME` (needs `config.workspace.repos`), or `git init` first.

**Announce says "Specialists not available — falling back to Sonnet"** → That string isn't emitted by the skill — and since audit #9 the spec explicitly forbids the behavior it describes: a configured-but-unavailable specialist MUST be announced (`Specialist {type}: NOT AVAILABLE — Opus inline fallback for {group}`) and reviewed inline by **Opus**, never Sonnet. If you see the Sonnet variant, the orchestrator violated phase-2/phase-3 — re-run, and check `config.specialists.*` against installed plugins (`claude plugin list`). Fresh configs shouldn't reference phantom plugins at all: auto-init filters the preset against `~/.claude/plugins/installed_plugins.json` and says so in the `Specialists:` announce line. Either install the missing plugin (see [Recommended Claude Code plugins](#recommended-claude-code-plugins-for-phase-3-specialist-review)) or remove the reference from your config.

**Branch is `claude/funny-leakey-...` instead of `feat/i42-...`** → Phase 4.0's `branch-normalize` wrapper detects and renames before PR creation (verdict line carries a `head=<sha>` tell; the final announce reads the branch back live from git); metrics record the rename as a Phase 2 spec violation. If it keeps happening, your Opus instance is using `Agent(isolation: "worktree")` — see anti-pattern 13 in [`skills/do/references/anti-patterns.md`](skills/do/references/anti-patterns.md).

**Metrics not appearing in `~/.claude/do/metrics/*.jsonl`** → Two cases. (a) `config.metrics.log_path` is unset — Phase 0 should now auto-add the block on first run; if it didn't, check the announce for `Metrics config: AUTO-ADDED` or `Metrics config: PATCH SKIPPED — <reason>`. (b) Block is set but Phase 4.11 silently skipped emission — the final announce MUST include `Metrics: <count> entries in <path> (pre=<n> gates=<n>)` (the `(pre=… gates=…)` suffix is the wrapper's tell carried into the announce). If it doesn't, that's a bug; file an issue with the announce text.

**Phase 0 announce missing `Caveman:` / `Config:` / `Metrics config:` lines** → Structural-coupling violation (the lines come exclusively from wrapper bash output, never composed). If any is absent in the announce, the orchestrator skipped Phase 0 Step 2 or Step 4 auto-init / Step 1 patch. See anti-patterns §19b (caveman) and §19c (config / metrics) in [`skills/do/references/anti-patterns.md`](skills/do/references/anti-patterns.md).

**`gh pr checks` times out** → You probably set `ci.required: true` but your repo doesn't have actual CI workflows running. Either set `ci.required: false` or wire up `.github/workflows/`.

**Stack detection wrong for monorepo** → If your stack markers (`go.mod`, `package.json`) live in subdirs (e.g., `apps/`, `App/`, `services/`), the detector scans depth-3. If still wrong: hand-edit `~/.claude/do/cache/<slug>.json` with correct values. Force re-detect with `--redetect`.

**`+++` doesn't trigger anything** → install.sh writes the trigger block to `~/.claude/CLAUDE.md`, wrapped in `<!-- senior-by-default:trigger:start/end -->` markers. Open the file and verify the block is there. If you installed via plugin (which doesn't run install.sh), add the block manually — see the snippet under [Recommended — Claude Code plugin install](#recommended--claude-code-plugin-install) above.

**Worry about auto-trigger from description match** → The skill's frontmatter has explicit "TRIGGER ONLY when LITERALLY starts with `/do`, `/<plugin>:do`, or `+++`" + "NEVER auto-trigger from description matching". This is a soft guard — Claude generally respects it, but if you want hard enforcement, you can add `disable-model-invocation: true` back to the SKILL.md frontmatter (this disables `+++` shortcut as a side effect). See [CHANGELOG [0.3.0]](CHANGELOG.md) for the trade-off discussion.

## Status

`v0.13.0` released (2026-08-16). **Telemetry-integrity release — the measurement was the bug.** A read of the 93 canonical entries logged since the v0.10.0 archive cut found five defects in the skill's own instrumentation and one real defect class in the pipeline. **(1)** PR-size warn caps were flat 800/20 for every tier while the H plan bucket allows 1500 lines — so an H plan approved at 1400 lines was *guaranteed* to WARN for being exactly the size it was authorized to be. `pr_size` warned on 43 of 86 runs (80 % of all H runs), and `calibration_size`, which is scored against that gate, read 53 % — a coin flip. Warn caps now come from the run's tier (`pr-size-check --tier`, same buckets as `plan-size-check`); block caps stay flat and tier-independent, so the PreToolUse hook still cannot disagree with the gate on anything enforced. **(2)** ~25 % of all Phase 3 criteria failures were one class — a new guard written, never covered, whole suite green — so Phase 2.5 self-review now requires **inverting every new condition and watching a named test go red**, reported on a `guard_coverage:` line and spot-checked by Phase 3.7. **(3)** `metrics-report`'s block-rate divided findings by appearances and could print 200 %; it now counts review cycles. **(4)** Four schema drifts are enforced in `metrics-append`: a `scope` vocabulary (93 entries carried eleven spellings of six concepts), duplicate `(ref, started_at)` entries, a `specialist_audit` verdict beside an empty detail array, and bare-string `blockers[]`. **(5)** The v0.12.0 token hook had fired **zero times** — its guard grepped for English announce prose and the one run since was conducted in Russian; the §4.13 announce is now specified as a verbatim-English protocol block, the hook also triggers on the machine-readable `Metrics:` line, and `DO_TOKENS_DEBUG=1` makes its silent no-ops explain themselves. Two new suites (37 + 30 assertions); `hook-live-sim.sh` 40/40.

`v0.12.0` released (2026-07-23). **Token-economy release — measured, not guessed.** A 2026-07-23 audit (a fanned-out, adversarially-verified re-measurement of the skill's own telemetry + context load) found the v0.10.0 `tokens` field at **0 % adoption across 27 post-release runs** and traced it to a structural gap: no in-session actor can read its own usage, so the field was unfillable. Four fixes ship together. **(1)** A new opt-in Stop hook [`do-tokens-stop-amend.sh`](skills/do/hooks/do-tokens-stop-amend.sh) sums the transcript's harness-recorded `message.usage` after a `/do` finalize and back-fills the entry via a new `metrics-append --amend-tokens` mode (amend-only, ref-matched, idempotent, never blocks; 23-assertion suite) — the `tokens` field is finally real. **(2)** The tracker-`none` Phase 1 skip is decided in `SKILL.md`, so M/H local runs stop loading `phase-1-issue.md` (17 KB) just to find a one-line skip. **(3)** `config-schema.md` split into a slim read-path (26.3 KB → 16.9 KB, mandated every run) plus a new [`config-authoring.md`](skills/do/references/config-authoring.md) loaded only when writing a config — zero normative loss (line-by-line union audit). **(4)** An explicit `Finalize owner:` flag ends the ~69 KB double-read of `phase-4-finalize.md` + `anti-patterns.md` between orchestrator and implementer. Enforcement is unchanged throughout: the §4.13 announce coupling and the wrapper OK-line still hold; `metrics-report` renders the newly-populated token medians per tier.

`v0.11.1` released (2026-07-23). **Branch-normalize no longer risks deleting `origin/main`.** Phase 4.0's post-rename remote cleanup keyed its `git push --delete` off the old branch's `@{upstream}` — and a harness-pre-spawned worktree (`git worktree add -b <name> origin/main`) tracks `origin/main`, so a rename could run `git push origin --delete main` and delete the default branch (only branch protection saved it in the wild). Cleanup is now keyed on the **old local branch name**, gated on "was actually pushed AND is not the default/main/master branch," with a hard guard that reports `old_remote=skipped(protected:<branch>)` and refuses. Legitimate stale-branch cleanup and `--no-remote-delete` are unchanged. Covered by a new cross-platform regression test.

`v0.11.0` released (2026-07-23). **Auto-split on PR-size BLOCK.** An over-block-cap change (default >2000 lines / >50 files) used to hard-halt: draft PR + `blocked` label, split by hand. Now the default is to split automatically — Phase 3 still reviews the whole change as one unit, then new [§4.2.1](skills/do/references/phase-4-pr.md) delivers it as a **stack of sub-cap PRs** (≈800 lines each, merged in order) via the new [`pr-split`](skills/do/scripts/pr-split) wrapper; the run ends `ready_for_review` with *k* open PRs. The stack is build-coherent by construction (part *i* off part *i-1*, tip == the reviewed change; GitHub auto-retargets children when a parent merges) and diffs against the *merge-base* so a `main` that advanced mid-task can't leak in. It's **not** a BLOCK→`warn` downgrade — the change never ships as one over-cap PR, it ships as *k* sub-cap ones; `gates.pr_size` stays `block` for honest telemetry. A hard self-check (each part's diff == its file-group, tip tree reproduced exactly) gates it: any mismatch or a change that can't be split → `SPLIT-FAILED` and clean fallback to the pre-0.11 draft + `blocked` path. Opt out with `config.pr_size.auto_split: false` or `--no-split`.

`v0.10.1` released (2026-07-17). **Merge-on-finish.** The two invocation forms now differ at the finish line: `+++ task` merges the gated branch after a clean APPROVE (`gh pr merge --squash` on M/H; local ff/merge into `main` on T/L, where no PR exists) and removes the worktree + branch — the loop closes without a manual merge step. `+++ nomerge task` (or plain `/do`) keeps today's await-review behavior; `/do --merge` opts in. Deliberately narrow: never fires on blocked/escalated/draft outcomes, a red `ci.required` gate always wins, merge conflicts abort-and-hand-back, and it is a separate rule from §4.2.6 auto-merge (which still requires explicit CI) — defined once in [phase-4 §4.10.5](skills/do/references/phase-4-finalize.md), so the two merge modes can't be played against each other. `install.sh`'s `+++` trigger block updated to state the difference.

`v0.10.0` released (2026-07-17). **Telemetry-driven diet release** — every change traces to a 227-run telemetry re-audit (independently re-verified against the raw JSONL) rather than intuition. Progressive disclosure now matches measured usage: the PR/CI/auto-merge path moved to [`phase-4-pr.md`](skills/do/references/phase-4-pr.md) (loaded only on M/H with a code-host — CI-wait and auto-merge had **0 uses in 227 runs** on the default local-only config, yet every Trivial/Low run paid to read them), the complete Low review path moved to [`phase-3-low.md`](skills/do/references/phase-3-low.md) (Low loads ~5 KB instead of the 23 KB M/H review file, same rigor — the audit's "drop review on L" proposal was rejected: the tier gradient did not replicate on a second repo), and telemetry design history moved to [`telemetry-internals.md`](skills/do/references/telemetry-internals.md). The Phase 1 concurrent-edit gate now warns on **in-flight work** (unmerged branches + live worktrees) instead of merged history — the old heuristic scored 0 true positives in 13 recorded checks with documented false alarms. Telemetry gains cost accounting (`metrics-append --tokens-in/--tokens-out`, harness-reported only) and `metrics-report` finally consumes the write-only half of the schema (per-tier wall-time/cycles/diff/fix-rate, specialist block-rates, normalized rebumps, SOFT DRIFT tier). Plus: the stop-gate no longer false-blocks on a log missing its final newline, and `config-schema.md` documents the real specialist preset instead of placeholders (a placeholder-reading audit recommended removing an agent from a preset it was never in).

`v0.9.1` released (2026-07-16). **Shell-portability release.** The orchestrator's shell is frequently zsh, which does not word-split unquoted expansions — and two spec idioms assumed bash. The bad one made the Phase 1 concurrent-edit gate report "no concurrent edits" for *every* multi-file task: the pathspec list collapsed into one bogus pathspec, `git log` matched nothing and exited 0, and a silent false all-clear is indistinguishable from a real pass. The other (`${VAR:+--flag "$VAR"}`, 18 sites) collapsed flag and value into one argv token, so wrappers answered `REJECT unknown arg` — loud, merely wasteful. Both now use arrays, verified byte-identical under bash 3.2 and zsh 5.9. Also: `SKILL.md` had been stuck at `version: 0.8.1` since before the 0.9.0 release. New [anti-patterns §25](skills/do/references/anti-patterns.md) records the rule the incident taught — *a gate that cannot fail is not a gate*; an empty result from a check whose pass looks like "matched nothing" is a claim requiring evidence.

`v0.9.0` (2026-07-09). **Enforcement-integrity release**, built from a 26-finding external audit: dynamic wrapper resolution works on every install layout (plugin cache, renamed skill, `~/.local/share` clone) and fails closed; the pre-push secret scan is wrapper-owned and coupled to the push itself; build/lint/test are re-run by the orchestrator instead of trusting the implementer's self-report; plan-size inputs are grounded per tier; migrations use UTC-timestamp prefixes; telemetry finally has a reader (`metrics-report`). Earlier v0.8 highlights:

- **Three enforcement tiers, now explicit** — soft instruction → structural-coupling wrapper (default) → **opt-in Claude Code hook** (runtime-enforced, model-independent). A **Stop hook** is the harness-enforced backstop for metrics emission (blocks a `/do` finalize lacking a file-backed `Metrics:` line; self-scopes so normal turns are untouched); a **PreToolUse hook** surfaces the plan-size verdict at spawn time. Off by default — see [`skills/do/references/hooks.md`](skills/do/references/hooks.md).
- **No dead gates** — the five "never-failing" gates were investigated and kept: `0 fails` was a measurement artifact (Phase 3 records the resolved state); all fire via `fix_cycle` (`opus_review` 16/125, `test` 5/130, …). (Measured with the operator-side daily report, since superseded by the shipped `metrics-report` CLI.)
- **Leaner anti-patterns** — the 7-entry §19 fabrication family consolidated to one principle + a table; wrapper boilerplate assessed and intentionally left self-contained.

The v0.7 cycle (folded below) acted on a 225→254-entry telemetry audit (May 14–24) — **measurement integrity + a PR-size ceiling that actually blocks**:

- **Controlled vocabulary for `gates`** — `metrics-append` normalizes gate keys (alias map → 19 canonical names) and statuses (→ `pass|warn|fail|block|skipped`), preserving unknown task-specific keys with a `noncanon=` tell. The audit found ~110 distinct keys for ~19 real gates; gate reports now bucket cleanly (60 → 19 + a few one-offs — see the shipped `metrics-report` CLI).
- **Split self-review calibration** — `calibration_defect` (real code defect missed) vs `calibration_size` (diff-size prediction), de-confounding the FP rate that 39% of historical "false positives" were just `pr_size=warn` noise inflating.
- **PR-size ceiling** — `plan-size-check` H bucket got a real file/line ceiling (was effectively unbounded; the values live only in the wrapper), so `SPLIT-REQUIRED` fires at plan time. New `pr-size-check` wrapper owns the Phase 3.0 PASS/WARN/**BLOCK** decision and **exits 3 on block** (hard halt → draft PR + `blocked`), so the 8 historical >2000-line PRs that shipped as `warn` would now block.

Builds on the v0.6 foundation of **structurally-coupled** wrappers — every side-effect announce token comes from wrapper stdout with an anti-fabrication tell, so skipping a check surfaces as a visible bug rather than a silent skip. v0.7 adds `pr-size-check` to that family (`metrics-append`, `config-init`, `config-ensure-metrics`, `check-caveman`, `plan-size-check`, `pr-size-check`).

Tier-1 metrics schema is stable; new fields added strictly via enum extension (the back-compat `calibration` field is retained alongside the split). See [`CHANGELOG.md`](CHANGELOG.md) for the per-fix postmortem trail — every wrapper has a documented production-failure origin.

## Uninstall

```bash
~/.local/share/senior-by-default/uninstall.sh
```

Removes the symlink, the trigger block from `~/.claude/CLAUDE.md` (if added by the installer), the opt-in enforcement hook entries from `~/.claude/settings.json` (jq-based, timestamped backup kept; only the four `do-*` entries are touched — without this step every Stop, Task spawn, and Bash call would error against the removed hook scripts), and optionally the install dir, cache, and metrics. If `jq` is missing the hook entries are left in place and the script prints manual removal instructions instead. See [`uninstall.sh`](uninstall.sh).

## License

[MIT](LICENSE) — Dmitry Bychkov, 2026.
