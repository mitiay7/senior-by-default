# Git Rules

## Pre-flight (every task, before any worktree/branch op)
```
git -C {repo_path} status --porcelain
```
Any modified tracked files OR any untracked files → **STOP**, ask user which to stash/discard. Do not proceed.

## Worktree creation — explicit only

Never `git checkout -b`. Never `git clone`. **Never use the Agent tool's `isolation: "worktree"` parameter** — it auto-names branches (`claude/funny-leakey-...`) and bypasses `config.naming`, breaking traceability between issue id and branch.

Always create the worktree explicitly BEFORE spawning any Sub-Agent:
```
git -C {repo_path} fetch origin --prune
git -C {repo_path} worktree add {worktree_path} -b {branch} origin/main
```

Then spawn `Agent(model: "sonnet")` with the worktree path passed in the prompt as the working directory. Sub-agent does NOT create its own worktree.

### `{worktree_path}` resolution
1. If `config.worktree.base` is set → `{config.worktree.base}/{repo_name}-{suffix}` (sibling-of-repo style — typical for multi-repo workspaces)
2. Else → `{repo_path}/.claude/worktrees/{suffix}` (Claude Code convention; default for new projects)

Both styles are first-class. Pick by config.

### Branch and suffix from `config.naming` (REQUIRED — auto-named branches like `claude/<adj>-<noun>` are forbidden)

| Complexity | `worktree_suffix` (default) | `branch` (default) |
|---|---|---|
| Low | `do-{slug}` | `feat/{slug}` |
| Medium / High | `i{N}` (issue id) | `feat/i{N}-{slug}` |

`{N}` MUST appear in the branch name for M/H complexity — this is how metrics, PRs, and tracker comments cross-reference. Linear/Jira-style prefixed IDs work because `{N}` substitutes the full id (`eng-123`, `PROJ-456`).

Override the templates in `config.naming` if your team uses different conventions. See [`config-schema.md`](config-schema.md) under `naming`.

### Branch normalization at Phase 4.0 — executed by the `branch-normalize` wrapper, NOT by inline bash

Before the final commit & push, Phase 4.0 runs the **`branch-normalize` wrapper** (`scripts/branch-normalize`, invoked per [`phase-4-finalize.md`](phase-4-finalize.md) §4.0). It owns the whole decision: slug kebab-normalization (Unicode letters preserved — see §$ARGUMENTS sanitization below; hostile ASCII → `-`; 40-char cap), `config.naming` template substitution, `-v2..-v9` collision suffixes (§Branch collisions), `git check-ref-format` validity, the rename, and old-remote-ref cleanup. Its verdict line carries the `head=<sha8>` anti-fabrication tell (anti-pattern [§19j](anti-patterns.md)). Computing an `EXPECTED` name in spec bash — or announcing a branch name that never appeared in a wrapper verdict — is the v0.3.1 production violation this wrapper exists to prevent.

A `BRANCH RENAMED` verdict is a SIGNAL that worktree creation didn't follow spec — recorded as `branch_rename` in the metrics entry's `--notes`; fix the next-task creation flow.

## Forbidden operations (no exceptions)
- Never commit to `main` / `master`
- Never `--force`, `--force-with-lease`, `--hard`, `--amend`, `--no-verify`
- Never modify `.git/config` or `core.hooksPath`
- Undo with `git revert` only — never history rewrite

## Commits
Frequent. **Specific files only** — never `git add .` or `git add -A`.

Convention (Conventional Commits):
```
{type}(module): {description}
```
Types: `feat | fix | refactor | test | chore | wip`.

For final commit on M/H: include `Ref: {issue_tracker.repo}#{N}` if issue tracker configured.

`Co-Authored-By` line — **auto-detect current model** from environment metadata (e.g. "Claude Opus &lt;version&gt; (1M context)" — read the running build, do not copy a literal version from this doc). Format:
```
Co-Authored-By: <Model Name> <noreply@anthropic.com>
```
Never hardcode an old version.

## Branch collisions
Branch already exists → increment suffix `-v2`, `-v3`, ..., **cap at `-v9` → ask user**. Never touch branches you didn't create.

## Secret guard (every push) — executed by the `secret-scan` wrapper, NOT by inspection

The gate is the **`secret-scan` wrapper** (`scripts/secret-scan`), invoked by the Phase 4.1.2 push block ([`phase-4-finalize.md`](phase-4-finalize.md)) — the push is dispatched on its exit code (0 = push, 3 = BLOCK, 1 = REJECT/fail-closed). Manual diff eyeballing is not the gate (anti-pattern [§19g](anti-patterns.md)).

What the wrapper enforces, over the **full push range** `merge-base(origin/main, HEAD)..HEAD` (per-commit names + added content; full-tree fallback when no origin/main):

- Forbidden file globs: `.env*`, `*.key`, `*.pem`, `credentials.*`, `*.secret`, `id_rsa*`, `*.p12`, `*.pfx` — basename match on every file touched in the range. Template files (`*.example`, `*.sample`, `*.template`, `*.dist`) are exempt from the name check only; their content is still scanned.
- Inline secrets in added lines: API keys (`sk-...`, `xox[baprs]-...`, `gh[pousr]_...`, AWS `AKIA...`), PEM private-key blocks, signed JWTs, quoted password / client-secret / signing-key assignments.

Why the full range and not `git diff --cached` (the pre-wrapper prose): by push time the earlier task commits are already in branch history — a secret committed (or committed-then-deleted) mid-implementation never appears in the staged diff, yet its blob is pushed with everything else. The range scan closes that latent bypass; `git log -p` per commit also catches add-then-delete.

Wrapper says BLOCK → STOP, alert user (finding list = pattern names + paths, never the secret text). Do not push — not from another block, another cwd, or with `--no-verify`. A pushed secret is revoke-and-rotate, not revert.

Origin: the pre-push check was instruction-only prose through v0.8.x — by the §19 ledger's law (metrics: 7 audited bypasses; caveman: 2 prod bypasses; plan-size, pr-size) it would eventually be skipped, and this is the pipeline's only unrecoverable skip. Wrapper-owned since the 2026-07 audit (finding 5).

## $ARGUMENTS sanitization
Strip injection-enabling characters only:
- backtick `` ` ``
- `$(...)` and `${...}`
- `;`, `|`, `&` (when used as command separators)
- `>` followed by a path (file redirection)

**Preserve all Unicode letters** — Cyrillic, CJK, emoji, accented Latin, etc. The previous restrictive `[A-Za-z0-9 _\-/.,#:()']` whitelist broke non-English tasks.

If sanitization would strip too aggressively → warn user and ask for clarification rather than silently mangling.

## Worktree cleanup (Phase 4.8)
Tell user — do NOT execute unless explicitly requested:

If `config.worktree.cleanup_cmd` set → suggest that template (substitute `{repo}`, `{suffix}`).
Else → suggest:
```
git -C {main_repo_path} worktree remove {worktree_path}
git -C {main_repo_path} branch -D {branch}    # only after merge confirmed
```

## Rollback (post-merge regression)
New `fix/...` branch from `origin/main`. `git revert <merge-sha>`. Never rewrite history of merged work.
