# ClickHouse Container Deployment

> Deploy ClickHouse in Docker for kyb-infra. Covers the Docker run, verification, Kafka/PostgreSQL integrations, and common pitfalls.

## Overview

- **Image**: `clickhouse/clickhouse-server:24.2-alpine`
- **Container**: `kyb-infra-clickhouse`
- **Ports**: `8123` (HTTP), `9000` (native TCP)
- **Volume**: `ch-data:/var/lib/clickhouse`
- **Auth**: trust (no password by default)

## Docker Run

```bash
docker volume create ch-data

docker run -d \
  --name kyb-infra-clickhouse \
  --network kyb-net \
  -p 8123:8123 \
  -p 9000:9000 \
  -v ch-data:/var/lib/clickhouse \
  -e ALL_PROXY=socks5://kyb-infra-sing-box:2080 \
  -e NO_PROXY=host.orb.internal,kyb-infra-*,localhost,127.0.0.1 \
  clickhouse/clickhouse-server:24.2-alpine
```

### What the flags do

| Flag / Env         | Purpose                                            |
|---------------------|----------------------------------------------------|
| `--network kyb-net` | Join kyb-infra network (reachable by other infra containers) |
| `-p 8123:8123`      | HTTP interface (for curl, Grafana, hook scripts)   |
| `-p 9000:9000`      | Native TCP interface (for clickhouse-client)       |
| `-v ch-data`        | Persistent data (databases, tables, config)        |
| `ALL_PROXY`         | Route outbound traffic through sing-box            |
| `NO_PROXY`          | Bypass proxy for kyb-infra containers, host.orb.internal, localhost |

## Verification

### Health check via HTTP

```bash
curl http://host.orb.internal:8123/?query=SELECT+1
# Expected: 1
```

### Health check via native protocol

```bash
docker exec kyb-infra-clickhouse clickhouse-client --host localhost --query "SELECT 1"
# Expected: 1
```

### List databases

```bash
curl http://host.orb.internal:8123/?query=SHOW+DATABASES
```

### Create a test table

```bash
curl -X POST http://host.orb.internal:8123/ \
  --data-binary "CREATE TABLE IF NOT EXISTS kyb.health_check (ts DateTime64(3), msg String) ENGINE = MergeTree ORDER BY ts"
```

## Kafka Engine Setup

ClickHouse can consume from Kafka topics directly using the Kafka table engine.

### Prerequisites

- Kafka broker reachable from the ClickHouse container
- Topic already exists on the broker

### Create Kafka engine table

```sql
CREATE TABLE kyb.kafka_queue (
    timestamp DateTime64(3),
    key String,
    value String,
    topic String,
    partition UInt32,
    offset UInt64
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kyb-infra-kafka:9092',
    kafka_topic_list = 'your-topic',
    kafka_group_name = 'ck-consumer-group',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1;
```

### Create materialized view to persist Kafka data

```sql
CREATE TABLE kyb.kafka_events (
    timestamp DateTime64(3),
    key String,
    value String,
    topic String,
    partition UInt32,
    offset UInt64
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), topic);

CREATE MATERIALIZED VIEW kyb.kafka_events_mv TO kyb.kafka_events AS
SELECT * FROM kyb.kafka_queue;
```

> The materialized view continuously pulls from the Kafka engine table and inserts into the MergeTree table. Data is consumed automatically as long as the Kafka engine table exists.

### Troubleshooting Kafka engine

```bash
# Check if Kafka engine table is consuming
docker exec kyb-infra-clickhouse clickhouse-client --query "
  SELECT * FROM system.kafka_consumers FORMAT Vertical
"

# Check consumer lag (if the topic has a consumer group offset tool)
# If no data flows, verify broker reachability:
docker exec kyb-infra-clickhouse ping kyb-infra-kafka
```

## PostgreSQL Table Function

