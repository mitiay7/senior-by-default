# Notifications (Slack / Teams Webhooks)

Async-friendly broadcasts at Phase boundaries. Triggered when `config.notifications.{slack_webhook | teams_webhook}` is set. Skipped silently otherwise.

## Events

`config.notifications.events` selects which boundaries broadcast. Available:

| Event | Fires at | Default body |
|---|---|---|
| `task_started` | After Phase 1 issue creation (M/H) OR after Phase 0.4 announce (Low) | "Started {ref_format}: {title} → {url}" |
| `task_blocked` | When Phase 3 escalates after 3 cycles, or Phase 2 budget exhaustion, or any STOP | "Blocked {ref_format}: {reason} → {issue_url}" |
| `task_completed` | After Phase 4.7 issue comment | "Completed {ref_format}: PR {pr_url} merged via auto-merge" or "ready for review" if no auto-merge |
| `migration_proposed` | When Phase 0.6 detects new migration | "Migration {TS} proposed in {ref_format} ({migration_dir})" |
| `ci_failed` | When Phase 4.2.5 CI gate detects failure | "CI failed for {ref_format}: {failed_check_names}" |

Defaults: `["task_started", "task_blocked", "task_completed"]`. Set to empty array to disable all.

## Webhook formats

### Slack (Incoming Webhook)

```bash
curl -X POST -H 'Content-Type: application/json' \
  --data '{
    "text": "Started i42: Add user avatars to settings → https://github.com/.../issues/42",
    "blocks": [
      {
        "type": "section",
        "text": { "type": "mrkdwn", "text": "*Started i42*\nAdd user avatars to settings\n<https://github.com/.../issues/42|View issue>" }
      }
    ]
  }' \
  $SLACK_WEBHOOK_URL
```

Plain `text` is a required fallback; `blocks` provides rich formatting in Slack clients that support it. For terse notifications, just `text` is fine.

### Microsoft Teams (Incoming Webhook)

```bash
curl -X POST -H 'Content-Type: application/json' \
  --data '{
    "@type": "MessageCard",
    "@context": "https://schema.org/extensions",
    "summary": "Task started",
    "themeColor": "0076D7",
    "title": "Started i42",
    "text": "Add user avatars to settings",
    "potentialAction": [
      { "@type": "OpenUri", "name": "View issue", "targets": [{ "os": "default", "uri": "https://github.com/.../issues/42" }] }
    ]
  }' \
  $TEAMS_WEBHOOK_URL
```

`themeColor` per event type:
- `task_started`: `"0076D7"` (blue)
- `task_blocked` / `ci_failed`: `"FF0000"` (red)
- `task_completed`: `"00CC00"` (green)
- `migration_proposed`: `"FFA500"` (orange)

## Templates

`config.notifications.templates` per event. Mustache-style placeholders:

| Placeholder | Value |
|---|---|
| `{title}` | Task title (from `$ARGUMENTS`) |
| `{N}` | Issue number / id |
| `{ref}` | Formatted issue ref (per `config.naming.issue.ref_format`) |
| `{url}` | Issue URL (from `{Tracker.view_url}`) |
| `{pr_url}` | PR URL (after Phase 4.2) |
| `{branch}` | Branch name |
| `{repo}` | Code repo (e.g. `lea-api`) |
| `{summary}` | One-line summary of changes (Phase 4.3 / 4.7) |
| `{reason}` | Block/failure reason (only for `task_blocked` / `ci_failed`) |
| `{author}` | Git author name (current user) |

Default templates use minimal text bodies. Override per event for organization-specific style.

## Implementation notes

- Send via `curl -X POST -H 'Content-Type: application/json' --data {body}` — no SDK dependency
- **Don't block the workflow on notification failure** — Phase work continues even if webhook returns 4xx/5xx. Log the failure to user output once.
- **Don't notify for retries / cycles within a Phase** — only Phase boundaries. `task_blocked` is for terminal failures, not gate retries.
- **Rate limiting**: most webhook providers cap at 1 req/sec. Phase boundaries are sparse enough that this never matters in practice.
- **Secrets**: webhook URLs are secrets — never commit to repo. They live in `config.json` which should be gitignored if the workspace path is in a repo. If your config sits OUTSIDE any tracked repo (e.g., a workspace dir holding multiple sibling repos), it can hold webhook URLs safely.

## Multi-channel routing (future)

If different events should go to different channels: extend schema to `config.notifications.channels[].{name, webhook, events}`. Not implemented in v1 — current model is single-channel-per-platform.

## Disabling for one task

Add `--no-notify` flag to `$ARGUMENTS` to skip notifications for that task only.
