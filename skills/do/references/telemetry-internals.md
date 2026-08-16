# Telemetry internals — rationale, history, and wrapper reference

**Not required reading for any phase.** This file holds the design rationale and wrapper-internals documentation behind [`phase-4-finalize.md`](phase-4-finalize.md) §4.11/§4.13 — material you consult when *changing* the telemetry system, never when *running* it. The operative instructions (closed announce forms, the wrapper invocation, dispatch rules) live in the core file; nothing here adds or relaxes an obligation.

## Why the gate vocabulary is controlled

The `gates` object's keys are a controlled vocabulary for the same data-quality reason the `outcome` enum exists (v0.6.0 found 16 outcome variants in production): the May-24 audit found **~110 distinct gate keys for ~19 real gates** — `test`/`tests`/`test_gate`/`go_test`, `ui`/`ui_gate`/`visual_verify`, `dep_vuln`/`dep_vuln_go`/`dep_vuln_pnpm`. Uncontrolled, every synonym splits a gate's stats across buckets and the gate-failure-rate metric is noise. Hence the wrapper-side canonical list + ~60-entry alias map: agents pass whatever name is natural at capture time; `metrics-append` renames known aliases and *preserves+flags* unknown keys (`noncanon=` in the OK line). Unknown keys are deliberately warn-normalized, not rejected — task-specific acceptance gates (`freenights_byte_identical`, `idempotency_cache_correct`) are legitimate one-off criteria, and hard-rejecting them would push agents to mislabel ad-hoc checks under canonical names they don't match, corrupting the very stats the vocabulary protects.

## Self-review calibration — the function `metrics-append` implements

All three calibration verdicts are computed INSIDE the wrapper from raw inputs (`--sr-performed`, `--sr-claimed`, normalized `--gates-json`, `--specialist-iterations-json` blockers, `--sr-size-assessment`, `--complexity-rebumped-from`). This is **documentation of wrapper internals, not an instruction to hand-execute** — hand-passed `--sr-calibration*` flags are optional cross-checks that REJECT on contradiction.

```
phase3_failed_gates = [g for g in gates if gates[g].status in ("fail", "block")]
sonnet_claimed = sonnet_self_review.claimed_status        # "ready" | "deferred" | "uncertain"

# --- Legacy combined calibration (`calibration`; unchanged semantics) ---
if not self_review.performed:
    calibration = "skipped"
elif sonnet_claimed == "ready" and phase3_failed_gates:
    calibration = "false_positive"
    miscalibrated = [f"{g}: claimed clean; Phase 3 found {brief_reason}" for g in phase3_failed_gates]
elif sonnet_claimed == "ready" and not phase3_failed_gates:
    calibration = "accurate"
elif sonnet_claimed in ("deferred", "uncertain") and not phase3_failed_gates:
    calibration = "false_negative"
else:
    calibration = "accurate"   # flagged issues, Phase 3 confirmed
```

(`miscalibrated` remains caller-provided free text via `--sr-miscalibrated-json` — it is descriptive, not a verdict.)

**Why the verdict is split into three dimensions** (production audit, 254 entries): of 44 `false_positive` entries, **17 (39%) fired ONLY `pr_size=warn`** — Sonnet's code was fine, it just under-predicted diff size. Counting those as "self-review missed something" inflates the FP rate and conflates two different failures: *missing a real code defect* vs *not predicting diff size*. The split records each separately so future audits read the right signal.

```
# A "real code defect" = any NON-pr_size gate failing/blocking, OR a specialist blocker.
specialist_blocked = any(c.blockers for c in specialist_iterations)
defect_found = [g for g in phase3_failed_gates if g != "pr_size"] or specialist_blocked

# --- calibration_defect: code-correctness dimension ---
if not self_review.performed:                       calibration_defect = "skipped"
elif sonnet_claimed == "ready" and defect_found:    calibration_defect = "false_positive"
elif sonnet_claimed == "ready":                     calibration_defect = "accurate"
elif sonnet_claimed in ("deferred","uncertain") and not defect_found:
                                                    calibration_defect = "false_negative"
else:                                               calibration_defect = "accurate"

# --- calibration_size: diff-size-prediction dimension ---
pr_size_fired      = gates.get("pr_size", {}).get("status") in ("warn", "block")
# Sonnet "flagged size" = --sr-size-assessment == "exceeds" (the Phase 2.5 machine-readable
# line — don't guess from prose), OR a Phase 2.0 plan-size rebump happened this task
# (--complexity-rebumped-from is set).
sonnet_flagged_size = (sr_size_assessment == "exceeds") \
                      or (COMPLEXITY_REBUMPED_FROM != "")

if not self_review.performed:                       calibration_size = "skipped"
elif "pr_size" not in gates:                        calibration_size = "n_a"   # gate didn't run
elif sonnet_flagged_size and pr_size_fired:         calibration_size = "accurate"
elif (not sonnet_flagged_size) and pr_size_fired:   calibration_size = "false_positive"  # under-predicted
elif sonnet_flagged_size and (not pr_size_fired):   calibration_size = "false_negative"  # over-predicted
else:                                               calibration_size = "accurate"
```

