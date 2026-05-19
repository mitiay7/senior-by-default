---
name: do
version: 0.5.0
model: opus
description: |
  Multi-actor implementation pipeline for Claude Code. Routes coding tasks by complexity (Trivial→Haiku, Low/Medium→Sonnet, High→Opus plan + Sonnet impl), creates issue in tracker, runs gated review (PR-size, dep-vuln, i18n, contract, zero-downtime migration audit), opens PR with optional CI gate and auto-merge.

  TRIGGER ONLY when the user's message LITERALLY starts with `/do`, `/<plugin>:do`, or `+++` — these are explicit invocations. NEVER auto-trigger from description matching, perceived task fit, or conversational context, EVEN IF a coding task otherwise matches every other criterion.

  Side effects (creates issues, commits, pushes, opens PRs, optionally auto-merges) make false-positive triggering destructive. When in doubt, do not invoke — let the user invoke explicitly.

  SKIP: pure Q&A, code review without implementation, scaffolding-from-scratch ("create new project"), exploratory ("how would I…"), single-line edits where the pipeline is overkill, ANY task not prefixed with the explicit invocation tokens above.
---

<!--
Frontmatter rationale: `model: opus` pins the orchestrator regardless of session model.
Phase 4 (commits/pushes/PRs/auto-merge) creates side effects; the strict TRIGGER ONLY +
NEVER auto-trigger description language is the soft guard against description-match
firing (no hard `disable-model-invocation` because that breaks the +++ shortcut —
Claude Code doesn't currently support CLI-level prompt rewriting; see CHANGELOG [0.3.0]).
-->

# Multi-Actor Implementation Pipeline

## Notation

- **`Agent(model: "<X>")`** — invoke the Task tool with the `subagent_type` mapping to model `<X>`. Concrete subagent types from installed plugins (e.g. `code-refactoring:code-reviewer`); harness defaults if unspecified.
- **Worktree creation** — always explicit `git worktree add` per [`references/git-rules.md`](references/git-rules.md). Task tool's `isolation: "worktree"` is **forbidden** here (auto-names branches, breaks `config.naming` traceability).
- **`<current model from environment>`** — Co-Authored-By footer reads running model identifier from harness session metadata. Never hardcode a model version.

## Roles

> **Opus** — analysis, issue creation, code review, merge. NEVER writes code except with `--implementer=opus` (rare: deep algorithmic, security-critical, complex concurrency, novel architecture). When Opus implements, Phase 3 Opus review MUST be fresh cold-context `Agent` invocation.
> **Sonnet** (`Agent(model: "sonnet")`) — plan, implement, test, self-review. NEVER makes architectural decisions. Also reviews Haiku's diffs for Trivial tasks.
> **Haiku** (`Agent(model: "haiku")`) — Trivial mechanical changes only (1-2 files, no logic decisions). NEVER touches M/H. NEVER reviews its own work.
> **No backwards compat** — clean breaks only. No re-exports, `_unused` vars, shims.
> **Context doc is mandatory IF configured.** Sonnet reads it before exploring; Phase 4 updates it.

**Input**: `$ARGUMENTS`

## Operating principles

Apply in every phase, pass through to spawned agents. Adapt Karpathy-style guardrails for this side-effect-heavy pipeline: bias toward caution on non-trivial work, but no ceremony for obvious one-line fixes.

1. **Think before coding** — do not silently choose between materially different interpretations. If ambiguity changes behavior, STOP and ask before creating issues, worktrees, commits, PRs. Low-risk assumption → record in issue/context and continue.
2. **Simplicity first** — smallest change satisfying the request + acceptance criteria. No speculative abstractions, config, feature flags, dependencies, "future flexibility", impossible-case error handling unless task explicitly requires.
3. **Surgical changes** — every changed line traces to user request, requirement, acceptance criterion, or cleanup caused by this change. Match existing style. Mention unrelated dead code as follow-up; do not edit it in this task.
4. **Goal-driven execution** — convert request into pass/fail criteria before implementation. Each non-trivial plan step names its verification check. Loop until criteria + gates pass, then stop.

## Progressive disclosure — load references on demand

Do NOT preload. Read each only when its trigger fires.

| When | Read |
|---|---|
| **Phase 0** (setup, routing, complexity, sanity checks) | [`references/phase-0-setup.md`](references/phase-0-setup.md) |
| Reading or writing `.claude/do/config.json` | [`references/config-schema.md`](references/config-schema.md) |
| Validating config on load | [`references/config-validation.md`](references/config-validation.md) |
| Stack detection or cache I/O | [`references/stack-detection.md`](references/stack-detection.md) |
| Any tracker operation | [`references/trackers.md`](references/trackers.md) |
| Any git operation | [`references/git-rules.md`](references/git-rules.md) |
| **Phase 1** (M/H) — issue creation | [`references/phase-1-issue.md`](references/phase-1-issue.md) |
| **Phase 2** — Sonnet prompt, plan review, self-review, stale-main | [`references/phase-2-implementation.md`](references/phase-2-implementation.md) |
| **Phase 3** — gates, specialist audit, Opus review | [`references/phase-3-review.md`](references/phase-3-review.md) |
| **Phase 4** — commit, push, PR, CI, auto-merge, metrics, announce | [`references/phase-4-finalize.md`](references/phase-4-finalize.md) |
| Migration audit specialist | [`references/zero-downtime-migrations.md`](references/zero-downtime-migrations.md) |
| Specialist audit + PR reviewer routing | [`references/codeowners.md`](references/codeowners.md) |
| ADR generation (High) | [`references/adr.md`](references/adr.md) |
| Slack/Teams notifications | [`references/notifications.md`](references/notifications.md) |
| Pre-finalize sanity check | [`references/anti-patterns.md`](references/anti-patterns.md) |

Example configs (at repo root):
- [`multi-repo-go-react-config.json`](../../examples/multi-repo-go-react-config.json) — workspace Go API + React + docs + GitHub
- [`minimal-config.json`](../../examples/minimal-config.json) — single-repo + GitHub
- [`python-fastapi-config.json`](../../examples/python-fastapi-config.json) — Python + Alembic + GitHub
- [`rust-workspace-config.json`](../../examples/rust-workspace-config.json) — Rust workspace + GitLab

## $ARGUMENTS handling

Sanitize: strip injection-enabling characters only — `` ` ``, `$()`, `;`, `|`, `&`, `>` followed by a path. **Preserve all Unicode letters** (Cyrillic, CJK, etc.).

### Main override flags

Recognize free-form (accept natural-language equivalents too):

| Flag | Effect |
|---|---|
| `--complexity=T\|L\|M\|H` | Force complexity bucket (T = Trivial → Haiku) |
| `--implementer=opus\|sonnet\|haiku` | Override default implementer (Phase 2 only — review/audit/merge stay on Opus) |
| `--repo=NAME` | Force target repo (skip workspace routing) |
| `--redetect` | Force stack re-detection (skip cache) |
| `--auto-merge` / `--no-auto-merge` | Per-task auto-merge override |

### Advanced flags (niche)

| Flag | Effect |
|---|---|
| `--skip-ci-wait` | Don't wait for CI before final announce |
| `--no-self-review` | Skip Sonnet self-review (Phase 2.5) — emergencies only |
| `--no-codeowners` | Skip CODEOWNERS-based reviewer routing |
| `--no-notify` | Skip notifications for this task |
| `--no-affected-graph` | Run full build/test even when monorepo affected-graph detected |
| `--no-caveman` | Skip companion-skill detection for this task |
| `--no-config-init` | Skip Phase 0 auto-init of `.claude/do/config.json` when missing (use defaults, write nothing) |
| `--no-specialists` | Auto-init config WITHOUT the default specialists preset (Opus inline review fallback for all groups) |
| `--no-metrics` | Skip telemetry auto-config — Step 1 won't patch existing configs missing `metrics`, Step 4 auto-init won't include the preset |

### Implementer override semantics

| Override | Allowed on | Effect |
|---|---|---|
| `--implementer=opus` | M/H | Phase 2 spawns `Agent(model: "opus")` instead of Sonnet. Phase 3 Opus review MUST be fresh cold-context. Announce: `Implementer: Opus (cold-context review required)`. |
| `--implementer=sonnet` | T | Phase 2 spawns Sonnet; Phase 3 diff-scan upgrades to Opus. Effectively `--complexity=L` minus the issue-skip warning. |
| `--implementer=haiku` | T only | No-op (default). On M/H → **HARD REJECT** (Haiku must not make logic decisions on multi-file or architectural work). |

`--implementer=opus` does NOT skip specialists, ADR, CODEOWNERS, or PR-size guards — it only changes who writes the code. `--implementer=opus` on L → warn `Opus on Low is overkill — proceed?` but honor.

## Phase 0 — Setup & Routing

Read [`references/phase-0-setup.md`](references/phase-0-setup.md). Six logical steps:

1. Load + validate config (inline WIP / postmortem checks if configured)
2. Companion-skill detect (caveman — sets prompt directive for Phase 2)
3. Resolve target repo(s)
4. Stack cache (load or detect)
5. Sanity checks (duplicate / concurrent-edit / migration / context doc)
6. Complexity routing + model assignment + announce

Final `[Phase 0] ...` announce — must include `Models:` line (orchestrator + implementer).

## Phases 1–4 — load reference per phase

| Phase | Always-run? | Reference |
|---|---|---|
| 1 — Issue creation | M/H only (skipped for T/L) | [`references/phase-1-issue.md`](references/phase-1-issue.md) |
| 2 — Implementation + self-review + ADR (High) | L/M/H (Trivial uses simplified flow below) | [`references/phase-2-implementation.md`](references/phase-2-implementation.md) |
| 3 — Code review (gates, specialist audit, Opus review) | L/M/H (Trivial uses Sonnet diff-scan only) | [`references/phase-3-review.md`](references/phase-3-review.md) |
| 4 — Finalize (commit, push, PR, CI, auto-merge, context doc, metrics, announce) | always | [`references/phase-4-finalize.md`](references/phase-4-finalize.md) |

**Low complexity simplifications**: skip Phase 1, Phase 3 = diff scan + dep-vuln scan only, Phase 4 = push + change summary (no PR), still emit metrics + notification.

**Trivial complexity simplifications**:
- Phase 1: skip (no issue)
- Phase 2: spawn `Agent(model: "haiku")` with tightly scoped prompt — exact files + exact change. Haiku does NOT explore codebase, does NOT make architectural decisions, does NOT touch tests. Anything ambiguous → **abort and re-route to Low**.
- Phase 3: skip all gates except dep-vuln (only if deps changed). `Agent(model: "sonnet")` diff-scan with one question: "does this diff do exactly what was asked, nothing more?" Reject + retry once; second failure → re-route to Low.
- Phase 4: commit + push to worktree branch. **No PR**, no context-doc update, no ADR. Emit metrics + notification. Co-Author = `Claude Haiku 4.5` (not parent model).
- Worktree rule still applies — Trivial does not bypass [`git-rules.md`](references/git-rules.md).

Before announcing completion, scan [`references/anti-patterns.md`](references/anti-patterns.md).

## Top-level git constraints (full: [`references/git-rules.md`](references/git-rules.md))

- Worktree only — never `git checkout -b`, never `git clone`
- Never commit to `main`. Never `--force` / `--hard` / `--amend` / `--no-verify`
- Never modify `.git/config` or `core.hooksPath`
- Never commit `.env*` / `*.key` / `*.pem` / `credentials.*` / `*.secret`. Verify `git diff --cached --name-only` + content before every push
- `Co-Authored-By: <current model from environment>` — auto-detect, never hardcode

## Top-level anti-patterns (full: [`references/anti-patterns.md`](references/anti-patterns.md))

**Hot ones to scan before final announce**:

- **Final assistant message ends with PR-summary prose and NO `Metrics: ...` line** — Phase 4.13 procedure skipped. Run bash flow verbatim from `phase-4-finalize.md` instead of composing prose.
- **Auto-named branches without `i{N}` for M/H** — Phase 4.0 renames UNCONDITIONALLY before PR open. "Pre-spawned worktree" is NOT an excuse — `git branch -m` works on pre-spawned worktrees too.
- **Using `Agent(isolation: "worktree")` for Phase 2** — auto-names branches, breaks `config.naming`. Pre-create worktree explicitly via `git worktree add`.
- **Skipping zero-downtime migration audit** when migration present
- **Bypassing CODEOWNERS** when file exists in repo
- **Subjective reviews / scope creep / silent assumptions / speculative abstractions / drive-by refactors**
- **Opus writing code without `--implementer=opus`** / **Haiku making logic decisions**
- **Shell-injecting `{title}`/`{labels}` into tracker commands** — pass via env vars or argv arrays; see `references/trackers.md` §Security
- **Compressing structured output when caveman is active** — `claimed_status`, metrics JSONL, announce format are LITERAL (parsed by downstream tooling)
