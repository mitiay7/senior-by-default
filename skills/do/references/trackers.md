# Issue Tracker Integration

The skill abstracts issue tracker operations to support GitHub, GitLab, custom CLIs, or no tracker at all. Tracker behavior is controlled by `config.issue_tracker.type` plus optional `commands` overrides.

## ⚠ Security: argv-safe execution is MANDATORY

User-controlled input (`$ARGUMENTS` → `{title}`) is interpolated into tracker commands. **Tracker commands MUST be executed with argv-safe semantics** — interpolating user content into a shell string is a shell-injection vulnerability.

### The vulnerability

Naive shell-template form (HISTORICAL — do NOT use):
```
gh issue create --repo {repo} --title "{title}" --body-file {body_file} --label "{labels}"
```

If a user runs `/do x" --milestone 5 --label injected "y` (an unusual but valid title), naive substitution produces:
```
gh issue create --repo foo/bar --title "x" --milestone 5 --label injected "y" --body-file /tmp/...
```
gh sees `title=x`, `milestone=5`, `label=injected`. The `--milestone` and `--label` flags were **smuggled in by the title**. Same vulnerability applies to `{labels}` (config-controlled but still string-substituted) and `{repo}` (less likely but possible if user types are misconfigured).

### The fix — pass user content via env vars or argv positions

The execution layer (Bash tool invoked by Opus) MUST pass `{title}` and other user-controlled values through bash variables (double-quoted), not through string-substituted shell templates.

**Built-in `github` invocation (argv-safe pattern):**
```bash
TITLE='<verbatim title from $ARGUMENTS — no shell parsing happens here>'
LABELS='session,refactoring'
BODY_FILE='/tmp/do-issue-body.XXXX'
REPO='owner/repo'

gh issue create --repo "$REPO" --title "$TITLE" --body-file "$BODY_FILE" --label "$LABELS"
```
Critically, `$TITLE` is set as an **environment variable**, not interpolated into the command string. Bash never re-parses its content. A malicious title `x" --milestone 5 --label injected "y` becomes one literal `--title` argument value, not extra flags.

When invoking the Bash tool, build the command with literal `$TITLE` references (not template substitution); set the variable in the same shell invocation:
```python
# pseudocode for Opus calling Bash tool
Bash(command=f"""
TITLE={shell_single_quote(title)}
LABELS={shell_single_quote(labels)}
BODY_FILE={shell_single_quote(body_file)}
REPO={shell_single_quote(repo)}
gh issue create --repo "$REPO" --title "$TITLE" --body-file "$BODY_FILE" --label "$LABELS"
""")
```

