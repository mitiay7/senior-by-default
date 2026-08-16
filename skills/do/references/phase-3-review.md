# Phase 3 — Code Review

## Metrics capture (Tier 1)

If `config.metrics.tier >= 1`, every gate that doesn't PASS must populate a `details` block for the metrics entry (see [`phase-4-finalize.md`](phase-4-finalize.md) §4.11). Capture happens **inline at the moment of detection** — don't try to reconstruct after the fact.

Gate keys land in the metrics entry under a **controlled vocabulary** (canonical names like `pr_size`, `dep_vuln`, `test`, `ui_gate`, `i18n`, `contract`, `diff_scan`, `specialist_audit`, `opus_review`); the `metrics-append` wrapper normalizes synonyms automatically, so capture with whatever name is natural and let the wrapper canonicalize. Full list + alias map: [`phase-4-finalize.md`](phase-4-finalize.md) §4.11 "Gate vocabulary".

Per gate, on failure / warning, capture:

| Gate | `details` shape |
|---|---|
| 3.0 PR Size | `{ "lines": <int>, "files": <int>, "thresholds_breached": ["lines"\|"files"\|both]` + when the wrapper reported a `generated excluded:` clause `, "generated_lines": <int>, "generated_files": <int>` (`lines`/`files` stay the **counted** handwritten numbers the verdict used) + on BLOCK-with-auto-split `, "auto_split": { "parts": <k>, "branches": [...] }` (parts/branches filled by Phase 4.2) `}` |
| 3.0.5 Dep Vuln | `{ "scanner": "<tool>", "findings": [{"severity","package","id"}], "threshold": "<level>" }` (cap at 10 findings; rest as `"truncated_count"`) |
| 3.0.6 Public Docs | `{ "api_files_changed": [...], "missing_docs": [...] }` |
| 3.1 Verify | per key `build`/`lint`/`test`: `{ "tell": "<that leg's per-command wrapper line(s), verbatim>" }`; on fail add `"failing_cmd"`, `"rc"`, `"self_report_mismatch": true\|false`; coverage misses add `"uncovered_branching_funcs": [...]` under `test` |
| 3.2 UI | `{ "broken_pages": [...], "console_errors": [first 5], "skip_reason": "<if skipped>" }` |
| 3.3 i18n | `{ "unwrapped_count": <int>, "unwrapped_samples": [{"file","line","text"}] (max 5), "locale_drift": {"<file>": ["missing keys"]} }` |
| 3.4 Contract | `{ "mismatches": [{"endpoint","field","be_type","fe_type"}] }` |
| 3.5 Low Diff Scan | `{ "issues": [{"category","file_line","summary"}] }` |
| 3.7 Opus Review | `{ "criteria_failures": [{"criterion","reason"}] }` |

Also record `fix_cycle` per gate — `0` if passed first try, `1`/`2`/`3` for which cycle resolved it.

For 3.6 Specialist Audit: accumulate `specialist_iterations` array (one entry per review cycle). Each entry: `{ cycle, auditors, approvers, blockers: [{ agent, category, file_line, summary }] }`.

All strings truncated to `config.metrics.max_string_length` chars. Captured data is **for the metrics log only** — it doesn't affect blocking decisions or output to the user.

## Gate applicability matrix

| Gate | Triggers when |
|---|---|
| 3.0 PR Size Guard | always (`config.pr_size`, defaults shown in schema) |
| 3.0.5 Dep Vuln Scan | `config.security_scan.enabled` (default true) |
| 3.0.6 Public Docs Check | `config.public_docs_dir` set AND diff modifies public API surface |
| 3.1 Build/Test Verify | always (build + lint legs; test leg only if Tests: YES) |
| 3.2 UI Gate | `config.ui_gate` set AND diff contains files matching `cache.ui_extensions` |
| 3.3 i18n Gate | `config.i18n` set AND diff contains UI files |
| 3.4 Contract Gate | diff contains BOTH backend (.go/.rs/.py API handler files) AND TS API type files |
| 3.5 Low Diff Scan | Low complexity only — full path in [`phase-3-low.md`](phase-3-low.md) (Low loads that file instead of this one) |
| 3.6 Specialist Audit | High complexity AND `config.specialists.{backend_audit|frontend_audit|migration_audit}` set OR `config.codeowners` provides agent_map |
| 3.7 Opus Review | Medium / High |

