---
decision: 现在就做
---

# Vector Pipeline — Standby Ready

> **Status:** Ready for go signal
> **Date:** 2026-05-23
> **Agent:** Claude Code (kyb)

## Reviewed Designs

| Document | Scope |
|----------|-------|
| `docs/infra/reviews/vector-pipeline.md` | Vector log pipeline for infra containers (cc-connect, boss, patrol, MCP). Docker log API + label discovery. ~1310 lines, covers full config, transforms, CK schemas, deployment. |
| `docs/infra/reviews/unified-vector.md` | Expanded scope: ALL containers via file tail of Docker json-log files, single `infra.message_log` canonical table, remote cluster forwarding. ~1285 lines, covers multi-cluster topology, migration strategy. |
| `docs/infra/reviews/otel-vector.md` | OTel Collector + Vector combined pipeline for traces/metrics/logs. Two-stage: Collector terminates OTLP, Vector enriches/routes to CK. ~1065 lines, covers three CK schemas (otel_spans, otel_metrics, otel_logs). |

## Ready to Deploy On Go Signal

### Phase 0: Foundation (vector-pipeline scope)

1. **Create CK tables:**
   - `cc.message_log` — structured cc-connect events (90d TTL)
   - `patrol.health_checks` — patrol health snapshots (30d TTL)
   - `boss.agent_log` — boss agent stdout (7d TTL)
   - `mcp.request_log` — MCP tool calls (30d TTL)

2. **Deploy Vector container** (Mac/Orbstack):
   - `timberio/vector:0.42.0-alpine`
   - Mount `/var/run/docker.sock:ro` (Docker log API)
   - Mount config from repo `docs/infra/vector/vector.toml`
   - Env: `VECTOR_CLUSTER=mac-orbstack`
   - Port: `8686:8686` (health API)

3. **Add labels** to existing infra containers:
   - `kyb.logs=true`, `kyb.service=<name>` on cc-connect, boss

4. **Verify data** lands in CK from Docker log discovery

### Phase 0b: OTel Pipeline (otel-vector scope)

1. **Create CK tables:** `kyb.otel_spans`, `kyb.otel_metrics`, `kyb.otel_logs`

2. **Deploy OTel Collector** container:
   - `otel/opentelemetry-collector-contrib:0.120.0`
   - Ports `4317` (gRPC), `4318` (HTTP)
   - Export to `vector:4319`

3. **Deploy Vector** (or extend existing):
   - `timberio/vector:0.44.0` (opentelemetry source support)
   - Port `4319` (OTLP gRPC from collector, internal)
   - Env: `CLUSTER_NAME=mac-orbstack`, `ENVIRONMENT=production`

4. **Point cc-connect OTLP** from tempo → otel-collector

### Phase 1+: Transforms & Enrichment

- Go duration parser for cc-connect `turn_duration`
- Session field parser (chat_id/sender_id extraction)
- `reduce` transform for msg_id-based join
- Cluster metadata enrichment on all events
- Route transforms to correct CK tables

## Key Deployment Commands

```bash
# Vector (core log pipeline)
docker run -d \
  --name kyb-infra-vector \
  --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v $(pwd)/docs/infra/vector/vector.toml:/etc/vector/vector.toml:ro \
  -v vector-data:/var/lib/vector \
  -e VECTOR_CLUSTER=mac-orbstack \
  --init \
  -p 8686:8686 \
  timberio/vector:0.42.0-alpine

# CK table creation
clickhouse-client --host host.orb.internal --query "$(cat docs/infra/vector/schemas/cc.message_log.sql)"
```

## Awaiting Go Signal

All three designs are fully reviewed. No open questions. Files for config (`vector.toml`) and SQL schemas need to be created in `docs/infra/vector/` before deployment begins.

> /人◕ ‿‿ ◕人＼
