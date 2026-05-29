# Changelog

All notable changes to this skill will be documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) loosely; versioning follows [SemVer](https://semver.org/).

## [Unreleased]

## [0.8.0] — 2026-05-29

**Hook-based enforcement + cleanup.** v0.7.0 fixed the measurement instrument and added a PR-size ceiling; v0.8.0 closes the enforcement loop and tidies what the prior cycles accreted.

**Release-level summary:**

- **Tier-3 harness hooks (P3, opt-in).** The wrapper tier is strong but model-dependent — if the orchestrator never invokes a wrapper, it can't fire. Two opt-in Claude Code hooks add a runtime backstop the model can't skip: a **Stop hook** that blocks a `/do` finalize lacking a valid, file-backed `Metrics:` line (self-scopes to `/do` runs), and a **PreToolUse hook** that surfaces the plan-size verdict at spawn time. Off by default; ship as `skills/do/hooks/` + `references/hooks.md` + opt-in `install.sh` wiring. The skill is unchanged without them.
- **Gate investigation (P4).** The five "never-failing" gates are NOT theater — `0 fails` was a measurement artifact (Phase 3 loops until pass, records the resolved state). Counting `fix_cycle>0`, all fire (`opus_review` 16/125, `test` 5/130, `i18n` 5/104, …). All kept; the daily report gained a `Fired*` column so live gates stop looking dead.
- **§19 consolidation (P4).** The 7-entry §19 anti-pattern family (one root cause, much repetition) collapsed to one principle + a 6-row instance table (with a new tier-3-hook column). Legacy ids retained for cross-references.
- **Wrapper-lib: assessed, declined (P4).** The only duplication is trivial 1-liners + an 8-line block in 2 wrappers; self-containment is a documented design value and a sourced lib would add a failure mode on the Phase 0 critical path. Cargo-cult DRY, declined with rationale.

The three enforcement tiers are now explicit: soft instruction → structural-coupling wrapper (default) → opt-in harness hook. See [`references/hooks.md`](skills/do/references/hooks.md).

### Cleanup — gate investigation, §19 consolidation, wrapper-lib assessment (P4)

#### Dead-gate investigation → keep all five (measurement artifact, not theater)

The audit flagged five gates as never-failing (`opus_review`, `i18n`, `contract`, `test`, `migration_audit` — all `0 fails` across runs). Investigated before pruning: the `0 fails` is a **measurement artifact**, not theater. Phase 3 loops until pass and records the *terminal* (resolved) gate state, so a gate that fired and was fixed within the task shows `status: pass` with `fix_cycle > 0`. Counting `fix_cycle > 0` (the gate actually caught something), all five DO fire: **`opus_review` 16/125, `test` 5/130, `i18n` 5/104, `contract` 2/81, `migration_audit` 1/38**. None is removed — each is a safety gate with demonstrated catches; removing any would lose real defect detection. The spec-level justification to keep them is exactly this `fix_cycle` evidence.

- **`daily-report.sh`** (operator-side) — gate table gains a **`Fired*`** column = terminal fail/block/warn OR `fix_cycle > 0`, sorted by it. This is the honest "is this gate doing anything?" metric; the old fail-only view hid the resolved catches and made live gates look dead. (e.g. `specialist_audit` Fired 39, `pr_size` 36, `dep_vuln` 21, `opus_review` 16 — all previously showed Fail 0.)

#### §19 anti-pattern family consolidated

- **`anti-patterns.md`** — the sprawling §19 / §19a–§19f (7 entries, heavy repetition of the same root cause) collapsed into **one principle** ("the orchestrator skips inline spec-bash and fabricates output; every side-effect must be wrapper-owned with a tell") **+ a compact 6-row instance table** (id · side-effect→wrapper · anti-fabrication tell · bypass diagnostic · tier-3 hook). Legacy ids (19a–19f) are retained as table-row tags so existing `§19c`-style cross-references still resolve. The table adds a **Tier-3 hook** column noting which instances now have a runtime backstop (19a metrics → Stop hook; 19d/19f size → PreToolUse hook). No information lost; ~70 lines → a principle + table.

#### Wrapper boilerplate — assessed, extraction declined (intentional)

Reviewed the 6 wrappers (1036 LOC) for a shared `scripts/_wrapper-lib.sh`. Found the only duplication is trivial or localized: `die`/`iofail` are 1-line definitions (5/3 wrappers), and the lone substantial repeat is an 8-line schema-validate python block in exactly 2 wrappers (`config-init`, `config-ensure-metrics`). **Decision: do not extract.** Rationale — (1) the wrappers' **self-containment is a documented design value** (`plan-size-check`: "duplicated here ON PURPOSE so the wrapper is self-contained"); each is independently inspectable/copyable, which matters for an audit-sensitive tool; (2) a sourced lib adds a "lib not found / not sourced" failure mode to the Phase 0 critical path (`config-init`/`config-ensure-metrics`) to save ~30 lines; (3) the schema-validate is already best-effort (skips when `jsonschema` is absent). Extracting would be cargo-cult DRY against an explicit principle. SKILL.md top-level anti-pattern list + README reviewed for consistency with the consolidation (legacy §-references still resolve; no edits needed beyond the P0–P3 additions).

### Hook-based enforcement (tier 3, OPT-IN) (P3)

The wrapper tier (tier 2) is strong but model-dependent: if the orchestrator never invokes a wrapper, it can't fire (~18% compliance on the internal-only plan-size check, higher on user-visible ones). For the two checks that MUST happen every task, add **Claude Code hooks** — scripts the runtime executes itself, independent of the model. Opt-in and off by default; the skill degrades cleanly to tiers 1+2 without them.

#### Added

- **`skills/do/hooks/do-metrics-stop-gate.sh`** (NEW, Stop hook) — makes Phase 4.11 metrics emission non-bypassable at the runtime level. Self-scopes to `/do` runs (no-op unless the last assistant message carries the `Complete. Branch:` / `Models: orchestrator=` announce signature — safe to register globally). Blocks the stop (`{"decision":"block",...}`) when a `/do` finalize lacks a `Metrics:` line OR the `Metrics: <N> entries in <path>` claim isn't backed by the file (path missing, or `wc -l < path` < N) — promoting the wrapper's pre/post line-count tell to harness enforcement. `stop_hook_active` loop-guard; terminal states (`not configured`, `APPEND FAILED`) not re-blocked.
- **`skills/do/hooks/do-plan-size-pretooluse.sh`** (NEW, PreToolUse hook, matcher `Task`) — surfaces the Phase 2.0 plan-size verdict at implementer-spawn time. Non-blocking by design (injects `additionalContext`, never denies). Acts only on the `PLAN-SIZE: files=N lines=M complexity=C` marker the Phase 2 spawn prompt now emits; any other `Task` spawn → no-op. Self-locates `plan-size-check` via `$0`.
- **`skills/do/hooks/settings.with-hooks.json`** (NEW) — the opt-in settings fragment to merge into `~/.claude/settings.json` or a project `.claude/settings.json`.
- **`references/hooks.md`** (NEW) — documents the three enforcement tiers (soft instruction → structural-coupling wrapper → harness hook), which checks each covers, the two shipped hooks, install instructions, and the global-scope caveat (why both hooks self-scope).

#### Changed

- **`install.sh`** — new opt-in Step 6.5 (default **No**): merges the hooks into `~/.claude/settings.json` idempotently (checks for the exact command before adding, backs up first, validates JSON, refuses on un-parseable existing settings). Never a mandatory mutation; respects the `ENABLE_HOOKS` env for non-interactive installs.
- **`phase-2-implementation.md`** — Sonnet-spawn prompt Flags section emits the `PLAN-SIZE:` marker; §2.0 documents the optional PreToolUse backstop.
- **`SKILL.md`** progressive-disclosure table + **README** gain a hooks section / doc-map entry. **`.github/workflows/lint.yml`** json-syntax step now also validates `settings.with-hooks.json` (kept out of the `examples/*.json` schema-validation glob — it's a settings file, not a do-config).

#### Tested

Both hook scripts validated with mock stdin across all branches (Stop: non-/do no-op, valid/missing/file-missing/count-mismatch/not-configured/loop-guard; PreToolUse: PASS/REBUMP/SPLIT-REQUIRED injection + no-marker no-op). The settings merge tested for idempotency + key-preservation + invalid-JSON refusal. Hooks were NOT registered into the live session (a Stop hook there would gate the session itself) — runtime registration is documented for the user to enable.

## [0.7.0] — 2026-05-29

**Measurement integrity + a PR-size ceiling that actually blocks.** This cycle acts on a 225-entry audit (May 14–24, since extended to 254 live entries). Two of the three big findings were that the metrics *instrument itself* was lying — the `gates` vocabulary had drifted to ~110 names for ~19 real gates, and the single `calibration` field conflated "missed a real defect" with "didn't predict diff size" (39% of "false positives" were pure `pr_size=warn` noise). The third was the real defect: tasks were too big and the size ceiling was never enforced — 8 PRs added >2000 lines and every one shipped as `pr_size=warn` despite `block_lines=2000`.

**Release-level summary** (detail in the entries below + the post-v0.6.0 follow-ups folded in from the prior `[Unreleased]`):

- **Controlled vocabulary for `gates` (P1).** `metrics-append` normalizes gate keys (alias map → 19 canonical names) + statuses (→ `pass|warn|fail|block|skipped`), coerces scalar values, merges collisions by severity, and **preserves** (never rejects) unknown task-specific keys with a `noncanon=` tell. Measured on 254 live entries: 60 raw synonym buckets → 19 canonical + a few one-offs.
- **Split calibration (P2).** New `calibration_defect` (real code defect missed — the de-confounded primary signal) + `calibration_size` (diff-size prediction) dimensions alongside the back-compat `calibration`. Flags default to `n_a`; the orchestrator computes both per the §4.11 logic.
- **PR-size ceiling that blocks (P0).** `plan-size-check` H bucket got a real ceiling (25 files / 1500 lines) so `SPLIT-REQUIRED` fires instead of being dead code. New `pr-size-check` wrapper owns the Phase 3.0 PASS/WARN/BLOCK decision; **BLOCK exits 3** (hard halt → draft PR + `blocked`), so the orchestrator can no longer downgrade block to warn.
- **Same structural-coupling invariant throughout.** Every new check is a wrapper that owns the decision + the literal strings + an anti-fabrication tell (gate rename counts, computed split counts, breach/overage lists); the spec only invokes + dispatches.

### Metrics — controlled vocabulary for `gates` keys + statuses (P1)

Audit of 225 canonical entries (May 14–24) found the `gates` JSON had **~110 distinct keys for ~19 real gates** — `test`/`tests`/`test_gate`/`go_test`, `ui`/`ui_gate`/`visual_verify`/`visual_smoke`, `i18n`/`i18n_gate`, `contract`/`contract_gate`, `dep_vuln`/`dep_vuln_go`/`dep_vuln_pnpm`, `type_check`/`type-check`/`lint_typecheck` — plus equally-drifty statuses (`skip`/`n/a`/`n-a`/`na`/`n_a`, scalar `pass`/`true`/`ok`/`clean`). Same data-quality class as the v0.6.0 `outcome`-enum drift: every synonym splits one gate's stats across buckets, so the daily-report gate-failure-rate was noise. `outcome` got a controlled vocabulary in v0.6.0; `gates` had none until now.

#### Changed

- **`metrics-append` — gate-vocabulary normalization** (jq step before the entry is built). Defines a 19-name canonical set (`build`, `lint`, `type_check`, `test`, `dep_vuln`, `pr_size`, `i18n`, `contract`, `ui_gate`, `migration_audit`, `specialist_audit`, `opus_review`, `public_docs`, `secret_scan`, `diff_scan`, `plan_size`, `codeowners`, `stale_main`, `concurrent_edit`) + a ~70-entry alias map. Known aliases are renamed to canonical; scalar gate values (`"pass"`, `true`) are coerced to `{status: …}`; statuses normalize to `pass|warn|fail|block|skipped` (with `skip`/`n/a`/`na` → `skipped`, prefix-matching for `skipped_no_ui`-style suffixed statuses). Key collisions after aliasing (e.g. `test` + `go_test`) merge by max severity (block>fail>warn>pass>skipped).
- **Policy: warn-normalize, not hard-reject.** Gate keys are an OPEN set (legitimate task-specific checks like `idempotency_cache_correct` exist), unlike the closed `outcome`/`complexity` enums. Unknown keys are **preserved verbatim** (entry NOT rejected — rejecting on the announce-coupled critical path would tempt the orchestrator to drop real gate signal or fabricate) but counted + surfaced. The closed enums stay hard-reject.
- **Anti-fabrication tell extended.** The OK line now ends `gates=<C> renamed=<R> noncanon=<list|->` — the orchestrator can't reproduce the rename count / non-canonical list without running the wrapper against the actual `--gates-json`. Non-canonical keys + statuses also print a `NOTE gate-normalize:` line to stderr. The `post=` sed-extraction in §4.13 is unaffected (verified).
- **`phase-4-finalize.md` §4.11** — new "Gate vocabulary (controlled, OPEN set)" subsection with the canonical table (key → phase) + alias/normalization rules. **`config-schema.md`** — JSONL example `ui`→`ui_gate`; controlled-vocabulary note added (+ the specialist-install confounder warning). **`phase-3-review.md`** — metrics-capture intro points to the canonical list. **`anti-patterns.md` §19e (NEW)** — gate-name fabrication documented as the same class as outcome-enum drift.
- **`daily-report.sh`** (operator-side, not shipped) — gate-failure-rate now buckets by canonical name (mirrors the wrapper alias map), so the 254 historical entries aggregate correctly (60 raw synonym buckets → ~19 canonical + a few task-specific one-offs). Also hardened: input parsing tolerates malformed JSONL lines (`fromjson?` instead of a fragile `jq -s` slurp that crashed on one corrupt line), and the `VALID_JSON`/bypass filters no longer crash when `self_review` is a non-object (2 such entries existed).

#### Measured impact (254 live entries)

- Gate buckets in the daily report: **60 → 19 canonical + ~8 task-specific one-offs**. `test` consolidated to 1 fail / 106 pass (was scattered across `test`/`tests`/`test_gate`/`go_test`/`go_test_race`/`unit_tests`/…), `specialist_audit` to 2/54, `dep_vuln` to 0/64, `pr_size` to 0/144.
- Confirms P4's "never-fails" gate candidates with clean data: `opus_review` 0/124, `i18n` 0/76, `contract` 0/39, `migration_audit` 0/19.

### Metrics — split self-review calibration into defect vs size (P2)

The single `self_review.calibration` field conflated two unrelated failures: *Sonnet missed a real code defect* and *Sonnet didn't predict diff size*. Audit of 254 live entries: of **44 `false_positive` entries, 17 (39%) fired ONLY `pr_size=warn`** — the code was fine, the diff was just big. Counting those as "self-review missed something" inflates the FP rate and misleads skill iteration (you'd tighten the self-review prompt when the actual problem is routing/size).

#### Added

- **`metrics-append` — `--sr-calibration-defect` + `--sr-calibration-size` flags** (enum `accurate|false_positive|false_negative|skipped|n_a`, default `n_a`). Recorded under `self_review.calibration_defect` / `self_review.calibration_size`. The legacy `self_review.calibration` is **unchanged** (back-compat) — callers that don't pass the split flags get `n_a` for both, correctly read as "split not computed; use the combined field." Enum-validated + asserted in the defense-in-depth schema gate.
  - `calibration_defect` — did Phase 3 find a real CODE defect (any non-`pr_size` gate fail/block, or a specialist blocker) that Sonnet claimed `ready` over? This is the **de-confounded primary calibration signal** going forward.
  - `calibration_size` — did Sonnet predict the diff size? (`pr_size` warn/block vs Sonnet's `size_assessment`/Phase 2.0 rebump). `n_a` when the `pr_size` gate didn't run.

#### Changed

- **`phase-4-finalize.md` §4.11 calibration logic** — rewritten to compute all three values (legacy + the two split dimensions) with explicit, copy-able pseudocode; §4.13 + the §4.11 canonical invocation now pass the two new flags.
- **`phase-2-implementation.md` Self-Review** — new step #8 instructs distinguishing a CODE deferral from a SIZE deferral; the completion-report format gains a machine-readable `size_assessment: fits|exceeds` line and splits `Deferred:` into `Deferred (code)` / `Deferred (size)` so the orchestrator computes `calibration_size` from a signal, not prose.
- **`config-schema.md`** — JSONL example shows the three calibration fields (+ the previously-missing `claimed_status`); `capture_self_review_calibration` description documents the split; **specialist-install confounder** documented (FP rates not comparable across the ≈2026-05-17 plugin-install boundary — pre-install cohorts had zero specialist review).

#### Why it matters

`calibration_defect` is now the metric to watch for self-review-prompt tuning (it ignores size noise); `calibration_size` measures whether Phase 0 line-aware routing + Phase 2.0 plan-size check + the P0 PR-size ceiling actually predict diff size. The two move independently — conflating them is why the v0.6→post-v0.6 "FP regression 15%→33%" looked alarming when it was mostly more reviewers + diff-size noise.

### PR-size ceiling that actually blocks + SPLIT-REQUIRED that actually fires (P0)

The single biggest quality gap: tasks were too big and the size ceiling was never enforced. Audit (254 entries): H-complexity diff median 855 lines, p90 3103, max 4166; **8 PRs added >2000 lines and ALL shipped as `pr_size=warn`, never `block`**, despite `block_lines=2000` (i807 3587L, i1167 3669L, i1100 2067L, i1168 2053L). Two root causes — (1) Phase 2.0 `plan-size-check`'s H bucket was effectively unbounded (`MAX_FILES=999 / MAX_LINES=99999`), so the `SPLIT-REQUIRED` branch was dead code; (2) Phase 3.0's PR-size gate described `block → STOP` as inline spec text the orchestrator treated as advisory and degraded to `warn`.

#### Changed

- **`plan-size-check` — real H ceiling**: `MAX_FILES 999→25`, `MAX_LINES 99999→1500`. `SPLIT-REQUIRED` now fires for genuinely-huge H plans (verified: 30 files / 4000 lines → `SPLIT-REQUIRED — … Split into ~3 sub-issues`). The H cap sits BELOW the Phase 3 `pr_size` block default (2000/50) on purpose: plan-time catches obviously-too-big before an hour of Sonnet; the 1500→2000 band is the estimate-error margin Phase 3 warns on; >2000 actual is the hard block. The suggested split count is computed (ceil of the worse overage) and doubles as an anti-fabrication tell.
- **`phase-2-implementation.md` §2.0 SPLIT-REQUIRED branch** — now actionable (present the suggested count, offer to file N sub-issues, re-run per slice) instead of a vague "ask user to split" that never triggered.

#### Added

- **`skills/do/scripts/pr-size-check`** (NEW wrapper) — the ONLY supported way to produce the Phase 3.0 PASS/WARN/BLOCK decision. Takes the real `git diff` `--lines`/`--files` (+ optional config threshold overrides; defaults baked in: warn 800/20, block 2000/50). Moves the verdict out of orchestrator judgment — it passes numbers, the wrapper decides. **BLOCK exits 3** (a hard halt) so the gate cannot degrade to advisory; PASS/WARN exit 0. Output carries `breached: [..]` + `+N lines/+N files` overage as the anti-fabrication tell. Same structural-coupling pattern as `plan-size-check`/`check-caveman`. (Clean exit codes also make it directly usable as a P3 `PreToolUse` hook on PR creation.)
- **`phase-3-review.md` §3.0** — rewritten to invoke `pr-size-check` + dispatch on the output/exit-3; BLOCK routes to the draft-PR + `blocked`-label escalation (same path as Phase 3.6 3-cycle exhaustion), `outcome=blocked`. "block is not advisory" called out explicitly.
- **`anti-patterns.md` §19f (NEW)** — "composing the Phase 3.0 PR-size verdict by hand" documented as the same fabrication-skip class as §19d (plan-size) / §19b (caveman). **§21** rewritten: block is a hard halt, never downgrade BLOCK→WARN to get a merge.

#### Docs

- **README** — new "PR-size ceiling" cheat-sheet row (warn/block thresholds + the plan-time/PR-time split). `examples/*.json` and the `config-init` auto-init preset were checked — neither encodes `pr_size`, so no threshold values needed updating (the wrapper defaults match config-schema.md).

#### Expected impact (measure at next audit)

- H tasks planning >1500 lines / >25 files re-route to SPLIT-REQUIRED at Phase 2.0 instead of producing a 3000–4000-line PR.
- PRs whose actual diff exceeds block thresholds halt at Phase 3.0 (`outcome=blocked`, draft PR) instead of shipping as `ready_for_review` with `pr_size=warn`. The 8 historical >2000-line `warn` PRs would all have blocked.

### Post-v0.6.0 audit follow-ups — 4 fixes from 32-entry data

After v0.6.0 deployed (May 21, 11:23Z), 32 canonical post-deploy entries accumulated in ~2.5 days. Audit (see [previous CHANGELOG entry](#phase-20-plan-size-check--observability-via-complexity_rebumped_from)) showed:

- Schema fixes worked perfectly (outcome 100% canonical, 0% negative cycle times, 100% orchestrator captured)
- FP rate REGRESSED from 15% → 33% with **0 Phase 2.0 re-bumps** despite **16 of 21 M-tasks** shipping >600 lines or >8 files
- 7 bypass entries with fabricated free-form shapes
- 1 case (i1023) with stub `specialist_iterations` (4 cycles all empty)

Four fixes, all in this [Unreleased] cycle:

#### Added

- **`skills/do/scripts/plan-size-check`** (NEW wrapper) — Phase 2.0 plan-size check moved out of inline spec bash into external wrapper. Same fabrication-avoidance pattern as `check-caveman` v3. Thresholds + bucket caps live ONLY in the wrapper. Outputs one of three structured decision lines: `Phase 2.0: PASS — ...`, `Phase 2.0: REBUMP <C>→H — ...`, `Phase 2.0: SPLIT-REQUIRED — ...`. Spec uses `case "$PLAN_SIZE_LINE" in` to dispatch — empty `$PLAN_SIZE_LINE` (wrapper skipped) matches nothing = visible bug. Anti-fabrication tell: output includes actual computed cap values for the bucket.

#### Changed

- **`metrics-append` — `--specialist-iterations-json` anti-stub validation** — reject if ANY cycle has `auditors=[]` AND `approvers=[]` AND `blockers=[]` (the i1023 fabrication pattern: sub-agent fabricated a 4-cycle structure with all-empty fields to satisfy field-present requirement). Real cycles MUST have at least `auditors` populated. If specialists genuinely didn't run for a cycle — omit the cycle, don't fabricate placeholder shape.
- **`phase-2-implementation.md` §2.0** — inline plan-size bash replaced with wrapper invocation + `case "$PLAN_SIZE_LINE"` dispatch. Explanation paragraph about WHY (the 0-rebump audit finding).
- **`phase-2-implementation.md` Self-Review section** — new pre-claim step (#6): `git diff main...HEAD --stat` and check against routed bucket caps. If diff exceeds M-bucket caps (600 lines / 8 files), return `claimed_status: deferred` with re-route hint instead of `ready`. Second-layer check using actual post-write diff, catches what Phase 2.0 plan-time check missed.
- **`anti-patterns.md` §19a** — added "Observed bypass shapes" subsection documenting 7 post-v0.6.0 bypass cases with specific field-name patterns (`ts`/`timestamp`, `insertions`/`deletions`, `verdict`/`outcomes`/`phase_4_status` invented). Confirms bypass = direct Write/echo, not wrapper misuse.
- **`anti-patterns.md` §19d (NEW)** — "Composing Phase 2.0 plan-size check decision by hand". Documents the 0/32 production observation. Same diagnostic pattern as §19b (caveman): missing structural tell in announce = wrapper skipped.

#### Expected impact (measure at next audit, ~T+50 fresh entries)

- **Phase 2.0 rebump rate >0%** for M-tasks shipping >600 lines (current: 0/16 expected, target: should fire on all 16)
- **FP rate** for M complexity should drop below baseline 12% once re-bumped tasks get H-tier specialist plan-review
- **Specialist iterations** no longer have stub shapes (i1023-style rejected at wrapper)
- **Bypass rate** still likely 10-20% — wrappers can't force sub-agents who don't call them; mitigation is daily-report tripwire visibility (already restored) and adding §19a observed shapes as the cookbook for code-review

### Phase 2.0 plan-size check — observability via `complexity_rebumped_from`

The v0.6.0 Phase 2.0 plan-size sanity check re-routes tasks to H when Sonnet's plan exceeds the bucket's caps, but the re-route fired silently — no field in the metrics entry captured that it happened. Result: we can't measure how often the check fires, on which transitions, or whether it correlates with lower FP rates. Adding observability now (cheap, +20 LOC) so the v0.6→v0.7 audit has the data.

#### Added

- **`metrics-append` — new `--complexity-rebumped-from {T|L|M}` flag** (optional, omit when no re-bump). Validates: enum is T|L|M (not H — H means already at top), and `--complexity-rebumped-from` cannot equal `--complexity` (re-bump means routed > original). Recorded in entry as top-level `complexity_rebumped_from` key, **omitted entirely** when no re-bump (keeps entries lean — only the rare cases get the field).

#### Changed

- **`phase-2-implementation.md` §2.0 plan-size check bash** — sets `COMPLEXITY_REBUMPED_FROM="$COMPLEXITY"` before bumping `COMPLEXITY` to H. New "Observability" paragraph explains the downstream metric.
- **`phase-4-finalize.md` §4.13 invocation** — passes `${COMPLEXITY_REBUMPED_FROM:+--complexity-rebumped-from "$COMPLEXITY_REBUMPED_FROM"}` (optional flag, no-op when var unset — the common case).
- **`config-schema.md` JSONL example** — adds `complexity_rebumped_from` to the documented Tier-1 entry shape with usage notes.

#### What this unlocks

Downstream analysis can now answer:
- "How often does Phase 2.0 fire?" — count of entries with the field present
- "Which Phase 0 bucket is most often wrong?" — distribution of T/L/M values in the field
- "Do re-bumped tasks have lower FP rate than tasks that stayed in their original bucket?" — comparison metric
- "Is Phase 0 routing improving over time?" — rate of re-bumps declining = Phase 0 estimates getting better

If after 100+ post-v0.6.0 entries the re-bump rate is <5%, line-aware Phase 0 routing is working as designed. If 15-25%, plan-size check is doing the heavy lifting. If >25%, Phase 0 estimate heuristics need revisiting.

## [0.6.0] — 2026-05-21

Phase 0 hardening cycle. 10 commits over 7 days (May 14–21) added 4 structurally-coupled wrappers (`check-caveman`, `config-init`, `config-ensure-metrics`, plus the existing `metrics-append` got v2), zero-touch project setup (auto-init of `.claude/do/config.json` with specialists + metrics presets), and line-aware complexity routing. Every change in this release traces to a documented production failure — see per-entry "Origin" / "Production-confirmed" / "Postmortem" sections below.

**Release-level summary** (detail in entries below):
- **4 wrappers, 4 structural-coupling tells.** Each announce token (`Caveman:`, `Config:`, `Metrics config:`, `Metrics:`) comes from wrapper stdout. Wrappers include a "tell" the orchestrator can't fabricate without running them (resolved path, probed-paths list, written file path, log line-count delta). Off-line copies become detectable visible bugs.
- **Zero-touch project setup.** First-run `/do` in a project auto-generates a working config (tracker from git remote, locale from `$ARGUMENTS`, specialists preset, tier-1 metrics preset). Existing configs missing `metrics` get patched idempotently.
- **Line-aware routing.** Phase 0 estimates files AND lines; refactor-keyword bumper for scope-multiplying changes; Phase 2.0 plan-size sanity check re-routes when Sonnet's plan exceeds bucket caps. Catches the May 21 burst of 6 underestimated Medium-tasks before they ship 1000+ line PRs.
- **Metrics enum cleanup.** `outcome` strict 3-value enum, timestamp ordering gate, orchestrator capture — addresses 121-entry audit that found 16 outcome variants and 36% negative cycle times.
- **Phantom plugin removed.** `frontend-excellence` (aspirational placeholder, not on any public marketplace) replaced with real `ui-design` + `javascript-typescript` (wshobson/agents).

### Phase 0/2 — line-aware complexity routing + Phase 2 plan-size sanity check

Postmortem of 13 false-positive cases on 2026-05-21 (10 of 13 in `miro-rooms-rentals`, all bursting in a 5-hour window) showed a consistent pattern: tasks routed Medium that actually produced 942–1859 lines / 9–31 files. The existing complexity matrix only cared about file count; line count was never considered. Phase 0 estimated `Files: ~7` correctly but ended up at 16+. `pr_size=warn` fired at Phase 3 (correctly!) but the wrapper didn't block because warn ≠ block, and `block_lines` defaults are tuned for H-bucket sizes (1500–2000 lines), making them no-ops on M tasks that wrote 1000+ lines.

Two complementary fixes — catch at routing time (cheap) and catch at plan time (when routing missed).

#### Changed

- **`phase-0-setup.md` complexity matrix** — added explicit "Lines added (est)" column with per-tier caps (T ≤50, L ≤200, M ≤600, H >600). New rule: "estimate BOTH files AND lines, pick the higher bucket." Includes references to the May 21 audit so the rule's origin is traceable.
- **`phase-0-setup.md` — refactor-keyword bumper** — new section. If `$ARGUMENTS` contains `refactor` / `rename` / `restructure` / `unify` / `consolidate` / `migrate <X> to <Y>` / `rewrite` / `extract <module>` / `split <module>` — prefer one tier higher. Refactors compound across the codebase even when "only N files" are touched directly.
- **`phase-0-setup.md` announce template** — adds `EstLines: ~{L}` next to `Files: ~{N}` so the estimate is visible to the user at routing time (and metrics-logged for future audit accuracy).

#### Added

- **`phase-2-implementation.md` §2.0 — Plan-size sanity check (NEW)** — runs once per Sonnet spawn, immediately after the approved plan is in and BEFORE the prompt is constructed. Compares planned files + estimated lines against the routed bucket's caps; if exceeded:
  - **Bumps to H** (re-runs Phase 1 issue update + Phase 2 specialist plan-review with new tier) when current is T/L/M
  - **Aborts and asks user to split** when current is already H (single PR is the wrong shape for the task)
  
  The old §2.0 (Stale-main check) is renumbered to §2.0.5. Check is cheap (numeric comparison) and runs ONCE per spawn — no per-iteration cost.

#### Why both at Phase 0 AND Phase 2

Phase 0 estimates are pre-exploration — the orchestrator hasn't seen the actual file list yet, just the user's task description. The estimate can be off by 2-4× for refactor-class tasks. Phase 2 re-checks against the now-concrete approved plan (file list is fixed by that point). Plan-size check at Phase 2 catches what Phase 0 estimate missed.

#### Expected impact

The May 21 postmortem 6 FP cases:
| ref | files (actual) | lines added | At Phase 0 (file-count rule alone) | At Phase 0 (NEW line-est rule) | At Phase 2.0 (plan-size check) |
|---|---|---|---|---|---|
| i968 | 16 | 1859 | H (>9 files) | H | (already H) |
| i970 | 9 | 1345 | H | H | (already H) |
| i963 | 13 | 1248 | H | H | (already H) |
| i961 | 28 | 1169 | H | H | (already H) |
| i969 | 21 | 1014 | H | H | (already H) |
| i959 | 31 | 942 | H | H | (already H) |

All 6 should have been routed H from Phase 0 by **the existing file-count rule** (>9 files = H). The Phase 0 announce showed `Files: ~N` < 9 for all of them — meaning the orchestrator's estimate was wrong, AND the line-estimate column would NOW be the secondary check that catches it (942–1859 >> 600 cap). Phase 2 plan-size check is the third layer: even if both Phase 0 estimates miss, by Phase 2 the plan has the real file list and the check fires.

### Phase 4.12 — `metrics-append` hardening: outcome enum, timestamp ordering, orchestrator capture

Audit of 121 canonical entries (May 14–21) surfaced three concrete data-quality issues that escaped the existing v0.6 wrapper:

1. **`outcome` field — 16 distinct values for what should be 3.** Wrapper accepted any non-empty string. Production drift: `success`/`completed`/`shipped`/`ok`/`pr_opened`/`pr_open`/`ready_for_review` for ~92 entries, plus **9 spelling variants of "merged"** (`merged_pending`, `merged_pr_open`, `merged_or_pr_open`, `merged_ready`, `merged_to_main_or_pr_open`, `merged_or_pushed`, `merged_open`, `merged_via_pr`). Cross-run aggregation (merge rate, blocked-PR analysis) required manual normalization on every dashboard.

2. **36% of entries had `ended_at < started_at`** (median negative delta: -2.5 hours). Sub-agents captured both timestamps at Phase 4.13 using inconsistent timezone handling or back-computing `started_at` incorrectly. Cycle-time analysis on a metric where 36% of values are nonsensical is useless — real median cycle time (23 min) only computable after filtering negatives.

3. **`orchestrator` field never captured.** All 121 canonical entries had it absent or `"?"`. Spec mandates capture per [SKILL.md notation](skills/do/SKILL.md#notation) — the Co-Authored-By footer reads model from session metadata for the same reason, but metrics-append had no flag for it.

#### Changed

- **`scripts/metrics-append` — strict outcome enum.** Regex `^(merged|ready_for_review|blocked)$`. Rejects everything else with a verbose error message explaining the canonical mapping (avoid replaying the audit).
- **`scripts/metrics-append` — timestamp ordering gate.** Both `--started-at` and `--ended-at` parsed via `date -j -u -f`. Reject if `ended_epoch < started_epoch`. Error message points at the most common cause (capturing both at Phase 4.13 retroactively) and the fix (capture STARTED_AT at Phase 0 entry).
- **`scripts/metrics-append` — `--orchestrator` flag.** Optional with default `"opus"` (spec mandates orchestrator=opus). Accepts `opus`, `opus-N.M`, plus `haiku`/`sonnet` for testing. Regex-validated. Schema gate (jq) also asserts the field exists.
- **`phase-4-finalize.md` §4.13 invocation** — adds `--orchestrator` passthrough (`${ORCHESTRATOR:+...}` form so it's optional for callers that don't track model version).
- **`phase-4-finalize.md` §4.11 (Step 2 area)** — new "Computing `$OUTCOME`" block. Explicit decision tree using `gh pr view --json mergedAt` and `$BLOCKED` flag, NOT free-form guessing. Plus "Computing `$ORCHESTRATOR`" and "Computing `$STARTED_AT`" guidance with anti-patterns called out.

#### Migration

Existing 121 canonical entries remain valid for retrospective analysis if you filter out the 36% with negative cycle times and bucket the 16 outcome variants manually. Fresh entries from this version forward will have uniform enum + positive deltas + non-null orchestrator.

### Phase 0.2 — caveman detect v3: external wrapper + probed-paths tell

**Third iteration on the same fabrication.** Production confirmed today (2026-05-17, lea-web run): orchestrator announced `Caveman: NOT INSTALLED — install: curl ...` while caveman was installed at path #1. The v2 fix had moved the line template into the bash literal (the `CAVEMAN_LINE="..."` assignment) — but the literal is still visible to the orchestrator at parse time, so it copy-pasted from there without running the bash. Same root failure, one indirection deeper.

v3 structural fix: detection moved to `scripts/check-caveman` wrapper. The spec now contains zero copyable form of either announce string — only `CAVEMAN_LINE="$(~/.claude/skills/do/scripts/check-caveman)"`. Plus a runtime-only **anti-fabrication tell**: the NOT-INSTALLED form includes `(probed: <P1>, <P2>, <P3>, <P4>)` — the actual paths checked, built from the wrapper's internal array, NEVER written in the spec. Orchestrator skipping the wrapper cannot include this suffix without inventing path names, which is a visible bug.

#### Added

- **`skills/do/scripts/check-caveman`** — zero-arg bash wrapper, exits 0 always. Two output forms:
  - `Caveman: ACTIVE (path: <resolved-path>)` — when any of 4 candidate paths has `SKILL.md`
  - `Caveman: NOT INSTALLED (probed: <P1>, <P2>, <P3>, <P4>) — install: curl …` — full probed-paths suffix as anti-fabrication tell

#### Changed

- **`phase-0-setup.md` Step 2** — replaced 13-line inline bash with 2-line wrapper invocation. Removed all prose descriptions of the canonical announce templates (only wrapper outputs them now). Explanation of WHY a wrapper (vs inline) is now part of the step text.
- **`anti-patterns.md` §19b** — rewritten as v3 entry. Documents both 2026-05-17 production fabrications (miro-rooms + lea-web). Diagnostic clause: announce missing `(path: ...)` or `(probed: ...)` suffix → orchestrator skipped the wrapper.

#### Why three iterations

Each version removed the previous round's copyable surface, orchestrator pivoted to the next-most-visible literal:
- **v1** (initial): prose bullets ("- ACTIVE → ...", "- NOT INSTALLED → ...") with full strings. Orchestrator copied from bullets.
- **v2** (this CHANGELOG, earlier): bullets removed, strings in `CAVEMAN_LINE="..."` bash assignments. Orchestrator copied from assignments.
- **v3** (now): wrapper-only. Spec has `$(wrapper)` invocation, zero string literals. Plus probed-paths tell makes off-line copies detectable even if a future orchestrator's prompt-cached spec is stale.

The general lesson: **structural coupling works only if there's no literal copy of the output in the spec for the agent to read.** Wrappers achieve this; inline bash with output-string literals does not.

### Phase 0.6 — telemetry auto-config (new + existing paths)

Sibling change to the specialists preset (below). Same friction: every new project gets a config without `metrics` block → Phase 4.11 silently no-ops (per spec line 205: "unset/null log_path → silently skip"), and the user has no telemetry until they remember to add the block by hand. Worse, EXISTING configs that pre-date the metrics rollout (or were copied from minimal example) also lack the block — Phase 0 had no way to surface or remediate this.

Fix covers both paths:
- **New configs (Step 4 auto-init)**: `config-init` now emits the documented tier-1 `metrics` preset by default (same flag pattern as `--specialists` — opt-out via `--no-metrics`).
- **Existing configs (Step 1 found-case)**: new `config-ensure-metrics` wrapper runs on every `/do` against a found config. If `metrics` key is absent → patches in the default preset + stamps `_meta` with `last_patched_*` provenance. If `metrics: {...}` → leaves alone. If `metrics: null` (explicit opt-out) → respects.

#### Added

- **`skills/do/scripts/config-ensure-metrics`** — bash wrapper, idempotent, named-arg CLI (`--config <path>`). Three outcomes via stdout (same structural-coupling pattern as `metrics-append` / `config-init`):
  - `Metrics config: ALREADY CONFIGURED in <path>` — `metrics: {object}` present, no change
  - `Metrics config: EXPLICIT OPT-OUT in <path> (metrics: null)` — key present with null value, user intent respected
  - `Metrics config: AUTO-ADDED to <path>` — key was absent, default tier-1 preset patched in via atomic tmp+rename
  - Refuses: missing `--config`, invalid JSON, senior-by-default repo itself (defense-in-depth — config dir → repo root walk + skill-source check), `jq` not installed. Schema-validates patched config against `config.schema.json` before write if `jsonschema` available.
- **`config-init` — new `--metrics {default|none}` flag** (default: `default`). When `default`, emits the documented tier-1 preset alongside specialists. `_setup_notes` extended to describe metrics behavior.

#### Changed

- **`phase-0-setup.md` Step 1 (found-case)** — added telemetry-ensure block: `config-ensure-metrics` called on the loaded config unless `--no-metrics` in `$ARGUMENTS`. `$METRICS_CONFIG_LINE` captures wrapper stdout (3 forms above + `SKIPPED (--no-metrics)` + `PATCH SKIPPED — <reason>` for refuse paths).
- **`phase-0-setup.md` Step 4 auto-init bash** — detects `--no-metrics` in `$ARGUMENTS`, passes `--metrics default|none` to `config-init`. After wrapper call, mirrors metrics state into `$METRICS_CONFIG_LINE` (`INCLUDED in auto-init` / `SKIPPED (--no-metrics)` / `N/A (auto-init skipped)`) so the announce token is uniformly set regardless of which Step set it.
- **`phase-0-setup.md` Announce template** — added mandatory `$METRICS_CONFIG_LINE` placeholder alongside `$CAVEMAN_LINE` / `$CONFIG_LINE`. Same "DO NOT compose" guard.
- **`SKILL.md` advanced flags** — added `--no-metrics`.

#### The preset (matches `config-schema.md` documented defaults)

```json
"metrics": {
  "log_path": "~/.claude/do/metrics/{repo_slug}.jsonl",
  "include_phase_durations": true,
  "tier": 1,
  "capture_failure_details": true,
  "capture_self_review_calibration": true,
  "capture_specialist_iterations": true,
  "max_string_length": 500
}
```

Home-based log location (not in-repo) means a single `daily-report.sh` scanner can see telemetry from every project. `{repo_slug}` placeholder resolved by Phase 4.11 at write time per [`phase-4-finalize.md`](skills/do/references/phase-4-finalize.md).

#### Why a separate wrapper for the patch path (not extend `config-init`)

`config-init` refuses-on-exists by design — that contract is load-bearing (prevents accidental overwrite of user customizations). Adding a `--patch-mode` flag would erode it. Single-purpose `config-ensure-metrics` keeps the two operations cleanly separated: create-or-fail vs ensure-section-or-noop. Each operation is one wrapper, one announce line, one anti-pattern bucket.

### Phase 0.5 — `config-init` ships specialists preset by default

Companion change to the `frontend-excellence → ui-design` docs swap below. With the README + examples updated, the natural next question is: why does the auto-generated config still omit `specialists` entirely? Every new project gets a minimum-viable config and the user has to copy a snippet from `examples/` to wire up Phase 3 specialist review. The friction is exactly the same one that produced the original "no config" annoyance.

Fix: auto-init now emits the recommended `specialists` preset by default, referencing the 6 real plugins from the two recommended marketplaces. The wrapper's `_setup_notes` lists the exact `/plugin install` commands so users have a self-contained install path inside the generated file. If a plugin isn't installed, /do falls back to Opus inline review for that group — same graceful-degradation behavior as before.

#### Changed

- **`scripts/config-init`** — new `--specialists {default|none}` flag (default: `default`). `default` emits the preset; `none` omits the block. `_setup_notes` text dynamically extended with install hint when preset enabled.
- **`phase-0-setup.md` Step 4 auto-init bash** — detects `--no-specialists` in `$ARGUMENTS`, passes `--specialists default|none` to wrapper. Updated trailing paragraph to describe the new shape (`version + _meta + issue_tracker + issue_locale + specialists`).
- **`SKILL.md` advanced flags** — added `--no-specialists` opt-out (alongside `--no-config-init`).

#### The preset

| Group | Agents |
|---|---|
| `backend_plan` | `backend-development:backend-architect`, `backend-development:security-auditor`, `database-design:database-architect` |
| `frontend_plan` | `ui-design:design-system-architect`, `ui-design:ui-designer`, `javascript-typescript:typescript-pro` |
| `backend_audit` | `code-refactoring:code-reviewer`, `backend-development:backend-architect`, `backend-development:security-auditor` |
| `frontend_audit` | `code-refactoring:code-reviewer`, `ui-design:ui-designer`, `pr-review-toolkit:silent-failure-hunter`, `ui-design:accessibility-expert` |
| `migration_audit` | `database-design:database-architect` |

Universal across stacks — Phase 3 routing already gates by diff content (frontend_audit fires on FE diff, backend on BE diff, migration_audit on migration presence). Users on pure-FE or pure-BE projects pay nothing for the unused groups.

#### Why bake it into the wrapper

Same reason as the original `config-init` design (see CHANGELOG below): keep the wrapper as the single source of truth for what auto-init writes. If users hand-edit the generated file to add specialists, that's expected; if downstream tooling has to guess "did /do write specialists or did the user add them later?", it can't tell. Wrapper-emitted preset solves both — discoverable defaults + observable provenance via `_meta.auto_generated_by`.

### Docs — replace phantom `frontend-excellence` plugin with real `ui-design` + `javascript-typescript`

Production-confirmed: orchestrator on a real Next.js project hit "Specialists not available — falling back to Sonnet" because `config.specialists.frontend_*` referenced `frontend-excellence:react-specialist|component-architect|frontend-optimizer`, but **no public marketplace ships a `frontend-excellence` plugin** — it was an aspirational placeholder that propagated from this README + the multi-repo example config to user configs. Verified by searching `anthropics/claude-plugins-official` (35 plugins, no match) and `wshobson/agents` (81 plugins, no match), and by github code-search across the public ecosystem.

#### Changed

- **README.md** — Recommended-plugins section restructured: separated marketplaces (`anthropics/claude-plugins-official` + `wshobson/agents`) from plugins, added install commands (`/plugin marketplace add` + `/plugin install <name>@<marketplace>`), replaced `frontend-excellence` line with `ui-design` (3 agents — `ui-designer`, `design-system-architect`, `accessibility-expert`) and `javascript-typescript` (2 agents — `typescript-pro`, `javascript-pro`). Historical note explains the replacement.
- **`examples/multi-repo-go-react-config.json`** — `specialists.frontend_plan` and `frontend_audit` updated to use the real substitutes. Audit roster grew to 4 (was 3) by adding `ui-design:accessibility-expert` — a11y is a strong Phase 3 audit angle for FE-heavy diffs.
- **`skills/do/references/codeowners.md`** — example agent_map updated.
- **`skills/do/references/config-schema.md`** — example agent_map updated.

#### Substitution rationale

| Original (phantom) | Replacement (real) | Closest semantic match |
|---|---|---|
| `frontend-excellence:react-specialist` | `ui-design:ui-designer` | UI/UX review |
| `frontend-excellence:component-architect` | `ui-design:design-system-architect` | Design-system / component-architecture review |
| `frontend-excellence:frontend-optimizer` | `javascript-typescript:typescript-pro` | TS-pro for type-safety + modern JS; the closest "quality optimizer" on a Next.js stack |
| n/a (new in audit roster) | `ui-design:accessibility-expert` | a11y audit — strong Phase 3 signal for FE |

#### Why this didn't bite earlier

The skill's fallback ("Opus inline review when specialist not available") is silent and works correctly. Users would just see slightly less parallelism and assume that was the design. Production observation surfaced the issue when the orchestrator narrated "Specialists not available" — that string isn't even in the spec; it's what sub-agents say when `Agent(subagent_type=<missing>)` fails. The bug wasn't broken behavior, it was misleading docs.

### Phase 0.4 — auto-init: locale detection + tighter `$CONFIG_LINE` contract

Production observation from the v0.3 auto-init: orchestrator ran the wrapper with default `--issue-locale en`, noticed the repo was Russian-speaking (Cyrillic in `$ARGUMENTS` + assumptions), post-edited the generated config to flip `issue_locale: en → ru`, and appended `" (patched issue_locale=ru)"` to `$CONFIG_LINE` in the announce. The patch itself was correct adaptation; the channel was wrong — `$CONFIG_LINE` is meant to be exactly what the wrapper emitted, augmenting it with free-form suffixes breaks structural coupling and sets precedent for arbitrary post-edits.

#### Changed

- **`phase-0-setup.md` Step 4 auto-init bash** — now detects `$ISSUE_LOCALE` from `$ARGUMENTS` before calling the wrapper: explicit `--issue-locale=<code>` wins; otherwise Cyrillic → `ru`, Hiragana/Katakana/CJK Unified Ideographs → `ja`, Hangul → `ko`, else default `en`. Passes the resolved value via `--issue-locale "$ISSUE_LOCALE"` in both `tracker=none` and `tracker={github,gitlab}` branches. Wrapper writes the right value in one atomic call; `$CONFIG_LINE` stays canonical.
- **`anti-patterns.md` §19c** — added explicit prohibition of the "post-edit + announce-annotation" pattern (production diagnostic + the two correct paths: pass `--issue-locale` at invocation, or edit the file as a separate clearly-separate step that does NOT touch `$CONFIG_LINE`).
- **`phase-0-setup.md` Step 4 trailing note** — explains why locale detection lives at invocation, not post-edit: keeps wrapper as single source of truth for `$CONFIG_LINE`.

#### Why detection lives in spec bash, not wrapper

Wrapper already accepts `--issue-locale`; the gap was just that nobody was passing it. Detection naturally belongs in the orchestrator's context (it has `$ARGUMENTS`, repo paths, README, etc.), not in the wrapper (which is single-purpose: write a valid config given args). Moving detection into wrapper would also force the wrapper to take a stance on auto-detection rules — better to keep wrapper deterministic and let the spec bash evolve detection heuristics.

#### Detection coverage (current)

| Script | Locale |
|---|---|
| Cyrillic (Russian, Ukrainian, Belarusian, etc.) | `ru` |
| CJK Unified Ideographs (Chinese, Japanese kanji) | `ja` (conservative default — extend per project) |
| Hiragana / Katakana (Japanese-specific kana) | `ja` |
| Hangul (Korean) | `ko` |
| Default | `en` |

Coarse on purpose. If your project needs `zh` vs `ja`, `uk` vs `ru`, or any other locale, pass `--issue-locale=<code>` explicitly in `$ARGUMENTS`. The detection block is small, easy to extend.

### Phase 0 — caveman detect v2 + auto-init of `.claude/do/config.json`

Two issues from production observation of the prior `[Unreleased]` v1 caveman fix:

1. **Caveman v1 didn't stick.** With the verbatim bash and mandatory-line patch, orchestrator still emitted `Caveman: NOT INSTALLED — install: curl -fsSL ...` on a machine where caveman was actually installed at the first path. Diagnosis: orchestrator read the spec, saw the `NOT INSTALLED` example bullet describing the not-found case, copy-pasted the full string (including install-hint suffix that the v1 bash did NOT echo). Confirmation = the install-hint suffix `— install: curl ...` was in the announce but the v1 bash's echo template only produced `Caveman: NOT INSTALLED` without that suffix. So the bash didn't run.

2. **`No .claude/do/config.json — using defaults` is a noisy status with no path forward.** Real projects benefit from a config (tracker integration, specialists, workspace routing), but writing one by hand from the schema is friction nobody pays. Result: every `/do` run in a fresh repo reports "no config" and that's the end of it.

#### Added

- **`skills/do/scripts/config-init`** — bash wrapper, named-args CLI. Required flags: `--repo-root`, `--tracker {github|gitlab|none}`. Conditional: `--tracker-repo owner/repo` (required when tracker ≠ none, regex-validated). Optional: `--stack`, `--issue-locale`. Refuses overwrite, refuses `$HOME` or `/` root, refuses to bootstrap senior-by-default itself (detects `skills/do/SKILL.md` at root). Composes minimal valid config (`version`, `_meta`, `issue_tracker`, `issue_locale`) via `jq -n`. Validates against `config.schema.json` if `python3 -m jsonschema` available. Atomic tmp+rename write. Exit codes: 0 OK / 1 REJECT / 2 IOFAIL — same shape as `metrics-append`.

#### Changed

- **`phase-0-setup.md` Step 2 (caveman v2)** — bash now builds the FULL announce line (including install-hint suffix for NOT INSTALLED) and assigns to `$CAVEMAN_LINE`. Removed the post-bash bullets that described the two output forms in prose — those were the copy-paste bait. Announce template references `$CAVEMAN_LINE` literally (same coupling as `$METRICS_LINE`). Spec contains no other example of either form's full text.
- **`phase-0-setup.md` Step 1** — restructured to set `CONFIG_FOUND` flag and `$CONFIG_LINE`. Found-case sets `CONFIG_LINE="Config: LOADED $CONFIG_PATH"`. Missing-case defers `$CONFIG_LINE` to Step 4 auto-init.
- **`phase-0-setup.md` Step 4** — added "Auto-init config" block at the end. Detects tracker from `git remote get-url origin` (github/gitlab/none with owner/repo extraction). Calls `config-init` with detected values, captures stdout/stderr into `$CONFIG_LINE`. Refuse paths produce `Config: AUTO-INIT SKIPPED — <reason>` — not errors, just visible notes.
- **`phase-0-setup.md` Announce template** — `Caveman:` and `Config:` lines replaced with literal `$CAVEMAN_LINE` / `$CONFIG_LINE` placeholders and "DO NOT compose" markers. Suppression: `--no-caveman` empties `$CAVEMAN_LINE` (line omitted); `--no-config-init` sets `$CONFIG_LINE="Config: NONE — using defaults (--no-config-init)"`.
- **`SKILL.md` advanced flags** — added `--no-config-init`.
- **`anti-patterns.md` §19b (new)** — "Composing the `Caveman:` announce line by hand instead of running Step 2 bash". Documents the exact production failure mode (install-hint suffix in announce while bash didn't emit it) as the diagnostic.
- **`anti-patterns.md` §19c (new)** — "Writing `.claude/do/config.json` directly instead of calling `config-init`". Bans `Write`, `echo >`, `jq > config.json`, `cat <<EOF >` paths. Notes that hand-composing `Config: AUTO-GENERATED →` without invoking the wrapper falls under this — lying about file state.

#### Why this round (not the v1 fix)

v1 added the verbatim bash but kept descriptive bullets immediately below it (`- ACTIVE → ...` / `- NOT INSTALLED → ...` with the install-hint string spelled out). Those bullets were the bait — sub-agents pattern-match on plausible-looking copyable strings. The v1 bash echoed only `Caveman: STATUS [path]`; the bullets' install-hint suffix was NOT in any bash variable. Yet the prod announce contained the full `NOT INSTALLED — install: curl ...` form. Only way that happens is hand-composition from prose.

v2 fix: the bash builds the COMPLETE line. The spec contains no other place where either full form appears verbatim. If the announce diverges from one of the two bash-emitted shapes by even a character, that's a fabrication tell.

Same coupling extended to config: there's no in-doc template to copy from; the wrapper's stdout IS the announce line. The five forms (`LOADED`, `AUTO-GENERATED`, `AUTO-INIT SKIPPED — ...`, `NONE — using defaults (--no-config-init)`) only emerge from the bash/wrapper combination, never from hand composition.

### Phase 0.2 — caveman detect: concrete bash + mandatory announce line

Production report: orchestrator ran `/do` on a machine where caveman was installed at `~/.claude/skills/caveman` (the FIRST path in the spec's detect list), yet the Phase 0 announce omitted the `Caveman:` line — same failure mode as the pre-v0.3.1 `metrics-append` bypass: prose-only spec → sub-agent reads, decides, skips, composes announce without the line. No way to tell from the announce whether detection ran-and-found-nothing or wasn't attempted.

#### Changed

- **`phase-0-setup.md` Step 2** — replaced "detect at one of: …" prose with a verbatim bash block (`for p in …; do [ -f "$p/SKILL.md" ] && { CAVEMAN_STATUS=ACTIVE; break; }; done; echo "Caveman: …"`). Same structural-coupling pattern as `metrics-append`: the announce line literally comes out of the bash, so it cannot be silently skipped.
- **`phase-0-setup.md` Step 2 — path list extended** to 4 entries. Added `~/.agents/skills/caveman` for users who installed via the agent-skill manager without a `~/.claude/skills/` symlink. Pinned the test to `[ -f "$p/SKILL.md" ]` (not `[ -d "$p" ]`) to resolve symlinks correctly and reject empty directories left by failed installs.
- **`phase-0-setup.md` Announce block** — promoted `Caveman:` from a conditional `[+ if …]` bracket to a mandatory line in the fixed template, alongside `Models:`. The only suppression path is `--no-caveman` (which skips Step 2 entirely). Absent line in announce now = visible bug.

#### Why this matters

Detection skipped silently → Phase 2 Sub-Agent prompts don't get the caveman-style directive even when caveman is active → output isn't compressed for the spawned agent → tokens wasted, register inconsistent across orchestrator vs sub-agent. The audit pattern (instruction-only spec → non-deterministic execution) is the same one that bit Phase 4.11 twice; the fix shape is the same too (move from "you should …" prose to "run this bash" + mandatory output token).

### Phase 4.11 — external `metrics-append` wrapper (real enforcement, take 2)

Audit of 9 production entries written after the prior `[Unreleased]` change showed the in-doc `jq -n` template + `:?`-guards approach **did not actually enforce anything**: 5 of 9 sub-agents bypassed the documented bash flow entirely (composed JSON via Write / echo / python with whatever shape they wanted, 100+ distinct field names across runs, `self_review` block missing in 5 of 9). The prior fix would have rejected these entries IF the sub-agent ran the documented bash block, but sub-agents don't reliably run documented bash — they read it, decide on a different approach, and write whatever JSON they want directly to the log path.

#### Added

- **`skills/do/scripts/metrics-append`** — standalone bash wrapper, named-args CLI. Required flags: `--log`, `--ref`, `--complexity`, `--implementer`, `--outcome`, `--started-at`, `--ended-at`, `--files-changed`, `--lines-added`, `--lines-deleted`, `--sr-performed`, `--sr-claimed`, `--sr-calibration`. Unknown flags reject. Bad enum values reject. Malformed JSON payloads (`--gates-json`, `--phase-durations-json`) reject. Append is atomic with pre/post line-count delta verification. Exit codes: 0 OK / 1 REJECT / 2 IOFAIL with explicit stderr message in each failure case.

#### Changed

- **`phase-4-finalize.md` Step 3** — removed the `jq -n` inline template (proven ignored). Replaced with: "the ONLY supported way to write is via `~/.claude/skills/do/scripts/metrics-append`". Documents the canonical invocation that the §4.13 announce block uses.
- **`phase-4-finalize.md` §4.13 emit block** — now invokes the wrapper and captures stdout into `$METRICS_LINE`. No JSON composition in the announce flow anymore. Removed `SCHEMA_OK` plumbing (wrapper exit code is the gate).
- **`phase-4-finalize.md` "Why structural coupling"** — rewritten to explain the three enforcement layers: soft instruction (failed) → bash coupling (caught the announce-skip pattern but not free-form JSON) → external wrapper (catches both).
- **`anti-patterns.md` #19a (new)** — "Writing to `$LOG_PATH` directly instead of calling `metrics-append`". Explicitly bans `echo >>`, `Write` tool, `python3 -c '...' >>`, manual `jq` + `>>`. Points at the wrapper and at the daily-report tripwire.

#### Tripwire (operator-side, not part of the skill distribution)

A local `daily-report.sh` (separate from the skill) now scans for entries that don't match the canonical shape and surfaces them in a "Schema bypass" section, listing which required fields are missing per entry. Bypasses become visible in the next morning's report instead of silently polluting analytics. Sub-agents that ignore the wrapper will see their entries excluded from analytics within 24 hours.

#### Migration

Past JSONL entries from the prior `[Unreleased]` cycle are mixed (some valid, most bypass). Operators should drop bypass entries and accumulate fresh — the wrapper guarantees uniform schema from this version forward.

### Phase 4.11 — structural schema enforcement for metrics JSONL

Sub-agents were composing the metrics entry as a free-form JSON string, producing wildly inconsistent shapes across runs (100+ distinct field names across a few dozen entries in one repo's log: `ts`/`timestamp`, `loc_added`/`added`/`insertions`/`lines_added`, `pr`/`pr_number`/`pr_url`, six spellings of `follow_up` — every run reinvented the schema). The `self_review` block — the highest-signal calibration signal — was emitted in **0 of 37** observed entries despite tier-1 config explicitly requesting it. Cross-run analysis (FP-rate, complexity vs cycles, gate failure trends) was impossible without manual normalization.

#### Changed

- **`phase-4-finalize.md` Step 3** — replaced the `JSON='{...}'` free-form-string example with a `jq -n --arg/--argjson` template fed from explicit env vars. `:?`-guards on required fields (`REF`, `COMPLEXITY`, `IMPLEMENTER`, `OUTCOME`, `STARTED_AT`, `ENDED_AT`, `FILES_CHANGED`, `LINES_ADDED`, `LINES_DELETED`, `SR_PERFORMED`, `SR_CLAIMED_STATUS`, `SR_CALIBRATION`) halt bash if unset. Optional fields default via plain `[ -z "${VAR:-}" ] && VAR=...` assignment (`${VAR:-{}}` parse bug: closing `}` of expansion swallows brace, leaves trailing literal that breaks `jq --argjson` — confirmed in dry-run).
- **`phase-4-finalize.md` Step 3.5 (new)** — `jq -e` schema gate. Validates types + regex on `complexity`, `implementer`, `outcome`, `self_review.{performed, claimed_status, calibration}`. On reject sets `SCHEMA_OK=0` and `METRICS_LINE="Metrics: SCHEMA REJECT — ..."`. The reject is intentional — silently appending a malformed entry pollutes the schema and degrades calibration analysis far worse than a visible reject does.
- **`phase-4-finalize.md` §4.13 emit block** — append now gated by `SCHEMA_OK=1`. Reject path keeps `METRICS_LINE` from Step 3.5; announce still prints. Same structural coupling as before (no emit → no announce) plus a new layer (no schema → no emit).
- **`phase-4-finalize.md` "What broke the procedure looks like"** — added diagnostic for `SCHEMA REJECT` line in announce.

#### Breaking behavior

Tasks where the sub-agent doesn't populate the `SR_*` env vars from Phase 2.5 will now produce `Metrics: SCHEMA REJECT — ...` instead of silently appending an entry missing `self_review`. For tier-0 or self-review-disabled configs, set `SR_PERFORMED=false`, `SR_CLAIMED_STATUS=n/a`, `SR_CALIBRATION=skipped` — these are valid enum values, not workarounds.

#### Migration

Past JSONL entries are unusable for calibration (no `self_review` block, ~120 distinct field names). Delete and accumulate fresh — ~20–30 valid entries gives the first reliable FP-rate point.

## [0.5.0] — 2026-05-14

Cleanup release. Audit found ~7% of repo content was structural bloat — false hierarchy (12 sub-phases in Phase 0), duplicated procedure docs (Phase 4.13 procedure repeated 3×), numbered anti-patterns with `31a/31b/31c/31d/31e/31f` chaos from incremental fixes, unsorted override flags (main vs niche slammed together), unused config sections lacking experimental marking.

**No behavior change.** Structural reorg only. SKILL.md shrunk from 331 → ~190 lines. Phase 0 detail extracted to dedicated reference. Anti-patterns rationalized 53 → ~25 grouped entries. Override flags split into main (5) + advanced (6). Phase 4.13 procedure consolidated to single canonical block. Experimental config sections marked.

### Changed

- **`SKILL.md` Phase 0 detail extracted** to new `references/phase-0-setup.md` (~170 lines). SKILL.md keeps a 6-bullet summary + pointer. Previous structure had 12 numbered sub-phases (`0.0`, `0.0.1`, `0.0.2`, `0.0.3`, `0.1`, ..., `0.8`) implying false hierarchy — `0.0.1` prefix suggested "sub-checks before main setup" when most were conditional bullets that only fire per config. Now 6 logical steps with conditionals inline.
- **`anti-patterns.md` rationalized**: 53 numbered entries with `31a-f` chaos → 24 grouped entries across 6 categories (Process / Memory & context / Git / Code / Distributed-team & enforcement / Opt-in only / Universalization-specific). Hot ones bolded. No info loss — overlapping entries merged, historical universalization items moved to bottom.
- **`SKILL.md` override flags split** into Main (5: `--complexity`, `--implementer`, `--repo`, `--redetect`, `--auto-merge`) + Advanced (6 niche: `--skip-ci-wait`, `--no-self-review`, `--no-codeowners`, `--no-notify`, `--no-affected-graph`, `--no-caveman`). Clearer separation of what most users override per-task vs config-level toggles.
- **`phase-4-finalize.md` §4.13 procedure consolidated**: bash flow was implicit in 3 sections (header notice + "The procedure" + "Why" subsections). Now: one canonical bash block, "Why structural coupling" explanation, "What broke the procedure looks like" diagnostic. ~50 lines saved, single source of truth.
- **`config-schema.md` experimental fields marked**: `wip_limit`, `feature_flags`, `lessons_doc`, `postmortem`, `concurrent_edit_check` now under "Experimental / niche fields" section with explicit "leave unset unless you specifically know what you want" guidance. Not removed for back-compat.
- **SKILL.md top-level anti-patterns line** shortened from 12-item run-on prose to 9-bullet list grouped by what's hot in production.

### Lines saved

| Area | Before | After | Saved |
|---|---|---|---|
| SKILL.md | 331 | ~190 | 140 |
| anti-patterns.md | 78 | ~75 | 3 (count similar but density up) |
| phase-4-finalize.md | 353 | ~310 | 40 |
| **Total realistic** | — | — | **~180 lines, ~5% of repo** |

### Not simplified (despite size)

- Phase 2 Sub-Agent prompt template (200+ lines) — each instruction bought by audit/production lesson
- 14 reference files via progressive disclosure — works as designed
- JSON Schema — programmatic validation, distinct consumer
- 4 example configs — different stacks need different shapes
- CHANGELOG — release history, archived later when v1.0+

### What to verify

After upgrading, run `+++ <small task>` in a sandbox/test project. Final assistant message should still end with `Metrics: <N> entries in <path>.` line (structural coupling unchanged). Phase 0 announce should still produce the `Models:` line. Branch should still be `feat/i{N}-{slug}` (not `claude/<adj>-<noun>`).

## [0.4.0] — 2026-05-11

Minor release. Adapts the four behavioral guardrails from [`forrestchang/andrej-karpathy-skills`](https://github.com/forrestchang/andrej-karpathy-skills) into the `do` pipeline without changing config shape or output schemas.

### Added
- **Top-level operating principles** in `SKILL.md`: think before coding, simplicity first, surgical changes, and goal-driven execution.
- **Phase 0 intent clarity check** before side effects: ask when interpretations would change behavior; otherwise record assumptions and convert the request into pass/fail criteria.
- **Phase 1 issue template hooks** for assumptions/tradeoffs, traceability of changed lines, and explicit no-scope-creep language.
- **Phase 2 implementer guardrails** passed to spawned agents: no silent assumptions, no speculative abstractions/config/deps/flags, plan steps include verification checks, and self-review must confirm simplicity + surgical scope.
- **Phase 3 review criteria** for speculative complexity, drive-by edits, and changed lines that do not trace to the task.
- **Anti-pattern entries** for silent assumptions, weak goals, speculative abstractions, drive-by cleanup, and untraceable changes.

### Changed
- README now calls out the behavioral guardrails as a core differentiator.
- Troubleshooting branch-normalization wording now references Phase 4.0, matching the current flow.

### No breaking changes
Prompt-only tightening. Existing `.claude/do/config.json` files, metrics JSONL shape, branch naming, and final announce format are unchanged.

## [0.3.3] — 2026-05-09

Patch release. Adds explicit model-usage visibility so users see (and metrics record) which model handles which role per task.

### Added
- **Phase 0 announce now includes `Models:` line** — `Models: orchestrator=opus | implementer={haiku|sonnet|opus}`. Implementer auto-derived from complexity (T→haiku, L/M→sonnet, H→sonnet); appended `(override)` when `--implementer=X` flag was passed.
- **Phase 2 spawn announce** — before invoking the implementer Sub-Agent, prints `[Phase 2] Spawning Agent(model: "<X>") in <worktree> on branch <branch>`. For High-complexity plan-review with specialists: prints the parallel-spawn list of `subagent_type` strings.
- **Phase 3.6 specialist roster announce** — before invoking audit specialists, prints the cycle number + count + list of `subagent_type` strings being invoked in parallel.
- **Phase 4.13 announce now includes `Models:` line** — `Models: orchestrator=opus, implementer=sonnet, specialists=[...]`. Provides full audit trail of which models touched the task.
- **Metrics entry `models` block** — new field in Tier 1 schema:
  ```json
  "models": {
    "orchestrator": "opus",
    "implementer": "sonnet|opus|haiku",
    "specialists": ["backend-development:backend-architect", "..."]
  }
  ```
  Enables downstream analysis like "did Haiku tasks have higher false_positive rate than Sonnet?", "which specialist combos correlate with longer review cycles?", etc.

### Why
Skill design routes work across three models (Opus/Sonnet/Haiku) plus optional plugin-provided specialists. Until v0.3.3 this was implicit — user had to read CHANGELOG / spec to know what spawned where. Now every spawn is visible at the moment it happens.

### No breaking changes
Output additions only; existing announce parsers (looking for `Metrics:` line) still work — `Models:` line precedes `Metrics:` but doesn't shadow it.

## [0.3.2] — 2026-05-09

Patch release. Closes the remaining gap from v0.3.1 after learning the actual production execution model.

### Context

User clarified: skill is invoked from a **parent Claude Code session that uses Task tool to spawn sub-agents** with `isolation: "worktree"`. User confirms each spawn manually. The spawned agent runs the entire skill flow start-to-finish and returns. There is no "Opus parent picks up after Sub-Agent reports done" — the spawned agent IS the orchestrator and implementer.

### Why v0.3.1 framing was wrong

v0.3.1's Phase 2 prompt addressed "Opus orchestrator" expecting a parent that finalizes after sub-agent. In the actual execution model, the spawned agent reads "you (Opus) MUST run Phase 4.13 after Sub-Agent reports done" and rationalizes: "I'm the sub-agent, the Opus parent will do this" — except there is no Opus parent that returns to do that. So the step gets skipped.

### Fixed

- **Phase 2 prompt template framing fixed**: critical Phase 4 reminders now address "whoever is currently executing this skill flow — whether you are the spawned agent doing everything yourself, or a parent orchestrator". Explicit: "if you're reading this, you are the executor". No more deferring to a non-existent parent.
- **Phase 4.13 procedure now includes Phase 4.0.5 pre-emit sanity check**: capture `wc -l` of `$LOG_PATH` BEFORE the append (`PRE_COUNT`), then verify after the append that `POST_COUNT - PRE_COUNT == 1`. If delta isn't exactly 1, set `METRICS_LINE="Metrics: APPEND FAILED — pre=X post=Y delta=Z expected=1"`. Catches silent corruption (disk full, permission flip mid-write, file lock, etc.) that would otherwise return exit 0 but write nothing.
- **Anti-pattern 31a updated**: explicitly mentions execution-model framing — "applies whether you are the spawned agent doing everything yourself, or a parent orchestrator — there's no 'the other one' to defer to; if you're reading this, you are the executor."

### Real-world test

In a fresh `+++` task on a project with `metrics.log_path` configured, the final assistant message MUST end with one of:
- `Metrics: <N> entries in <path>.` — success
- `Metrics: APPEND FAILED — pre=X post=Y delta=Z expected=1.` — write succeeded but delta wrong (silent corruption)
- `Metrics: APPEND FAILED — write error to <path> (exit N).` — write failed
- `Metrics: not configured (set config.metrics.log_path to enable).` — feature disabled

If the final message ends with PR-summary prose and no `Metrics:` line at all, the bash procedure was skipped — that's now provably the wrong path because the procedure literally generates the entire announce text. Free-form prose announce should be impossible.

## [0.3.1] — 2026-05-09

Patch release. Fixes two systematic Phase 4 escapes observed in real production runs:
1. **Phase 4.11 metrics emission consistently skipped** despite "MANDATORY" labels, even with `disable-model-invocation` removed in v0.3.0. Sub-agents/Opus orchestrator open the PR, write a detailed PR-summary prose, then stop — never appending JSONL.
2. **Phase 4.1.0 branch rename rationalized away** when worktree was pre-spawned by Claude Code's harness. Sub-agent observed mismatch (`claude/<adj>-<noun>-<hash>` vs `feat/i{N}-{slug}`) and explicitly chose NOT to rename, citing "the worktree was pre-spawned" as exception — even though `git branch -m` works fine on pre-spawned worktrees.

Both bugs are the same class: **soft instructional enforcement fails when the agent treats steps as ceremony**. v0.3.1 replaces soft enforcement with structural coupling.

### Changed
- **Phase 4.13 final-announce is now a single bash procedure that EMITS METRICS AND PRINTS ANNOUNCE in one block**. Announce text references `$METRICS_LINE` shell variable that's set ONLY by the metrics-append step. You cannot produce the announce without running the emit. If the announce comes out without the `Metrics: ...` line, the procedure was skipped (free-form prose written instead). Hard structural coupling, not soft instruction.
- **Phase 4.0 (renamed from 4.1.0, moved up)**: branch normalization runs BEFORE Phase 4.2 PR creation. PR opens on the correct `feat/i{N}-{slug}` branch from the start, not `claude/...`. Eliminates the "PR is on auto-name; would have been i{N}-{slug} but" rationalization.
- **Pre-spawned worktree is NOT an excuse**: Phase 4.0 spec explicitly states the rename is UNCONDITIONAL. Worktree path is fine to keep; branch must follow `config.naming` for `i{N}`-traceability across commits/PRs/metrics/tracker comments.
- **Phase 2 sub-agent prompt template**: Phase 4 critical reminder pinned at the TOP of the Rules section (was buried at the end). Sub-agent's first instruction is "When this Sub-Agent reports done, you (Opus) MUST run the Phase 4.13 final-announce bash procedure verbatim..." — orchestrator gets the reminder at session-start context, not at end-of-task when it's already forgotten.

### Anti-patterns strengthened
- **31a (skip metrics emission)**: now points at the bash-coupling solution. Says: "if your final assistant message ends with PR-summary prose and NO `Metrics: ...` line, you skipped the procedure — go back and run the bash flow verbatim instead of composing prose announce."
- **31c (auto-named branches)**: now points at Phase 4.0 (BEFORE PR open) instead of 4.1.0 (after). Explicitly forbids the "pre-spawned worktree" rationalization.

### Top-level anti-patterns in SKILL.md updated
Two new entries surfaced to the top-level visible list:
- "Final assistant message ends with PR-summary prose and NO `Metrics: ...` line" (you skipped Phase 4.13 procedure)
- "Auto-named branches without `i{N}` for M/H" — now references Phase 4.0 (BEFORE PR) and explicitly disqualifies pre-spawn excuses

### Background
v0.3.0 removed `disable-model-invocation: true` to enable `+++` shortcut. We expected Phase 4.11 enforcement to hold via the strict description language. Real production runs showed it doesn't — sub-agents read all the right instructions but skip the final emit step because by the end of a long flow it feels ceremonial.

The pattern of failures (consistent across multiple sessions, regardless of caveman compression directive specifics) confirmed instructional enforcement is insufficient. v0.3.1 ships structural enforcement: the announce text physically depends on the metrics-emit shell variable. If sub-agent skips the emit, the announce literally can't be composed. Test in a fresh session: if the final message ends with `Metrics: <N> entries in <path>.`, the procedure ran. If the final message is free-form prose ending with PR-summary, it didn't.

## [0.3.0] — 2026-05-09

Minor release. Restores `+++` shortcut by removing `disable-model-invocation: true` and replacing the hard architectural guard with a strict-description soft guard.

### The trade-off

Third-pass audit (in v0.2.0) added `disable-model-invocation: true` because the skill performs side effects (issues, commits, pushes, PRs, optional auto-merge) and shouldn't auto-trigger from description matching mid-conversation. **The flag was correct** — it's defense-in-depth.

But the same flag also blocks Skill-tool invocations routed through a `+++` CLAUDE.md trigger. Verified with claude-code-guide: Claude Code currently has **no CLI-level prompt-rewrite mechanism** (`UserPromptSubmit` hook only supports adding context or blocking, not replacement). So with the flag set, `+++` simply cannot work — only `/do <task>` does.

v0.3.0 picks ergonomics over the hard guard:
- **Removed**: `disable-model-invocation: true` from frontmatter
- **Replaced with**: strict description language — `TRIGGER ONLY when the user's message LITERALLY starts with /do, /<plugin>:do, or +++`. `NEVER auto-trigger from description matching, perceived task fit, or conversational context, EVEN IF a coding task otherwise matches every other criterion.`
- **Result**: `+++` shortcut works; risk of false-positive description-match auto-trigger goes from "architecturally impossible" to "depends on Claude respecting the strict description". In practice Claude is good at respecting clear "ONLY when... NEVER..." rules; in pathological cases it could still misfire.

### What if I want the hard guard back?

Edit your local `~/.claude/skills/do/SKILL.md` (or `~/.claude/plugins/.../skills/do/SKILL.md`) and re-add `disable-model-invocation: true` to the frontmatter. You'll lose the `+++` shortcut. Document this trade-off in your team's onboarding so people know `/do <task>` is the only invocation in your setup.

### Changed
- **`skills/do/SKILL.md` frontmatter**: removed `disable-model-invocation: true`. Description rewritten with explicit "TRIGGER ONLY when LITERALLY starts with..." + "NEVER auto-trigger" language as soft guard. HTML comment under frontmatter explains the trade-off and the reason the flag was removed (CC harness lacks CLI-level prompt rewriting).
- **`install.sh`**: TRIGGER feature restored (was removed in v0.2.4 because the trigger didn't work). New installs get `+++` block in `~/.claude/CLAUDE.md` again. Marker-wrapped for clean uninstall.
- **`install.sh` Step 6**: legacy-cleanup branch (v0.2.4 behavior) replaced with trigger-setup branch (v0.2.0 behavior, but for a now-working trigger).
- **`README.md`**: removed broken "Why no `+++` shortcut via CLAUDE.md" + "Shortcut setup (CLI hook)" sections. Restored `+++` shortcut documentation in plugin install + manual install paths. Top example now shows both `/do` and `+++` forms. New Troubleshooting entries: "`+++` doesn't trigger anything" (check the trigger block in CLAUDE.md), "Worry about auto-trigger from description match" (re-add the flag for hard guard, lose the shortcut).
- **`.github/workflows/lint.yml`**: frontmatter check updated. Now ASSERTS `disable-model-invocation` is NOT set (or false), and that description contains "TRIGGER ONLY" + "NEVER auto-trigger". Locks in the v0.3.0 design — preventing accidental re-introduction of the flag without also removing the trigger feature.

### Migration for v0.2.4–v0.2.5 users

Re-run `install.sh` — it will write the `+++` trigger block to `~/.claude/CLAUDE.md` (which v0.2.4 cleanup may have stripped). Or add the marker-wrapped block manually:

```md
<!-- senior-by-default:trigger:start -->
## +++ Trigger

When a user message starts with `+++`, treat everything after `+++` as the argument and invoke the `/do` skill with that text. This is a shorthand — `+++ add user avatars` is equivalent to `/do add user avatars`.
<!-- senior-by-default:trigger:end -->
```

For plugin install users: replace `/do` with `/senior-by-default:do` in the block.

### Lessons from this whole arc (v0.2.0 → v0.2.5 → v0.3.0)

1. **Audit recommendations need end-to-end re-test of all documented entry points.** v0.2.0 added `disable-model-invocation` (correct fix for stated risk) but broke the documented `+++` flow. Caught only when a real user (the author) tried `+++` after the changes shipped.

2. **CI shellcheck on install.sh actually catches things.** v0.2.5 hot-fix happened in 5 minutes because shellcheck pinpointed the bad backtick on the right line.

3. **README that documents non-existent features is worse than missing docs.** v0.2.4 invented a "UserPromptSubmit hook that rewrites prompts" that Claude Code doesn't support. Removed in v0.3.0. Fix: verify any "PRs welcome" / "you can do X" claim against actual API docs before shipping.

4. **Hard guards (architectural) are stronger than soft guards (instructional).** v0.3.0 trades hard for soft for ergonomic reasons. That's the author's call as the primary user; teams with stricter security postures should keep the hard guard.

## [0.2.5] — 2026-05-09

Hot-fix for v0.2.4 — install.sh syntax error caught by CI shellcheck immediately after release.

### Fixed
- **`install.sh:219`**: `log "Kept legacy block. It does nothing — \`/do <task>\` works regardless."` — backticks inside double quotes triggered shell command substitution. shellcheck SC1073/SC1072 errors. Fix: switched to single-quoted string (no interpolation, no metachar parsing). Same class of quoting bug we fixed for tracker commands in v0.2.1, in our own installer this time.

### Lesson
v0.2.4 release notes already called for "CI smoke-test that the documented invocation flow actually fires (not just `bash -n` syntax check)". Shellcheck on install.sh is part of that. v0.2.4 added shellcheck to CI in v0.2.0 — and it caught this one before any user did. Working as intended.

## [0.2.4] — 2026-05-09

Patch release. Removes a broken-by-design feature: the `+++` trigger that v0.2.0–v0.2.3 wrote into `~/.claude/CLAUDE.md` never actually worked because of `disable-model-invocation: true` on the skill (added in v0.2.0 per third-pass audit). Surfaced when a real user (the author) tried `+++` after the v0.2.0 audit fixes and got:

```
Skill do cannot be used with Skill tool due to disable-model-invocation
```

Audit passes 1-7 didn't catch it because nobody re-tested the documented `+++` flow end-to-end after the third-pass `disable-model-invocation` change. The flag (correctly) blocks ALL Skill-tool invocations — including the supposedly-explicit ones the `+++` trigger asked the model to make.

### Changed
- **`install.sh`**: TRIGGER feature removed. No longer prompts for or writes a `+++` trigger block to CLAUDE.md.
- **`install.sh`**: new Step 6 — detects legacy marker-wrapped trigger blocks from v0.2.0–v0.2.3 in `~/.claude/CLAUDE.md` and offers to strip them (default: yes). Existing users get cleaned up on next install/update.
- **`README.md`**: removed `+++` shortcut promise from plugin install section. New "Why no `+++` shortcut via CLAUDE.md" Troubleshooting entry explains the conflict. New "Shortcut setup (CLI hook)" section sketches the right way to do `+++` (a `UserPromptSubmit` hook in `~/.claude/settings.json` that rewrites `+++ X` → `/do X` at CLI level — bypasses `disable-model-invocation` because it produces a real slash-command, not a Skill-tool invocation).
- **`SKILL.md` frontmatter description**: TRIGGER line dropped `(or +++ shortcut)`.
- **`SKILL.md` notation comment**: clarifies that any shortcut mechanism MUST happen at CLI level, never via CLAUDE.md instruction asking the model to invoke the skill.
- **`CONTRIBUTING.md`**: bug-report template + smoke-test checklist now reference `/do` (not `+++`).
- **References (`stack-detection.md`, `trackers.md`)**: example invocations updated from `+++ ...` to `/do ...`.

### Migration for existing users (v0.2.0–v0.2.3 installs)

Re-run `install.sh` — Step 6 will offer to strip the dead `+++` block from your `~/.claude/CLAUDE.md`. Or remove it manually (search for `<!-- senior-by-default:trigger:start -->` … `<!-- senior-by-default:trigger:end -->`).

If you want a `+++`-style shortcut, set up the CLI hook described in README "Shortcut setup (CLI hook)" — that path works regardless of `disable-model-invocation`.

## [0.2.3] — 2026-05-09

Patch release. Bug fix in `install.sh` — env-var override path was broken in v0.2.0–v0.2.2.

### Fixed
- **`install.sh prompt()` env-var override path**: when the user ran `SKILL_NAME=do TRIGGER=+++ curl ... | bash`, `prompt()` printed its `(from $ENVVAR)` confirmation banner to **stdout** instead of stderr. `SKILL_NAME=$(prompt ...)` then captured both the banner AND the value, producing a multi-line string that failed the next-line regex validation:
  ```
  ✗ Skill name must be lowercase alphanumeric with - or _ (got 'Skill name (becomes /do slash-command): do (from $SKILL_NAME)
  do')
  ```
  Interactive path was unaffected because that branch already wrote to `>&2`. Audit passes 1-6 didn't catch it because no pass exercised the `curl ... | bash` env-var path end-to-end.

  Fix: redirect the env-var override `printf` to `>&2`, matching the interactive branch. Added a code comment explaining why all user-facing prints in `prompt()` MUST go to stderr (only the value goes to stdout).

  Verified: `SKILL_NAME=mysuperskill prompt ...` now captures cleanly; subsequent regex validation passes; full `install.sh` env-var-override flow runs end-to-end on a clean machine.

## [0.2.2] — 2026-05-08

Patch release. Companion-skill integration with [caveman](https://github.com/JuliusBrussee/caveman) — additive, opt-in, no schema or behavior changes for existing configs.

### Added
- **Companion skill: caveman integration** — Phase 0.0.3 detects whether caveman is installed and announces its activation status. Caveman's SessionStart hook compresses agent output ~75% via "caveman speak" while preserving technical accuracy; once active, all Sub-Agent spawns from Phase 2 inherit compressed mode.
  - **Phase 2 Sub-Agent prompt template** now includes a conditional caveman-style directive (only when Phase 0.0.3 detected caveman as ACTIVE). Critically distinguishes natural-language framing (compress freely) from structured output — code, paths, JSON, diffs, `claimed_status: ready` self-review block, Phase 4.11 metrics JSONL, and final announce format MUST stay LITERAL because downstream tooling parses them.
  - **`--no-caveman`** override flag for per-task opt-out.
  - **README**: new "Recommended companion: caveman (install FIRST)" section above the Phase 3 plugins list. Explains why install order matters (SessionStart hook fires at session boot — installing caveman after senior-by-default requires session restart).
  - **Anti-pattern 31e**: skipping Phase 0.0.3 when caveman is installed.
  - **Anti-pattern 31f**: compressing structured output (would break Phase 4.11 metrics calibration parsing).

## [0.2.1] — 2026-05-08

Patch release. Security follow-up after sixth-pass audit found a bypass in v0.2.0's shlex-quote fallback for legacy string-form tracker commands.

### Security (audit sixth pass)
- **Schema-reject string-form `commands.<op>` containing `{title}` or `{labels}`**. The v0.2.0 `shlex.quote` fallback was insufficient when the template wraps the placeholder in `"..."` (the natural shape of `--title "{title}"`): a `"` inside user-supplied title content closes the surrounding quote regardless of how the substituted value is escaped. Reproducible exploit:
  - template: `--title "{title}"`
  - title from `$ARGUMENTS`: `x" --milestone 5 --label injected "y`
  - after `shlex.quote`: `'x" --milestone 5 --label injected "y'`
  - naive substitution: `--title "'x" --milestone 5 --label injected "y'"`
  - shell parses → `--title 'x · --milestone · 5 · --label · injected · y'` (six argv elements; injection succeeded)
  - **No text-level escape can fix this** — only argv-array form is safe.

  Fix: `config.schema.json` now has `not: { pattern: "\\{(title|labels)\\}" }` on the string variant of `trackerCommand`. String-form commands carrying user-controlled placeholders fail validation; argv-array form is required for any operation that interpolates `{title}` or `{labels}`. String form remains valid for ops without user content (`view_url`, `view_body`, `edit_body`, `comment` with body-file).

  - **`references/trackers.md`**: new subsection "Why the string form CANNOT carry user content (and is schema-rejected for it)" with the exploit and schema rule.
  - **`references/anti-patterns.md` 31d**: updated — `shlex.quote` is NOT sufficient fallback; schema enforces the constraint.

  Verified negatively: string with `{title}` rejected; string with `{labels}` rejected; string without user content (e.g. `linear issue view {N} --json | jq -r .url`) accepted; argv array with `{title}` accepted; existing 4 example configs still validate.

## [0.2.0] — 2026-05-08

Five rounds of independent audit closed. SemVer minor: additive schema changes, new opt-in features, structural reorg under `skills/do/`, security hardening of tracker execution. No breaking changes for existing user configs (legacy string-form tracker commands still validate).

### Security (audit fifth pass)
- **Shell injection via `{title}` placeholder** in tracker commands. User-controlled `$ARGUMENTS` reaches `{title}`; a malicious title (`x" --milestone 5 --label injected "y`) smuggled extra CLI flags through naive shell substitution.
  - **`references/trackers.md` rewritten** with explicit "Security: argv-safe execution is MANDATORY" section at top, including the exploit example, the env-var-based fix pattern, and argv-array form for custom trackers.
  - **Built-in `github`/`gitlab` tables** now show env-var argv-safe invocations (`gh issue create --title "$TITLE" ...`) instead of string templates with placeholder substitution.
  - **Custom trackers**: argv-array form is now the documented preferred form. String form remains for back-compat with mandatory `shlex.quote` fallback + deprecation warning.
  - **JSON Schema** `commands.<op>` now accepts either argv array (preferred) or string (deprecated) via `oneOf` in new `$defs/trackerCommand` definition.
  - **Anti-pattern 31d** added.
  - **Top-level anti-patterns in SKILL.md** updated.
  - **`phase-1-issue.md`** points readers at the secure execution pattern in trackers.md.

### Fixed (audit fourth pass)
- **Plugin examples local-path row removed from README**. Claude Code stores plugins under `~/.claude/plugins/cache/...` with versioned subdirectories that change across updates — the documented copy path was unstable. Plugin users are now directed to Option A (curl from raw.githubusercontent.com) or to clone the repo separately for local examples.
- **Custom `SKILL_NAME` no longer mutates tracked files**. Previously `install.sh` patched `skills/do/SKILL.md` in the cloned install dir, which broke `git pull --ff-only` on subsequent runs (local-changes detection skipped pull). Refactored: pristine clone is never modified; for custom names, a patched copy is regenerated on every install at `$INSTALL_DIR/.rendered-skills/<name>/` (gitignored). Symlink points at the rendered copy. Default name still symlinks straight at the pristine source — zero overhead.
- **Schema/markdown contract fully aligned on `version`**. `config-schema.md` prose now says "no fields are strictly required, `version` is *recommended*, defaults to 1 with warning, explicit mismatches hard-fail" — matches what `config.schema.json` actually does.
- **JSON Schema description rewritten** to declare the back-compat default-1 behavior explicitly, removing "all fields except version are optional" wording that contradicted the actual `required` array (empty).
- **Bonus**: `workspace` block in JSON Schema now has `required: ["is_workspace", "repos"]`. Previously empty `workspace: {}` or `workspace: {"repos":{}}` (without `is_workspace: true`) silently passed validation — fourth-pass auditor flagged this as "malformed workspace passes unexpectedly".

### Fixed (audit third pass)
- **`model: opus` pinned in SKILL.md frontmatter** — orchestrator role (Phase 0 routing, Phase 3 review, Phase 4 decisions) now runs on Opus regardless of session model. Previously the skill ran on whatever active session model the user had, so a Sonnet session silently downgraded "Opus reviews" to Sonnet reviewing itself.
- **`disable-model-invocation: true` added** — skill creates issues, commits, pushes, opens PRs, optionally auto-merges. Must not auto-discover from description matching mid-conversation; only fires on explicit `/do` or `+++`.
- **Configure-your-project section in README rewritten** — install-agnostic curl variant for any install path; lookup table for plugin / manual-symlink / custom-clone install dirs. Old `cp ~/.claude/skills/do/../../examples/...` only worked for default symlink install.
- **CI frontmatter check tightened** — now asserts `model: opus` and `disable-model-invocation: true` are present (locks in the design decisions).

### Fixed (audit second pass)
- **Plugin install slash-command** documented correctly in README: `/senior-by-default:do` (plugin namespace) vs `/do` (manual symlink). Was: README implied `/plugin install` registers `/do`, which would mislead plugin-path users.
- **JSON Schema `version` no longer required** — matches the documented backcompat behavior in `config-validation.md` (missing version → default 1 + warn). Was: schema hard-failed configs that markdown said were valid.

### Changed (post-audit)
- **Restructured to plugin format**: `SKILL.md` and `references/` moved under `skills/do/`; added `.claude-plugin/plugin.json` manifest. Enables `/plugin install` distribution path.
- **`SKILL.md` frontmatter**: switched from prose blob to `TRIGGER:`/`SKIP:` format per Anthropic skill conventions; added `version: 0.1.0`.
- **README**: example-first lead, then tagline. Install order: plugin install → manual symlink → curl-pipe (last, with "review the script" warning). Added security/permissions section.
- **`config.schema.json`**: full JSON Schema (draft 2020-12) for programmatic validation. CI validates all examples against it.
- **`config-schema.md` + `config-validation.md`**: documented relative-path resolution (relative to config.json's dir, not CWD); `version` default-to-1 behavior with warning instead of hard-fail.
- **`stack-detection.md`** + Phase 0.2: cache verification now compares `cache.repo_path` against current repo (guards slug collision for `/foo/work-api` vs `/foo/work/api`).
- **Phase 0.3 concurrent-edit check**: now runs `git fetch origin main` first (was reading stale local ref).
- **`postmortem` defaults documented**: trigger keywords + branch prefixes listed in config-schema prose.
- **Notation section** added to `SKILL.md`: `Agent(model: ...)` shorthand explained for adopters reading source.
- **Pseudocode unification**: bash-first reference implementations (slug rule, etc.).
- **Markdown table escaping**: `--complexity=T\|L\|M\|H` no longer breaks GitHub rendering.

### Added (post-audit)
- `.github/workflows/lint.yml` — shellcheck + JSON validate + frontmatter check + markdown-link sanity.
- `uninstall.sh` — symlink removal, marker-aware trigger-block stripping from `~/.claude/CLAUDE.md`, optional cache/metrics/install-dir purge.
- `install.sh`: marker-wrapped trigger blocks (`<!-- senior-by-default:trigger:start/end -->`), local-changes detection before pull, fail-fast on hard deps (git/python3), warn on soft deps (jq/gh).

### Fixed (post-audit)
- Broken links in `SKILL.md` and `config-schema.md` to renamed `examples/multi-repo-go-react-config.json` (was `lea-config.json`).
- Self-referential link in `phase-4-finalize.md` (`references/notifications.md` → `notifications.md`).

## [0.1.0] — 2026-05-08

Initial public release.

### Architecture
- **Three-actor pipeline**: Opus (architect/reviewer), Sonnet (implementer), Haiku (trivial mechanical changes). Strict role boundaries enforced via SKILL.md rules and Phase 2 prompt construction.
- **Complexity routing**: Trivial / Low / Medium / High auto-detected from `$ARGUMENTS` + file count + scope, with `--complexity=` override flag.
- **Progressive disclosure**: SKILL.md (~250 lines) loads phase-specific references on demand; total ~2000 lines of documentation across 14 reference files.

### Phases
- **Phase 0 — Setup & routing**: config discovery + validation, stack detection (cached per repo), duplicate / concurrent-edit / migration checks, complexity assignment.
- **Phase 1 — Issue creation** (M/H): structured body with acceptance criteria, build checklist, worktree-setup commands; tracker-agnostic command templates.
- **Phase 2 — Implementation**: worktree pre-created by Opus (no `Agent(isolation: "worktree")`); Sonnet self-review with `claimed_status` declaration; stale-main check; ADR generation for High complexity.
- **Phase 3 — Code review**: gates for PR-size, dependency vulns, public-docs, tests, UI (Claude Preview), i18n, contract (BE↔FE types); Low diff-scan; specialist parallel audit (High); Opus acceptance-criteria check.
- **Phase 4 — Finalize**: branch verification, commit + push, PR creation, optional CI gate, optional auto-merge, context-doc update, mandatory metrics emission.

### Stack support
- Auto-detection: Go / TS / JS / Rust / Python / Ruby / PHP / Dart-Flutter / JVM / .NET / Deno / Elixir.
- Multi-stack monorepos: subdir-scan up to depth 3 when root has no markers (handles `apps/`, `services/`, `App/`, etc.).
- Package manager detection from lockfiles for JS ecosystem.

### Trackers
- Built-in: `github` (gh CLI), `gitlab` (glab CLI), `none`.
- `custom` type with command templates for Linear, Jira, internal trackers.
- Cross-repo close-keyword logic (Closes vs Refs).

### Distributed-team practices
- CODEOWNERS-aware specialist routing in Phase 3.6.
- Zero-downtime migration audit checklist (forbidden ops: DROP/RENAME/NOT NULL-without-default; expand-contract pattern).
- ADR generation for High-complexity architectural decisions.
- PR-size guards (warn at 800 lines / 20 files; block at 2000 / 50).
- Stale-main detection with optional auto-rebase.
- Sonnet self-review with calibration metric (`accurate` / `false_positive` / `false_negative`).
- Opt-in: CI gate, auto-merge, async notifications (Slack/Teams), feature flags, WIP limits.

### Metrics (Tier 1)
- JSONL append per task to `config.metrics.log_path`.
- Captured: phase durations, gate failure details, self-review calibration, specialist iterations with file:line citations, branch_rename flags, outcome, blocked_reason.
- **Mandatory emission** when `metrics.log_path` configured — final announce verifies append succeeded.

### Anti-patterns
- 42 documented anti-patterns across general process, memory/context, git, code, distributed-team practices.
- Pre-finalize sanity check loads `references/anti-patterns.md`.

### Configuration
- 4 example configs: minimal (single-repo + GitHub), multi-repo Go+React, Python+FastAPI+Alembic, Rust workspace + GitLab.
- Validation rules in `references/config-validation.md`.
- All features opt-in or skip-by-default; out of the box you get build/test/lint enforcement, self-review, PR-size guards, concurrent-edit warnings.

### Known limitations
- Tier 1 metrics schema may evolve; entries don't yet have schema version field.
- No `/do-review` companion skill yet for automated metrics analysis (Tier 2 — planned after data accumulates).
- `Agent(isolation: "worktree")` shortcut by Opus is hard-forbidden but enforcement relies on Phase 4.1.0 branch-rename fallback when violated.
