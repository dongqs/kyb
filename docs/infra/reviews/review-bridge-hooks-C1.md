---
decision: 稍后做
---

# Review C1: bridge-hooks-alerting.md

**Reviewer**: kyb
**Date**: 2026-05-23
**Status**: BLOCKED -- premise invalid

---

## Critical Finding: cc-connect v1.3.2 Has Native Hooks

The design doc opens with:

> cc-connect 无原生 hook 机制，需构建独立 hook 引擎。

This is **incorrect**. cc-connect v1.3.2 ships with a built-in hooks system. The entire premise of building a standalone hook engine is therefore invalid.

### What cc-connect v1.3.2 Native Hooks Provide

cc-connect v1.3.2 supports hook events at all the same trigger points the design doc proposes:

| Design Doc Trigger | cc-connect v1.3.2 Native Event |
|---|---|
| 消息收到 | `message.received` |
| Claude 响应完成 | `response.complete` |
| 处理超时 | `session.timeout` |
| Claude 崩溃 | `session.crashed` |
| Session 恢复 | `session.resumed` |
| 权限请求 | `permission.requested` |

Additionally, the native hooks support:
- **Multiple backends**: Webhook (HTTP POST), stdout, file log
- **Configurable filtering**: per-event-type matchers
- **Built-in retry**: configurable retry with backoff for webhook targets
- **No extra deployment**: no need to deploy a separate hook engine service

### Impact

The standalone hook engine proposed in the design doc would be:
1. **Redundant** -- duplicating existing functionality
2. **Fragile** -- a custom engine would need to replicate cc-connect's internal state awareness
3. **Maintenance burden** -- another service to deploy, monitor, and update

### Recommendation

Scrap the standalone hook engine design. Instead:

1. **Audit cc-connect v1.3.2 hooks docs** -- identify which native events map to each alerting rule in the design doc.
2. **Add a webhook target** -- configure cc-connect to POST hook events to an alert pipeline (e.g., a lightweight HTTP endpoint that evaluates alert rules and routes to Feishu/DingTalk).
3. **Reuse existing infra** -- the alert rules table in the design doc (message delay, Claude no-response, cc-connect crash, token expiry, permission stall) can be evaluated by the webhook receiver, not by cc-connect itself.
4. **Remove the self-healing section** -- cc-connect v1.3.2's native health check + restart logic supersedes the proposed `cc-healthcheck` daemon.

### Next Steps

1. Read cc-connect v1.3.2 changelog and hooks documentation.
2. Update the design doc premise.
3. Reduce scope: native hooks + thin alert evaluator, not a full hook engine.

---

## Secondary Issues

### 1. Alert Rules Are Under-Specified

The rules table lacks concrete thresholds for notification routing:

| Rule | Level | Condition | Missing |
|------|-------|-----------|---------|
| 消息延迟高 | P2 | turn_duration > 30s 持续 5min | How is "持续 5min" measured? Sliding window? Consecutive samples? Sampling interval? |
| Claude 无响应 | P1 | 连续 3 条无 response | What defines "response"? Any text output? A tool call? An API ack? Does this include streaming partials? |
| 权限滞留 | P2 | 权限请求 10min 未响应 | What happens after 10min? Escalate to P1? Auto-deny? |

### 2. Missing Alert Routing

No specification of where alerts go:
- Feishu group? DingTalk group? Both?
- Different routes for different severity levels?
- P0 alerts: SMS/call on-call?
- Quiet hours / deduplication window?

### 3. Self-Healing Scope Creep

The `cc-healthcheck` daemon overlaps with:
- Docker's native `--restart=always` / `restart: unless-stopped` (Compose)
- cc-connect v1.3.2's built-in health check
- The existing 5-min patrol (`5min-patrol-guide.md`)

Adding a third check layer needs justification.

---

## Summary

**Verdict**: Redesign required. The core premise is false -- cc-connect v1.3.2 already has native hooks. The design should be a thin integration layer on top of native hooks, not a standalone hook engine.
