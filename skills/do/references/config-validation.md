# Config Validation

Run validation **once per task** after loading `config.json` in Phase 0.0. Skip silently for missing/optional fields. Hard-fail only on malformed schema.

For programmatic validation, use [`config.schema.json`](config.schema.json) (JSON Schema draft 2020-12). The rules below mirror the schema; the JSON Schema is the source of truth.

## Path resolution

All path-bearing fields resolve **relative to the directory containing `config.json`** (not CWD). Absolute paths and `~`-expanded paths are passed through unchanged. See [`config-schema.md`](config-schema.md) §"Path resolution" for the full list of affected fields.

## Validation rules

### `version`
- Should be present; if missing, default to `1` and emit a WARNING (don't hard-fail — back-compat)
- If present, must equal `1`
- Explicit mismatch (`version: 2`, etc.) → STOP, tell user: `Config version mismatch (got {n}, expected 1). Update .claude/do/config.json or upgrade the skill.`

### `workspace`
If present:
- `is_workspace` must be `true` (the field exists for explicitness)
- `repos` must be non-empty object
- Each repo's `path` must be an absolute path that exists (`test -d {path}`)
- Each repo's `path` must contain a `.git` dir or file (`test -e {path}/.git`) — if not, warn: `{repo-key} at {path} is not a git repo`
- Each repo's `scope_keywords` must be a non-empty array of strings

### `issue_tracker`
If present:
- `type` must be one of: `github`, `gitlab`, `none`, `custom`; omitted → treat as `github` (documented default — `repo` is still required)
- `none` → ignore other fields
- `github` / `gitlab` → require `repo` (string, format `owner/name`)
- `custom` → require `commands.create` at minimum; warn for each missing operation
- `commands` placeholders: validate that `{repo}` appears in templates that need it; `{N}` appears in per-issue commands (view/edit/comment)

### `context_doc`
If present:
- `path` must exist (`test -f {path}`)
- `sections` must be an object — values can be integers (line/section numbers) or strings (anchor names)
- `required_for_finalize` must be boolean

### `i18n`
If present:
- `fn` must be non-empty string
- `locale_files` must be array of paths
- For each locale file: `test -f {path}` — warn if missing (but don't fail; might be created in this task)
- `ui_extensions` must be array of strings starting with `.`

### `ui_gate`
If present:
- `infra_cmd` and `dev_cmd` must be non-empty strings
- `url` must be a valid HTTP(S) URL
- `login_script` (if set) must exist and be executable

### `contract_gate`
If present, both paths optional but if set: must be relative paths (resolved against repo root at use time).

### `specialists`
If present, each list must be array of strings in `plugin:agent-name` format. No existence check (plugins may be loaded lazily).

### `naming`
If present:
- For each of `low.{worktree_suffix, branch}` and `issue.{worktree_suffix, branch, ref_format}`: must contain at least one placeholder OR be a literal that doesn't conflict with git refs
- Placeholders: only `{N}` and `{slug}` allowed
- Branch templates: must NOT start with `main`, `master`, `release/` (reserved)

### `worktree`
If present:
- `base` must be an absolute path that exists
- `cleanup_cmd` (if set) is a template — no validation on content

### `issue_locale`
If present: must match `^[a-z]{2}(-[A-Z]{2})?$` (any ISO 639-1 code, optional region — `en`, `ru`, `ja`, `ko`, `pt-BR`). Pattern, not an enum: Phase 0 auto-init detects `ja`/`ko` and its output must validate.

### `metrics`
If present: `null` is VALID — explicit telemetry opt-out (`config-ensure-metrics` respects it, never re-patches). Object form: `log_path` is string or `null` (`null` = keep block, disable JSONL emission — the opt-out auto-init's `_setup_notes` advises).

### `memory_path`
If present and not `"auto"`: must be an absolute path. Warn if file doesn't exist (will be created on first write).

### `acceptance_extensions`
If present: each item must have non-empty `trigger_keywords` array and non-empty `criterion` string.

## Validation flow

1. Read `config.json`
2. Parse JSON — malformed JSON → STOP, show line:col of error
3. Schema gate — programmatic check against [`config.schema.json`](config.schema.json) when tooling exists (`python3 -c "import jsonschema"` succeeds). Module absent → do NOT fail, but NEVER skip silently: run the rule-based checks below and append `(schema gate SKIPPED — jsonschema unavailable)` to the `Config:` announce line. The write-path wrappers (`config-init`, `config-ensure-metrics`) emit the same suffix on their success lines when they couldn't schema-validate — a clean announce with no suffix means the schema gate actually ran. The suffix is wrapper/flow-emitted, not an agent annotation — carrying it verbatim into the announce is not a §19c violation; stripping it is.
4. Validate `version`
5. For each section present: run rules above
6. Collect WARNINGS and ERRORS separately
7. ERRORS → STOP, list all errors, ask user to fix
8. WARNINGS → print before Phase 0.0 announcement, proceed

## Example error output

```
[Config] /Users/alice/work/.claude/do/config.json — 1 error, 2 warnings:

ERROR:
  - issue_tracker.type "githab" — must be one of: github, gitlab, none, custom

WARNINGS:
  - workspace.repos.lea-api.path /Users/alice/work/api — not a git repo (no .git found)
  - i18n.locale_files[1] /Users/alice/work/lea-web/src/locales/de.json — file not found

Fix the error and re-run.
```

## Tolerant fallback

If validation hits an error in an OPTIONAL section, the skill MAY fall back to "section disabled" rather than full STOP, depending on severity:

- `issue_tracker.type` invalid → STOP (it's the most consequential field)
- `i18n.locale_files[k]` missing → WARN, gate will check what exists
- `ui_gate.login_script` missing → WARN, skip login step
- `specialists.X` empty array → WARN, fall back to inline review

The principle: "the user explicitly added this section, so they want it. If it's broken, tell them — don't silently ignore."
