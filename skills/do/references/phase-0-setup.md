# Phase 0 — Setup & Routing

Read this when entering Phase 0 (every task starts here). Everything below runs before Phase 1+.

## Preflight — task clock, then intent clarity + minimal path

### Task clock — capture `STARTED_AT` FIRST, before anything else

Very first action of Phase 0 — before the clarity check, before any other tool call. **Run this bash verbatim**:

```bash
# STARTED_AT must be captured at Phase 0 ENTRY. Phase 4.11's metrics-append
# hard-rejects --ended-at < --started-at (production audit: 36% of pre-fix
# entries had negative cycle times from back-computing started_at at the end).
# Why a file, not a variable: every spec bash block runs in a FRESH shell —
# a variable set here does not exist in the Phase 4 shell hours later. The
# clock file is the durable carrier; the echo below is the transcript fallback.
CLOCK_ANCHOR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CLOCK_FILE="$HOME/.claude/do/state/$(printf '%s' "$CLOCK_ANCHOR" | sed -E 's/[^a-zA-Z0-9]+/-/g; s/^-+//; s/-+$//').task-clock.json"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$(dirname "$CLOCK_FILE")"
printf '{"started_at":"%s","phase_entered_at":{"0":"%s"}}\n' "$STARTED_AT" "$STARTED_AT" > "$CLOCK_FILE"
echo "Clock: started $STARTED_AT → $CLOCK_FILE"
```

Path derivation is anchored on the **orchestrator's CWD** (git toplevel, or `pwd` outside a repo) — NOT the resolved target repo (Step 3) or the worktree. It must produce the identical path when Phase 4.11 re-derives it in a fresh shell, and CWD is the only anchor that exists this early. Known limit: parallel `/do` sessions launched from the same CWD share the path — latest Phase 0 wins; the Phase 4 cross-check against the announce value (below) makes the overwrite visible.

**Per-phase stamps.** On ENTERING each later phase (1, 2, 3, 4) — before the phase's first step — stamp the clock with the same derivation (fresh shell, so re-derive):

```bash
CLOCK_ANCHOR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CLOCK_FILE="$HOME/.claude/do/state/$(printf '%s' "$CLOCK_ANCHOR" | sed -E 's/[^a-zA-Z0-9]+/-/g; s/^-+//; s/-+$//').task-clock.json"
jq --arg p "<phase number: 1|2|3|4>" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.phase_entered_at[$p] = $t' "$CLOCK_FILE" > "$CLOCK_FILE.tmp" && mv "$CLOCK_FILE.tmp" "$CLOCK_FILE"
```

Phase 4.11 derives `phase_durations_seconds` from these stamps (delta to the next stamp; the last stamped phase ends at `$ENDED_AT`). Degradation is graceful and asymmetric by design: a missed stamp only loses that duration split; a missed **capture** loses `--started-at` entirely and Phase 4 cannot legally reconstruct it — which is why the capture is the first action, not a step.

### Intent clarity + minimal path

Before any side effects (issue creation, worktree creation, commits, pushes), read `$ARGUMENTS` and decide whether the task is clear enough to execute.

- If multiple interpretations would produce different behavior or data contracts, STOP and ask the user.
- If one reasonable interpretation exists but there are assumptions, proceed only after recording the assumptions in the Phase 0 announce and, for M/H, the issue body.
- Prefer the smallest path that meets the user goal. If the user asked for a broad change but a narrower change clearly satisfies the goal, surface the tradeoff before proceeding.
- Convert the request into concrete pass/fail acceptance criteria before Phase 1 (M/H) or Phase 2 (T/L).

## Steps

Phase 0 is **6 logical steps**, not 12 sub-phases. Conditional bullets are inline; they only fire when relevant config or context is present.

### 1. Load + validate config

Walk CWD upward for `.claude/do/config.json`. First match wins. Defaults defined in [`config-schema.md`](config-schema.md) (single-repo, no issue tracker, no UI/i18n gates, no specialists, no context doc).

