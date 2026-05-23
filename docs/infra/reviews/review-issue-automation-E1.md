---
decision: 稍后做
---

# Review E1: cc-connect Cron for Issue Automation

> Review of the cc-connect cron approach for polling GitLab issues.
> Design doc: `docs/infra/designs/issue-automation.md`

## Summary

The cc-connect cron approach (方案 C) is the recommended option — zero new infrastructure,
leverages existing cc-connect deployment. This review identifies operational risks and
mitigations.

## Findings

### 1. Cron Job Reliability

**Risk**: cc-connect cron jobs run in-process. If a cron script hangs or crashes,
cc-connect itself may be affected.

**Mitigation**: Wrap `check-issues.sh` with a timeout:

```sh
timeout 60 sh check-issues.sh
```

cc-connect should also isolate cron execution (separate process, kill on timeout).

### 2. State Persistence

**Risk**: `last_issue_id` must survive container restarts. If stored only in memory,
every restart re-notifies all existing issues.

**Mitigation**: Store state on a mounted volume (e.g., `/data/issue-automation/last_id`).
cc-connect cron exec runs inside the container but can write to the bind-mounted data
directory.

### 3. Duplicate Notifications

**Risk**: If `last_issue_id` write fails after a successful notification, the same issue
is re-notified on the next cycle.

**Mitigation**: Write `last_issue_id` **before** sending the notification. The trade-off
(rare missed notification vs. frequent duplicates) favors silent skip.

### 4. Cron Execution Monitoring

**Risk**: Silent cron failures — script exits with error, no notification sent, no
alert raised. Users assume automation is working.

**Mitigation**: Within the script, pipe errors to cc-connect's own logging. Consider a
heartbeat mechanism: if `check-issues.sh` has not run successfully in N cycles, send
an alert to the ops channel.

### 5. Race Conditions on Startup

**Risk**: On container restart, cc-connect cron may fire immediately. If the startup
sequence takes time, the first cron tick may run before dependencies (network, DNS)
are ready.

**Mitigation**: Add a startup delay or a readiness check at the top of the script.

### 6. cc-connect Availability

**Risk**: If cc-connect itself goes down (OOM, crash loop, network partition), the
entire polling mechanism stops.

**Mitigation**: Add a Docker-level restart policy (`--restart unless-stopped`) and
monitor cc-connect container health via Docker events or a simple uptime check.

## Conclusion

cc-connect cron is the correct choice (lowest maintenance, zero new infra). The risks
are manageable with state file persistence, execution timeouts, and basic monitoring.
**Approve with mitigations**.
