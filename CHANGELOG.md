# Changelog

All notable changes to this skill will be documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) loosely; versioning follows [SemVer](https://semver.org/).

## [Unreleased]

### Fixed (audit third pass)
- **`model: opus` pinned in SKILL.md frontmatter** — orchestrator role (Phase 0 routing, Phase 3 review, Phase 4 decisions) now runs on Opus regardless of session model. Previously the skill ran on whatever active session model the user had, so a Sonnet session silently downgraded "Opus reviews" to Sonnet reviewing itself.
- **`disable-model-invocation: true` added** — skill creates issues, commits, pushes, opens PRs, optionally auto-merges. Must not auto-discover from description matching mid-conversation; only fires on explicit `/do` or `+++`.
- **Configure-your-project section in README rewritten** — install-agnostic curl variant for any install path; lookup table for plugin / manual-symlink / custom-clone install dirs. Old `cp ~/.claude/skills/do/../../examples/...` only worked for default symlink install.
- **CI frontmatter check tightened** — now asserts `model: opus` and `disable-model-invocation: true` are present (locks in the design decisions).

### Fixed (audit second pass)
- **Plugin install slash-command** documented correctly in README: `/senior-by-default:do` (plugin namespace) vs `/do` (manual symlink). Was: README implied `/plugin install` registers `/do`, which would mislead plugin-path users.
- **JSON Schema `version` no longer required** — matches the documented backcompat behavior in `config-validation.md` (missing version → default 1 + warn). Was: schema hard-failed configs that markdown said were valid.

### Changed (post-audit)
- **Restructured to plugin format**: `SKILL.md` and `references/` moved under `skills/do/`; added `.claude-plugin/plugin.json` manifest. Enables `/plugin install` distribution path.
- **`SKILL.md` frontmatter**: switched from prose blob to `TRIGGER:`/`SKIP:` format per Anthropic skill conventions; added `version: 0.1.0`.
- **README**: example-first lead, then tagline. Install order: plugin install → manual symlink → curl-pipe (last, with "review the script" warning). Added security/permissions section.
- **`config.schema.json`**: full JSON Schema (draft 2020-12) for programmatic validation. CI validates all examples against it.
- **`config-schema.md` + `config-validation.md`**: documented relative-path resolution (relative to config.json's dir, not CWD); `version` default-to-1 behavior with warning instead of hard-fail.
- **`stack-detection.md`** + Phase 0.2: cache verification now compares `cache.repo_path` against current repo (guards slug collision for `/foo/work-api` vs `/foo/work/api`).
- **Phase 0.3 concurrent-edit check**: now runs `git fetch origin main` first (was reading stale local ref).
- **`postmortem` defaults documented**: trigger keywords + branch prefixes listed in config-schema prose.
- **Notation section** added to `SKILL.md`: `Agent(model: ...)` shorthand explained for adopters reading source.
- **Pseudocode unification**: bash-first reference implementations (slug rule, etc.).
- **Markdown table escaping**: `--complexity=T\|L\|M\|H` no longer breaks GitHub rendering.

### Added (post-audit)
- `.github/workflows/lint.yml` — shellcheck + JSON validate + frontmatter check + markdown-link sanity.
- `uninstall.sh` — symlink removal, marker-aware trigger-block stripping from `~/.claude/CLAUDE.md`, optional cache/metrics/install-dir purge.
- `install.sh`: marker-wrapped trigger blocks (`<!-- senior-by-default:trigger:start/end -->`), local-changes detection before pull, fail-fast on hard deps (git/python3), warn on soft deps (jq/gh).

### Fixed (post-audit)
- Broken links in `SKILL.md` and `config-schema.md` to renamed `examples/multi-repo-go-react-config.json` (was `lea-config.json`).
- Self-referential link in `phase-4-finalize.md` (`references/notifications.md` → `notifications.md`).

## [0.1.0] — 2026-05-08

Initial public release.

### Architecture
- **Three-actor pipeline**: Opus (architect/reviewer), Sonnet (implementer), Haiku (trivial mechanical changes). Strict role boundaries enforced via SKILL.md rules and Phase 2 prompt construction.
- **Complexity routing**: Trivial / Low / Medium / High auto-detected from `$ARGUMENTS` + file count + scope, with `--complexity=` override flag.
- **Progressive disclosure**: SKILL.md (~250 lines) loads phase-specific references on demand; total ~2000 lines of documentation across 14 reference files.

### Phases
- **Phase 0 — Setup & routing**: config discovery + validation, stack detection (cached per repo), duplicate / concurrent-edit / migration checks, complexity assignment.
- **Phase 1 — Issue creation** (M/H): structured body with acceptance criteria, build checklist, worktree-setup commands; tracker-agnostic command templates.
- **Phase 2 — Implementation**: worktree pre-created by Opus (no `Agent(isolation: "worktree")`); Sonnet self-review with `claimed_status` declaration; stale-main check; ADR generation for High complexity.
- **Phase 3 — Code review**: gates for PR-size, dependency vulns, public-docs, tests, UI (Claude Preview), i18n, contract (BE↔FE types); Low diff-scan; specialist parallel audit (High); Opus acceptance-criteria check.
- **Phase 4 — Finalize**: branch verification, commit + push, PR creation, optional CI gate, optional auto-merge, context-doc update, mandatory metrics emission.

### Stack support
- Auto-detection: Go / TS / JS / Rust / Python / Ruby / PHP / Dart-Flutter / JVM / .NET / Deno / Elixir.
- Multi-stack monorepos: subdir-scan up to depth 3 when root has no markers (handles `apps/`, `services/`, `App/`, etc.).
- Package manager detection from lockfiles for JS ecosystem.

### Trackers
- Built-in: `github` (gh CLI), `gitlab` (glab CLI), `none`.
- `custom` type with command templates for Linear, Jira, internal trackers.
- Cross-repo close-keyword logic (Closes vs Refs).

### Distributed-team practices
- CODEOWNERS-aware specialist routing in Phase 3.6.
- Zero-downtime migration audit checklist (forbidden ops: DROP/RENAME/NOT NULL-without-default; expand-contract pattern).
- ADR generation for High-complexity architectural decisions.
- PR-size guards (warn at 800 lines / 20 files; block at 2000 / 50).
- Stale-main detection with optional auto-rebase.
- Sonnet self-review with calibration metric (`accurate` / `false_positive` / `false_negative`).
- Opt-in: CI gate, auto-merge, async notifications (Slack/Teams), feature flags, WIP limits.

### Metrics (Tier 1)
- JSONL append per task to `config.metrics.log_path`.
- Captured: phase durations, gate failure details, self-review calibration, specialist iterations with file:line citations, branch_rename flags, outcome, blocked_reason.
- **Mandatory emission** when `metrics.log_path` configured — final announce verifies append succeeded.

### Anti-patterns
- 42 documented anti-patterns across general process, memory/context, git, code, distributed-team practices.
- Pre-finalize sanity check loads `references/anti-patterns.md`.

### Configuration
- 4 example configs: minimal (single-repo + GitHub), multi-repo Go+React, Python+FastAPI+Alembic, Rust workspace + GitLab.
- Validation rules in `references/config-validation.md`.
- All features opt-in or skip-by-default; out of the box you get build/test/lint enforcement, self-review, PR-size guards, concurrent-edit warnings.

### Known limitations
- Tier 1 metrics schema may evolve; entries don't yet have schema version field.
- No `/do-review` companion skill yet for automated metrics analysis (Tier 2 — planned after data accumulates).
- `Agent(isolation: "worktree")` shortcut by Opus is hard-forbidden but enforcement relies on Phase 4.1.0 branch-rename fallback when violated.
