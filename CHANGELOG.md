# Changelog

All notable changes to this skill will be documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) loosely; versioning follows [SemVer](https://semver.org/).

## [Unreleased]

## [0.3.1] — 2026-05-09

Patch release. Fixes two systematic Phase 4 escapes observed in real production runs:
1. **Phase 4.11 metrics emission consistently skipped** despite "MANDATORY" labels, even with `disable-model-invocation` removed in v0.3.0. Sub-agents/Opus orchestrator open the PR, write a detailed PR-summary prose, then stop — never appending JSONL.
2. **Phase 4.1.0 branch rename rationalized away** when worktree was pre-spawned by Claude Code's harness. Sub-agent observed mismatch (`claude/<adj>-<noun>-<hash>` vs `feat/i{N}-{slug}`) and explicitly chose NOT to rename, citing "the worktree was pre-spawned" as exception — even though `git branch -m` works fine on pre-spawned worktrees.

Both bugs are the same class: **soft instructional enforcement fails when the agent treats steps as ceremony**. v0.3.1 replaces soft enforcement with structural coupling.

### Changed
- **Phase 4.13 final-announce is now a single bash procedure that EMITS METRICS AND PRINTS ANNOUNCE in one block**. Announce text references `$METRICS_LINE` shell variable that's set ONLY by the metrics-append step. You cannot produce the announce without running the emit. If the announce comes out without the `Metrics: ...` line, the procedure was skipped (free-form prose written instead). Hard structural coupling, not soft instruction.
- **Phase 4.0 (renamed from 4.1.0, moved up)**: branch normalization runs BEFORE Phase 4.2 PR creation. PR opens on the correct `feat/i{N}-{slug}` branch from the start, not `claude/...`. Eliminates the "PR is on auto-name; would have been i{N}-{slug} but" rationalization.
- **Pre-spawned worktree is NOT an excuse**: Phase 4.0 spec explicitly states the rename is UNCONDITIONAL. Worktree path is fine to keep; branch must follow `config.naming` for `i{N}`-traceability across commits/PRs/metrics/tracker comments.
- **Phase 2 sub-agent prompt template**: Phase 4 critical reminder pinned at the TOP of the Rules section (was buried at the end). Sub-agent's first instruction is "When this Sub-Agent reports done, you (Opus) MUST run the Phase 4.13 final-announce bash procedure verbatim..." — orchestrator gets the reminder at session-start context, not at end-of-task when it's already forgotten.

### Anti-patterns strengthened
- **31a (skip metrics emission)**: now points at the bash-coupling solution. Says: "if your final assistant message ends with PR-summary prose and NO `Metrics: ...` line, you skipped the procedure — go back and run the bash flow verbatim instead of composing prose announce."
- **31c (auto-named branches)**: now points at Phase 4.0 (BEFORE PR open) instead of 4.1.0 (after). Explicitly forbids the "pre-spawned worktree" rationalization.

### Top-level anti-patterns in SKILL.md updated
Two new entries surfaced to the top-level visible list:
- "Final assistant message ends with PR-summary prose and NO `Metrics: ...` line" (you skipped Phase 4.13 procedure)
- "Auto-named branches without `i{N}` for M/H" — now references Phase 4.0 (BEFORE PR) and explicitly disqualifies pre-spawn excuses

### Background
v0.3.0 removed `disable-model-invocation: true` to enable `+++` shortcut. We expected Phase 4.11 enforcement to hold via the strict description language. Real production runs showed it doesn't — sub-agents read all the right instructions but skip the final emit step because by the end of a long flow it feels ceremonial.

The pattern of failures (consistent across multiple sessions, regardless of caveman compression directive specifics) confirmed instructional enforcement is insufficient. v0.3.1 ships structural enforcement: the announce text physically depends on the metrics-emit shell variable. If sub-agent skips the emit, the announce literally can't be composed. Test in a fresh session: if the final message ends with `Metrics: <N> entries in <path>.`, the procedure ran. If the final message is free-form prose ending with PR-summary, it didn't.

## [0.3.0] — 2026-05-09

Minor release. Restores `+++` shortcut by removing `disable-model-invocation: true` and replacing the hard architectural guard with a strict-description soft guard.

### The trade-off

Third-pass audit (in v0.2.0) added `disable-model-invocation: true` because the skill performs side effects (issues, commits, pushes, PRs, optional auto-merge) and shouldn't auto-trigger from description matching mid-conversation. **The flag was correct** — it's defense-in-depth.

But the same flag also blocks Skill-tool invocations routed through a `+++` CLAUDE.md trigger. Verified with claude-code-guide: Claude Code currently has **no CLI-level prompt-rewrite mechanism** (`UserPromptSubmit` hook only supports adding context or blocking, not replacement). So with the flag set, `+++` simply cannot work — only `/do <task>` does.

v0.3.0 picks ergonomics over the hard guard:
- **Removed**: `disable-model-invocation: true` from frontmatter
- **Replaced with**: strict description language — `TRIGGER ONLY when the user's message LITERALLY starts with /do, /<plugin>:do, or +++`. `NEVER auto-trigger from description matching, perceived task fit, or conversational context, EVEN IF a coding task otherwise matches every other criterion.`
- **Result**: `+++` shortcut works; risk of false-positive description-match auto-trigger goes from "architecturally impossible" to "depends on Claude respecting the strict description". In practice Claude is good at respecting clear "ONLY when... NEVER..." rules; in pathological cases it could still misfire.

### What if I want the hard guard back?

Edit your local `~/.claude/skills/do/SKILL.md` (or `~/.claude/plugins/.../skills/do/SKILL.md`) and re-add `disable-model-invocation: true` to the frontmatter. You'll lose the `+++` shortcut. Document this trade-off in your team's onboarding so people know `/do <task>` is the only invocation in your setup.

### Changed
- **`skills/do/SKILL.md` frontmatter**: removed `disable-model-invocation: true`. Description rewritten with explicit "TRIGGER ONLY when LITERALLY starts with..." + "NEVER auto-trigger" language as soft guard. HTML comment under frontmatter explains the trade-off and the reason the flag was removed (CC harness lacks CLI-level prompt rewriting).
- **`install.sh`**: TRIGGER feature restored (was removed in v0.2.4 because the trigger didn't work). New installs get `+++` block in `~/.claude/CLAUDE.md` again. Marker-wrapped for clean uninstall.
- **`install.sh` Step 6**: legacy-cleanup branch (v0.2.4 behavior) replaced with trigger-setup branch (v0.2.0 behavior, but for a now-working trigger).
- **`README.md`**: removed broken "Why no `+++` shortcut via CLAUDE.md" + "Shortcut setup (CLI hook)" sections. Restored `+++` shortcut documentation in plugin install + manual install paths. Top example now shows both `/do` and `+++` forms. New Troubleshooting entries: "`+++` doesn't trigger anything" (check the trigger block in CLAUDE.md), "Worry about auto-trigger from description match" (re-add the flag for hard guard, lose the shortcut).
- **`.github/workflows/lint.yml`**: frontmatter check updated. Now ASSERTS `disable-model-invocation` is NOT set (or false), and that description contains "TRIGGER ONLY" + "NEVER auto-trigger". Locks in the v0.3.0 design — preventing accidental re-introduction of the flag without also removing the trigger feature.

### Migration for v0.2.4–v0.2.5 users

Re-run `install.sh` — it will write the `+++` trigger block to `~/.claude/CLAUDE.md` (which v0.2.4 cleanup may have stripped). Or add the marker-wrapped block manually:

```md
<!-- senior-by-default:trigger:start -->
## +++ Trigger

When a user message starts with `+++`, treat everything after `+++` as the argument and invoke the `/do` skill with that text. This is a shorthand — `+++ add user avatars` is equivalent to `/do add user avatars`.
<!-- senior-by-default:trigger:end -->
```

For plugin install users: replace `/do` with `/senior-by-default:do` in the block.

### Lessons from this whole arc (v0.2.0 → v0.2.5 → v0.3.0)

1. **Audit recommendations need end-to-end re-test of all documented entry points.** v0.2.0 added `disable-model-invocation` (correct fix for stated risk) but broke the documented `+++` flow. Caught only when a real user (the author) tried `+++` after the changes shipped.

2. **CI shellcheck on install.sh actually catches things.** v0.2.5 hot-fix happened in 5 minutes because shellcheck pinpointed the bad backtick on the right line.

3. **README that documents non-existent features is worse than missing docs.** v0.2.4 invented a "UserPromptSubmit hook that rewrites prompts" that Claude Code doesn't support. Removed in v0.3.0. Fix: verify any "PRs welcome" / "you can do X" claim against actual API docs before shipping.

4. **Hard guards (architectural) are stronger than soft guards (instructional).** v0.3.0 trades hard for soft for ergonomic reasons. That's the author's call as the primary user; teams with stricter security postures should keep the hard guard.

## [0.2.5] — 2026-05-09

Hot-fix for v0.2.4 — install.sh syntax error caught by CI shellcheck immediately after release.

### Fixed
- **`install.sh:219`**: `log "Kept legacy block. It does nothing — \`/do <task>\` works regardless."` — backticks inside double quotes triggered shell command substitution. shellcheck SC1073/SC1072 errors. Fix: switched to single-quoted string (no interpolation, no metachar parsing). Same class of quoting bug we fixed for tracker commands in v0.2.1, in our own installer this time.

### Lesson
v0.2.4 release notes already called for "CI smoke-test that the documented invocation flow actually fires (not just `bash -n` syntax check)". Shellcheck on install.sh is part of that. v0.2.4 added shellcheck to CI in v0.2.0 — and it caught this one before any user did. Working as intended.

## [0.2.4] — 2026-05-09

Patch release. Removes a broken-by-design feature: the `+++` trigger that v0.2.0–v0.2.3 wrote into `~/.claude/CLAUDE.md` never actually worked because of `disable-model-invocation: true` on the skill (added in v0.2.0 per third-pass audit). Surfaced when a real user (the author) tried `+++` after the v0.2.0 audit fixes and got:

```
Skill do cannot be used with Skill tool due to disable-model-invocation
```

Audit passes 1-7 didn't catch it because nobody re-tested the documented `+++` flow end-to-end after the third-pass `disable-model-invocation` change. The flag (correctly) blocks ALL Skill-tool invocations — including the supposedly-explicit ones the `+++` trigger asked the model to make.

### Changed
- **`install.sh`**: TRIGGER feature removed. No longer prompts for or writes a `+++` trigger block to CLAUDE.md.
- **`install.sh`**: new Step 6 — detects legacy marker-wrapped trigger blocks from v0.2.0–v0.2.3 in `~/.claude/CLAUDE.md` and offers to strip them (default: yes). Existing users get cleaned up on next install/update.
- **`README.md`**: removed `+++` shortcut promise from plugin install section. New "Why no `+++` shortcut via CLAUDE.md" Troubleshooting entry explains the conflict. New "Shortcut setup (CLI hook)" section sketches the right way to do `+++` (a `UserPromptSubmit` hook in `~/.claude/settings.json` that rewrites `+++ X` → `/do X` at CLI level — bypasses `disable-model-invocation` because it produces a real slash-command, not a Skill-tool invocation).
- **`SKILL.md` frontmatter description**: TRIGGER line dropped `(or +++ shortcut)`.
- **`SKILL.md` notation comment**: clarifies that any shortcut mechanism MUST happen at CLI level, never via CLAUDE.md instruction asking the model to invoke the skill.
- **`CONTRIBUTING.md`**: bug-report template + smoke-test checklist now reference `/do` (not `+++`).
- **References (`stack-detection.md`, `trackers.md`)**: example invocations updated from `+++ ...` to `/do ...`.

### Migration for existing users (v0.2.0–v0.2.3 installs)

Re-run `install.sh` — Step 6 will offer to strip the dead `+++` block from your `~/.claude/CLAUDE.md`. Or remove it manually (search for `<!-- senior-by-default:trigger:start -->` … `<!-- senior-by-default:trigger:end -->`).

If you want a `+++`-style shortcut, set up the CLI hook described in README "Shortcut setup (CLI hook)" — that path works regardless of `disable-model-invocation`.

## [0.2.3] — 2026-05-09

Patch release. Bug fix in `install.sh` — env-var override path was broken in v0.2.0–v0.2.2.

### Fixed
- **`install.sh prompt()` env-var override path**: when the user ran `SKILL_NAME=do TRIGGER=+++ curl ... | bash`, `prompt()` printed its `(from $ENVVAR)` confirmation banner to **stdout** instead of stderr. `SKILL_NAME=$(prompt ...)` then captured both the banner AND the value, producing a multi-line string that failed the next-line regex validation:
  ```
  ✗ Skill name must be lowercase alphanumeric with - or _ (got 'Skill name (becomes /do slash-command): do (from $SKILL_NAME)
  do')
  ```
  Interactive path was unaffected because that branch already wrote to `>&2`. Audit passes 1-6 didn't catch it because no pass exercised the `curl ... | bash` env-var path end-to-end.

  Fix: redirect the env-var override `printf` to `>&2`, matching the interactive branch. Added a code comment explaining why all user-facing prints in `prompt()` MUST go to stderr (only the value goes to stdout).

  Verified: `SKILL_NAME=mysuperskill prompt ...` now captures cleanly; subsequent regex validation passes; full `install.sh` env-var-override flow runs end-to-end on a clean machine.

## [0.2.2] — 2026-05-08

Patch release. Companion-skill integration with [caveman](https://github.com/JuliusBrussee/caveman) — additive, opt-in, no schema or behavior changes for existing configs.

### Added
- **Companion skill: caveman integration** — Phase 0.0.3 detects whether caveman is installed and announces its activation status. Caveman's SessionStart hook compresses agent output ~75% via "caveman speak" while preserving technical accuracy; once active, all Sub-Agent spawns from Phase 2 inherit compressed mode.
  - **Phase 2 Sub-Agent prompt template** now includes a conditional caveman-style directive (only when Phase 0.0.3 detected caveman as ACTIVE). Critically distinguishes natural-language framing (compress freely) from structured output — code, paths, JSON, diffs, `claimed_status: ready` self-review block, Phase 4.11 metrics JSONL, and final announce format MUST stay LITERAL because downstream tooling parses them.
  - **`--no-caveman`** override flag for per-task opt-out.
  - **README**: new "Recommended companion: caveman (install FIRST)" section above the Phase 3 plugins list. Explains why install order matters (SessionStart hook fires at session boot — installing caveman after senior-by-default requires session restart).
  - **Anti-pattern 31e**: skipping Phase 0.0.3 when caveman is installed.
  - **Anti-pattern 31f**: compressing structured output (would break Phase 4.11 metrics calibration parsing).

## [0.2.1] — 2026-05-08

Patch release. Security follow-up after sixth-pass audit found a bypass in v0.2.0's shlex-quote fallback for legacy string-form tracker commands.

### Security (audit sixth pass)
- **Schema-reject string-form `commands.<op>` containing `{title}` or `{labels}`**. The v0.2.0 `shlex.quote` fallback was insufficient when the template wraps the placeholder in `"..."` (the natural shape of `--title "{title}"`): a `"` inside user-supplied title content closes the surrounding quote regardless of how the substituted value is escaped. Reproducible exploit:
  - template: `--title "{title}"`
  - title from `$ARGUMENTS`: `x" --milestone 5 --label injected "y`
  - after `shlex.quote`: `'x" --milestone 5 --label injected "y'`
  - naive substitution: `--title "'x" --milestone 5 --label injected "y'"`
  - shell parses → `--title 'x · --milestone · 5 · --label · injected · y'` (six argv elements; injection succeeded)
  - **No text-level escape can fix this** — only argv-array form is safe.

  Fix: `config.schema.json` now has `not: { pattern: "\\{(title|labels)\\}" }` on the string variant of `trackerCommand`. String-form commands carrying user-controlled placeholders fail validation; argv-array form is required for any operation that interpolates `{title}` or `{labels}`. String form remains valid for ops without user content (`view_url`, `view_body`, `edit_body`, `comment` with body-file).

  - **`references/trackers.md`**: new subsection "Why the string form CANNOT carry user content (and is schema-rejected for it)" with the exploit and schema rule.
  - **`references/anti-patterns.md` 31d**: updated — `shlex.quote` is NOT sufficient fallback; schema enforces the constraint.

  Verified negatively: string with `{title}` rejected; string with `{labels}` rejected; string without user content (e.g. `linear issue view {N} --json | jq -r .url`) accepted; argv array with `{title}` accepted; existing 4 example configs still validate.

## [0.2.0] — 2026-05-08

Five rounds of independent audit closed. SemVer minor: additive schema changes, new opt-in features, structural reorg under `skills/do/`, security hardening of tracker execution. No breaking changes for existing user configs (legacy string-form tracker commands still validate).

### Security (audit fifth pass)
- **Shell injection via `{title}` placeholder** in tracker commands. User-controlled `$ARGUMENTS` reaches `{title}`; a malicious title (`x" --milestone 5 --label injected "y`) smuggled extra CLI flags through naive shell substitution.
  - **`references/trackers.md` rewritten** with explicit "Security: argv-safe execution is MANDATORY" section at top, including the exploit example, the env-var-based fix pattern, and argv-array form for custom trackers.
  - **Built-in `github`/`gitlab` tables** now show env-var argv-safe invocations (`gh issue create --title "$TITLE" ...`) instead of string templates with placeholder substitution.
  - **Custom trackers**: argv-array form is now the documented preferred form. String form remains for back-compat with mandatory `shlex.quote` fallback + deprecation warning.
  - **JSON Schema** `commands.<op>` now accepts either argv array (preferred) or string (deprecated) via `oneOf` in new `$defs/trackerCommand` definition.
  - **Anti-pattern 31d** added.
  - **Top-level anti-patterns in SKILL.md** updated.
  - **`phase-1-issue.md`** points readers at the secure execution pattern in trackers.md.

### Fixed (audit fourth pass)
- **Plugin examples local-path row removed from README**. Claude Code stores plugins under `~/.claude/plugins/cache/...` with versioned subdirectories that change across updates — the documented copy path was unstable. Plugin users are now directed to Option A (curl from raw.githubusercontent.com) or to clone the repo separately for local examples.
- **Custom `SKILL_NAME` no longer mutates tracked files**. Previously `install.sh` patched `skills/do/SKILL.md` in the cloned install dir, which broke `git pull --ff-only` on subsequent runs (local-changes detection skipped pull). Refactored: pristine clone is never modified; for custom names, a patched copy is regenerated on every install at `$INSTALL_DIR/.rendered-skills/<name>/` (gitignored). Symlink points at the rendered copy. Default name still symlinks straight at the pristine source — zero overhead.
- **Schema/markdown contract fully aligned on `version`**. `config-schema.md` prose now says "no fields are strictly required, `version` is *recommended*, defaults to 1 with warning, explicit mismatches hard-fail" — matches what `config.schema.json` actually does.
- **JSON Schema description rewritten** to declare the back-compat default-1 behavior explicitly, removing "all fields except version are optional" wording that contradicted the actual `required` array (empty).
- **Bonus**: `workspace` block in JSON Schema now has `required: ["is_workspace", "repos"]`. Previously empty `workspace: {}` or `workspace: {"repos":{}}` (without `is_workspace: true`) silently passed validation — fourth-pass auditor flagged this as "malformed workspace passes unexpectedly".

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
