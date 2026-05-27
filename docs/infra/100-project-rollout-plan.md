# 100 Project Infrastructure Rollout Plan

> Last updated: 2026-05-22
> Author: kyb-infra-boss
> Status: Phase 0 in progress

## Table of Contents

1. [Current State Assessment](#1-current-state-assessment)
2. [Constraints & Bottlenecks](#2-constraints--bottlenecks)
3. [Phase 0: Foundation (Week 1)](#3-phase-0--foundation)
4. [Phase 1: Per-Project Onboarding (Weeks 2-4)](#4-phase-1--per-project-onboarding)
5. [Phase 2: Observability (Weeks 3-5)](#5-phase-2--observability)
6. [Phase 3: Cloud Migration Prep (Weeks 5-8)](#6-phase-3--cloud-migration-prep)
7. [MVP Definition](#7-mvp-definition)
8. [Project Troubleshooting Doc Template](#8-troubleshooting-doc-template)
9. [Parallelization Strategy](#9-parallelization-strategy)
10. [Resource Budget](#10-resource-budget)
11. [Rollback Plan](#11-rollback-plan)

---

## 1. Current State Assessment

### 1.1 Running Infrastructure

| Service | Container | Status | Image | Port | Notes |
|---------|-----------|--------|-------|------|-------|
| Proxy | kyb-infra-sing-box | Running | kyb-sing-box:1.13.11 | 2080 | SOCKS5 all traffic |
| Redis | kyb-infra-redis | Running | redis:7-alpine | 6379 | AOF, 512MB limit |
| Kafka | kyb-infra-kafka | Running | apache/kafka:latest | 9092 | KRaft single node |
| PG16 | kyb-infra-postgresql-16 | Running | postgres:16-alpine | 5436 | Trust auth |
| PG14 | kyb-infra-postgresql-14 | Running | postgres:14-alpine | 5434 | Trust auth |
| ClickHouse | kyb-infra-clickhouse | Running | clickhouse/clickhouse-server:24.2-alpine | 8123/9000 | Containerized, fresh (4 system DBs only) |
| Boss | kyb-infra-boss | Running | kyb-base | - | AI orchestration |

### 1.2 Missing / Not Yet Deployed

| Service | Status | Blocker | Action |
|---------|--------|---------|--------|
| PG15 | Not pulled | Need to pull `postgres:15-alpine` | `docker pull postgres:15-alpine` |
| PG17 | Not pulled | Need to pull `postgres:17-alpine` | `docker pull postgres:17-alpine` |
| Grafana | Image blocked | `docker.xuanyuan.me` rate limit (429) | Try direct Docker Hub pull, or use alternative image source |
| PeerDB | ghcr.io denied | `ghcr.io/peerdb-io/*` needs auth | Use Kafka engine as fallback |
| PG15/PG17 data volumes | Not created | Pre-requisite for run commands | `docker volume create pg15-data; docker volume create pg17-data` |

### 1.3 Host Resources

| Resource | Total | Used | Free | Notes |
|----------|-------|------|------|-------|
| CPU | 10 cores (M-series) | ~2-3 cores idle | 7-8 cores | 100 agents peak = ~1-2% each |
| RAM | 16 GB | ~4-5 GB | ~11 GB | PG x4 = ~800MB-2GB, Kafka = ~600MB, base overhead |
| Disk | 121 GB overlay | 49 GB (40%) | 73 GB | Build cache = 20.58GB (97% reclaimable = 20GB) |
| Docker build cache | 20.58 GB | 383 entries | 20.05 GB reclaimable | **Immediate cleanup candidate** |

### 1.4 Pre-Onboarding Pipeline

- **Total GitLab projects scanned**: ~130 (excl. fed/ frontend, sre/, infrastructure/)
- **Onboarding-ready candidates**: ~70 (business services)
- **Already onboarded (converged)**: 18 projects (dredge-lxk, buyer-center, buyer-server, nova, data-ant, triggers-refund, form-manager, moneta, rating-boost, netflix, recommendation-filter, recommendation-config, recommendation-finder, peroration, lighthouse, sidecar, citi, business-rule)
- **Wave 1 completed (17 projects overnight 05-21)**: 12 fully converged, 3 partially blocked, 2 read-only
- **Currently registered in config.yml**: 14 projects
- **Remaining**: ~50-60 projects across groups (digismart/fly-shuttle ~14, oversea/cross-border ~25, base-service remaining ~5, RPA ~12, etc.)

### 1.5 Image Registry Status

| Registry | Status | Workaround |
|----------|--------|------------|
| `docker.io` (Docker Hub) | Rate-limited on mirror | Direct pull via ALL_PROXY |
| `docker.xuanyuan.me` (mirror) | 429 rate-limited | Wait or bypass |
| `ghcr.io` (GitHub Container Registry) | Denied (no auth) | Need GitHub PAT: `echo $PAT \| docker login ghcr.io -u <user> --password-stdin` |
| `docker.1ms.run` (mirror) | Unknown | Test: `docker pull docker.1ms.run/library/postgres:15-alpine` |

---

## 2. Constraints & Bottlenecks

### 2.1 Identified Bottlenecks (Ranked)

```
Bottleneck                     Impact                          Mitigation
─────────────────────────────  ──────────────────────────────  ─────────────────────────
1. PG provisioning (per-DB)    Each project needs own DB/schema  Pre-create all DBs centrally
2. JDK version switching       JDK 8/17/21 per-project           mise install all versions ahead
3. Nexus publish gating        Some deps not in Nexus           Publish base/common libs
4. Docker pull bandwidth       ghcr.io blocked, mirror 429      Pull via proxy, retry logic
5. Build cache bloat           20GB unused cache                 `docker builder prune -a`
6. Agent concurrency           Context window limits             Batch 3-6 per wave
7. Knowledge retention         Each agent starts fresh           Onboarding templates + .kyb.md
8. CK data restore             Containerized CK has no data      Restore from host backup
```

### 2.2 Key Constraints

- **Docker image pulls**: `docker.xuanyuan.me` returns 429. Alternative mirrors may work better. Direct Docker Hub pulls via `ALL_PROXY=socks5://kyb-infra-sing-box:2080 docker pull ...` should work for most images.
- **ghcr.io access**: PeerDB, some tools. Need GitHub PAT authentication. Can also try `docker pull ghcr.io/peerdb-io/peerdb-server:stable-v0.36.19` with `ALL_PROXY` and logged in.
- **GitLab API 403 (nuc8 proxy)**: GitLab API returns 403 when using `ALL_PROKY` through nuc8 proxy. Use `HTTPS_PROXY` (not `ALL_PROXY`) for Go tools, or direct connection.
- **Tailscale**: Not available inside containers. Use SSH via Tailscale IP from host, or public IP fallback.
- **No TTY**: `kyb enter` unavailable. Use `kyb create` + `kyb exec`.
- **ARM64**: Orbstack on M-series Mac. Some images (elasticsearch, some JDK distros) may need special handling.

### 2.3 Ordering Strategy

**Principle**: Most common tech stack first = most leverage. Java + Maven + PG is ~60% of projects.

```
Priority  Tech Stack                % of Projects  Reference Projects
────────  ────────────────────────  ─────────────  ─────────────────
P0        Java 8 + Maven + PG       ~30%           dredge-lxk, lighthouse, timeline
P0        Java 21 + Maven + PG      ~20%           buyer-center, trade, moneta
P1        Java + Maven (no DB)      ~10%           netflix, policy-tools
P1        build.sh / shell          ~10%           store-home, assistant
P2        Python + uv               ~5%            sidecar, citi
P2        Python + Airflow          ~5%            business-rule
P3        RPA scripts (various)     ~15%           refund series
P3        Go / other                ~5%            leyan-proto-golang
```

**Wave ordering (maximize reuse)**:
1. **Wave 2a**: Remaining base-service projects (Java Maven PG, most similar to already-onboarded)
2. **Wave 2b**: dialogue-engine + ai (Java 8 / Python, have reference projects)
3. **Wave 3a**: digismart/fly-shuttle (Java/Python mix, similar patterns)
4. **Wave 3b**: oversea/cross-border (Java, parallel to base-service)
5. **Wave 4**: RPA scripts (lightweight, batch processing)
6. **Wave 5**: Long tail (rest, special cases)

---

## 3. Phase 0: Foundation (Week 1)

### 3.1 Immediate Cleanup

```bash
# Free 20GB from build cache
docker builder prune -a -f

# Remove dangling images
docker image prune -f

# Check freed space
docker system df
```

### 3.2 Deploy PG15 and PG17

```bash
# Pull images (try direct Docker Hub via proxy if mirror is 429)
docker pull postgres:15-alpine
docker pull postgres:17-alpine

# Create volumes
docker volume create pg15-data
docker volume create pg17-data

# Deploy PG15
docker run -d \
  --name kyb-infra-postgresql-15 \
  --network kyb-net \
  --restart unless-stopped \
  -p 5435:5432 \
  -v pg15-data:/var/lib/postgresql/data \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=postgres \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -e TZ=Asia/Shanghai \
  postgres:15-alpine

# Deploy PG17
docker run -d \
  --name kyb-infra-postgresql-17 \
  --network kyb-net \
  --restart unless-stopped \
  -p 5437:5432 \
  -v pg17-data:/var/lib/postgresql/data \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=postgres \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -e TZ=Asia/Shanghai \
  postgres:17-alpine

# Verify all 4 versions
docker ps --filter name=kyb-infra-postgresql --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# Test connections
docker run --rm --network kyb-net postgres:16-alpine psql -h kyb-infra-postgresql-14 -U postgres -c "SELECT version();"
docker run --rm --network kyb-net postgres:16-alpine psql -h kyb-infra-postgresql-15 -U postgres -c "SELECT version();"
docker run --rm --network kyb-net postgres:16-alpine psql -h kyb-infra-postgresql-16 -U postgres -c "SELECT version();"
docker run --rm --network kyb-net postgres:16-alpine psql -h kyb-infra-postgresql-17 -U postgres -c "SELECT version();"
```

### 3.3 Fix Grafana Deployment

Grafana pull fails because `docker.xuanyuan.me` is rate-limited. Try these approaches in order:

```bash
# Approach 1: Pull via proxy directly from Docker Hub
ALL_PROXY=socks5://kyb-infra-sing-box:2080 docker pull grafana/grafana-oss:latest

# Approach 2: Try alternative mirror
docker pull docker.1ms.run/grafana/grafana-oss:latest
docker tag docker.1ms.run/grafana/grafana-oss:latest grafana/grafana-oss:latest

# Approach 3: Build from a different base image if pull fails
# (least preferred, only if 1 & 2 fail)
```

Once image is available:

```bash
docker volume create grafana-storage

docker run -d \
  --name kyb-infra-grafana \
  --network kyb-net \
  --restart unless-stopped \
  -p 3000:3000 \
  -v grafana-storage:/var/lib/grafana \
  -e GF_INSTALL_PLUGINS=grafana-clickhouse-datasource \
  -e ALL_PROXY=socks5://kyb-infra-sing-box:2080 \
  -e NO_PROXY=host.orb.internal,localhost,127.0.0.1 \
  grafana/grafana-oss:latest

# Verify
docker ps --filter name=kyb-infra-grafana
```

### 3.4 Set Up PG-to-ClickHouse Data Pipeline (PeerDB Alternative)

Since PeerDB is blocked by ghcr.io, use ClickHouse Kafka engine with PG `pgoutput` logical replication.

**Step 1: Enable logical replication on PG16**

```bash
# PG16 already deployed. Check wal_level:
docker exec kyb-infra-postgresql-16 psql -U postgres -c "SHOW wal_level;"

# If not 'logical', we need to reconfigure. Try:
docker exec -u root kyb-infra-postgresql-16 bash -c "echo 'wal_level = logical' >> /var/lib/postgresql/data/postgresql.conf"
docker exec -u root kyb-infra-postgresql-16 bash -c "echo 'max_wal_senders = 10' >> /var/lib/postgresql/data/postgresql.conf"
docker exec -u root kyb-infra-postgresql-16 bash -c "echo 'max_replication_slots = 10' >> /var/lib/postgresql/data/postgresql.conf"
docker restart kyb-infra-postgresql-16
```

**Step 2: Set up pg2kafka bridge**

```bash
# Deploy a lightweight CDC producer (Debezium Kafka Connect or pg2kafka)
# Option A: Kafka Connect with Debezium (if Kafka is running)
docker run -d \
  --name kyb-infra-debezium \
  --network kyb-net \
  --restart unless-stopped \
  -e BOOTSTRAP_SERVERS=kyb-infra-kafka:9092 \
  -e GROUP_ID=pgdck \
  -e CONFIG_STORAGE_TOPIC=pgdck-config \
  -e OFFSET_STORAGE_TOPIC=pgdck-offset \
  -e STATUS_STORAGE_TOPIC=pgdck-status \
  debezium/connect:latest
```

If Debezium image pull fails, use a lightweight Python producer:

```bash
# Minimal pg2kafka producer using psycopg2 + kafka-python
# See: /home/dev/projects/kyb/docs/infra/peerdb-pg-ck.md (Kafka Engine section)
# Or use the existing ClickHouse Kafka engine pattern:
```

**Step 3: Create ClickHouse Kafka engine tables**

```sql
-- Example: target table
CREATE TABLE IF NOT EXISTS kyb.pg_replica (
    id UInt64,
    source_table String,
    payload String,
    _timestamp DateTime DEFAULT now()
) ENGINE = MergeTree()
ORDER BY (id);

-- Kafka engine consumer
CREATE TABLE IF NOT EXISTS kyb.pg_replica_queue (
    id UInt64,
    source_table String,
    payload String
) ENGINE = Kafka()
SETTINGS
    kafka_broker_list = 'kyb-infra-kafka:9092',
    kafka_topic_list = 'pg.cdc',
    kafka_group_name = 'ck-pg-replica',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1;

-- Materialized view to persist
CREATE MATERIALIZED VIEW IF NOT EXISTS kyb.pg_replica_mv TO kyb.pg_replica AS
SELECT * FROM kyb.pg_replica_queue;
```

### 3.5 Restore ClickHouse Data (If Needed)

The containerized ClickHouse has only system databases. If the host ClickHouse data needs to be migrated:

```bash
# Check if host CK data still exists
ls /tmp/clickhouse-data/  # or wherever host data was stored

# If data exists on host, mount it into the container:
docker stop kyb-infra-clickhouse
docker rm kyb-infra-clickhouse

docker run -d \
  --name kyb-infra-clickhouse \
  --network kyb-net \
  --restart unless-stopped \
  -p 8123:8123 \
  -p 9000:9000 \
  -v /path/to/host/clickhouse/data:/var/lib/clickhouse \
  clickhouse/clickhouse-server:24.2-alpine
```

### 3.6 Phase 0 Checklist

```
[ ] docker builder prune -a (-20GB)
[ ] PG15 pulled and running
[ ] PG17 pulled and running
[ ] All 4 PG versions verified
[ ] Grafana image pulled and running
[ ] Grafana ClickHouse datasource configured
[ ] CK Kafka engine tables created
[ ] pg2kafka bridge deployed (Debezium or custom)
[ ] Host CK data restored (if needed)
[ ] All containers use --restart unless-stopped on kyb-net
[ ] NO_PROXY configured correctly on all containers
[ ] GitLab PAT for ghcr.io configured: echo "$PAT" | docker login ghcr.io -u dongqs --password-stdin
```

---

## 4. Phase 1: Per-Project Onboarding (Weeks 2-4)

### 4.1 Input: Project List

Projects come from `/home/dev/projects/kyb/docs/pre-onboarding-list.md`. Approximately 50-60 remain, grouped as:

1. **base-service (remaining)**: treasure, bot-trainer, picture-sync, base-service-common
2. **digismart (14)**: robot-processor, invoice-robot-cloud, feisuo-app, llm-wiki, dgt-risk-control, etc.
3. **oversea/cross-border (~25)**: oversea-door, overseaim-store-home, overseaim-hi, overseaim-trade, etc.
4. **RPA (12)**: refund scripts (monitor_refund_new, taobao_refund, douyin_refund, etc.)
5. **Other**: policy-codex-api, oppo-v2, leyan-proto, leyan-avro, sites, create-backend, etc.

### 4.2 Per-Project Onboarding Script

Each project follows the same sequence. Automated via a dispatch script:

```bash
#!/bin/bash
# onboard-project.sh — Onboard a single project
# Usage: ./onboard-project.sh <project-name> <gitlab-url> <pg-version>
#
# Steps (each step is a kyb exec dispatch to an AI agent):
#   1. scan — Determine tech stack (Java/Python/Ruby/Go), JDK version, DB deps, build system
#   2. clone — Git clone + checkout
#   3. build — Install deps, get a green build
#   4. test — Run tests, fix failures
#   5. doc — Write .kyb.md troubleshooting doc
#   6. register — Add to config.yml
#   7. verify — kybd create + kybd exec (DID) smoke test

PROJECT="$1"
GIT_URL="$2"
PG_VER="${3:-16}"
WORKDIR="/home/dev/projects/kyb"

echo "=== Onboarding $PROJECT (PG $PG_VER) ==="

# Step 1: Create project sandbox (non-interactive scan)
kyb create "$PROJECT-scan" --clone \
  --git-url "$GIT_URL"

# Step 2: Register in config.yml
# (automated config append)

# Step 3: Dispatch onboarding agent
kyb exec "$PROJECT-scan" -- \
  "cd /home/dev/projects/$PROJECT && \
   echo 'Tech stack scan...' && \
   ls pom.xml build.gradle build.sh setup.py pyproject.toml Cargo.toml 2>/dev/null && \
   echo '=== Git log ===' && git log --oneline -5"

# Step 4: Run build (Java example)
kyb exec "$PROJECT-scan" -- \
  "cd /home/dev/projects/$PROJECT && mvn compile -DskipTests"

# Step 5: Run tests
kyb exec "$PROJECT-scan" -- \
  "cd /home/dev/projects/$PROJECT && mvn test"

# Step 6: Write .kyb.md
# (generated from template in section 8)

# Step 7: DID smoke test
kyb did create "$PROJECT-did"
kyb exec "$PROJECT-did" -- \
  "cd /home/dev/projects/$PROJECT && mvn test"
kyb rm "$PROJECT-did"

# Cleanup scan container
kyb rm "$PROJECT-scan"

echo "=== $PROJECT onboarded ==="
```

### 4.3 Automated Batch Onboarding

For maximum throughput, run batches of 3-6 projects concurrently:

```bash
#!/bin/bash
# batch-onboard.sh — Onboard N projects in parallel
# Usage: ./batch-onboard.sh wave-2a.txt
# wave-2a.txt format: project-name git-url pg-version

BATCH_FILE="$1"
MAX_PARALLEL=6

while IFS= read -r line; do
  # Start onboarding in background, throttle to MAX_PARALLEL
  ./onboard-project.sh $line &
  
  # Wait if we've reached the limit
  while [ "$(jobs -r | wc -l)" -ge "$MAX_PARALLEL" ]; do
    sleep 10
  done
done < "$BATCH_FILE"

wait
echo "=== Batch complete ==="
```

### 4.4 Project Registration Template (config.yml addition)

For each project, add to `~/.config/kyb/config.yml`:

```yaml
  PROJECT_NAME:
    path: "~/leyan/GROUP/PROJECT_NAME"
    base_branch: master
    git_url: "git@git.leyantech.com:GROUP/PROJECT_NAME.git"
    extra_prompt: "Tech stack: Java 8 + Maven + PostgreSQL 14. See .kyb.md for known issues."
    ports:
    - 8080:8080
```

### 4.5 Database Provisioning

Onboarding a project means provisioning its database. Run this centrally (not per-agent):

```bash
#!/bin/bash
# provision-project-db.sh
# Usage: ./provision-project-db.sh <project-name> <pg-version>

PROJECT="$1"
PG_VER="${2:-16}"
PG_HOST="kyb-infra-postgresql-${PG_VER}"

echo "=== Provisioning DB for $PROJECT on PG$PG_VER ==="

# Create database
docker exec "$PG_HOST" psql -U postgres -c "CREATE DATABASE ${PROJECT//-/_};"

# Create schema (if mig25 config exists)
if [ -f "$WORKDIR/projects/$PROJECT/.env" ]; then
  docker exec kyb-infra-boss bash -c "cd /home/dev/projects/$PROJECT && mig25 up"
fi

echo "DB ${PROJECT//-/_} created on PG$PG_VER"
```

### 4.6 Phase 1 Waves

#### Wave 2a: base-service remaining (3 projects, Day 1-2)

| Project | Stack | PG | Reference |
|---------|-------|----|-----------|
| treasure | Java + Maven (est.) | 16 | buyer-center |
| bot-trainer | Unknown | 16 | assistant |
| picture-sync | Unknown | 14 | peroration |

#### Wave 2b: dialogue-engine + ai (4 projects, Day 2-3)

| Project | Stack | PG | Reference |
|---------|-------|----|-----------|
| policy-codex-api | Java + Maven | 16 | policy-tools |
| oppo-v2 | Unknown | - | netflix |
| leyan-proto | Java | - | common-libs |
| leyan-avro | Unknown | - | - |

#### Wave 3a: digismart/fly-shuttle (14 projects, Day 4-7)

Batch of 6, then batch of 6, then 2. Parallelize within each batch.

| Project | Est. Stack | PG | Notes |
|---------|-----------|----|-------|
| robot-processor | Java | 16 | Flow job backend |
| invoice-robot-cloud | Java/Python | - | Invoice robot |
| feisuo-app | Java | 16 | Fly-shuttle app backend |
| llm-wiki | Python | - | LLM knowledge base |
| dgt-risk-control | Java | 14 | Risk control |
| digismart-trade | Java | 16 | Order service |
| robot-transfer | Java | - | Robot transfer |
| digismart-alipay | Java | - | Alipay integration |
| robot-types | Java | - | Robot types |
| digsmart-metabase | Python/Java | - | Metadata |
| theia | Java | 14 | BI dashboard backend |
| dgt-bi-server | Java | - | BI server |
| digismart-item | Java | 16 | Item service |
| mola-service | Python/Java | - | Mola website |

#### Wave 3b: oversea/cross-border (~25 projects, Day 8-14)

Partition into 4 batches of 6. Each batch takes ~1-2 days.

Key projects:

| Project | Est. Stack | PG | Similar to (base-service) |
|---------|-----------|----|--------------------------|
| oversea-door | Java | 16 | Gateway |
| overseaim-store-home | Java | 16 | store-home |
| oversaim-hi-manager | Java | 16 | assistant |
| overseaim-hi | Java | 16 | dialogue |
| overseaim-trade | Java | 16 | trade |
| overseaim-item | Java | 16 | item |
| oversea-tunnel | Java | - | - |
| oversea-policy | Java | 16 | policy-tools |
| oversea-agent | Java | 16 | - |
| oversea-dialogue | Java | 16 | dialogue |

Since oversea projects are structurally parallel to base-service projects, **reuse `.kyb.md` templates from base-service counterparts** (trade, store-home, assistant, dialogue, item).

#### Wave 4: RPA scripts (12 projects, Day 15-16)

RPA is simpler (mostly Python scripts, fewer dependencies):

| Project | Type |
|---------|------|
| monitor_refund_new | Python refund monitor |
| pdd_feedback_central | PDD feedback |
| taobao_refund | Taobao refund |
| douyin_shipped_refund | Douyin shipped refund |
| taobao_return_refund | Taobao return refund |
| douyin_return_refund | Douyin return refund |
| tao_work_order | Taobao work order |
| pdd_return_and_refund | PDD return refund |
| pdd_reply_review | PDD reply review |
| rpa-control | RPA control |
| invoice-robot | Invoice robot |
| rpa-libs | RPA common libraries |

#### Wave 5: Long tail (~rest, Day 17-19)

| Project | Group | Notes |
|---------|-------|-------|
| base-service-common | base-service | Common library |
| sites | ep | Internal sites |
| create-backend | ep | Create backend |
| common-libs | ep | Java base libs |
| leyan-proto-golang | leyan | Go proto |
| java-example | leyan | Example |
| refund-agent | cto | CTO office |
| Any remaining | all | Catch-all |

### 4.7 Phase 1 Deliverables

- [ ] All ~50-60 projects registered in `~/.config/kyb/config.yml`
- [ ] Each project has `.kyb.md` troubleshooting doc in its repo
- [ ] Each project has a database created on the appropriate PG version
- [ ] Each project builds with `mvn compile` or equivalent
- [ ] Each project's tests pass in a DID container
- [ ] Wave completion reports pushed to kyb-infra-boss

---

## 5. Phase 2: Observability (Weeks 3-5)

### 5.1 Deploy Grafana (from Phase 0, unblocked)

Once the Grafana image is pulled and container is running:

```bash
# Verify Grafana is accessible
curl -s http://localhost:3000/api/health

# Provision ClickHouse datasource
cat > /home/dev/kyb/provisioning/datasources/clickhouse.yaml <<'EOF'
apiVersion: 1

datasources:
  - name: ClickHouse
    type: grafana-clickhouse-datasource
    access: proxy
    url: http://host.orb.internal:8123
    jsonData:
      defaultDatabase: kyb
      port: 8123
      protocol: http
    isDefault: true
EOF
```

### 5.2 Wire Claude Hooks -> ClickHouse

**Goal**: Every Claude Code agent session sends tool call data to ClickHouse.

**Implementation** (from `/home/dev/projects/kyb/docs/infra/claude-hooks-ck.md`):

```bash
# 1. Create ClickHouse tables
docker exec kyb-infra-clickhouse clickhouse-client <<'SQL'
CREATE TABLE IF NOT EXISTS kyb.claude_hook_events (
    timestamp DateTime64(3),
    event_type LowCardinality(String),
    session_id String,
    agent_id LowCardinality(String),
    cwd String,
    project String,
    tool_name LowCardinality(String),
    tool_input String,
    tool_output String,
    tool_exit_code Nullable(Int32),
    duration_ms UInt32,
    error_message String,
    claude_version LowCardinality(String),
    entrypoint LowCardinality(String),
    is_interactive Bool,
    model String,
    parent_session_id String,
    subagent_task String,
    prompt_preview String,
    token_count UInt32,
    message_count UInt32,
    via_proxy Bool DEFAULT false,
    metadata Map(String, String)
)
ENGINE = MergeTree
ORDER BY (toDate(timestamp), project, event_type, session_id)
TTL timestamp + INTERVAL 30 DAY;
SQL

# 2. Install hook script
mkdir -p /home/dev/.claude/hooks
cat > /home/dev/.claude/hooks/emit-ck.sh <<'SCRIPT'
#!/bin/bash
set -o pipefail
CK_HOST="${CK_HOST:-host.orb.internal}"
CK_PORT="${CK_PORT:-8123}"
CK_DB="${CK_DB:-kyb}"
CK_TABLE="${CK_TABLE:-claude_hook_events}"
CK_URL="http://${CK_HOST}:${CK_PORT}/?query=INSERT+INTO+${CK_DB}.${CK_TABLE}+FORMAT+JSONEachRow"
INPUT=$(cat)
[ -z "$INPUT" ] && exit 0
ENRICHED=$(echo "$INPUT" | python3 -c "
import json, sys, socket, os
try:
    d = json.load(sys.stdin)
except:
    sys.exit(0)
if 'timestamp' not in d or not d.get('timestamp'):
    from datetime import datetime, timezone
    d['timestamp'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
d['hostname'] = socket.gethostname()
d['pid'] = os.getpid()
d['via_proxy'] = os.environ.get('ALL_PROXY', '') != ''
print(json.dumps(d, default=str))
" 2>/dev/null)
[ -z "$ENRICHED" ] && exit 0
curl -s -X POST "$CK_URL" --noproxy '*' --max-time 3 --connect-timeout 2 \
  -H "Content-Type: application/json" -d "$ENRICHED" > /dev/null 2>&1 || true
exit 0
SCRIPT
chmod +x /home/dev/.claude/hooks/emit-ck.sh

# 3. Add hooks configuration to settings.json
# See /home/dev/projects/kyb/docs/infra/claude-hooks-ck.md section 4
```

### 5.3 Wire Network Metrics -> ClickHouse

**Goal**: Capture all container network traffic for observability.

```bash
# 1. Enable Clash API in sing-box
# Edit sing-box config to add:
# "experimental": { "clash_api": { "external_controller": "0.0.0.0:9090", "secret": "kyb-infra-token" } }

# 2. Deploy network capture poller
# See: /home/dev/projects/kyb/docs/infra/network-capture.md Phase 1

# 3. Create network_connections table in ClickHouse
docker exec kyb-infra-clickhouse clickhouse-client <<'SQL'
CREATE TABLE IF NOT EXISTS kyb.network_connections (
    timestamp       DateTime,
    src_ip          String,
    src_container   String,
    dst_host        String,
    dst_ip          String,
    dst_port        UInt16,
    protocol        String,
    outbound_rule   String,
    start_time      DateTime,
    end_time        Nullable(DateTime),
    upload_bytes    UInt64,
    download_bytes  UInt64,
    agent_id        Nullable(String),
    session_id      Nullable(String),
    project         Nullable(String)
) ENGINE = MergeTree
  ORDER BY (project, timestamp);
SQL
```

### 5.4 Per-Project Dashboard

Create a Grafana dashboard template with these panels:

1. **DB Status**: PG connection health, database size, active connections
2. **Build Status**: Last build time, success/fail rate, test count
3. **Resource Usage**: Container CPU/RAM per project
4. **Agent Activity**: Claude sessions, tool calls, errors per project
5. **Network**: API call volume, bytes transferred

**Provisioning file**:

```yaml
# /home/dev/kyb/provisioning/dashboards/project-overview.json
# (generated per project, auto-imported by Grafana)
```

### 5.5 Phase 2 Deliverables

- [ ] Grafana accessible at http://localhost:3000
- [ ] ClickHouse datasource provisioned in Grafana
- [ ] `kyb.claude_hook_events` table capturing agent tool calls
- [ ] `kyb.network_connections` table capturing network traffic
- [ ] Per-project activity dashboard (template, paramaterized by project)
- [ ] Alert: no hook events for 15 minutes => infra-boss notification
- [ ] Alert: PG connection failures => notify

---

## 6. Phase 3: Cloud Migration Prep (Weeks 5-8)

### 6.1 Document Every Service's Docker Run Command

For each container, generate a Docker run spec:

```bash
#!/bin/bash
# generate-docker-spec.sh
# Usage: ./generate-docker-spec.sh <container-name>

CONTAINER="$1"
echo "=== Docker Spec: $CONTAINER ==="

# Get full inspect
docker inspect "$CONTAINER" | python3 -c "
import json, sys
c = json.load(sys.stdin)[0]
print('Image:', c['Config']['Image'])
print('Command:', ' '.join(c['Config']['Cmd'] or []))
print('Entrypoint:', ' '.join(c['Config']['Entrypoint'] or []))
print('Env:', json.dumps(c['Config']['Env'], indent=2))
print('Ports:', json.dumps(c['NetworkSettings']['Ports'], indent=2))
print('Volumes:', json.dumps(c['Mounts'], indent=2, default=str))
print('Network:', list(c['NetworkSettings']['Networks'].keys()))
print('RestartPolicy:', c['HostConfig']['RestartPolicy']['Name'])
print('Memory:', c['HostConfig']['Memory'])
print('Labels:', json.dumps(c['Config']['Labels'], indent=2))
"

# Generate docker-compose compatible YAML
docker inspect "$CONTAINER" | python3 -c "
import json, sys
c = json.load(sys.stdin)[0]
name = c['Name'].lstrip('/')
print(f'''
# {name}
# Generated: $(date -u +%Y-%m-%d)
services:
  {name}:
    image: {c['Config']['Image']}
    container_name: {name}
    restart: unless-stopped
    networks:
      - kyb-net
    ports:
''')
for p, hosts in (c['NetworkSettings']['Ports'] or {}).items():
    if hosts:
        print(f'      - \"{hosts[0][\"HostPort\"]}:{p.split(\"/\")[0]}\"')
print('''    environment:''')
for e in c['Config']['Env'] or []:
    k = e.split('=')[0]
    print(f'      - {k}={{{{ {k} | default(\"\") }}}}')
print('''    volumes:''')
for m in c['Mounts'] or []:
    src = m.get('Source', '') or m.get('Name', '')
    dst = m['Destination']
    if m['Type'] == 'volume':
        print(f'      - {src}:{dst}')
    else:
        print(f'      - {src}:{dst}')
" 2>/dev/null
```

### 6.2 Remove Host Path Dependencies

Survey all containers for host path mounts:

```bash
docker inspect $(docker ps -q) | python3 -c "
import json, sys
data = json.load(sys.stdin)
for c in data:
    name = c['Name'].lstrip('/')
    for m in c['Mounts']:
        if m['Type'] == 'bind' and 'Source' in m:
            print(f'{name}: {m[\"Source\"]} -> {m[\"Destination\"]}')
"
```

Replace host paths with:
- Named volumes (for persistent data)
- Docker configs/secrets (for config files)
- Environment variables (for runtime config)

**Checklist**:
```
[ ] kyb-infra-sing-box  → uses custom kyb-sing-box image (ok)
[ ] kyb-infra-redis     → uses redis-data volume (ok)
[ ] kyb-infra-kafka     → uses kafka-data volume (ok)
[ ] kyb-infra-postgresql-* → uses pg*-data volumes (ok)
[ ] kyb-infra-clickhouse → check if host path mounted (should be volume)
[ ] kyb-infra-grafana   → uses grafana-storage volume + provisioning bind mount (fix provisiong)
[ ] kyb-infra-boss      → check for host dependencies
```

### 6.3 Standardize Port Mappings

Document the port allocation scheme to avoid conflicts:

| Range | Purpose | Example |
|-------|---------|---------|
| 2080 | Proxy (sing-box) | kyb-infra-sing-box |
| 3000 | Web UI | Grafana |
| 5434-5437 | PostgreSQL 14-17 | kyb-infra-postgresql-* |
| 6379 | Redis | kyb-infra-redis |
| 8123, 9000 | ClickHouse | kyb-infra-clickhouse |
| 9090-9099 | Admin/Management APIs | Clash API, Temporal |
| 9092 | Kafka | kyb-infra-kafka |
| 10666 | TTS | macOS host |
| 30000+ | Per-project sandboxes (dynamic) | kyb create |

### 6.4 Create Docker Compose Manifests

Unified docker-compose for the entire kyb-infra stack:

```yaml
# /home/dev/projects/kyb/docker-compose.infra.yml
name: kyb-infra

networks:
  kyb-net:
    external: true

volumes:
  pg14-data:
  pg15-data:
  pg16-data:
  pg17-data:
  redis-data:
  kafka-data:
  clickhouse-data:
  grafana-storage:

services:
  sing-box:
    image: kyb-sing-box:1.13.11
    container_name: kyb-infra-sing-box
    restart: unless-stopped
    networks:
      - kyb-net
    ports:
      - "2080:2080"
    volumes:
      - ./sing-box/config.json:/etc/sing-box/config.json:ro

  postgresql-14:
    image: postgres:14-alpine
    container_name: kyb-infra-postgresql-14
    restart: unless-stopped
    networks:
      - kyb-net
    ports:
      - "5434:5432"
    volumes:
      - pg14-data:/var/lib/postgresql/data
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_HOST_AUTH_METHOD: trust
      TZ: Asia/Shanghai

  # ... same pattern for PG15, PG16, PG17

  redis:
    image: redis:7-alpine
    container_name: kyb-infra-redis
    restart: unless-stopped
    networks:
      - kyb-net
    ports:
      - "6379:6379"
    volumes:
      - redis-data:/data
    command: redis-server --appendonly yes --maxmemory 512mb --maxmemory-policy allkeys-lru

  kafka:
    image: apache/kafka:latest
    container_name: kyb-infra-kafka
    restart: unless-stopped
    networks:
      - kyb-net
    ports:
      - "9092:9092"
    volumes:
      - kafka-data:/var/lib/kafka/data
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kyb-infra-kafka:9093
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kyb-infra-kafka:9092
      KAFKA_HEAP_OPTS: "-Xmx512m -Xms512m"

  clickhouse:
    image: clickhouse/clickhouse-server:24.2-alpine
    container_name: kyb-infra-clickhouse
    restart: unless-stopped
    networks:
      - kyb-net
    ports:
      - "8123:8123"
      - "9000:9000"
    volumes:
      - clickhouse-data:/var/lib/clickhouse

  grafana:
    image: grafana/grafana-oss:latest
    container_name: kyb-infra-grafana
    restart: unless-stopped
    networks:
      - kyb-net
    ports:
      - "3000:3000"
    volumes:
      - grafana-storage:/var/lib/grafana
      - ./provisioning:/etc/grafana/provisioning:ro
    environment:
      GF_INSTALL_PLUGINS: grafana-clickhouse-datasource
      ALL_PROXY: socks5://kyb-infra-sing-box:2080
      NO_PROXY: host.orb.internal,localhost,127.0.0.1
```

### 6.5 Generate Kubernetes Manifests (Optional)

If cloud target is K8s:

```bash
# Use kompose (if available) to convert docker-compose to k8s
# Or use kustomize for environment overlays
# Example: kompose convert -f docker-compose.infra.yml
```

### 6.6 Phase 3 Deliverables

- [ ] Docker run spec for every infrastructure container
- [ ] No host path bind mounts in any container (named volumes only)
- [ ] Port allocation documented and non-conflicting
- [ ] `docker-compose.infra.yml` single-file deploy
- [ ] Environment variable templating (no hardcoded secrets)
- [ ] Migration runbook: "move all containers to new host in < 1 hour"

---

## 7. MVP Definition

A project is considered "onboarded" when:

```yaml
Minimum Viable Onboarding:
  registration:    Registered in ~/.config/kyb/config.yml
  database:        Has database on correct PG version
  build:           mvn compile (or equivalent) passes
  tests:           Core test suite passes (mvn test or equivalent)
  .kyb.md:         Troubleshooting doc exists in project repo
  DID:             Works in kyb did create (Docker-in-Docker) container

Full Onboarding (all of above plus):
  CI:              GitLab CI pipeline passes with kyb container
  cleanup:         No manual steps, everything automated
  reference:       Listed in onboarded-projects-reference.md
```

### Effort Estimate Per Project

| Type | Scan | Build | Test | .kyb.md | DID | Total |
|------|------|-------|------|---------|-----|-------|
| Java Maven PG (standard) | 5m | 10m | 15m | 10m | 5m | ~45m |
| Java Maven (complex, submodules) | 10m | 20m | 30m | 15m | 5m | ~80m |
| Python (uv/pip) | 5m | 5m | 10m | 5m | 5m | ~30m |
| build.sh / shell | 5m | 10m | 10m | 5m | 5m | ~35m |
| RPA script | 5m | 5m | 5m | 5m | 5m | ~25m |

**Total Phase 1 estimate**: ~50 projects * ~45m average = ~37.5 agent-hours, or ~6 parallel agents * ~6 hours each. Realistic with wave batching: **2-3 weeks wall clock**.

### What NOT to do (anti-MVP)

- Full CI/CD pipeline overhaul (leave as-is, just make it run in kyb)
- Production data migration (not needed for dev environments)
- Performance optimization (only if blocking tests)
- Code refactoring (unless required for JDK version compatibility)
- Full test coverage improvement (fix what's broken, don't add new tests)

---

## 8. Troubleshooting Doc Template

Each onboarded project gets a `.kyb.md` file in its repo root. This template standardizes the information:

```markdown
# .kyb.md — PROJECT_NAME

## Overview

- **Group**: GROUP_NAME
- **Tech Stack**: Java 8/17/21 | Python 3.x | Maven/Gradle/uv/pip
- **Database**: PostgreSQL 14/15/16/17 (database name: PROJECT_DB)
- **External Dependencies**: Kafka | Redis | ClickHouse | Nexus | Apollo | RocketMQ
- **Maintainer**: Name (from ntsb/dbs.toml or git blame)

## Quick Start

```bash
# Clone and enter
kyb create PROJECT_NAME-feature-branch --clone
kyb exec PROJECT_NAME-feature-branch -- bash

# Run tests
cd /home/dev/projects/PROJECT_NAME
# Maven:
mvn test -DskipITs
# Python:
uv run pytest
```

## Known Issues

### Issue 1: JDK Version Required

- **Problem**: Project requires JDK 8 but kyb-base has JDK 21
- **Fix**: `mise install java@corretto-8 && mise use java@corretto-8`
- **Verify**: `java -version` → openjdk version "1.8.x"
- **Auto in DID**: See .env.kyb for JAVA_HOME override

### Issue 2: Nexus 403

- **Problem**: leyantech.leyan/chaos repo returns 403
- **Cause**: VPN/routing issue; office network works, but proxy routing fails
- **Fix**: Add mirror to ~/.m2/settings.xml:
  ```xml
  <mirror>
    <id>nexus</id>
    <url>https://nexus.leyantech.com/repository/maven-public/</url>
    <mirrorOf>*</mirrorOf>
  </mirror>
  ```
- **Verify**: `mvn dependency:resolve`

### Issue 3: Submodule Authentication

- **Problem**: `git submodule update` fails with auth error
- **Fix**: Ensure SSH agent has keys loaded:
  ```bash
  eval $(ssh-agent) && ssh-add ~/.ssh/id_ed25519
  git submodule update --init --recursive
  ```
- **Verify**: `git submodule status` shows clean

### Issue 4: ARM64 Compatibility

- **Problem**: netty-epoll, grpcio, or other native libs fail on ARM64
- **Fix**: Install ARM-compatible versions:
  - Java: Use CORRETTO JDK (ARM-native)
  - Python: Use `--find-links` for ARM wheels
  - Maven: Add netty classifier `linux-aarch_64`
- **Verify**: `uname -m` → aarch64; relevant lib loads without UnsatisfiedLinkError

### Issue 5: DID Timezone

- **Problem**: Tests fail due to UTC vs Asia/Shanghai timezone mismatch
- **Fix**: Set in DID container:
  ```bash
  export TZ=Asia/Shanghai
  ```
- **Verify**: `date` → CST

### Issue 6: Database Connection

- **Problem**: Tests can't connect to PostgreSQL
- **Fix**: Ensure PG version is running and connection string is correct:
  ```
  postgresql://postgres:postgres@kyb-infra-postgresql-16:5432/project_db
  ```
- **Verify**: `psql $DATABASE_URL -c "SELECT 1"`

## Test Pattern

```bash
# Fast unit tests (no external deps):
mvn test -DskipITs -pl module-name

# Full test suite:
mvn test

# Specific test class:
mvn test -Dtest=TestClassName

# Python:
uv run pytest tests/ -x -v
```

## Resources

- Onboarded by: [date]
- Reference projects: [similar projects]
- GitLab CI config: [link to .gitlab-ci.yml or equivalent]
- DB migration: [link to mig25 config if applicable]
```

---

## 9. Parallelization Strategy

### 9.1 Agent Dispatch Model

```
kyb-infra-boss
  │
  ├── Worker 1: Wave 2a (base-service)    → 3 projects, ~2 days
  ├── Worker 2: Wave 2b (dialogue-engine) → 4 projects, ~2 days
  ├── Worker 3: Wave 3a batch 1           → 6 projects, ~2 days
  ├── Worker 4: Wave 3a batch 2           → 6 projects, ~2 days
  ├── Worker 5: Wave 3b batch 1           → 6 projects, ~2 days
  └── Worker 6: Wave 3b batch 2           → 6 projects, ~2 days
```

### 9.2 File Conflict Avoidance

Only `~/.config/kyb/config.yml` is shared across all workers. Use a merge-safe pattern:

```bash
# Each worker writes to a fragment file, merged at the end:
echo "  $PROJECT:" >> /tmp/kyb-config-fragment-$WORKER_ID.yml
echo "    path: ..." >> /tmp/kyb-config-fragment-$WORKER_ID.yml
```

Final merge:

```bash
cat /tmp/kyb-config-fragment-*.yml >> ~/.config/kyb/config.yml
```

### 9.3 Resource Throttling

```bash
# Concurrent containers (per worker):
# Each project create → 1 kyb container
# Each DID container → 1 more
# Peak: 6 workers * 2 containers each = 12 sandboxes + 8 infra = ~20 containers

# Docker resources:
# 20 containers * ~100MB average = 2GB RAM overhead
# CPU at ~10% total utilization during build peaks

# Memory budget for 6 parallel workers:
# - Each mvn test: ~512MB-1GB heap
# - 6 workers peak: 3-6GB
# - Within 16GB total budget (with ~4GB infra overhead = 10GB/16GB)
```

### 9.4 Wave Timing

```
Week 1: Phase 0 (foundation)
Week 2: Phase 1 Wave 2a + 2b (7 projects)
Week 3: Phase 1 Wave 3a + Phase 2 start (14 projects + observability)
Week 4: Phase 1 Wave 3b (25 projects)
Week 5: Phase 1 Wave 4+5 (~rest) + Phase 2 complete
Weeks 5-8: Phase 3 (cloud migration prep)
```

**Total**: ~8 weeks for full rollout. Phase 0+1 (the critical path) = 5 weeks.

---

## 10. Resource Budget

### 10.1 Container Resources

| Container | CPU Limit | RAM Limit | Disk | Priority |
|-----------|-----------|-----------|------|----------|
| kyb-infra-sing-box | Unbound | 256 MB | Config | Critical |
| kyb-infra-redis | Unbound | 512 MB | redis-data | Critical |
| kyb-infra-kafka | Unbound | 512 MB heap | kafka-data | Critical |
| kyb-infra-postgresql-14 | Unbound | 512 MB | pg14-data | Critical |
| kyb-infra-postgresql-15 | Unbound | 512 MB | pg15-data | Critical |
| kyb-infra-postgresql-16 | Unbound | 512 MB | pg16-data | Critical |
| kyb-infra-postgresql-17 | Unbound | 512 MB | pg17-data | Critical |
| kyb-infra-clickhouse | Unbound | 2 GB | ch-data | Critical |
| kyb-infra-grafana | Unbound | 512 MB | grafana-storage | High |
| kyb-infra-boss | Unbound | 1 GB | - | Critical |
| Per sandbox (kyb create) | Unbound | 2 GB | - | Transient |

### 10.2 Disk Budget

| Category | Current | After Phase 0 | After Phase 1 | Notes |
|----------|---------|---------------|---------------|-------|
| Docker images | 53.5 GB | ~30 GB | ~35 GB | Prune 14GB unused |
| Build cache | 20.6 GB | ~0.5 GB | ~5 GB | Prune 20GB |
| Containers | 9.3 GB | ~10 GB | ~15 GB | +Grafana, +workers |
| Volumes (data) | 15.7 GB | ~16 GB | ~20 GB | PG data grows with usage |
| **Total** | **~99 GB** | **~57 GB** | **~75 GB** | **Available: ~46-64 GB** |

### 10.3 Maximum Capacity

Maximum simultaneous sandboxes before resource exhaustion:

| Constraint | Limit | Sandboxes at limit |
|------------|-------|-------------------|
| RAM (16 GB - 4 GB infra = 12 GB) | 12 GB / 2 GB per sandbox | ~6 |
| Disk (73 GB - 10 GB margin = 63 GB) | 63 GB / 500 MB per sandbox | ~126 |
| CPU (10 cores) | 10 / 0.5 core per active build | ~20 |
| Docker containers | System limit (default 100+) | ~80 |

**Practical limit**: 6-10 concurrent agent sandboxes before RAM contention.
Beyond that, jobs should be queued or scheduled.

---

## 11. Rollback Plan

### 11.1 If PG Deployment Fails

```bash
# Roll back specific PG version
docker stop kyb-infra-postgresql-14
docker rm kyb-infra-postgresql-14
docker volume rm pg14-data

# Switch all PG14-dependent projects to PG16 temporarily
# (update connection strings in config.yml or .env)
```

### 11.2 If Grafana Breaks Everything

```bash
docker stop kyb-infra-grafana
docker rm kyb-infra-grafana
docker volume rm grafana-storage
# Port 3000 freed, no impact on other services
```

### 11.3 If ClickHouse Containerization Loses Data

```bash
# Restore from host backup (if exists)
docker stop kyb-infra-clickhouse
docker rm kyb-infra-clickhouse
# Re-create with host data mount
docker run -d \
  --name kyb-infra-clickhouse \
  --network kyb-net \
  --restart unless-stopped \
  -p 8123:8123 -p 9000:9000 \
  -v /path/to/host/backup:/var/lib/clickhouse \
  clickhouse/clickhouse-server:24.2-alpine
```

### 11.4 If Onboarding Breaks a Project's CI

Projects with pre-existing CI pipelines should remain unaffected because:
- kyb onboarding does not modify CI config files
- kyb containers are isolated and do not touch the shared runner
- If project CI was already green, onboarding doesn't change that

**Worst case**: Revert the `.kyb.md` file and config.yml entry, delete any databases created:
```bash
docker exec kyb-infra-postgresql-16 psql -U postgres -c "DROP DATABASE IF EXISTS project_name;"
```

### 11.5 Full Reset

```bash
#!/bin/bash
# reset-infra.sh — Full kyb-infra reset
# Running: kyb-infra-boss, kyb-infra-sing-box, kyb-infra-redis,
#          kyb-infra-kafka, kyb-infra-postgresql-14/15/16/17,
#          kyb-infra-clickhouse, kyb-infra-grafana

for container in kyb-infra-grafana kyb-infra-clickhouse \
  kyb-infra-postgresql-17 kyb-infra-postgresql-15 \
  kyb-infra-postgresql-16 kyb-infra-postgresql-14 \
  kyb-infra-kafka kyb-infra-redis; do
  docker stop "$container" 2>/dev/null
  docker rm "$container" 2>/dev/null
done

# Remove all created volumes (careful!)
for vol in grafana-storage pg14-data pg15-data pg16-data pg17-data \
  kafka-data redis-data; do
  docker volume rm "$vol" 2>/dev/null
done

echo "=== Infrastructure reset complete ==="
echo "Re-deploy from docker-compose.infra.yml"
```

---

## Immediate Next Steps (Today)

1. **Prune build cache**: `docker builder prune -a -f` (recovers ~20GB)
2. **Deploy PG15**: `docker pull postgres:15-alpine` + run command
3. **Deploy PG17**: `docker pull postgres:17-alpine` + run command
4. **Fix Grafana pull**: Try direct Docker Hub via ALL_PROXY
5. **Set up ghcr.io auth**: `echo "$GITHUB_TOKEN" | docker login ghcr.io -u <user> --password-stdin`
6. **Create onboarding batches**: Partition remaining ~50 projects into waves
7. **Dispatch Wave 2a**: 3 base-service projects in parallel
8. **Start observability setup**: Create CK tables for hooks, deploy hook scripts

```
Phase 0 (Week 1)    ████████░░░░░░░░░░░░░░░░░░░░░░  25%
Phase 1 (Weeks 2-4) ░░░░░░░░████████████░░░░░░░░░░  50%
Phase 2 (Weeks 3-5) ░░░░░░░░░░░░░████████░░░░░░░░  25%
Phase 3 (Weeks 5-8) ░░░░░░░░░░░░░░░░░░████████████  40%
                     └──────────────────────────────
                     Week 1  2  3  4  5  6  7  8
```

---

> Written for kyb infra 100-project rollout initiative.
> Boss mode: dispatch, don't do. Parallel by default. Never wait.
