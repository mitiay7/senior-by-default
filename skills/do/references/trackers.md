# Issue Tracker Integration

The skill abstracts issue tracker operations to support GitHub, GitLab, custom CLIs, or no tracker at all. Tracker behavior is controlled by `config.issue_tracker.type` plus optional `commands` overrides.

## Built-in tracker types

### `github` (default)
Uses `gh` CLI. Just set `repo`:
```json
"issue_tracker": {
  "type": "github",
  "repo": "owner/name"
}
```

Default commands:
| Op | Command |
|---|---|
| list_open  | `gh issue list --repo {repo} --state open --limit 20` |
| create     | `gh issue create --repo {repo} --title "{title}" --body-file {body_file} --label "{labels}"` |
| view_body  | `gh issue view {N} --repo {repo} --json body -q .body` |
| edit_body  | `gh issue edit {N} --repo {repo} --body-file {body_file}` |
| comment    | `gh issue comment {N} --repo {repo} --body-file {body_file}` |
| view_url   | `gh issue view {N} --repo {repo} --json url -q .url` |
| close_keyword | `Closes` |

PR creation uses `gh pr create --repo {code_repo}`.

### `gitlab`
Uses `glab` CLI. Set `repo` to `owner/project` or numeric project ID:
```json
"issue_tracker": {
  "type": "gitlab",
  "repo": "owner/project"
}
```

Default commands:
| Op | Command |
|---|---|
| list_open  | `glab issue list -R {repo} --opened --per-page 20` |
| create     | `glab issue create -R {repo} --title "{title}" --description-file {body_file} --label "{labels}"` |
| view_body  | `glab issue view {N} -R {repo} --output json | jq -r .description` |
| edit_body  | `glab issue update {N} -R {repo} --description-file {body_file}` |
| comment    | `glab issue note {N} -R {repo} --message-file {body_file}` |
| view_url   | `glab issue view {N} -R {repo} --output json | jq -r .web_url` |
| close_keyword | `Closes` |

MR (PR equivalent) creation uses `glab mr create -R {code_repo}`.

### `none`
Phase 1 entirely skipped. No `Closes #N` in PRs. No `Ref:` in commits. Sonnet runs from inline task description (Low-task format).

```json
"issue_tracker": { "type": "none" }
```

### `custom`
For Linear, Jira, Trello, internal trackers, etc. — provide the `commands` block with templates.

```json
"issue_tracker": {
  "type": "custom",
  "repo": "team-id-or-project-key",
  "commands": {
    "list_open": "linear issue list --team {repo} --state open",
    "create":    "linear issue create --team {repo} --title \"{title}\" --description-file {body_file}",
    "view_body": "linear issue view {N} --json | jq -r .description",
    "edit_body": "linear issue update {N} --description-file {body_file}",
    "comment":   "linear comment create --issue {N} --body-file {body_file}",
    "view_url":  "linear issue view {N} --json | jq -r .url",
    "close_keyword": "Fixes"
  }
}
```

All seven keys recommended (six commands + close_keyword). Missing keys → that operation is skipped (e.g., no `comment` template → no completion comment posted; warn user).

## Per-command override
Any tracker type accepts `commands` overrides. Useful for:
- Adding labels to default `gh` calls (`--assignee @me`, custom `--milestone`)
- Switching to `--json` output for parsing
- Wrapping commands with `script.sh`

Override only what differs; built-in defaults fill the rest.

## Placeholders

| Placeholder | Meaning |
|---|---|
| `{repo}` | Value from `config.issue_tracker.repo` |
| `{N}` | Issue number / ID (substituted at call time) |
| `{title}` | Issue title (Phase 1 derives from `$ARGUMENTS`) |
| `{body_file}` | Path to a temp file containing the body — skill writes body to a temp file then substitutes the path. Avoids shell-escaping multi-line content. |
| `{labels}` | Comma-separated label list for create. Empty string if no labels. |
| `{state}` | For list/filter ops: `open` / `closed` / `all` |

## Issue number extraction

When parsing the response of `create`:
- GitHub `gh`: returns the issue URL on stdout. Extract trailing integer.
- GitLab `glab`: same — URL on stdout, extract trailing integer.
- Custom: tracker-dependent. Document expected output format in your `create` template OR pipe through `jq` / `awk` to extract the ID.

## PR / MR creation

PRs are tracker-coupled but generally:
- GitHub: `gh pr create --repo {code_repo} --base main --head {branch}`
- GitLab: `glab mr create -R {code_repo} --target-branch main --source-branch {branch}`
- Linear / Jira / etc: PR usually lives on GitHub/GitLab/Bitbucket and is linked back to the tracker via `Fixes ABC-123` keyword in PR description.

So PR creation always uses the **code-hosting** CLI (gh/glab), not the tracker CLI. The tracker just provides the issue id and the `close_keyword` for the PR description.

## Cross-repo issues

If issues live in a separate repo from code (e.g. code in `api`/`web`, issues in `docs`):

PR description uses `Refs {tracker.repo}#{N}` instead of `Closes #N` (cross-repo Closes doesn't work in GitHub).

Pattern: same-repo → `{close_keyword} #{N}`. Cross-repo → `Refs {tracker.repo}#{N}`.

## Future: MCP-based trackers

For trackers exposed via MCP (e.g. Linear MCP, Jira MCP), the skill currently treats them as `type: "custom"`. Direct MCP integration (calling `mcp__linear__*` tools) is out of scope for this version — would require detecting available MCPs and routing operations through them instead of shell commands. PRs welcome.
