# Contributing

Welcome. The skill works for me — that doesn't mean it works for you. Bug reports and PRs are very useful.

## Reporting bugs

Open a GitHub issue with:

1. **What you ran** — the `/do` command verbatim
2. **What happened** — exact final announce text from the skill (the `Complete. Branch: ... Metrics: ...` line)
3. **What you expected**
4. **Your config** — sanitize personal paths/repo names, paste relevant section of `.claude/do/config.json`
5. **Your stack cache** — `cat ~/.claude/do/cache/<your-slug>.json`
6. **Claude Code version** — `claude --version`

Especially valuable: if the final announce was missing the `Metrics:` line — that means the skill silently skipped Phase 4.11, which is a bug.

If you have metrics enabled (`config.metrics.tier: 1`), grep your JSONL for the relevant entry and include it. The `gates.<name>.details` blocks tell us exactly what failed.

## Pull requests

Small / focused PRs are easier to review than rewrites. Touch one phase per PR if possible.

For non-trivial changes:

- Add an ADR in `docs/adr/` (if architectural decision)
- Update relevant `skills/do/references/*.md` files
- Update `skills/do/references/config.schema.json` if config shape changes
- Bump version in `CHANGELOG.md` and SKILL.md frontmatter
- Add a sanitized example to `examples/` if you're introducing a new config field

The skill is **opinionated**. Some PRs will be declined for fit reasons — not quality. If unsure, open an issue first to discuss direction.

### Acceptance criteria for PRs

- [ ] CI green (lint workflow runs shellcheck + JSON schema validation + frontmatter check + markdown-link sanity)
- [ ] If config shape changed: `config.schema.json` updated AND all `examples/*.json` re-validate
- [ ] If reference content changed: linked from `SKILL.md` references table OR there's a clear progressive-disclosure trigger
- [ ] No personal paths/usernames/repo names committed (run `grep -rn "yourname\|/Users/yourname" skills/ examples/` before push)
- [ ] CHANGELOG entry under `[Unreleased]`

### Versioning (SemVer)

Applied to `version` in `.claude-plugin/plugin.json` AND `SKILL.md` frontmatter (kept in sync):

- **Major** (`X.0.0`) — Breaking change to existing user configs OR phase-flow contract. Examples: required field added to existing config block; renamed gate; removed override flag; changed metrics JSONL schema in incompatible way.
- **Minor** (`0.X.0`) — New optional config fields, new opt-in features, new gates that don't run unless configured. Existing configs continue to work unchanged.
- **Patch** (`0.0.X`) — Bug fixes, doc improvements, prompt tweaks. No config or output changes.

**Rule of thumb for "breaking"**: if a user with a working `.claude/do/config.json` would see different behavior after upgrade without editing config, that's at least minor; if they'd see an *error*, that's major.

### Reference docs vs prompt logic

`skills/do/references/*.md` are **read by Opus during phases**. Changes here change behavior. Treat them like code:

- Adding a step → minor version bump
- Renaming a phase or removing an instruction → major version bump
- Tightening wording, fixing typos → patch
- Adding examples without changing rules → patch

Don't treat references as "just docs". They're prompt material that gates real work.

### Test checklist before PR

There's no automated functional test suite — the skill runs through Claude. Smoke-test manually:

1. Run a real `/do` task on a sandbox repo. Verify:
   - Final announce includes `Metrics: <count> entries in <path>` (if metrics configured)
   - Branch name matches `config.naming` template (no `claude/<adj>-<noun>`)
   - Phase you changed actually fires the new behavior
2. If your change touches stack detection, test with at least 2 stacks (e.g. pure Go + JS monorepo).
3. If your change touches a gate, force a failure case + a pass case to verify both paths.
4. Inspect last metrics entry: `tail -1 ~/.claude/do/metrics/<repo-slug>.jsonl | jq` — does it have the data you expected? Then run `skills/do/scripts/metrics-report --repo <repo-slug>` — your entry must aggregate cleanly (no malformed-line WARN, not listed under SCHEMA BYPASS). If your change touches the metrics schema or `metrics-append`, also run the report against a crafted log covering every enum value plus one malformed line + one field-incomplete entry: the malformed line must be skipped with a WARN (never fatal), the incomplete entry must land in SCHEMA BYPASS, and an empty log must produce the helpful "no entries yet" message.
5. Check: did anything regress? Re-run a previously-working task type.
6. If your change touches `scripts/` or `hooks/`, run the touched script once on GNU/Linux too — BSD (macOS) and GNU coreutils disagree on flags (`date -j -u -f` vs `date -u -d` burned metrics emission on every Linux host once already). Docker one-liner from the repo root:

   ```bash
   docker run --rm -v "$PWD":/w -w /w debian:stable-slim bash -c \
     'apt-get -qq update && apt-get -qq install -y jq >/dev/null && bash -n skills/do/scripts/* && <your invocation here>'
   ```