All applicable gates must PASS before 3.6 / 3.7 — **except a `pr_size` BLOCK when auto-split is armed** (§3.0 below): the size verdict gates *delivery*, not *review*, so 3.6 / 3.7 still run on the full diff and the change is reviewed once as a unit before Phase 4.2 splits it into a stack of sub-cap PRs.

## 3.0 PR Size Guard — **decision comes from the `pr-size-check` wrapper, NOT your judgment**

Run the wrapper against the worktree — it measures the diff itself. Do NOT eyeball the numbers and decide PASS/WARN/BLOCK yourself, and do NOT hand it counts you computed: production shipped **8 PRs >2000 lines as `pr_size=warn`** because the orchestrator read "block → STOP" and treated it as advisory (anti-patterns §19f / §21). The wrapper owns both the measurement and the decision; **BLOCK exits 3 (a hard halt)**, so it cannot be narrated past.

**The warn caps come from the run's own tier (v0.13.0).** `--tier "$COMPLEXITY"` makes the amber threshold the same budget Phase 2.0 approved the plan against (T 2f/50L · L 3/200 · M 8/600 · H 25/1500 — `plan-size-check`'s buckets). Before this the caps were flat 800/20 for every tier, which sat *below* the H bucket's own 1500-line cap: an H plan that legitimately PASSED §2.0 at 1400 lines was **guaranteed** to WARN at §3.0 for being exactly the size it was authorized to be. Telemetry across 93 runs: `pr_size` warned on 43 of 86 — 80 % of all H runs — so amber meant nothing, and `calibration_size` (which scores the self-review's size prediction *against this gate*) sat at 53 %, a coin flip. WARN now states one interpretable fact: **the delivered diff exceeded the budget its own plan was approved against.** Block caps are unchanged and deliberately tier-independent — "unreviewable as one PR" is a property of the diff, not of the tier that produced it. A project that sets `config.pr_size.warn_lines`/`warn_files` still wins over the tier bucket; the verdict line names which source it used (`[warn caps: tier H]`).

**Generated artifacts don't count as handwritten code.** A repo that commits machine-generated files — `openapi/*.json`, `*.pb.go`, snapshots — sets `config.pr_size.generated_paths` (glob list) and the wrapper subtracts those paths from the counted lines/files. Nobody reviews them line by line; a drift check in CI keeps them honest, so counting them measures the wrong quantity and pushes the repo into serial threshold bumps (the lea-api ledger: 2000→3000→4000→4500 across one epic, every bump caused by generated files). The excluded volume is **always printed** next to the counted volume (`900 handwritten + 1200 generated = 2100 total lines`) — hiding it would hide "the generator produced a 40k-line diff". The list lives only in the repo's committed config; there is no per-run flag, so this is not a way to talk a BLOCK down.

**BLOCK → auto-split by default (v0.11.0).** A BLOCK verdict means the change cannot ship as ONE PR. It is *never* downgraded to a single mergeable PR. But the default response is no longer "halt and ask the user to split" — it is to **split automatically in Phase 4.2** into a stack of individually-reviewable, sub-cap PRs (via the `pr-split` wrapper). Resolve `CFG_AUTO_SPLIT` from `config.pr_size.auto_split` (default `true`); `--no-split` in `$ARGUMENTS` or `auto_split:false` reverts to the pre-0.11 hard halt (draft PR + `blocked`, user splits manually). Auto-split sets `PR_SPLIT_REQUIRED=1` and **continues** the rest of Phase 3 on the full diff — it does NOT set `BLOCKED`, because the run ends `ready_for_review` with *k* open PRs, not blocked.

