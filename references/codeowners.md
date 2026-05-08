# CODEOWNERS Integration

CODEOWNERS routes review responsibility based on which files a PR touches. The skill uses it for two things:

1. **Specialist audit routing** (Phase 3.6) — augment `config.specialists` with auditors mapped to the specific code-owners affected
2. **PR reviewer auto-request** (Phase 4.2) — `gh pr create` already does this natively when `.github/CODEOWNERS` exists; we just ensure it's not bypassed

## File discovery

Search `config.codeowners.paths` (default: `.github/CODEOWNERS`, `.gitlab/CODEOWNERS`, `docs/CODEOWNERS`, `CODEOWNERS`). First existing file wins.

If none found and `config.codeowners.enabled: true` → warn once, then skip (no error).

## Syntax (GitHub format — universal de-facto standard)

```
# Comments start with #

# Pattern → owner(s) (space-separated)
*                       @platform-team
/docs/                  @docs-team
*.go                    @backend-team
*.tsx                   @frontend-team @design-team
/internal/auth/**       @security-team @backend-team
/migrations/*.sql       @data-team @backend-team
```

Rules:
- Last matching pattern wins (NOT first)
- `*` matches anything except `/`
- `**` matches anything including `/`
- Patterns starting with `/` are anchored to repo root
- Patterns ending with `/` match only directories
- Owners can be: `@username`, `@org/team-name`, or email

## Matching logic

1. `git diff --name-only main...HEAD` → list of changed files
2. For each file, find the last-matching CODEOWNERS rule
3. Collect unique set of owners across all changed files
4. Map each owner to a `subagent_type` via `config.codeowners.agent_map`
5. Owners without a mapping → omitted from auditor list (but still get GitHub auto-request for human review)

## Specialist augmentation

Phase 3.6 specialist list is the union of:
- `config.specialists.{backend_audit | frontend_audit}` (per scope)
- Mapped agents from CODEOWNERS owners (deduplicated)
- `config.specialists.migration_audit` (always, if migration exists)

Example flow:
```
Diff touches: src/api/users.go, web/components/Avatar.tsx, migrations/042_add_avatar_url.sql

CODEOWNERS resolves to: @backend-team, @frontend-team, @data-team

config.codeowners.agent_map:
  @backend-team  → backend-development:backend-architect
  @frontend-team → frontend-excellence:react-specialist
  @data-team     → database-design:database-architect

Specialist auditor set =
  config.specialists.backend_audit (e.g. code-reviewer)
  + backend-development:backend-architect (from CODEOWNERS @backend-team)
  + config.specialists.frontend_audit (e.g. code-reviewer)
  + frontend-excellence:react-specialist (from CODEOWNERS @frontend-team)
  + database-design:database-architect (from migration_audit AND @data-team — dedup)
  → run all in parallel
```

Cap at 5 auditors (more = noise without signal). If union >5, prioritize:
1. Always: `migration_audit` if migration exists
2. Always: at least one architect/lead
3. Always: at least one security agent if auth/input handling
4. Add CODEOWNERS-mapped agents until cap

## PR reviewer auto-request

When `.github/CODEOWNERS` exists at repo root, `gh pr create` automatically requests review from matched owners. The skill should NOT bypass this with `--reviewer @other`.

For GitLab: `glab mr create` does NOT auto-request from CODEOWNERS by default. Phase 4.2 should add `--reviewer` for each matched human owner if known.

## Anti-patterns to detect

The audit step should also flag:
- Diff touches files owned by N different teams but PR is filed by single contributor without CODEOWNERS coordination → suggest splitting PR or adding `Cc: @teamX` in description
- New file created in a path with no CODEOWNERS entry → warn (probably should add a rule)
- CODEOWNERS rule modified without notice to existing owners → ensure `@org/admins` review

## When to skip

- `config.codeowners.enabled: false`
- File doesn't exist in any of the search paths
- `--no-codeowners` flag in `$ARGUMENTS` (one-off override)
- Solo-maintainer projects (still useful as documentation, but no augmentation needed)
