# Phase 3 — Code Review

## Metrics capture (Tier 1)

If `config.metrics.tier >= 1`, every gate that doesn't PASS must populate a `details` block for the metrics entry (see [`phase-4-finalize.md`](phase-4-finalize.md) §4.11). Capture happens **inline at the moment of detection** — don't try to reconstruct after the fact.

Gate keys land in the metrics entry under a **controlled vocabulary** (canonical names like `pr_size`, `dep_vuln`, `test`, `ui_gate`, `i18n`, `contract`, `diff_scan`, `specialist_audit`, `opus_review`); the `metrics-append` wrapper normalizes synonyms automatically, so capture with whatever name is natural and let the wrapper canonicalize. Full list + alias map: [`phase-4-finalize.md`](phase-4-finalize.md) §4.11 "Gate vocabulary".

Per gate, on failure / warning, capture:

| Gate | `details` shape |
|---|---|
| 3.0 PR Size | `{ "lines": <int>, "files": <int>, "thresholds_breached": ["lines"\|"files"\|both] }` |
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
| 3.5 Low Diff Scan | Low complexity only |
| 3.6 Specialist Audit | High complexity AND `config.specialists.{backend_audit|frontend_audit|migration_audit}` set OR `config.codeowners` provides agent_map |
| 3.7 Opus Review | Medium / High |

All applicable gates must PASS before 3.6 / 3.7.

## 3.0 PR Size Guard — **decision comes from the `pr-size-check` wrapper, NOT your judgment**

Measure the actual diff, then run the wrapper. Do NOT eyeball the numbers and decide PASS/WARN/BLOCK yourself — production shipped **8 PRs >2000 lines as `pr_size=warn`** because the orchestrator read "block → STOP" and treated it as advisory (anti-patterns §19f / §21). The wrapper owns the decision; **BLOCK exits 3 (a hard halt)**, so it cannot be narrated past.

```bash
DIFF_LINES=$(git -C "$WORKTREE_PATH" diff main...HEAD --numstat | awk '{a+=$1; d+=$2} END {print a+d+0}')   # total churn (added+deleted)
DIFF_FILES=$(git -C "$WORKTREE_PATH" diff main...HEAD --name-only | wc -l | tr -d ' ')

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
add_opt --warn-lines  "${CFG_WARN_LINES:-}"
add_opt --warn-files  "${CFG_WARN_FILES:-}"
add_opt --block-lines "${CFG_BLOCK_LINES:-}"
add_opt --block-files "${CFG_BLOCK_FILES:-}"

if [ -x "$DO_SCRIPTS/pr-size-check" ]; then
  PR_SIZE_LINE="$("$DO_SCRIPTS/pr-size-check" \
    --lines "$DIFF_LINES" --files "$DIFF_FILES" \
    ${PR_SIZE_ARGS[@]+"${PR_SIZE_ARGS[@]}"})" && PR_SIZE_RC=0 || PR_SIZE_RC=$?
else
  # FAIL CLOSED — explicit token so the case below has a matching arm.
  PR_SIZE_LINE="Phase 3.0: GATE ERROR — pr-size-check wrapper not found (do-scripts resolver found no install)"; PR_SIZE_RC=127
fi
echo "$PR_SIZE_LINE"

case "$PR_SIZE_LINE" in
  "Phase 3.0: PASS"*)  GATE_PR_SIZE_STATUS=pass ;;                         # proceed
  "Phase 3.0: WARN"*)  GATE_PR_SIZE_STATUS=warn; PR_SIZE_NOTE="$PR_SIZE_LINE" ;;  # note in PR desc (4.2), proceed
  "Phase 3.0: BLOCK"*)                                                     # PR_SIZE_RC == 3 — HARD HALT
    GATE_PR_SIZE_STATUS=block
    # Do NOT proceed to the merge gate. Same escalation path as Phase 3.6 3-cycle exhaustion:
    #   1. Push current state, create a DRAFT PR (`gh pr create --draft`, title prefixed `WIP:`)
    #   2. File follow-up split issues (~N sub-issues per the wrapper's suggested count)
    #   3. Apply the `blocked` label; comment the split proposal on the issue
    #   4. Phase 4.11 metrics: gates.pr_size.status = "block"; OUTCOME = "blocked"
    #   5. Tell user: "PR-size BLOCK: {PR_SIZE_LINE}. Draft PR: {url}. Split before merge."
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

**Why a wrapper, not inline threshold bash**: identical to the [plan-size-check §2.0](phase-2-implementation.md) lesson — the orchestrator reliably runs `$(wrapper)` + `case`, but reliably *fabricates* a plausible verdict from inline `if [ $lines -gt $block ]` it's told to evaluate itself. The wrapper output's `breached: [..]` list + `+N lines/+N files` overage are the anti-fabrication tell (computed from the real numbers); the non-zero BLOCK exit is the structural halt. Record the result in the metrics `gates.pr_size` entry: `{ "status": pass|warn|block, "details": { "lines": <int>, "files": <int>, "thresholds_breached": [...] } }`.

> **`block` is not advisory.** If `pr-size-check` says BLOCK, the PR does not merge this run — it becomes a draft + `blocked` outcome and the user splits it. The plan was wrong, not the implementation (re-plan into smaller issues; Phase 2.0 plan-size-check should have caught it earlier).

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

Phase 2's completion report — exit codes included — is the implementer's own testimony, and the report format asks Sonnet to write its own rc's. Adjudicating "tests pass / build passes" from that report is the §19 fabrication class one trust level down: a plausible green self-report reaches commit, push, and PR with zero independent evidence (with `auto_merge` + no CI, it reaches merged main). Re-run the checklist yourself via the `build-verify` wrapper. Cost is a duplicate of Sonnet's run — acceptable for M/H, trivial for Low's small diffs (§3.5 routes Low through this same re-run); with `config.affected_graph` the re-run is scoped to affected projects (the same commands Phase 2 ran; `--no-affected-graph` = full set). The opt-in §4.2.5 CI gate re-proves this post-push when configured — it does not replace this pre-commit re-run on the default (no-CI) path.

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

## 3.5 Low — Opus Diff Scan
§3.1 `build-verify` re-run PASS (the wrapper, in the worktree — Low is NOT exempt; without it the Low path is self-report-only, §19h) + dep vuln scan pass + Opus scans `git diff` for:
- SQL injection / unsanitized input
- Missing error handling
- Resource leaks (DB rows, HTTP bodies, file handles, useEffect cleanup)
- Nil/undefined dereference without guard
- Unsafe type assertions (Go `x.(T)` without `ok`; TS `as T` on uncertain values)
- Race conditions (shared state without mutex, concurrent map access)
- Hardcoded user-facing strings (only if `config.i18n` set)
- Import pattern violations (per CLAUDE.md)
- Accidental secret files OR inline secrets
- Speculative abstractions/config/feature flags/dependencies not required by acceptance criteria
- Drive-by refactors, formatting churn, comment rewrites, or changed lines not traceable to the task

All clear → Phase 4. Issues → one fix cycle (no specialists). Opus describes fixes, Sonnet applies.

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