```bash
# Do NOT pre-compute the numbers here. `--repo` hands the wrapper the repo and
# the base ref; IT resolves the refs, runs `--numstat`, reads the project's
# `.claude/do/config.json` (thresholds AND `pr_size.generated_paths`) and
# decides. The PreToolUse hook calls the same mode with the same repo, so the
# two enforcement tiers cannot disagree on the same diff — the WARN-here /
# BLOCK-there split that a hook-only or wrapper-only exclusion would produce.

# Canonical do-scripts resolver — identical line in every wrapper block; each
# block runs in a fresh shell, so re-resolve here (rationale: phase-0-setup.md Step 1).
DO_SCRIPTS="$(find -L ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT/skills"} "$HOME/.claude/skills" "$HOME/.claude/plugins/cache" "$HOME/.local/share/senior-by-default/skills" -maxdepth 7 -type f -name metrics-append -path '*/scripts/*' 2>/dev/null | head -1)"; DO_SCRIPTS="${DO_SCRIPTS%/metrics-append}"

# Pass config.pr_size.* ONLY when the project overrides the defaults; the wrapper
# bakes in the config-schema.md defaults (warn 800/20, block 2000/50) otherwise.
#
# Optional flags go through an ARRAY, never `${VAR:+--flag "$VAR"}`: that idiom
# needs the shell to word-split the expansion — bash does, **zsh does not**, and
# under zsh it collapses flag+value into ONE argv token (`--warn-lines 800`), which
# every wrapper rejects as an unknown arg. add_opt behaves identically under bash
# and zsh, skips unset/empty values, and keeps values containing spaces intact.
PR_SIZE_ARGS=()
add_opt() { [ -n "${2:-}" ] && PR_SIZE_ARGS+=("$1" "$2"); return 0; }
# The ROUTED tier (post-rebump — if Phase 2.0 re-bumped M→H, the H budget is the
# one this diff was authorized against). Warn caps come from it unless the
# project overrides them below.
add_opt --tier        "${COMPLEXITY:-}"
add_opt --warn-lines  "${CFG_WARN_LINES:-}"
add_opt --warn-files  "${CFG_WARN_FILES:-}"
add_opt --block-lines "${CFG_BLOCK_LINES:-}"
add_opt --block-files "${CFG_BLOCK_FILES:-}"

if [ -x "$DO_SCRIPTS/pr-size-check" ]; then
  PR_SIZE_LINE="$("$DO_SCRIPTS/pr-size-check" \
    --repo "$WORKTREE_PATH" --base main \
    ${PR_SIZE_ARGS[@]+"${PR_SIZE_ARGS[@]}"})" && PR_SIZE_RC=0 || PR_SIZE_RC=$?
else
  # FAIL CLOSED — explicit token so the case below has a matching arm.
  PR_SIZE_LINE="Phase 3.0: GATE ERROR — pr-size-check wrapper not found (do-scripts resolver found no install)"; PR_SIZE_RC=127
fi
echo "$PR_SIZE_LINE"

case "$PR_SIZE_LINE" in
  "Phase 3.0: PASS"*)  GATE_PR_SIZE_STATUS=pass ;;                         # proceed
  "Phase 3.0: WARN"*)  GATE_PR_SIZE_STATUS=warn; PR_SIZE_NOTE="$PR_SIZE_LINE" ;;  # note in PR desc (4.2), proceed
  "Phase 3.0: BLOCK"*)                                                     # PR_SIZE_RC == 3 — cannot ship as ONE PR
    GATE_PR_SIZE_STATUS=block
    if [ "${CFG_AUTO_SPLIT:-true}" != "false" ] && ! printf '%s' "$ARGUMENTS" | grep -qw -- '--no-split'; then
      # DEFAULT: auto-split. Arm the flag and CONTINUE the rest of Phase 3 (the
      # full change is reviewed as one unit here; Phase 4.2 splits DELIVERY into a
      # stack of sub-cap PRs via `pr-split`). Do NOT set BLOCKED — outcome is
      # ready_for_review with k open PRs. gates.pr_size.status stays "block" (the
      # size genuinely blocked a single PR — telemetry stays honest); add
      # details.auto_split = { requested: true } now, parts/branches filled in 4.2.
      PR_SPLIT_REQUIRED=1
      echo "Phase 3.0: BLOCK → auto-split armed — Phase 4.2 will open a stack of sub-cap PRs; continuing full-diff review."
    else
      # OPT-OUT (config.pr_size.auto_split:false OR --no-split): the pre-0.11 hard
      # halt. Do NOT proceed to the merge gate. Same escalation path as the Phase
      # 3.6 3-cycle exhaustion:
      #   1. Push current state, create a DRAFT PR (`gh pr create --draft`, title prefixed `WIP:`)
      #   2. File follow-up split issues (~N sub-issues per the wrapper's suggested count)
      #   3. Apply the `blocked` label; comment the split proposal on the issue
      #   4. Phase 4.11 metrics: gates.pr_size.status = "block"; OUTCOME = "blocked"
      #   5. Tell user: "PR-size BLOCK: {PR_SIZE_LINE}. Draft PR: {url}. Split before merge."
      BLOCKED=true; PR_SPLIT_REQUIRED=0
    fi
    ;;
  "Phase 3.0: GATE ERROR"*)                                                # FAIL CLOSED
    GATE_PR_SIZE_STATUS=fail
    # The wrapper is unreachable — the size gate CANNOT run. Treat like BLOCK,
    # never like pass: proceeding unchecked deletes the only hard PR-size halt
    # (the exact silent-vanish this resolver exists to prevent). Do NOT eyeball
    # the thresholds yourself (§19f). STOP: surface the line to the user; fix =
    # re-run install.sh or /plugin install, then re-run Phase 3. Metrics:
    # gates.pr_size = { "status": "fail", "details": { "reason": "wrapper not found" } }.
    ;;
esac
```

