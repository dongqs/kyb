---
decision: 稍后做
---

# Review C2: bridge-hooks-alerting.md

**Reviewer**: boss  
**Date**: 2026-05-23  
**Document**: `docs/infra/designs/bridge-hooks-alerting.md`

## Summary

Defines hook trigger points (6 events), alert rules (4 rules, P0-P2), self-healing via cc-healthcheck docker restart, and 5min patrol integration. Minimal two-page design, quick to implement.

## What Works

1. Trigger point coverage is reasonable — message receive, response, timeout, crash, session recovery, and permissions cover the main failure modes.
2. Severity grading (P0-P2) is correct: container unhealthy = P0, API token failures and silent Claude = P1, latency/permissions = P2.
3. Self-healing loop (healthcheck -> docker restart) is pragmatic — no need for K8s-level orchestration for a single container.
4. 5min patrol integration is a sensible safety net for edge cases the hook engine might miss.

## Grafana Alerting Status: NOT COVERED

This is the biggest gap in the current design.

### Current State

The document defines alert rules with severity levels but **does not specify how alerts are surfaced, visualized, or managed**. Grafana is not mentioned once. The observability-design.md references Grafana only for message-log dashboards (cc.message_log table), not for alerting.

The implied delivery path is:
- Feishu group messages (ad-hoc) + 5min patrol (polling)

This is insufficient for P0/P1 conditions that need real-time visibility.

### What's Missing

1. **No Grafana alerting rules defined**. Grafana has a built-in alerting engine that can query ClickHouse (or any datasource) and route through notification channels. P0/P1 conditions should be configured as Grafana Managed Alerts with proper evaluation intervals (e.g., 30s for P0, 1min for P1).

2. **No dashboard**. A `cc-connect` health dashboard in Grafana should show:
   - Container state (up/down/restarts)
   - Turn latency history
   - Claude response success rate
   - Token refresh status
   - Active session count

3. **No notification routing policy**. Grafana alerting supports silences, grouping, and escalation. P0 should page immediately; P2 can batch into a daily digest. The current design has no escalation path.

4. **No evaluation interval or for-duration logic**. "turn_duration > 30s 持续 5min" is a sensible condition, but the design doesn't say how this is evaluated. Grafana's alerting engine handles this natively with `for` duration.

5. **No alert history / noise reduction**. Without Grafana's alert state history, diagnosing flapping or recurring failures requires grepping Feishu chat history.

### Recommendation

| Component | Action | Priority |
|-----------|--------|----------|
| Grafana alert rules | Define ClickHouse queries for each P0/P1 condition; configure evaluation intervals (P0: 30s, P1: 60s) | **Required before ship** |
| cc-connect dashboard | Create a Grafana dashboard with container health, latency, error rates | **Required before ship** |
| Notification channels | Add Grafana Contact Points for Feishu webhook + email fallback; set up escalation for P0 unacknowledged >5min | **Recommended** |
| Self-healing visibility | Log healthcheck-triggered restarts into a ClickHouse event table so Grafana can show restart history | **Recommended** |

## Other Gaps

1. **No delivery SLA for alerts**. How fast must a P0 notification reach the operator? The patrol runs every 5min, which is too slow for P0.

2. **No mention of mute/silence**. During maintenance, the alerting system should support silencing P0/P1 without disabling the hook engine.

3. **No test plan**. How do you verify that a hook fires correctly? The document should include a testing strategy (e.g., inject a fake timeout, verify alert fires).

4. **Missing hook for cc-connect startup**. If cc-connect restarts, the hook engine should reinitialize and emit a "service recovered" event so Grafana can clear the alert state.

## Verdict

The hook trigger points and alert rule definitions are a solid start, but **Grafana alerting is a prerequisite for shipping P0/P1 alerts**. Without it, the operators have no real-time view, no alert history, and no escalation path — effectively making the P0/P1 labels aspirational rather than operational.

**Blocking**: Define Grafana alerting rules and a health dashboard before calling this design complete.