Why this matters downstream: `calibration_defect` is the **highest-signal data point** for skill iteration (the de-confounded FP rate: defect-FP trending up → self-review prompt too lax; defect-FN up → Sonnet over-flagging), while `calibration_size` tells whether Phase 0/2.0 routing predicts diff size well (size-FP up → routing under-estimates; the P0 PR-size ceiling + plan-size-check should drive it down). **Confounder**: do not compare FP rates across the ≈2026-05-17 specialist-plugin-install boundary — pre-install cohorts had zero specialist review, so mechanically fewer findings. Segment any trend on that date.

Measured validation (2026-07-17 re-audit, 227 runs on one repo + 109 on a second): the false-positive rate — implementer claimed `ready`, review found a real problem — rises monotonically with tier on the primary repo (L 3.6% → M ~21% → H 44.4%), and the High-tier gate-caused-fix-cycle rate replicated across both repos within one point (68.1% vs 69.2%). The L/M ordering did NOT replicate on the second repo — treat per-tier conclusions below High as single-repo evidence.

## Why token accounting exists (and why estimates are banned)

The 2026-07-17 re-audit's biggest measurement finding: across 369 telemetry entries in all logs, **zero** carried any cost field — durations, gates, and diff sizes were logged, but the skill could not compute its own ROI (every cost claim in every audit was a chars/4 guess). `--tokens-in`/`--tokens-out` close that hole. They are optional and **must come from harness-reported usage only** — an estimated or reconstructed number is worse than an absent one, because downstream ROI math can't tell measured entries from guessed ones. No harness figure available → omit the flags; absence is honest.

**Why the manual flags stayed empty (and what fills them now).** A 2026-07-23 re-audit found the flags at **0 % adoption** — 0 of 27 post-v0.10.0 entries carried a `tokens` object — and diagnosed it as structural, not negligence: *no in-session actor can read its own usage*. `/cost` is TUI-only; a sub-agent can't observe its own usage; a headless `claude -p --output-format json` usage block lands at the invoking process only after the session ends. The one actor the runtime hands harness-recorded usage is a **hook** — a Stop hook receives `transcript_path`, and the transcript's assistant records carry `message.usage`. v0.12.0 ships that: the opt-in `do-tokens-stop-amend.sh` (see [`hooks.md`](hooks.md)) sums those records after the finalize turn and back-fills the run's entry via a new `metrics-append --amend-tokens` mode. Design points worth pinning:

- **Amend, not append** — the entry already exists (Phase 4.11 wrote it); the hook adds only an absent `tokens` key. `--amend-tokens` runs the read-modify-write under the same log lock, verifies the rewrite touched nothing but `tokens`, and REJECTs a second amend on an already-filled entry → **idempotent** re-fires.
- **Ref-match, not last-line** — the target is the last entry whose `.ref` is named in the announce, so concurrent same-log sessions don't cross-fill each other.
- **`in` counts cache** — `in = input + cache_creation_input_tokens + cache_read_input_tokens`; cached reads are billed input and belong in ROI. `out = output_tokens`.
- **Window** — `[started_at − 120s, ended_at + 900s]` bounds the sum to this task; both bounds unusable → whole-transcript sum (a /do run is one task per session). All-zero → no write (absence stays honest; the hook never records `{in:0,out:0}`).
- **Still harness-measured** — every summed figure is a number the harness recorded, so the estimate ban holds; the manual flags remain legal for an operator who genuinely has a readout.

**What v0.12.0's hook actually produced: nothing (and why that took a release to notice).** Between shipping it on 2026-08-08 and the next audit on 2026-08-16 there was exactly **one** `/do` run, and its entry carried no `tokens` key — one opportunity, zero amends, no error anywhere. The hook was registered, executable, and byte-identical to the dev copy; it simply never matched. Root cause: that run was conducted in Russian, and the self-scoping guard was an anchored grep for the English prose lines `Complete. Branch:` / `Models: orchestrator=`. Every guard in the hook is a silent `exit 0` by design — enrichment must never wedge a Stop — so a hook that never triggers is externally indistinguishable from one that correctly had nothing to do. Three things changed in v0.13.0, and the ordering is the lesson:

