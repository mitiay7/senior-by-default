---
name: do
version: 0.11.1
model: opus
description: |
  Multi-actor implementation pipeline for Claude Code. Routes coding tasks by complexity (Trivial→Haiku, Low/Medium→Sonnet, High→Sonnet plan + specialist/Opus plan review + Sonnet impl), creates issue in tracker, runs gated review (PR-size, dep-vuln, i18n, contract, zero-downtime migration audit), opens PR with optional CI gate and auto-merge. `+++`-form invocations additionally merge the gated branch and clean the worktree at the end (opt out with `nomerge`).

  TRIGGER ONLY when the user's message LITERALLY starts with `/do`, `/<plugin>:do`, or `+++` as a COMPLETE TOKEN — followed by whitespace or end of message. `/docs`, `/done`, `/do-something` do NOT match. A message starting `+++ b/` or `--- a/` is a pasted unified diff, not an invocation — do NOT trigger. NEVER auto-trigger from description matching, perceived task fit, or conversational context, EVEN IF a coding task otherwise matches every other criterion.

  Side effects (creates issues, commits, pushes, opens PRs, optionally auto-merges) make false-positive triggering destructive. When in doubt, do not invoke — let the user invoke explicitly.

  SKIP: pure Q&A, code review without implementation, scaffolding-from-scratch ("create new project"), exploratory ("how would I…"), ANY task not prefixed with the explicit invocation tokens above. An explicit invocation of an implementable task ALWAYS runs — a one-line edit routes to the Trivial tier, it is never refused as "pipeline overkill".
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
- **`<current model from environment>`** — Co-Authored-By footer reads the model identifier from the session metadata of whoever authored the commit (for spawned implementers: the sub-agent's own session model). Never hardcode a model version.
- **Model names** — `opus` / `sonnet` / `haiku` throughout this spec are harness model-tier aliases (top / mid / fast), resolved by the harness to whatever those tiers currently map to. Never pin a dated model id in spec text, prompts, or commit trailers.

## Roles

> **Opus** — analysis, issue creation, plan-review adjudication (High: binding decision after 3 unresolved iterations), code review, merge. NEVER writes code except with `--implementer=opus` (rare: deep algorithmic, security-critical, complex concurrency, novel architecture). When Opus implements, Phase 3 Opus review MUST be fresh cold-context `Agent` invocation.
> **Sonnet** (`Agent(model: "sonnet")`) — plan drafting, implement, test, self-review. Also reviews Haiku's diffs for Trivial tasks. On High, Sonnet DRAFTS the plan + ADR — drafting is not deciding: nothing Sonnet proposes is architectural authority until specialists/Opus approve it (phase-2 Step 2). Sonnet NEVER decides architecture unilaterally.
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
| Reading `.claude/do/config.json` (steady-state — location, path resolution, field semantics, defaults) | [`references/config-schema.md`](references/config-schema.md) |
| Creating / initializing / editing a config (Phase 0 auto-init, hand-authoring — full annotated schema, JSONL entry shape, examples) | [`references/config-authoring.md`](references/config-authoring.md) |
| Validating config on load | [`references/config-validation.md`](references/config-validation.md) |
| Stack detection or cache I/O | [`references/stack-detection.md`](references/stack-detection.md) |
| Any tracker operation | [`references/trackers.md`](references/trackers.md) |
| Any git operation | [`references/git-rules.md`](references/git-rules.md) |
| **Phase 1** (M/H, tracker configured & ≠ `none`) — issue creation | [`references/phase-1-issue.md`](references/phase-1-issue.md) — skip decided in Phase 1 §tracker-none skip; don't load on a none tracker |
| **Phase 2** — Sonnet prompt, plan review, self-review, stale-main | [`references/phase-2-implementation.md`](references/phase-2-implementation.md) |
| **Phase 3** (M/H) — gates, specialist audit, Opus review | [`references/phase-3-review.md`](references/phase-3-review.md) |
| **Phase 3** (Low) — build-verify + dep-vuln + diff scan, complete Low path | [`references/phase-3-low.md`](references/phase-3-low.md) |
| **Phase 4** — commit, push, context doc, metrics, announce (every tier) | [`references/phase-4-finalize.md`](references/phase-4-finalize.md) — **loaded by the finalize owner only** (see Finalize-owner note below); a thin orchestrator that delegated Phase 4 to the implementer does not re-read it |
| **Phase 4 PR path** (M/H with code-host) — PR, CI gate, auto-merge, issue comment | [`references/phase-4-pr.md`](references/phase-4-pr.md) |
| Changing the telemetry system itself (never at runtime) | [`references/telemetry-internals.md`](references/telemetry-internals.md) |
| Migration audit specialist | [`references/zero-downtime-migrations.md`](references/zero-downtime-migrations.md) |
| Specialist audit + PR reviewer routing | [`references/codeowners.md`](references/codeowners.md) |
| ADR generation (High) | [`references/adr.md`](references/adr.md) |
| Slack/Teams notifications | [`references/notifications.md`](references/notifications.md) |
| Pre-finalize sanity check | [`references/anti-patterns.md`](references/anti-patterns.md) |
| Opt-in harness enforcement (Stop / PreToolUse hooks) | [`references/hooks.md`](references/hooks.md) |

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
| `--complexity=T\|L\|M\|H` | Force complexity bucket (T = Trivial → Haiku). A forced tier still passes the Phase 2.0 plan-size gate; on a REBUMP verdict against a forced tier the orchestrator STOPs and asks — never silently overrides either side (phase-2 §2.0) |
| `--implementer=opus\|sonnet\|haiku` | Override default implementer (Phase 2 only — review/audit/merge stay on Opus) |
| `--repo=NAME` | Force target repo (skip workspace routing) |
| `--redetect` | Force stack re-detection (skip cache) |
| `--auto-merge` / `--no-auto-merge` | Per-task override of §4.2.6 CI-coupled auto-merge (distinct from merge-on-finish below) |
| `--merge` / `--no-merge` (bare `nomerge` token accepted) | Merge-on-finish override — see "Invocation-form default" below |

### Invocation-form default — merge-on-finish

If the triggering user message began with the **`+++` token** → `merge_on_finish = true`: Phase 4 ends by merging the gated branch ([`phase-4-finalize.md`](references/phase-4-finalize.md) §4.10.5 — `gh pr merge` on M/H, local ff/merge into `main` on T/L) and removing the worktree + branch. If it began with **`/do`** → `merge_on_finish = false` (today's await-review behavior). An explicit flag always wins over the form default: `+++ nomerge fix X` leaves the branch for manual review; `/do --merge fix X` merges. Strip `nomerge`/`--no-merge`/`--merge` from the task text like every other flag. Merge-on-finish NEVER fires on a blocked/escalated/draft outcome, and a red §4.2.5 CI gate always beats it — full fire conditions live only in §4.10.5. Do not confuse with `--auto-merge` (§4.2.6, the code-host's merge-when-CI-green).

### Advanced flags (niche)

| Flag | Effect |
|---|---|
| `--no-split` / `--split` | Per-task override of `config.pr_size.auto_split` (default on). On a Phase 3.0 PR-size BLOCK, `--split` auto-splits delivery into a stack of sub-cap PRs (§4.2.1); `--no-split` reverts to the pre-0.11 hard halt (draft PR + `blocked`, split manually) |
| `--skip-ci-wait` | Don't wait for CI before final announce |
| `--no-self-review` | Skip Sonnet self-review (Phase 2.5) — emergencies only |
| `--no-codeowners` | Skip CODEOWNERS-based reviewer routing |
| `--no-notify` | Skip notifications for this task |
| `--no-affected-graph` | Run full build/test even when monorepo affected-graph detected |
| `--no-caveman` | Skip companion-skill detection for this task |
| `--no-config-init` | Skip Phase 0 auto-init of `.claude/do/config.json` when missing (use defaults, write nothing) |
| `--no-specialists` | Auto-init config WITHOUT the default specialists preset (Opus inline review fallback for all groups) |
| `--no-metrics` | Skip telemetry auto-config — Step 1 won't patch existing configs missing `metrics`, Step 4 auto-init won't include the preset |
| `--issue-locale=<code>` | Force the `issue_locale` Phase 0 Step 4 auto-init writes (any ISO 639-1 code, e.g. `--issue-locale=fr`) — overrides the `$ARGUMENTS` script auto-detection (ru/ja/ko heuristics) |

### Implementer override semantics

| Override | On tier | Effect |
|---|---|---|
| `--implementer=opus` | M/H | Phase 2 spawns `Agent(model: "opus")` instead of Sonnet. Phase 3 Opus review MUST be fresh cold-context. Announce: `Implementer: Opus (cold-context review required)`. On L → warn `Opus on Low is overkill — proceed?` but honor. |
| `--implementer=sonnet` | T | Phase 2 spawns Sonnet instead of Haiku; Phase 3 diff-scan upgrades to Opus. On L/M/H → explicit **no-op** (Sonnet is already the default implementer; announce `implementer=sonnet (no-op — already default)`). |
| `--implementer=haiku` | T | No-op (Haiku is the Trivial default). On L/M/H → **HARD REJECT** (Haiku must not make logic decisions on multi-file, logic-bearing, or architectural work). |

Every tier/override combination is covered above — there are no implicit rejections beyond the one HARD REJECT (haiku on L/M/H); redundant overrides are announced no-ops, never silent downgrades. `--implementer=opus` does NOT skip specialists, ADR, CODEOWNERS, or PR-size guards — it only changes who writes the code.

## Phase 0 — Setup & Routing

Read [`references/phase-0-setup.md`](references/phase-0-setup.md). Six logical steps:

1. Load + validate config (inline WIP / postmortem checks if configured)
2. Companion-skill detect (caveman — sets prompt directive for Phase 2)
3. Resolve target repo(s)
4. Stack cache (load or detect)
5. Sanity checks (duplicate / migration / context doc — the concurrent-edit check runs in Phase 1, after the planned-files list exists)
6. Complexity routing + model assignment + announce

Final `[Phase 0] ...` announce — must include `Models:` line (orchestrator + implementer).

## Phases 1–4 — load reference per phase

| Phase | Always-run? | Reference |
|---|---|---|
| 1 — Issue creation | M/H **with a configured tracker** (skipped for T/L, and for any tier when `issue_tracker.type` is missing or `none`) | [`references/phase-1-issue.md`](references/phase-1-issue.md) — **do not load it on the skip; decide the skip here** (see below) |
| 2 — Implementation + self-review + ADR (High) | L/M/H (Trivial uses simplified flow below) | [`references/phase-2-implementation.md`](references/phase-2-implementation.md) |
| 3 — Code review (gates, specialist audit, Opus review) | M/H → [`references/phase-3-review.md`](references/phase-3-review.md); **Low → [`references/phase-3-low.md`](references/phase-3-low.md) instead** (Trivial: Sonnet diff-scan + dep-vuln when deps changed — see below) | per tier |
| 4 — Finalize (commit, push, context doc, metrics, announce) | always (loaded by the **finalize owner** only — see the Finalize-owner note below) | [`references/phase-4-finalize.md`](references/phase-4-finalize.md) — **plus** [`references/phase-4-pr.md`](references/phase-4-pr.md) (PR, CI, auto-merge, issue comment) on M/H with a code-host; **T/L never load the PR file** |

**Phase 1 tracker-none skip (decide here — do NOT open `phase-1-issue.md` for it).** On M/H, before loading the Phase 1 file, check the tracker: if `config.issue_tracker` is missing or `issue_tracker.type == "none"`, Phase 1 is a no-op — **skip it without reading `phase-1-issue.md`** (loading a 17 KB file only to execute its own first-line skip is pure overhead). Announce exactly one line, then move on:
- Plain none/missing → `[Phase 1] SKIPPED — tracker: none`
- Degraded none (config carries `_meta.tracker_degraded_from`, or Phase 0's `$CONFIG_LINE` included a `Tracker: DEGRADED to none (…)` line) → `[Phase 1] SKIPPED — tracker: none (DEGRADED from {github|gitlab}: {tracker_degraded_reason})` — repeat the reason here; the Phase 0 announce scrolls away and a silent skip reads as "worked as configured" when the truth is the tracker CLI was missing/unauthenticated (audit #13).

Downstream consequences of a none tracker (so nothing else needs `trackers.md` on this path): no `Closes #N`, no `Ref:` line in commits, no issue comment in Phase 4 ([`trackers.md`](references/trackers.md) §none). Load `phase-1-issue.md` **only** when the tracker is configured (`type` set and ≠ `none`) — that is the sole case where an issue is actually created.

**Low complexity simplifications**: skip Phase 1, Phase 3 = the complete [`phase-3-low.md`](references/phase-3-low.md) path — `build-verify` re-run + diff scan + dep-vuln scan (nothing else), Phase 4 = push + change summary (no PR, no ADR — ADR is High-only; context-doc update per §4.6 still applies when `required_for_finalize: true`), still emit metrics + notification. With merge-on-finish (`+++` form): §4.10.5 then merges the branch into `main` and removes the worktree.

**Trivial complexity simplifications**:
- Phase 1: skip (no issue)
- Phase 2: spawn `Agent(model: "haiku")` with tightly scoped prompt — exact files + exact change. Haiku does NOT explore codebase, does NOT make architectural decisions, does NOT touch tests. Anything ambiguous → **abort and re-route to Low**.
- Phase 3: skip all gates except dep-vuln (only if deps changed). `Agent(model: "sonnet")` diff-scan with one question: "does this diff do exactly what was asked, nothing more?" Reject + retry once; second failure → re-route to Low.
- Phase 4: commit + push to worktree branch. **No PR**, no context-doc update, no ADR. Emit metrics + notification. With merge-on-finish (`+++` form): §4.10.5 merges into `main` + cleans the worktree first. Co-Author = the implementer sub-agent's model identifier read from ITS session metadata (the Haiku-tier agent that wrote the diff — not the orchestrator's model, and never a hardcoded version; see Notation).
- Worktree rule still applies — Trivial does not bypass [`git-rules.md`](references/git-rules.md).

Before announcing completion, the **finalize owner** scans [`references/anti-patterns.md`](references/anti-patterns.md) (see the Finalize-owner note below — the actor that runs Phase 4 loads it; the other actor does not).

**Finalize owner (avoids a double read of `phase-4-finalize.md` + `anti-patterns.md`, ~69 KB).** Phase 4 is executed by exactly one actor, and only that actor loads those two files. The Phase 2 spawn prompt carries a `Finalize owner: {you | orchestrator}` flag ([`phase-2-implementation.md`](references/phase-2-implementation.md) §Sonnet prompt template): with `you` (the default, and the dominant single-agent install) the spawned implementer runs the whole flow through Phase 4 and finalizes itself — the orchestrator then **relays** the implementer's §4.13 announce instead of re-reading the two files to verify it (enforcement stays the wrapper OK-line + the opt-in Stop gate). With `orchestrator` the implementer returns after coding and the orchestrator runs Phase 4 from its own copy. Either way the §4.13 bash flow runs **exactly once**, by the owner — never by both, never by neither; §19a announce coupling is unchanged.

## Top-level git constraints (full: [`references/git-rules.md`](references/git-rules.md))

- Worktree only — never `git checkout -b`, never `git clone`
- Never commit to `main` (two scoped exceptions, both defined in [`git-rules.md`](references/git-rules.md): Phase 4.6 context-doc delivery into a separate docs repo gated on `context_doc.allow_main_push: true`, and §4.10.5 merge-on-finish merging THIS run's gated branch after Phase 3 APPROVE). Never `--force` / `--hard` / `--amend` / `--no-verify`
- Never modify `.git/config` or `core.hooksPath`
- Never commit `.env*` / `*.key` / `*.pem` / `credentials.*` / `*.secret` or inline keys/tokens. The Phase 4.1.2 `secret-scan` wrapper gates every push over the full push range (`merge-base(origin/main, HEAD)..HEAD`) — push only on its exit 0, never on eyeballed diffs
- `Co-Authored-By: <current model from environment>` — auto-detect, never hardcode

## Top-level anti-patterns (full: [`references/anti-patterns.md`](references/anti-patterns.md))

**Hot ones to scan before final announce**:

- **Final assistant message ends with PR-summary prose and NO `Metrics: ...` line** — Phase 4.13 procedure skipped. Run bash flow verbatim from `phase-4-finalize.md` instead of composing prose.
- **Auto-named branches without `i{N}` for M/H** — Phase 4.0 renames UNCONDITIONALLY before PR open. "Pre-spawned worktree" is NOT an excuse — `git branch -m` works on pre-spawned worktrees too.
- **Using `Agent(isolation: "worktree")` for Phase 2** — auto-names branches, breaks `config.naming`. Pre-create worktree explicitly via `git worktree add`.
- **Downgrading a Phase 3.0 PR-size BLOCK to `warn`** — the `pr-size-check` wrapper owns the verdict and BLOCK exits 3. Never eyeball the diff and ship an over-block change as one `warn` PR (production ledger: [anti-patterns §19f](references/anti-patterns.md)). BLOCK's default response is **auto-split into a stack of sub-cap PRs** (§4.2.1 `pr-split`), or draft PR + `blocked` with `--no-split` — never a single mergeable over-block PR. Plan-time sibling: Phase 2.0 `plan-size-check` SPLIT-REQUIRED.
- **Skipping zero-downtime migration audit** when migration present
- **Bypassing CODEOWNERS** when file exists in repo
- **Subjective reviews / scope creep / silent assumptions / speculative abstractions / drive-by refactors**
- **Opus writing code without `--implementer=opus`** / **Haiku making logic decisions**
- **Shell-injecting `{title}`/`{labels}` into tracker commands** — pass via env vars or argv arrays; see `references/trackers.md` §Security
- **Compressing structured output when caveman is active** — `claimed_status`, metrics JSONL, announce format are LITERAL (parsed by downstream tooling)
