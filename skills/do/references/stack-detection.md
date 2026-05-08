# Stack Detection & Cache

## When this runs
Phase 0.2 only. **If cache exists and `$ARGUMENTS` doesn't request re-detection, skip this entirely** — use cached values.

## Cache location
`~/.claude/do/cache/<slug>.json`

### Slug rule
Replace every run of non-alphanumeric characters (including `/`, `.`, ` `, `_`) with a single `-`, then strip leading and trailing `-`. Reference implementation in bash:

```bash
slug() {
  printf '%s' "$1" | LC_ALL=C tr -c '[:alnum:]' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//'
}
slug /Users/alice/work/api                                # → Users-alice-work-api
slug "/Users/alice/work/my project"                       # → Users-alice-work-my-project
```

Equivalent regex (for spec verification): `s/[^a-zA-Z0-9]+/-/g` then trim leading/trailing `-`.

Examples (verified):
| Repo path | Slug |
|---|---|
| `/Users/alice/work/api` | `Users-alice-work-api` |
| `/Users/alice/work/my-monorepo` | `Users-alice-work-my-monorepo` |
| `/home/alice/projects/my_app` | `home-alice-projects-my-app` |

This matches Claude Code's project-path slug convention so cache files don't collide with weird characters in shell. **Do NOT preserve dots, underscores, or spaces** — they make filenames awkward across tools (jq, grep, scripts).

`mkdir -p ~/.claude/do/cache/` if missing before writing.

## Cache schema (version 1)
```json
{
  "version": 1,
  "repo_path": "/abs/path/to/repo",
  "detected_at": "2026-05-07T10:00:00Z",
  "stack": "go" | "ts" | "js" | "rust" | "python" | "ruby" | "php" | "dart" | "jvm" | "dotnet" | "deno" | "elixir" | "fullstack" | "other",
  "package_manager": "pnpm" | "npm" | "yarn" | "bun" | "go" | "cargo" | "uv" | "poetry" | "pip" | "bundler" | "composer" | "pub" | "gradle" | "maven" | "dotnet" | "deno" | "mix" | null,
  "build_cmds": ["go build ./...", "..."],
  "lint_cmds": ["golangci-lint run ./...", "..."],
  "test_cmd": "go test ./...",
  "ui_files": true | false,
  "ui_extensions": [".tsx", ".vue"],
  "migration_dir": "migrations/" | null,
  "migration_pattern": "*.sql" | null
}
```

## Re-detection triggers
Re-detect (and overwrite cache) only when:
- Cache file does not exist
- `cache.version != 1` (schema migrated)
- **`cache.repo_path` does not match the current repo's absolute path** — guards against slug collisions for paths like `/Users/alice/work-api` and `/Users/alice/work/api` (both produce the same slug `Users-alice-work-api`)
- `$ARGUMENTS` contains literal `--redetect`
- `$ARGUMENTS` contains natural-language equivalent: "re-detect stack", "повторно определи стек", "пере-определи", "redetect stack", etc.

**Do NOT** auto-invalidate by file mtime, dependency changes, or time elapsed. Stack changes are infrequent and the user has full control.

When writing cache, always include `repo_path` (canonical absolute path, no symlinks resolved unless via `realpath`). The verification step on load uses string equality.

## Detection rules

### Step 1 — root scan (non-recursive)
First, walk repo root with one `ls`:

| Marker | Stack | Build | Lint | Test |
|---|---|---|---|---|
| `go.mod` | `go` | `go build ./...` | `golangci-lint run ./...` (only if `.golangci.yml`/`.golangci.yaml` exists) | `go test ./...` |
| `package.json` | `ts` if any `.ts`/`.tsx` in `src/` else `js` | from `scripts.build` | from `scripts.lint` + `scripts.type-check` (if either exists) | from `scripts.test` |
| `Cargo.toml` | `rust` | `cargo build` | `cargo clippy -- -D warnings` | `cargo test` |
| `pyproject.toml` | `python` | (skip — interpreted) | from `[tool.ruff]` / `[tool.mypy]` (if defined) | `pytest` if `[tool.pytest]` or `tests/` exists, else null |
| `Gemfile` | `ruby` | `bundle install` | `bundle exec rubocop` (if Gemfile mentions rubocop) | `bundle exec rspec` if `spec/` exists else `bundle exec rake test` |
| `composer.json` | `php` | `composer install --no-dev` (build) | `vendor/bin/phpstan analyse` (if `phpstan.neon` exists), `vendor/bin/php-cs-fixer fix --dry-run` (if `.php-cs-fixer.dist.php` exists) | `vendor/bin/phpunit` if `phpunit.xml*` exists, else `vendor/bin/pest` if `pest.php` exists |
| `pubspec.yaml` | `dart` (or `flutter` if `flutter:` key in pubspec) | `flutter build` (if Flutter) else `dart compile` | `dart analyze` (or `flutter analyze`) | `flutter test` (if Flutter) else `dart test` |
| `build.gradle` / `build.gradle.kts` / `pom.xml` | `jvm` | `./gradlew build` (Gradle) or `mvn -B compile` (Maven) | `./gradlew spotlessCheck` / `mvn checkstyle:check` (if configured) | `./gradlew test` / `mvn test` |
| `*.csproj` / `*.sln` | `dotnet` | `dotnet build` | `dotnet format --verify-no-changes` | `dotnet test` |
| `deno.json` / `deno.jsonc` | `deno` | (skip — interpreted) | `deno lint` | `deno test` |
| `mix.exs` | `elixir` | `mix compile` | `mix credo` (if dep present in mix.lock) | `mix test` |

