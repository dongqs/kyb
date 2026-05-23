# kyb Infrastructure Master Report

> **Generated:** 2026-05-22 19:02 CST
> **Author:** kyb-infra-boss
> **Status:** Phase 0 (Foundation) in progress
> **Source docs:** See `/home/dev/projects/kyb/docs/infra/` directory

---

## Table of Contents

1. [Infrastructure Services Status](#1-infrastructure-services-status)
2. [Project Infrastructure Survey Summary](#2-project-infrastructure-survey-summary)
3. [Known Issues & Blockers](#3-known-issues--blockers)
4. [Network Topology](#4-network-topology)
5. [System Resources](#5-system-resources)
6. [Rollout Plan Status](#6-rollout-plan-status)
7. [Recommended Next Steps](#7-recommended-next-steps)

---

## 1. Infrastructure Services Status

### 1.1 Running Services

| Service | Status | Port(s) | Container | Image | Notes |
|---------|--------|---------|-----------|-------|-------|
| Sing-box (Proxy) | ✅ Running | 2080 | kyb-infra-sing-box | kyb-sing-box:1.13.11 | SOCKS5 + HTTP mixed proxy, all traffic routed |
| Redis 7 | ✅ Running | 6379 | kyb-infra-redis | redis:7-alpine | AOF enabled, 512MB limit, allkeys-lru |
| Kafka (KRaft) | ✅ Running | 9092 | kyb-infra-kafka | apache/kafka:latest | Single-node KRaft mode, 512MB heap |
| PostgreSQL 14 | ✅ Running | 5434 | kyb-infra-postgresql-14 | postgres:14-alpine | Trust auth, TZ Asia/Shanghai |
| PostgreSQL 16 | ✅ Running | 5436 | kyb-infra-postgresql-16 | postgres:16-alpine | Trust auth, TZ Asia/Shanghai |
| ClickHouse 24.2 | ✅ Running | 8123/9000 | kyb-infra-clickhouse | clickhouse/clickhouse-server:24.2-alpine | Containerized, 4 system DBs, no user data |
| Boss Agent | ✅ Running | - | kyb-infra-boss | kyb-base | AI orchestration container |
| kyb-teams | ✅ Running | - | kyb-kyb-teams | kyb-base | Teams service container |

### 1.2 Missing / Not Yet Deployed

| Service | Status | Blocker | Action Required | Priority |
|---------|--------|---------|----------------|----------|
| PostgreSQL 15 | ❌ Not pulled | Image not pulled | `docker pull postgres:15-alpine` + deploy | High |
| PostgreSQL 17 | ❌ Not pulled | Image not pulled | `docker pull postgres:17-alpine` + deploy | High |
| Grafana | ❌ Image blocked | `docker.xuanyuan.me` rate limit (429) | Pull via ALL_PROXY from Docker Hub, or use alternative mirror | Medium |
| PeerDB | ❌ ghcr.io denied | `ghcr.io/peerdb-io/*` needs auth | Authenticate to ghcr.io with GitHub PAT, or use Kafka engine fallback | Medium |
| PeerDB catalog DB | ❌ Not created | Pre-req for PeerDB | `CREATE DATABASE peerdb_catalog` on PG16 | Medium |
| PG15/PG17 volumes | ❌ Not created | Pre-req for run commands | `docker volume create pg15-data; docker volume create pg17-data` | High |
| APT cache proxy | ❌ Not deployed | Not planned yet | Set up local apt-cacher-ng for faster package installs | Low |

### 1.3 Configuration Issues

| Issue | Details | Impact |
|-------|---------|--------|
| NO_PROXY empty | `NO_PROXY` not set in containers | ClickHouse traffic may route through proxy, causing latency |
| config.yml read-only | Mounted from host, cannot be modified inside container | Agents cannot register projects directly |
| Docker mirror rate limit | `docker.xuanyuan.me` returns 429 | Slows image pulls, especially for CI |

### 1.4 Database Provisioning Status

| PG Version | DBs Created | Used By |
|------------|-------------|---------|
| PG 14 | `postgres` (default) | timeline, variable-graph, buyer-center, dredge-lxk, oms-lxk, trade, chat-stream |
| PG 15 | Not deployed | lighthouse (needs 15.3), store-home, ecplatform, assistant, bot-trainer |
| PG 16 | `postgres` (default) | General purpose, PeerDB catalog (future) |
| PG 17 | Not deployed | Future-proofing |

---

## 2. Project Infrastructure Survey Summary

### 2.1 Survey Coverage

| Survey Doc | Projects Scanned | Key Groups | Status |
|------------|-----------------|------------|--------|
| `survey-base-service.md` | 10 | trade, chat-stream, lighthouse, store-home, assistant, ecplatform, treasure, bot-trainer, picture-sync, base-service-common | Complete |
| `survey-oversea-digismart.md` | ~40 (25 oversea + 14 digismart + rest) | Oversea, Digismart, RPA | Complete |
| `survey-remaining.md` | ~30 | dialogue-engine, ai, EP, leyan, marketing, recommendation, RPA/lebots | Complete |

### 2.2 By Tech Stack

#### Java + Maven (dominant, ~70% of all backend projects)

| Sub-stack | Count (est.) | PG Version | JDK | Key Projects |
|-----------|-------------|------------|-----|-------------|
| Java Maven PG 14 | ~12 | 14 | 8/21 | trade, timeline, variable-graph, buyer-center, dredge-lxk, oms-lxk |
| Java Maven PG 15 | ~5 | 15 | 8/21 | lighthouse, store-home, ecplatform, assistant, bot-trainer |
| Java Maven PG 15 (pgvector) | ~2 | 15 w/ pgvector | 21 | assistant, bot-trainer |
| Java Maven (no DB) | ~10 | - | 8/21 | treasure, netflix, policy-tools, common-libs |
| Java Maven MySQL | ~25 (oversea) | - | 8/21 | overseaim-store-home, overseaim-trade, overseaim-item, digismart-alipay |
| Java Maven (unknown DB) | ~15 | Unknown | Various | oversea subgroup services |

#### Python

| Type | Count (est.) | Python Version | Key Projects |
|------|-------------|---------------|-------------|
| Flask/Web | ~5 | 3.8/3.11 | oversea_mkt_door, oversea_mkt_ip_proxy |
| Robot Framework (RPA) | ~20 | Python 3.x | monitor_refund_new, pdd_feedback_central, taobao_refund |
| AI/ML | ~5 | 3.11 | business-rule, citi |
| Library | ~3 | 3.8/3.11 | leyan-proto, leyan-avro, robot-types |
| RPA lebots | ~60 | Python | Various automation scripts under digismart/rpa/lebots |

#### Other

| Type | Count (est.) | Notes |
|------|-------------|-------|
| Node.js / TypeScript | ~25 | Frontend subgroup (oversea/front), invoice-robot-cloud, mola-service |
| Go | ~3 | leyan-proto-golang, jolect-claw-go |
| Bun | ~1 | invoice-robot-cloud |
| Static sites | ~1 | sites (Vue.js) |
| Unknown/Private | ~5 | feisuo-app, feisuo-work-order, policy-codex-api, oppo-v2 |

### 2.3 By Infrastructure Dependency

| Dependency | Projects Needing It (est.) | Service Status | Notes |
|------------|---------------------------|----------------|-------|
| PostgreSQL 14 | ~15 | ✅ Running | Most common PG version |
| PostgreSQL 15 | ~7 | ❌ Not deployed | lighthouse, store-home, ecplatform, assistant, bot-trainer |
| PostgreSQL 16 | ~5 | ✅ Running | Newer projects |
| PostgreSQL 17 | ~3 | ❌ Not deployed | Future projects |
| Redis | ~15 | ✅ Running | chat-stream, ecplatform, common-libs, oversea services |
| Kafka | ~20 | ✅ Running | chat-stream, ecplatform, common-libs, oversea services, digismart services |
| ClickHouse | ~5 | ✅ Running | bot-trainer, oms-lxk, lxk-marketing projects |
| MySQL | ~40 (oversea) | ❌ Not deployed | Major gap for oversea group |
| Elasticsearch | ~3 | ❌ Not deployed | overseaim-hi, item-cluster, dgt-global-search |
| RocketMQ/ONS | ~3 | ❌ Not deployed | chat-stream, base-service-common |
| pgvector | ~2 | ❌ Not configured | assistant, bot-trainer need PG 15 + pgvector extension |

### 2.4 Java Version Distribution

| JDK | Projects (representative) | Count (est.) |
|-----|--------------------------|-------------|
| Java 8 (1.8) | chat-stream, lighthouse, ecplatform, treasure, bot-trainer, picture-sync, timeline, dredge-lxk, oms-lxk, oversea-agent, oversea-policy, theia | ~20 |
| Java 21 | trade, store-home, assistant, base-service-common, buyer-center, oversea-tunnel, oversaim-hi-manager | ~10 |
| Java 17 | Available in base images (maven-build:latest) | Runtime for unversioned |

### 2.5 Key Architectural Findings

1. **Oversea group (165 projects)** is structurally parallel to Base-Service but uses **MySQL** instead of PostgreSQL, and **Redis + Kafka** are ubiquitous (~70% of services).
2. **Digismart group (200 projects)** has a dual-stack architecture: Python 3.8/3.11 for RPA/bots, Java for enterprise services. It has its own Docker runner pool.
3. **RPA lebots (~60 projects)** under digismart/rpa/lebots are all stateless Robot Framework (Python) scripts with zero infrastructure dependencies.
4. **MySQL gap is the largest infrastructural blind spot**: ~40 oversea projects and 3 base-service projects depend on MySQL, which is not deployed in kyb-infra.
5. **Elasticsearch gap**: 3 projects (overseaim-hi, item-cluster, dgt-global-search) need ES, which is not containerized (ARM64 complexity).

### 2.6 Already Onboarded Projects

18 projects have been onboarded and converged:
- dredge-lxk, buyer-center, buyer-server, nova, data-ant, triggers-refund, form-manager, moneta, rating-boost, netflix, recommendation-filter, recommendation-config, recommendation-finder, peroration, lighthouse, sidecar, citi, business-rule

~14 are registered in `~/.config/kyb/config.yml`. ~50-60 remain across all groups.

---

## 3. Known Issues & Blockers

### 3.1 Infrastructure Blockers

| # | Issue | Impact | Workaround | Resolution |
|---|-------|--------|------------|------------|
| 1 | **config.yml read-only mount** | Agents cannot register projects | Manual edit via host volume | Remount as writable |
| 2 | **Docker mirror rate limit** (429 on docker.xuanyuan.me) | Slow/failed image pulls | ALL_PROXY direct pull; try alt mirrors (docker.1ms.run) | Set up ACR mirror |
| 3 | **ghcr.io access denied** | PeerDB and other ghcr images blocked | Use Kafka engine fallback; authenticate with GitHub PAT | `echo $PAT \| docker login ghcr.io -u <user> --password-stdin` |
| 4 | **NO_PROXY not configured** | CK traffic routed through proxy | Set `NO_PROXY="host.orb.internal,kyb-infra-*,localhost,127.0.0.1"` | Fix in entrypoint.sh |
| 5 | **Docker Hub blocked from Aliyun** | Pulls from sim ECS fail | Always route through kyb-infra-sing-box proxy | Set up ACR image sync |
| 6 | **ARM64 compatibility** | Some native libs fail (netty, grpcio) | Use CORRETTO JDK; find ARM wheels | Per-project fix in .kyb.md |
| 7 | **Grafana image blocked** | Observability delayed | Use ALL_PROXY to pull from Docker Hub directly | Pull attempt: `ALL_PROXY=socks5://... docker pull grafana/grafana-oss` |
| 8 | **PG15/PG17 not pulled** | Projects needing these versions blocked | Use PG14/16 as temporary alternative | `docker pull postgres:15-alpine; docker pull postgres:17-alpine` |
| 9 | **No MySQL container** | ~40 oversea projects blocked | Cannot test MySQL-dependent projects | Deploy MySQL 8.0 container |
| 10 | **No pgvector extension** | assistant, bot-trainer blocked | Cannot run AI feature tests | Add pgvector to PG15 Dockerfile |

### 3.2 Network Issues

| # | Issue | Impact | Details |
|---|-------|--------|---------|
| 1 | **CGNAT on nuc8's ISP** | Tailscale P2P fails, must relay through sim | Both home and office behind restrictive NAT |
| 2 | **sim's 3 Mbps bandwidth** | Bottleneck for all proxy traffic | Aliyun 99-plan ECS, 3 Mbps fixed |
| 3 | **SSH tunnel TCP-over-TCP** | Connection instability, zombie processes | SSH tunnel through sim compounds TCP issues |
| 4 | **No direct TCP to nuc8** (port 2080 filtered) | Cannot bypass sim for GitLab access | CGNAT + office firewall |

### 3.3 Build & CI Issues

| # | Issue | Impact | Details |
|---|-------|--------|---------|
| 1 | **Nexus 403 on leyantech.leyan/chaos repo** | Some builds fail | VPN/routing issue with proxy |
| 2 | **Submodule auth failures** | `git submodule update` fails | SSH agent needs key loading |
| 3 | **JDK 8 required but not installed** | JDK8 projects blocked | Need `mise install java@corretto-8` |
| 4 | **Build cache bloat (20.58 GB)** | Disk pressure | 97% reclaimable: `docker builder prune -a -f` |

### 3.4 Process Issues

| # | Issue | Impact | Details |
|---|-------|--------|---------|
| 1 | **No TTY available** | Cannot use `kyb enter` | Use `kyb create` + `kyb exec` instead |
| 2 | **Agent context limits** | Reduced effectiveness | Batch 3-6 per wave, use templates |
| 3 | **Knowledge retention** | Each agent starts fresh | Onboarding templates + .kyb.md mitigate |

---

## 4. Network Topology

### 4.1 Current Architecture

```
macOS Host (Orbstack, home broadband)
  Docker kyb-net (192.168.97.0/24)
  │
  ├── kyb-infra-sing-box     (192.168.97.2:2080, SOCKS5+HTTP proxy)
  ├── kyb-infra-redis        (192.168.97.x:6379)
  ├── kyb-infra-kafka        (192.168.97.x:9092)
  ├── kyb-infra-postgresql-14 (192.168.97.x:5432 → host:5434)
  ├── kyb-infra-postgresql-16 (192.168.97.x:5432 → host:5436)
  ├── kyb-infra-clickhouse   (192.168.97.x:8123/9000)
  ├── kyb-infra-boss         (AI orchestration)
  └── kyb-kyb-teams          (Teams service)

Proxy Chain:
  Container (ALL_PROXY=socks5://kyb-infra-sing-box:2080)
    → sing-box routing:
      - ai-extra (anthropic.com) → Relay-US2 (Shadowsocks)
      - cn-ip (deepseek.com) → Direct
      - nuc8-proxy (git.leyantech.com) → SSH tunnel → sim → Tailscale → nuc8
      - default → Relay-JP2 (Shadowsocks)
```

### 4.2 Key Traffic Routes

| Traffic | Path | Latency | Notes |
|---------|------|---------|-------|
| DeepSeek API (Claude Code) | Direct (cn-ip match) | ~80ms | Chinese IPs, no relay |
| GitLab (git.leyantech.com) | sing-box → SSH tunnel → sim (47.100.71.220) → Tailscale → nuc8 (100.98.29.39) | ~80ms | TCP-over-TCP bottleneck |
| Docker Hub pulls | sing-box → Relay-JP2 (103.181.1.45, MonoCloud Tokyo) | Variable | 3 Mbps bottleneck via sim |
| ClickHouse (host.orb.internal) | Direct (internal) | <1ms | No proxy for infra traffic |

### 4.3 Planned Improvements

| Improvement | Status | Impact | Effort |
|-------------|--------|--------|--------|
| **Eliminate SSH tunnel** (sing-box → nuc8 direct via Tailscale) | Planned | Reduces latency, removes TCP-over-TCP | 5 min |
| **ACR registry cache** (Aliyun Container Registry) | Not started | Fast Docker pulls for builds | 2 hours |
| **IP whitelist on nuc8** | Not started | Bypasses sim completely for GitLab | 30 min + sudo |
| **ISP CGNAT removal** for nuc8 | Long-term | Enables Tailscale P2P, full bandwidth | Phone call to ISP |
| **High-bandwidth relay** | Not started | Solves bandwidth bottleneck | Cost dependent |

### 4.4 Tailscale Connectivity

| Connection | Type | Latency | Status |
|------------|------|---------|--------|
| host (dongqs-mac) → nuc8 | Peer-relay via sim | ~17ms | No direct P2P (CGNAT) |
| host → sim | Direct | ~15ms | Working |
| nuc8 → sim | Direct | ~11ms | Working |

---

## 5. System Resources

### 5.1 Current Snapshot (2026-05-22 19:02)

| Resource | Total | Used | Available | Status |
|----------|-------|------|-----------|--------|
| CPU | 10 cores | Load 5.52 | ~4.5 cores idle | Healthy (load < 15 threshold) |
| RAM | 15 GiB | 6.7 GiB | 9.0 GiB | Healthy (well above 4 GiB min) |
| Disk (overlay) | 261 GiB | 50 GiB (19%) | 212 GiB | Healthy |
| Docker images | 54.23 GiB | 30 images | 14.15 GiB reclaimable | Good |
| Build cache | 20.58 GiB | 419 entries | 20.05 GiB reclaimable | Needs pruning |

### 5.2 Container Resource Usage

| Container | CPU % | MEM Usage | Limit |
|-----------|-------|-----------|-------|
| kyb-infra-boss | 30.25% | 979.9 MiB | 15.65 GiB |
| kyb-kyb-teams | 7.39% | 1.293 GiB | 15.65 GiB |
| kyb-infra-clickhouse | 1.63% | 488.2 MiB | 15.65 GiB |
| kyb-infra-kafka | 0.78% | 306.6 MiB | 15.65 GiB |
| kyb-infra-redis | 0.32% | 4.262 MiB | 15.65 GiB |
| kyb-infra-sing-box | 0.16% | 46.56 MiB | 15.65 GiB |
| kyb-infra-postgresql-14 | 0.00% | 15.49 MiB | 15.65 GiB |
| kyb-infra-postgresql-16 | 0.00% | 18.98 MiB | 15.65 GiB |

### 5.3 Capacity Limits

| Constraint | Limit | Max Concurrent Sandboxes |
|------------|-------|-------------------------|
| RAM (9 GiB available / 2 GiB per sandbox) | ~4-5 | Conservative limit |
| Disk (212 GiB / 500 MiB per sandbox) | ~424 | Not a bottleneck |
| CPU (10 cores / 0.5 per active build) | ~20 | Not a bottleneck |
| Practical RAM limit | ~6-10 | Including build overhead |

### 5.4 Monitoring Thresholds

| Metric | Warning | Critical | Current |
|--------|---------|----------|---------|
| Load average (10 cores) | >8 | >15 | 5.52 |
| Free memory | <4 GiB | <2 GiB | 9.0 GiB |
| Free disk | <20 GiB | <10 GiB | 212 GiB |
| Active containers | >20 | >30 | 8 |

**Conclusion**: Resources are healthy. Can dispatch 6 concurrent onboarding agents without issue.

---

## 6. Rollout Plan Status

### 6.1 Phase 0 Checklist (Foundation)

| Task | Status | Notes |
|------|--------|-------|
| Prune Docker build cache (-20GiB) | ❌ Not done | `docker builder prune -a -f` |
| Pull PG15 image | ❌ Not done | Need to run: `docker pull postgres:15-alpine` |
| Pull PG17 image | ❌ Not done | Need to run: `docker pull postgres:17-alpine` |
| Deploy PG15 container | ❌ Not done | Pending image pull + volume creation |
| Deploy PG17 container | ❌ Not done | Pending image pull + volume creation |
| Pull Grafana image | ❌ Blocked | Mirror rate limit; try ALL_PROXY direct pull |
| Deploy Grafana container | ❌ Blocked | Pending image pull |
| Enable logical replication on PG16 | ❌ Not done | Need wal_level=logical |
| Create CK Kafka engine tables | ❌ Not done | For PeerDB alternative |
| Set ghcr.io auth | ❌ Not done | Need GitHub PAT |
| Add NO_PROXY to entrypoint.sh | ❌ Not done | Fix proxy routing |
| Dispatch Wave 2a onboarding | ❌ Not started | policy-tools, common-libs, assistant, store-home |

### 6.2 Completed

- [x] PG14 deployed and running (port 5434)
- [x] PG16 deployed and running (port 5436)
- [x] Redis 7 deployed and running (port 6379)
- [x] Kafka (KRaft) deployed and running (port 9092)
- [x] ClickHouse 24.2 deployed and running (ports 8123/9000)
- [x] Sing-box proxy deployed and running (port 2080)
- [x] All 3 survey docs completed (base-service, oversea-digismart, remaining)
- [x] 100-project rollout plan documented
- [x] PeerDB alternatives research completed
- [x] Claude hooks -> ClickHouse pipeline designed
- [x] Network capture strategy designed
- [x] Direct network options analyzed (nuc8, Tailscale)
- [x] Aliyun network options analyzed (ACR, OSS, sim)
- [x] cc-connect research completed
- [x] 18 projects onboarded and converged (Wave 1)

### 6.3 Waves Remaining

| Wave | Group | Projects | Est. Count | Est. Effort | Ready? |
|------|-------|----------|------------|-------------|--------|
| 2a | base-service remaining | treasure, bot-trainer, picture-sync, base-service-common | 4 | 2 days | ✅ (scanned) |
| 2b | dialogue-engine + ai | policy-tools, policy-codex-api, common-libs, citi, business-rule | 5 | 2 days | ✅ (scanned) |
| 2c | EP, leyan | sites, create-backend, common-libs, leyan-proto, leyan-avro, java-example | 6 | 2 days | ✅ (scanned) |
| 3a | digismart (batch 1) | robot-processor, invoice-robot-cloud, dgt-risk-control, dgt-bi-server, digismart-alipay, digismart-item | 6 | 2-3 days | ✅ (scanned) |
| 3a | digismart (batch 2) | theia, mola-service, robot-transfer, robot-types, digsmart-metabase, llm-wiki | 6 | 2-3 days | ✅ (scanned) |
| 3b | oversea (batch 1) | oversea-door, overseaim-store-home, oversaim-hi-manager, overseaim-hi, overseaim-trade, overseaim-item | 6 | 3-4 days | ⚠️ No MySQL |
| 3b | oversea (batch 2) | oversea-tunnel, oversea-policy, oversea-agent, oversea-dialogue, oversea-knowledge-builder, oversea-hi-vts | 6 | 3-4 days | ⚠️ No MySQL |
| 3b | oversea (batch 3) | oversea-prompt, oversea-review-analyzer, oversea-llm-config, item-cluster, oversea-buyer-tag, oversea-apidoc | 6 | 3-4 days | ⚠️ No MySQL |
| 4 | RPA scripts | monitor_refund_new, pdd_feedback_central, taobao_refund, etc. | 12 | 2 days | ✅ (scanned) |
| 5 | Long tail | hermes-agent, agent-bridge, oversea-agent-mcp, leyan-proto-golang, any remaining | ~10 | 2 days | ⚠️ Partially scanned |

---

## 7. Recommended Next Steps

### Priority 1: Infrastructure Foundation (Today/Tonight)

```
[P1] docker builder prune -a -f                     # Recover 20 GB
[P1] docker pull postgres:15-alpine                 # Enable PG15 projects
[P1] docker pull postgres:17-alpine                 # Enable PG17 projects
[P1] docker volume create pg15-data                 # Pre-create volumes
[P1] docker volume create pg17-data
[P1] Deploy PG15 + PG17 containers                 # Run docker run commands
[P1] Add NO_PROXY to entrypoint.sh                  # Fix proxy routing
[P1] Authenticate ghcr.io with GitHub PAT           # Unblock PeerDB
```

### Priority 2: Observability (This Week)

```
[P2] Pull Grafana image via ALL_PROXY              # Enable dashboards
[P2] Deploy Grafana container                       # Port 3000
[P2] Create kyb.claude_hook_events CK table        # Enable hook capture
[P2] Install hook scripts in ~/.claude/hooks/      # Enable telemetry
[P2] Add hooks to ~/.claude-host-settings.json     # Wire up hooks
[P2] Create kyb.network_connections CK table       # Enable network capture
[P2] Enable Clash API in sing-box config           # Enable connection polling
```

### Priority 3: Project Onboarding (This Week -> Next Week)

```
[P3] Dispatch Wave 2a: policy-tools, common-libs, assistant, store-home
[P3] Dispatch Wave 2b: base-service remaining (treasure, bot-trainer, picture-sync)
[P3] Dispatch Wave 2c: dialogue-engine + ai
[P3] Dispatch Wave 3a: digismart batch 1
[P3] Monitor system resources between each batch
```

### Priority 4: Network Improvements (This Week -> Next Week)

```
[P4] Eliminate SSH tunnel (sing-box → nuc8 direct via Tailscale)
[P4] Register ACR Personal Edition for image mirror
[P4] Set up ACR image sync for common base images
[P4] Install aliyun CLI on sim
[P4] Set up OSS artifact cache for mise tools
```

### Priority 5: Medium-Term (Next 2-4 Weeks)

```
[P5] Deploy MySQL 8.0 container (for oversea projects)
[P5] Configure pgvector on PG15 (for assistant, bot-trainer)
[P5] Deploy PeerDB (once ghcr.io access resolved)
[P5] Deploy cc-connect (once tokens provided)
[P5] Set up per-project Grafana dashboards
[P5] Phase 3: Cloud migration prep (Docker Compose manifests)
```

### Resource Monitoring Reminder

Check every 10 minutes or between dispatches:
```bash
free -h | head -2          # Memory check
uptime                     # Load check
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null
```

Thresholds: Load > 15 or Memory < 4 GiB available => throttle agent count.

---

## Appendix: Document Index

All infrastructure docs at `/home/dev/projects/kyb/docs/infra/`:

| Document | Focus |
|----------|-------|
| `MASTER-REPORT.md` | This file -- aggregate summary |
| `100-project-rollout-plan.md` | Full 8-week rollout strategy, phases, waves |
| `survey-base-service.md` | 10 base-service project scans |
| `survey-oversea-digismart.md` | ~40 oversea + digismart project scans |
| `survey-remaining.md` | ~30 remaining project scans |
| `peerdb-pg-ck.md` | PeerDB deployment + Kafka engine alternative |
| `claude-hooks-ck.md` | Claude Code hooks -> ClickHouse pipeline |
| `claude-session-capture.md` | Full session capture architecture |
| `network-capture.md` | Network traffic capture strategy |
| `direct-network-options.md` | nuc8 direct connectivity analysis |
| `aliyun-network-options.md` | Aliyun ACR/OSS/CDN options |
| `cc-connect-research.md` | cc-connect bridge research |
| `postgresql-setup.md` | PostgreSQL deployment guide |
| `redis-setup.md` | Redis deployment guide |
| `kafka-setup.md` | Kafka deployment guide |
| `grafana-setup.md` | Grafana deployment guide |

---

> Written for kyb infra 100-project rollout initiative.
> Boss mode: dispatch, don't do. Parallel by default. Never wait.
> ／人◕ ‿‿ ◕人＼
