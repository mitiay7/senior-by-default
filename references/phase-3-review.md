# Phase 3 — Code Review

## Metrics capture (Tier 1)

If `config.metrics.tier >= 1`, every gate that doesn't PASS must populate a `details` block for the metrics entry (see [`phase-4-finalize.md`](phase-4-finalize.md) §4.11). Capture happens **inline at the moment of detection** — don't try to reconstruct after the fact.

Per gate, on failure / warning, capture:

| Gate | `details` shape |
|---|---|
| 3.0 PR Size | `{ "lines": <int>, "files": <int>, "thresholds_breached": ["lines"\|"files"\|both] }` |
| 3.0.5 Dep Vuln | `{ "scanner": "<tool>", "findings": [{"severity","package","id"}], "threshold": "<level>" }` (cap at 10 findings; rest as `"truncated_count"`) |
| 3.0.6 Public Docs | `{ "api_files_changed": [...], "missing_docs": [...] }` |
| 3.1 Test | `{ "uncovered_branching_funcs": [...], "failing_tests": [...] }` |
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
| 3.1 Test Gate | always, if Tests: YES |
| 3.2 UI Gate | `config.ui_gate` set AND diff contains files matching `cache.ui_extensions` |
| 3.3 i18n Gate | `config.i18n` set AND diff contains UI files |
| 3.4 Contract Gate | diff contains BOTH backend (.go/.rs/.py API handler files) AND TS API type files |
| 3.5 Low Diff Scan | Low complexity only |
| 3.6 Specialist Audit | High complexity AND `config.specialists.{backend_audit|frontend_audit|migration_audit}` set OR `config.codeowners` provides agent_map |
| 3.7 Opus Review | Medium / High |

All applicable gates must PASS before 3.6 / 3.7.

## 3.0 PR Size Guard
```
git -C {worktree} diff main...HEAD --shortstat
git -C {worktree} diff main...HEAD --name-only | wc -l
```

Apply `config.pr_size` thresholds:
- ≤warn → proceed
- warn < lines/files ≤ block → WARN: `"PR is {lines} lines / {files} files. Consider splitting follow-ups."`. Note in PR description.
- > block → BLOCK. Tell user: `"PR exceeds block thresholds ({lines}>{block_lines} or {files}>{block_files}). Split into N follow-up issues. Sonnet should not have produced this size — review the plan."` Push current state as draft branch, file follow-up issues with the proposed splits, do NOT proceed to merge gate.

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

## 3.1 Test Gate
Tests: YES but no PASS output → return to Sonnet for fixes (Sonnet's bug, not a review cycle).

**Coverage rule**: every public function with branching logic gets minimum 1 happy-path + 1 error-path test. Algorithm/calculation functions also test empty input + boundary values.

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
Build + tests pass + dep vuln scan pass + Opus scans `git diff` for:
- SQL injection / unsanitized input
- Missing error handling
- Resource leaks (DB rows, HTTP bodies, file handles, useEffect cleanup)
- Nil/undefined dereference without guard
- Unsafe type assertions (Go `x.(T)` without `ok`; TS `as T` on uncertain values)
- Race conditions (shared state without mutex, concurrent map access)
- Hardcoded user-facing strings (only if `config.i18n` set)
- Import pattern violations (per CLAUDE.md)
- Accidental secret files OR inline secrets

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
- **Tests pass** → PASS in Sonnet report (and listed in self-review)
- **Build passes** → zero issues for ALL commands in Build/Lint/Test
- **No hardcoded strings** → confirmed by 3.3
- **Migration applies** → confirmed in Sonnet report; zero-downtime audit PASS
- **No regressions** → no deleted assertions/expects/requires, no removed `if err` blocks, no removed nil guards
- **Acceptance extensions** → all matched extensions covered
- **Dep vulns** → 3.0.5 PASS at threshold
- **Public docs** → 3.0.6 PASS if applicable
- **Feature flag** → wrapped at entry point if required by config
- **Context doc** → if `required_for_finalize` and Sonnet didn't update it → BLOCKING
- **ADR** (High) → present and references the implementation

Blocking → return to Sonnet.
Non-blocking → tech-debt: GitHub issue labeled `tech-debt`, OR append to `config.tech_debt_doc`, OR write to memory. **No scope creep — log as new issue.**

**Migration amendment**: if review requires schema change → increment migration number, write NEW migration. Never amend existing. Note dependency in PR.

## Announce
```
[Phase 3] APPROVE after {N} cycle(s). Gates run: {list with pass/fail}. PR size: {lines}/{files}. Vulns: {count or clean}.
```
