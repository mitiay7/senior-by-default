# Contributing

Welcome. The skill works for me — that doesn't mean it works for you. Bug reports and PRs are very useful.

## Reporting bugs

Open a GitHub issue with:

1. **What you ran** — the `+++` / `/do` command verbatim
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
- Update relevant `references/*.md` files
- Bump version in `CHANGELOG.md`
- Add a sanitized example to `examples/` if you're introducing a new config field

The skill is **opinionated**. Some PRs will be declined for fit reasons — not quality. If unsure, open an issue first to discuss direction.

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
