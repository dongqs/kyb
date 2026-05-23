# PeerDB: PostgreSQL -> ClickHouse Replication

> 2026-05-22
> Host: Orbstack Docker on macOS, ARM64
> ClickHouse 25.1.3.23 at `host.orb.internal:8123` (HTTP) / `:9000` (native)

## Architecture Overview

PeerDB is an open-source real-time CDC (Change Data Capture) tool purpose-built for
PostgreSQL -> ClickHouse replication. It uses PostgreSQL's logical replication (`wal_level=logical`)
to stream changes and ClickHouse's native TCP protocol to ingest.

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────────┐
│  PostgreSQL 16  │────▶│   PeerDB     │────▶│   ClickHouse    │
│  kyb-infra-     │     │  (CDC)       │     │  host.orb.      │
│  postgresql-16  │     │  kyb-net     │     │  internal:9000  │
│  :5432          │     │  :9900       │     │                 │
└─────────────────┘     └──────────────┘     └─────────────────┘
                              │
                    ┌─────────┴──────────┐
                    ▼                    ▼
             ┌────────────┐    ┌──────────────────┐
             │  Catalog   │    │  Temporal         │
             │  Postgres  │    │  Workflow Engine  │
             └────────────┘    └──────────────────┘
```

PeerDB requires several supporting services:
- **Catalog PostgreSQL**: Stores PeerDB's own metadata (peer configs, mirror state)
- **Temporal**: Workflow orchestration engine for managing replication pipelines
- **MinIO**: S3-compatible intermediate storage for ClickHouse staging (optional but recommended)

## PeerDB Docker Images

PeerDB publishes images to `ghcr.io/peerdb-io/` (GitHub Container Registry):

| Image | Tag | Purpose |
|-------|-----|---------|
| `ghcr.io/peerdb-io/peerdb-server` | `stable-v0.36.19` | SQL interface (psql on port 9900) |
| `ghcr.io/peerdb-io/peerdb-ui` | `stable-v0.36.19` | Web UI (port 3000) |
| `ghcr.io/peerdb-io/flow-api` | `stable-v0.36.19` | REST/gRPC API for flows |
| `ghcr.io/peerdb-io/flow-worker` | `stable-v0.36.19` | CDC worker process |
| `ghcr.io/peerdb-io/flow-snapshot-worker` | `stable-v0.36.19` | Initial snapshot worker |

Supporting images:
| Image | Purpose |
|-------|---------|
| `postgres:18-alpine` | PeerDB catalog database |
| `temporalio/auto-setup:1.29` | Workflow orchestration |
| `temporalio/ui:2.49.1` | Temporal UI (debugging) |
| `minio/minio:latest` | S3 intermediate storage |

## Current Environment Status

| Component | Status | Notes |
|-----------|--------|-------|
| ClickHouse 25.1 | Running | `host.orb.internal:8123/9000`, trust auth |
| PostgreSQL 16 | Running | `kyb-infra-postgresql-16:5432` on kyb-net, trust auth |
| Kafka (KRaft) | Running | `kyb-infra-kafka:9092` on kyb-net |
| kyb-net | Exists | Docker bridge network |
| PeerDB | Not deployed | Requires pull + deploy |
| ghcr.io access | DENIED | `ghcr.io/peerdb-io/*` images cannot be pulled (requires auth) |
| Docker Hub access | RATE LIMITED | Mirror `docker.xuanyuan.me` returns 429 |

> **Image Pull Status (as of 2026-05-22):**
> ```
> ghcr.io/peerdb-io/peerdb-server:stable-v0.36.19       → denied
> ghcr.io/peerdb-io/peerdb-ui:stable-v0.36.19           → denied
> ghcr.io/peerdb-io/flow-api:stable-v0.36.19            → denied
> ghcr.io/peerdb-io/flow-worker:stable-v0.36.19         → denied
> ghcr.io/peerdb-io/flow-snapshot-worker:stable-v0.36.19 → denied
> postgres:18-alpine                                     → 429
> temporalio/auto-setup:1.29                             → 429
> minio/minio:latest                                     → 429
> ```
> Resolution: Need a Docker Hub token or GitHub PAT for ghcr.io, or switch Docker mirror.

## PeerDB Deployment Plan

### Prerequisites

PostgreSQL 16 must have logical replication enabled. Check on source PG:

```sql
-- On kyb-infra-postgresql-16
SHOW wal_level;              -- must be 'logical'
SHOW max_wal_senders;        -- enough slots (>= 10)
SHOW max_replication_slots;  -- enough slots (>= 10)

-- If not set, add to postgresql.conf:
-- wal_level = logical
-- max_wal_senders = 10
-- max_replication_slots = 10
```

### Docker Compose (Recommended)

The PeerDB project provides a `docker-compose.yml` that deploys all services.
For kyb-infra, adapt it to use `kyb-net` and `kyb-infra-postgresql-16:5432` as both
the data source AND the catalog DB:

```yaml
# docker-compose.peerdb.yml
name: peerdb

x-catalog-config: &catalog-config
  PEERDB_CATALOG_HOST: kyb-infra-postgresql-16
  PEERDB_CATALOG_PORT: 5432
  PEERDB_CATALOG_USER: postgres
  PEERDB_CATALOG_PASSWORD: postgres
  PEERDB_CATALOG_DATABASE: peerdb_catalog

x-flow-worker-env: &flow-worker-env
  TEMPORAL_HOST_PORT: temporal:7233
  PEERDB_TEMPORAL_NAMESPACE: default
  AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:-}
  AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY:-}
  AWS_REGION: us-east-1
  AWS_ENDPOINT: ${AWS_ENDPOINT:-}

x-minio-config: &minio-config
  PEERDB_CLICKHOUSE_AWS_CREDENTIALS_AWS_ACCESS_KEY_ID: _peerdb_minioadmin
  PEERDB_CLICKHOUSE_AWS_CREDENTIALS_AWS_SECRET_ACCESS_KEY: _peerdb_minioadmin
  PEERDB_CLICKHOUSE_AWS_CREDENTIALS_AWS_REGION: us-east-1
  PEERDB_CLICKHOUSE_AWS_CREDENTIALS_AWS_ENDPOINT_URL_S3: http://kyb-infra-minio:9000
  PEERDB_CLICKHOUSE_AWS_S3_BUCKET_NAME: peerdbbucket

services:
  temporal:
    image: temporalio/auto-setup:1.29
    container_name: kyb-infra-temporal
    restart: unless-stopped
    networks:
      - kyb-net
    environment:
      - DB=postgres12
      - DB_PORT=5432
      - POSTGRES_USER=postgres
      - POSTGRES_PWD=postgres
      - POSTGRES_SEEDS=kyb-infra-postgresql-16
      - DYNAMIC_CONFIG_FILE_PATH=config/dynamicconfig/development-sql.yaml
    ports:
      - "7233:7233"

  temporal-ui:
    image: temporalio/ui:2.49.1
    container_name: kyb-infra-temporal-ui
    restart: unless-stopped
    networks:
      - kyb-net
    environment:
      - TEMPORAL_ADDRESS=temporal:7233
      - TEMPORAL_CORS_ORIGINS=http://localhost:3000
      - TEMPORAL_CSRF_COOKIE_INSECURE=true
    ports:
      - "8085:8080"

  flow-api:
    image: ghcr.io/peerdb-io/flow-api:stable-v0.36.19
    container_name: kyb-infra-flow-api
    restart: unless-stopped
    networks:
      - kyb-net
    ports:
      - "8112:8112"
      - "8113:8113"
    environment:
      <<: [*catalog-config, *flow-worker-env, *minio-config]
    depends_on:
      temporal:
        condition: service_started

  flow-worker:
    image: ghcr.io/peerdb-io/flow-worker:stable-v0.36.19
    container_name: kyb-infra-flow-worker
    restart: unless-stopped
    networks:
      - kyb-net
    environment:
      <<: [*catalog-config, *flow-worker-env, *minio-config]
    depends_on:
      temporal:
        condition: service_started

  flow-snapshot-worker:
    image: ghcr.io/peerdb-io/flow-snapshot-worker:stable-v0.36.19
    container_name: kyb-infra-flow-snapshot-worker
    restart: unless-stopped
    networks:
      - kyb-net
    environment:
      <<: [*catalog-config, *flow-worker-env, *minio-config]
    depends_on:
      temporal:
        condition: service_started

  peerdb-server:
    image: ghcr.io/peerdb-io/peerdb-server:stable-v0.36.19
    container_name: kyb-infra-peerdb-server
    restart: unless-stopped
    networks:
      - kyb-net
    environment:
      <<: *catalog-config
      PEERDB_PASSWORD: peerdb
      PEERDB_FLOW_SERVER_ADDRESS: grpc://flow-api:8112
      RUST_LOG: info
      RUST_BACKTRACE: 1
    ports:
      - "9900:9900"
    depends_on:
      - flow-api

  peerdb-ui:
    image: ghcr.io/peerdb-io/peerdb-ui:stable-v0.36.19
    container_name: kyb-infra-peerdb-ui
    restart: unless-stopped
    networks:
      - kyb-net
    ports:
      - "3000:3000"
    environment:
      <<: *catalog-config
      PEERDB_FLOW_SERVER_HTTP: http://flow-api:8113
      NEXTAUTH_SECRET: peerdb-secret-change-me
      NEXTAUTH_URL: http://localhost:3000
      PEERDB_EXPERIMENTAL_ENABLE_SCRIPTING: true
    depends_on:
      - flow-api

  minio:
    image: minio/minio:latest
    container_name: kyb-infra-minio
    restart: unless-stopped
    networks:
      - kyb-net
    volumes:
      - minio-data:/data
    ports:
      - "9001:9000"
      - "9002:36987"
    environment:
      <<: *minio-config
    entrypoint: >
      /bin/sh -c "
      minio server /data --console-address=:36987 &
      sleep 2;
      mc alias set myminiopeerdb http://localhost:9000 $$MINIO_ROOT_USER $$MINIO_ROOT_PASSWORD;
      mc mb myminiopeerdb/$$PEERDB_CLICKHOUSE_AWS_S3_BUCKET_NAME;
      wait
      "

volumes:
  minio-data:

networks:
  kyb-net:
    external: true
```

### Step-by-Step Deployment

```bash
# 1. Create catalog database on PG16
docker exec kyb-infra-postgresql-16 psql -U postgres -c "CREATE DATABASE peerdb_catalog;"

# 2. Pull images (if ghcr.io access is available)
ALL_PROXY=socks5://kyb-infra-sing-box:2080 docker compose -f docker-compose.peerdb.yml pull

# 3. Start services
docker compose -f docker-compose.peerdb.yml up -d

# 4. Verify
docker ps --filter name=peerdb --format 'table {{.Names}}\t{{.Status}}'
```

### Configure PG -> CK Mirror

Once PeerDB is running, connect via `psql` on port 9900:

```bash
# Connect to PeerDB SQL interface
psql "host=localhost port=9900 password=peerdb"
```

Then create the PG peer, CK peer, and mirror:

```sql
-- Create PostgreSQL peer (source)
CREATE PG PEER pg_peer
  WITH (
    host = 'kyb-infra-postgresql-16',
    port = 5432,
    user = 'postgres',
    password = 'postgres',
    database = 'postgres'
  );

-- Create ClickHouse peer (destination)
CREATE CLICKHOUSE PEER ck_peer
  WITH (
    host = 'host.orb.internal',
    port = 9000,
    user = 'default',
    password = '',
    database = 'peerdb'
  );

-- Create a mirror for specific tables
CREATE MIRROR my_mirror
  FROM pg_peer TABLES (public.table1, public.table2)
  TO ck_peer
  WITH (
    -- 'snapshot' for one-time copy, 'cdc' for continuous
    -- Or combine: 'snapshot_and_cdc'
    mode = 'snapshot_and_cdc'
  );

-- Check mirror status
SELECT * FROM peerdb_mirrors;
```

### Connection Strings

| Component | Connection |
|-----------|------------|
| PG16 (from kyb-net) | `postgresql://postgres:postgres@kyb-infra-postgresql-16:5432/postgres` |
| CK HTTP (from kyb-net) | `http://host.orb.internal:8123` |
| CK Native (from kyb-net) | `host.orb.internal:9000` |
| PeerDB SQL | `psql "host=localhost port=9900 password=peerdb"` |
| PeerDB UI | `http://localhost:3000` |
| Temporal UI | `http://localhost:8085` |

### PeerDB ClickHouse Table Schema Convention

PeerDB creates tables in the target ClickHouse database with additional metadata columns:

```sql
-- Source PG table: public.daily_dialogues
-- Target CK table: peerdb.daily_dialogues

CREATE TABLE peerdb.daily_dialogues (
  -- Original PG columns (types mapped)
  id UUID,
  seller_id Int64,
  created_at DateTime64(6),

  -- PeerDB metadata columns (auto-added)
  _peerdb_synced_at DateTime64(9) DEFAULT now64(),
  _peerdb_is_deleted UInt8,          -- soft delete flag
  _peerdb_version UInt64             -- version for conflict resolution
)
ENGINE = ReplacingMergeTree(_peerdb_version)
ORDER BY (id);
```

Key design notes:
- PeerDB uses `ReplacingMergeTree` with `_peerdb_version` for deduplication
- `_peerdb_is_deleted` tracks row deletions (PG deletes become upserts with `is_deleted=1`)
- Column types are auto-mapped from PG types to CK types
- The ORDER BY key should match the PG table's primary key

### Existing PeerDB Data in ClickHouse

As of 2026-05-22, the `peerdb` database already exists in ClickHouse with these tables:

| Table | Engine | Rows | Data |
|-------|--------|------|------|
| `peerdb.moneta_buyer_tags` | MergeTree | 103,500 | Populated |
| `peerdb.moneta_buyer_tags_migrated` | MergeTree | 103,500 | Populated |
| `peerdb.moneta_lbid_mapping` | MergeTree | 155,162 | Populated |
| `peerdb.daily_*` (6 tables) | MergeTree | 0 | Empty (schemas exist) |

The populated tables are from a previous PeerDB deployment that has since been
decommissioned. Metadata columns (`_peerdb_synced_at`, `_peerdb_is_deleted`,
`_peerdb_version`) are present on most tables.

---

## Alternative: ClickHouse Kafka Engine

If PeerDB cannot be deployed (e.g., ghcr.io access is blocked), the alternative
is to stream data through Kafka into ClickHouse using ClickHouse's built-in
Kafka engine.

### Architecture

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────────┐
│  PostgreSQL 16  │────▶│  Kafka       │────▶│   ClickHouse    │
│  (via Debezium  │     │  kyb-infra-  │     │  Kafka Engine   │
│   CDC, pgoutput)│     │  kafka:9092  │     │  + MV -> MergeTree
└─────────────────┘     └──────────────┘     └─────────────────┘
```

Two approaches:
1. **Debezium + Kafka**: PG -> Debezium -> Kafka -> CK Kafka Engine -> MaterializedView -> MergeTree
2. **Direct Kafka producer**: Application writes to Kafka -> CK Kafka Engine -> MergeTree

### Kafka Engine Table

ClickHouse 25.1 supports the Kafka engine natively. The standard pattern uses
three objects:

```sql
-- 1. Create the target MergeTree table (persistent storage)
CREATE TABLE peerdb.daily_dialogues (
  id UUID,
  seller_id Int64,
  created_at DateTime64(6),
  content String,
  _timestamp DateTime DEFAULT now()
)
ENGINE = MergeTree()
ORDER BY (id);

-- 2. Create the Kafka engine table (stream consumer)
--    Note: This table does NOT persist data itself
CREATE TABLE peerdb.daily_dialogues_queue (
  id UUID,
  seller_id Int64,
  created_at DateTime64(6),
  content String
)
ENGINE = Kafka()
SETTINGS
  kafka_broker_list = 'kyb-infra-kafka:9092',
  kafka_topic_list = 'pg.daily_dialogues',
  kafka_group_name = 'ck-peerdb-consumer',
  kafka_format = 'JSONEachRow',
  kafka_num_consumers = 2;

-- 3. Materialized View: streams Kafka data into the MergeTree table
CREATE MATERIALIZED VIEW peerdb.daily_dialogues_mv TO peerdb.daily_dialogues AS
SELECT * FROM peerdb.daily_dialogues_queue;
```

### Kafka Engine Parameters

| Parameter | Recommended Value | Notes |
|-----------|------------------|-------|
| `kafka_broker_list` | `kyb-infra-kafka:9092` | Kafka on kyb-net |
| `kafka_topic_list` | `pg.<table_name>` | Topic per table convention |
| `kafka_group_name` | `ck-peerdb-<table>` | Consumer group per table |
| `kafka_format` | `JSONEachRow` | JSON messages matching column names |
| `kafka_num_consumers` | ≤ partitions | Max parallelism |
| `kafka_skip_broken_messages` | 100 | Skip malformed messages |
| `kafka_max_block_size` | 65536 | Max batch size |
| `kafka_commit_on_select` | `false` | Commit based on flush interval |

### Data Flow

```
Kafka topic "pg.daily_dialogues"
  │
  ▼
kafka.daily_dialogues_queue (Kafka engine, transient)
  │
  ▼ (MaterializedView)
peerdb.daily_dialogues (MergeTree, persistent)
  │
  ▼ (optional MaterializedView for aggregation)
daily.daily_dialogues (daily aggregation table)
```

### Handling PG CDC via Debezium

For true CDC from PostgreSQL through Kafka, you would use Debezium
(either as a connector in Kafka Connect or as a standalone service):

```bash
# Debezium connector config (conceptual)
{
  "name": "pg-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "kyb-infra-postgresql-16",
    "database.port": "5432",
    "database.user": "postgres",
    "database.password": "postgres",
    "database.dbname": "postgres",
    "database.server.name": "kyb-infra-pg16",
    "plugin.name": "pgoutput",
    "table.include.list": "public.daily_dialogues",
    "transforms": "unwrap",
    "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
    "value.converter.schemas.enable": false
  }
}
```

Alternatively, a simpler approach: write a lightweight Go/Rust/Python service
that tails PG via `pg_logical` or `pgoutput` and produces to Kafka directly.

### Verification Steps

```sql
-- Check Kafka engine status
SELECT * FROM system.kafka_consumers;

-- Read raw Kafka data (may block waiting for messages)
SELECT * FROM peerdb.daily_dialogues_queue LIMIT 5;

-- Read persisted data
SELECT count() FROM peerdb.daily_dialogues;
```

---

## Comparison: PeerDB vs Kafka Engine

| Factor | PeerDB | Kafka Engine + Debezium |
|--------|--------|------------------------|
| **Setup complexity** | Medium (5 services) | High (Kafka + Debezium + CK engine) |
| **Infrastructure** | Heavy (catalog PG, Temporal, MinIO) | Light if Kafka already exists |
| **Image availability** | Blocked (ghcr.io denied) | Kafka works (`apache/kafka:latest`) |
| **CDC support** | Native, built-in | Requires Debezium connector |
| **DDL changes** | Handled by PeerDB | Manual (need to alter CK schema) |
| **Operational burden** | Higher (more moving parts) | Moderate |
| **ClickHouse integration** | Purpose-built, optimizes batch writes | Generic Kafka consumer |
| **Monitoring** | PeerDB UI + Temporal UI | ClickHouse system.kafka_consumers |
| **Production readiness** | Mature (PeerDB v0.36) | Mature (ClickHouse + Kafka) |
| **PG schema mapping** | Automatic type mapping | Manual (define CK columns) |
| **Deletes** | Handled via `_peerdb_is_deleted` | Requires custom handling |
| **Conflict resolution** | Version-based (`_peerdb_version`) | Last-write-wins |

---

## Recommendation

**Option 1: PeerDB (if ghcr.io access resolved)**

PeerDB is the best tool for this job -- it is purpose-built for PG -> CK
replication, handles CDC automatically, maps types, tracks deletes, and
manages the initial snapshot. However, deployment is currently blocked by
ghcr.io access. Resolution paths:

1. Authenticate to ghcr.io: `ALL_PROXY=socks5://... echo $GITHUB_TOKEN | docker login ghcr.io -u <user> --password-stdin`
2. Build PeerDB images from source
3. Use a different Docker registry mirror

**Option 2: Kafka Engine (if Kafka already exists, which it does)**

Since Kafka is already running (`kyb-infra-kafka:9092`) and the ClickHouse
Kafka engine is built-in (no additional images needed), this is the most
immediately feasible approach. Add a Kafka Connect Debezium container or
a lightweight CDC producer to bridge PG -> Kafka.

**Option 3: Hybrid (recommended for now)**

Use the ClickHouse Kafka engine with a lightweight PG CDC producer for the
immediate need, with PeerDB as a future upgrade once ghcr.io access is resolved.

---

## References

- PeerDB Docs: https://docs.peerdb.io
- PeerDB GitHub: https://github.com/PeerDB-io/peerdb
- ClickHouse Kafka Engine: https://clickhouse.com/docs/engines/table-engines/integrations/kafka
- ClickHouse PG-CK Stack: https://github.com/ClickHouse/postgres-clickhouse-stack
- Debezium PG Connector: https://debezium.io/documentation/reference/connectors/postgresql.html