**Why a wrapper, not inline threshold bash**: identical to the [plan-size-check §2.0](phase-2-implementation.md) lesson — the orchestrator reliably runs `$(wrapper)` + `case`, but reliably *fabricates* a plausible verdict from inline `if [ $lines -gt $block ]` it's told to evaluate itself. The wrapper output's `breached: [..]` list + `+N lines/+N files` overage + the trailing `| diff <base>...<head>` range are the anti-fabrication tell (all computed from the real repo); the non-zero BLOCK exit is the structural halt. Record the result in the metrics `gates.pr_size` entry: `{ "status": pass|warn|block, "details": { "lines": <int>, "files": <int>, "thresholds_breached": [...] } }` — `lines`/`files` are the **counted** (handwritten) numbers the verdict used; when the output carries a `generated excluded:` clause, add `"generated_lines": <int>, "generated_files": <int>` from it so the telemetry can tell a 900-line PR apart from a 900-line PR carrying 1200 generated lines.

> **`block` is not advisory — but the default response is auto-split, not halt.** BLOCK means the change cannot ship as ONE PR; it never downgrades to a single mergeable PR (§19f/§21). By default Phase 4.2 splits it into a **stack of sub-cap PRs** (`pr-split` wrapper) and the run ends `ready_for_review` with *k* open PRs. With `config.pr_size.auto_split:false` or `--no-split` it reverts to the pre-0.11 hard halt (draft + `blocked`; user splits manually). Either way the plan was over-budget — Phase 2.0 plan-size-check should have said SPLIT-REQUIRED earlier; auto-split is the safety net, not a licence to plan huge.