- **Found** → validate per [`config-validation.md`](config-validation.md). Hard error → STOP. Warnings → print and proceed. Set:
  ```bash
  CONFIG_FOUND=1
  CONFIG_LINE="Config: LOADED $CONFIG_PATH"
  ```

  Then — **ensure telemetry settings**. If `--no-metrics` not in `$ARGUMENTS`, **run this bash verbatim** (do not Edit the file by hand, do not compose `$METRICS_CONFIG_LINE` yourself — see [anti-patterns §19c](anti-patterns.md)):
  ```bash
  # Canonical do-scripts resolver — REPEATED VERBATIM in every wrapper block
  # (fresh shell per block: a variable resolved in one phase does NOT exist in
  # the next — same shell model as the task clock above; files and re-run
  # probes are the only durable carriers). NEVER invoke a wrapper via a
  # literal ~/.claude/skills/do/scripts/ path: that dir exists only for the
  # default-name symlink install — plugin installs and renamed SKILL_NAMEs
  # have no such path, and the literal killed the whole wrapper tier there
  # (audit finding #2). Probe order: plugin root → ~/.claude/skills/<any
  # name>/scripts → plugin cache → default manual clone dir. metrics-append
  # is the sentinel file; every wrapper ships in the same scripts/ dir.
  DO_SCRIPTS="$(find -L ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT/skills"} "$HOME/.claude/skills" "$HOME/.claude/plugins/cache" "$HOME/.local/share/senior-by-default/skills" -maxdepth 7 -type f -name metrics-append -path '*/scripts/*' 2>/dev/null | head -1)"; DO_SCRIPTS="${DO_SCRIPTS%/metrics-append}"

  if [ -x "$DO_SCRIPTS/config-ensure-metrics" ]; then
    METRICS_CONFIG_LINE="$("$DO_SCRIPTS/config-ensure-metrics" --config "$CONFIG_PATH" 2>&1)" \
      || METRICS_CONFIG_LINE="Metrics config: PATCH SKIPPED — $METRICS_CONFIG_LINE"
  else
    # FAIL CLOSED — explicit token, never an empty variable (see §19c).
    METRICS_CONFIG_LINE="Metrics config: PATCH SKIPPED — do-scripts resolver found no install (probed plugin root, ~/.claude/skills/*/scripts, plugin cache, ~/.local/share/senior-by-default)"
  fi
  echo "$METRICS_CONFIG_LINE"
  ```
  Wrapper is idempotent — 3 outcomes, all via wrapper stdout, never composed. The spec deliberately does NOT print their full form (state tokens only — the lines live in the wrapper, same pattern as `check-caveman` below; see [anti-patterns §19i](anti-patterns.md)):
  - **ALREADY CONFIGURED state** — `metrics` block exists, no change.
  - **EXPLICIT OPT-OUT state** — user set `metrics: null` explicitly, respected, no write.
  - **AUTO-ADDED state** — key was absent, default tier-1 preset patched in, `_meta` stamped with `last_patched_by`/`last_patched_at`/`last_patch_added`. May carry a wrapper-emitted ` (schema gate SKIPPED — jsonschema unavailable)` suffix — the file was written unvalidated (python3-jsonschema missing). Keep the suffix verbatim in the announce; it's the wrapper's tell, not a §19c annotation.

  **The anti-fabrication tell**: every outcome line ends with a runtime fingerprint suffix — `(cfg=<cksum> …)` computed over the canonicalized JSON of the config file the wrapper actually read or wrote (AUTO-ADDED adds `patched_at=<runtime clock>`, ALREADY CONFIGURED adds the actual `keys=` count). None of that is composable from spec text; auditors recompute the crc from the file on disk (`jq -cS . <path> | cksum`). A `Metrics config: ALREADY CONFIGURED / EXPLICIT OPT-OUT / AUTO-ADDED` line WITHOUT the `(cfg=…)` suffix was composed by hand — re-run the wrapper, paste actual output. The spec-side fallback forms (`PATCH SKIPPED`, `SKIPPED (--no-metrics)`, the Step 4 mirrors) remain copyable on purpose: they are honest degraded/derived states, not plausible-looking successes.

  If `--no-metrics` was passed → skip this block, set `METRICS_CONFIG_LINE="Metrics config: SKIPPED (--no-metrics)"`.
- **None** → set `CONFIG_FOUND=0`. Use in-memory defaults for now. **Auto-init is DEFERRED to the end of Step 4** (needs stack-detect output to populate `_meta.auto_generated_for_stack`). `CONFIG_LINE` and `METRICS_CONFIG_LINE` will be set there.

**Conditional, inline**:
- `config.wip_limit` set → count `git worktree list` + open issues assigned to user; warn if sum > limit. Opt-in only; default disabled. (Kanban WIP limits derive from human team context-switching cost; in AI-orchestrated workflows with isolated agent contexts, parallel sessions are usually a strength — leave unset unless you specifically want a soft ceiling.)
- `config.postmortem.trigger_keywords` match `$ARGUMENTS` OR branch matches `branch_prefixes` (e.g. `fix/...`) → suggest `/postmortem` skill if installed, else add `## Postmortem` section to Phase 1 issue body (cause / impact / detection / mitigation / prevention).

### 2. Companion-skill detect — caveman