Multiple markers at root → `fullstack`. Build/lint/test arrays merge from each (deduplicated).

### Step 2 — subdir scan (REQUIRED if root yielded no markers)

If root has NO marker files, **do not give up and write `stack: "other"`** — many monorepos keep stacks in subdirs (e.g. `App/`, `apps/`, `services/`, `backend/`, `frontend/`). Scan up to depth 3 for the same marker files:

```bash
# Skip noisy/irrelevant dirs
find {repo} -maxdepth 3 \( \
   -name "go.mod" -o -name "package.json" -o -name "Cargo.toml" \
   -o -name "pyproject.toml" -o -name "Gemfile" -o -name "composer.json" \
   -o -name "pubspec.yaml" -o -name "build.gradle" -o -name "build.gradle.kts" \
   -o -name "pom.xml" -o -name "*.csproj" -o -name "deno.json" -o -name "mix.exs" \
\) \
-not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/target/*" \
-not -path "*/build/*" -not -path "*/dist/*" -not -path "*/vendor/*" \
-not -path "*/.next/*" -not -path "*/.turbo/*" \
-print
```

**Critical**: when subdir scan finds markers, prefix every command with `cd <subdir> && ...`. The cache should be:

```json
"build_cmds": [
  "cd App && pnpm build",
  "cd App/backend && go build ./..."
]
```

NOT just `pnpm build` (which would fail because root has no `package.json`).

If multiple subdir markers found → `stack: "fullstack"`, package_manager picks the dominant one (or `null` if mixed). Merge build/lint/test arrays from all subdirs.

### When subdir scan returns nothing
Then `stack: "other"`, `build_cmds: []`, `lint_cmds: []`, `test_cmd: null`. Phase 2 will degrade gracefully (no automated build verification — Sonnet does its own thing per task).

### Package manager (JS/TS)
| Lockfile | Manager | Prefix for scripts |
|---|---|---|
| `pnpm-lock.yaml` | pnpm | `pnpm` |
| `bun.lockb` or `bun.lock` | bun | `bun` |
| `yarn.lock` | yarn | `yarn` |
| `package-lock.json` | npm | `npm run` |
| none of above | npm (default) | `npm run` |

Apply prefix to script invocations: `pnpm build`, `bun test`, `yarn lint`, `npm run type-check`.

### Reading package.json scripts
```
jq -r '.scripts.build // empty' package.json
jq -r '.scripts.lint // empty' package.json
jq -r '.scripts["type-check"] // .scripts.typecheck // empty' package.json
jq -r '.scripts.test // empty' package.json
jq -r '.scripts.dev // empty' package.json    # for ui_gate auto-fill
```
Empty string → omit that command from the array.

### UI files
Set `ui_files = true` if repo contains any of `*.tsx`, `*.jsx`, `*.vue`, `*.svelte`, `*.astro`. Cheap check:
```
find {repo} -maxdepth 5 \( -name "*.tsx" -o -name "*.jsx" -o -name "*.vue" -o -name "*.svelte" -o -name "*.astro" \) -not -path "*/node_modules/*" -print -quit
```
For Flutter (`pubspec.yaml` with `flutter:` key): `ui_files = true`, `ui_extensions = [".dart"]` — but UI Gate only runs against HTTP servers; native UI is out of scope.

`ui_extensions` = list of extensions that actually matched.

### Migration directory
Look for, in order (first found wins):

| Path | Convention |
|---|---|
| `migrations/` | generic, golang-migrate, custom |
| `db/migrate/` | Rails (ActiveRecord) |
| `db/migrations/` | Knex, Sequelize, custom |
| `prisma/migrations/` | Prisma |
| `alembic/versions/` | Python Alembic |
| `internal/db/migrations/` | Go internal layout |
| `src/main/resources/db/migration/` | Flyway (JVM convention) |
| `src/Migrations/` or `Migrations/` | EF Core (.NET) |
| `priv/repo/migrations/` | Ecto (Elixir) |
| `db/schema_migrations/` | Diesel (Rust) |

Pattern derived from existing files:
- `*.sql` (most common — golang-migrate, Flyway, Rails)
- `*.ts` (Prisma, TypeORM)
- `*.py` (Alembic)
- `*.cs` (EF Core)
- `*.exs` (Ecto)
- `*.rs` (Diesel)

None found → `migration_dir: null`, `migration_pattern: null`. Phase 0.6 skipped.

## Detection output
Print inline before continuing Phase 0:
```
Stack: {stack} | PM: {pm or "—"} | UI: {y/n} | Migrations: {dir or "none"} | Cached: NEW
```

For cache hits print `Cached: HIT (detected {detected_at})` instead.

## Cache write
After detection completes:
```
mkdir -p ~/.claude/do/cache/
```
Then use the `Write` tool to create the JSON file (not raw bash with `cat <<EOF`).

## Manual cache clear (user-facing)
- Wipe all caches: `rm -rf ~/.claude/do/cache/`
- Single repo: `rm ~/.claude/do/cache/<slug>.json`
- Force re-detect inline: add `--redetect` to the next `+++ ...` invocation