ClickHouse can query PostgreSQL tables live via the `postgresql` table function. No data is copied -- queries run on the PG side in real time.

### Basic usage

```sql
SELECT *
FROM postgresql(
    'host.orb.internal:5432',
    'mydb',
    'my_table',
    'postgres',
    'postgres'
)
WHERE id > 100
LIMIT 10;
```

### Create a cached copy (materialized from PG)

For frequent queries, it is better to periodically dump PG data into CK:

```sql
CREATE TABLE kyb.pg_users AS
SELECT * FROM postgresql(
    'host.orb.internal:5432',
    'mydb',
    'users',
    'postgres',
    'postgres'
) WHERE 1=0;  -- create schema only, no data

INSERT INTO kyb.pg_users
SELECT * FROM postgresql(
    'host.orb.internal:5432',
    'mydb',
    'users',
    'postgres',
    'postgres'
);
```

> Then set up a cron / kyb task to refresh periodically.

## Common Pitfalls

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| **Version mismatch** | Host runs CK 25.1, container runs 24.2. Queries using 25.1-only syntax fail in the container. | Standardize on one version. The host CK is used for ad-hoc queries; the container CK is for service consumers. Keep a `clickhouse-client` alias that targets the correct host/port. |
| **DateTime64(3) TTL with raw timestamp** | TTL expression `timestamp + INTERVAL 30 DAY` fails because `timestamp` is DateTime64, not Date. | Use `toDate(timestamp)` in TTL: `TTL toDate(timestamp) + INTERVAL 30 DAY` |
| **Grafana CK plugin v4 `jsonData.server`** | Plugin config uses `url` field but v4 requires `jsonData.server`. Datasource shows "Bad Gateway". | Set `jsonData.server` instead of `url` in the Grafana datasource provisioning YAML. (See grafana-deploy.md for details.) |
| **`host.orb.internal` unreachable** | Outside Orbstack (e.g., native Linux Docker), `host.orb.internal` does not resolve. | Use `host.docker.internal` or the host machine's IP address instead. |
| **NO_PROXY missing** | CK queries go through SOCKS5 proxy and fail with timeout or connection refused. | Add `NO_PROXY=host.orb.internal,localhost,127.0.0.1` to the container environment. |
| **Port conflict with host CK** | Docker fails to bind port 8123 or 9000 because host CK is already listening. | Stop host CK: `sudo systemctl stop clickhouse-server`, or use different host ports (`-p 8124:8123 -p 9001:9000`). |
| **Container CK won't start** | Logs show `Listen [::]:8123 failed: Address already in use` | Same as above -- check for host CK or another container on those ports. |
| **Subpath queries fail** | Query `SELECT * FROM my_table` returns "Database does not exist" | Even with `-e CK_DB=kyb`, you must specify the database in queries: `SELECT * FROM kyb.my_table` |
| **Memory limit errors** | CK OOM on large queries in the container. | Limit memory: add `-e CLICKHOUSE_SETTINGS=max_memory_usage=10000000000` (10 GB) |

## How to Check Logs

```bash
# Tail last 20 lines
docker logs kyb-infra-clickhouse --tail 20

# Watch logs live
docker logs -f kyb-infra-clickhouse

# Check for errors
docker logs kyb-infra-clickhouse 2>&1 | grep -i error

# Check startup sequence
docker logs kyb-infra-clickhouse 2>&1 | grep -i "done"
```

## Stopping and Cleaning Up

```bash
docker stop kyb-infra-clickhouse
docker rm kyb-infra-clickhouse
docker volume rm ch-data  # WARNING: deletes all data
```

## References

- [ClickHouse Docker Docs](https://clickhouse.com/docs/en/install/docker)
- [ClickHouse Kafka Engine](https://clickhouse.com/docs/en/engines/table-engines/integrations/kafka)
- [ClickHouse PostgreSQL Table Function](https://clickhouse.com/docs/en/sql-reference/table-functions/postgresql)