Skip if `--no-caveman` in `$ARGUMENTS` (set `CAVEMAN_LINE=""` — announce will omit the line). Otherwise — **invoke the wrapper verbatim** (do not paraphrase, do not "check mentally", do not compose the announce line yourself — see [anti-patterns §19b](anti-patterns.md)):

```bash
# Canonical do-scripts resolver — same line as Step 1, re-run here (fresh shell per block).
DO_SCRIPTS="$(find -L ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT/skills"} "$HOME/.claude/skills" "$HOME/.claude/plugins/cache" "$HOME/.local/share/senior-by-default/skills" -maxdepth 7 -type f -name metrics-append -path '*/scripts/*' 2>/dev/null | head -1)"; DO_SCRIPTS="${DO_SCRIPTS%/metrics-append}"

if [ -x "$DO_SCRIPTS/check-caveman" ]; then
  CAVEMAN_LINE="$("$DO_SCRIPTS/check-caveman")"
else
  # FAIL CLOSED — explicit token, never an empty variable.
  CAVEMAN_LINE="Caveman: CHECK SKIPPED — do-scripts resolver found no install (probed plugin root, ~/.claude/skills/*/scripts, plugin cache, ~/.local/share/senior-by-default)"
fi
echo "$CAVEMAN_LINE"
```

**The wrapper is the single source of truth for the line.** Possible outputs (the spec deliberately does NOT spell out the templates — they live only in the wrapper script):
- **ACTIVE form** — includes the resolved install path AND a `levels:` hint. The path differs per machine; orchestrator cannot guess between `~/.claude/skills/caveman`, `~/.agents/skills/caveman`, the marketplace-namespaced plugin cache, etc. The `levels:` hint (`smart` | `base`) is grepped by the wrapper from the INSTALLED SKILL.md at run time — it selects the Phase 2 directive register (see below) and is not knowable without reading the file.
- **NOT INSTALLED form** — includes a `(probed: <P1>, <P2>, …)` suffix listing every candidate the wrapper actually checked (fixed paths + marketplace-cache glob expansions; an unmatched glob stays in the list as its literal pattern). This suffix is the **anti-fabrication tell**: the list is built from the wrapper's internal array, never written in the spec, so orchestrator skipping the wrapper cannot include it without inventing path names (which is a detectable visible-bug).
- **CHECK SKIPPED form** — the spec-side fail-closed fallback (the `else` branch above), fires only when the resolver finds no install at all. The one form that IS copyable from the spec — acceptable because it is an honest degraded state the user will chase (broken install), not a plausible-looking success.

