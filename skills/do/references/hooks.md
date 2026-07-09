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

All three hook scripts are **self-locating** (resolve siblings via `$0`) and **degrade gracefully** (missing `jq`/wrapper → silent allow). They never block on uncertainty — only on a positive detection of the failure mode.

### `do-metrics-stop-gate.sh` — Stop hook (primary)

The **harness-enforced backstop** for Phase 4.11 metrics emission — a backstop, not a guarantee: it is opt-in and verifies the announce against the log file, nothing stronger (the tier table's "Defeated by" column applies). On every `Stop`, the runtime runs it; it:

1. **Self-scopes**: no-op unless the last assistant message carries the /do final-announce signature (`Complete. Branch:` or `Models: orchestrator=`). Normal Q&A, other skills, non-/do turns → never touched. *This is why it is safe to register globally.* A message carrying **unexpanded §4.13 placeholders** (`$EXPECTED`, `${METRICS_LINE}`, …) is quoting/editing the spec (docs work on the skill itself), not announcing a finalize → also no-op. This is deliberately narrower than a cwd-based self-repo guard, which would disable the backstop for genuine /do runs on this repo.
2. On a /do finalize turn, **blocks the stop** (`{"decision":"block","reason":...}`) when:
   - there is **no `Metrics:` line** (prose announce was composed instead of running the §4.13 bash flow), OR
   - the `Metrics:` line matches **none of the closed set of legal forms** — `Metrics: <N> entries in <path> (pre=<p> gates=<g>)` (the tell suffix is optional for pre-tell installs), `Metrics: APPEND FAILED — …`, `Metrics: not configured …`. A hand-composed variant like `Metrics: skipped — <reason>` is a positive §19a detection, not uncertainty — no bash path emits it, OR
   - the entries claim is **not backed by the file** — the path doesn't exist, the file has fewer than `N` lines (deliberately `<`, not `≠`: a concurrent session may legitimately push the count above `N`), or the carried tell is internally inconsistent (`pre`+1 ≠ `N`; the wrapper guarantees post = pre+1). This promotes the wrapper's pre/post line-count tell to a runtime-enforced check, OR
   - the log is **stale** — the last JSONL entry's `ref` doesn't appear in the announce AND the file wasn't written in the last 30 minutes. Catches the cheapest bypass: claiming the log's existing `wc -l` as `<N>` with zero appends this turn.
3. Valid terminal states (`Metrics: not configured`, `Metrics: APPEND FAILED — …`) are **not** re-blocked — the failure is already surfaced.
4. `stop_hook_active` loop-guard: if it already blocked this turn, it allows the stop (Claude Code also hard-overrides Stop hooks after 8 consecutive blocks).

> **Lockstep invariant.** The hook's parsers understand exactly the announce forms the §4.13 bash flow emits. Change `phase-4-finalize.md` §4.13's `METRICS_LINE` format and `do-metrics-stop-gate.sh` **together** — drift either false-blocks every legitimate run or silently disables verification. After changing either, re-install so the deployed copies match.

Covers anti-patterns [§19 / §19a](anti-patterns.md) at the runtime level.

### `do-plan-size-pretooluse.sh` — PreToolUse hook on `Task` (secondary)

Surfaces the Phase 2.0 plan-size verdict when the implementer sub-agent is spawned, so the size gate can't be silently skipped. **Non-blocking by design** — it injects the verdict as `additionalContext`, never denies (a parse miss must not break a legit `Task` spawn). It acts only when the spawn prompt carries the marker the Phase 2 spec emits:

```
PLAN-SIZE: files=<N> lines=<M> complexity=<T|L|M|H>
```

No marker (an `Explore` / `code-review` / any non-/do `Task`) → allow, no-op. With the marker it runs `plan-size-check` and injects the PASS / REBUMP / SPLIT-REQUIRED line into the model's context (impossible to not-see), reinforcing anti-pattern [§19d](anti-patterns.md). The injected verdict carries the wrapper's derived `[tell:<head8>:<ck>]` suffix and is passed through verbatim — the hook's tell may differ from the orchestrator's §2.0 run (different cwd → different HEAD), which is fine: each is independently recomputable, no consumer compares them. Resolution of REBUMP/SPLIT-REQUIRED stays the orchestrator's job per [`phase-2-implementation.md`](phase-2-implementation.md) §2.0.

### `do-secret-scan-pretooluse.sh` — PreToolUse hook on `Bash` (the irreversible-skip backstop)

Re-checks the Phase 4.1.2 pre-push secret gate at the runtime level. Tier 2 (the `secret-scan` wrapper gating the push inside the §4.1.2 bash block) is model-dependent — a push issued outside the gated block runs no scan. This hook closes that gap for the one skip that cannot be recovered (a pushed secret is revoke-and-rotate, not revert): every Bash command performing a `git push` gets the same range scan first.

- **Self-scoping**: no-op on any Bash command that is not a `git push` (`git stash push` excluded). Deliberately NOT /do-specific — unlike the other two hooks it also guards pushes outside /do runs, because the no-secrets rule ([`git-rules.md`](git-rules.md) §Secret guard) is unconditional and the failure irreversible. Non-push work is never touched.
- **Blocks ONLY on a confirmed match**: `secret-scan` exit 3 → hook exits 2 with the finding list (paths + pattern names, never the secret text) fed back to the model. Everything else — missing `jq`/wrapper, unresolvable repo dir, wrapper REJECT or crash — **fails open** (allow): a backstop must never break legitimate pushes on uncertainty.
- **On PASS** it injects the wrapper's verdict line (with its range-SHA tell) as `additionalContext`, so a /do finalize gets the genuine `gates.secret_scan` tell even at the runtime level.
- Repo dir for the scan: `git -C <dir> push` → `<dir>`; otherwise the tool call's `cwd`. An unexpandable `"$VARIABLE"` path falls back to `cwd`; worst case the fallback scans the wrong repo and yields an empty-range PASS — degraded to no-op, never a false block.

Covers anti-pattern [§19g](anti-patterns.md) at the runtime level.

## Enabling the hooks (opt-in)

The hooks are **not** installed by `install.sh` unless you opt in (it prompts, default No), and they are **never** force-merged into your settings. To enable manually, merge [`settings.with-hooks.json`](../hooks/settings.with-hooks.json) into your Claude Code settings:

- **User scope** (all projects): merge into `~/.claude/settings.json`
- **Project scope** (this repo only): merge into `<project>/.claude/settings.json`
- **Local/un-committed**: `<project>/.claude/settings.local.json`

The shipped example uses `$HOME/.claude/skills/do/hooks/...` (default skill name). If you installed under a custom skill name, change `do` to your name. The most robust form is a fully-resolved absolute path (what `install.sh` writes when you opt in). This caveat applies to hook **registration only** — the spec's wrapper invocations are not affected by the skill name or install method: every wrapper block self-resolves the scripts dir via the canonical do-scripts resolver (plugin root → `~/.claude/skills/<any name>/scripts` → plugin cache → default clone dir; see `phase-0-setup.md` Step 1), and the hook scripts locate their siblings via `$0`. After editing settings, run `/hooks` in Claude Code to confirm registration. Hooks from multiple scopes **compose** (they don't override); for permission decisions the most restrictive wins.

