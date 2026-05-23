---
decision: 稍后做
---

# Service Dependency Graph Monitoring

> **Status:** Practical Design Document
> **Date:** 2026-05-23
> **Context:** Map all infra services, detect dependency chains, visualize health propagation, and design monitoring for cascading failure detection.

---

## Table of Contents

1. [Service Inventory](#1-service-inventory)
2. [Dependency Graph](#2-dependency-graph)
3. [Health Signal Matrix](#3-health-signal-matrix)
4. [Data Flow Diagrams](#4-data-flow-diagrams)
5. [Cascading Failure Analysis](#5-cascading-failure-analysis)
6. [Dependency-Aware Alerting](#6-dependency-aware-alerting)
7. [Grafana Implementation](#7-grafana-implementation)
8. [Operational Runbook](#8-operational-runbook)

---

## 1. Service Inventory

### 1.1 All Managed Services

| ID | Service | Tier | Cluster | Type | Depends On |
|----|---------|------|---------|------|------------|
| S01 | **cc-connect** | 0 | mac-orbstack | Go bridge (Feishu ↔ Claude) | S06, S09, EXT-01, EXT-03 |
| S02 | **feishu-bridge** | 1 | mac-orbstack | Feishu integration layer | S01, S09 |
| S03 | **cc-healthcheck** | 2 | mac-orbstack | Health check cron | S01 |
| S04 | **PostgreSQL 14** | 1 | mac-orbstack | Database | S09 |
| S05 | **PostgreSQL 15** | 1 | mac-orbstack | Database | S09 |
| S06 | **PostgreSQL 16** | 1 | mac-orbstack | Database (cc-connect primary) | S09 |
| S07 | **PostgreSQL 17** | 1 | mac-orbstack | Database | S09 |
| S08 | **ClickHouse** | 1 | mac-orbstack | OLAP / observability | S09 |
| S09 | **sing-box** | 2 | mac-orbstack | SOCKS5 proxy exit | EXT-02 (Shadowsocks relays) |
| S10 | **Redis** | 1 | mac-orbstack | Cache | S09 |
| S11 | **Grafana** | 3 | mac-orbstack | Dashboards / alerting | S08, S06 |
| S12 | **Vector** | 2 | mac-orbstack | Log shipping & transform | S08 |
| S13 | **Kafka (Redpanda)** | 1 | mac-orbstack | Event bus | S09 |
| S14 | **kyb-infra-boss** | 1 | mac-orbstack | Management container | S09 |
| S15 | **kyb-infra-boss-fallback** | 2 | mac-orbstack | Fallback manager | S09 |
| S16 | **docker-event-watcher** | 2 | all | Container lifecycle monitor | S08, S14 |
| S17 | **sb-metrics-poller** | 2 | mac-orbstack | Sing-box metrics collector | S09, S08 |
| S18 | **session-monitor** | 2 | mac-orbstack | cc-connect session tracker | S01, S08 |
| S19 | **Patrol (3 agents)** | 1 | all | 5-min infra patrol | S08, EXT-03, EXT-04 |
| S20 | **ACR mirror** | 2 | aliyun | Docker registry mirror | EXT-05 (Docker Hub) |
| S21 | **OSS cache** | 2 | aliyun | Artifact cache (mise) | EXT-06 (GitHub releases) |
| S22 | **Build runner** | 3 | aliyun | CI/CD runner | S20 |
| S23 | **feishu-bridge-sync** | 2 | office | Sync service | EXT-04 |
| S24 | **Nexus cache** | 2 | office | Proxy cache | EXT-04 |
| S25 | **SOCKS5 proxy (office)** | 2 | office | Office intranet proxy | — |
| S26 | **sshd / host** | 1 | all | SSH tunnel to cluster | — |
| S27 | **Tailscale** | 1 | all | Overlay mesh VPN | — |

### 1.2 External Dependencies

| ID | Service | Purpose | Dependency Of |
|----|---------|---------|---------------|
| EXT-01 | **Claude API** (api.anthropic.com) | LLM inference | S01 |
| EXT-02 | **Shadowsocks relays** (JP, HK, US) | Proxy relay nodes | S09 |
| EXT-03 | **Feishu API** (open.feishu.cn) | IM platform | S01, S02 |
| EXT-04 | **GitLab** (git.leyantech.com) | Source control, CI | S19, S23, S24 |
| EXT-05 | **Docker Hub / GHCR** | Container images | S20 |
| EXT-06 | **GitHub releases** | Tool downloads | S21 |

### 1.3 Service Groupings by Dependence Chain

```
Group 1: Bridge (user-facing, Tier-0 path)
  EXT-03 (Feishu) → S01 (cc-connect) → EXT-01 (Claude API)
                    S01 → S06 (PG16) → S09 (sing-box) → EXT-02 (relays)
                    S01 → S12 (Vector) → S08 (CK)

Group 2: Observability (internal, Tier-1/2/3)
  S16 (docker-events) → S08 (CK)
  S17 (sb-metrics) → S08 (CK)
  S18 (sessions) → S08 (CK)
  S19 (patrol) → S08 (CK)
  S08 (CK) → S11 (Grafana)
  S06 (PG) → S11 (Grafana)

Group 3: Infrastructure (Tier-1)
  S14 (boss) → S09 (sing-box) → EXT-02
  S14 (boss) → S27 (Tailscale) → S26 (SSH targets)
  S26 (SSH) → S14/alpine (remote bosses)

Group 4: Registry & Cache (Tier-2/3)
  EXT-05 (Docker Hub) → S20 (ACR mirror) → S22 (Build runner)
  EXT-06 (GitHub) → S21 (OSS cache)
  EXT-04 (GitLab) → S24 (Nexus cache)
```

---

## 2. Dependency Graph

### 2.1 Full Dependency DAG

```
External Layer:
  EXT-01 Claude API  EXT-02 Relays    EXT-03 Feishu    EXT-04 GitLab    EXT-05 Docker Hub    EXT-06 GitHub
      │                  │                │                │                  │                  │
      ▼                  ▼                ▼                │                  ▼                  ▼
┌──────────┐    ┌──────────────┐   ┌──────────┐           │           ┌──────────┐      ┌──────────┐
│ S01      │    │ S09          │   │ S02      │           │           │ S20      │      │ S21      │
│ cc-conn  │◄───│ sing-box     │   │ feishu   │           │           │ ACR      │      │ OSS      │
│ ect      │    │ (SOCKS5:2080)│   │ -bridge  │           │           │ mirror   │      │ cache    │
└────┬─────┘    └──────┬───────┘   └──────────┘           │           └────┬─────┘      └────┬─────┘
     │                 │                                  │                │                  │
     │                 │                                  │                │                  │
     │          ┌──────┴───────┐                          │                │                  │
     │          │ S13 Kafka    │                          │                │                  │
     │          │ S10 Redis    │                          │                │                  │
     │          │ S04-S07 PG   │                          │                │                  │
     │          │ S08 CK       │                          │                │                  │
     │          └──────────────┘                          │                │                  │
     │                                                    │                │                  │
     ▼                                                    │                ▼                  ▼
┌──────────┐    ┌──────────────┐   ┌──────────┐   ┌──────────────┐   ┌────────────────────────────────┐
│ S12      │    │ S11 Grafana  │   │ S19      │   │ S23 feishu   │   │ S22 Build Runner / S24 Nexus  │
│ Vector   │───►│ (CK datasrc) │   │ Patrol   │   │ -bridge-sync │   │                              │
└────┬─────┘    └──────┬───────┘   └────┬───────┘   └──────────────┘   └────────────────────────────────┘
     │                 │                │
     ▼                 │                │
┌──────────┐           │                │
│ S08 CK   │◄──────────┘◄───────────────┘
│ (central)│
└────┬─────┘
     │
     ▼
┌──────────┐
│ S11      │
│ Grafana  │
│ (panels) │
└──────────┘

Cluster Boss Layer (per cluster):
┌─────────────────────────────────────────────────────────────────────┐
│ S14 kyb-infra-boss (each cluster)                                    │
│  ├── S16 docker-event-watcher  (all clusters → S08 CK)              │
│  ├── S19 Patrol agents         (all clusters → S08 CK)              │
│  ├── S17 sb-metrics-poller     (mac only → S08 CK)                  │
│  └── S18 session-monitor       (mac only → S08 CK)                  │
└─────────────────────────────────────────────────────────────────────┘

Mesh Layer:
┌─────────────────────────────────────────────────────────────────────┐
│ S27 Tailscale (inter-boss mesh)                                     │
│  ├── mac-orbstack ↔ aliyun (direct, 12ms)                           │
│  ├── mac-orbstack ↔ office  (direct, 11ms)                          │
│  └── aliyun ↔ office         (direct, 10ms)                         │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 Dependence Matrix

```
Service   │ S01 S02 S03 S04 S05 S06 S07 S08 S09 S10 S11 S12 S13 S14 S16 S17 S18 S19 S20 S21 S22 S23 S24 S25 S27 EXT
──────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────
S01 cc-c  │  ·   ·   ·   ·   ·   ●   ·   ·   ●   ·   ·   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ●●
S02 fei-b │  ●   ·   ·   ·   ·   ·   ·   ·   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·
S03 cc-h  │  ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·
S04-PG14  │  ·   ·   ·   ·   ·   ·   ·   ·   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·
S05-PG15  │  ·   ·   ·   ·   ·   ·   ·   ·   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·
S06-PG16  │  ●   ·   ·   ·   ·   ·   ·   ·   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·
S07-PG17  │  ·   ·   ·   ·   ·   ·   ·   ·   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·
S08-CK    │  ·   ·   ·   ·   ·   ·   ·   ·   ●   ·   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·
S09-sing  │  ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ●
S10-redis │  ·   ·   ·   ·   ·   ·   ·   ·   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·
S11-graf  │  ·   ·   ·   ·   ·   ●   ·   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·
S12-vect  │  ·   ·   ·   ·   ·   ·   ·   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·
S13-kafka │  ·   ·   ·   ·   ·   ·   ·   ·   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·
S14-boss  │  ·   ·   ·   ·   ·   ·   ·   ·   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ●   ·
S16-dk-ev │  ·   ·   ·   ·   ·   ·   ·   ●   ·   ·   ·   ·   ·   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·
S17-sb-m  │  ·   ·   ·   ·   ·   ·   ·   ●   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·
S18-sess  │  ●   ·   ·   ·   ·   ·   ·   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·
S19-pat   │  ·   ·   ·   ·   ·   ·   ·   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ●
S20-ACR   │  ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ●
S21-OSS   │  ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ●
S22-build │  ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·
S23-sync  │  ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ●
S24-nexus │  ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ●
S25-s5off │  ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·
S27-ts    │  ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ●   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·

Legend: ● = hard dependency (downstream breaks), ◐ = soft dependency (degraded), · = no dependency
        ●● = depends on 2+ externals
```

---

## 3. Health Signal Matrix

### 3.1 Signal Types per Service

Each service emits one or more health signals. These are the inputs to the dependency-aware health model.

```
Service       │ Signal Type        │ Source                    │ Interval    │ Destination
──────────────┼────────────────────┼───────────────────────────┼─────────────┼─────────────
S01 cc-connect│ container health   │ Docker HEALTHCHECK        │ 15s         │ docker-events → CK
              │ message throughput  │ Vector / CK cc.message_log│ 1min        │ Grafana
              │ session count       │ session-monitor           │ 5min        │ CK
              │ turn latency        │ CK query                  │ 5min        │ Grafana

S04-S07 PG    │ container health   │ docker-event-watcher      │ per-event   │ CK
              │ query success       │ pg_isready (planned)      │ 30s         │ HEALTHCHECK
              │ transaction rate    │ (future: Prometheus)      │ 1min        │ —

S08 CK        │ container health   │ docker-event-watcher      │ per-event   │ CK
              │ query latency       │ Grafana probe             │ 30s         │ Grafana
              │ disk usage          │ boss_heartbeats           │ 60s         │ CK

S09 sing-box  │ container health   │ docker-event-watcher      │ per-event   │ CK
              │ latency per node    │ sb-metrics-poller         │ 30s         │ CK → Grafana
              │ active connections  │ sb-metrics-poller         │ 10s         │ CK → Grafana
              │ proxy reachability  │ patrol check              │ 5min        │ CK

S11 Grafana   │ dashboard load     │ (future: synthetic check)  │ 5min        │ —
              │ alert firing        │ Grafana API               │ per-event   │ Feishu

S14 boss      │ heartbeat           │ boss_heartbeats loop      │ 60s         │ CK
              │ docker events       │ docker-event-watcher      │ per-event   │ CK
              │ disk usage          │ boss_heartbeats           │ 60s         │ CK

S16 dk-ev     │ event pipeline      │ events appearing in CK    │ continuous  │ CK
              │ watcher alive       │ pgrep from patrol         │ 5min        │ patrol log

S19 patrol    │ heartbeat           │ patrol heartbeat files    │ 5min        │ local FS
              │ sibling alive       │ cross-check 3 files       │ 5min        │ patrol log
              │ checkpoint          │ CK patrol event log       │ 5min        │ CK

S20 ACR       │ pull success        │ (future: registry metrics)│ —           │ —
S21 OSS       │ cache hit rate      │ (future: access log)      │ —           │ —
S22 build-run │ job success         │ (future: runner API)      │ —           │ —
```

### 3.2 Health Propagation Paths

```
Primary Path (user-facing):
  EXT-01 Claude API ───┐
  EXT-03 Feishu API ───┤
  S09 sing-box ─────────┤
  S06 PG16 ─────────────┤
  S10 Redis ────────────┤
                        ▼
                    S01 cc-connect
                        │
                        ▼
                    S12 Vector
                        │
                        ▼
                    S08 ClickHouse
                        │
                        ▼
                    S11 Grafana

  Any node failure in this path → degraded or broken user experience.
  Most sensitive: S01 (single point of containment).
```

```
Observability Path (internal):
  S16 docker-events ──┐
  S17 sb-metrics ─────┤
  S18 sessions ───────┤
  S19 patrol ─────────┤
  S14 boss heartbeat ─┤
                       ▼
                   S08 ClickHouse
                       │
                       ▼
                   S11 Grafana

  A failure here does NOT affect user messaging, but blinds operators.
```

```
Inter-Cluster Path:
  S14 boss (mac) ←── S27 Tailscale ←── S14 boss (aliyun)
  S14 boss (mac) ←── S27 Tailscale ←── S14 boss (office)
                       │
                       ▼
                   S08 CK (mac)
                       │
            ┌──────────┴──────────┐
            ▼                     ▼
        Grafana panels      Grafana alerts

  Tailscale failure = blind to remote clusters.
  CK failure = no remote cluster health data (but clusters keep running).
```

### 3.3 Health Status Propagation Rules

When a dependency fails, the dependent services transition through states:

| Dependency State | Downstream Effect | Detection Latency | Recovery |
|-----------------|-------------------|-------------------|----------|
| **Healthy** | Normal operation | — | — |
| **Degraded** (latency >P90, partial failures) | Increased latency, reduced throughput | 30s-5min | Auto when dep recovers |
| **Down** (no signal) | Service unavailable, cascading error | 15s-60s | Dep recovery → restart cascade |
| **Flapping** (oscillating) | Unstable throughput, partial data loss | 2-5min | Stabilize dep first |

**Cascading failure detection rules:**

```
Rule CF1: If S08 (CK) is down → S11 Grafana is blind
  └─ Impact: no dashboards, no CK-based alerts
  └─ Still works: patrol (local heartbeat), docker (local)

Rule CF2: If S09 (sing-box) is down → ALL mac services lose proxy
  └─ Impact: S01 cannot reach Claude API, S04-S07 cannot pull images
  └─ Still works: local Docker networking (inter-container)

Rule CF3: If S14 boss container dies → local management lost
  └─ Impact: cannot exec into containers, no heartbeats
  └─ Auto-recovery: Docker restart policy (unless-stopped)
  └─ Fallback: SSH into host, start new container

Rule CF4: If S27 Tailscale is down → cross-cluster visibility lost
  └─ Impact: no heartbeats from remote clusters, no CK writes
  └─ Fallback: SSH via public IP (sim: 47.100.71.220)

Rule CF5: If S01 cc-connect is down → user messages not processed
  └─ Detection: HEALTHCHECK fails, docker-event-watcher fires die
  └─ Auto-recovery: Docker restart policy, cc-healthcheck restart
  └─ Alert: P0, immediate notification to Feishu
```

---

## 4. Data Flow Diagrams

### 4.1 Bridge Message Flow (Tier-0 Path)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ FEISHU                                                                      │
│  User sends message ───► WebSocket ───► cc-connect (S01)                    │
└─────────────────────────────────────────────────────────────────────────────┘
                                          │
                                          ▼
                              ┌───────────────────────┐
                              │  1. Route message     │
                              │     (session lookup)  │──► S06 PG16 (session state)
                              └───────────────────────┘
                                          │
                                          ▼
                              ┌───────────────────────┐
                              │  2. Agent loop start  │
                              │     (create trace)    │──► OTel Collector
                              └───────────────────────┘
                                          │
                                          ▼
                              ┌───────────────────────┐
                              │  3. Claude API call   │──► EXT-01 (api.anthropic.com)
                              │     (HTTP POST)       │     via S09 sing-box
                              └───────────────────────┘
                                          │
                                          ▼
                              ┌───────────────────────┐
                              │  4. Tool execution    │
                              │     (if tool_use)     │
                              └───────────────────────┘
                                          │
                                          ▼
                              ┌───────────────────────┐
                              │  5. Send response     │──► EXT-03 (Feishu API)
                              │     (Feishu message)  │     via S09 sing-box
                              └───────────────────────┘
                                          │
                                          ▼
                              ┌───────────────────────┐
                              │  6. Log to stdout     │
                              └──────────┬────────────┘
                                         │
                                         ▼
                              ┌───────────────────────┐
                              │  S12 Vector           │
                              │  (docker_logs source)  │
                              └──────────┬────────────┘
                                         │
                                         ▼
                              ┌───────────────────────┐
                              │  S08 ClickHouse        │
                              │  cc.message_log table  │
                              └──────────┬────────────┘
                                         │
                                         ▼
                              ┌───────────────────────┐
                              │  S11 Grafana          │
                              │  (message dashboard)  │
                              └───────────────────────┘

Health signals at each step:
  Step 1-5: span-level OTel traces
  Step 6:   Vector pipeline health (p95 delivery < 60s)
  CK:       data freshness (event_time vs now())
  Grafana:  dashboard load success
```

### 4.2 Observability Pipeline Flow

```
┌──────────────────┐
│ PRODUCERS        │
│                  │
│ S01 cc-connect   │─── stdout logs ──► S12 Vector ──► S08 CK (cc.message_log)
│                  │
│ S14 boss         │─── heartbeat loop ──► HTTP POST ──► S08 CK (boss_heartbeats)
│                  │
│ S16 dk-evt-watch │─── docker events ──► HTTP POST ──► S08 CK (infra.docker_events)
│                  │
│ S17 sb-metrics   │─── Clash API poll ──► HTTP POST ──► S08 CK (net.* tables)
│                  │
│ S18 session-mon  │─── session scan ──► HTTP POST ──► S08 CK (cc.session_snapshots)
│                  │
│ S19 patrol       │─── check results ──► HTTP POST ──► S08 CK (patrol.event_log)
│                  │   (planned: Kafka topic patrol.events)
│                  │
│ S13 Kafka        │─── (planned: unified event bus) ──► CK Kafka Engine tables
└──────────────────┘
        │
        │ All flows converge here
        ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ S08 ClickHouse (central observability store)                             │
│                                                                          │
│  Databases:                                                              │
│    cc.*          — cc-connect message_log, session_snapshots             │
│    infra.*       — docker_events, otel_spans                             │
│    net.*         — connection_log, outbound_snapshot, latency            │
│    patrol.*      — event_log (future: patrol.event_log)                  │
│    boss_heartbeats  — cross-cluster boss health                          │
│    otel.traces   — (future: patrol OTel traces)                          │
└──────────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ S11 Grafana (visualization & alerting)                                   │
│                                                                          │
│  Dashboards:                                                             │
│    Boss Overview       — heartbeat, container count, disk (all clusters) │
│    Bridge Metrics      — message throughput, latency, errors, tokens     │
│    Proxy Traffic       — per-outbound bandwidth, connections, latency    │
│    Docker Events       — crash loops, OOM, health transitions           │
│    Error Budget        — SLO compliance, burn rate per service           │
│    Session Monitor     — active/stale/zombie session counts             │
│    Cluster Health      — per-cluster resource usage                     │
│                                                                          │
│  Alerts:                                                                 │
│    See Section 6                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### 4.3 Cross-Cluster Heartbeat Flow

```
┌──────────────────────┐     ┌──────────────────────┐     ┌──────────────────────┐
│ mac-orbstack boss    │     │ aliyun boss (sim)    │     │ office boss (nuc8)   │
│                      │     │                      │     │                      │
│ while true; do       │     │ while true; do       │     │ while true; do       │
│   curl -X POST       │     │   curl -X POST       │     │   curl -X POST       │
│   → 100.104.244.99   │     │   → 100.104.244.99   │     │   → 100.104.244.99   │
│   :8123              │     │   :8123              │     │   :8123              │
│   INSERT INTO        │     │   INSERT INTO        │     │   INSERT INTO        │
│   boss_heartbeats    │     │   boss_heartbeats    │     │   boss_heartbeats    │
│ sleep 60             │     │ sleep 60             │     │ sleep 60             │
│ done                 │     │ done                 │     │ done                 │
└──────────┬───────────┘     └──────────┬───────────┘     └──────────┬───────────┘
           │                            │                            │
           │         ┌──────────────────┴──────────────────┐         │
           │         │                                     │         │
           │         │  S27 Tailscale Mesh                 │         │
           │         │  (all heartbeats reach CK via        │         │
           │         │   mac-orbstack's Tailscale IP)      │         │
           │         │                                     │         │
           │         └──────────────────┬──────────────────┘         │
           │                            │                            │
           ▼                            ▼                            ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│  S08 ClickHouse (on mac-orbstack: host.orb.internal:8123 / 100.104.244.99:8123)│
│                                                                               │
│  boss_heartbeats table:                                                        │
│    boss_id    │ cluster       │ timestamp      │ docker_running │ disk_used_pct│
│    ───────────┼───────────────┼────────────────┼────────────────┼──────────────│
│    infra-boss │ mac-orbstack  │ T+0s           │ 16             │ 45           │
│    kyb-infra- │ aliyun        │ T+12ms         │ 4              │ 32           │
│    boss       │               │                │                │              │
│    kyb-infra- │ office        │ T+11ms         │ 3              │ 67           │
│    boss       │               │                │                │              │
└───────────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │  Grafana Alerts      │
                    │                     │
                    │  boss_heartbeat_    │
                    │  warn: lag > 120s   │
                    │  critical: lag >300s│
                    └─────────────────────┘
```

---

## 5. Cascading Failure Analysis

### 5.1 Single-Point-of-Failure Inventory

| Component | Failure Impact | Mitigation | Detection |
|-----------|---------------|------------|-----------|
| **S01 cc-connect** | User messages stop processing | Docker restart policy + cc-healthcheck auto-restart | HEALTHCHECK + docker-event-watcher |
| **S06 PG16** | cc-connect cannot load/save sessions | PG is local, not clustered (single node) | docker-event-watcher |
| **S08 CK** | No observability, Grafana blind | Events lost during downtime; no data loss if Kafka buffer exists | docker-event-watcher + Grafana self-monitoring |
| **S09 sing-box** | All mac services lose internet proxy | No auto-failover proxy | sb-metrics-poller active conns == 0 |
| **S14 boss container** | Can't manage local containers | Docker restart policy | boss_heartbeats |
| **S27 Tailscale** | Cross-cluster visibility lost | SSH fallback via public IP | patrol check |
| **S12 Vector** | Log pipeline breaks | Buffered input; restart recovers | docker-event-watcher |

### 5.2 Cascade Scenarios

**Scenario A: sing-box down**

```
Time  Event                                              Detection
────  ─────                                              ────────
T+0   S09 sing-box container dies                         docker-event-watcher
T+1   docker restarts sing-box (unless-stopped)
T+5   S01 cc-connect cannot reach Claude API               patrol check (github/gitlab delay)
      (messages queued, not processed)
T+10  S01 cc-connect agent loop timeout                    CK message_log gap
T+15  sb-metrics-poller: 0 active connections              net.outbound_snapshot
T+30  Users complain: bot not responding                   Feishu message
T+60  Patrol detects sing-box down                         patrol check
```

**Mitigation**: Add proxy failover (SOCKS5 multi upstream). Currently none.

**Scenario B: Tailscale relay degrades (office behind CGNAT)**

```
Time  Event                                              Detection
────  ─────                                              ────────
T+0   office DERP relay saturated                         tailscale status (manual)
T+60  office boss heartbeat misses 2 cycles               boss_heartbeats lag > 120s
T+120 office boss marked WARNING                          Grafana alert
T+180 office boss lag > 300s → CRITICAL                   Grafana alert P1
T+300 office boss considered down                         alarm sent to Feishu
```

**Mitigation**: SSH fallback via sim's public IP. Auto-reconnect when DERP recovers.

**Scenario C: ClickHouse disk full**

```
Time  Event                                              Detection
────  ─────                                              ────────
T+0   CK disk > 85%                                       boss_heartbeats
T+60  CK starts rejecting writes                          INSERT errors in producer logs
T+120 Vector buffer fills up                               Vector log
T+180 cc-connect logs not ingested                         Grafana: stale message_log
T+300 Heartbeats not ingested (silent)                     Grafana: no heartbeat data
      Grafana dashboards stale
      No alerting possible (alert depends on CK data!)
```

**Critical issue: CK disk full causes observability death spiral** -- the very system that should alert about disk is blinded by the disk issue.

**Mitigation**: 
- Disk usage alert for CK volume specifically (from boss heartbeat, which writes directly via curl -- separate from Vector/CK pipeline)
- TTL on all CK tables to prevent unbounded growth
- Grafana should have a heartbeat-independent alert path (e.g., periodic `SELECT 1` probe from outside CK)

### 5.3 Resilience Scoring

| Service | Auto-Restart | Health Check | Redundancy | Fallback | Score |
|---------|-------------|-------------|------------|----------|-------|
| S01 cc-connect | yes (unless-stopped) | HEALTHCHECK defined | none | cc-healthcheck manual restart | 6/10 |
| S04-S07 PG | yes (unless-stopped) | none (PG planned) | none (4 versions but not HA) | none | 4/10 |
| S08 CK | yes (unless-stopped) | none | none | Kafka buffer (planned) | 4/10 |
| S09 sing-box | yes (unless-stopped) | none | socks5:2080 (single) | none | 3/10 |
| S11 Grafana | yes (unless-stopped) | none | none | none | 3/10 |
| S13 Kafka | yes (unless-stopped) | none | none | N/A (message loss) | 3/10 |
| S14 boss | yes (unless-stopped) | none | boss2, boss3, fallback | SSH into host | 7/10 |
| S27 Tailscale | systemd auto | tailscale status | DERP relay | SSH via public IP | 7/10 |

**Key gap**: Most services lack Docker HEALTHCHECK and lack redundancy. The boss container has multiple instances (boss, boss2, boss3, fallback) -- this is the only service with real redundancy.

---

## 6. Dependency-Aware Alerting

### 6.1 Alert Grouping by Dependency Layer

Alerts are grouped so that a root cause does not trigger N downstream alerts.

```
Layer 0: External
  ├── EXT-01 Claude API unreachable
  ├── EXT-02 All relay nodes dead
  └── EXT-03 Feishu API token expired

Layer 1: Infrastructure (boss, proxy, network)
  ├── S09 sing-box down
  ├── S14 boss container dead
  ├── S27 Tailscale mesh down
  └── S16 docker-event-watcher stopped

Layer 2: Data stores (stateful)
  ├── S06 PG16 down
  ├── S08 CK query failure
  ├── S10 Redis down
  └── S13 Kafka broker down

Layer 3: Processing (bridges, transforms)
  ├── S01 cc-connect unhealthy (P0)
  ├── S12 Vector pipeline stalled
  └── S19 patrol agent dead

Layer 4: Visualization (leaf)
  └── S11 Grafana down (P3 -- no user impact)
```

### 6.2 Alert Suppression Rules

When a Layer-X service fires an alert, suppress all alerts from Layer > X that depend on it:

```
Rule SUP-1: S09 (sing-box) down → suppress:
  - All proxy-dependent alerts (S01, S04-S07 pull failures, S10, S13)
  - Do NOT suppress: S14 heartbeats, S08 CK, S11 Grafana (these are local)

Rule SUP-2: S08 (CK) down → suppress:
  - All CK-dependent dashboard alerts (S11)
  - Do NOT suppress: S01 cc-connect (still running), patrol alerts (local)

Rule SUP-3: S01 (cc-connect) down → suppress:
  - S03 cc-healthcheck alerts (expected)
  - Do NOT suppress: S06 PG16, S08 CK, S09 sing-box (these run independently)

Rule SUP-4: S27 (Tailscale) mesh down for remote cluster → suppress:
  - Heartbeat missing alerts for that cluster
  - Do NOT suppress: local mac-orbstack alerts
  - Create single "Cluster-X blind" alert
```

### 6.3 Alert Thresholds by Dependency Distance

The closer an alert is to the user-facing path, the more aggressive the threshold:

```
Service        │ Tier │ Max Downtime │ Alert Lag │ Page Severity
───────────────┼──────┼──────────────┼───────────┼──────────────
S01 cc-connect │ 0    │ 10s          │ 15s       │ P0
S06 PG16       │ 1    │ 30s          │ 60s       │ P1
S08 CK         │ 1    │ 60s          │ 60s       │ P1
S09 sing-box   │ 2    │ 30s          │ 60s       │ P1
S10 Redis      │ 1    │ 60s          │ 60s       │ P1
S13 Kafka      │ 1    │ 2min         │ 2min      │ P1
S11 Grafana    │ 3    │ 10min        │ 5min      │ P3
S12 Vector     │ 2    │ 5min         │ 5min      │ P2
S16 dk-ev-wat  │ 2    │ 5min         │ 5min      │ P2
S17 sb-poll    │ 2    │ 10min        │ 5min      │ P2
S18 sess-mon   │ 2    │ 15min        │ 5min      │ P3
S19 patrol     │ 1    │ 6min         │ 1min      │ P0 (all 3 dead)
S20 ACR        │ 2    │ 5min         │ 5min      │ P2
S22 build-run  │ 3    │ 30min        │ 10min     │ P3
```

### 6.4 Alert Routing by Dependency Depth

```
Alert Origin             │ Primary Route        │ Escalation
─────────────────────────┼──────────────────────┼─────────────────
Layer 0 (external)       │ Feishu @all          │ TTS + phone call
Layer 1 (infrastructure) │ Feishu @oncall       │ escalate after 5min
Layer 2 (data stores)    │ Feishu @oncall       │ escalate after 10min
Layer 3 (processing)     │ Feishu @all (P0/P1)  │ immediate for P0
Layer 4 (visualization)  │ Feishu digest        │ next business day
```

### 6.5 Composite Alerts (Dependency-Aware)

These alerts consider the dependency graph rather than individual service state:

```
CA-1: "Bridge Path Health"
  Condition: S01 unhealthy AND S06 PG16 healthy AND S09 healthy AND EXT-01 healthy
  → Means: cc-connect has an internal issue, not a dependency issue
  → Action: Check cc-connect logs, restart cc-connect
  → Severity: P0

CA-2: "Bridge Path Dependency Failure"
  Condition: S01 unhealthy AND (S06 down OR S09 down OR EXT-01 down)
  → Means: cc-connect is collateral damage
  → Action: Fix the underlying dependency first
  → Severity: P0 (but different runbook)

CA-3: "Observability Blackout"
  Condition: S08 CK down AND S16 watcher alive
  → Means: CK lost but data collection still works
  → Action: Restore CK, lost events since CK went down
  → Severity: P1

CA-4: "Multi-Cluster Blind"
  Condition: No heartbeats from >=2 remote clusters for >5min
  → Means: Likely Tailscale or mac-orbstack CK issue, not individual clusters
  → Action: Check Tailscale status, check CK
  → Severity: P1

CA-5: "Sing-Box Proxy Collapse"
  Condition: S09 down AND active_connections from sb-metrics-poller = 0
  → Means: sing-box crashed or network interface lost
  → Action: Check sing-box logs, docker restart
  → Severity: P1

CA-6: "Crash Loop Detected"
  Condition: >=3 die events for same container in 5 min
  → Means: container crash loop
  → Action: Check logs for that specific container
  → Severity: P1
```

---

## 7. Grafana Implementation

### 7.1 Dependency Graph Panel

A dedicated Grafana dashboard shows the live dependency graph. Each node is color-coded by health status:

```
Dashboard: "Service Dependency Graph"

Panel 1: Live Dependency Graph (Node Graph / Custom Visualization)

  ┌──────────┐     ┌──────────┐     ┌──────────┐
  │ EXT-01   │     │ EXT-03   │     │ EXT-02   │
  │ Claude   │     │ Feishu   │     │ Relays   │
  │ ●  OK    │     │ ●  OK    │     │ ●  OK    │
  └────┬─────┘     └────┬─────┘     └────┬─────┘
       │                │                │
       ▼                ▼                │
  ┌──────────┐     ┌──────────┐          │
  │ S01      │     │ S02      │          │
  │ cc-conn  │     │ feishu   │          │
  │ ●  OK    │     │ ●  OK    │          │
  └────┬─────┘     └──────────┘          │
       │                                 │
       ▼                                 ▼
  ┌──────────┐     ┌──────────┐     ┌──────────┐
  │ S06      │     │ S08      │     │ S09      │
  │ PG16     │     │ CK       │     │ sing-box │
  │ ●  OK    │     │ ●  OK    │     │ ●  OK    │←── latency OK
  └──────────┘     └────┬─────┘     └──────────┘
                        │
                        ▼
                   ┌──────────┐
                   │ S11      │
                   │ Grafana  │
                   │ ●  OK    │
                   └──────────┘

  Color legend: ● green=healthy, ◐ yellow=degraded, ○ red=down, ○ gray=unknown
  Edge style: ── solid=hard dep, ── dashed=soft dep
  Click node → drill-down dashboard for that service
```

**Implementation approach**: Since Grafana does not have a built-in dependency graph panel, build it as:

1. **Primary**: A [Node Graph panel](https://grafana.com/docs/grafana/latest/panels-visualizations/visualizations/node-graph/) (Grafana 10+ supports this for service graphs)
2. **Fallback**: A table with hierarchical indentation showing dependency chains and status per row
3. **Live data source**: ClickHouse query that joins health signals from all services

**ClickHouse query for dependency graph data**:

```sql
-- Service node data (health status from latest signals)
SELECT
  service_id,
  service_name,
  tier,
  cluster,
  multiIf(
    status = 'ok', 2,      -- green
    status = 'degraded', 1, -- yellow
    0                       -- red
  ) AS health_score,
  status,
  last_updated
FROM infra.service_health_latest
ORDER BY tier, service_name;

-- Edge data (dependency links)
SELECT
  service_id AS source,
  depends_on AS target,
  dep_type    -- 'hard' or 'soft'
FROM infra.service_dependencies;
```

### 7.2 Dashboard: Service Dependency Health

```
Row 1: "Dependency Graph"
  ┌─────────────────────────────────────────────────────────────────────┐
  │  Node Graph: all services, color-coded, edges for dependencies      │
  │  (Auto-refresh: 30s)                                                │
  └─────────────────────────────────────────────────────────────────────┘

Row 2: "Chain Health (Critical Paths)"
  ┌─────────────────────────────────────────────────────────────────────┐
  │  Chain: Feishu → cc-connect → Claude API                           │
  │    [ OK ] Feishu API   [ OK ] cc-connect   [ OK ] Claude API       │
  │    E2E latency: P50=4.2s  P90=12.1s  P99=28.3s                     │
  ├─────────────────────────────────────────────────────────────────────┤
  │  Chain: Boss → CK → Grafana                                        │
  │    [ OK ] infra-boss   [ OK ] CK   [ OK ] Grafana                  │
  │    Heartbeat lag: 2s  Data freshness: 1s                           │
  ├─────────────────────────────────────────────────────────────────────┤
  │  Chain: Registry → Build Runner                                    │
  │    [ OK ] ACR mirror   [ OK ] Build runner                         │
  │    Last build: 2h ago                                              │
  └─────────────────────────────────────────────────────────────────────┘

Row 3: "Degraded Services"
  ┌─────────────────────────────────────────────────────────────────────┐
  │  Table of services with health_score < 2 (degraded or down)         │
  │  Columns: service, tier, status, last_signal, duration, action      │
  │  Sort by: tier ASC, last_signal ASC                                 │
  └─────────────────────────────────────────────────────────────────────┘

Row 4: "Recent Dependency Failures"
  ┌─────────────────────────────────────────────────────────────────────┐
  │  Time series: cascading failure events (last 24h)                   │
  │  Each horizontal line = one service                                 │
  │  Vertical bands = correlated failures (same root cause)             │
  │  Click on a band → highlight all services affected                  │
  └─────────────────────────────────────────────────────────────────────┘

Row 5: "Alert Suppression Status"
  ┌─────────────────────────────────────────────────────────────────────┐
  │  Table of active alert suppressions                                 │
  │  Columns: root_cause, suppressed_alert(s), reason, since            │
  └─────────────────────────────────────────────────────────────────────┘
```

### 7.3 ClickHouse Schema for Dependency Tracking

```sql
-- Service registry (source of truth for dependency graph)
CREATE TABLE infra.service_registry (
    service_id      LowCardinality(String),
    service_name    String,
    tier            UInt8,                -- 0-3
    cluster         LowCardinality(String),
    service_type    LowCardinality(String), -- 'internal', 'external', 'infra'
    description     String,
    depends_on      Array(String),         -- service_id list
    dep_types       Array(String),         -- 'hard', 'soft' (parallel to depends_on)
    healthcheck_cmd String DEFAULT '',
    updated_at      DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(updated_at)
ORDER BY service_id;

-- Service health snapshots (written by patrol / heartbeat processors)
CREATE TABLE infra.service_health (
    event_time      DateTime64(3),
    service_id      LowCardinality(String),
    cluster         LowCardinality(String),
    status          LowCardinality(String), -- 'ok', 'degraded', 'down', 'unknown'
    health_score    UInt8,                 -- 2=ok, 1=degraded, 0=down
    signal_source   LowCardinality(String), -- 'heartbeat', 'docker_event', 'patrol', 'probe'
    latency_ms      Nullable(UInt32),
    error_message   String DEFAULT '',
    detail_json     String DEFAULT ''       -- extensible payload
) ENGINE = MergeTree
ORDER BY (toDate(event_time), service_id, cluster)
TTL event_time + INTERVAL 90 DAY;

-- Materialized view: latest health per service
CREATE MATERIALIZED VIEW infra.service_health_latest
ENGINE = ReplacingMergeTree
ORDER BY (service_id, cluster)
POPULATE AS
SELECT
    argMax(event_time, event_time) AS last_updated,
    service_id,
    cluster,
    argMax(status, event_time) AS status,
    argMax(health_score, event_time) AS health_score,
    argMax(signal_source, event_time) AS signal_source,
    argMax(latency_ms, event_time) AS latency_ms,
    argMax(error_message, event_time) AS error_message
FROM infra.service_health
GROUP BY service_id, cluster;

-- Dependency failure events (generated by alert processor)
CREATE TABLE infra.dependency_failures (
    event_time      DateTime64(3),
    failure_id      String,              -- unique failure ID
    root_service    LowCardinality(String),
    affected_services Array(String),     -- services impacted by cascade
    failure_type    LowCardinality(String), -- 'crash', 'latency', 'timeout', 'unknown'
    root_cause      String,
    duration_sec    UInt32,              -- 0 if ongoing
    resolved_at     Nullable(DateTime64(3)),
    alert_suppressions Array(String)     -- alerts that were suppressed due to this
) ENGINE = MergeTree
ORDER BY (toDate(event_time), root_service)
TTL event_time + INTERVAL 90 DAY;
```

### 7.4 Grafana Alert Rules for Dependency-Aware Alerts

```yaml
# docs/infra/grafana/provisioning/alerting/resources/dependency-alerts.yaml
apiVersion: 1
groups:
  - name: dependency-alerts
    folder: kyb-infra-alerts
    interval: 30s
    rules:

      # Composite: Bridge path healthy?
      - uid: bridge_path_health
        title: "Bridge Path Composite Health"
        condition: "A and B and C and D"
        data:
          - refId: A
            datasourceUid: clickhouse
            model:
              rawSql: |-
                SELECT count() AS ok FROM infra.service_health_latest
                WHERE service_id = 'S01' AND status = 'ok'
              format: table
          - refId: B
            datasourceUid: clickhouse
            model:
              rawSql: |-
                SELECT count() AS ok FROM infra.service_health_latest
                WHERE service_id = 'S06' AND status = 'ok'
              format: table
          - refId: C
            datasourceUid: clickhouse
            model:
              rawSql: |-
                SELECT count() AS ok FROM infra.service_health_latest
                WHERE service_id = 'S09' AND status = 'ok'
              format: table
          - refId: D
            datasourceUid: clickhouse
            model:
              rawSql: |-
                SELECT count() AS cnt FROM cc.message_log
                WHERE event_time > now() - 120
                LIMIT 1
              format: table
        noDataState: Alerting
        for: 2m
        annotations:
          summary: "Bridge path degraded — one or more chain components unhealthy"
          runbook: "docs/infra/runbooks/bridge-path.md"
        labels:
          severity: critical
          p: "0"

      # Cascading failure detected
      - uid: cascade_failure
        title: "Cascading Failure Detected"
        condition: "A"
        data:
          - refId: A
            datasourceUid: clickhouse
            model:
              rawSql: |-
                SELECT root_service, count(affected_services) AS affected_count
                FROM infra.dependency_failures
                WHERE resolved_at IS NULL
                GROUP BY root_service
                ORDER BY affected_count DESC
                LIMIT 1
              format: table
        for: 1m
        annotations:
          summary: "Cascading failure — {{ $values.root_service }} affected {{ $values.affected_count }} downstream services"
          runbook: "docs/infra/runbooks/cascade-response.md"
        labels:
          severity: critical
          p: "1"

      # Single service down, check if it's root cause or cascade
      - uid: service_down_with_context
        title: "Service Down — Dependency Context"
        condition: "A and B"
        data:
          - refId: A
            datasourceUid: clickhouse
            model:
              rawSql: |-
                SELECT service_id, status
                FROM infra.service_health_latest
                WHERE health_score = 0 AND last_updated > now() - 300
                LIMIT 5
              format: table
          - refId: B
            datasourceUid: clickhouse
            model:
              rawSql: |-
                -- Are any of this service's dependencies also down?
                SELECT s.service_id, d.depends_on, h.status AS dep_status
                FROM infra.service_registry s
                ARRAY JOIN depends_on AS d, dep_types AS dt
                LEFT JOIN infra.service_health_latest h ON h.service_id = d
                WHERE s.health_score = 0
                  AND h.health_score = 0
                  AND dt = 'hard'
                LIMIT 5
              format: table
        for: 1m
        annotations:
          summary: "{{ $labels.service_id }} down — dependency chain: {{ $values.dep_status }}"
          runbook: "docs/infra/runbooks/service-down.md"
        labels:
          severity: critical
          p: "1"
```

---

## 8. Operational Runbook

### 8.1 When a Dependency Alert Fires

```
Step 1: Identify root cause vs. cascade

  Query: Who is the origin?
  ─────────────────────────────────────────────
  SELECT root_service, count() AS cascade_depth
  FROM infra.dependency_failures
  WHERE resolved_at IS NULL
  GROUP BY root_service
  ORDER BY cascade_depth DESC
  LIMIT 1;

Step 2: Check dependency context

  Query: What services depend on this?
  ─────────────────────────────────────────────
  SELECT depends_on
  FROM infra.service_registry
  WHERE service_id = '<root_service>';

Step 3: Determine impact scope

  ─ A Tier-0 service (cc-connect)? → P0, drop everything
  ─ A Tier-1 service (PG, CK, Redis)? → P1, fix within 15min
  ─ A Tier-2 service (proxy, Vector)? → P2, fix within 1h
  ─ A Tier-3 service (Grafana, build runner)? → P3, next business day

Step 4: Fix the root cause (not the cascade)

  ─ If PG is down and cc-connect is also showing errors:
    → Fix PG first. cc-connect will recover automatically.
    → Don't restart cc-connect -- it's not the problem.

Step 5: Verify recovery

  Query: Check cascade resolution
  ─────────────────────────────────────────────
  SELECT service_id, status
  FROM infra.service_health_latest
  WHERE last_updated > now() - 120
  ORDER BY tier ASC;
```

### 8.2 Adding a New Service to the Graph

```bash
# 1. Register the service
docker exec infra-boss bash -c "
  curl -s -X POST http://host.orb.internal:8123 \
    -d \"INSERT INTO infra.service_registry FORMAT JSONEachRow {
      'service_id': 'S28',
      'service_name': 'my-new-service',
      'tier': 2,
      'cluster': 'mac-orbstack',
      'service_type': 'internal',
      'description': 'Does XYZ',
      'depends_on': ['S09', 'S08'],
      'dep_types': ['hard', 'soft']
    }\"
"

# 2. Deploy a health signal producer for this service
#    (heartbeat, docker-event-watcher, or custom probe)

# 3. Add Grafana panel
#    Edit docs/infra/grafana/provisioning/dashboards/json/dependency-graph.json

# 4. Add alert rules (if needed)
#    Edit docs/infra/grafana/provisioning/alerting/resources/dependency-alerts.yaml

# 5. Update this document's service inventory table
```

### 8.3 Routine Maintenance

```bash
# Verify all services are reporting health signals
docker exec infra-boss bash -c "
  curl -s 'http://host.orb.internal:8123?query=
    SELECT
      service_id,
      argMax(status, last_updated) AS current_status,
      max(last_updated) AS last_signal,
      dateDiff(\"second\", max(last_updated), now()) AS lag_seconds
    FROM infra.service_health
    GROUP BY service_id
    ORDER BY lag_seconds DESC'
"

# Expected: all services reporting, lag < 120s for Tier-0/1 services
# Investigate any service with lag > 300s

# Check for unresolved cascading failures
docker exec infra-boss bash -c "
  curl -s 'http://host.orb.internal:8123?query=
    SELECT * FROM infra.dependency_failures
    WHERE resolved_at IS NULL
    ORDER BY event_time DESC'
"
```

### 8.4 Health Signal Troubleshooting

```
Symptom                          │ Likely Cause                        │ Check
─────────────────────────────────┼─────────────────────────────────────┼──────────────────────────────────────
No heartbeats from a cluster     │ Tailscale / network issue            │ tailscale ping <target_ip>
                                 │ boss container died                 │ SSH into host → docker ps
                                 │ heartbeat script stopped            │ pgrep -f heartbeat_loop

No docker events from a cluster  │ docker-event-watcher stopped        │ pgrep -f docker-event-watcher
                                 │ CK unreachable                     │ curl http://host.orb.internal:8123

No sb-metrics data               │ sing-box Clash API down             │ curl http://kyb-infra-sing-box:9090
                                 │ poller script crashed              │ pgrep -f sb-metrics-poller

No patrol events in CK           │ patrol not running                  │ check .kyb-diaries/.patrol-*-hb
                                 │ CK table missing                   │ SHOW TABLES IN patrol

Grafana shows stale data         │ CK query timeout                    │ SELECT 1 (probe query)
                                 │ Grafana datasource misconfigured    │ Check datasource in UI
                                 │ CK disk full / read-only            │ SHOW CREATE TABLE; check system.errors
```

---

## 9. Implementation Roadmap

| Phase | Items | Depends On | Effort |
|-------|-------|------------|--------|
| **P0** | Create `infra.service_registry` table + populate | Existing CK | 30min |
| **P0** | Create `infra.service_health` + MV `service_health_latest` | Existing CK | 30min |
| **P0** | Create `infra.dependency_failures` table | Existing CK | 15min |
| **P1** | Write health data from boss heartbeat to `infra.service_health` | P0 tables | 1h |
| **P1** | Write health data from docker-event-watcher | P0 tables, S16 deployed | 1h |
| **P1** | Write health data from sb-metrics-poller | P0 tables, S17 deployed | 1h |
| **P1** | Write health data from patrol | P0 tables, S19 active | 1h |
| **P1** | Build "Service Dependency Graph" Grafana dashboard (Node Graph) | P0 tables + health data flowing | 2h |
| **P2** | Add dependency-aware alert rules (composite alerts) | P1 dashboard | 1h |
| **P2** | Add suppression rules for cascade scenarios | P2 alert rules | 1h |
| **P2** | Add Docker HEALTHCHECK to all infra containers | — | 2h |
| **P3** | Build cascade timeline panel (vertical event bands) | P1 dashboard | 1h |
| **P3** | Automatic root cause identification from CK queries | P2 alert rules | 2h |
| **P4** | Integrate external dependency probing (Claude API, Feishu API) | — | 2h |

---

## Appendix A: Registry Seed Data

Execute once to populate the service_registry table:

```sql
INSERT INTO infra.service_registry FORMAT JSONEachRow
{"service_id":"S01","service_name":"cc-connect","tier":0,"cluster":"mac-orbstack","service_type":"internal","description":"Feishu-Claude bridge","depends_on":["S06","S09","S12"],"dep_types":["hard","hard","soft"]},
{"service_id":"S02","service_name":"feishu-bridge","tier":1,"cluster":"mac-orbstack","service_type":"internal","description":"Feishu integration layer","depends_on":["S01","S09"],"dep_types":["hard","hard"]},
{"service_id":"S03","service_name":"cc-healthcheck","tier":2,"cluster":"mac-orbstack","service_type":"internal","description":"Health check cron","depends_on":["S01"],"dep_types":["hard"]},
{"service_id":"S04","service_name":"postgresql-14","tier":1,"cluster":"mac-orbstack","service_type":"internal","description":"PostgreSQL 14","depends_on":["S09"],"dep_types":["soft"]},
{"service_id":"S05","service_name":"postgresql-15","tier":1,"cluster":"mac-orbstack","service_type":"internal","description":"PostgreSQL 15","depends_on":["S09"],"dep_types":["soft"]},
{"service_id":"S06","service_name":"postgresql-16","tier":1,"cluster":"mac-orbstack","service_type":"internal","description":"PostgreSQL 16 (cc-connect primary)","depends_on":["S09"],"dep_types":["soft"]},
{"service_id":"S07","service_name":"postgresql-17","tier":1,"cluster":"mac-orbstack","service_type":"internal","description":"PostgreSQL 17","depends_on":["S09"],"dep_types":["soft"]},
{"service_id":"S08","service_name":"clickhouse","tier":1,"cluster":"mac-orbstack","service_type":"internal","description":"Central observability store","depends_on":["S09"],"dep_types":["soft"]},
{"service_id":"S09","service_name":"sing-box","tier":2,"cluster":"mac-orbstack","service_type":"internal","description":"SOCKS5 proxy exit","depends_on":[],"dep_types":[]},
{"service_id":"S10","service_name":"redis","tier":1,"cluster":"mac-orbstack","service_type":"internal","description":"Cache","depends_on":["S09"],"dep_types":["soft"]},
{"service_id":"S11","service_name":"grafana","tier":3,"cluster":"mac-orbstack","service_type":"internal","description":"Dashboard and alerting","depends_on":["S06","S08"],"dep_types":["soft","hard"]},
{"service_id":"S12","service_name":"vector","tier":2,"cluster":"mac-orbstack","service_type":"internal","description":"Log shipping and transform","depends_on":["S08"],"dep_types":["hard"]},
{"service_id":"S13","service_name":"kafka","tier":1,"cluster":"mac-orbstack","service_type":"internal","description":"Event bus","depends_on":["S09"],"dep_types":["soft"]},
{"service_id":"S14","service_name":"kyb-infra-boss","tier":1,"cluster":"mac-orbstack","service_type":"infra","description":"Management container","depends_on":["S09","S27"],"dep_types":["soft","soft"]},
{"service_id":"S16","service_name":"docker-event-watcher","tier":2,"cluster":"all","service_type":"infra","description":"Container lifecycle monitor","depends_on":["S08","S14"],"dep_types":["hard","hard"]},
{"service_id":"S17","service_name":"sb-metrics-poller","tier":2,"cluster":"mac-orbstack","service_type":"internal","description":"Sing-box metrics collector","depends_on":["S09","S08"],"dep_types":["hard","hard"]},
{"service_id":"S18","service_name":"session-monitor","tier":2,"cluster":"mac-orbstack","service_type":"internal","description":"cc-connect session tracker","depends_on":["S01","S08"],"dep_types":["hard","hard"]},
{"service_id":"S19","service_name":"patrol","tier":1,"cluster":"all","service_type":"infra","description":"5-min infra patrol","depends_on":["S08"],"dep_types":["soft"]},
{"service_id":"S20","service_name":"acr-mirror","tier":2,"cluster":"aliyun","service_type":"internal","description":"Docker registry mirror","depends_on":[],"dep_types":[]},
{"service_id":"S21","service_name":"oss-cache","tier":2,"cluster":"aliyun","service_type":"internal","description":"Artifact cache","depends_on":[],"dep_types":[]},
{"service_id":"S22","service_name":"build-runner","tier":3,"cluster":"aliyun","service_type":"internal","description":"CI/CD runner","depends_on":["S20"],"dep_types":["soft"]},
{"service_id":"S23","service_name":"feishu-bridge-sync","tier":2,"cluster":"office","service_type":"internal","description":"Sync service","depends_on":[],"dep_types":[]},
{"service_id":"S24","service_name":"nexus-cache","tier":2,"cluster":"office","service_type":"internal","description":"Proxy cache","depends_on":[],"dep_types":[]},
{"service_id":"S25","service_name":"office-proxy","tier":2,"cluster":"office","service_type":"internal","description":"Office intranet SOCKS5 proxy","depends_on":[],"dep_types":[]},
{"service_id":"S26","service_name":"sshd-host","tier":1,"cluster":"all","service_type":"infra","description":"SSH tunnel to cluster","depends_on":[],"dep_types":[]},
{"service_id":"S27","service_name":"tailscale","tier":1,"cluster":"all","service_type":"infra","description":"Overlay mesh VPN","depends_on":[],"dep_types":[]},
{"service_id":"EXT-01","service_name":"claude-api","tier":0,"cluster":"external","service_type":"external","description":"Anthropic Claude API","depends_on":[],"dep_types":[]},
{"service_id":"EXT-02","service_name":"shadowsocks-relays","tier":1,"cluster":"external","service_type":"external","description":"Shadowsocks relay nodes","depends_on":[],"dep_types":[]},
{"service_id":"EXT-03","service_name":"feishu-api","tier":0,"cluster":"external","service_type":"external","description":"Feishu Open API","depends_on":[],"dep_types":[]},
{"service_id":"EXT-04","service_name":"gitlab","tier":1,"cluster":"external","service_type":"external","description":"GitLab (git.leyantech.com)","depends_on":[],"dep_types":[]},
{"service_id":"EXT-05","service_name":"docker-hub","tier":2,"cluster":"external","service_type":"external","description":"Docker Hub / GHCR","depends_on":[],"dep_types":[]},
{"service_id":"EXT-06","service_name":"github-releases","tier":2,"cluster":"external","service_type":"external","description":"GitHub releases","depends_on":[],"dep_types":[]};
```

---

## Appendix B: Query Library

```sql
-- B1: Current health score per service (sorted by tier)
SELECT service_id, service_name, tier, status, health_score,
       dateDiff('second', last_updated, now()) AS lag_seconds
FROM infra.service_health_latest
ORDER BY tier, health_score ASC;

-- B2: Downstream services affected by a given failure
SELECT arrayJoin(affected_services) AS impacted
FROM infra.dependency_failures
WHERE root_service = 'S09' AND resolved_at IS NULL;

-- B3: Dependency chain for a service
SELECT service_id AS svc, depends_on, dep_types
FROM infra.service_registry
ARRAY JOIN depends_on, dep_types
WHERE service_id = 'S01';

-- B4: All hard-dependency chains (for cascade analysis)
WITH RECURSIVE deps AS (
    SELECT service_id, depends_on AS dep, dep_types AS dt,
           1 AS depth,
           [service_id] AS path
    FROM infra.service_registry
    ARRAY JOIN depends_on, dep_types
    WHERE dep_types = 'hard'
    UNION ALL
    SELECT parent.service_id, child.depends_on, child.dep_types,
           parent.depth + 1,
           arrayConcat(parent.path, [child.service_id])
    FROM deps parent
    JOIN infra.service_registry child
      ON parent.dep = child.service_id
    WHERE child.dep_types = 'hard'
      AND NOT has(parent.path, child.service_id)
)
SELECT * FROM deps ORDER BY depth DESC;

-- B5: Cascade detection (services that went down within 5min of a root)
SELECT
    root_service,
    groupArray(affected_service) AS cascade_group,
    min(affected_time) AS first_failure,
    max(affected_time) AS last_failure,
    dateDiff('second', first_failure, last_failure) AS cascade_window_sec
FROM (
    SELECT
        r.service_id AS root_service,
        r.event_time AS root_time,
        h.service_id AS affected_service,
        h.event_time AS affected_time
    FROM infra.service_health r
    JOIN infra.service_health h
      ON h.event_time BETWEEN r.event_time
         AND r.event_time + INTERVAL 5 MINUTE
     AND h.health_score = 0
    WHERE r.health_score = 0
      AND r.service_id != h.service_id
)
GROUP BY root_service
HAVING count() > 1
ORDER BY first_failure DESC;

-- B6: Service uptime over window (for SLO calculation)
SELECT
    service_id,
    countIf(health_score = 2) AS good_samples,
    count() AS total_samples,
    round(good_samples / total_samples * 100, 2) AS uptime_pct
FROM infra.service_health
WHERE event_time > now() - INTERVAL 30 DAY
GROUP BY service_id
ORDER BY uptime_pct ASC;

-- B7: Active cascade events (unresolved)
SELECT
    root_service,
    length(affected_services) AS affected_count,
    affected_services,
    event_time,
    dateDiff('second', event_time, now()) AS duration_sec
FROM infra.dependency_failures
WHERE resolved_at IS NULL
ORDER BY duration_sec DESC;
```

---

## Appendix C: Grafana Panel Reference

| Dashboard | Panel | Panel Type | Data Source | Refresh |
|-----------|-------|------------|-------------|---------|
| Service Dependency | Dependency Graph | Node Graph | CK (infra.*) | 30s |
| Service Dependency | Chain Health | Row/Repeater | CK (B1 query) | 30s |
| Service Dependency | Degraded Services | Table | CK (B1, health_score<2) | 30s |
| Service Dependency | Cascade Timeline | Time Series | CK (infra.dependency_failures) | 60s |
| Service Dependency | Suppression Status | Table | CK (B7, active cascades) | 30s |
| Boss Overview | Heartbeat Lag | Table | CK (boss_heartbeats) | 30s |
| Boss Overview | Active Bosses | Stat | CK (count distinct) | 30s |
| Bridge Metrics | Message Throughput | Time Series | CK (cc.message_log) | 1min |
| Bridge Metrics | Turn Latency | Heatmap | CK (cc.message_log) | 1min |
| Docker Events | Crash Count | Bar Chart | CK (infra.docker_events) | 1min |
| Error Budget | Budget Remaining | Bar Gauge | CK/Prometheus | 1min |

---

> **Status: COMPLETE**
> This document defines the complete service dependency graph for all 33 managed services
> (27 internal + 6 external). Implementation starts with the ClickHouse tables (P0),
> followed by health data ingestion from existing producers, and culminates in the
> dependency-aware Grafana dashboard and alerting system.

> ／人◕ ‿‿ ◕人＼