Why a wrapper (not inline bash like v1/v2): both prior versions had the announce-line template visible in the bash literal inside the spec. Orchestrators systematically read the template and copy-pasted it into the announce **without running the bash** (production-confirmed 2026-05-17, lea-web run: announced `Caveman: NOT INSTALLED — install: curl ...` while caveman was installed at path #1). Moving the strings into a wrapper script and adding a runtime-only tell (probed-paths list) is the structural fix.

If the announce contains a `Caveman:` line that lacks the `(path: ...)` suffix for ACTIVE, the `(probed: ...)` suffix for NOT INSTALLED, and is not the exact CHECK SKIPPED fallback — orchestrator skipped the wrapper. Re-run, paste actual wrapper output.

When the wrapper returns the ACTIVE form, Sub-Agent prompts get the caveman-style directive (see [`phase-2-implementation.md`](phase-2-implementation.md) Rules section) — **register selected by the `levels:` hint**: `levels: smart` → smart register (content compression, grammar intact — the designed fit for readability-enforcing harnesses, which fight full-register grammar-dropping); `levels: base` → full register. Caveman is **passive** (SessionStart hook); once active, all assistant output flows through compression. No runtime wrapping needed — only the prompt directive.

### 3. Resolve target repo(s)

If `$ARGUMENTS` has `--repo=NAME` → use that.

Else if `config.workspace.repos` exists → match `$ARGUMENTS` against each repo's `scope_keywords`:
- 1 match → that repo
- multiple → fullstack (multiple worktrees)
- 0 → ask user

Else → CWD must be inside a git repo — **run this bash verbatim; STOP on failure, never let Step 4/5 dereference an unset `$REPO`**:

```bash
REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "STOP: not inside a git repo — cd into a project repo, pass --repo=NAME (needs config.workspace.repos), or git init first"
  exit 1
}
echo "Repo: $REPO"
```

`STOP:` printed → **HALT Phase 0**: relay the line to the user verbatim and end the task. No Step 4/5, no auto-init, no worktree, no announce. Pre-fix this state had no defined behavior — `git rev-parse` failed quietly and the first symptom was later Step 4/5 bash operating on an empty `$REPO` (model improvisation instead of a defined stop, against the skill's own every-failure-mode-is-a-spec'd-line philosophy — audit #13).

### 4. Stack cache (load or detect)

For each target repo, compute cache slug from absolute path. Slug rule: replace every run of non-alphanumeric characters with a single `-`, then strip leading/trailing `-`. Example: `/Users/alice/work/api` → `Users-alice-work-api`. Cache file: `~/.claude/do/cache/<slug>.json`. Full canonical algorithm: [`stack-detection.md`](stack-detection.md).

**Load cache** (default):
- Verify `cache.version == 1`
- Verify `cache.repo_path` matches current repo's absolute path (guards slug collisions — `/Users/alice/work-api` and `/Users/alice/work/api` collide to same slug)
- If `$ARGUMENTS` doesn't contain `--redetect` (or NL equivalent like "re-detect stack") → use cache, skip to step 5

**Detect** (cache miss / version mismatch / `--redetect`):
- Run detection per [`stack-detection.md`](stack-detection.md)
- If `nx.json` or `turbo.json` present, set `affected_graph_tool` — a durable cache fact, recorded regardless of per-task flags.
- Write result to cache. Always include canonical `repo_path`.

**Affected-graph "in use" (per task, never cached)**: `affected_graph_tool` set AND `config.affected_graph` enabled AND `--no-affected-graph` NOT in `$ARGUMENTS`. Only when in use do the scoped equivalents substitute `cache.build_cmds` / `cache.test_cmd` — Step 6 test scoping, Phase 1 Build Checklist, Phase 2 Build line, and Phase 3 `build-verify` all key off this one predicate. The flag exists for exactly the suspicious case (user suspects the affected graph missed cross-project breakage), so honoring it means the FULL suite runs everywhere — a scoped run behind a passed flag left the user believing the full suite passed (documented no-op flag, audit #17). When the flag suppresses a detected tool, the announce reads `Affected-graph: disabled (flag)`.

Cache fields used throughout phases 1–4: `stack`, `package_manager`, `build_cmds`, `lint_cmds`, `test_cmd`, `ui_files`, `ui_extensions`, `migration_dir`, `migration_pattern`, `affected_graph_tool`. Never re-derive mid-task.

**Auto-init config (only if Step 1 set `CONFIG_FOUND=0` AND `--no-config-init` not in `$ARGUMENTS`)** — **run this bash verbatim** (do not Write a `config.json` by hand, do not compose `$CONFIG_LINE` yourself — see [anti-patterns §19c](anti-patterns.md)):

```bash
# Detect tracker from git remote (origin). Bash parameter expansion only —
# avoids sed regex with `](...)` that confuses markdown link parsers.
# NOTE: this detects the remote URL ONLY. Presence + auth of the tracker CLI
# is config-init's gate (wrapper-side: probes `command -v gh|glab` + `gh|glab
# auth status`; failure degrades the written config to type:none and emits a
# second "Tracker: …" stdout line — see "Tracker preflight" below). Do NOT
# pre-probe gh here and flip $TRACKER yourself — the wrapper owns the verdict.
REMOTE_URL="$(git -C "$REPO" remote get-url origin 2>/dev/null || true)"
case "$REMOTE_URL" in
  *github.com*) TRACKER="github"; TR_PATH="${REMOTE_URL##*github.com[:/]}"; TRACKER_REPO="${TR_PATH%.git}" ;;
  *gitlab.com*) TRACKER="gitlab"; TR_PATH="${REMOTE_URL##*gitlab.com[:/]}"; TRACKER_REPO="${TR_PATH%.git}" ;;
  *)            TRACKER="none"; TRACKER_REPO="" ;;
esac

# Detect issue_locale from $ARGUMENTS — pass to wrapper so it writes the right
# value in one shot. Without this, sub-agents who notice non-en context
# (Cyrillic / CJK in $ARGUMENTS, repo README, etc.) tend to post-edit the
# generated config to switch locale, then append " (patched issue_locale=ru)"
# to $CONFIG_LINE — that's a §19c violation. Pass at invocation instead.
# Override: explicit "--issue-locale=<code>" in $ARGUMENTS wins.
ISSUE_LOCALE="en"
case "$ARGUMENTS" in
  *--issue-locale=*) ISSUE_LOCALE="${ARGUMENTS##*--issue-locale=}"; ISSUE_LOCALE="${ISSUE_LOCALE%% *}" ;;
  *) if LC_ALL=C printf '%s' "$ARGUMENTS" | grep -q '[А-Яа-яЁё]'; then ISSUE_LOCALE="ru"
     elif LC_ALL=C printf '%s' "$ARGUMENTS" | grep -q '[一-龥぀-ゟ゠-ヿ]'; then ISSUE_LOCALE="ja"
     elif LC_ALL=C printf '%s' "$ARGUMENTS" | grep -q '[가-힣]'; then ISSUE_LOCALE="ko"
     fi ;;