## 3.0.5 Dep Vulnerability Scan
Per `cache.package_manager`:
| PM | Command (default) |
|---|---|
| npm/pnpm/yarn | `npm audit --audit-level={threshold} --json` (or `pnpm audit --json` / `yarn audit --json`) |
| go | `govulncheck ./...` |
| cargo | `cargo audit` |
| pip / uv / poetry | `pip-audit` (preferred) or `safety check --json` |
| bundler | `bundle audit check --update` |
| composer | `composer audit --format=json` |
| dotnet | `dotnet list package --vulnerable --include-transitive` |
| pub | `dart pub outdated --mode=null-safety` (limited; supplement with manual review) |

Override per-PM via `config.security_scan.command_override_by_pm`.

Threshold (`config.security_scan.threshold`, default `high`): block at this severity or higher; warn for one level below.

Findings → return to Sonnet with the vuln list. Sonnet decides: upgrade dep, replace dep, OR add to `config.tech_debt_doc` with explicit risk acceptance + remediation deadline (only if upgrade path doesn't exist yet).

## 3.0.6 Public Docs Check
If diff modifies API signatures (handler routes, public function signatures, exported types) AND `config.public_docs_dir` exists:
- List API-affecting files: backend handlers, exported function definitions, public type declarations
- For each, check if a corresponding doc file in `public_docs_dir` was modified
- Mismatch → WARN (or BLOCK if `config.public_docs_dir.required: true`): `"Public API changed in {files} but no docs updated in {public_docs_dir}. Run before review: update docs."`

## 3.1 Build/Test Verify — **YOU re-run the checklist in the worktree; the implementer's report is NEVER the gate**

Phase 2's completion report — exit codes included — is the implementer's own testimony, and the report format asks Sonnet to write its own rc's. Adjudicating "tests pass / build passes" from that report is the §19 fabrication class one trust level down: a plausible green self-report reaches commit, push, and PR with zero independent evidence (with `auto_merge` + no CI, it reaches merged main). Re-run the checklist yourself via the `build-verify` wrapper. Cost is a duplicate of Sonnet's run — acceptable for M/H, trivial for Low's small diffs ([`phase-3-low.md`](phase-3-low.md) routes Low through this same re-run); with `config.affected_graph` the re-run is scoped to affected projects (the same commands Phase 2 ran; `--no-affected-graph` = full set). The opt-in §4.2.5 CI gate re-proves this post-push when configured — it does not replace this pre-commit re-run on the default (no-CI) path.

```bash
# Canonical do-scripts resolver — identical line in every wrapper block; each
# block runs in a fresh shell, so re-resolve here (rationale: phase-0-setup.md Step 1).
DO_SCRIPTS="$(find -L ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT/skills"} "$HOME/.claude/skills" "$HOME/.claude/plugins/cache" "$HOME/.local/share/senior-by-default/skills" -maxdepth 7 -type f -name metrics-append -path '*/scripts/*' 2>/dev/null | head -1)"; DO_SCRIPTS="${DO_SCRIPTS%/metrics-append}"

# Commands come from the stack cache (stack-detection.md). If affected-graph is
# in use per the phase-0 Step 4 predicate (tool detected + config enabled +
# --no-affected-graph absent), substitute the affected-scoped equivalents
# Phase 2 ran instead of reading the cache arrays; with --no-affected-graph
# the full cache commands run here too.
CACHE_FILE="$HOME/.claude/do/cache/{slug}.json"     # slug per stack-detection.md
VERIFY_ARGS=()
while IFS= read -r c; do VERIFY_ARGS+=(--build "$c"); done < <(jq -r '.build_cmds[]?' "$CACHE_FILE")
while IFS= read -r c; do VERIFY_ARGS+=(--lint "$c");  done < <(jq -r '.lint_cmds[]?'  "$CACHE_FILE")
# Test leg ONLY when the task is Tests: YES (gate matrix). Tests: NO → DELETE the
# next two lines; the wrapper reports test=skipped (a skipped leg is never a pass).
TEST_CMD="$(jq -r '.test_cmd // empty' "$CACHE_FILE")"
[ -n "$TEST_CMD" ] && VERIFY_ARGS+=(--test "$TEST_CMD")

if [ -x "$DO_SCRIPTS/build-verify" ]; then
  VERIFY_OUT="$("$DO_SCRIPTS/build-verify" --dir "$WORKTREE_PATH" ${VERIFY_ARGS[@]+"${VERIFY_ARGS[@]}"})" && VERIFY_RC=0 || VERIFY_RC=$?
else
  # FAIL CLOSED — explicit token so the case below has a matching arm.
  VERIFY_OUT="Phase 3.1: GATE ERROR — build-verify wrapper not found (do-scripts resolver found no install)"; VERIFY_RC=127
fi
printf '%s\n' "$VERIFY_OUT"

case "$VERIFY_OUT" in
  "Phase 3.1: VERIFY PASS"*)     # proceed — record gates.build/lint/test per the wrapper's leg statuses
    ;;
  "Phase 3.1: VERIFY SKIPPED"*)  # degraded stack (stack "other") and/or Tests: NO
    # Record gates.build/lint/test = skipped — NEVER upgrade to pass. No automated
    # verification exists for this stack; say so in the Phase 3 announce.
    ;;
  "Phase 3.1: VERIFY FAIL"*)     # VERIFY_RC == 3 — return to Sonnet (Sonnet's bug, not a review cycle)
    # 1. Hand Sonnet the wrapper's failing-command tail; re-run this block after the fix.
    # 2. Check the Phase 2 report for the SAME command: if it claimed PASS / rc=0 →
    #    set details.self_report_mismatch = true on that gate key — fabrication-class
    #    signal (anti-patterns §19h); feeds §4.11 self-review calibration.
    # 3. APPROVE requires a real VERIFY PASS line — never proceed on the old report.
    ;;
  "Phase 3.1: GATE ERROR"*)      # FAIL CLOSED — wrapper unreachable
    # Falling back to "PASS in Sonnet report" is the exact hole this gate closes.
    # STOP: surface the line to the user; fix = re-run install.sh or /plugin install,
    # then re-run Phase 3. Metrics: gates.build = { "status": "fail",
    # "details": { "reason": "wrapper not found" } }.
    ;;
esac
```

Metrics land under the **existing canonical keys** `build` / `lint` / `test` (phase-4-finalize.md §4.11 vocabulary — do not invent new ones); `details.tell` = that leg's per-command wrapper line(s) verbatim. Bypass tells (§19h): a `pass` leg with no `Phase 3.1: VERIFY` line in the transcript; a leg `skipped` while the cache has commands for it; `test` skipped on a Tests: YES task.

**Coverage rule** (unchanged — adjudicated from the diff + self-review, not from execution): every public function with branching logic gets minimum 1 happy-path + 1 error-path test. Algorithm/calculation functions also test empty input + boundary values.

If Sonnet's self-review (Phase 2.5) didn't list tests for each new branching function → FAIL with the function names that need coverage.

## 3.2 UI Gate
Requires `config.ui_gate` and UI files in diff.

1. Start infrastructure:
   - `config.ui_gate.infra_cmd` (background)
   - `config.ui_gate.dev_cmd` (background; auto-fill from `package.json scripts.dev` if not set)
   - Poll: `curl -sf {config.ui_gate.url} > /dev/null` until 200 (timeout 60s).

   Infra fails: diagnose and fix infra. Don't count as code failure.
   Unrestorable after 2 attempts: skip UI Gate, note `UI Gate: SKIPPED (infra unavailable)`.

2. Login (if `config.ui_gate.login_script` set), then navigate to verify URL.

3. For each affected page:
   - `preview_screenshot` — layout renders, no breakage
   - `preview_console_logs` — zero errors (warnings OK)
   - `preview_click` / `preview_fill` — primary interactions
   - Layout changed → `preview_resize` to 375px, 768px, 1280px
   - Custom interactive components → tab-navigate, check `aria-label` on icon-only buttons
   - Dark mode applicable → toggle, screenshot

PASS = all pages render + zero console errors + interactions work.
FAIL → return to Sonnet for fixes.

## 3.3 i18n Gate
Requires `config.i18n` and UI files in diff.

Check for hardcoded user-visible strings NOT wrapped in `config.i18n.fn`:

Check: JSX/template text content (`>Some text<`), user-visible props (`placeholder`, `title`, `label`, `alt`, `aria-label`).
Exclude: import paths, `className`, `type`/`role`/`name`/`id`/`data-*`, `console.*` args, object keys, comparison operands, URLs, date format strings, ALL_CAPS constants.

Verify all entries in `config.i18n.locale_files` have matching key sets for new keys.

Mismatch → return to Sonnet.

## 3.4 Contract Gate
For each new/modified API endpoint:

1. Read backend handler → response struct → tags (Go `json:"..."`, Rust `#[serde(rename)]`, Python `BaseModel.Config`)
2. Read corresponding frontend type. Lookup order:
   - `config.contract_gate.frontend_types_path` if set
   - Otherwise: follow imports from frontend code calling this endpoint
   - Fallback: grep the repo for response struct's JSON-tag names
3. Field-by-field: tag = TS prop; pointer/Option → `T | null` / `?`; `omitempty` → `?`; `int` → `number`; `time.Time` → `string`; `[]T` → `T[]`; `json:"-"` → must NOT appear in TS

Mismatch → list with file:line, return to Sonnet.

## 3.5 Low — Opus Diff Scan → [`phase-3-low.md`](phase-3-low.md)

The complete Low path (build-verify re-run + dep-vuln + the 11-item Opus diff-scan checklist + one fix cycle, no specialists) lives in [`phase-3-low.md`](phase-3-low.md) — **Low runs load that file INSTEAD of this one**. If you are on a Low task and reading this file, switch. Semantics are unchanged from the former inline §3.5: Low is NOT exempt from the §3.1 `build-verify` re-run (without it the Low path is self-report-only, §19h).

## 3.6 Specialist Audit (High only)

Auditor list = union of:
- `config.specialists.backend_audit` / `frontend_audit` (per scope)
- `config.specialists.migration_audit` (always, if migration exists) — auditor MUST follow [`zero-downtime-migrations.md`](zero-downtime-migrations.md) checklist
- CODEOWNERS-mapped agents per [`codeowners.md`](codeowners.md) (deduplicated, capped at 5 total)

Inputs to each auditor:
- `git diff main...HEAD`
- The approved plan (from issue comment posted in Phase 2)
- The ADR if exists (Phase 2 High)
- Phase 2.5 self-review output

Before invoking, announce the roster (visible to user — makes it clear which models/agents handle the audit and how many will run):

```
[Phase 3.6] Specialist audit cycle {N} — invoking {K} agents in parallel:
  - {subagent_type_1}
  - {subagent_type_2}
  - {subagent_type_3}
```

**Configured-but-unavailable auditor** (the Task tool rejects the `subagent_type` — plugin uninstalled since the config was written, or never installed): announce per seat — `Specialist {subagent_type}: NOT AVAILABLE — Opus inline fallback for {backend_audit|frontend_audit|migration_audit}` — and run that seat inline as **Opus** with the same inputs and the same checklist obligations (a migration seat still MUST apply the [`zero-downtime-migrations.md`](zero-downtime-migrations.md) checklist). The seat counts toward the roster `{K}` and its findings carry full blocking authority. NEVER substitute Sonnet, never drop the seat silently (audit #9 — the phantom-plugin incident surfaced downstream as "falling back to Sonnet"; auto-init now filters the preset against installed plugins, but hand-edited configs and post-init uninstalls still reach this rule).

Run in parallel.

**Plan fidelity**: reviewers verify (1) all planned files present in diff, (2) architectural patterns match plan + ADR, (3) endpoints/routes match, (4) data model matches.

Deviations: justified (auditor's reasoning satisfied) → continue. Unjustified → blocking.

**Migration audit must explicitly** apply zero-downtime checklist from [`zero-downtime-migrations.md`](zero-downtime-migrations.md) — not just "looks good".

Max 3 review cycles.

**After 3rd cycle with unresolved blocking issues**:
1. STOP — no further fix attempts
2. Push branch, create draft PR (`gh pr create --draft`), title prefixed `WIP:`
3. Comment on issue: `## Blocking Issues` with specialist citations + file paths. Apply label `blocked`.
4. Tell user: `Escalation: 3 cycles exhausted. {N} blocking issues. Draft PR for manual review: {url}`
5. Send `task_blocked` notification if configured.

## 3.7 Opus Review (Medium / High)
Acceptance criteria PASS / FAIL — check each from the issue:

- **Requirements** → each checkbox maps to diff
- **Tests pass** → §3.1 `VERIFY PASS` test leg from YOUR wrapper re-run (the Sonnet report alone is never evidence — §19h); coverage listed in self-review
- **Guard coverage** → the self-review's `guard_coverage:` tally (Phase 2.5 step 3) is present, and its `mutation-verified` count covers every new/changed condition you can see in the diff — `if`/`switch` arms, `WHERE` / `ON CONFLICT` predicates, middleware and route guards, permission / ownership / tenancy checks, retry and timeout branches, early returns, success callbacks. A guard the implementer listed as `deferred` is a **known** gap: judge it on merit. A guard present in the diff and **absent from the tally** is an unknown one — spot-check it by inverting the condition and running the named test yourself; a suite that stays green is a FAIL with criterion `guard-coverage`. This is the largest single defect class in the pipeline's history (~25 % of all criteria failures across 93 runs), which is why it is checked here and not left to the tests-pass line above.
- **Build passes** → §3.1 `VERIFY PASS` build + lint legs from the same run — rc=0 for ALL commands in Build/Lint/Test
- **No hardcoded strings** → confirmed by 3.3
- **Migration applies** → confirmed in Sonnet report; zero-downtime audit PASS
- **No regressions** → no deleted assertions/expects/requires, no removed `if err` blocks, no removed nil guards
- **Simplicity + surgical scope** → no speculative abstractions/config/deps/flags, no drive-by cleanup, every changed line traces to a requirement, acceptance criterion, or cleanup caused by this change
- **Acceptance extensions** → all matched extensions covered
- **Dep vulns** → 3.0.5 PASS at threshold
- **Public docs** → 3.0.6 PASS if applicable
- **Feature flag** → wrapped at entry point if required by config
- **Context doc** → if `required_for_finalize` and Sonnet didn't update it → BLOCKING
- **ADR** (High) → present and references the implementation

Blocking → return to Sonnet.
Non-blocking → tech-debt: GitHub issue labeled `tech-debt`, OR append to `config.tech_debt_doc`, OR write to memory. **No scope creep — log as new issue.**

**Migration amendment**: if review requires schema change → write NEW migration with a fresh UTC timestamp prefix (`date -u +%Y%m%d%H%M%S`). Never amend existing, never allocate sequentially. Note dependency in PR.

## Announce
```
[Phase 3] APPROVE after {N} cycle(s). Gates run: {list with pass/fail}. Verify: {status + "N cmds in Nms" from the 3.1 verdict line}. PR size: {lines}/{files}. Vulns: {count or clean}.
```

The `Verify:` token is carried verbatim from the `build-verify` verdict line (its cmd-count/elapsed-ms is the anti-fabrication tell) — a hand-written `Verify: PASS` with no matching `Phase 3.1: VERIFY` line in the transcript is a §19h bypass.