`shell_single_quote()` wraps in `'...'` and escapes any embedded `'` — this is the only string-level escaping needed (and it's restricted to assignment, not the gh argv).

For Python: `shlex.quote(s)`. For shell: `printf '%q' "$VAR"`.

### Custom trackers — argv array form (preferred)

For `type: "custom"`, prefer the **argv array form** in config — substitution happens after argv split, so values can't smuggle flags:

```json
"commands": {
  "create": ["linear", "issue", "create", "--team", "{repo}", "--title", "{title}", "--description-file", "{body_file}"]
}
```

Each `{...}` placeholder occupies one argv slot. The skill substitutes the literal value (no shell parse) into that slot. Even `--milestone 5 --label injected` as a title stays a single string in `argv[6]`.

### Why the string form CANNOT carry user content (and is schema-rejected for it)

A naive instinct is to allow `"create": "linear ... --title \"{title}\" ..."` as long as the skill `shlex.quote`'s placeholders before substitution. **This is unsafe and the schema rejects it.** Reproducible exploit:

- Template: `--title "{title}"`  (placeholder already inside `"..."`)
- Title from `$ARGUMENTS`: `x" --milestone 5 --label injected "y`
- After `shlex.quote`: `'x" --milestone 5 --label injected "y'`  (single-quoted whole string)
- Naive substitution: `--title "'x" --milestone 5 --label injected "y'"`
- Shell parses → `--title 'x · --milestone · 5 · --label · injected · y'` (six argv elements; injection succeeded)

The `"` inside the title content closes the template's surrounding `"..."` regardless of what we wrap *outside* the substitution. There is no `shlex.quote`-style fix — the only safe form is argv-array, where placeholders aren't shell-parsed at all.

`config.schema.json` enforces this: any string form for `commands.<op>` containing literal `{title}` or `{labels}` fails validation. To carry user content, the command MUST be an argv array.

---

## Built-in tracker types

### `github` (default)
Uses `gh` CLI. Just set `repo`:
```json
"issue_tracker": {
  "type": "github",
  "repo": "owner/name"
}
```

Argv-safe invocations (execute with values passed via env vars per "argv-safe execution" above):

| Op | Argv |
|---|---|
| list_open  | `gh issue list --repo "$REPO" --state open --limit 20` |
| create     | `gh issue create --repo "$REPO" --title "$TITLE" --body-file "$BODY_FILE" --label "$LABELS"` |
| view_body  | `gh issue view "$N" --repo "$REPO" --json body -q .body` |
| edit_body  | `gh issue edit "$N" --repo "$REPO" --body-file "$BODY_FILE"` |
| comment    | `gh issue comment "$N" --repo "$REPO" --body-file "$BODY_FILE"` |
| view_url   | `gh issue view "$N" --repo "$REPO" --json url -q .url` |
| close_keyword | `Closes` (literal, not a command) |

PR creation uses `gh pr create --repo "$CODE_REPO" --base main --head "$BRANCH"`.

### `gitlab`
Uses `glab` CLI. Set `repo` to `owner/project` or numeric project ID:
```json
"issue_tracker": {
  "type": "gitlab",
  "repo": "owner/project"
}
```

Argv-safe invocations:

| Op | Argv |
|---|---|
| list_open  | `glab issue list -R "$REPO" --opened --per-page 20` |
| create     | `glab issue create -R "$REPO" --title "$TITLE" --description-file "$BODY_FILE" --label "$LABELS"` |
| view_body  | `glab issue view "$N" -R "$REPO" --output json | jq -r .description` |
| edit_body  | `glab issue update "$N" -R "$REPO" --description-file "$BODY_FILE"` |
| comment    | `glab issue note "$N" -R "$REPO" --message-file "$BODY_FILE"` |
| view_url   | `glab issue view "$N" -R "$REPO" --output json | jq -r .web_url` |
| close_keyword | `Closes` (literal) |

MR (PR equivalent) creation uses `glab mr create -R "$CODE_REPO" --target-branch main --source-branch "$BRANCH"`.

The `| jq` pipe is safe because `jq` reads stdin; no user input goes through the shell pipe boundary.

### `none`
Phase 1 entirely skipped — with an explicit `[Phase 1] SKIPPED — tracker: none` announce (see [`phase-1-issue.md`](phase-1-issue.md); never silent). No `Closes #N` in PRs. No `Ref:` in commits. Sonnet runs from inline task description (Low-task format).

```json
"issue_tracker": { "type": "none" }
```

**DEGRADED none** — Phase 0 auto-init writes `type: "none"` itself when the remote points at github/gitlab but the CLI is missing or unauthenticated (`_meta.tracker_degraded_from` + `tracker_degraded_reason` record what was intended and why it degraded; `_setup_notes` carries the remedy). Runtime behavior is identical to plain none; the difference is observability — the Phase 0 announce carries the wrapper's `Tracker: DEGRADED to none (…)` line and the Phase 1 skip announce repeats the reason. Restore by installing/authenticating the CLI, then setting `issue_tracker` back per `_setup_notes`.

### `custom`
For Linear, Jira, Trello, internal trackers, etc. — provide the `commands` block.

**Preferred (argv array form, argv-safe):**
```json
"issue_tracker": {
  "type": "custom",
  "repo": "team-id-or-project-key",
  "commands": {
    "list_open": ["linear", "issue", "list", "--team", "{repo}", "--state", "open"],
    "create":    ["linear", "issue", "create", "--team", "{repo}", "--title", "{title}", "--description-file", "{body_file}"],
    "view_body": ["sh", "-c", "linear issue view \"$1\" --json | jq -r .description", "_", "{N}"],
    "edit_body": ["linear", "issue", "update", "{N}", "--description-file", "{body_file}"],
    "comment":   ["linear", "comment", "create", "--issue", "{N}", "--body-file", "{body_file}"],
    "view_url":  ["sh", "-c", "linear issue view \"$1\" --json | jq -r .url", "_", "{N}"],
    "close_keyword": "Fixes"
  }
}
```

Each placeholder occupies a dedicated argv element; substitution happens **after** argv parsing, so values cannot inject flags. For commands needing pipes (`linear ... | jq ...`), wrap as `["sh", "-c", "...", "_", "{N}"]` and reference `$1` in the inline script — the substituted `{N}` becomes `$1`, never reaches the parent shell parser.

**String form (back-compat, restricted):**

Allowed ONLY for commands that don't carry user-controlled content — i.e., **must NOT contain `{title}` or `{labels}`**. JSON Schema rejects strings containing those placeholders. Examples that ARE acceptable:

```json
"commands": {
  "view_body": "linear issue view {N} --json | jq -r .description",
  "view_url":  "linear issue view {N} --json | jq -r .url"
}
```

(`{N}` is parsed from tracker output, `{repo}` is config-controlled — neither carries `$ARGUMENTS` content.)

For `create` (always carries `{title}`) and any command that uses `{labels}` — argv array form is **mandatory**. See "Why the string form CANNOT carry user content" above for the exploit and the schema rule.

When the skill detects a string-form command containing `{title}`/`{labels}`: validation fails fast with a security explanation, and the user is directed to migrate that command to argv-array form.

All seven keys recommended (six commands + `close_keyword`). Missing keys → that operation is skipped (e.g., no `comment` template → no completion comment posted; warn user).

**Line-1 execute callout on custom trackers.** Issue bodies are tracker-agnostic except line 1: the execute callout (see [`phase-1-issue.md`](phase-1-issue.md) §Execute callout) stays the literal first line on every tracker. If the tracker doesn't render markdown blockquotes/backticks, adapt the syntax but keep the semantics — one visually-distinct first line containing the literal `+++` invocation, with the tracker's native issue ref (e.g. `ENG-123`) or the issue URL after `+++`.

## Per-command override
Any tracker type accepts `commands` overrides. Useful for:
- Adding labels to default `gh` calls (`--assignee @me`, custom `--milestone`)
- Switching to `--json` output for parsing
- Wrapping commands with `script.sh`

Override using the argv array form:
```json
"commands": {
  "create": ["gh", "issue", "create", "--repo", "{repo}", "--title", "{title}", "--body-file", "{body_file}", "--label", "{labels}", "--assignee", "@me", "--milestone", "v0.2"]
}
```

Override only what differs; built-in defaults fill the rest.

## Placeholders

| Placeholder | Meaning | User-controlled? |
|---|---|---|
| `{repo}` | Value from `config.issue_tracker.repo` | No (config) |
| `{N}` | Issue number / ID (substituted at call time) | Indirectly (parsed from tracker output) |
| `{title}` | Issue title (Phase 1 derives from `$ARGUMENTS`) | **YES — main injection vector** |
| `{body_file}` | Path to a temp file containing the body. Skill writes body to a temp file then substitutes the path. Inherently safe — body content never crosses shell. | No (skill-controlled path) |
| `{labels}` | Comma-separated label list for create. Empty string if no labels. | Indirectly (config + matched extensions) |
| `{state}` | For list/filter ops: `open` / `closed` / `all` | No (skill-controlled enum) |

User-controlled placeholders (`{title}` always; `{labels}` if extensions match user input) MUST be passed via env vars or argv positions, never via string template substitution.

## Issue number extraction

When parsing the response of `create`:
- GitHub `gh`: returns the issue URL on stdout. Extract trailing integer.
- GitLab `glab`: same — URL on stdout, extract trailing integer.
- Custom: tracker-dependent. Document expected output format in your `create` argv OR pipe through `jq` / `awk` to extract the ID.

## PR / MR creation

PRs are tracker-coupled but generally:
- GitHub: `gh pr create --repo "$CODE_REPO" --base main --head "$BRANCH"`
- GitLab: `glab mr create -R "$CODE_REPO" --target-branch main --source-branch "$BRANCH"`
- Linear / Jira / etc: PR usually lives on GitHub/GitLab/Bitbucket and is linked back to the tracker via `Fixes ABC-123` keyword in PR description.

So PR creation always uses the **code-hosting** CLI (gh/glab), not the tracker CLI. The tracker just provides the issue id and the `close_keyword` for the PR description.

The same argv-safe rule applies to PR title/body — pass via env vars, never substitute into a shell string.

## Cross-repo issues

If issues live in a separate repo from code (e.g. code in `api`/`web`, issues in `docs`):

PR description uses `Refs {tracker.repo}#{N}` instead of `Closes #N` (cross-repo Closes doesn't work in GitHub).

Pattern: same-repo → `{close_keyword} #{N}`. Cross-repo → `Refs {tracker.repo}#{N}`.

## Future: MCP-based trackers

For trackers exposed via MCP (e.g. Linear MCP, Jira MCP), the skill currently treats them as `type: "custom"`. Direct MCP integration (calling `mcp__linear__*` tools) is out of scope for this version — would require detecting available MCPs and routing operations through them instead of shell commands. PRs welcome.

MCP-based execution is **inherently argv-safe** — MCP tools accept structured parameters, no shell parsing involved. Migrating to MCP for built-in trackers is on the roadmap.
