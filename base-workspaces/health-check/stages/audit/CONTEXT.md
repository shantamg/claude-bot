# Health Check — Audit Stage

You are performing a comprehensive health audit of this bot instance. Work through each section below in order, collecting status for each. At the end, compile and post a summary report.

## Environment

These variables are available at runtime:

- `$BOT_HOME` — Root directory of the bot installation (e.g., `/opt/claude-bot`)
- `$BOT_NAME` — Name of this bot instance (e.g., `peter`)
- `$BOT_LOG_DIR` — Log directory (typically `/var/log/$BOT_NAME`)
- `$BOT_PROJECT_DIR` — The project repo this bot operates on
- `$SLACK_OPS_CHANNEL` — Slack channel ID for operational reports

## Checks

### 1. System Resources

Run standard Linux commands to assess the host machine:

- **Disk**: `df -h` — flag any filesystem above 85% usage
- **Memory**: `free -h` — flag if available memory is below 500MB
- **CPU**: `uptime` — flag load average above the CPU count
- **Swap**: Check if swap is heavily used (above 50%)

### 2. Recent Logs

Scan log files under `$BOT_LOG_DIR/*.log` for problems:

- Search for `ERROR`, `FAIL`, `FATAL`, `PANIC` patterns in the last 200 lines of each log
- Search for `WARN` patterns — note count but treat as lower severity
- Check log file timestamps — a log that has not been written to in over 24 hours may indicate a dead process
- Report the top 3 most frequent error patterns if any exist

### 3. Cron Health

Verify scheduled jobs are running:

- Run `crontab -l` to confirm the crontab is installed and list entries
- Check `$BOT_LOG_DIR/cron.log` for recent entries — the most recent entry should be within the expected schedule interval
- Flag if cron.log has errors or if the last entry is stale (older than expected)

### 4. Agent Health

Check for stuck or orphaned agents:

- Look in `$BOT_HOME/workspaces/*/\_active/` for agent directories
- For each agent directory, read `meta.json` to get the PID and start time
- Verify the PID is still running (`kill -0 $PID`)
- Flag any agent that has been running for more than 2 hours as potentially stuck
- Flag any agent directory whose PID is no longer running as orphaned (stale lock)

### 5. Git Sync Health

Verify the project repo is up to date:

- `cd $BOT_PROJECT_DIR && git status` — flag uncommitted changes or dirty state
- Check `$BOT_LOG_DIR/git-pull.log` for recent errors (merge conflicts, auth failures)
- Compare local HEAD with remote: `git rev-list HEAD..origin/main --count` — flag if behind by more than 10 commits

### 6. GitHub Integration

Verify GitHub CLI access and notification processing:

- Run `gh auth status` to confirm authentication is valid
- Check `$BOT_LOG_DIR/github-poll.log` or notification logs for recent errors
- Verify that notification processing has run recently (check log timestamps)

### 7. Slack Integration

Verify the Slack socket listener is alive:

- Check for a running Slack listener process (e.g., `pgrep -f slack-socket` or equivalent)
- Check `$BOT_LOG_DIR/slack-socket.log` for recent errors or disconnection messages
- If a heartbeat file exists (e.g., `$BOT_HOME/.slack-heartbeat`), verify it was updated within the last 5 minutes
- Flag if the listener appears to be down or if heartbeat is stale

## Compile the Report

Build a health report using these status indicators:

- **HEALTHY** — No issues detected
- **WARNING** — Non-critical issue that should be investigated
- **CRITICAL** — Service is down or a serious problem exists

Format the report as a structured Slack message. Example:

```
:stethoscope: *Health Check Report — $BOT_NAME*
Timestamp: YYYY-MM-DD HH:MM UTC

*System Resources* — HEALTHY
  Disk: 42% used | Memory: 2.1GB free | Load: 0.5

*Logs* — WARNING
  3 ERROR entries in dispatcher.log (last 6h)
  Top pattern: "connection timeout" (x3)

*Cron* — HEALTHY
  Last run: 12 min ago | All schedules on track

*Agents* — HEALTHY
  0 active | 0 orphaned

*Git Sync* — HEALTHY
  Up to date with origin/main

*GitHub* — HEALTHY
  Auth valid | Last poll: 8 min ago

*Slack* — HEALTHY
  Listener running | Heartbeat: 2 min ago
```

## Post the Report

Use the `slack-post.sh` script to send the report to the ops channel:

```bash
$BOT_HOME/scripts/slack-post.sh "$SLACK_OPS_CHANNEL" "$REPORT"
```

If any section is CRITICAL, also mention `@ops` in the message so the team is alerted.

## Project-Specific Overrides

Projects that extend this workspace may add additional checks beyond what is covered here. Common additions include:

- **Database health** — connection pool status, replication lag, query latency
- **External API status** — uptime checks against third-party services the project depends on
- **Application-specific services** — websocket servers, background job queues, cache hit rates
- **Custom metrics** — business-logic health indicators (e.g., order processing pipeline, webhook delivery rates)
- **SSL/TLS certificate expiry** — flag certificates expiring within 30 days

Projects add these by creating their own `health-check` workspace that references this base and appends additional check sections. See the workspace cascade documentation for details on how to extend a base workspace.
