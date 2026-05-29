# Hook-based enforcement (OPT-IN, harness-level)

The skill has three enforcement tiers, each catching a failure mode the previous one couldn't. Hooks are the **strongest** tier — but they are **opt-in** and ship disabled. The skill works fully without them (it degrades to the wrapper tier).

## The three tiers

| Tier | Mechanism | Runs | Catches | Defeated by |
|---|---|---|---|---|
| 1. Soft instruction | "MANDATORY" prose in the spec | the model, if it chooses | nothing reliably | the model deciding it's ceremony |
| 2. Structural-coupling wrapper | `scripts/*` own the decision + literal strings + an anti-fabrication tell; the spec only invokes + dispatches | the model, when it runs the wrapper | fabricated/skipped output **when the wrapper is actually invoked** (announce can't be composed without it; tells expose off-line copies) | the model never invoking the wrapper at all |
| 3. **Harness hook** | Claude Code runtime runs a script on `Stop` / `PreToolUse`, independent of the model | the **runtime**, every time, unconditionally | the model skipping the wrapper entirely — the runtime re-checks and can BLOCK | being disabled (opt-in) or a runtime without the hook event |

Tier 2 is the skill's default and was the entire v0.6/v0.7 thesis (`metrics-append`, `plan-size-check`, `pr-size-check`, `check-caveman`, `config-init`, `config-ensure-metrics`). Empirically it lifted plan-size rebump tracking 0%→18% and drives the user-visible announce tokens. But it is still **model-dependent**: if the orchestrator never calls the wrapper, tier 2 can't fire. Tier 3 closes that gap for the checks that MUST happen every task — at the cost of being a global runtime config the user opts into.

## What ships (in `skills/do/hooks/`)

Both hook scripts are **self-locating** (resolve siblings via `$0`) and **degrade gracefully** (missing `jq`/wrapper → silent allow). They never block on uncertainty — only on a positive detection of the failure mode.

### `do-metrics-stop-gate.sh` — Stop hook (primary)

Makes Phase 4.11 metrics emission **non-bypassable**. On every `Stop`, the runtime runs it; it:

1. **Self-scopes**: no-op unless the last assistant message carries the /do final-announce signature (`Complete. Branch:` or `Models: orchestrator=`). Normal Q&A, other skills, non-/do turns → never touched. *This is why it is safe to register globally.*
2. On a /do finalize turn, **blocks the stop** (`{"decision":"block","reason":...}`) when:
   - there is **no `Metrics:` line** (prose announce was composed instead of running the §4.13 bash flow), OR
   - the `Metrics: <N> entries in <path>` line is **not backed by the file** — the path doesn't exist, or the file has fewer than `N` lines (fabricated or silently-failed append). This promotes the wrapper's pre/post line-count tell to a runtime-enforced check.
3. Valid terminal states (`Metrics: not configured`, `Metrics: APPEND FAILED — …`) are **not** re-blocked — the failure is already surfaced.
4. `stop_hook_active` loop-guard: if it already blocked this turn, it allows the stop (Claude Code also hard-overrides Stop hooks after 8 consecutive blocks).

Covers anti-patterns [§19 / §19a](anti-patterns.md) at the runtime level.

### `do-plan-size-pretooluse.sh` — PreToolUse hook on `Task` (secondary)

Surfaces the Phase 2.0 plan-size verdict when the implementer sub-agent is spawned, so the size gate can't be silently skipped. **Non-blocking by design** — it injects the verdict as `additionalContext`, never denies (a parse miss must not break a legit `Task` spawn). It acts only when the spawn prompt carries the marker the Phase 2 spec emits:

```
PLAN-SIZE: files=<N> lines=<M> complexity=<T|L|M|H>
```

No marker (an `Explore` / `code-review` / any non-/do `Task`) → allow, no-op. With the marker it runs `plan-size-check` and injects the PASS / REBUMP / SPLIT-REQUIRED line into the model's context (impossible to not-see), reinforcing anti-pattern [§19d](anti-patterns.md). Resolution of REBUMP/SPLIT-REQUIRED stays the orchestrator's job per [`phase-2-implementation.md`](phase-2-implementation.md) §2.0.

## Enabling the hooks (opt-in)

The hooks are **not** installed by `install.sh` unless you opt in (it prompts, default No), and they are **never** force-merged into your settings. To enable manually, merge [`settings.with-hooks.json`](../hooks/settings.with-hooks.json) into your Claude Code settings:

- **User scope** (all projects): merge into `~/.claude/settings.json`
- **Project scope** (this repo only): merge into `<project>/.claude/settings.json`
- **Local/un-committed**: `<project>/.claude/settings.local.json`

The shipped example uses `$HOME/.claude/skills/do/hooks/...` (default skill name). If you installed under a custom skill name, change `do` to your name. The most robust form is a fully-resolved absolute path (what `install.sh` writes when you opt in). After editing settings, run `/hooks` in Claude Code to confirm registration. Hooks from multiple scopes **compose** (they don't override); for permission decisions the most restrictive wins.

> **Scope caveat.** Claude Code hooks are **global to the session** once registered (a plugin/skill cannot scope a hook to "only when this skill runs" except via transient skill-frontmatter hooks). That is precisely why `do-metrics-stop-gate.sh` self-scopes on the /do announce signature and `do-plan-size-pretooluse.sh` self-scopes on the `PLAN-SIZE:` marker — so enabling them globally does not disturb non-/do work.

## Graceful degradation

Without hooks the skill behaves exactly as it does today — tiers 1+2 only. The hooks add a runtime safety net for the two must-happen checks (metrics emission, plan-size verdict); they do not change any Phase 0–4 behavior. Removing the `hooks` block from settings fully disables them. The hook scripts themselves are inert unless the Claude Code runtime invokes them on the corresponding event.
