# Phase 3 — Low complexity (complete path)

**Low runs load THIS file instead of [`phase-3-review.md`](phase-3-review.md)** — it is the whole Low review, same rigor as the former §3.5, none of the M/H machinery (no specialists, no Opus criteria review, no UI/i18n/contract gates — [SKILL.md](../SKILL.md): "build-verify re-run + diff scan + dep-vuln scan, nothing else"). If you're reading phase-3-review.md on a Low task, switch here; M/H tasks must NOT use this file.

The Low gate set: **3.1 build-verify re-run** + **3.0.5 dep-vuln scan** + **Opus diff scan** (§3.5 semantics, checklist below). One fix cycle on findings; Opus describes fixes, Sonnet applies.

## 1. Build/Test Verify — YOU re-run the checklist in the worktree

Low is NOT exempt: the implementer's report — exit codes included — is its own testimony; without this re-run the Low path is self-report-only (anti-patterns §19h).

```bash
# LOCKSTEP: this block mirrors phase-3-review.md §3.1 — change both together.
# Canonical do-scripts resolver — identical line in every wrapper block; each
# block runs in a fresh shell, so re-resolve here (rationale: phase-0-setup.md Step 1).
DO_SCRIPTS="$(find -L ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT/skills"} "$HOME/.claude/skills" "$HOME/.claude/plugins/cache" "$HOME/.local/share/senior-by-default/skills" -maxdepth 7 -type f -name metrics-append -path '*/scripts/*' 2>/dev/null | head -1)"; DO_SCRIPTS="${DO_SCRIPTS%/metrics-append}"

# Commands come from the stack cache (stack-detection.md); affected-graph scoping
# applies per the phase-0 Step 4 predicate, same as M/H.
CACHE_FILE="$HOME/.claude/do/cache/{slug}.json"     # slug per stack-detection.md
VERIFY_ARGS=()
while IFS= read -r c; do VERIFY_ARGS+=(--build "$c"); done < <(jq -r '.build_cmds[]?' "$CACHE_FILE")
while IFS= read -r c; do VERIFY_ARGS+=(--lint "$c");  done < <(jq -r '.lint_cmds[]?'  "$CACHE_FILE")
# Test leg ONLY when the task is Tests: YES. Tests: NO → DELETE the next two lines;
# the wrapper reports test=skipped (a skipped leg is never a pass).
TEST_CMD="$(jq -r '.test_cmd // empty' "$CACHE_FILE")"
[ -n "$TEST_CMD" ] && VERIFY_ARGS+=(--test "$TEST_CMD")

if [ -x "$DO_SCRIPTS/build-verify" ]; then
  VERIFY_OUT="$("$DO_SCRIPTS/build-verify" --dir "$WORKTREE_PATH" ${VERIFY_ARGS[@]+"${VERIFY_ARGS[@]}"})" && VERIFY_RC=0 || VERIFY_RC=$?
else
  # FAIL CLOSED — explicit token so the dispatch below has a matching arm.
  VERIFY_OUT="Phase 3.1: GATE ERROR — build-verify wrapper not found (do-scripts resolver found no install)"; VERIFY_RC=127
fi
printf '%s\n' "$VERIFY_OUT"
```

Dispatch on the verdict line — identical semantics to phase-3-review.md §3.1:
- `VERIFY PASS` → proceed; record `gates.build/lint/test` per the wrapper's leg statuses (`details.tell` = that leg's per-command wrapper line(s), verbatim).
- `VERIFY SKIPPED` → record legs `skipped`, NEVER upgrade to pass; say so in the announce.
- `VERIFY FAIL` (rc 3) → hand Sonnet the failing-command tail, re-run this block after the fix. If the Phase 2 report claimed PASS for the same command → `details.self_report_mismatch: true` (fabrication-class, §19h).
- `GATE ERROR` → FAIL CLOSED: stop, surface the line; fix = re-run install.sh / `/plugin install`. Never fall back to the implementer's report.

## 2. Dep vulnerability scan

Same gate as phase-3-review.md §3.0.5 (skipped only if `config.security_scan.enabled: false`). Run the scanner for `cache.package_manager` — npm/pnpm/yarn `audit`, go `govulncheck ./...`, cargo `cargo audit`, pip `pip-audit`, etc.; the full per-PM command table and `command_override_by_pm` live in [`phase-3-review.md`](phase-3-review.md) §3.0.5 — consult it only if the default command for your PM is unclear. Threshold `config.security_scan.threshold` (default `high`): block at threshold+, warn one level below. Findings → return to Sonnet (upgrade / replace dep, or tech-debt with explicit risk acceptance). Metrics: `gates.dep_vuln`.

## 3. Opus diff scan

Opus scans `git diff` for:
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

All clear → Phase 4. Issues → **one fix cycle** (no specialists). Opus describes fixes, Sonnet applies, re-run steps 1–3 on the fixed diff.

## Metrics capture

Canonical keys for this path: `build` / `lint` / `test` (step 1), `dep_vuln` (step 2), `diff_scan` (step 3: `{ "issues": [{"category","file_line","summary"}] }` on findings). Record `fix_cycle` per gate (0 = first try). Full vocabulary + wrapper normalization: [`phase-4-finalize.md`](phase-4-finalize.md) §4.11.

## Announce

```
[Phase 3] APPROVE after {N} cycle(s). Gates run: {list with pass/fail}. Verify: {status + "N cmds in Nms" from the 3.1 verdict line}. Vulns: {count or clean}.
```

The `Verify:` token is carried verbatim from the `build-verify` verdict line (its cmd-count/elapsed-ms is the anti-fabrication tell) — a hand-written `Verify: PASS` with no matching `Phase 3.1: VERIFY` line in the transcript is a §19h bypass.
