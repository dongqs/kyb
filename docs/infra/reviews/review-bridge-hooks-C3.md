---
decision: 稍后做
---

# Review C3: Bridge Hooks + Alerting Design

Review of `docs/infra/designs/bridge-hooks-alerting.md`.

## Summary

The document is a minimal sketch (22 lines). The hook trigger points and alert rules table are a good starting point, but the design lacks depth in alert definitions, escalation paths, and—most critically—**cc-healthcheck coverage** has a dangerous blind spot.

## cc-healthcheck Coverage Analysis

### Current Scope (from 5min-patrol-guide.md)

```
~/.kyb/bin/cc-healthcheck:
  1. Container running
  2. Docker HEALTHCHECK status
  3. Feishu API token validity
```

### What This Covers

| Check | Catches | Misses |
|-------|---------|--------|
| Container running | Container crash, OOM kill | Healthy container with broken internal process |
| Docker HEALTHCHECK | Basic TCP/HTTP liveness | Logic-level degradation (Claude stuck, message loop dead) |
| Feishu token | Token expired, API credential rotated | Token works but message send/recv pipeline broken |

### Critical Blind Spots (confirmed by incident 2026-05-23)

The unreachable-boss incident demonstrated a failure mode that cc-healthcheck could not detect:

1. **cc-connect container was HEALTHY** (Docker healthcheck green)
2. **Feishu token was valid** (messages could be sent)
3. **But the user->Claude->infra-boss path was broken** — cc-connect's Claude processed messages but no notification reached kyb-infra-boss
4. **The patrol ran cc-healthcheck every 5 minutes and reported all green** — the incident was invisible for ~3 hours

### Proposed Coverage Gaps

| Gap | Severity | Description |
|-----|----------|-------------|
| Claude process health | P1 | cc-connect container can be healthy while the Claude Code process inside is dead or stuck. No check probes Claude responsiveness. |
| Message round-trip | P1 | No end-to-end test: send a self-test message through the bridge, verify it comes back. Without this, silent failures in the message pipeline are undetectable. |
| Hook pipeline liveness | P2 | The Claude->CK hook pipeline can go silent without any alert. The hooks-ck-pipeline doc mentions a 15-min silence alert but it lives outside the cc-healthcheck script. |
| Patrol heartbeat integrity | P2 | Patrol heartbeat files can become stale without triggering alert (the patrol guide says "check brothers >15min stale" but cc-healthcheck doesn't verify this). |
| Session recovery status | P2 | After a cc-connect restart, does session recovery actually work? No post-restart verification step. |

## Alert Rules Review

The current 5-rule table (from the design doc):

| Rule | Level | Condition | Issue |
|------|-------|-----------|-------|
| Message latency high | P2 | turn_duration >30s for 5min | P2 feels too low: 30s latency means the bot is unusable. Should be P1. |
| Claude no response | P1 | 3 consecutive messages no response | Correctly P1. But how is "no response" detected? Needs implementation detail. |
| cc-connect crash | P0 | container unhealthy | P0 is correct. But "unhealthy" is too narrow — see coverage gaps above. |
| Token expired | P1 | Feishu API token refresh fails | P1 is reasonable. Auto-retry logic should be specified. |
| Permission stuck | P2 | Permission request 10min no response | P2 is appropriate. |

### Missing Alert Rules

| Rule | Suggested Level | Rationale |
|------|----------------|-----------|
| Message received but no response (per message) | P1 | cc-connect gets the message but Claude never replies. Different from "Claude no response" counter. |
| Hook silence >15min | P2 | Claude is working but hooks pipeline is broken — observability gap, not operational gap. |
| cc-connect heartbeat stale | P1 | cc-connect should emit a periodic heartbeat. If missing for 2 cycles, assume dead. |
| Patrol brother dead | P2 | One of the 3 patrol cron processes hasn't updated heartbeat in >15min. |

## Recommendations

1. **Extend cc-healthcheck** to probe Claude process responsiveness (e.g., `docker exec cc-connect claude -p 'echo ok'` with timeout).
2. **Add a self-test message loop**: send a periodic test message through the Feishu bridge, verify it comes back within a timeout. This catches silent pipeline breaks.
3. **Promote message latency alert to P1** — 30s latency makes the system unusable.
4. **Add a "message received, no response" counter-based alert** at the cc-connect level, separate from the Claude no-response counter.
5. **Specify notification channels per alert** — which alerts go to Feishu group, which go to kyb-infra-boss session, which trigger auto-remediation.
6. **Document escalation paths** — if P0 alert fires and auto-remediation fails, what happens? Who gets notified next?
7. **Add implementation detail for each hook trigger point** — the current doc lists 6 trigger points but provides no implementation approach for any of them.

## Conclusion

The bridge hooks and alerting design is a solid skeleton but needs substantial flesh. The most urgent gap is cc-healthcheck's inability to detect the failure mode experienced in the 2026-05-23 unreachable-boss incident: a healthy container with a broken message pipeline. Without closing this gap, the alerting system provides a false sense of safety.

---

Reviewer: kyb-infra-boss
Date: 2026-05-23