esac

# Specialists preset: by default emit the recommended `specialists` block
# (references the 6 plugins from anthropics/claude-plugins-official +
# wshobson/agents — see README). config-init VERIFIES the preset against
# ~/.claude/plugins/installed_plugins.json and DROPS missing plugins —
# reported on a wrapper-emitted "Specialists: …" stdout line (part of
# $CONFIG_LINE; see "Specialists preset verification" below). Do NOT
# pre-probe the manifest here — the wrapper owns the verdict.
# Opt-out: --no-specialists in $ARGUMENTS.
case "$ARGUMENTS" in
  *--no-specialists*) SPECIALISTS="none" ;;
  *)                  SPECIALISTS="default" ;;
esac

# Metrics preset: by default emit the documented tier-1 telemetry block
# (~/.claude/do/metrics/<repo-slug>.jsonl + phase durations + failure
# details + self-review calibration). Opt-out: --no-metrics in $ARGUMENTS.
case "$ARGUMENTS" in
  *--no-metrics*) METRICS="none" ;;
  *)              METRICS="default" ;;
esac

# Canonical do-scripts resolver — same line as Step 1, re-run here (fresh shell per block).
DO_SCRIPTS="$(find -L ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT/skills"} "$HOME/.claude/skills" "$HOME/.claude/plugins/cache" "$HOME/.local/share/senior-by-default/skills" -maxdepth 7 -type f -name metrics-append -path '*/scripts/*' 2>/dev/null | head -1)"; DO_SCRIPTS="${DO_SCRIPTS%/metrics-append}"

# Call the wrapper. Captures full stdout/stderr into CONFIG_LINE — the wrapper
# itself emits the canonical line on success ("Config: AUTO-GENERATED → …"),
# and "REJECT …" / "IOFAIL …" on the skip paths (already exists, refused
# context, missing tooling). Either way, $CONFIG_LINE is the announce token —
# do NOT append annotations like "(patched ...)" to it (see §19c). The success
# line may already end in " (schema gate SKIPPED — jsonschema unavailable)" —
# that suffix is WRAPPER-emitted (file written unvalidated), not an agent
# annotation: keep it verbatim, never strip it to "clean up" the line.
if [ ! -x "$DO_SCRIPTS/config-init" ]; then
  # FAIL CLOSED — explicit token, never an empty variable (see §19c).
  CONFIG_LINE="Config: AUTO-INIT SKIPPED — do-scripts resolver found no install (probed plugin root, ~/.claude/skills/*/scripts, plugin cache, ~/.local/share/senior-by-default)"
elif [ "$TRACKER" = "none" ]; then
  CONFIG_LINE="$("$DO_SCRIPTS/config-init" \
    --repo-root "$REPO" --tracker none --stack "$STACK" --issue-locale "$ISSUE_LOCALE" --specialists "$SPECIALISTS" --metrics "$METRICS" 2>&1)" \
    || CONFIG_LINE="Config: AUTO-INIT SKIPPED — $CONFIG_LINE"
else
  CONFIG_LINE="$("$DO_SCRIPTS/config-init" \
    --repo-root "$REPO" --tracker "$TRACKER" --tracker-repo "$TRACKER_REPO" --stack "$STACK" --issue-locale "$ISSUE_LOCALE" --specialists "$SPECIALISTS" --metrics "$METRICS" 2>&1)" \
    || CONFIG_LINE="Config: AUTO-INIT SKIPPED — $CONFIG_LINE"
fi
echo "$CONFIG_LINE"

# Auto-init wrote metrics inline (per --metrics flag above). Mirror that
# fact into $METRICS_CONFIG_LINE so the announce has a uniform tell for
# the metrics state regardless of which Step set it (Step 1 found-case
# patches via config-ensure-metrics; Step 4 auto-init bakes it in).
case "$CONFIG_LINE" in
  "Config: AUTO-GENERATED"*)
    if [ "$METRICS" = "default" ]; then
      METRICS_CONFIG_LINE="Metrics config: INCLUDED in auto-init"
    else
      METRICS_CONFIG_LINE="Metrics config: SKIPPED (--no-metrics)"
    fi ;;
  *) METRICS_CONFIG_LINE="Metrics config: N/A (auto-init skipped)" ;;