7. **RELEASE GATE — hook live-sim must pass** (both platforms) if your change touches `hooks/`, the §4.13 announce format, `install.sh`'s hook merge, or `uninstall.sh`'s hook removal. The v0.8.0 hooks shipped validated with mock stdin only and had never been live-registered — a wrong payload-field assumption would have made the tier-3 backstop silently no-op forever (audit finding #16). Never again:

   ```bash
   ./skills/do/hooks/hook-live-sim.sh   # macOS/BSD — 39 cases, sandboxed (never touches your real ~/.claude)
   docker run --rm -v "$PWD":/w -w /w debian:stable-slim bash -c \
     'apt-get -qq update && apt-get -qq install -y jq git python3 >/dev/null 2>&1 && ./skills/do/hooks/hook-live-sim.sh'
   ```

   It registers the hooks through the real `install.sh` into a sandbox HOME and drives every allow/block/inject path with documented Stop/PreToolUse payloads (shapes recorded in `references/hooks.md` §Verified 2026-07-09). If you changed the announce format, update the sim's fixtures and BOTH Stop hooks TOGETHER (lockstep invariant).

   The token-amend hook has its own end-to-end suite — run it too if you touch `do-tokens-stop-amend.sh` or `metrics-append`'s `--amend-tokens` mode:

   ```bash
   bash tests/tokens-stop-amend.test.sh   # 23 assertions, synthetic logs + transcripts, sandboxed
   ```

   The PR-size gate has its own suite — run it if you touch `pr-size-check`, `do-pr-size-pretooluse.sh`, or the §3.0 block. It runs **both** enforcement tiers on one fixture and fails on any verdict split, which is the failure mode that made a hook-only or wrapper-only path-exclusion field unimplementable in the first place:

   ```bash
   bash tests/pr-size-generated-paths.test.sh   # 24 assertions, synthetic repos, sandboxed
   ```

   The pre-push secret gate has its own suite — run it if you touch `secret-scan`, `do-secret-scan-pretooluse.sh`, or §4.1.2. It asserts what the gate does when it is pointed at the WRONG directory, which is the state that let a secret through on 2026-08-13 (lea-docs#1463):

   ```bash
   bash tests/secret-scan-worktree-scope.test.sh   # 21 assertions, synthetic repos, sandboxed
   ```

## Adding a new tracker

To support a new issue tracker beyond GitHub/GitLab:

1. Add command templates to `references/trackers.md`
2. Document the new `type` value in `references/config-schema.md`
3. Add an example config in `examples/` (placeholder repo names, no personal data)

PR welcome especially for: Linear, Jira, Bitbucket, self-hosted Gitea/Forgejo.

## Testing changes

Reality: there's no automated test suite for the skill itself — it runs through Claude. Smoke-test by running a real task on a sandbox repo:

```bash
mkdir /tmp/skill-smoke && cd /tmp/skill-smoke && git init && git commit --allow-empty -m "init"
mkdir -p .claude/do && cp ~/.claude/skills/do/examples/minimal-config.json .claude/do/config.json
# edit config to disable issue_tracker (set type: none), then in Claude Code:
/do add a README with project name and description
```

If your change touches Phase 0 (stack detection / config validation), test with at least 2 stacks (pure Go, pure JS, monorepo).

## Code of conduct

Don't be a dick. Don't gatekeep "real engineering" — the whole point of this skill is people who ship outpace people who lecture. If you can't help without sneering about hierarchy, this isn't the project for you.

## License

By contributing, you agree your contributions are licensed under MIT (see [LICENSE](LICENSE)).
