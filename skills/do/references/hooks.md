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

All five hook scripts are **self-locating** (resolve siblings via `$0`) and **degrade gracefully** (missing `jq`/wrapper → silent allow). Four of them never block on uncertainty — only on a positive detection of the failure mode; the fifth (`do-tokens-stop-amend.sh`) **never blocks at all** — it only enriches an already-written entry. Every registration + payload path below is exercised by [`hook-live-sim.sh`](../hooks/hook-live-sim.sh) (see §Verified 2026-07-09), which MUST pass before any release touching `hooks/`, the §4.13 announce format, or `install.sh`'s hook merge.

### `do-metrics-stop-gate.sh` — Stop hook (primary)

The **harness-enforced backstop** for Phase 4.11 metrics emission — a backstop, not a guarantee: it is opt-in and verifies the announce against the log file, nothing stronger (the tier table's "Defeated by" column applies). On every `Stop`, the runtime runs it; it:

1. **Self-scopes**: no-op unless the last assistant message carries the /do final-announce signature (`Complete. Branch:` or `Models: orchestrator=`). Normal Q&A, other skills, non-/do turns → never touched. *This is why it is safe to register globally.* A message carrying **unexpanded §4.13 placeholders** (`$BRANCH_NAME`, `${METRICS_LINE}`, …) is quoting/editing the spec (docs work on the skill itself), not announcing a finalize → also no-op. This is deliberately narrower than a cwd-based self-repo guard, which would disable the backstop for genuine /do runs on this repo.
2. On a /do finalize turn, **blocks the stop** (`{"decision":"block","reason":...}`) when:
   - there is **no `Metrics:` line** (prose announce was composed instead of running the §4.13 bash flow), OR
   - the `Metrics:` line matches **none of the closed set of legal forms** — `Metrics: <N> entries in <path> (pre=<p> gates=<g>)` (the tell suffix is optional for pre-tell installs), `Metrics: APPEND FAILED — …`, `Metrics: not configured …`. A hand-composed variant like `Metrics: skipped — <reason>` is a positive §19a detection, not uncertainty — no bash path emits it, OR
   - the entries claim is **not backed by the file** — the path doesn't exist, the file has fewer than `N` lines (deliberately `<`, not `≠`: a concurrent session may legitimately push the count above `N`), or the carried tell is internally inconsistent (`pre`+1 > `N`; the wrapper guarantees post ≥ pre+1 — since audit #18 its delta is informational under the log lock, so `N` above pre+1 is tolerated as concurrent growth, while `N` at or below `pre` is the stale-`wc -l` hand-composition signature). This promotes the wrapper's pre/post line-count tell to a runtime-enforced check, OR
   - the log is **stale** — the last JSONL entry's `ref` doesn't appear in the announce AND the file wasn't written in the last 30 minutes. Catches the cheapest bypass: claiming the log's existing `wc -l` as `<N>` with zero appends this turn.
3. Valid terminal states (`Metrics: not configured`, `Metrics: APPEND FAILED — …`) are **not** re-blocked — the failure is already surfaced.
4. `stop_hook_active` loop-guard: if it already blocked this turn, it allows the stop (Claude Code also hard-overrides Stop hooks after 8 consecutive blocks).

> **Lockstep invariant.** The hook's parsers understand exactly the announce forms the §4.13 bash flow emits. Change `phase-4-finalize.md` §4.13's `METRICS_LINE` format and `do-metrics-stop-gate.sh` **together** — drift either false-blocks every legitimate run or silently disables verification. After changing either, re-install so the deployed copies match.

Covers anti-patterns [§19 / §19a](anti-patterns.md) at the runtime level.

### `do-tokens-stop-amend.sh` — Stop hook (token-usage enrichment)

Closes the token-accounting loop v0.10.0 opened. `metrics-append --tokens-in/--tokens-out` can record per-run usage, but **no in-session actor can read its own usage** (`/cost` is TUI-only; a sub-agent can't observe its own usage; headless JSON usage lands after the session ends). The only actor the runtime ever hands harness-recorded usage is a **hook**: a Stop hook receives `transcript_path`, and the transcript's assistant records carry `message.usage`. This hook sums those and amends the run's telemetry entry with a `tokens` object — the honest, measured figure the estimate ban (`--tokens-*` "harness-reported only") demands. Adoption before it existed: **0 of 27 post-v0.10.0 entries** carried a `tokens` object; the field was structurally unfillable, not merely neglected.

1. **Self-scopes** on the /do final-announce signature — `Complete. Branch:`, `Models: orchestrator=`, **or `Metrics:`** — plus a no-op on a spec-quoting turn (unexpanded §4.13 placeholders) and the `stop_hook_active` loop-guard. Safe to register globally. The `Metrics:` alternative is v0.13.0 and is the load-bearing one: the other two are *prose* lines, and prose gets localized. v0.12.0 shipped this hook, the next `/do` run happened to be conducted in Russian, and the entry landed with **no `tokens` field and no error** — one shipped feature, one opportunity to fire, zero output. `Metrics:` is a machine line (literal key, count, filesystem path) and survives a translated announce. Widening the trigger costs nothing in scoping because the real scope check is structural, not textual (step 3): the message must name a ref that is on the resolved log and still lacks `tokens`. The durable fix lives in the spec — [`phase-4-finalize.md`](phase-4-finalize.md) §"The announce is a protocol, not prose" mandates the block be emitted verbatim in English regardless of session language.
2. Parses the log `<path>` out of the closed-set `Metrics:` line; terminal states (`not configured`, `APPEND FAILED`) → no-op.
3. **Finds the target entry by ref, not by position**: the last log entry whose `.ref` appears in the announce text AND that has no `tokens` key yet. Ref-match is what makes it correct under concurrent same-log sessions; none found → no-op.
4. Sums usage from the transcript within `[started_at − 120s, ended_at + 900s]` (both read from the entry): `in = Σ(input + cache_creation + cache_read)`, `out = Σ output` over every assistant record carrying `message.usage` (sub-agent/sidechain records in the transcript are included by construction). Both bounds unusable → whole-transcript sum (a /do run is one task per session). All-zero sum → no-op (never writes a misleading `{in:0,out:0}`).
5. Calls `metrics-append --amend-tokens --log <path> --ref <ref> --tokens-in N --tokens-out M`. **Idempotent**: the wrapper REJECTs a second amend on an entry that already has `tokens`, and the hook swallows the result — a re-fired Stop is clean.

> **Never blocks.** Unlike the metrics *gate*, this hook emits no decision object; every failure path is a silent `exit 0`. Telemetry enrichment must not wedge a Stop.

> **Diagnosing silence: `DO_TOKENS_DEBUG=1`.** Because every path is a silent `exit 0`, a hook that is registered, executable, and simply never *matching* is indistinguishable from one that correctly had nothing to do — which is exactly the state v0.12.0 shipped in, with eight guards and no way to tell which one dropped the turn. Set `DO_TOKENS_DEBUG=1` in the environment and each no-op prints its reason to stderr (`[do-tokens-stop-amend] no-op: message carries no /do finalize signature …`), plus the ref/log/sums on the success path and whatever `metrics-append` replied. It changes nothing else — same exits, same writes.

The wrapper's `--amend-tokens` mode runs the whole read-modify-write under the same `mkdir` log lock as append, rewrites atomically (same-dir temp + `mv`), verifies the amended line changed **only** the `tokens` key, and refuses to overwrite an existing one. Regression-tested end-to-end in [`tests/tokens-stop-amend.test.sh`](../../../tests/tokens-stop-amend.test.sh) (23 assertions: happy path, refuse-overwrite, one-flag-alone, last-ref-wins, estimate-ban rejects, and the hook summing real synthetic-transcript usage into the ref-matched entry, idempotent re-fire, self-scope no-ops, concurrent-session ref selection, never-blocks).

> **Lockstep invariant.** Its announce parser shares the closed-set `Metrics:` grammar with `do-metrics-stop-gate.sh` — change §4.13's format and update **both** Stop hooks together.

### `do-plan-size-pretooluse.sh` — PreToolUse hook on `Task` (secondary)

Surfaces the Phase 2.0 plan-size verdict when the implementer sub-agent is spawned, so the size gate can't be silently skipped. **Non-blocking by design** — it injects the verdict as `additionalContext`, never denies (a parse miss must not break a legit `Task` spawn). It acts only when the spawn prompt carries the marker the Phase 2 spec emits:

```
PLAN-SIZE: files=<N> lines=<M> complexity=<T|L|M|H>
```

No marker (an `Explore` / `code-review` / any non-/do `Task`) → allow, no-op. With the marker it runs `plan-size-check` and injects the PASS / REBUMP / SPLIT-REQUIRED line into the model's context (impossible to not-see), reinforcing anti-pattern [§19d](anti-patterns.md). The injected verdict carries the wrapper's derived `[tell:<head8>:<ck>]` suffix and is passed through verbatim — the hook's tell may differ from the orchestrator's §2.0 run (different cwd → different HEAD), which is fine: each is independently recomputable, no consumer compares them. Resolution of REBUMP/SPLIT-REQUIRED stays the orchestrator's job per [`phase-2-implementation.md`](phase-2-implementation.md) §2.0.

### `do-secret-scan-pretooluse.sh` — PreToolUse hook on `Bash` (the irreversible-skip backstop)

Re-checks the Phase 4.1.2 pre-push secret gate at the runtime level. Tier 2 (the `secret-scan` wrapper gating the push inside the §4.1.2 bash block) is model-dependent — a push issued outside the gated block runs no scan. This hook closes that gap for the one skip that cannot be recovered (a pushed secret is revoke-and-rotate, not revert): every Bash command performing a `git push` gets the same range scan first.

- **Self-scoping**: no-op on any Bash command that is not a `git push` (`git stash push` excluded). Deliberately NOT /do-specific — unlike the metrics and plan-size hooks it also guards pushes outside /do runs, because the no-secrets rule ([`git-rules.md`](git-rules.md) §Secret guard) is unconditional and the failure irreversible. Non-push work is never touched.
- **Blocks ONLY on a confirmed match**: `secret-scan` exit 3 → hook exits 2 with the finding list (paths + pattern names, never the secret text) fed back to the model. Everything else — missing `jq`/wrapper, unresolvable repo dir, wrapper REJECT or crash — **fails open** (allow): a backstop must never break legitimate pushes on uncertainty.
- **On PASS** it injects the wrapper's verdict line (with its range-SHA tell) as `additionalContext`, so a /do finalize gets the genuine `gates.secret_scan` tell even at the runtime level.
- **Repo dir for the scan**, in order: `git -C <dir> push` → `<dir>`; else a `cd <dir>` / `pushd <dir>` earlier in the SAME command (the shape a push from a worktree actually takes — the pr-size hook has resolved `cd` prefixes since v0.13.0, and this one did not); else the tool call's `cwd`. An unexpandable `"$VARIABLE"` path falls through to the next step.
- **An empty range is never treated as clean** (lea-docs#1463). When the resolved directory holds no commits ahead of `origin/main`, the wrapper answers INCONCLUSIVE (exit 4) and the hook then scans **every worktree of that repository** that is ahead of `origin/main`, unioning the verdicts: one BLOCK blocks. If nothing anywhere has commits to scan, the push is still allowed — a backstop must not break pushes — but the injected context says `NOT SCANNED` in as many words and explicitly refuses to be used as `gates.secret_scan` evidence.
  The old behaviour called this case harmless: *"worst case the fallback scans the wrong repo and yields an empty-range PASS — degraded to no-op, never a false block."* Half true. There was no false block, but the no-op **printed PASS**, and §4.1.2 instructs the model to file that line as proof the gate ran. Reproduced live on 2026-08-13: a commit carrying a password assignment was allowed while the hook reported `range f1c451e..f1c451e clean (0 commits, 0 files)`. Absence of a check filed as evidence of one is strictly worse than a missing gate.
- Every verdict line now carries `[dir: <path>]`, so a scan of the wrong checkout is visible in the transcript instead of reading exactly like a successful one.

Covers anti-pattern [§19g](anti-patterns.md) at the runtime level.

### `do-pr-size-pretooluse.sh` — PreToolUse hook on `Bash` (the PR-creation backstop)

Re-checks the Phase 3.0 PR-size gate at the runtime level — §19f's Tier-3 leg. Tier 2 (the `pr-size-check` wrapper inside the §3.0 bash block) is model-dependent: a PR created without running §3.0 gets no gate, which is exactly how 8 production PRs >2000 lines shipped as `warn`. This hook re-computes the verdict from the repo's **real diff** before every Bash command that creates a PR/MR (`gh pr create` / `glab mr create`).

- **Self-scoping**: no-op on any Bash command that is not a PR/MR creation. Like the secret-scan hook it is deliberately NOT /do-specific — an unreviewable 4000-line PR is a problem in any session.
- **Compatible with the default auto-split path (v0.11.0)**: §3.0 BLOCK normally routes to §4.2.1 auto-split, which opens a stack whose per-part PR diff (base = the previous part branch) is each sub-cap — so those non-draft creations hit this hook's PASS/WARN arm and pass. The hook needs no split-awareness; it just never fires on the parts.
- **Draft escape hatch (load-bearing)**: §3.0's `--no-split`/opt-out BLOCK remediation is "push current state as a DRAFT PR + `blocked` label" — so a `--draft` creation is ALWAYS allowed. On a BLOCK verdict a draft gets the verdict injected as `additionalContext` (keep it draft, apply the label, file split sub-issues) instead of a deny. Blocking drafts would deadlock the sanctioned escape path.
- **Denies ONLY a confirmed over-block-cap non-draft creation**: `pr-size-check` exit 3 → hook exits 2 with the verdict + the sanctioned paths (auto-split, or `--no-split` draft) fed back to the model — this only ever fires on a genuine SINGLE over-block PR, which auto-split never produces. Everything else — missing `jq`/wrapper, non-repo dir, unresolvable base ref, wrapper REJECT or crash — **fails open** (allow).
- **On PASS/WARN** it injects the wrapper's verdict line as `additionalContext`, so a /do finalize gets a genuine `gates.pr_size` verdict even when §3.0 was skipped (WARN reminds to add the PR-size note to the description).
- Inputs are derived, never trusted: repo dir = leading `cd <dir> &&` in the command (unexpandable `$VAR` falls through) else the call's `cwd`; base = `--base`/`-B` (gh) / `--target-branch`/`-b` (glab); head = `--head`/`-H` / `--source-branch`/`-s`.
- **The hook does not measure anything itself.** It passes `--repo <dir>` plus the refs the command named to `pr-size-check`, and the wrapper does the ref resolution (origin/`<ref>` first, then `<ref>`; no base ⇒ `origin/HEAD` → origin/main → origin/master → main → master; unresolvable head ⇒ HEAD), the `--numstat` churn, the `<repo>/.claude/do/config.json` read — thresholds **and** `pr_size.generated_paths` exclusion — and the verdict. Before lea-docs#1399 the hook re-implemented the counting and read exactly four config keys, which meant any new config field could only take effect in one of the two tiers: gate says WARN, hook says BLOCK on the same diff. One implementation, one verdict ([lea-docs#1399](https://github.com/mitiay7/lea-docs/issues/1399)). A wrapper `REJECT` (exit 1 — unusable repo, no resolvable base) is a fail-open here, same as before.
- **It passes no `--tier`, on purpose (v0.13.0).** §3.0 hands the wrapper the run's complexity tier so the WARN cap equals the budget the plan was approved against; a PreToolUse hook sees only a shell command and cannot know the tier. That is safe precisely because the only thing this hook enforces is BLOCK, and block caps are deliberately tier-independent — so the two callers can differ on advisory WARN *text* and never on an enforced verdict. The wrapper stamps `[warn caps: …]` on its line so a reader can always see which budget produced a given verdict.

Covers anti-pattern [§19f / §21](anti-patterns.md) at the runtime level.

## Enabling the hooks (opt-in)

The hooks are **not** installed by `install.sh` unless you opt in (it prompts, default No), and they are **never** force-merged into your settings. To enable manually, merge [`settings.with-hooks.json`](../hooks/settings.with-hooks.json) into your Claude Code settings:

- **User scope** (all projects): merge into `~/.claude/settings.json`
- **Project scope** (this repo only): merge into `<project>/.claude/settings.json`
- **Local/un-committed**: `<project>/.claude/settings.local.json`

The shipped example uses `$HOME/.claude/skills/do/hooks/...` (default skill name). If you installed under a custom skill name, change `do` to your name. The most robust form is a fully-resolved absolute path (what `install.sh` writes when you opt in). This caveat applies to hook **registration only** — the spec's wrapper invocations are not affected by the skill name or install method: every wrapper block self-resolves the scripts dir via the canonical do-scripts resolver (plugin root → `~/.claude/skills/<any name>/scripts` → plugin cache → default clone dir; see `phase-0-setup.md` Step 1), and the hook scripts locate their siblings via `$0`. After editing settings, run `/hooks` in Claude Code to confirm registration. Hooks from multiple scopes **compose** (they don't override); for permission decisions the most restrictive wins.

> **Scope caveat.** Claude Code hooks are **global to the session** once registered (a plugin/skill cannot scope a hook to "only when this skill runs" except via transient skill-frontmatter hooks). That is precisely why `do-metrics-stop-gate.sh` and `do-tokens-stop-amend.sh` self-scope on the /do announce signature, `do-plan-size-pretooluse.sh` on the `PLAN-SIZE:` marker, `do-secret-scan-pretooluse.sh` on `git push` commands, and `do-pr-size-pretooluse.sh` on `gh pr create` / `glab mr create` commands — so enabling them globally does not disturb unrelated work. (The secret-scan and pr-size hooks intentionally also guard non-/do pushes/PRs; see their sections above.)

## Graceful degradation

Without hooks the skill behaves exactly as it does today — tiers 1+2 only. The hooks add a runtime safety net for the four must-happen checks (metrics emission, plan-size verdict, pre-push secret scan, PR-size ceiling) plus one enrichment (token-usage recording); they do not change any Phase 0–4 behavior. Removing the `hooks` block from settings fully disables them. The hook scripts themselves are inert unless the Claude Code runtime invokes them on the corresponding event.

## Disabling / uninstalling

`uninstall.sh` reverses the install-time merge (Step 2.5): it strips the `Stop`/`PreToolUse` entries whose command ends in `do-metrics-stop-gate.sh` / `do-tokens-stop-amend.sh` / `do-plan-size-pretooluse.sh` / `do-secret-scan-pretooluse.sh` / `do-pr-size-pretooluse.sh` from `~/.claude/settings.json` — matched by basename, so custom skill names and manual `settings.with-hooks.json` merges are covered — with a timestamped `.bak` of the file kept and everything else untouched. This step is load-bearing: the uninstall removes the symlink the hook commands resolve through, so stranded entries would error on **every** Stop, Task spawn, and Bash call in every project, with nothing attributing the failure to this skill. Requires `jq`; if absent (or the file is not valid JSON) the entries are left in place and the script prints manual removal instructions — delete the five entries yourself, then run `/hooks` in Claude Code to confirm they're gone. To disable without uninstalling, remove the same entries by hand (hooks stay opt-in either way).

## Verified 2026-07-09 — live registration + harness-simulated payloads

v0.8.0 shipped the hooks validated with mock stdin only; the payload field names were assumptions. This section records what was actually verified (audit finding #16) and pins the ground truth the parsers rely on. The runnable form of everything below is [`hook-live-sim.sh`](../hooks/hook-live-sim.sh) — **40 cases, run green on macOS/BSD and debian/GNU (re-run 2026-08-16)** (the 38th, M4b, pins the audit-#18 tell tolerance: `N > pre+1` = concurrent growth, allowed) — which is a release gate for any change to `hooks/`, the §4.13 announce format, or `install.sh`'s hook merge (CONTRIBUTING §Test checklist).

**Registration (verified end-to-end, sandboxed).** The real `install.sh` run with `ENABLE_HOOKS=Y` against a scratch `$HOME` produces exactly the hooks.md-documented shape in `~/.claude/settings.json` — `Stop` ×2 (`do-metrics-stop-gate.sh`, `do-tokens-stop-amend.sh`), `PreToolUse` matcher `Task` ×1 (`do-plan-size-pretooluse.sh`), `PreToolUse` matcher `Bash` ×2 (`do-secret-scan-pretooluse.sh`, `do-pr-size-pretooluse.sh`) — each `command` a fully-resolved absolute path through the `~/.claude/skills/<name>` symlink, each executable, each self-locating its sibling `scripts/` through that symlink. The merge is idempotent (re-run adds nothing) and `uninstall.sh` strips all five entries by basename. After enabling on a real machine, run `/hooks` in Claude Code to confirm the runtime picked them up — that display is the one step no simulation can substitute.

**Payload shapes (cross-checked against the Claude Code hooks reference + hooks-guide at code.claude.com/docs, 2026-07-09).** The harness passes ONE JSON object on stdin per event:

```json
// PreToolUse (matcher Task / Bash) — common envelope + tool fields
{
  "session_id": "…", "prompt_id": "…",
  "transcript_path": "~/.claude/projects/<slug>/<session>.jsonl",
  "cwd": "/path/of/the/tool/call", "permission_mode": "default",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",                          // or "Task"
  "tool_input": { "command": "…", "description": "…" }   // Task: { "prompt": …, "description": …, "subagent_type": … }
}
// Stop — common envelope + final-text + loop guard
{
  "session_id": "…", "prompt_id": "…", "transcript_path": "…",
  "cwd": "…", "permission_mode": "default", "hook_event_name": "Stop",
  "last_assistant_message": "…",   // documented: THE field for the turn's final assistant text
  "stop_hook_active": false        // documented (hooks-guide): true once the hook already blocked this turn
}
```

Both fields the metrics gate depends on are **documented, not assumed**: the reference explicitly directs Stop hooks to `last_assistant_message` for the final text, and the hooks-guide documents `stop_hook_active` as the loop guard (plus the runtime's own 8-consecutive-blocks override). The gate's transcript fallback (for runtimes that omit `last_assistant_message`) was verified against a **real local transcript**: entries are `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":…}]}}` per line, which is exactly the shape the fallback `jq` parses — and the live-sim's M12 case proves the fallback still blocks with the field absent. Exit contract verified as documented: PreToolUse exit 2 = deny with stderr fed to the model; exit 0 + `hookSpecificOutput.permissionDecision/additionalContext` = allow with injected context; Stop `{"decision":"block","reason":…}` on stdout = turn continues with the reason.

**What the matrix proves per hook** (see the sim's case names): the metrics gate blocks a finalize missing the `Metrics:` line, any hand-composed/off-set form, a tell with `pre+1 > N` (`N > pre+1` is tolerated concurrent growth since audit #18), a nonexistent/short/stale log — and allows the compliant `(pre=<p> gates=<g>)` announce, both terminal states, non-/do turns, placeholder quotes, and the `stop_hook_active` re-entry. The plan-size hook injects tell-intact PASS/REBUMP/SPLIT-REQUIRED verdicts for marked spawns and no-ops otherwise (non-blocking by design — `permissionDecision` is always `allow`). The secret-scan hook denies a push whose range carries a committed-then-deleted secret and passes clean ranges with the tell injected. The pr-size hook denies a non-draft `gh pr create`/`glab mr create` over the block cap, always allows `--draft` (with the BLOCK verdict injected), injects PASS/WARN verdicts, honors `config.pr_size.*` overrides, resolves `cd <dir> &&` prefixes, and fails open without a resolvable base.

**Residual honesty.** The simulation feeds documented payloads to the registered commands; it does not run a live Claude Code session end-to-end (the desktop-VM `claude` binary is not host-executable). If a future runtime renames an envelope field, the graceful-degradation design means the hooks no-op rather than break — re-run the live-sim and re-check `/hooks` + one real `/do` finalize after any Claude Code major upgrade.