esac
echo "$METRICS_CONFIG_LINE"
```

Locale detection rationale: keeps the wrapper as the single source of truth for `$CONFIG_LINE`. If you notice locale-relevant context AFTER the wrapper ran (e.g. README turns out to be in another language than `$ARGUMENTS`), do NOT post-edit + annotate — instead, either edit the file directly in a separate observable step (and don't touch `$CONFIG_LINE`), or rerun with `--issue-locale=<code>` after deleting the auto-generated file. The Phase 0 announce must reflect what the wrapper actually wrote in one atomic call.

**Refuse paths (script-side, all produce `AUTO-INIT SKIPPED`, not errors)**:
- Repo root is `$HOME` or `/` — script refuses (looks like a stray `/do` invocation, not a project).
- Repo IS senior-by-default (has `skills/do/SKILL.md` at root) — script refuses to bootstrap its own config.
- `config.json` already exists — refuses to overwrite (Step 1 already loaded it; this branch shouldn't execute, but defense in depth).
- `jq` not installed — refuses with reason.

**Tracker preflight (wrapper-side, fires only on github/gitlab detections)**: before writing `type: github|gitlab`, config-init probes `command -v gh|glab` + `gh|glab auth status`. Probe fails → the wrapper DEGRADES the written config to `type: "none"` (records `_meta.tracker_degraded_from` / `tracker_degraded_reason` + the remedy in `_setup_notes`) and appends a second stdout line after the `Config:` line: `Tracker: DEGRADED to none (<tool> missing|unauthenticated — <fix>)`. Probe passes → `Tracker: github|gitlab OK (<tool version>; auth account: <login>)` — version + account are runtime probes, not composable from spec text (the anti-fabrication tell; [anti-patterns §19c](anti-patterns.md)). Both forms are part of `$CONFIG_LINE` (full stdout capture) and ride into the announce verbatim. DEGRADED is an honest state, not an error: Phase 1 is skipped **with an explicit announce** (see [`phase-1-issue.md`](phase-1-issue.md)), the rest of the pipeline runs trackerless. Do NOT hand-flip the type back to github/gitlab without a working CLI — the next run's Phase 1 dies at the first `{Tracker.list_open}`. Pre-fix, auto-init trusted the remote URL alone; the fresh-machine state (git present, gh absent) committed the pipeline to a tracker it couldn't talk to, surfacing as a raw `gh: command not found` mid-pipeline (audit #13).

**Specialists preset verification (wrapper-side, fires when the preset is requested — the default)**: config-init no longer writes the preset blind. It reads `~/.claude/plugins/installed_plugins.json` (the machine-readable install manifest), DROPS every preset entry whose plugin isn't installed, OMITS groups that become empty, and appends a further stdout line after the `Config:`/`Tracker:` lines: `Specialists: PRESET VERIFIED (N/M plugins installed: <name@version, …>)` | `PRESET FILTERED (… MISSING: … — entries dropped, groups omitted: …)` | `PRESET EMPTY (… specialists block OMITTED …)` | `UNVERIFIED (no readable manifest — full preset written)`. The `name@version` list is read from the manifest at runtime — not composable from spec text (the [§19c](anti-patterns.md) tell standard). All forms ride inside `$CONFIG_LINE` verbatim. Pre-fix, every new-machine auto-init wrote all 6 plugin references regardless of what's installed — re-arming the phantom-plugin incident class, where a configured-but-absent specialist surfaced at runtime as an improvised fallback to the WRONG model ("falling back to Sonnet", audit #9). The runtime half of that fix lives in [`phase-2-implementation.md`](phase-2-implementation.md) (Plan Review) and [`phase-3-review.md`](phase-3-review.md) §3.6: a configured specialist unavailable at spawn time → announced Opus inline fallback, NEVER Sonnet.

The generated file contains: `version + _meta + issue_tracker + issue_locale + specialists` (unless `--no-specialists` passed, or the verified preset came back empty). The specialists preset references plugins from the two recommended marketplaces (`anthropics/claude-plugins-official` + `wshobson/agents` — see [README](../../../README.md#recommended-claude-code-plugins-for-phase-3-specialist-review)). `_meta._setup_notes` in the generated file lists the exact install commands, including per-missing-plugin restore commands when the preset was filtered.

Other config sections (`context_doc`, `workspace.repos`, `ui_gate`, `acceptance_extensions`, `naming` overrides) are left for the user to add by extending the file. The file is left unstaged — user reviews and commits when ready. Subsequent `/do` runs re-read it on each Phase 0, so no reload needed after extension.

If `--no-config-init` was passed → skip this block entirely, set `CONFIG_LINE="Config: NONE — using defaults (--no-config-init)"`.

### 5. Sanity checks

**Duplicate check** (only if tracker configured AND ≠ `none`):
- Run `{Tracker.list_open}` from [`trackers.md`](trackers.md). Default for github: `gh issue list --repo {repo} --state open --limit 20`.

**Always**:
- `git -C {repo} branch -a`
- `git -C {repo} worktree list`

Duplicate issue or branch → STOP, ask user. Stale worktrees → warn.

**Concurrent-edit check — runs in Phase 1, NOT here.** The check needs the planned-files list, which does not exist until Phase 1 derives it — placing it in Phase 0 was circularly sequenced (Phase 0 needed Phase 1's output; nothing looped back), leaving the gate unreachable for M/H, its only applicable tiers (audit #19). It now runs inside [`phase-1-issue.md`](phase-1-issue.md) §Concurrent-edit check, immediately after the planned-files list is derived. T/L skip it by construction (no Phase 1, no planned-files artifact).

**Migration detection** (only if `cache.migration_dir != null`):
- Migration prefix: `MIGRATION_PREFIX="$(date -u +%Y%m%d%H%M%S)"` — UTC timestamp, generated at creation time. NEVER compute "next free number" from existing files (`ls | sort -V | tail -1` + 1): every parallel session picks the same slot at spawn, and the duplicate surfaces only on the last rebase. Timestamps remove the race by construction — two sessions creating a migration in the same UTC second is essentially impossible.
- Mixing with existing sequential migrations is fine: every common tool sorts numerically, `000036` < `20260509073812`, so new timestamp files come after the legacy ones. Leave history as-is; do NOT renumber.
- Legacy-duplicate scan (WARN only): `git -C {repo} branch -a | xargs -I{} git log {} --oneline -- {migration_dir} 2>/dev/null` — catches pre-existing sequential duplicates already committed on other branches. Duplicate found → WARN + note in issue; no STOP, timestamp prefixes cannot collide with in-flight work.

Origin: 2026-05-09 miro-rooms-rentals — three parallel `/do` agents each computed `000036` as next-free; the duplicate gate fired only on the third rebase, the second slipped to main via `--admin` merge.

**Context doc check** (only if `config.context_doc.required_for_finalize: true`):
- Set BLOCKING flag for Phase 4 finalize
- Read context doc now if exists; pass to Sonnet in Phase 2 (trim relevant sections if huge)

### 6. Complexity routing + model assignment + announce

If `$ARGUMENTS` has `--complexity=T|L|M|H` → use it.

Else estimate:

| Complexity | Files (est) | Lines added (est) | Other indicators | Workflow |
|---|---|---|---|---|
| **Trivial** | 1-2 | ≤50 | mechanical (typo/rename/comment/lint/dep bump/single constant), zero logic decisions | Haiku solo → Sonnet diff scan → commit |
| **Low** | ≤3 | ≤200 | single module, simple logic | Sonnet solo → Opus diff scan → commit |
| **Medium** | 4-8 | ≤600 | new module/API | Issue → Sonnet → Opus review |
| **High** | 9+ | >600 OR open-ended | new architecture, breaking changes, refactor across subsystems | Full pipeline + specialists + ADR |

**Estimate BOTH files AND lines, pick the higher bucket.** A task that touches only 5 files but plans ~1200 line changes is High, not Medium. Production audit (May 14–21): 6 of 13 false-positive cases on 2026-05-21 were Medium-routed tasks that actually shipped 942–1859 lines — Phase 0 underestimated lines, Sonnet self-claimed `ready`, Phase 3 caught with `pr_size=warn`. Catching at routing time avoids the wasted cycle.

**Refactor-keyword bumper.** If `$ARGUMENTS` contains any of: `refactor`, `rename`, `restructure`, `unify`, `consolidate`, `migrate <X> to <Y>`, `rewrite`, `extract <module>`, `split <module>` — prefer one tier higher than the file-count alone would suggest. Refactors compound across the codebase even when "only N files" are touched directly (every caller of a renamed symbol becomes a touched file).

Boundaries: 4 trivial files in one module → prefer Low. 3 files spanning new API surface → prefer Medium. **Any judgment call about behaviour → bump to Low** (Haiku must not pick between alternatives). If task touches migrations, security-sensitive code, public API, or i18n — never Trivial.

Ambiguity about user intent or observable behavior is never Trivial. Ask if it changes the outcome; otherwise record the assumption and choose the lowest complexity bucket that can verify the acceptance criteria.

**Test detection**: YES for new functions/services/handlers, logic changes, algorithms. NO for pure UI/CSS, config, docs. Test command from `cache.test_cmd`; if affected-graph is **in use** (Step 4 predicate — tool detected, config enabled, `--no-affected-graph` absent), scope via `nx affected:test` / `turbo run test --filter=...[main]`; otherwise run the full `cache.test_cmd`.

**Model assignment**:
- Orchestrator: always `opus` (per SKILL.md frontmatter `model: opus`)
- Implementer: T → `haiku`; L/M/H → `sonnet`
- `--implementer=X` flag overrides (announce as `implementer=X (override)`)

**Optional: notify start** if `config.notifications.events` includes `task_started`. See [`notifications.md`](notifications.md).

### Announce

After all 6 steps pass:

```
[Phase 0] Repo: {repo} | Stack: {stack} (cached: {y/n}) | Scope: {B/F/FS} | Complexity: {T/L/M/H}
  Files: ~{N} | EstLines: ~{L} | Tests: {YES/NO} | Migration: {YES {TS}/NO} | Context doc: {required/none}
  Models: orchestrator=opus | implementer={haiku|sonnet|opus per complexity, or override}
  Started: {STARTED_AT — the exact value echoed by the preflight task-clock capture, verbatim; Phase 4.11 reads the same value back from $CLOCK_FILE and cross-checks against this line}
  {$CAVEMAN_LINE — output of Step 2 bash, verbatim — DO NOT compose}
  {$CONFIG_LINE — output of Step 1 (LOADED) or Step 4 auto-init bash (AUTO-GENERATED | AUTO-INIT SKIPPED | NONE), verbatim — DO NOT compose; auto-init carries EXTRA wrapper lines — `Tracker: … OK (…)` | `Tracker: DEGRADED to none (…)` on github/gitlab detections, and `Specialists: PRESET VERIFIED|FILTERED|EMPTY|UNVERIFIED (…)` when the preset was requested — keep ALL lines, same verbatim rule}
  {$METRICS_CONFIG_LINE — output of Step 1 config-ensure-metrics or Step 4 mirror (ALREADY CONFIGURED | EXPLICIT OPT-OUT | AUTO-ADDED | INCLUDED in auto-init | SKIPPED | PATCH SKIPPED | N/A), verbatim — DO NOT compose; the three wrapper forms carry a runtime `(cfg=…)` fingerprint (§19i) — a wrapper form without it was composed by hand}
  WIP: {n}/{limit} | Affected-graph: {nx/turbo/none — or "disabled (flag)" when --no-affected-graph suppressed a detected tool}
  [+ if assumptions recorded → "Assumptions: {short list}"]
  [+ if simpler path chosen → "Tradeoff: {short explanation of narrower implementation}"]
  [+ if postmortem context → "ℹ Postmortem section will be added to issue"]