> **Scope caveat.** Claude Code hooks are **global to the session** once registered (a plugin/skill cannot scope a hook to "only when this skill runs" except via transient skill-frontmatter hooks). That is precisely why `do-metrics-stop-gate.sh` self-scopes on the /do announce signature, `do-plan-size-pretooluse.sh` on the `PLAN-SIZE:` marker, and `do-secret-scan-pretooluse.sh` on `git push` commands — so enabling them globally does not disturb unrelated work. (The secret-scan hook intentionally also guards non-/do pushes; see its section above.)

## Graceful degradation

Without hooks the skill behaves exactly as it does today — tiers 1+2 only. The hooks add a runtime safety net for the three must-happen checks (metrics emission, plan-size verdict, pre-push secret scan); they do not change any Phase 0–4 behavior. Removing the `hooks` block from settings fully disables them. The hook scripts themselves are inert unless the Claude Code runtime invokes them on the corresponding event.

## Disabling / uninstalling

`uninstall.sh` reverses the install-time merge (Step 2.5): it strips the `Stop`/`PreToolUse` entries whose command ends in `do-metrics-stop-gate.sh` / `do-plan-size-pretooluse.sh` / `do-secret-scan-pretooluse.sh` from `~/.claude/settings.json` — matched by basename, so custom skill names and manual `settings.with-hooks.json` merges are covered — with a timestamped `.bak` of the file kept and everything else untouched. This step is load-bearing: the uninstall removes the symlink the hook commands resolve through, so stranded entries would error on **every** Stop, Task spawn, and Bash call in every project, with nothing attributing the failure to this skill. Requires `jq`; if absent (or the file is not valid JSON) the entries are left in place and the script prints manual removal instructions — delete the three entries yourself, then run `/hooks` in Claude Code to confirm they're gone. To disable without uninstalling, remove the same entries by hand (hooks stay opt-in either way).