1. **The spec is the fix.** [`phase-4-finalize.md`](phase-4-finalize.md) §"The announce is a protocol, not prose" now states outright that the §4.13 block is emitted verbatim in English regardless of session language, because two hooks parse it. Say anything you like around it in the user's language; the five lines themselves are a wire format.
2. **The hook is hardened, not made clever.** It additionally triggers on the machine-readable `Metrics:` line — a literal key, a count, and a path, with no translatable words — instead of trying to enumerate translations. Scoping is unaffected: the real check was always structural (the announce must name a ref that is on the resolved log and still lacks `tokens`), not textual.
3. **Silence is now debuggable.** `DO_TOKENS_DEBUG=1` prints the reason for each no-op. Any hook whose every failure path is a silent success needs this from day one; shipping without it is what turned a one-line guard mismatch into a release-long blind spot.

The `do-metrics-stop-gate.sh` trigger was deliberately **not** widened the same way. It is enforcement, not enrichment, and widening an enforcement trigger changes what gets blocked; the announce mandate in (1) covers it.

## Why `calibration_size` read 53 % — and why that was the gate's fault, not the reviewer's

`calibration_size` scores the Phase 2.5 self-review's diff-size prediction against the Phase 3.0 `pr_size` verdict. Across 93 post-v0.10.0 runs it sat at **53 % accuracy** — indistinguishable from guessing, on a dimension the skill deliberately de-confounded from `calibration_defect` (75 %) in v0.10.0 specifically to make it readable.

The measurement was broken at the other end. `pr_size` warn caps were flat 800 lines / 20 files for **every** complexity tier, while the H bucket's own plan-time cap is 25 files / 1500 lines. So an H plan approved at 1400 lines PASSed Phase 2.0 and was **guaranteed** to WARN at Phase 3.0 for being exactly the size it had been authorized to be — the two gates contradicted each other by construction. Measured effect: `pr_size` warned on 43 of 86 runs, **80 % of all H runs**; the amber verdict carried no information, and a metric scored against it could not either.

v0.13.0 derives the warn caps from the run's tier (`pr-size-check --tier`), so WARN states one interpretable fact: the delivered diff exceeded the budget its own plan was approved against. Block caps stay flat and tier-independent — unreviewable is unreviewable. Expected effect on the same 93-run cohort: H warn rate 80 % → 57 %, M 22 % → 40 % (M's flat 800 was *looser* than its own 600-line bucket, so the gate gets stricter exactly where it was too permissive). The residual 57 % on H is not threshold noise — it is the finding that H plans systematically under-estimate, which is now a readable signal instead of a constant.

**General lesson for this telemetry system:** a calibration metric is only as meaningful as the gate it scores against. Before concluding "the model predicts badly", check whether the threshold it is being scored against fires on the median case.

## Why structural coupling + external wrapper, not soft instruction

Three enforcement layers, each addressing a failure mode the previous one missed:

1. **Soft "mandatory" instruction** (v0.1–v0.3) — got skipped systematically. Sub-agent reads "Phase 4.11 mandatory" at session start, opens the PR, writes detailed PR-summary as final output, stops without emitting metrics.

2. **Announce↔emit bash coupling** (v0.3–v0.5) — `$METRICS_LINE` set only by the emit block, no emit → can't compose announce. Fixed the "stops without emitting" failure. Still let sub-agents compose JSON freely inside the emit block, producing 100+ distinct field names across runs and `self_review` block missing in 0 of 37 entries (v0.6 audit).

3. **External wrapper with named-args CLI** (current) — the wrapper is the only path to a valid append. Unknown flags reject, missing required flags reject, bad enums reject. Sub-agent cannot invent a new shape without making the announce print `Metrics: APPEND FAILED — REJECT <reason>`, which is visible. Content-based append verification lives inside the wrapper too (the exact entry must be present as a full line after the lock-serialized write), so a `>>` that returns exit 0 without actually writing (disk full) is still caught.

Effectiveness, measured: in the primary production log, every schema-drifted entry (24 of 227) predates the wrapper mandate's rollout window (2026-05-15 → 2026-05-31); the following six-plus weeks of runs produced zero new drift. The remaining blind spot is drift *inside* a canonical envelope (a valid entry whose `gates` is empty or whose `self_review` lacks calibration subfields) — `metrics-report`'s SOFT DRIFT tier surfaces those.

## What metrics enable

DORA-ish self-analysis: cycle time per complexity, review-iterations distribution, gate failure rate, self-review calibration trend, per-tier ROI once token fields accumulate, CI flakiness (when the CI gate is opt-in-on). Consumer: `metrics-report` (same resolver as `metrics-append`; read-only, never a phase step).