```

`Models:`, `Started:`, `$CAVEMAN_LINE`, `$CONFIG_LINE`, and `$METRICS_CONFIG_LINE` are **mandatory** — they make model usage, cycle-time anchor, companion-skill state, config state, and telemetry state explicit so users see (and metrics record) what the orchestrator decided. `Started:` doubles as the transcript-durable fallback for `--started-at`: if the clock file is wiped mid-task, Phase 4.11 reuses this exact value instead of inventing one.

The three structural-coupling lines (`$CAVEMAN_LINE`, `$CONFIG_LINE`, `$METRICS_CONFIG_LINE`) come **only** from the bash blocks in Step 2 / Step 4 / Step 1 wrapper respectively. The spec deliberately contains no copyable templates of their full form — if you "know what the line looks like" without running the bash, you're guessing. This is the same structural-enforcement pattern as `$METRICS_LINE` in Phase 4.13 (see [`phase-4-finalize.md`](phase-4-finalize.md) and [anti-patterns §19, §19a, §19b, §19c](anti-patterns.md)).

Suppression paths:
- `--no-affected-graph` → Step 4's "in use" predicate turns false for this task: full (unscoped) build/test commands everywhere (Step 6, Phase 1 Build Checklist, Phase 2 Build line, Phase 3 `build-verify`); announce shows `Affected-graph: disabled (flag)`. The cache keeps `affected_graph_tool` — durable fact, per-task flag.
- `--no-caveman` → Step 2 skipped, `$CAVEMAN_LINE=""`, line omitted from announce.
- `--no-config-init` → Step 4 auto-init skipped, `$CONFIG_LINE="Config: NONE — using defaults (--no-config-init)"`, line still printed.
- `--no-specialists` → Step 4 auto-init writes config WITHOUT `specialists` block; doesn't affect $CONFIG_LINE.
- `--no-metrics` → Step 1 patch + Step 4 auto-init both skip metrics. `$METRICS_CONFIG_LINE="Metrics config: SKIPPED (--no-metrics)"`.
