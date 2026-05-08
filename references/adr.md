# Architecture Decision Records (ADR)

For High-complexity tasks (or per `config.adr.min_complexity`), generate an ADR after plan approval (Phase 2 Step 2). The ADR captures **why** an architectural choice was made — not what was built (the code does that). ADRs are immutable history; new decisions supersede old ones rather than rewriting them.

## When generated
- `config.adr.dir` is set
- Task complexity ≥ `config.adr.min_complexity` (default: `"high"` — only High triggers; can lower to `"medium"`)
- The plan involves an architectural choice (new dependency, new pattern, new service boundary, technology selection, breaking deviation from existing convention)

A purely-implementation High task (e.g. "implement spec X exactly as designed") doesn't need an ADR. Sonnet judges this in Step 2 and reports back; Opus confirms.

## Numbering

`config.adr.dir` lists existing ADRs as `NNNN-title.md`. Next number = max existing + 1, zero-padded to 4 digits (`0001`, `0002`, ..., `0042`). If no ADRs exist yet, start at `0001`.

Filename: `config.adr.filename_format` (default `{NNNN}-{slug}.md`) where `{slug}` is the kebab-case task title.

## Template

If `config.adr.template_path` is set → use that. Otherwise the default template:

```markdown
# ADR-{NNNN}: {Title}

- **Status**: Accepted
- **Date**: {YYYY-MM-DD}
- **Issue**: {tracker.repo}#{N}
- **Deciders**: {primary author + reviewers from CODEOWNERS / specialists}

## Context

{What problem are we solving? What forces are at play (technical, business, organizational)? What constraints? Reference any prior ADRs being superseded.}

## Decision

{What we are doing. Be specific — name technologies, patterns, file paths. Future readers should be able to identify the decision in the codebase.}

## Consequences

### Positive
- {what improves}

### Negative
- {what we're trading off — operational complexity, learning curve, vendor lock-in, etc.}

### Neutral
- {changes that are neither good nor bad but worth noting}

## Alternatives Considered

### {Alternative 1}
{Why rejected. Be specific — "X is slower" → "X benchmarked at 200ms vs Y's 40ms for our P50 case".}

### {Alternative 2}
{Same.}

## Implementation Notes

- Migration path: {how existing code/data moves to new design}
- Rollback: {can we undo this? at what cost?}
- Observability: {what metrics/logs prove this is working?}

## References

- Related ADR: ADR-{N} (if any)
- External: {RFC, blog post, paper, vendor doc URLs}
```

## Status lifecycle

- **Proposed** — under specialist review (Phase 2 Step 2)
- **Accepted** — approved by specialists / Opus, ready to implement
- **Superseded by ADR-NNNN** — replaced by a later ADR; never delete the old one
- **Deprecated** — abandoned without replacement (rare; document why)

When an ADR supersedes another, the new ADR's "References" cites the old one, and Phase 2 also updates the old ADR's status with a back-reference.

## Generation flow (Phase 2)

For High tasks where Step 2 plan review APPROVES:

1. Sonnet detects "is this an architectural decision?" — if yes, drafts the ADR alongside the plan
2. Specialists review the ADR draft as part of plan review
3. On full approval:
   - Compute `NNNN` = max existing + 1
   - Write `{config.adr.dir}/{NNNN}-{slug}.md`
   - Stage in worktree (`git add`)
   - Reference in issue comment: `### Approved Plan / ADR-{NNNN}`
4. ADR commits with the implementation in Phase 4 (same PR)

## Discovery for future tasks

Future tasks in Phase 0 should:
- `ls {config.adr.dir}/*.md` — list existing ADRs
- If task scope overlaps with an existing ADR's domain, include that ADR's "Decision" section in Sonnet's context (so they don't violate it without consciously superseding it)

This is light-touch: just a directory listing and conditional inclusion. Don't preload all ADRs.

## Sources

The ADR pattern follows Michael Nygard's original 2011 post and the modernized templates from [adr.github.io](https://adr.github.io). The template above is a pragmatic synthesis — adjust per project conventions.

## Anti-patterns

- **ADRs without "Alternatives Considered"** — a rationale that doesn't say what was rejected is just a description
- **ADRs that say "we chose X because it's better"** — better at what? for whom? under which workload? always be specific
- **Editing accepted ADRs** — if a decision changes, write a new ADR that supersedes it; preserve the original reasoning
- **One ADR per file change** — ADRs are for cross-cutting decisions, not per-PR notes (use commit messages and PR descriptions for those)
- **Generating ADRs for trivial choices** — "we used `time.Now()` instead of `time.UTC()`" doesn't need an ADR. Reserve ADRs for choices that future engineers will reasonably ask "why did we do it this way?"
